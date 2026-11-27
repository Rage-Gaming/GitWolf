using System.Text;

namespace GitWolf.Core;

// Pulling, and setting local work aside to do it.
public sealed partial class GitRepository
{
    public Task PullAsync() => PullAsync(rebase: false);

    /// <summary>Fetches and integrates the upstream branch, by merging or by rebasing.</summary>
    public async Task PullAsync(bool rebase)
    {
        var net = await NetworkGitAsync();
        if (rebase)
        {
            var already = InProgressOperation() is not null;
            try
            {
                await net.RunAsync(["pull", "--rebase", "--autostash", "--no-edit"]);
            }
            catch (GitException) when (!already && InProgressOperation() is not null)
            {
                // Stopped on a conflict: not a failure, the operation banner takes over.
            }
            return;
        }
        try
        {
            await net.RunAsync(["pull", "--no-edit"]);
        }
        catch (GitException error) when (error.Stderr.Contains("divergent branches"))
        {
            await net.RunAsync(["pull", "--no-edit", "--no-rebase"]);
        }
    }

    public Task<bool> PullWithStashAsync() => PullWithStashAsync(rebase: false);

    /// <summary>
    /// Stashes local work (untracked files too), pulls, then puts the work back. The work is put
    /// back when the pull fails as well. False means it couldn't be restored cleanly, in which case
    /// git keeps the stash.
    /// </summary>
    public async Task<bool> PullWithStashAsync(bool rebase)
    {
        var before = await StashHashesAsync();
        await StashPushAsync("Changes set aside to pull");
        // Git succeeds without creating a stash when there is nothing it can save.
        var mine = (await StashHashesAsync()).Except(before).FirstOrDefault();
        try
        {
            await PullAsync(rebase);
        }
        catch (Exception pullError)
        {
            if (mine is not null && !await RestoreStashAsync(mine))
                throw new InvalidOperationException(
                    $"{pullError.Message}\n\nYour changes are saved in the stash list.", pullError);
            throw;
        }
        return mine is null || await RestoreStashAsync(mine);
    }

    private async Task<List<string>> StashHashesAsync() =>
        (await Git.RunStringAsync(["stash", "list", "--format=%H"], readOnly: true))
            .Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToList();

    private async Task<bool> RestoreStashAsync(string hash)
    {
        // Looked up again: other stashes may have been added since, shifting the numbers.
        var index = (await StashHashesAsync()).IndexOf(hash);
        if (index < 0) return false;
        var reference = $"stash@{{{index}}}";
        try
        {
            // --index also restores what was staged.
            await Git.RunAsync(["stash", "pop", "--index", reference]);
            return true;
        }
        catch (GitException)
        {
            // The staged state may no longer apply to the new files; the contents still might.
        }
        var unmerged = await Git.RunAsync(["diff", "--name-only", "--diff-filter=U"], readOnly: true);
        if (unmerged.Length > 0) return false;
        try
        {
            await Git.RunAsync(["stash", "pop", reference]);
            return true;
        }
        catch (GitException)
        {
            return false;
        }
    }
}
