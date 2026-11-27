using System.Text.Json;

namespace GitWolf.Core;

// Ported from the collaboration part of apple/Sources/GitWolfCore/ProviderClient.swift.

public enum CollabKind { PullRequest, Issue }

public enum CollabState { Open, Closed, Merged }

public enum CollabFilter { Open, Closed, All }

/// <summary>A pull / merge request or an issue.</summary>
public sealed record CollabItem
{
    public required int Number { get; init; }
    public required string Title { get; init; }
    public string Author { get; init; } = "";
    public CollabState State { get; init; } = CollabState.Open;
    public bool IsDraft { get; init; }
    public IReadOnlyList<string> Labels { get; init; } = [];
    public int Comments { get; init; }
    public DateTimeOffset? Created { get; init; }
    public DateTimeOffset? Updated { get; init; }
    /// <summary>The item's web page; only http and https addresses are kept.</summary>
    public Uri? Url { get; init; }
    public string Body { get; init; } = "";
    public string SourceBranch { get; init; } = "";
    public string TargetBranch { get; init; } = "";
    /// <summary>Commit at the tip of the pull request branch, used to look up CI checks.</summary>
    public string HeadSha { get; init; } = "";
}

public static class CollabProviderExtensions
{
    /// <summary>Whether GitWolf can list pull requests / issues for this provider.</summary>
    public static bool SupportsCollab(this ProviderKind kind, CollabKind what, string host) => kind switch
    {
        ProviderKind.GitHub or ProviderKind.GitLab or ProviderKind.Gitea => true,
        ProviderKind.Bitbucket => what == CollabKind.PullRequest && host == "bitbucket.org",
        _ => false,
    };

    /// <summary>Whether GitWolf can create and change them (not just list them).</summary>
    public static bool SupportsWriting(this ProviderKind kind, CollabKind what, string host) =>
        kind.SupportsCollab(what, host);
}

public sealed partial class ProviderClient
{
    public const int CollabPageSize = 30;

    /// <summary>One page (1-based) of pull requests or issues for the repository at `owner/repo`.</summary>
    public async Task<List<CollabItem>> CollabAsync(CollabKind kind, string repoPath, CollabFilter filter, int page) =>
        (await ListCollabAsync(kind, repoPath, filter, page)).Select(i => i with { Url = Openable(i.Url) }).ToList();

    /// <summary>
    /// A link the server sent, if it may be opened: https, or http for an account on a plain-HTTP server.
    /// </summary>
    private Uri? Openable(Uri? url) =>
        url is not null && (url.Scheme == Uri.UriSchemeHttps || Account.Scheme == "http") ? url : null;

    private async Task<List<CollabItem>> ListCollabAsync(CollabKind kind, string repoPath, CollabFilter filter, int page)
    {
        if (!Account.Kind.SupportsCollab(kind, Account.Host))
            throw ProviderException.Unsupported(
                $"{Account.Kind.Title()} {(kind == CollabKind.Issue ? "issues are" : "pull requests are")} not supported here yet.");
        const int n = CollabPageSize;
        var state = filter.ToString().ToLowerInvariant();
        var pulls = kind == CollabKind.PullRequest;
        switch (Account.Kind)
        {
            case ProviderKind.GitHub:
                return ParseGitHubCollab(await FetchAsync(
                    $"{Repo(repoPath)}/{(pulls ? "pulls" : "issues")}?state={state}&sort=updated&direction=desc&per_page={n}&page={page}"), kind);
            case ProviderKind.GitLab:
            {
                string[] states = filter switch
                {
                    CollabFilter.Open => ["opened"],
                    CollabFilter.Closed => pulls ? ["closed", "merged"] : ["closed"],
                    _ => ["all"],
                };
                var items = new List<CollabItem>();
                foreach (var s in states)
                    items.AddRange(ParseGitLabCollab(await FetchAsync(
                        $"{Repo(repoPath)}/{Resource(kind)}?state={s}&order_by=updated_at&sort=desc&per_page={n}&page={page}"), kind));
                return states.Length > 1 ? items.OrderByDescending(i => i.Updated ?? DateTimeOffset.MinValue).ToList() : items;
            }
            case ProviderKind.Gitea:
                return ParseGiteaCollab(await FetchAsync(pulls
                    ? $"{Repo(repoPath)}/pulls?state={state}&sort=recentupdate&limit={n}&page={page}"
                    : $"{Repo(repoPath)}/issues?type=issues&state={state}&limit={n}&page={page}"), kind);
            default:
            {
                string[] states = filter switch
                {
                    CollabFilter.Open => ["OPEN"],
                    CollabFilter.Closed => ["MERGED", "DECLINED"],
                    _ => ["OPEN", "MERGED", "DECLINED"],
                };
                var query = string.Join('&', states.Select(s => $"state={s}"));
                return ParseBitbucketCollab(await FetchAsync(
                    $"{Repo(repoPath)}/pullrequests?{query}&sort=-updated_on&pagelen={n}&page={page}"));
            }
        }
    }

