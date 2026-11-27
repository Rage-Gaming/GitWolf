namespace GitWolf.Core;

// Ported from apple/Sources/GitWolfCore/Fork.swift.

public static class ForkExtensions
{
    public static bool SupportsForking(this ProviderKind kind) => kind != ProviderKind.Azure;
}

/// <summary>What to do with a fork once it exists.</summary>
/// <param name="RemoteName">
/// Add the fork as an extra remote with this name; null makes the original `upstream` and the fork
/// `origin`, the usual contribution setup.
/// </param>
public sealed record ForkRemoteMode(string? RemoteName)
{
    public static ForkRemoteMode UseAsOrigin { get; } = new((string?)null);
    public static ForkRemoteMode AddRemote(string name) => new(name);
}

public sealed partial class ProviderClient
{
    /// <summary>
    /// Forks the repository into your account (or returns the existing fork) and gives its clone URLs.
    /// GitHub finishes the copy in the background, so a fetch right away can take a few seconds to work.
    /// </summary>
    public async Task<RemoteRepository> ForkAsync(string repoPath)
    {
        if (!Account.Kind.SupportsForking() || (Account.Kind == ProviderKind.Bitbucket && Account.Host != "bitbucket.org"))
            throw ProviderException.Unsupported($"Forking isn’t supported for {Account.Kind.Title()} here.");
        var data = await SendAsync(HttpMethod.Post,
            Repo(repoPath) + (Account.Kind == ProviderKind.GitLab ? "/fork" : "/forks"), new { });
        var parsed = Account.Kind switch
        {
            ProviderKind.GitHub => ParseGitHub(AsArray(data)),
            ProviderKind.Gitea => ParseGitea(AsArray(data)),
            ProviderKind.GitLab => ParseGitLab(AsArray(data)),
            _ => ParseBitbucket(AsValues(data)),
        };
        return parsed.Count > 0 ? parsed[0] : throw ProviderException.InvalidResponse;
    }
}

public sealed partial class GitRepository
{
    /// <summary>URL of a remote, if it exists.</summary>
    public async Task<string?> RemoteUrlAsync(string name)
    {
        try
        {
            return (await Git.RunStringAsync(["remote", "get-url", Operand(name)], readOnly: true)).Trim();
        }
        catch (GitException)
        {
            return null;
        }
    }

    /// <summary>
    /// Points this repository at a fork, using SSH when the current remote does, otherwise HTTPS, then
    /// fetches it. Pass `fetch: false` to only rewire the remotes.
    /// </summary>
    /// <returns>The name of the remote that now points at the fork.</returns>
    public async Task<string> AdoptForkAsync(RemoteRepository fork, ForkRemoteMode mode, bool fetch = true)
    {
        var current = await RemoteUrlAsync("origin") ?? "";
        var usesSsh = current.StartsWith("git@", StringComparison.Ordinal) || current.StartsWith("ssh://", StringComparison.Ordinal);
        var url = usesSsh && fork.SshUrl.Length > 0 ? fork.SshUrl : fork.HttpsUrl;
        // The address comes from a server: only a network URL, never a git remote helper or an option.
        if (RemoteLocation.Parse(url) is null || url.StartsWith('-') || url.Contains("::", StringComparison.Ordinal))
            throw ProviderException.InvalidResponse;

        string remote;
        if (mode.RemoteName is { } name)
        {
            if (name.Length == 0 || name.StartsWith('-') || name.Any(char.IsWhiteSpace))
                throw new GitException("remote add", 1, $"“{name}” isn’t a valid remote name.");
            await Git.RunAsync(["remote", "add", name, url]);
            remote = name;
        }
        else
        {
            if ((await RemotesAsync()).Contains("upstream"))
                throw new GitException("remote rename", 1,
                    "A remote named “upstream” already exists. Use “Add as a remote” instead.");
            await Git.RunAsync(["remote", "rename", "origin", "upstream"]);
            await Git.RunAsync(["remote", "add", "origin", url]);
            remote = "origin";
        }
        if (fetch) await FetchRemoteAsync(remote);
        return remote;
    }
}
