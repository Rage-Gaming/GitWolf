using GitWolf.App.Services;
using GitWolf.Core;
using GitWolf.Store;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Windows.System;

namespace GitWolf.App.Views;

/// <summary>One pull request or issue: description, conversation and actions. Ported from CollabViews.swift.</summary>
public sealed class CollabDetailView : UserControl
{
    private readonly ScrollViewer _scroller = new();
    private readonly StackPanel _body = new() { Spacing = 12, Padding = new Thickness(18, 16, 18, 18) };
    private readonly StackPanel _composer = new() { Spacing = 8, Padding = new Thickness(18, 10, 18, 14) };
    private readonly TextBox _comment = new()
    {
        PlaceholderText = "Write a comment (Markdown)", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap,
        MinHeight = 56, MaxHeight = 140,
    };
    private readonly Button _send;
    private readonly TextBlock _empty = new()
    {
        HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Opacity = 0.65,
    };
    private readonly ChecksView _checks = new();
    private RepositoryStore? _store;
    private CollabStore? _collab;
    private (CollabStore?, int?) _drafting;

    public CollabDetailView()
    {
        AutomationProperties.SetName(_comment, "Comment");
        _send = Ui.Button("Comment", () => _ = SendAsync());
        _send.HorizontalAlignment = HorizontalAlignment.Right;
        _comment.TextChanged += (_, _) => _send.IsEnabled = CanSend;
        _composer.Children.Add(_comment);
        _composer.Children.Add(_send);
        _scroller.Content = _body;
        var root = new Grid { RowDefinitions = { new RowDefinition(), new RowDefinition { Height = GridLength.Auto } } };
        Grid.SetRow(_composer, 1);
        Grid.SetRowSpan(_empty, 2);
        root.Children.Add(_scroller);
        root.Children.Add(_composer);
        root.Children.Add(_empty);
        Content = root;
    }

    private bool CanSend => _collab is { IsWorking: false } && _comment.Text.Trim().Length > 0;

    private async Task SendAsync()
    {
        if (_collab is not { } collab || !CanSend) return;
        var key = _drafting;
        // Kept on screen until the server has it.
        if (await collab.AddCommentAsync(_comment.Text.Trim()) && _drafting == key) _comment.Text = "";
    }

    internal void Show(RepositoryStore store, CollabKind kind)
    {
        var collab = store.Collab(kind);
        if (!ReferenceEquals(_store, store))
        {
            if (_store is not null) _store.PropertyChanged -= OnStoreChanged;
            _store = store;
            store.PropertyChanged += OnStoreChanged;
        }
        if (!ReferenceEquals(collab, _collab))
        {
            if (_collab is not null) _collab.PropertyChanged -= OnChanged;
            _collab = collab;
            collab.PropertyChanged += OnChanged;
        }
        Render();
    }

