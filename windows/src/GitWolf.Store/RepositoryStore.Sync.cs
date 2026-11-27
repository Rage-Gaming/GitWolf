using System.Diagnostics;
using GitWolf.Core;

namespace GitWolf.Store;

// Pulling, pushing and managing remotes.
public sealed partial class RepositoryStore
{
    /// <summary>The strategy of a pull that local work stopped, so "stash and pull" repeats it.</summary>
    private PullStrategy? _blockedStrategy;

    private PullStrategy DefaultStrategy => _settings.PullRebase ? PullStrategy.Rebase : PullStrategy.Merge;

    /// <summary>A pull that local work is in the way of sets <see cref="PullBlock"/> rather than an error.</summary>
    /// <param name="chosen">A strategy for this pull only; the setting's when null.</param>
    public Task<bool> PullAsync(PullStrategy? chosen = null)
    {
        var strategy = chosen ?? DefaultStrategy;
        var label = strategy == PullStrategy.Rebase ? "Pulling (rebase)…" : "Pulling…";
        return AnnounceAsync(PerformAsync(label, r => r.PullAsync(strategy), e =>
        {
            if (e is not GitException git) return false;
            if (Core.PullBlock.Parse(git.Stderr) is { } block)
            {
                _blockedStrategy = strategy;
                PullBlock = block;
                return true;
            }
            if (strategy != PullStrategy.FastForwardOnly || !git.IsDivergedPull()) return false;
            ErrorMessage = "The branch has diverged, so it can’t be fast-forwarded. Pull with merge or rebase instead.";
            return true;
        }), "Pulled");
    }

    public async Task<bool> StashAndPullAsync()
    {
        var (restored, strategy) = (false, _blockedStrategy ?? DefaultStrategy);
        if (!await PerformAsync("Stashing and pulling…", async r => restored = await r.PullWithStashAsync(strategy)))
            return false;
        if (!restored)
            ErrorMessage = "The pull finished, but your changes conflict with the new commits. "
                + "Resolve any conflicted files. Your changes are also still saved in the stash list.";
        else
            Succeeded?.Invoke("Pulled");
        return restored;
    }

    /// <summary>Fetches and reports what a force push would replace; null if that failed.</summary>
    public async Task<ForcePushPlan?> PlanForcePushAsync(string? remote)
    {
        var (status, remotes) = (Status, Remotes);
        ForcePushPlan? plan = null;
        var done = await PerformAsync("Checking the remote…",
            async r => plan = await r.PlanForcePushAsync(status, remotes, remote));
        return done ? plan : null;
    }

    /// <summary>A force push is destructive: the UI must confirm it first.</summary>
    public async Task<bool> PushAsync(PushOptions? options = null)
    {
        var (status, remotes, chosen) = (Status, Remotes, options ?? new PushOptions());
        var label = chosen.Force is not null ? "Force pushing…" : "Pushing…";
        var pushed = await AnnounceAsync(PerformAsync(label, r => r.PushAsync(status, remotes, chosen), e =>
        {
            if (e is not GitException git || !git.IsPushRejected()) return false;
            if (chosen.Force is not null)
                ErrorMessage = "The remote branch is no longer where it was when you confirmed, so the force push "
                    + "was refused. Try again to see what is new.";
            else
                RejectedPush = chosen;
            return true;
        }), "Pushed");
        // The run for what was just pushed is about to appear.
        if (pushed) WatchChecks(status.HeadOid);
        return pushed;
    }

    public Task<bool> FetchRemoteAsync(string remote) =>
        AnnounceAsync(PerformAsync($"Fetching {remote}…", r => r.FetchRemoteAsync(remote)), "Fetched");

    /// <summary>The remotes and their addresses; null when they can't be read.</summary>
    public async Task<IReadOnlyList<RemoteInfo>?> RemoteInfosAsync()
    {
        var repo = Repo;
        try
        {
            return await Task.Run(repo.RemoteInfosAsync);
        }
        catch (Exception e) when (e is GitException or IOException or UnauthorizedAccessException)
        {
            Trace.TraceWarning($"Listing remotes failed: {e.GetType().Name}");
            ErrorMessage = e.Message;
            return null;
        }
    }

    /// <summary>Both versions of an image file, for the diff view.</summary>
    public Task<(byte[]? Old, byte[]? New)> ImageVersionsAsync(DiffTarget target)
    {
        var repo = Repo;
        return Task.Run(() => repo.ImageVersionsAsync(target));
    }

    public Task<bool> AddRemoteAsync(string name, string url) =>
        PerformAsync("Adding remote…", r => r.AddRemoteAsync(name, url));

    /// <param name="url">The new address, or null to leave it as it is.</param>
    public Task<bool> EditRemoteAsync(string old, string name, string? url) =>
        PerformAsync("Updating remote…", async r =>
        {
            // The address first: if it is refused, nothing has changed.
            if (url is not null) await r.SetRemoteUrlAsync(old, url);
            if (name != old) await r.RenameRemoteAsync(old, name);
        });

    /// <summary>Destructive: the UI must confirm first.</summary>
    public Task<bool> RemoveRemoteAsync(string name) =>
        PerformAsync("Removing remote…", r => r.RemoveRemoteAsync(name));
}
