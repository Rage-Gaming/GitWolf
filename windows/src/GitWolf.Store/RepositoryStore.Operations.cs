using System.Diagnostics;
using GitWolf.Core;

namespace GitWolf.Store;

// Mutating operations. One runs at a time; each returns true only if it ran and succeeded.
public sealed partial class RepositoryStore
{
    /// <param name="handle">Returns true when it has dealt with the failure itself.</param>
    private async Task<bool> PerformAsync(
        string label, Func<GitRepository, Task> operation, Func<Exception, bool>? handle = null)
    {
        if (IsBusy) return false;
        SetBusy(true, label);
        try
        {
            var repo = Repo;
            await Task.Run(() => operation(repo));
            return true;
        }
        catch (Exception e)
        {
            if (handle?.Invoke(e) != true) ErrorMessage = e.Message;
            return false;
        }
        finally
        {
            SetBusy(false, null);
            _ = RequestRefresh();
        }
    }

    private void SetBusy(bool busy, string? label)
    {
        IsBusy = busy;
        BusyLabel = label;
        Notify(nameof(IsBusy));
        Notify(nameof(BusyLabel));
    }

    public Task<bool> ApplyHunkAsync(int index, PatchAction action) =>
        Diff is { } diff ? ApplyPatchAsync(diff, diff.ChangedLineIds(index), action) : Task.FromResult(false);

    public Task<bool> ApplySelectedLinesAsync(PatchAction action) =>
        Diff is { } diff ? ApplyPatchAsync(diff, new HashSet<int>(LineSelection), action) : Task.FromResult(false);

    /// <summary>
    /// Applies lines of a diff the user was looking at, for example after a confirmation. Refused when
    /// another file or newer changes are on screen, so line numbers can't point at something else.
    /// </summary>
    public Task<bool> ApplyShownAsync(DiffTarget target, FileDiff diff, ISet<int> ids, PatchAction action)
    {
        if (CanPatch && SelectedTarget == target && Equals(Diff, diff)) return ApplyPatchAsync(diff, ids, action);
        ErrorMessage = "The file changed, so nothing was done. Check the new changes and try again.";
        return Task.FromResult(false);
    }

    /// <summary>What a discard would lose; null when it can't be worked out.</summary>
    public async Task<DiscardSummary?> DiscardSummaryAsync(IReadOnlyList<FileChange> changes, bool untracked)
    {
        var paths = changes.Select(c => c.Path).ToList();
        var repo = Repo;
        try
        {
            return await Task.Run(() => untracked
                ? repo.DiscardSummaryAsync([], paths)
                : repo.DiscardSummaryAsync(paths, []));
        }
        catch (Exception e) when (e is GitException or IOException or UnauthorizedAccessException)
        {
            Trace.TraceWarning($"Summarising a discard failed: {e.GetType().Name}");
            return null;
        }
    }

    /// <summary>Stashes one hunk of the diff the user was looking at when they asked.</summary>
    public Task<bool> StashHunkAsync(DiffTarget target, FileDiff diff, int hunk, string message)
    {
        if (!CanStashHunk || SelectedTarget != target || !Equals(Diff, diff))
        {
            ErrorMessage = "The file changed, so nothing was done. Check the new changes and try again.";
            return Task.FromResult(false);
        }
        var ids = diff.ChangedLineIds(hunk);
        if (PatchBuilder.Make(diff, ids, PatchAction.Stage) is not { } forward
            || PatchBuilder.Make(diff, ids, PatchAction.Discard) is not { } back)
            return Task.FromResult(false);
        return PerformAsync("Stashing hunk…", r => r.StashHunkAsync(forward, back, target.Path, message));
    }

    private Task<bool> ApplyPatchAsync(FileDiff diff, ISet<int> ids, PatchAction action)
    {
        if (PatchBuilder.Make(diff, ids, action) is not { } patch) return Task.FromResult(false);
        var label = action switch
        {
            PatchAction.Stage => "Staging…",
            PatchAction.Unstage => "Unstaging…",
            _ => "Discarding…",
        };
        return PerformAsync(label, r => r.ApplyAsync(patch, action));
    }

