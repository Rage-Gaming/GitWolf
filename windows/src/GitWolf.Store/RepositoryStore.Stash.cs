using System.Diagnostics;
using GitWolf.Core;

namespace GitWolf.Store;

// Previewing a stash.
public sealed partial class RepositoryStore
{
    private int _stashToken;

    public Stash? SelectedStash { get; private set; }
    public StashContents? StashContents { get; private set; }
    public string? StashError { get; private set; }

    /// <summary>Shows what a stash holds, without touching the working tree.</summary>
    public Task SelectStashAsync(Stash stash)
    {
        Mode = StoreMode.Stash;
        if (stash == SelectedStash) return PendingLoad;
        SetPending(true, false);
        SelectTarget(null);
        var token = ++_stashToken;
        SetStash(stash, null, null);
        return PendingLoad = LoadStashAsync(stash, token);
    }

    private async Task LoadStashAsync(Stash stash, int token)
    {
        var repo = Repo;
        StashContents contents;
        try
        {
            contents = await Task.Run(() => repo.StashContentsAsync(stash.Ref));
        }
        catch (Exception e) when (e is GitException or IOException or UnauthorizedAccessException)
        {
            Trace.TraceWarning($"Reading a stash failed: {e.GetType().Name}");
            if (token != _stashToken) return;
            SetStash(stash, null, e.Message);
            SetPending(false, _diffPending);
            return;
        }
        if (token != _stashToken) return;
        SetStash(stash, contents, null);
        var loading = true;
        if (contents.Files.Count > 0) SelectChange(contents.Files[0], contents.Source);
        else if (contents.UntrackedSource is DiffSource untracked && contents.UntrackedFiles.Count > 0)
            SelectChange(contents.UntrackedFiles[0], untracked);
        else loading = false;
        SetPending(false, _diffPending);
        // SelectChange started the diff load, which replaced PendingLoad.
        if (loading) await PendingLoad;
    }

    /// <summary>Stash numbers shift as entries come and go, so the selection follows the entry itself.</summary>
    private void ReconcileStash()
    {
        if (SelectedStash is not { } selected || Stashes.Contains(selected)) return;
        if (Stashes.FirstOrDefault(s => s.Date == selected.Date && s.Message == selected.Message) is { } moved)
        {
            SelectedStash = null;
            _ = SelectStashAsync(moved);
            return;
        }
        SelectTarget(null);
        ClearStash();
        SetPending(false, _diffPending);
    }

    private void ClearStash()
    {
        _stashToken++;
        SetStash(null, null, null);
    }

    private void SetStash(Stash? stash, StashContents? contents, string? error)
    {
        if (SelectedStash == stash && ReferenceEquals(StashContents, contents) && StashError == error) return;
        SelectedStash = stash;
        StashContents = contents;
        StashError = error;
        Notify(nameof(SelectedStash));
    }
}
