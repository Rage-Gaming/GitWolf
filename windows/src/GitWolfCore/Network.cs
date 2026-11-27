namespace GitWolf.Core;

// Commands that talk to a remote. They run what the repository configures with the user's rights, so
// an account token is handed only to the process whose remote belongs to that account.
public sealed partial class GitRepository
{
    private const string CredentialWithheld =
        "GitWolf didn’t use your saved account: this repository’s own configuration sets an HTTP or proxy "
        + "option that could send the token elsewhere. Remove it from .git/config to use the account.";

    private const string CredentialWithheldFromSubmodules =
        "GitWolf didn’t use your saved account: this repository or one of its submodules is set up to run "
        + "programs, which could read the token.";

    private sealed record NetworkRunner(GitRunner Git, bool HasCredential, string? Withheld)
    {
        public async Task RunAsync(params string[] arguments)
        {
            try
            {
                await Git.RunAsync(arguments);
            }
            catch (GitException error) when (Withheld is not null && error is not UntrustedRepositoryException)
            {
                throw new GitException(error.Command, error.ExitCode, $"{error.Stderr.Trim()}\n\n{Withheld}");
            }
        }
    }

    /// <summary>A runner for one remote, with the account credential when every address of it is the account's.</summary>
    /// <param name="push">Use the addresses git pushes to, which can differ from the ones it fetches.</param>
    /// <param name="disableHooks">Stops repository hooks from running.</param>
    /// <param name="submodules">
    /// The command also works inside submodules, so no program any of them configures may see the token.
    /// </param>
    private async Task<NetworkRunner> RemoteGitAsync(
        string? remote, bool push = false, bool disableHooks = false, bool submodules = false)
    {
        var environment = new Dictionary<string, string>();
        string? withheld = null;
        var hasCredential = false;
        if (remote is not null && await CredentialForRemoteAsync(remote, push) is var (credential, url))
        {
            var risk = await RepositoryInspector.InspectAsync(Root, GitPath);
            if (risk.BlocksCredential)
            {
                withheld = CredentialWithheld;
            }
            else if (submodules && risk.Settings.Count > 0)
            {
                withheld = CredentialWithheldFromSubmodules;
            }
            else
            {
                environment = credential.Environment(AskpassPath!, url);
                hasCredential = true;
                // No clean-up job that could run a configured command with the token in its environment.
                GitCredential.AddConfig(environment, "maintenance.auto", "false");
                GitCredential.AddConfig(environment, "gc.auto", "0");
            }
        }
        // "ext::" addresses are commands. Set here, it outranks the repository's own setting.
        GitCredential.AddConfig(environment, "protocol.ext.allow", "never");
        if (disableHooks) GitCredential.AddConfig(environment, "core.hooksPath", "/dev/null");
        return new NetworkRunner(Runner(environment), hasCredential, withheld);
    }

    private async Task<(GitCredential Credential, string Url)?> CredentialForRemoteAsync(string remote, bool push)
    {
        if (Credentials is null || AskpassPath is null || remote.StartsWith('-')) return null;
        string[] urls;
        try
        {
            // `get-url` applies `insteadOf` rewrites, so these are the addresses git will really use.
            string[] arguments = push ? ["remote", "get-url", "--push", "--all", remote] : ["remote", "get-url", "--all", remote];
            urls = (await Git.RunStringAsync(arguments, readOnly: true))
                .Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        }
        catch (GitException error) when (error is not UntrustedRepositoryException)
        {
            return null; // Not a configured remote; git reports that itself.
        }
        if (urls.Length == 0 || GitCredential.HttpAuthority(urls[0]) is not { } authority) return null;
        if (await Credentials(authority) is not { } credential || !urls.All(credential.Allows)) return null;
        return (credential, urls[0]);
    }

    private async Task<string?> ConfigValueAsync(string key)
    {
        var output = await Git.RunAsync(["config", "--get", key], readOnly: true,
            allowedExitCodes: new HashSet<int> { 0, 1 });
        var value = System.Text.Encoding.UTF8.GetString(output).Trim();
        return value.Length == 0 ? null : value;
    }

