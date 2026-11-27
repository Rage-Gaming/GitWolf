using System.Diagnostics;
using GitSync.Core;

namespace GitSync.Store;

public sealed partial class RepositoryStore
{
    private StoreMode _mode = StoreMode.History;
    public StoreMode Mode
    {
        get => _mode;
        set
        {
            if (_mode == value) return;
            _mode = value;
            ClearSelection();
            Notify(nameof(Mode));
            Notify(nameof(CanPatch));
        }
    }

    public string? SelectedCommitId { get; private set; }
    public DiffTarget? SelectedTarget { get; private set; }
    public IReadOnlyList<FileChange> CommitFiles { get; private set; } = [];
    public string CommitMessage { get; private set; } = "";
    public FileDiff? Diff { get; private set; }
    public IReadOnlySet<int> LineSelection { get; private set; } = new HashSet<int>();

    public Commit? SelectedCommit => Commits.FirstOrDefault(c => c.Id == SelectedCommitId)
        ?? SearchResults?.FirstOrDefault(c => c.Id == SelectedCommitId);

    /// <summary>The latest diff / commit-detail load, so callers can await it.</summary>
    public Task PendingLoad { get; private set; } = Task.CompletedTask;

    private void ClearSelection()
    {
        _diffToken++;
        _commitToken++;
        ClearLineSelection();
        SetSelectedTarget(null);
        SetSelectedCommit(null);
        SetDiff(null);
        SetCommitDetails([], "");
        ClearStash();
    }

    /// <summary>
    /// Keeps selection valid after the repository changes underneath it. A file that moved between
    /// areas (e.g. just staged) is followed rather than dropped.
    /// </summary>
    private void ReconcileSelection()
    {
        if (Mode == StoreMode.History)
        {
            // Commits are immutable; only drop a selection that disappeared.
            if (SelectedCommitId is not null && SelectedCommit is null) ClearSelection();
            return;
        }
        // A comparison is between fixed commits, so its selection stays valid.
        if (Mode == StoreMode.Compare) return;
        if (Mode == StoreMode.Stash)
        {
            ReconcileStash();
            return;
        }

        if (SelectedTarget is not { } target) return;
        (DiffSource Source, IReadOnlyList<FileChange> Files)[] areas =
        [
            (DiffSource.Staged, Status.Staged), (DiffSource.Unstaged, Status.Unstaged),
            (DiffSource.Untracked, Status.Untracked), (DiffSource.Conflicted, Status.Conflicted),
        ];

        if (areas.Any(a => a.Source == target.Source && a.Files.Any(f => f.Path == target.Path)))
        {
            PendingLoad = LoadDiffAsync(target);
            return;
        }
        foreach (var (source, files) in areas)
        {
            if (files.FirstOrDefault(f => f.Path == target.Path) is { } change)
            {
                SelectChange(change, source);
                return;
            }
        }
        _diffToken++;
        SetSelectedTarget(null);
        SetDiff(null);
    }

    public void SelectCommit(string? id)
    {
        if (id == SelectedCommitId) return;
        _diffToken++;
        _commitToken++;
        SetSelectedCommit(id);
        SetSelectedTarget(null);
        SetDiff(null);
        SetCommitDetails([], "");
        if (Commits.FirstOrDefault(c => c.Id == id) is { } commit)
            PendingLoad = LoadCommitAsync(commit, _commitToken);
    }

    private async Task LoadCommitAsync(Commit commit, int token)
    {
        var repo = Repo;
        var filesTask = Task.Run(() => repo.FilesAsync(commit));
        var messageTask = Task.Run(() => repo.MessageAsync(commit.Hash));

        IReadOnlyList<FileChange> files = [];
        var message = commit.Subject;
        try { files = await filesTask; }
        catch (Exception e) { Trace.TraceWarning($"Loading commit files failed: {e.GetType().Name}"); }
        try { message = await messageTask; }
        catch (Exception e) { Trace.TraceWarning($"Loading commit message failed: {e.GetType().Name}"); }

        if (token != _commitToken) return;
        SetCommitDetails(files, message);
        if (files.Count > 0)
        {
            SelectChange(files[0], DiffSource.ForCommit(commit.Hash));
            await PendingLoad;
        }
    }

    public void Reveal(string hash)
    {
        Mode = StoreMode.History;
        SelectCommit(hash);
    }

