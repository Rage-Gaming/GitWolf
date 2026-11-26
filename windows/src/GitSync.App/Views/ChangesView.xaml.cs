using System.Collections.ObjectModel;
using GitSync.App.Services;
using GitSync.Core;
using GitSync.Store;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

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

    private void OnContext(UIElement sender, ContextRequestedEventArgs e)
    {
        var element = e.OriginalSource as DependencyObject;
        while (element is not null and not ListViewItem) element = VisualTreeHelper.GetParent(element);
        if (_store is not { } store || element is not ListViewItem item
            || Files.ItemFromContainer(item) is not FileRow { File: { } file } row) return;

        var menu = new MenuFlyout();
        void Add(string text, Action action)
        {
            var entry = new MenuFlyoutItem { Text = text, IsEnabled = !store.IsBusy };
            entry.Click += (_, _) => action();
            menu.Items.Add(entry);
        }
        var staged = row.Source == DiffSource.Staged;
        // A staged rename must unstage both of its paths.
        string[] paths = file.OriginalPath is { } from && staged ? [from, file.Path] : [file.Path];
        if (staged) Add("Unstage", () => _ = store.UnstageAsync(paths));
        else Add("Stage", () => _ = store.StageAsync(paths));
        var untracked = row.Source == DiffSource.Untracked;
        if (untracked || row.Source == DiffSource.Unstaged)
            Add("Discard changes\u2026", () => _ = DiscardAsync(store, file, untracked));
        Add("Copy path", () => Dialogs.Copy(file.Path));

        e.Handled = true;
        if (e.TryGetPosition(item, out var point)) menu.ShowAt(item, point);
        else menu.ShowAt(item);
    }

    /// <summary>Asks first, saying how much is lost.</summary>
    private async Task DiscardAsync(RepositoryStore store, FileChange file, bool untracked)
    {
        var summary = await store.DiscardSummaryAsync([file], untracked);
        var confirmed = await Dialogs.ConfirmAsync(XamlRoot, $"Discard changes to \u201C{file.FileName}\u201D?",
            summary?.Sentence ?? "This can\u2019t be undone.", "Discard");
        // Still the same repository, and the file still has the kind of change that was described.
        var current = untracked ? store.Status.Untracked : store.Status.Unstaged;
        if (confirmed && ReferenceEquals(store, _store) && current.Any(f => f.Path == file.Path))
            await store.DiscardAsync([file], untracked);
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