    private async Task<string?> CurrentBranchAsync()
    {
        var output = await Git.RunAsync(["symbolic-ref", "-q", "--short", "HEAD"], readOnly: true,
            allowedExitCodes: new HashSet<int> { 0, 1 });
        var name = System.Text.Encoding.UTF8.GetString(output).Trim();
        return name.Length == 0 ? null : name;
    }

    private static string? DefaultRemote(IReadOnlyList<string> remotes) =>
        remotes.Contains("origin") ? "origin" : remotes.Count > 0 ? remotes[0] : null;

    /// <summary>The remote `git pull` fetches from, or with <paramref name="push"/> the one `git push` sends to.</summary>
    private async Task<string?> BranchRemoteAsync(string? branch, bool push)
    {
        if (branch is not null)
        {
            if (push && await ConfigValueAsync($"branch.{branch}.pushRemote") is { } own) return own;
            if (push && await ConfigValueAsync("remote.pushDefault") is { } shared) return shared;
            if (await ConfigValueAsync($"branch.{branch}.remote") is { } upstream) return upstream;
        }
        return DefaultRemote(await RemotesAsync());
    }

    /// <summary>
    /// A runner for submodule commands, which may use the account of the remote this repository pulls from.
    /// </summary>
    private async Task<NetworkRunner> SubmoduleGitAsync() => await RemoteGitAsync(
        await BranchRemoteAsync(await CurrentBranchAsync(), push: false), disableHooks: true, submodules: true);

    public async Task FetchAsync()
    {
        var remotes = await RemotesAsync();
        var skipped = await SkippedByFetchAllAsync();
        var included = remotes.Where(r => !skipped.Contains(r)).ToList();
        var runners = new List<(string Remote, NetworkRunner Net)>();
        // Fetch also runs unattended in the background, so no repository hook runs.
        foreach (var remote in included)
            runners.Add((remote, await RemoteGitAsync(remote, disableHooks: true)));

        if (runners.All(r => !r.Net.HasCredential && r.Net.Withheld is null))
        {
            var plain = await RemoteGitAsync(null, disableHooks: true);
            await plain.RunAsync("fetch", "--all", "--prune");
            return;
        }

        // One process per remote: a token never reaches another remote's commands, and other hosts keep
        // the user's own sign-in. A failing remote doesn't stop the rest.
        GitException? first = null;
        foreach (var (remote, net) in runners)
        {
            try
            {
                await FetchOneAsync(net, remote);
            }
            catch (GitException error) when (error is not UntrustedRepositoryException)
            {
                first ??= error;
            }
        }
        if (first is not null) throw first;
    }

    private static Task FetchOneAsync(NetworkRunner net, string remote) => net.HasCredential
        // A submodule's own configuration must not run with the token.
        ? net.RunAsync("fetch", "--prune", "--no-recurse-submodules", Operand(remote))
        : net.RunAsync("fetch", "--prune", Operand(remote));

    private async Task<HashSet<string>> SkippedByFetchAllAsync()
    {
        var output = await Git.RunAsync(
            ["config", "--bool", "--get-regexp", @"^remote\..*\.(skipfetchall|skipdefaultupdate)$"], readOnly: true,
            allowedExitCodes: new HashSet<int> { 0, 1 });
        var skipped = new HashSet<string>(StringComparer.Ordinal);
        foreach (var line in System.Text.Encoding.UTF8.GetString(output).Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            if (!line.TrimEnd().EndsWith(" true", StringComparison.Ordinal)) continue;
            var key = line[..line.LastIndexOf(' ')];
            skipped.Add(key["remote.".Length..key.LastIndexOf('.')]);
        }
        return skipped;
    }

    /// <summary>Fetches one remote.</summary>
    public async Task FetchRemoteAsync(string remote) =>
        await FetchOneAsync(await RemoteGitAsync(remote, disableHooks: true), remote);
}