    public void SelectChange(FileChange change, DiffSource source) =>
        SelectTarget(new DiffTarget(source, change.Path, change.OriginalPath));

    public void SelectTarget(DiffTarget? target)
    {
        if (target == SelectedTarget) return;
        ClearLineSelection();
        SetSelectedTarget(target);
        if (target is { } t)
        {
            PendingLoad = LoadDiffAsync(t);
        }
        else
        {
            _diffToken++;
            SetDiff(null);
        }
    }

    private void ReloadDiff()
    {
        if (SelectedTarget is { } target) PendingLoad = LoadDiffAsync(target);
    }

    private async Task LoadDiffAsync(DiffTarget target)
    {
        var token = ++_diffToken;
        var repo = Repo;
        FileDiff result;
        try
        {
            result = await Task.Run(() => repo.DiffAsync(target));
        }
        catch (Exception e)
        {
            Trace.TraceWarning($"Loading diff failed: {e.GetType().Name}");
            result = FileDiff.Empty;
        }
        if (token != _diffToken || Equals(Diff, result)) return;
        ClearLineSelection();
        SetDiff(result);
    }

    private async Task LoadHeadMessageAsync()
    {
        try
        {
            var repo = Repo;
            var message = await Task.Run(repo.HeadMessageAsync);
            if (Amend && DraftMessage.Length == 0) DraftMessage = message;
        }
        catch (GitException)
        {
            // No commit yet: there is no message to prefill.
        }
    }

    // MARK: Hunk & line staging

    /// <summary>
    /// Hunk/line operations are offered for plain staged or unstaged text diffs only (not renames,
    /// binaries, truncated or non-UTF-8 diffs, which can't be patched safely).
    /// </summary>
    public bool CanPatch =>
        Mode == StoreMode.Changes && SelectedTarget is { OriginalPath: null } target && Diff?.CanPatch == true
        && (target.Source == DiffSource.Staged || target.Source == DiffSource.Unstaged);

    public void ClearLineSelection()
    {
        _selectionAnchor = null;
        if (LineSelection.Count > 0) SetLineSelection([]);
    }

    /// <summary>Toggles a changed line; with <paramref name="extend"/> selects every changed line from the anchor.</summary>
    public void ToggleLine(int id, bool extend)
    {
        if (Diff is not { } diff || id < 0 || id >= diff.Lines.Count || !diff.Lines[id].IsChange) return;
        var selection = new HashSet<int>(LineSelection);
        if (extend && _selectionAnchor is { } anchor && anchor < diff.Lines.Count)
        {
            for (var i = Math.Min(anchor, id); i <= Math.Max(anchor, id); i++)
                if (diff.Lines[i].IsChange) selection.Add(i);
        }
        else
        {
            if (!selection.Remove(id)) selection.Add(id);
            _selectionAnchor = id;
        }
        SetLineSelection(selection);
    }

    /// <summary>A hunk can be stashed when the file has unstaged changes only.</summary>
    public bool CanStashHunk =>
        CanPatch && SelectedTarget is { } target && target.Source == DiffSource.Unstaged
        && !Status.Staged.Any(f => f.Path == target.Path);

    // MARK: Notifying setters

    private void SetSelectedCommit(string? id)
    {
        if (SelectedCommitId == id) return;
        SelectedCommitId = id;
        Notify(nameof(SelectedCommitId));
        Notify(nameof(SelectedCommit));
    }

    private void SetSelectedTarget(DiffTarget? target)
    {
        if (SelectedTarget == target) return;
        SelectedTarget = target;
        Notify(nameof(SelectedTarget));
        Notify(nameof(CanPatch));
    }

    private void SetDiff(FileDiff? diff)
    {
        if (Equals(Diff, diff)) return;
        Diff = diff;
        Notify(nameof(Diff));
        Notify(nameof(CanPatch));
    }

    private void SetCommitDetails(IReadOnlyList<FileChange> files, string message)
    {
        if (!CommitFiles.SequenceEqual(files))
        {
            CommitFiles = files;
            Notify(nameof(CommitFiles));
        }
        if (CommitMessage != message)
        {
            CommitMessage = message;
            Notify(nameof(CommitMessage));
        }
    }

    private void SetLineSelection(HashSet<int> selection)
    {
        LineSelection = selection;
        Notify(nameof(LineSelection));
    }
}