    /// <summary>
    /// The API address of a repository. The path comes from a git remote, so each part is escaped and
    /// dot segments are refused: it must not steer a request (with the token) somewhere else.
    /// </summary>
    private string Repo(string repoPath)
    {
        var parts = repoPath.Split('/');
        if (parts.Any(p => p.Length == 0 || p is "." or ".."))
            throw ProviderException.Unsupported("That repository path isn’t valid.");
        return Account.Kind switch
        {
            ProviderKind.GitLab => $"{ApiBase}/projects/{GitLabProjectId(repoPath)}",
            ProviderKind.Bitbucket => $"{ApiBase}/repositories/{string.Join('/', parts.Select(Uri.EscapeDataString))}",
            _ => $"{ApiBase}/repos/{string.Join('/', parts.Select(Uri.EscapeDataString))}",
        };
    }

    internal static string GitLabProjectId(string path) => Uri.EscapeDataString(path);

    private string Resource(CollabKind kind) => kind == CollabKind.Issue ? "issues"
        : Account.Kind == ProviderKind.GitLab ? "merge_requests" : "pulls";

    // MARK: Parsing

    private static int? GetInt(JsonElement element, string property) =>
        Property(element, property) is { ValueKind: JsonValueKind.Number } v && v.TryGetInt32(out var n) ? n : null;

    private static string Nested(JsonElement element, string property, string inner) =>
        Property(element, property) is { } child ? GetString(child, inner) ?? "" : "";

    private static IEnumerable<JsonElement> Items(JsonElement element, string property) =>
        Property(element, property) is { ValueKind: JsonValueKind.Array } v ? v.EnumerateArray() : [];

    private static Uri? Link(string? address) =>
        Uri.TryCreate(address, UriKind.Absolute, out var url)
        && (url.Scheme == Uri.UriSchemeHttps || url.Scheme == Uri.UriSchemeHttp) ? url : null;

    internal static List<CollabItem> ParseGitHubCollab(byte[] data, CollabKind kind)
    {
        var result = new List<CollabItem>();
        foreach (var r in ArrayOf(data))
        {
            // The issues endpoint also returns pull requests; drop them.
            if (kind == CollabKind.Issue && Property(r, "pull_request") is not null) continue;
            if (GetInt(r, "number") is not { } number || GetString(r, "title") is not { } title) continue;
            result.Add(new CollabItem
            {
                Number = number, Title = title, Author = Nested(r, "user", "login"),
                State = GetString(r, "merged_at") is not null ? CollabState.Merged
                    : GetString(r, "state") == "open" ? CollabState.Open : CollabState.Closed,
                IsDraft = GetBool(r, "draft", false),
                Labels = Items(r, "labels").Select(l => GetString(l, "name")).OfType<string>().ToList(),
                Comments = GetInt(r, "comments") ?? 0,
                Created = Iso(GetString(r, "created_at")), Updated = Iso(GetString(r, "updated_at")),
                Url = Link(GetString(r, "html_url")), Body = GetString(r, "body") ?? "",
                SourceBranch = Nested(r, "head", "ref"), TargetBranch = Nested(r, "base", "ref"),
                HeadSha = Nested(r, "head", "sha"),
            });
        }
        return result;
    }

