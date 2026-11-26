using System.Collections.ObjectModel;
using GitSync.App.Services;
using GitSync.Store;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace GitSync.App.Views;

public sealed partial class HistoryView : UserControl
{
    private readonly ObservableCollection<CommitRow> _commits = [];
    private RepositoryStore? _store;
    /// <summary>Set while the view mirrors the store, so selection events aren't read as user input.</summary>
    private bool _syncing;

    public HistoryView()
    {
        InitializeComponent();
        Commits.ItemsSource = _commits;
    }

    internal void Attach(RepositoryStore store)
    {
        _store = store;
        _syncing = true;
        _commits.Clear();
        _syncing = false;
        Search.Text = "";
        ShowCommits();
    }

    internal void ShowCommits()
    {
        if (_store is not { } store) return;
        var count = Math.Min(store.Commits.Count, store.Graph.Count);
        var lanes = store.GraphLaneCount;
        var rows = new List<CommitRow>(count);
        var query = Search.Text.Trim();
        for (var i = 0; i < count; i++)
        {
            var commit = store.Commits[i];
            if (query.Length == 0) rows.Add(new CommitRow(commit, store.Graph[i], lanes));
            // Lanes mean nothing once rows are skipped, so the graph is hidden while filtering.
            else if (commit.Subject.Contains(query, StringComparison.CurrentCultureIgnoreCase)
                || commit.AuthorName.Contains(query, StringComparison.CurrentCultureIgnoreCase)
                || commit.Hash.StartsWith(query, StringComparison.OrdinalIgnoreCase))
                rows.Add(new CommitRow(commit, store.Graph[i], 0));
        }

        _syncing = true;
        ListSync.Apply(_commits, rows, r => r.Commit.Hash);
        _syncing = false;
        Empty.Text = query.Length == 0 ? "No commits yet" : "No matching commits";
        Empty.Visibility = store.IsLoaded && rows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        ShowSelection();
    }

    internal void ShowSelection()
    {
        if (_store is not { } store) return;
        _syncing = true;
        Commits.SelectedItem = _commits.FirstOrDefault(r => r.Commit.Hash == store.SelectedCommitId);
        _syncing = false;
    }

    private void OnSearch(object sender, TextChangedEventArgs e) => ShowCommits();

    private void OnContext(UIElement sender, ContextRequestedEventArgs e)
    {
        var element = e.OriginalSource as DependencyObject;
        while (element is not null and not ListViewItem) element = VisualTreeHelper.GetParent(element);
        if (_store is not { } store || element is not ListViewItem item
            || Commits.ItemFromContainer(item) is not CommitRow { Commit: var commit }) return;

        var menu = new MenuFlyout();
        void Add(string text, Action action)
        {
            var entry = new MenuFlyoutItem { Text = text };
            entry.Click += (_, _) => action();
            menu.Items.Add(entry);
        }
        Add("Check out commit", () => _ = store.CheckoutCommitAsync(commit.Hash));
        Add("New branch here\u2026", () => _ = Dialogs.NewBranchAsync(XamlRoot, store, commit.Hash));
        Add("New tag\u2026", () => _ = Dialogs.NewTagAsync(XamlRoot, store, commit.Hash));
        menu.Items.Add(new MenuFlyoutSeparator());
        Add("Cherry-pick", () => _ = store.CherryPickAsync(commit.Hash));
        Add("Revert", () => _ = store.RevertAsync(commit.Hash));
        menu.Items.Add(new MenuFlyoutSeparator());
        if (store.WebLinks is not null)
            Add($"Open on {store.ProviderTitle ?? "the web"}", () => store.OpenOnWeb(new WebTarget.Commit(commit.Hash)));
        Add("Copy hash", () => Dialogs.Copy(commit.Hash));

        e.Handled = true;
        if (e.TryGetPosition(item, out var point)) menu.ShowAt(item, point);
        else menu.ShowAt(item);
    }

    private void OnCommitSelected(object sender, SelectionChangedEventArgs e)
    {
        if (!_syncing && Commits.SelectedItem is CommitRow row) _store?.SelectCommit(row.Commit.Hash);
    }

    private void OnCommitRow(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (args.InRecycleQueue || args.ItemContainer.ContentTemplateRoot is not CommitRowView view
            || args.Item is not CommitRow row) return;
        view.Show(row);
        // Near the end: fetch the next page of history.
        if (Search.Text.Length == 0 && args.ItemIndex >= _commits.Count - 20) DispatcherQueue.TryEnqueue(() => _store?.LoadMoreCommits());
    }
}
