using GitSync.App.Services;
using GitSync.Core;
using GitSync.Store;
using Microsoft.UI.Xaml;

namespace GitSync.App.Views;

// Hunk and line staging. Ported from DiffView.swift.
public sealed partial class DiffView
{
    private DiffStaging? Staging(RepositoryStore store) =>
        store.SelectedTarget is { } target
            ? new DiffStaging(target.Source == DiffSource.Staged, store.LineSelection, store.ToggleLine, ApplyHunk,
                store.CanStashHunk ? StashHunk : null)
            : null;

    private void ApplyHunk(int index, PatchAction action)
    {
        if (_store is not { Diff: { } diff } store) return;
        if (action == PatchAction.Discard) _ = DiscardShownAsync(diff.ChangedLineIds(index), "this hunk");
        else _ = store.ApplyHunkAsync(index, action);
    }

    private void StashHunk(int index)
    {
        if (_store is { SelectedTarget: { } target, Diff: { } diff } store)
            _ = BranchDialogs.StashHunkAsync(XamlRoot, store, target, diff, index);
    }

    private void ShowSelectionBar()
    {
        var count = _staging?.Selection.Count ?? 0;
        SelectionBar.Visibility = count > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (_staging is not { } staging || count == 0) return;
        SelectionText.Text = count == 1 ? "1 line selected" : $"{count} lines selected";
        ApplyLines.Content = staging.Staged ? "Unstage Lines" : "Stage Lines";
        DiscardLines.Visibility = staging.Staged ? Visibility.Collapsed : Visibility.Visible;
    }

    private void OnApplyLines(object sender, RoutedEventArgs e)
    {
        if (_staging is { } staging)
            _ = _store?.ApplySelectedLinesAsync(staging.Staged ? PatchAction.Unstage : PatchAction.Stage);
    }

    private void OnDiscardLines(object sender, RoutedEventArgs e)
    {
        if (_staging is not { Selection.Count: > 0 } staging) return;
        var count = staging.Selection.Count;
        _ = DiscardShownAsync(new HashSet<int>(staging.Selection),
            count == 1 ? "1 selected line" : $"{count} selected lines");
    }

    private void OnClearLines(object sender, RoutedEventArgs e) => _store?.ClearLineSelection();

    /// <summary>Discards lines of the diff on screen once the user agrees.</summary>
    private async Task DiscardShownAsync(HashSet<int> ids, string what)
    {
        if (_store is not { SelectedTarget: { } target, Diff: { } diff } store || ids.Count == 0) return;
        var lines = diff.Lines.Where(l => ids.Contains(l.Id)).ToList();
        var size = $"+{lines.Count(l => l.Kind == DiffLineKind.Addition)} "
            + $"−{lines.Count(l => l.Kind == DiffLineKind.Deletion)}";
        if (await Dialogs.ConfirmAsync(XamlRoot, $"Discard {what} ({size})?",
                "These changes will be removed from your working tree and can’t be recovered.", "Discard")
            && ReferenceEquals(store, _store))
            await store.ApplyShownAsync(target, diff, ids, PatchAction.Discard);
    }
}
