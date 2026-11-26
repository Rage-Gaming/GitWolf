using GitSync.Core;

namespace GitSync.Store;

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

    public Task<bool> FetchAsync() => PerformAsync("Fetching…", r => r.FetchAsync());

    /// <summary>A pull that local work is in the way of sets <see cref="PullBlock"/> rather than an error.</summary>
    public Task<bool> PullAsync() => PerformAsync("Pulling…", r => r.PullAsync(), e =>
    {
        if (e is not GitException git || Core.PullBlock.Parse(git.Stderr) is not { } block) return false;
        PullBlock = block;
        return true;
    });

    public async Task<bool> StashAndPullAsync()
    {
        var restored = false;
        if (!await PerformAsync("Stashing and pulling…", async r => restored = await r.PullWithStashAsync()))
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
    public async Task<bool> CommitAsync()
    {
        var (message, amend) = (DraftMessage, Amend);
        if (!await PerformAsync("Committing…", r => r.CommitAsync(message, amend))) return false;
        DraftMessage = "";
        Amend = false;
        return true;
    }

    public Task<bool> CheckoutAsync(Branch branch) => PerformAsync("Switching…", r => r.CheckoutAsync(branch));
    public Task<bool> CheckoutCommitAsync(string hash) => PerformAsync("Checking out…", r => r.CheckoutCommitAsync(hash));

    public Task<bool> CreateBranchAsync(string name, string? from, bool checkout) =>
        PerformAsync("Creating branch…", r => r.CreateBranchAsync(name, from, checkout));

    public Task<bool> DeleteBranchAsync(string name, bool force = false) =>
        PerformAsync("Deleting…", r => r.DeleteBranchAsync(name, force));

    public Task<bool> MergeAsync(string name) => PerformAsync("Merging…", r => r.MergeAsync(name));
    public Task<bool> CherryPickAsync(string hash) => PerformAsync("Cherry-picking…", r => r.CherryPickAsync(hash));
    public Task<bool> RevertAsync(string hash) => PerformAsync("Reverting…", r => r.RevertAsync(hash));
    public Task<bool> CreateTagAsync(string name, string hash) => PerformAsync("Tagging…", r => r.CreateTagAsync(name, hash));
    public Task<bool> DeleteTagAsync(string name) => PerformAsync("Deleting tag…", r => r.DeleteTagAsync(name));
    public Task<bool> StashPushAsync(string message) => PerformAsync("Stashing…", r => r.StashPushAsync(message));
    public Task<bool> StashApplyAsync(string reference) => PerformAsync("Applying stash…", r => r.StashApplyAsync(reference));
    public Task<bool> StashPopAsync(string reference) => PerformAsync("Popping stash…", r => r.StashPopAsync(reference));
    public Task<bool> StashDropAsync(string reference) => PerformAsync("Dropping stash…", r => r.StashDropAsync(reference));
}