    public Task<bool> ContinueOperationAsync() => OnOperationAsync("Continuing…", (r, o) => r.ContinueOperationAsync(o));
    public Task<bool> SkipOperationAsync() => OnOperationAsync("Skipping…", (r, o) => r.SkipOperationAsync(o));
    /// <summary>Destructive: the UI must confirm first.</summary>
    public Task<bool> AbortOperationAsync() => OnOperationAsync("Aborting…", (r, o) => r.AbortOperationAsync(o));

    private Task<bool> OnOperationAsync(string label, Func<GitRepository, InProgressOperation, Task> run) =>
        Operation is { } operation ? PerformAsync(label, r => run(r, operation)) : Task.FromResult(false);

    public Task<bool> ResolveConflictAsync(string path, string content, string expected) =>
        PerformAsync("Resolving…", r => r.ResolveConflictAsync(path, content, expected));

    public Task<bool> ResolveConflictAsync(string path, ConflictSide side) =>
        PerformAsync("Resolving…", r => r.ResolveConflictAsync(path, side));

    public Task<bool> FetchAsync() => PerformAsync("Fetching…", r => r.FetchAsync());

    /// <summary>A pull that local work is in the way of sets <see cref="PullBlock"/> rather than an error.</summary>
    public Task<bool> PullAsync()
    {
        var rebase = _settings.PullRebase;
        return PerformAsync(rebase ? "Pulling (rebase)…" : "Pulling…", r => r.PullAsync(rebase), e =>
        {
            if (e is not GitException git || Core.PullBlock.Parse(git.Stderr) is not { } block) return false;
            PullBlock = block;
            return true;
        });
    }

    public async Task<bool> StashAndPullAsync()
    {
        var (restored, rebase) = (false, _settings.PullRebase);
        if (!await PerformAsync("Stashing and pulling…", async r => restored = await r.PullWithStashAsync(rebase)))
            return false;
        if (!restored)
            ErrorMessage = "The pull finished, but your changes conflict with the new commits. "
                + "Resolve any conflicted files. Your changes are also still saved in the stash list.";
        return restored;
    }


    public Task<bool> PushAsync()
    {
        var (status, remotes) = (Status, Remotes);
        return PerformAsync("Pushing…", r => r.PushAsync(status, remotes));
    }

    public Task<bool> PushTagAsync(string name, string remote) =>
        PerformAsync("Pushing tag…", r => r.PushTagAsync(name, remote));

    public Task<bool> PushAllTagsAsync(string remote) =>
        PerformAsync("Pushing tags…", r => r.PushAllTagsAsync(remote));

    /// <summary>Destructive: the UI must confirm first.</summary>
    public Task<bool> DeleteRemoteTagAsync(string name, string remote) =>
        PerformAsync($"Deleting on {remote}…", r => r.DeleteRemoteTagAsync(name, remote));

    /// <summary>Destructive: the UI must confirm first.</summary>
    public Task<bool> DeleteRemoteBranchAsync(string remote, string branch) =>
        PerformAsync($"Deleting on {remote}…", r => r.DeleteRemoteBranchAsync(remote, branch));

    public Task<bool> StageAsync(IReadOnlyList<string> paths) => PerformAsync("Staging…", r => r.StageAsync(paths));
    public Task<bool> UnstageAsync(IReadOnlyList<string> paths) => PerformAsync("Unstaging…", r => r.UnstageAsync(paths));
    public Task<bool> StageAllAsync() => PerformAsync("Staging…", r => r.StageAllAsync());
    public Task<bool> UnstageAllAsync() => PerformAsync("Unstaging…", r => r.UnstageAllAsync());

