using System.Diagnostics;
using GitWolf.Core;

namespace GitWolf.Store;

// The repository's hosting provider: pull requests, issues, CI checks and forking.
public sealed partial class RepositoryStore
{
    private static readonly TimeSpan ForkRetryDelay = TimeSpan.FromSeconds(4);

    private CollabStore? _pullRequests;
    private CollabStore? _issues;

    public CollabStore PullRequests => _pullRequests ??= new CollabStore(CollabKind.PullRequest, ConnectAsync);
    public CollabStore Issues => _issues ??= new CollabStore(CollabKind.Issue, ConnectAsync);
    public CollabStore Collab(CollabKind kind) => kind == CollabKind.PullRequest ? PullRequests : Issues;

    private ProviderAccount? Account =>
        RemoteLocation?.Host is { } host ? _settings.AccountForHost(host) : null;

    private ProviderKind? ProviderKindOfRemote =>
        RemoteLocation?.Host is { } host ? Account?.Kind ?? ProviderKindExtensions.Guess(host) : null;

    /// <summary>Whether the remote is on a provider whose pull requests / issues can be listed.</summary>
    public bool Supports(CollabKind kind) =>
        RemoteLocation is { } location && ProviderKindOfRemote is { } provider
        && provider.SupportsCollab(kind, Account?.Host ?? location.Host);

    /// <summary>"Pull Requests" or "Merge Requests" depending on the provider.</summary>
    public string PullRequestsTitle => (WebLinks?.PullRequestsWord ?? "Pull Request") + "s";

    public bool HasProviderAccount => Account is not null;

    public bool CanFork =>
        RemoteLocation?.Host is { } host && ProviderKindOfRemote is { } kind && kind.SupportsForking()
        && !(kind == ProviderKind.Bitbucket && host != "bitbucket.org");

    /// <summary>
    /// A client for the remote's provider and the `owner/repo` path. A saved account's secret is used
    /// only when the account is for exactly this host; otherwise the request is anonymous.
    /// </summary>
    public async Task<ProviderConnection?> ConnectAsync()
    {
        if (RemoteLocation is not { } location) return null;
        var saved = _settings.AccountForHost(location.Host);
        // A guessed provider gets no secret, and is only ever reached over HTTPS.
        var account = saved ?? (ProviderKindExtensions.Guess(location.Host) is { } kind
            ? new ProviderAccount(kind, location.Host, "")
            : null);
        if (account is null) return null;
        var secret = saved is null ? null : await _settings.SecretAsync(saved);
        return new ProviderConnection(
            new ProviderClient(account, secret ?? "", _settings.Transport), location.Path, !string.IsNullOrEmpty(secret));
    }

    /// <summary>Called when accounts were added or removed.</summary>
    public void AccountsChanged()
    {
        ResetChecks();
        _pullRequests?.Reset();
        _issues?.Reset();
        NotifyProvider();
        if (Mode is StoreMode.PullRequests) _ = PullRequests.LoadAsync();
        if (Mode is StoreMode.Issues) _ = Issues.LoadAsync();
        if (SelectedCommit is { } commit) _ = LoadChecksAsync(commit.Hash);
        LoadHeadChecks();
    }

    private void NotifyProvider()
    {
        Notify(nameof(RemoteLocation));
        Notify(nameof(WebLinks));
        Notify(nameof(ProviderTitle));
    }

    // MARK: Issue references

    /// <summary>Up to 15 open issues to reference in a commit message; empty when they can't be listed.</summary>
    public async Task<IReadOnlyList<CollabItem>> OpenIssuesAsync()
    {
        if (!Supports(CollabKind.Issue)) return [];
        try
        {
            if (await ConnectAsync() is not { } connection) return [];
            var (client, path) = (connection.Client, connection.Path);
            var issues = await Task.Run(() => client.CollabAsync(CollabKind.Issue, path, CollabFilter.Open, 1));
            return issues.Take(15).ToList();
        }
        catch (ProviderException e)
        {
            Trace.TraceWarning($"Listing issues failed (HTTP {e.Status}).");
            return [];
        }
    }

    public void AddIssueReference(string keyword, int number) =>
        DraftMessage = Core.CommitMessage.AddReference(keyword, number, DraftMessage);

    // MARK: Create and fork

    /// <summary>
    /// Opens a pull request from the current branch (pushing it first when the server lacks its latest
    /// commits) or an issue. Throws with the reason on failure.
    /// </summary>
    public async Task CreateCollabAsync(CollabKind kind, string title, string body, string baseBranch, bool draft)
    {
        var head = Status.Branch ?? "";
        if (kind == CollabKind.PullRequest)
        {
            if (head.Length == 0) throw ProviderException.Unsupported("Check out a branch first.");
            if (NeedsPush)
            {
                var (repo, status, remotes) = (Repo, Status, Remotes);
                await Task.Run(() => repo.PushAsync(status, remotes));
                _ = RequestRefresh();
            }
        }
        await Collab(kind).CreateAsync(title, body, head, baseBranch, draft);
        if (kind == CollabKind.PullRequest) DismissPushOffer();
        Mode = kind == CollabKind.PullRequest ? StoreMode.PullRequests : StoreMode.Issues;
    }

    public bool NeedsPush => Status.Upstream is null || Status.Ahead > 0;

    /// <summary>
    /// Forks the repository on its provider, then points this checkout at the fork. Throws with the
    /// reason on failure. Changes the server and the remotes: the UI asks first.
    /// </summary>
    public async Task ForkAsync(ForkRemoteMode mode)
    {
        if (IsBusy) throw ProviderException.Unsupported("Wait for the current operation to finish.");
        SetBusy(true, "Forking…");
        try
        {
            if (await ConnectAsync() is not { SignedIn: true } connection)
                throw ProviderException.Unsupported("Add an account for this repository’s host in Settings → Accounts.");
            var repo = Repo;
            // Check before forking, so a refused remote setup doesn't leave a fork behind.
            if (mode.RemoteName is null && Remotes.Contains("upstream"))
                throw ProviderException.Unsupported("A remote named “upstream” already exists. Add the fork as another remote.");
            if (mode.RemoteName is { } name && Remotes.Contains(name))
                throw ProviderException.Unsupported($"A remote named “{name}” already exists.");
            var (client, path) = (connection.Client, connection.Path);
            await Task.Run(async () =>
            {
                var fork = await client.ForkAsync(path);
                var remote = await repo.AdoptForkAsync(fork, mode, fetch: false);
                try
                {
                    await repo.FetchRemoteAsync(remote);
                }
                catch (GitException)
                {
                    // GitHub copies in the background; give it a moment and try the fetch once more.
                    await Task.Delay(ForkRetryDelay, _lifetime.Token);
                    await repo.FetchRemoteAsync(remote);
                }
            });
        }
        finally
        {
            SetBusy(false, null);
            _ = RefreshRemoteLocationAsync();
            _ = RequestRefresh();
        }
    }
}
