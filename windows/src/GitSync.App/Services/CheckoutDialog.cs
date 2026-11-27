using System.Diagnostics;
using System.Text.RegularExpressions;
using GitSync.Core;
using GitSync.Store;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;

namespace GitSync.App.Services;

/// <summary>Worktrees and submodules of a repository. Ported from WorktreesSheet.swift.</summary>
internal sealed partial class CheckoutDialog
{
    private readonly RepositoryStore _store;
    private readonly IntPtr _window;
    private readonly Action<string> _open;
    private readonly StackPanel _content = new() { Spacing = 10, Width = 480 };
    private readonly TextBlock _error = new() { TextWrapping = TextWrapping.Wrap, FontSize = 12, MaxHeight = 120 };
    private readonly ContentDialog _dialog;

    private CheckoutDialog(XamlRoot root, RepositoryStore store, IntPtr window, Action<string> open)
    {
        (_store, _window, _open) = (store, window, open);
        _dialog = new ContentDialog
        {
            RequestedTheme = (root.Content as FrameworkElement)?.ActualTheme ?? ElementTheme.Default,
            XamlRoot = root, Title = "Worktrees & submodules", CloseButtonText = "Done",
            Content = new ScrollViewer { Content = _content, Padding = new Thickness(0, 0, 12, 0) },
        };
    }

    public static async Task ShowAsync(XamlRoot root, RepositoryStore store, IntPtr window, Action<string> open)
    {
        var view = new CheckoutDialog(root, store, window, open);
        await view.LoadAsync();
        try
        {
            await view._dialog.ShowAsync();
        }
        catch (Exception e)
        {
            // WinUI allows one dialog at a time.
            Trace.TraceWarning($"Worktrees dialog could not be shown: {e.GetType().Name}");
        }
    }

    private async Task LoadAsync()
    {
        try
        {
            var repo = _store.Repo;
            var worktrees = await Task.Run(repo.WorktreesAsync);
            var submodules = await Task.Run(repo.SubmodulesAsync);
            _content.Children.Clear();
            ShowWorktrees(worktrees);
            ShowSubmodules(submodules);
        }
        catch (Exception e) when (e is GitException or IOException or UnauthorizedAccessException)
        {
            _error.Text = e.Message;
        }
        if (!_content.Children.Contains(_error)) _content.Children.Add(_error);
    }

    private async Task ChangeAsync(string label, Func<GitRepository, Task> change)
    {
        _content.IsHitTestVisible = false;
        _error.Text = label;
        var done = await _store.ChangeCheckoutsAsync(label, change);
        var failure = done ? "" : _store.ErrorMessage ?? "Another operation is still running.";
        await LoadAsync();
        _error.Text = failure;
        _content.IsHitTestVisible = true;
    }

    private void ShowWorktrees(IReadOnlyList<Worktree> worktrees)
    {
        _content.Children.Add(Heading("Worktrees"));
        foreach (var tree in worktrees)
        {
            var tags = string.Join(" · ", new[]
            {
                tree.Branch ?? "detached", tree.IsMain ? "main worktree" : null, tree.IsLocked ? "locked" : null,
                tree.IsPrunable ? "missing" : null,
            }.Where(t => t is not null));
            var buttons = new List<Button>();
            var current = SamePath(tree.Path, _store.Id);
            if (!current && !tree.IsPrunable) buttons.Add(Button("Open", () => OpenAndClose(tree.Path)));
            if (!current && !tree.IsMain && !tree.IsPrunable && !tree.IsLocked) buttons.Add(RemoveButton(tree));
            _content.Children.Add(Row(tree.Name, $"{tags}\n{tree.Path}", buttons));
        }
        if (worktrees.Any(t => t.IsPrunable))
            _content.Children.Add(Button("Prune missing worktrees",
                () => _ = ChangeAsync("Pruning worktrees…", r => r.PruneWorktreesAsync())));
        ShowNewWorktree(worktrees);
    }

