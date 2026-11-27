using System.Collections.ObjectModel;
using System.Diagnostics;
using GitWolf.Core;
using GitWolf.Store;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace GitWolf.App.Views;

// The whitespace and whole-file options, folded lines and image previews.
public sealed partial class DiffView
{
    /// <summary>Raised with (ignore whitespace, show whole file) when the user changes either.</summary>
    internal event Action<bool, bool>? OptionsChanged;

    internal void ShowOptions(bool ignoreWhitespace, bool wholeFile)
    {
        WhitespaceButton.IsChecked = ignoreWhitespace;
        WholeFileButton.IsChecked = wholeFile;
    }

    private void OnOption(object sender, RoutedEventArgs e) =>
        OptionsChanged?.Invoke(WhitespaceButton.IsChecked == true, WholeFileButton.IsChecked == true);

    // Folded rows of the current diff. Unfolding edits these in place, so the list keeps its position.
    private ObservableCollection<DiffLine>? _lineRows;
    private ObservableCollection<SplitRow>? _splitRows;
    /// <summary>Folds opened in the diff on screen, so changing the layout keeps them open.</summary>
    private readonly HashSet<int> _unfolded = [];

    private List<DiffLine> Rows(FileDiff diff)
    {
        var rows = new List<DiffLine>();
        foreach (var line in diff.Folded())
        {
            if (line.IsFold && _unfolded.Contains(line.Id)) rows.AddRange(diff.Unfold(line));
            else rows.Add(line);
        }
        return rows;
    }

    private void Unfold(DiffLine fold)
    {
        if (_diff is not { } diff || !_unfolded.Add(fold.Id)) return;
        var lines = diff.Unfold(fold).ToList();
        if (_lineRows is { } unified && unified.IndexOf(fold) is >= 0 and var at)
        {
            unified[at] = lines[0];
            for (var i = 1; i < lines.Count; i++) unified.Insert(at + i, lines[i]);
        }
        if (_splitRows is not { } split) return;
        for (var index = 0; index < split.Count; index++)
        {
            if (!ReferenceEquals(split[index].Header, fold) && split[index].Header?.Id != fold.Id) continue;
            // Row ids only need to differ from the others; these lines have no other row.
            split[index] = new SplitRow(-(lines[0].Id + 1), null, lines[0], lines[0]);
            for (var i = 1; i < lines.Count; i++)
                split.Insert(index + i, new SplitRow(-(lines[i].Id + 1), null, lines[i], lines[i]));
            return;
        }
    }

    private FileDiff? _imageDiff;

    /// <summary>Shows both versions in place of the text when the file is a binary image.</summary>
    private bool ShowImages(RepositoryStore store, FileDiff? diff)
    {
        var wanted = diff is { IsBinary: true } && store.SelectedTarget is { } selected
            && GitRepository.IsImagePath(selected.Path);
        Images.Visibility = wanted ? Visibility.Visible : Visibility.Collapsed;
        if (!wanted)
        {
            _imageDiff = null;
            Images.Clear();
        }
        else if (!ReferenceEquals(_imageDiff, diff))
        {
            _imageDiff = diff;
            Images.Clear();
            _ = LoadImagesAsync(store, store.SelectedTarget!.Value, diff!);
        }
        return wanted;
    }

    private async Task LoadImagesAsync(RepositoryStore store, DiffTarget target, FileDiff diff)
    {
        try
        {
            var (old, @new) = await store.ImageVersionsAsync(target);
            if (ReferenceEquals(_imageDiff, diff))
                await Images.ShowAsync(old, @new, () => ReferenceEquals(_imageDiff, diff));
        }
        catch (Exception e)
        {
            // A preview is optional; the header still names the file.
            Trace.TraceWarning($"Loading an image preview failed: {e.GetType().Name}");
            if (ReferenceEquals(_imageDiff, diff)) Empty.Text = "Binary file";
        }
    }
}
