using System.Globalization;
using System.Text.RegularExpressions;

namespace GitWolf.Core;

public enum PullStrategy
{
    /// <summary>Merge when histories diverged (the default).</summary>
    Merge,
    /// <summary>Rebase local commits on top of the upstream, stashing local changes around it.</summary>
    Rebase,
    /// <summary>Only move forward; fail if the branch has diverged.</summary>
    FastForwardOnly,
}

/// <param name="Remote">Push to this remote instead of the branch's upstream.</param>
/// <param name="Force">Overwrite the remote branch, as confirmed. Its remote wins over <c>Remote</c>.</param>
/// <param name="SetUpstream">Track the remote branch afterwards.</param>
public sealed record PushOptions(
    string? Remote = null, ForcePushPlan? Force = null, bool IncludeTags = false, bool SetUpstream = false);

/// <summary>What a force push would replace, as shown to the user before it runs.</summary>
/// <param name="Target">The branch on the remote.</param>
/// <param name="Expected">The commit it was at; null when it didn't exist.</param>
/// <param name="LostCount">How many of its commits the local branch doesn't have.</param>
/// <param name="Lost">The newest of those, as "hash author: subject".</param>
public sealed record ForcePushPlan(
    string Branch, string Remote, string Target, string? Expected, int LostCount, IReadOnlyList<string> Lost);

public static class SyncErrors
{
    /// <summary>The remote refused a push because it has commits you don't, or your view of it was stale.</summary>
    public static bool IsPushRejected(this GitException error) =>
        new[] { "[rejected]", "non-fast-forward", "fetch first", "stale info" }
            .Any(text => error.Stderr.Contains(text, StringComparison.Ordinal));

    /// <summary>A pull that stopped because the branches diverged and fast-forward was required.</summary>
    public static bool IsDivergedPull(this GitException error) =>
        error.Stderr.Contains("Not possible to fast-forward", StringComparison.Ordinal)
        || error.Stderr.Contains("divergent branches", StringComparison.Ordinal);
}

public sealed record RemoteInfo(string Name, string FetchUrl, string PushUrl);

// Pushing with options, and managing remotes. Ported from Sync.swift.
public sealed partial class GitRepository
{
    public Task PushAsync(WorkingStatus status, IReadOnlyList<string> remotes) =>
        PushAsync(status, remotes, new PushOptions());

