using System.Text.Json;

namespace GitWolf.Core;

// Ported from apple/Sources/GitWolfCore/CollabActions.swift.

public enum MergeMethod { Merge, Squash, Rebase }

public static class MergeMethodExtensions
{
    public static string Title(this MergeMethod method) => method switch
    {
        MergeMethod.Squash => "Squash and merge",
        MergeMethod.Rebase => "Rebase and merge",
        _ => "Create a merge commit",
    };
}

/// <summary>A comment on a pull request or issue.</summary>
public sealed record CollabComment(string Id, string Author, string Body, DateTimeOffset? Created);

public sealed partial class ProviderClient
{
    private void GuardWriting(CollabKind kind)
    {
        if (!Account.Kind.SupportsWriting(kind, Account.Host))
            throw ProviderException.Unsupported(
                $"{Account.Kind.Title()} {(kind == CollabKind.Issue ? "issues" : "pull requests")} can’t be changed from GitWolf yet.");
    }

    // MARK: Create

    /// <summary>Opens a pull / merge request from `head` into `base` and returns it.</summary>
    public async Task<CollabItem> CreatePullRequestAsync(
        string repoPath, string title, string body, string head, string baseBranch, bool draft)
    {
        GuardWriting(CollabKind.PullRequest);
        var url = Repo(repoPath) + (Account.Kind == ProviderKind.Bitbucket ? "/pullrequests" : $"/{Resource(CollabKind.PullRequest)}");
        object json = Account.Kind switch
        {
            ProviderKind.GitHub => new Dictionary<string, object>
                { ["title"] = title, ["body"] = body, ["head"] = head, ["base"] = baseBranch, ["draft"] = draft },
            ProviderKind.GitLab => new Dictionary<string, object>
            {
                ["title"] = draft ? $"Draft: {title}" : title, ["description"] = body,
                ["source_branch"] = head, ["target_branch"] = baseBranch,
            },
            ProviderKind.Gitea => new Dictionary<string, object>
                { ["title"] = draft ? $"WIP: {title}" : title, ["body"] = body, ["head"] = head, ["base"] = baseBranch },
            _ => new Dictionary<string, object>
            {
                ["title"] = title, ["description"] = body,
                ["source"] = new { branch = new { name = head } },
                ["destination"] = new { branch = new { name = baseBranch } },
            },
        };
        return Created(await SendAsync(HttpMethod.Post, url, json), CollabKind.PullRequest);
    }

    public async Task<CollabItem> CreateIssueAsync(
        string repoPath, string title, string body, IReadOnlyList<string>? labels = null)
    {
        GuardWriting(CollabKind.Issue);
        var json = new Dictionary<string, object> { ["title"] = title };
        json[Account.Kind == ProviderKind.GitLab ? "description" : "body"] = body;
        if (labels is { Count: > 0 })
        {
            if (Account.Kind == ProviderKind.GitHub) json["labels"] = labels;
            else if (Account.Kind == ProviderKind.GitLab) json["labels"] = string.Join(',', labels);
        }
        return Created(await SendAsync(HttpMethod.Post, $"{Repo(repoPath)}/issues", json), CollabKind.Issue);
    }

    /// <summary>The parsers expect lists; a create call returns one object.</summary>
    private CollabItem Created(byte[] data, CollabKind kind)
    {
        var items = Account.Kind switch
        {
            ProviderKind.GitHub => ParseGitHubCollab(AsArray(data), kind),
            ProviderKind.GitLab => ParseGitLabCollab(AsArray(data), kind),
            ProviderKind.Gitea => ParseGiteaCollab(AsArray(data), kind),
            _ => ParseBitbucketCollab(AsValues(data)),
        };
        return items.Count > 0 ? items[0] : throw ProviderException.InvalidResponse;
    }

    private static string ObjectText(byte[] data)
    {
        using var doc = ParseJson(data);
        return doc.RootElement.ValueKind == JsonValueKind.Object
            ? doc.RootElement.GetRawText()
            : throw ProviderException.InvalidResponse;
    }

    private static byte[] AsArray(byte[] data) => System.Text.Encoding.UTF8.GetBytes($"[{ObjectText(data)}]");

    private static byte[] AsValues(byte[] data) =>
        System.Text.Encoding.UTF8.GetBytes($"{{\"values\":[{ObjectText(data)}]}}");

    // MARK: Comments

    private string CommentsUrl(CollabKind kind, string repoPath, int number) => Account.Kind switch
    {
        ProviderKind.GitLab => $"{Repo(repoPath)}/{Resource(kind)}/{number}/notes",
        ProviderKind.Bitbucket => $"{Repo(repoPath)}/pullrequests/{number}/comments",
        _ => $"{Repo(repoPath)}/issues/{number}/comments",
    };

