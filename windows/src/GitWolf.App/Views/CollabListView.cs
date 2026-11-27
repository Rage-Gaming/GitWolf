using GitWolf.App.Services;
using GitWolf.Core;
using GitWolf.Store;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace GitWolf.App.Views;

/// <summary>The list of pull requests or issues. Ported from CollabViews.swift.</summary>
public sealed class CollabListView : UserControl
{
    private readonly TextBlock _title = Ui.Text("", 15, bold: true);
    private readonly ComboBox _filter = new() { MinWidth = 96, FontSize = 12 };
    private readonly TextBox _search = new() { PlaceholderText = "Search title, author, label or #number" };
    private readonly ListView _list = new() { SelectionMode = ListViewSelectionMode.Single, Padding = new Thickness(6) };
    private readonly StackPanel _status = new() { Spacing = 8, Margin = new Thickness(18), HorizontalAlignment = HorizontalAlignment.Center };
    private readonly ProgressBar _loading = new() { IsIndeterminate = true };
    private readonly Button _more;
    private readonly Button _create;
    private RepositoryStore? _store;
    private CollabStore? _collab;
    private IReadOnlyList<CollabItem> _shown = [];
    private bool _syncing;

    public CollabListView()
    {
        foreach (var filter in Enum.GetValues<CollabFilter>()) _filter.Items.Add(filter.ToString());
        AutomationProperties.SetName(_filter, "Filter");
        AutomationProperties.SetName(_search, "Search");
        AutomationProperties.SetName(_list, "Items");
        _filter.SelectionChanged += (_, _) =>
        {
            if (!_syncing && _collab is { } c && _filter.SelectedIndex >= 0) c.Filter = (CollabFilter)_filter.SelectedIndex;
        };
        _search.TextChanged += (_, _) => { if (!_syncing && _collab is { } c) c.Query = _search.Text; };
        _list.SelectionChanged += (_, _) =>
        {
            if (!_syncing && _list.SelectedItem is FrameworkElement { Tag: int number }) _collab?.Select(number);
        };
        _more = Ui.Button("Load more", () => _ = _collab?.LoadMoreAsync());
        _more.HorizontalAlignment = HorizontalAlignment.Center;
        _create = Ui.Button("New…", () =>
        {
            if (_store is { } s && _collab is { } c) _ = ProviderDialogs.NewCollabAsync(XamlRoot, s, c.Kind);
        });
        var reload = Ui.Button(new FontIcon { Glyph = "", FontSize = 12 }, () => _ = _collab?.LoadAsync(), "Reload");

        var header = new Grid
        {
            ColumnSpacing = 8,
            ColumnDefinitions =
            {
                new ColumnDefinition(), new ColumnDefinition { Width = GridLength.Auto },
                new ColumnDefinition { Width = GridLength.Auto }, new ColumnDefinition { Width = GridLength.Auto },
            },
        };
        UIElement[] items = [_title, _filter, reload, _create];
        for (var i = 0; i < items.Length; i++)
        {
            Grid.SetColumn((FrameworkElement)items[i], i);
            header.Children.Add(items[i]);
        }
        _title.VerticalAlignment = VerticalAlignment.Center;
        var top = new StackPanel { Spacing = 8, Padding = new Thickness(12, 12, 12, 8), Children = { header, _search, _loading } };

        var root = new Grid
        {
            RowDefinitions =
            {
                new RowDefinition { Height = GridLength.Auto }, new RowDefinition(), new RowDefinition { Height = GridLength.Auto },
            },
        };
        Grid.SetRow(_list, 1);
        Grid.SetRow(_status, 1);
        Grid.SetRow(_more, 2);
        _more.Margin = new Thickness(0, 6, 0, 10);
        foreach (var child in new FrameworkElement[] { top, _list, _status, _more }) root.Children.Add(child);
        Content = root;
    }

    internal void Show(RepositoryStore store, CollabKind kind)
    {
        var collab = store.Collab(kind);
        _store = store;
        if (!ReferenceEquals(collab, _collab))
        {
            if (_collab is not null) _collab.PropertyChanged -= OnChanged;
            _collab = collab;
            collab.PropertyChanged += OnChanged;
            _shown = [];
            _list.Items.Clear();
        }
        _title.Text = kind == CollabKind.PullRequest ? store.PullRequestsTitle : "Issues";
        _create.Visibility = store.HasProviderAccount ? Visibility.Visible : Visibility.Collapsed;
        Render();
    }

    private void OnChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (ReferenceEquals(sender, _collab)) Render();
    }

    private void Render()
    {
        if (_collab is not { } collab) return;
        _syncing = true;
        try
        {
            _filter.SelectedIndex = (int)collab.Filter;
            if (_search.Text != collab.Query) _search.Text = collab.Query;
            _loading.Visibility = collab.IsLoading ? Visibility.Visible : Visibility.Collapsed;
            _more.Visibility = collab.HasMore && !collab.IsLoading ? Visibility.Visible : Visibility.Collapsed;

            var visible = collab.VisibleItems;
            // Rows are rebuilt only when the items change, so selecting one doesn't scroll the list.
            if (!visible.SequenceEqual(_shown))
            {
                _shown = visible.ToList();
                _list.Items.Clear();
                foreach (var item in _shown) _list.Items.Add(Row(item));
            }
            _list.SelectedItem = _list.Items.OfType<FrameworkElement>()
                .FirstOrDefault(r => (int)r.Tag == collab.SelectedNumber);

            _status.Children.Clear();
            if (collab.Error is { } error)
            {
                _status.Children.Add(Ui.Error(error));
                _status.Children.Add(Ui.Button("Try again", () => _ = collab.LoadAsync()));
            }
            else if (!collab.IsLoading && visible.Count == 0)
            {
                _status.Children.Add(Ui.Text(collab.Query.Length > 0 ? "Nothing matches your search." : "Nothing here.",
                    secondary: true));
            }
        }
        finally
        {
            _syncing = false;
        }
    }

    private static FrameworkElement Row(CollabItem item)
    {
        var meta = Ui.Row(6, Ui.Text($"#{item.Number} · {item.Author} · {Ui.Ago(item.Updated)}", 11.5, secondary: true, wrap: false));
        if (item.IsDraft) meta.Children.Add(Ui.Chip("Draft"));
        if (item.State != CollabState.Open) meta.Children.Add(Ui.Chip(item.State.ToString(), StateBrush(item.State)));
        if (item.Comments > 0) meta.Children.Add(Ui.Text(item.Comments == 1 ? "1 comment" : $"{item.Comments} comments", 11.5, secondary: true, wrap: false));

        var title = Ui.Text(item.Title, 13, bold: true);
        title.MaxLines = 2;
        title.TextTrimming = TextTrimming.CharacterEllipsis;
        var panel = new StackPanel { Spacing = 3, Padding = new Thickness(0, 7, 0, 7), Tag = item.Number, Children = { title, meta } };
        if (item.Labels.Count > 0)
        {
            var labels = Ui.Row(4);
            foreach (var label in item.Labels.Take(4)) labels.Children.Add(Ui.Chip(label));
            panel.Children.Add(labels);
        }
        AutomationProperties.SetName(panel, $"#{item.Number} {item.Title}");
        return panel;
    }

    internal static Microsoft.UI.Xaml.Media.Brush StateBrush(CollabState state) => state switch
    {
        CollabState.Open => Palette.Green,
        CollabState.Merged => Palette.Ref(RefKind.Remote),
        _ => Palette.Orange,
    };
}