    /// <summary>
    /// Fetches the remote, then reports what a force push would replace. The push is tied to that
    /// commit, so a later background fetch can't widen what gets overwritten.
    /// </summary>
    public async Task<ForcePushPlan> PlanForcePushAsync(
        WorkingStatus status, IReadOnlyList<string> remotes, string? chosen = null)
    {
        if (status.Branch is not { } branch) throw NoBranch();
        var remote = chosen ?? await PushRemoteAsync(status, remotes, branch);
        var target = status.Upstream is { } upstream
            && SplitRemoteBranch(upstream, remotes) is var (host, name) && host == remote ? name : branch;
        await FetchRemoteAsync(remote);

        var tracking = $"refs/remotes/{remote}/{target}";
        // Unlike rev-parse, this succeeds with no output when the ref doesn't exist.
        var found = await Git.RunStringAsync(
            ["for-each-ref", "--format=%(refname) %(objectname)", tracking], readOnly: true);
        var expected = found.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(line => line.Split(' '))
            .FirstOrDefault(parts => parts[0] == tracking)?[1];
        if (expected is null) return new ForcePushPlan(branch, remote, target, null, 0, []);

        var range = $"refs/heads/{branch}..{expected}";
        var count = int.Parse(
            (await Git.RunStringAsync(["rev-list", "--count", range, "--"], readOnly: true)).Trim(),
            CultureInfo.InvariantCulture);
        var log = await Git.RunStringAsync(
            ["log", "--no-show-signature", "-n", "5", "--format=%h %an: %s", range, "--"], readOnly: true);
        return new ForcePushPlan(branch, remote, target, expected, count,
            log.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries));
    }

    public async Task PushAsync(WorkingStatus status, IReadOnlyList<string> remotes, PushOptions options)
    {
        var arguments = new List<string> { "push" };
        var force = options.Force;
        if (force is not null)
        {
            if (status.Branch != force.Branch)
                throw new GitException("push", 1, "The branch changed since the force push was confirmed.");
            // An empty expected commit means "only if the branch doesn't exist".
            arguments.Add($"--force-with-lease=refs/heads/{force.Target}:{force.Expected}");
        }
        if (options.IncludeTags) arguments.Add("--tags");
        var publishing = status.Upstream is null;
        var chosen = force?.Remote ?? options.Remote;
        string? remote;
        if (status.Branch is { } branch && (chosen is not null || publishing))
        {
            remote = chosen ?? await PushRemoteAsync(status, remotes, branch);
            // Publishing to a remote the branch doesn't track yet also starts tracking it.
            if (publishing || options.SetUpstream) arguments.Add("--set-upstream");
            arguments.Add(Operand(remote));
            // A force push names exactly one branch, whatever `push.default` says: the one confirmed.
            arguments.Add($"refs/heads/{branch}:refs/heads/{force?.Target ?? branch}");
        }
        else
        {
            // Without a branch there is no chosen remote to name one on.
            if (options.Remote is not null && !options.IncludeTags) throw NoBranch();
            remote = options.Remote ?? await BranchRemoteAsync(status.Branch, push: true);
            if (options.Remote is not null) arguments.Add(Operand(options.Remote));
        }
        var net = await RemoteGitAsync(remote, push: true);
        await net.RunAsync([.. arguments]);
    }

    private async Task<string> PushRemoteAsync(WorkingStatus status, IReadOnlyList<string> remotes, string branch) =>
        (status.Upstream is null ? DefaultRemote(remotes) : await BranchRemoteAsync(branch, push: true))
        ?? "origin";

    private static GitException NoBranch() => new("push", 1, "Check out a branch before pushing it.");

    /// <summary>Remotes with their fetch and push URLs. Any password in a URL is hidden.</summary>
    public async Task<IReadOnlyList<RemoteInfo>> RemoteInfosAsync()
    {
        var output = await Git.RunStringAsync(["remote", "-v"], readOnly: true);
        var order = new List<string>();
        var fetch = new Dictionary<string, string>(StringComparer.Ordinal);
        var push = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var line in output.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            // "name<TAB>url (fetch)", with " [filter]" after it for a partial clone. URLs may hold spaces.
            var match = RemoteLine().Match(line);
            if (!match.Success) continue;
            var name = match.Groups["name"].Value;
            if (!order.Contains(name)) order.Add(name);
            (match.Groups["kind"].Value == "fetch" ? fetch : push)[name] = Redact(match.Groups["url"].Value);
        }
        return order.Select(name =>
        {
            var from = fetch.GetValueOrDefault(name, "");
            return new RemoteInfo(name, from, push.GetValueOrDefault(name, from));
        }).ToList();
    }

    /// <summary>
    /// `https://user:secret@host/x` becomes `https://user@host/x`. A web address whose user name is a
    /// token (`https://token@host/x`) loses the name too.
    /// </summary>
    public static string Redact(string url) => UrlUser().Replace(
        UrlPassword().Replace(url, match => match.Groups["user"].Value.Length > 0
            ? $"{match.Groups["scheme"].Value}{match.Groups["user"].Value}@"
            : match.Groups["scheme"].Value),
        match => LooksLikeToken(match.Groups["user"].Value) ? match.Groups["scheme"].Value : match.Value);

    /// <summary>A known token prefix, or a long run of letters and digits that no one picks as a name.</summary>
    private static bool LooksLikeToken(string user) =>
        TokenPrefix().IsMatch(user)
        || (user.Length >= 32 && user.Any(char.IsAsciiDigit)
            && user.All(c => char.IsAsciiLetterOrDigit(c) || c is '_' or '-'));

    public Task AddRemoteAsync(string name, string url) =>
        Git.RunAsync(["remote", "add", RemoteName(name), RemoteUrl(url)]);

    public Task RemoveRemoteAsync(string name) => Git.RunAsync(["remote", "remove", RemoteName(name)]);

    public Task RenameRemoteAsync(string old, string name) =>
        Git.RunAsync(["remote", "rename", RemoteName(old), RemoteName(name)]);

    public Task SetRemoteUrlAsync(string name, string url) =>
        Git.RunAsync(["remote", "set-url", RemoteName(name), RemoteUrl(url)]);

    private static string RemoteName(string name) =>
        name.Length > 0 && !name.StartsWith('-') && !name.Any(char.IsWhiteSpace)
            ? name
            : throw new GitException("remote", 1, $"“{name}” isn’t a valid remote name.");

    private static string RemoteUrl(string url)
    {
        var trimmed = url.Trim();
        if (trimmed.Length == 0 || trimmed.StartsWith('-') || trimmed.Any(char.IsControl))
            throw new GitException("remote", 1, "Enter the remote’s URL.");
        // "transport::address" runs a helper program, and "ext::" runs any command.
        if (HelperUrl().IsMatch(trimmed))
            throw new GitException("remote", 1, "Addresses that name a helper program (“::”) aren’t supported.");
        RefuseSecret("remote", trimmed);
        return trimmed;
    }

    /// <summary>Secrets never go into URLs: they would end up in .git/config in plain text.</summary>
    private static void RefuseSecret(string command, string url)
    {
        if (UrlPassword().IsMatch(url) || Redact(url) != url)
            throw new GitException(command, 1,
                "Don’t put a password or token in the URL. Connect an account in Settings → Accounts instead.");
    }

    [GeneratedRegex(@"^(?<name>[^\t]+)\t(?<url>.*) \((?<kind>fetch|push)\)( \[[^\]]*\])?$")]
    private static partial Regex RemoteLine();

    [GeneratedRegex(@"^(?<scheme>[A-Za-z][A-Za-z0-9+.-]*://)(?<user>[^/?#:]*):[^/?#]*@")]
    private static partial Regex UrlPassword();

    [GeneratedRegex(@"^(?<scheme>[Hh][Tt][Tt][Pp][Ss]?://)(?<user>[^/?#:@]+)@")]
    private static partial Regex UrlUser();

    [GeneratedRegex(@"^(gh[pousr]_|github_pat_|glpat-|gloas-|ATBB|ATATT)")]
    private static partial Regex TokenPrefix();

    [GeneratedRegex(@"^[A-Za-z0-9][A-Za-z0-9+.-]*::")]
    private static partial Regex HelperUrl();
}
