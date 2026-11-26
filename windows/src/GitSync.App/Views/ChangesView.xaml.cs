using System.Collections.ObjectModel;
using GitSync.Core;
using GitSync.Store;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace GitSync.App.Views;

public sealed partial class ChangesView : UserControl
{
    private readonly ObservableCollection<FileRow> _rows = [];
    private RepositoryStore? _store;
    /// <summary>Set while the view mirrors the store, so selection events aren't read as user input.</summary>
    private bool _syncing;

    public ChangesView()
    {
        InitializeComponent();
        Files.ItemsSource = _rows;
    }

    internal void Attach(RepositoryStore store)
    {
        _store = store;
        _syncing = true;
        _rows.Clear();
        _syncing = false;
        ShowFiles();
        ShowDraft();
    }

    internal void ShowFiles()
    {
        if (_store is not { } store) return;
        var rows = new List<FileRow>();
        void Section(string title, DiffSource source, IReadOnlyList<FileChange> files)
        {
            if (files.Count == 0) return;
            rows.Add(new FileRow(null, source, $"{title} ({files.Count})"));
            rows.AddRange(files.Select(f => new FileRow(f, source)));
        }
        var status = store.Status;
        Section("CONFLICTS", DiffSource.Conflicted, status.Conflicted);
        Section("STAGED", DiffSource.Staged, status.Staged);
        Section("CHANGES", DiffSource.Unstaged, status.Unstaged);
        Section("UNTRACKED", DiffSource.Untracked, status.Untracked);

        _syncing = true;
        // Headers are keyed by section only, so a changed count updates the row in place.
        ListSync.Apply(_rows, rows, r => (r.Source.Kind, r.File?.Path ?? ""));
        _syncing = false;
        Clean.Visibility = store.IsLoaded && status.IsClean ? Visibility.Visible : Visibility.Collapsed;
        ShowSelection();
        ShowCommitState();
    }

    internal void ShowSelection()
    {
        if (_store is not { } store) return;
        _syncing = true;
        Files.SelectedItem = store.SelectedTarget is { } target
            ? _rows.FirstOrDefault(r => r.File?.Path == target.Path && r.Source == target.Source)
            : null;
        _syncing = false;
    }

    internal void ShowDraft()
    {
        if (_store is not { } store) return;
        if (Normalize(Message.Text) != store.DraftMessage) Message.Text = store.DraftMessage;
        Amend.IsChecked = store.Amend;
        ShowCommitState();
    }

    internal void ShowCommitState()
    {
        if (_store is not { } store) return;
        var hasMessage = !string.IsNullOrWhiteSpace(store.DraftMessage);
        CommitButton.IsEnabled = !store.IsBusy && store.Status.Conflicted.Count == 0
            && (store.Amend || (hasMessage && store.Status.Staged.Count > 0));
    }

    /// <summary>TextBox uses '\r' for line breaks; git must receive '\n'.</summary>
    private static string Normalize(string text) => text.Replace("\r\n", "\n").Replace('\r', '\n');

    private void OnSelected(object sender, SelectionChangedEventArgs e)
    {
        if (_syncing) return;
        if (Files.SelectedItem is FileRow { File: { } file } row) _store?.SelectChange(file, row.Source);
        else ShowSelection(); // Headers aren't selectable.
    }

    private void OnRow(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (args.InRecycleQueue || args.ItemContainer.ContentTemplateRoot is not FileRowView view
            || args.Item is not FileRow row || _store is not { } store) return;

        var staged = row.Source == DiffSource.Staged;
        if (row.File is { } file)
        {
            // A staged rename must unstage both of its paths.
            string[] paths = file.OriginalPath is { } from && staged ? [from, file.Path] : [file.Path];
            view.Show(row, staged ? "Unstage" : "Stage",
                () => _ = staged ? store.UnstageAsync(paths) : store.StageAsync(paths));
        }
        else if (row.Source == DiffSource.Conflicted)
        {
            view.Show(row, null, null);
        }
        else if (staged)
        {
            view.Show(row, "Unstage all", () => _ = store.UnstageAllAsync());
        }
        else
        {
            var source = row.Source;
            view.Show(row, "Stage all", () => _ = store.StageAsync(
                (source == DiffSource.Untracked ? store.Status.Untracked : store.Status.Unstaged)
                    .Select(f => f.Path).ToList()));
        }
    }

    private void OnMessageChanged(object sender, TextChangedEventArgs e)
    {
        if (_store is not { } store) return;
        store.DraftMessage = Normalize(Message.Text);
    }

    private void OnAmend(object sender, RoutedEventArgs e)
    {
        if (_store is { } store) store.Amend = Amend.IsChecked == true;
    }

    private void OnCommit(object sender, RoutedEventArgs e) => _ = _store?.CommitAsync();
}
