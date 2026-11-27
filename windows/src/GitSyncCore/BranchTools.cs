namespace GitSync.Core;

public enum CleanupReason { Merged, UpstreamGone }

/// <summary>A local branch that is probably safe to delete, and why. Ported from BranchTools.swift.</summary>
/// <param name="IsMerged">Merged into the base, so a normal delete succeeds. Otherwise deleting loses commits.</param>
/// <param name="Hash">The tip when listed; a branch that has moved since is not deleted.</param>
public sealed record BranchCleanupItem(string Name, CleanupReason Reason, bool IsMerged, string Hash);

public sealed partial class GitRepository
{
    private const string LocalPrefix = "refs/heads/";

    /// <summary>Branch names that cleanup never offers.</summary>
    private static readonly HashSet<string> ProtectedBranches =
        ["main", "master", "develop", "dev", "trunk", "release"];

    public async Task RenameBranchAsync(string old, string name)
    {
        name = name.Trim();
        try
        {
            // The full ref form, because --branch would expand shorthand such as "@{-1}".
            await Git.RunAsync(["check-ref-format", LocalPrefix + Operand(name)], readOnly: true);
        }
        catch (GitException e)
        {
            throw new GitException("branch", e.ExitCode, $"“{name}” isn’t a valid branch name.");
        }
        await Git.RunAsync(["branch", "-m", Operand(old), name]);
    }

    /// <summary>Tracks <paramref name="upstream"/> (e.g. `origin/main`); null stops tracking.</summary>
    public Task SetUpstreamAsync(string branch, string? upstream) =>
        Git.RunAsync(upstream is null
            ? ["branch", "--unset-upstream", Operand(branch)]
            : ["branch", $"--set-upstream-to={upstream}", Operand(branch)]);

    /// <summary>Local branches that are merged into <paramref name="baseRef"/> or whose remote branch is gone.</summary>
    public async Task<List<BranchCleanupItem>> CleanupCandidatesAsync(string baseRef)
    {
        var branches = await BranchesAsync();
        var output = await Git.RunStringAsync(
            ["branch", "--merged", Operand(baseRef), "--format=%(refname)"], readOnly: true);
        var merged = output.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .ToHashSet(StringComparer.Ordinal);
        var items = new List<BranchCleanupItem>();
        foreach (var branch in branches.Local)
        {
            // From the full ref: the short name gains "heads/" when a tag has the same name.
            var name = branch.FullRef[LocalPrefix.Length..];
            if (branch.IsCurrent || name == baseRef || ProtectedBranches.Contains(name)) continue;
            var isMerged = merged.Contains(branch.FullRef);
            if (!branch.UpstreamGone && !isMerged) continue;
            var reason = branch.UpstreamGone ? CleanupReason.UpstreamGone : CleanupReason.Merged;
            items.Add(new BranchCleanupItem(name, reason, isMerged, branch.Hash));
        }
        return items;
    }

    /// <summary>
    /// Deletes each branch, forcing only the ones that aren't merged. Returns the names that were
    /// not deleted, including any that gained commits since they were listed. Destructive.
    /// </summary>
    public async Task<List<string>> DeleteBranchesAsync(IReadOnlyList<BranchCleanupItem> items)
    {
        var failed = new List<string>();
        foreach (var item in items)
        {
            try
            {
                var tip = (await Git.RunStringAsync(
                    ["rev-parse", "--verify", LocalPrefix + item.Name], readOnly: true)).Trim();
                if (tip != item.Hash) failed.Add(item.Name);
                else await DeleteBranchAsync(item.Name, force: !item.IsMerged);
            }
            catch (GitException)
            {
                // E.g. checked out in another worktree. The caller names what is left.
                failed.Add(item.Name);
            }
        }
        return failed;
    }
}