    internal static List<CollabItem> ParseGitLabCollab(byte[] data, CollabKind kind)
    {
        var result = new List<CollabItem>();
        foreach (var r in ArrayOf(data))
        {
            if (GetInt(r, "iid") is not { } number || GetString(r, "title") is not { } title) continue;
            result.Add(new CollabItem
            {
                Number = number, Title = title, Author = Nested(r, "author", "username"),
                State = GetString(r, "state") switch
                {
                    "merged" => CollabState.Merged, "closed" => CollabState.Closed, _ => CollabState.Open,
                },
                IsDraft = kind == CollabKind.PullRequest && GetBool(r, "draft", GetBool(r, "work_in_progress", false)),
                Labels = Items(r, "labels").Where(l => l.ValueKind == JsonValueKind.String).Select(l => l.GetString()!).ToList(),
                Comments = GetInt(r, "user_notes_count") ?? 0,
                Created = Iso(GetString(r, "created_at")), Updated = Iso(GetString(r, "updated_at")),
                Url = Link(GetString(r, "web_url")), Body = GetString(r, "description") ?? "",
                SourceBranch = GetString(r, "source_branch") ?? "", TargetBranch = GetString(r, "target_branch") ?? "",
                HeadSha = GetString(r, "sha") ?? "",
            });
        }
        return result;
    }

    internal static List<CollabItem> ParseGiteaCollab(byte[] data, CollabKind kind)
    {
        var result = new List<CollabItem>();
        foreach (var r in ArrayOf(data))
        {
            if (GetInt(r, "number") is not { } number || GetString(r, "title") is not { } title) continue;
            var merged = GetBool(r, "merged", GetString(r, "merged_at") is not null);
            var lowered = title.ToLowerInvariant();
            var draft = GetBool(r, "draft",
                lowered.StartsWith("wip:") || lowered.StartsWith("[wip]") || lowered.StartsWith("draft:"));
            result.Add(new CollabItem
            {
                Number = number, Title = title, Author = Nested(r, "user", "login"),
                State = merged ? CollabState.Merged
                    : GetString(r, "state") == "open" ? CollabState.Open : CollabState.Closed,
                IsDraft = kind == CollabKind.PullRequest && draft,
                Labels = Items(r, "labels").Select(l => GetString(l, "name")).OfType<string>().ToList(),
                Comments = GetInt(r, "comments") ?? 0,
                Created = Iso(GetString(r, "created_at")), Updated = Iso(GetString(r, "updated_at")),
                Url = Link(GetString(r, "html_url")), Body = GetString(r, "body") ?? "",
                SourceBranch = Nested(r, "head", "ref"), TargetBranch = Nested(r, "base", "ref"),
                HeadSha = Nested(r, "head", "sha"),
            });
        }
        return result;
    }

    internal static List<CollabItem> ParseBitbucketCollab(byte[] data)
    {
        using var doc = ParseJson(data);
        if (Property(doc.RootElement, "values") is not { ValueKind: JsonValueKind.Array } values)
            throw ProviderException.InvalidResponse;
        var result = new List<CollabItem>();
        foreach (var r in values.EnumerateArray())
        {
            if (GetInt(r, "id") is not { } number || GetString(r, "title") is not { } title) continue;
            string Branch(string side) =>
                Property(r, side) is { } s ? Nested(s, "branch", "name") : "";
            result.Add(new CollabItem
            {
                Number = number, Title = title,
                Author = Property(r, "author") is { } a ? GetString(a, "display_name") ?? GetString(a, "nickname") ?? "" : "",
                State = GetString(r, "state") switch
                {
                    "MERGED" => CollabState.Merged, "OPEN" => CollabState.Open, _ => CollabState.Closed,
                },
                Comments = GetInt(r, "comment_count") ?? 0,
                Created = Iso(GetString(r, "created_on")), Updated = Iso(GetString(r, "updated_on")),
                Url = Link(Property(r, "links") is { } links ? Nested(links, "html", "href") : null),
                Body = GetString(r, "description") ?? "",
                SourceBranch = Branch("source"), TargetBranch = Branch("destination"),
                HeadSha = Property(r, "source") is { } source ? Nested(source, "commit", "hash") : "",
            });
        }
        return result;
    }
}