    private void ShowNewWorktree(IReadOnlyList<Worktree> worktrees)
    {
        // A branch can only be checked out in one place at a time.
        var taken = worktrees.Select(t => t.Branch).ToHashSet(StringComparer.Ordinal);
        var free = _store.LocalBranches.Select(b => b.Name).Where(n => !taken.Contains(n)).ToList();
        var existing = new ComboBox
        {
            ItemsSource = free, PlaceholderText = "Branch", HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        var name = new TextBox { PlaceholderText = "new-branch-name", Visibility = Visibility.Collapsed };
        var fresh = new CheckBox { Content = "New branch" };
        var create = Button("Choose folder and create…", () => { });
        void Check() => create.IsEnabled = fresh.IsChecked == true
            ? name.Text.Trim().Length > 0 : existing.SelectedItem is string;
        fresh.Click += (_, _) =>
        {
            name.Visibility = fresh.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
            existing.Visibility = fresh.IsChecked == true ? Visibility.Collapsed : Visibility.Visible;
            Check();
        };
        existing.SelectionChanged += (_, _) => Check();
        name.TextChanged += (_, _) => Check();
        Check();
        create.Click += async (_, _) =>
        {
            var isNew = fresh.IsChecked == true;
            var branch = isNew ? name.Text.Trim() : existing.SelectedItem as string;
            if (string.IsNullOrEmpty(branch)
                || await ToolDialogs.PickFolderAsync(_window, _store) is not { } parent) return;
            var folder = Path.Combine(parent, branch.Replace('/', '-'));
            await ChangeAsync("Adding worktree…", r => r.AddWorktreeAsync(folder, branch, isNew));
        };
        _content.Children.Add(existing);
        _content.Children.Add(name);
        _content.Children.Add(fresh);
        _content.Children.Add(create);
    }

    private Button RemoveButton(Worktree tree)
    {
        var confirm = new Button { Content = "Delete folder" };
        var flyout = new Flyout
        {
            Content = new StackPanel
            {
                Spacing = 8, MaxWidth = 300,
                Children =
                {
                    new TextBlock
                    {
                        TextWrapping = TextWrapping.Wrap,
                        Text = "Its folder is deleted. The branch and its commits stay. Git refuses if the folder "
                            + "has uncommitted changes.",
                    },
                    confirm,
                },
            },
        };
        confirm.Click += (_, _) =>
        {
            flyout.Hide();
            _ = ChangeAsync("Removing worktree…", r => r.RemoveWorktreeAsync(tree.Path));
        };
        var button = new Button { Content = "Remove…" };
        FlyoutBase.SetAttachedFlyout(button, flyout);
        button.Click += (_, _) => flyout.ShowAt(button);
        return button;
    }

    private void ShowSubmodules(IReadOnlyList<Submodule> submodules)
    {
        _content.Children.Add(Heading("Submodules"));
        foreach (var module in submodules)
        {
            var state = module.State switch
            {
                SubmoduleState.NotInitialized => "not initialized",
                SubmoduleState.Modified => "different commit checked out",
                SubmoduleState.Conflicted => "conflicted",
                _ => "up to date",
            };
            var button = module.State == SubmoduleState.NotInitialized
                ? Button("Initialize",
                    () => _ = ChangeAsync("Downloading submodule…", r => r.UpdateSubmodulesAsync(module.Path)))
                : Button("Open", () => OpenAndClose(Path.GetFullPath(Path.Combine(_store.Id, module.Path))));
            _content.Children.Add(Row(module.Path, $"{state}\n{Redact(module.Url)}", [button]));
        }
        if (submodules.Count > 0)
            _content.Children.Add(new StackPanel
            {
                Orientation = Orientation.Horizontal, Spacing = 8,
                Children =
                {
                    Button("Update all",
                        () => _ = ChangeAsync("Updating submodules…", r => r.UpdateSubmodulesAsync())),
                    Button("Update to latest",
                        () => _ = ChangeAsync("Updating submodules…", r => r.UpdateSubmodulesToLatestAsync())),
                },
            });
        var url = new TextBox { PlaceholderText = "Repository URL" };
        var path = new TextBox { PlaceholderText = "Folder inside this repository" };
        var add = Button("Add submodule", () =>
        {
            var (from, into) = (url.Text.Trim(), path.Text.Trim());
            if (from.Length > 0 && into.Length > 0)
                _ = ChangeAsync("Adding submodule…", r => r.AddSubmoduleAsync(from, into));
        });
        _content.Children.Add(url);
        _content.Children.Add(path);
        _content.Children.Add(add);
    }

    private void OpenAndClose(string path)
    {
        _dialog.Hide();
        _open(path);
    }

    private static bool SamePath(string a, string b) => string.Equals(
        Path.TrimEndingDirectorySeparator(Path.GetFullPath(a)), Path.TrimEndingDirectorySeparator(Path.GetFullPath(b)),
        StringComparison.OrdinalIgnoreCase);

    /// <summary>A URL can carry a user name or token, which is never shown.</summary>
    private static string Redact(string url) => Credentials().Replace(url, "");

    [GeneratedRegex(@"(?<=://)[^/]*@")]
    private static partial Regex Credentials();

    private static TextBlock Heading(string text) => new()
    {
        Text = text, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Margin = new Thickness(0, 6, 0, 0),
    };

    private static Button Button(string text, Action run)
    {
        var button = new Button { Content = text };
        button.Click += (_, _) => run();
        return button;
    }

    private static Grid Row(string title, string detail, IReadOnlyList<Button> buttons)
    {
        var text = new StackPanel
        {
            Children =
            {
                new TextBlock { Text = title, TextTrimming = TextTrimming.CharacterEllipsis },
                new TextBlock
                {
                    Text = detail, FontSize = 12, Opacity = 0.7, TextWrapping = TextWrapping.Wrap,
                    IsTextSelectionEnabled = true,
                },
            },
        };
        var actions = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center,
        };
        foreach (var button in buttons) actions.Children.Add(button);
        Grid.SetColumn(actions, 1);
        return new Grid
        {
            ColumnSpacing = 8,
            ColumnDefinitions = { new ColumnDefinition(), new ColumnDefinition { Width = GridLength.Auto } },
            Children = { text, actions },
        };
    }
}
