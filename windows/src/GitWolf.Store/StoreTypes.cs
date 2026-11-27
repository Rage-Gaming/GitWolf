using GitWolf.Core;

namespace GitWolf.Store;

public enum StoreMode { History, Changes, Compare, Stash, PullRequests, Issues }

/// <summary>What a hook printed, and the signing choice to repeat if the user commits without hooks.</summary>
public sealed record HookFailure(string Hook, string Output, bool? Sign);

public abstract record StoreSheet
{
    public sealed record NewBranch(string? From) : StoreSheet;
    public sealed record NewTag(string Hash) : StoreSheet;
    public sealed record StashChanges : StoreSheet;
}

public abstract record WebTarget
{
    public sealed record Repository : WebTarget;
    public sealed record Branch : WebTarget;
    public sealed record PullRequest : WebTarget;
    public sealed record Commit(string Hash) : WebTarget;
}

/// <summary>What the store needs from user settings and saved accounts. Read on every use.</summary>
public interface IStoreSettings
{
    int CommitPageSize { get; }
    /// <summary>0 disables background fetch.</summary>
    int AutoFetchMinutes { get; }
    /// <summary>Pull by rebasing local commits onto the upstream instead of merging.</summary>
    bool PullRebase => false;
    /// <summary>Applies git path, diff context and credentials to a repository.</summary>
    GitRepository Configure(GitRepository repo);
    /// <summary>The saved account for a host, if the user added one.</summary>
    ProviderAccount? AccountForHost(string host) => null;

    /// <summary>The user agreed to what this repository's configuration runs.</summary>
    void TrustRepository(string root, string fingerprint) { }
    /// <summary>The account's token or password, refreshed first when it is an expiring sign-in.</summary>
    Task<string?> SecretAsync(ProviderAccount account) => Task.FromResult<string?>(null);
    /// <summary>Replaced by tests; null uses the real network.</summary>
    HttpTransport? Transport => null;
}