    public async Task<List<CollabComment>> CommentsAsync(CollabKind kind, string repoPath, int number)
    {
        GuardWriting(kind);
        var url = CommentsUrl(kind, repoPath, number);
        switch (Account.Kind)
        {
            case ProviderKind.GitHub or ProviderKind.Gitea:
                return ParseComments(await FetchAsync(url + "?per_page=100"), "user", "login");
            case ProviderKind.GitLab:
                // System notes ("added 1 commit", "changed the description") are noise here.
                return ParseComments(await FetchAsync(url + "?sort=asc&per_page=100"), "author", "username", "system");
            default:
            {
                using var doc = ParseJson(await FetchAsync(url + "?pagelen=100&sort=created_on"));
                if (Property(doc.RootElement, "values") is not { ValueKind: JsonValueKind.Array } values)
                    throw ProviderException.InvalidResponse;
                var result = new List<CollabComment>();
                foreach (var r in values.EnumerateArray())
                {
                    if (GetInt(r, "id") is not { } id || Property(r, "content") is not { } content
                        || GetString(content, "raw") is not { } raw || GetBool(r, "deleted", false)) continue;
                    var author = Property(r, "user") is { } u ? GetString(u, "display_name") ?? GetString(u, "nickname") ?? "" : "";
                    result.Add(new CollabComment(id.ToString(), author, raw, Iso(GetString(r, "created_on"))));
                }
                return result;
            }
        }
    }

    internal static List<CollabComment> ParseComments(byte[] data, string authorKey, string nameKey, string? skipping = null)
    {
        var result = new List<CollabComment>();
        foreach (var r in ArrayOf(data))
        {
            if (skipping is not null && GetBool(r, skipping, false)) continue;
            if (GetString(r, "body") is not { } text) continue;
            var id = Property(r, "id")?.ToString() ?? Guid.NewGuid().ToString();
            result.Add(new CollabComment(id, Nested(r, authorKey, nameKey), text, Iso(GetString(r, "created_at"))));
        }
        return result;
    }

    public async Task AddCommentAsync(CollabKind kind, string repoPath, int number, string body)
    {
        GuardWriting(kind);
        object json = Account.Kind == ProviderKind.Bitbucket ? new { content = new { raw = body } } : new { body };
        await SendAsync(HttpMethod.Post, CommentsUrl(kind, repoPath, number), json);
    }

    // MARK: Merge and close

    public async Task MergeAsync(string repoPath, int number, MergeMethod method)
    {
        GuardWriting(CollabKind.PullRequest);
        var name = method.ToString().ToLowerInvariant();
        var repo = Repo(repoPath);
        switch (Account.Kind)
        {
            case ProviderKind.GitHub:
                await SendAsync(HttpMethod.Put, $"{repo}/pulls/{number}/merge", new { merge_method = name });
                break;
            case ProviderKind.GitLab:
                if (method == MergeMethod.Rebase)
                    throw ProviderException.Unsupported(
                        "GitLab merges with fast-forward only if the project is set to it. Choose merge or squash.");
                await SendAsync(HttpMethod.Put, $"{repo}/merge_requests/{number}/merge",
                    new { squash = method == MergeMethod.Squash });
                break;
            case ProviderKind.Gitea:
                await SendAsync(HttpMethod.Post, $"{repo}/pulls/{number}/merge", new Dictionary<string, string> { ["Do"] = name });
                break;
            default:
                var strategy = method switch
                {
                    MergeMethod.Squash => "squash", MergeMethod.Rebase => "fast_forward", _ => "merge_commit",
                };
                await SendAsync(HttpMethod.Post, $"{repo}/pullrequests/{number}/merge", new { merge_strategy = strategy });
                break;
        }
    }

    /// <summary>Closes or reopens a pull request or issue. (Bitbucket can only decline; it can't reopen.)</summary>
    public async Task SetOpenAsync(bool open, CollabKind kind, string repoPath, int number)
    {
        GuardWriting(kind);
        var repo = Repo(repoPath);
        switch (Account.Kind)
        {
            case ProviderKind.GitHub or ProviderKind.Gitea:
                await SendAsync(HttpMethod.Patch, $"{repo}/{Resource(kind)}/{number}", new { state = open ? "open" : "closed" });
                break;
            case ProviderKind.GitLab:
                await SendAsync(HttpMethod.Put, $"{repo}/{Resource(kind)}/{number}", new { state_event = open ? "reopen" : "close" });
                break;
            default:
                if (open) throw ProviderException.Unsupported("Bitbucket can’t reopen a declined pull request.");
                await SendAsync(HttpMethod.Post, $"{repo}/pullrequests/{number}/decline");
                break;
        }
    }

    // MARK: Labels

    /// <summary>Replaces an item's labels (GitHub and GitLab; Gitea addresses labels by id and isn't supported).</summary>
    public async Task SetLabelsAsync(IReadOnlyList<string> labels, CollabKind kind, string repoPath, int number)
    {
        GuardWriting(kind);
        switch (Account.Kind)
        {
            case ProviderKind.GitHub:
                await SendAsync(HttpMethod.Put, $"{Repo(repoPath)}/issues/{number}/labels", new { labels });
                break;
            case ProviderKind.GitLab:
                await SendAsync(HttpMethod.Put, $"{Repo(repoPath)}/{Resource(kind)}/{number}",
                    new { labels = string.Join(',', labels) });
                break;
            default:
                throw ProviderException.Unsupported($"Editing labels isn’t supported for {Account.Kind.Title()}.");
        }
    }

    /// <summary>Names of the labels defined in the repository.</summary>
    public async Task<List<string>> RepositoryLabelsAsync(string repoPath) =>
        Account.Kind is ProviderKind.GitHub or ProviderKind.Gitea or ProviderKind.GitLab
            ? ArrayOf(await FetchAsync($"{Repo(repoPath)}/labels?per_page=100"))
                .Select(l => GetString(l, "name")).OfType<string>().ToList()
            : [];
}