    /// <summary>Destructive: the UI must confirm first.</summary>
    public Task<bool> DiscardAsync(IEnumerable<FileChange> changes, bool untracked)
    {
        var paths = changes.Select(c => c.Path).ToList();
        return PerformAsync("Discarding…", r => untracked ? r.DiscardAsync([], paths) : r.DiscardAsync(paths, []));
    }

    /// <summary>The draft is cleared only when the commit succeeds.</summary>
    public async Task<bool> CommitAsync(bool? sign = null, bool skipHooks = false)
    {
        var (message, amend) = (DraftMessage, Amend);
        if (!await PerformAsync("Committing…", r => r.CommitAsync(message, amend, sign, skipHooks), e =>
            {
                if (e is not HookFailedException hook) return false;
                HookFailure = new HookFailure(hook.Hook, hook.Output, sign);
                return true;
            }))
            return false;
        DraftMessage = "";
        Amend = false;
        return true;
    }

    /// <param name="untrack">A tracked path to remove from the index so the rule takes effect.</param>
    public Task<bool> IgnoreAsync(string pattern, bool local, string? untrack) =>
        PerformAsync("Ignoring…", async r =>
        {
            await r.AddIgnoreRuleAsync(pattern, local);
            if (untrack is not null) await r.StopTrackingAsync(untrack);
        });

    public Task<bool> CheckoutAsync(Branch branch) => PerformAsync("Switching…", r => r.CheckoutAsync(branch));
    public Task<bool> CheckoutCommitAsync(string hash) => PerformAsync("Checking out…", r => r.CheckoutCommitAsync(hash));

    public Task<bool> CreateBranchAsync(string name, string? from, bool checkout) =>
        PerformAsync("Creating branch…", r => r.CreateBranchAsync(name, from, checkout));

    public Task<bool> DeleteBranchAsync(string name, bool force = false) =>
        PerformAsync("Deleting…", r => r.DeleteBranchAsync(name, force));

    public Task<bool> MergeAsync(string name) => PerformAsync("Merging…", r => r.MergeAsync(name));
    public Task<bool> CherryPickAsync(string hash) => PerformAsync("Cherry-picking…", r => r.CherryPickAsync(hash));
    public Task<bool> RevertAsync(string hash) => PerformAsync("Reverting…", r => r.RevertAsync(hash));

    public Task<bool> CreateTagAsync(string name, string hash, string message = "", string? pushTo = null) =>
        PerformAsync("Tagging…", async r =>
        {
            await r.CreateTagAsync(name, hash, message);
            if (pushTo is not null) await r.PushTagAsync(name, pushTo);
        });

    public Task<bool> RenameBranchAsync(string old, string name) =>
        PerformAsync("Renaming…", r => r.RenameBranchAsync(old, name));

    public Task<bool> SetUpstreamAsync(string branch, string? upstream) =>
        PerformAsync("Updating tracking…", r => r.SetUpstreamAsync(branch, upstream));

    /// <summary>Destructive: the UI must confirm first.</summary>
    public Task<bool> DeleteBranchesAsync(IReadOnlyList<BranchCleanupItem> items) =>
        PerformAsync("Deleting branches…", async r =>
        {
            var failed = await r.DeleteBranchesAsync(items);
            if (failed.Count > 0)
                throw new GitException("branch", 1, $"Couldn’t delete: {string.Join(", ", failed)}");
        });

    public Task<bool> DeleteTagAsync(string name) => PerformAsync("Deleting tag…", r => r.DeleteTagAsync(name));
    public Task<bool> StashPushAsync(string message) => PerformAsync("Stashing…", r => r.StashPushAsync(message));
    public Task<bool> StashApplyAsync(string reference) => PerformAsync("Applying stash…", r => r.StashApplyAsync(reference));
    public Task<bool> StashPopAsync(string reference) => PerformAsync("Popping stash…", r => r.StashPopAsync(reference));
    public Task<bool> StashDropAsync(string reference) => PerformAsync("Dropping stash…", r => r.StashDropAsync(reference));
}
