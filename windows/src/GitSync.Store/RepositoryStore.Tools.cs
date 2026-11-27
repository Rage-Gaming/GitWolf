using System.Diagnostics;
using GitSync.Core;

namespace GitSync.Store;

// Bisect, patches, shallow clones and Git LFS. Ported from StoreScale.swift.
public sealed partial class RepositoryStore
{
    private string? _bisectProgress;

    /// <summary>The bisect session, with git's latest progress estimate.</summary>
    public BisectState Bisect { get; private set; } = BisectState.Inactive;
    /// <summary>Commits picked before a session has started.</summary>
    public string? BisectBad { get; private set; }
    public string? BisectGood { get; private set; }
    /// <summary>Changed files stored with Git LFS.</summary>
    public IReadOnlySet<string> LfsPaths { get; private set; } = new HashSet<string>();
    /// <summary>History is cut off because the clone was made with a depth limit.</summary>
    public bool IsShallow { get; private set; }

    /// <summary>Cheap checks that are not part of the snapshot. Starts git only when LFS is in use.</summary>
    private static async Task<(BisectState Bisect, IReadOnlySet<string> Lfs, bool Shallow)> ReadExtrasAsync(
        GitRepository repo, WorkingStatus status)
    {
        IReadOnlySet<string> lfs = new HashSet<string>();
        try
        {
            var attributes = Path.Combine(repo.Root, ".gitattributes");
            if (!status.IsClean && File.Exists(attributes)
                && (await File.ReadAllTextAsync(attributes)).Contains("filter=lfs", StringComparison.Ordinal))
            {
                var paths = status.Staged.Concat(status.Unstaged).Concat(status.Untracked).Concat(status.Conflicted)
                    .Select(f => f.Path).Distinct().ToList();
                lfs = await repo.LfsPathsAsync(paths);
            }
        }
        catch (Exception e) when (e is GitException or IOException or UnauthorizedAccessException)
        {
            // Only the badges are missing.
            Trace.TraceWarning($"Checking for LFS files failed: {e.GetType().Name}");
        }
        return (repo.BisectState(), lfs, repo.IsShallow());
    }

    private void ApplyExtras(BisectState bisect, IReadOnlySet<string> lfs, bool shallow)
    {
        if (!bisect.IsActive) _bisectProgress = null;
        SetBisect(bisect);
        if (!LfsPaths.SetEquals(lfs))
        {
            LfsPaths = lfs;
            Notify(nameof(LfsPaths));
        }
        if (IsShallow == shallow) return;
        IsShallow = shallow;
        Notify(nameof(IsShallow));
    }

    private void SetBisect(BisectState state)
    {
        state = state with { Progress = state.IsActive ? _bisectProgress : null };
        if (Bisect.Equals(state)) return;
        Bisect = state;
        Notify(nameof(Bisect));
    }

    /// <summary>
    /// Marks a commit. Before a session starts, remembers the bad and good picks and starts once
    /// both are known.
    /// </summary>
    public Task<bool> BisectMarkCommitAsync(BisectMark mark, string hash)
    {
        if (Bisect.IsActive) return BisectStepAsync("Bisecting…", r => r.BisectMarkAsync(mark, hash));
        if (mark == BisectMark.Skip || IsBusy) return Task.FromResult(false);
        if (mark == BisectMark.Bad) BisectBad = hash;
        else BisectGood = hash;
        if (BisectBad is not { } bad || BisectGood is not { } good)
        {
            Notify(nameof(Bisect));
            return Task.FromResult(true);
        }
        BisectBad = BisectGood = null;
        Notify(nameof(Bisect));
        return BisectStepAsync("Starting bisect…", r => r.BisectStartAsync(bad, good));
    }

    /// <summary>Marks the commit checked out for testing.</summary>
    public Task<bool> BisectMarkCurrentAsync(BisectMark mark) =>
        BisectStepAsync("Bisecting…", r => r.BisectMarkAsync(mark));

    public Task<bool> StopBisectAsync()
    {
        BisectBad = BisectGood = null;
        if (Bisect.IsActive) return PerformAsync("Ending bisect…", r => r.BisectResetAsync());
        Notify(nameof(Bisect));
        return Task.FromResult(true);
    }

    private async Task<bool> BisectStepAsync(string label, Func<GitRepository, Task<BisectState>> step)
    {
        BisectState? result = null;
        var done = await PerformAsync(label, async r => result = await step(r));
        if (!done || result is null) return false;
        _bisectProgress = result.Progress;
        SetBisect(result);
        return true;
    }

    /// <summary>Why the patches can't be applied, or null when they can.</summary>
    public async Task<string?> PatchProblemAsync(IReadOnlyList<string> files, bool mailbox)
    {
        // `git am` merges three ways, so it can succeed where a plain check fails.
        if (mailbox) return null;
        var repo = Repo;
        foreach (var file in files)
            if (await Task.Run(() => repo.CheckPatchAsync(file)) is { } problem)
                return $"“{Path.GetFileName(file)}” does not apply cleanly:\n{problem}";
        return null;
    }

    /// <summary>Applies patch files as commits, or to the working tree (and the index when staging).</summary>
    public Task<bool> ApplyPatchFilesAsync(IReadOnlyList<string> files, bool asCommits, bool stage) =>
        PerformAsync("Applying patches…", async r =>
        {
            if (asCommits) await r.ApplyMailboxAsync(files);
            else foreach (var file in files) await r.ApplyPatchFileAsync(file, stage);
        });

    public Task<bool> ExportPatchAsync(string hash, string directory) =>
        PerformAsync("Saving patch…", r => r.FormatPatchesAsync([hash], directory));

    /// <summary>Saves uncommitted changes to tracked files as a patch.</summary>
    public Task<bool> SaveWorkingPatchAsync(string file) => PerformAsync("Saving patch…", async r =>
    {
        var patch = await r.WorkingPatchAsync(stagedOnly: false);
        if (patch.Length == 0) throw new GitException("diff", 1, "There are no changes to tracked files to save.");
        await File.WriteAllBytesAsync(file, patch);
    });

    public Task<bool> UnshallowAsync() => PerformAsync("Fetching full history…", r => r.UnshallowAsync());

    /// <summary>Runs a worktree or submodule change.</summary>
    public Task<bool> ChangeCheckoutsAsync(string label, Func<GitRepository, Task> change) =>
        PerformAsync(label, change);
}