    private void OnChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (ReferenceEquals(sender, _collab)) Render();
    }

    private void OnStoreChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(RepositoryStore.Checks) && ReferenceEquals(sender, _store)) ShowChecks();
    }

    private void ShowChecks()
    {
        if (_collab?.Selected is { HeadSha.Length: > 0 } item) _checks.Show(_store?.Checks(item.HeadSha));
        else _checks.Show(null);
    }

    private void Render()
    {
        if (_collab is not { } collab) return;
        var item = collab.Selected;
        _empty.Text = collab.Kind == CollabKind.Issue ? "Select an issue to read it" : "Select a pull request to read it";
        _empty.Visibility = item is null ? Visibility.Visible : Visibility.Collapsed;
        _scroller.Visibility = item is null ? Visibility.Collapsed : Visibility.Visible;
        _composer.Visibility = item is not null && collab.CanWrite ? Visibility.Visible : Visibility.Collapsed;
        _send.IsEnabled = CanSend;
        // A half-written comment belongs to the item it was written on.
        if (_drafting != (collab, item?.Number))
        {
            _drafting = (collab, item?.Number);
            _comment.Text = "";
            _scroller.ChangeView(null, 0, null, true);
        }
        // The checks control is reused, so it leaves its old parent before the content is rebuilt.
        _body.Children.Clear();
        if (item is null) return;

        var title = Ui.Text(item.Title, 18, bold: true);
        title.IsTextSelectionEnabled = true;
        _body.Children.Add(title);

        var meta = Ui.Row(8, Ui.Chip(item.IsDraft ? "Draft" : item.State.ToString(), CollabListView.StateBrush(item.State)),
            Ui.Text($"#{item.Number} by {item.Author} · {Ui.Ago(item.Created)}", 12, secondary: true));
        _body.Children.Add(meta);
        if (item.SourceBranch.Length > 0)
            _body.Children.Add(Ui.Text($"{item.SourceBranch} → {item.TargetBranch}", 12, secondary: true));
        if (item.Labels.Count > 0)
        {
            var labels = Ui.Row(4);
            foreach (var label in item.Labels) labels.Children.Add(Ui.Chip(label));
            _body.Children.Add(new ScrollViewer
            {
                Content = labels, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
                VerticalScrollBarVisibility = ScrollBarVisibility.Disabled, HorizontalScrollMode = ScrollMode.Auto,
            });
        }
        _body.Children.Add(Actions(collab, item));
        if (collab.ActionError is { } failure) _body.Children.Add(Ui.Error(failure));
        _body.Children.Add(_checks);
        ShowChecks();
        if (item.HeadSha.Length > 0) _ = _store?.LoadChecksAsync(item.HeadSha);

        _body.Children.Add(Card(item.Author, item.Created,
            item.Body.Trim().Length > 0 ? MarkdownView.Create(item.Body) : Ui.Text("No description.", secondary: true)));
        if (collab.IsLoadingComments) _body.Children.Add(new ProgressBar { IsIndeterminate = true });
        if (collab.CommentsError is { } error) _body.Children.Add(Ui.Error(error));
        foreach (var comment in collab.Comments)
            _body.Children.Add(Card(comment.Author, comment.Created, MarkdownView.Create(comment.Body)));
    }

    private static Border Card(string author, DateTimeOffset? when, UIElement content) => new()
    {
        CornerRadius = new CornerRadius(10), BorderThickness = new Thickness(1), Padding = new Thickness(14, 10, 14, 12),
        BorderBrush = Ui.Theme("PillBorderBrush"),
        Child = new StackPanel
        {
            Spacing = 8,
            Children = { Ui.Text($"{author} · {Ui.Ago(when)}", 11.5, secondary: true), content },
        },
    };

    private UIElement Actions(CollabStore collab, CollabItem item)
    {
        var row = Ui.Row(8);
        if (item.Url is { } url) row.Children.Add(Ui.Button("Open on web", () => _ = Launcher.LaunchUriAsync(url)));
        if (!collab.CanWrite) return row;
        var pull = collab.Kind == CollabKind.PullRequest;
        var word = pull ? "pull request" : "issue";
        if (pull && item.State == CollabState.Open && !item.IsDraft)
        {
            var menu = new MenuFlyout();
            foreach (var method in Enum.GetValues<MergeMethod>())
            {
                var entry = new MenuFlyoutItem { Text = method.Title() };
                entry.Click += (_, _) => _ = ConfirmThenAsync(collab, item.Number, $"Merge #{item.Number}?",
                    $"{method.Title()} “{item.Title}” into {item.TargetBranch}. This changes the repository on the server.",
                    "Merge", () => collab.MergeAsync(method));
                menu.Items.Add(entry);
            }
            row.Children.Add(new DropDownButton { Content = "Merge", Flyout = menu, IsEnabled = !collab.IsWorking });
        }
        if (item.State == CollabState.Open)
        {
            var close = Ui.Button("Close", () => _ = ConfirmThenAsync(collab, item.Number, $"Close #{item.Number}?",
                $"Close the {word} “{item.Title}” on the server.", "Close", () => collab.SetOpenAsync(false)));
            close.IsEnabled = !collab.IsWorking;
            row.Children.Add(close);
        }
        else if (item.State == CollabState.Closed)
        {
            var reopen = Ui.Button("Reopen", () => _ = collab.SetOpenAsync(true));
            reopen.IsEnabled = !collab.IsWorking;
            row.Children.Add(reopen);
        }
        if (collab.RepositoryLabels.Count > 0) row.Children.Add(LabelsButton(collab, item));
        return row;
    }

    private static UIElement LabelsButton(CollabStore collab, CollabItem item)
    {
        var menu = new MenuFlyout();
        foreach (var label in collab.RepositoryLabels)
        {
            var toggle = new ToggleMenuFlyoutItem { Text = label, IsChecked = item.Labels.Contains(label) };
            toggle.Click += (_, _) => _ = collab.SetLabelsAsync(toggle.IsChecked
                ? [.. item.Labels, label]
                : item.Labels.Where(l => l != label).ToList());
            menu.Items.Add(toggle);
        }
        return new DropDownButton { Content = "Labels", Flyout = menu, IsEnabled = !collab.IsWorking };
    }

    /// <summary>Nothing happens if another item was selected while the question was open.</summary>
    private async Task ConfirmThenAsync(
        CollabStore collab, int number, string title, string message, string verb, Func<Task<bool>> run)
    {
        if (await Dialogs.ConfirmAsync(XamlRoot, title, message, verb) && collab.SelectedNumber == number) await run();
    }
}
