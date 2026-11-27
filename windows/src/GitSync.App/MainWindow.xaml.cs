using System.ComponentModel;
using System.Diagnostics;
using GitSync.App.Services;
using GitSync.App.Views;
using GitSync.Core;
using GitSync.Store;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.Storage.Pickers;
using Windows.System;

namespace GitSync.App;

/// <summary>Shell: repository rail, top bar, sidebar, list and detail panels for the selected repository.</summary>
public sealed partial class MainWindow : Window
{
    private readonly Workspace _workspace;
    private readonly AppSettings _settings = new();
    /// <summary>The repository the panels currently mirror.</summary>
    private RepositoryStore? _store;

    public MainWindow()
    {
        InitializeComponent();
        Title = "GitSync";
        ExtendsContentIntoTitleBar = true;
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;

        _workspace = new Workspace(_settings, uri => _ = Launcher.LaunchUriAsync(uri));
        Avatars.Enabled = _settings.State.ProfilePictures;
        Avatars.Changed += () =>
        {
            History.ShowPictures();
            Detail.ShowPicture();
        };
        _workspace.Changed += Bind;
        Rail.Attach(_workspace);
        Rail.AddRequested += ShowAddMenu;
        Dashboard.CloneRequested += () => _ = CreateAsync(clone: true);
        Dashboard.NewRequested += () => _ = CreateAsync(clone: false);
        TopBar.JumpRequested += OpenPalette;
        Dashboard.OpenRequested += () => _ = PickAsync();
        Dashboard.JumpRequested += OpenPalette;
        Dashboard.PathsRequested += paths => _ = OpenAllAsync(paths);
        Diff.LayoutChanged += split => _workspace.SplitDiff = split;
        Rail.SettingsRequested += Settings.Open;
        Settings.Attach(this, _settings, _workspace);
        Settings.SplitChanged += split => _workspace.SplitDiff = Diff.IsSplit = split;
        _settings.Changed += OnSettingsChanged;
        Diff.SyntaxEnabled = _settings.State.SyntaxHighlighting;
        Root.ActualThemeChanged += (_, _) => Theming.UpdateCaptionButtons(this, Root.ActualTheme);
        Root.Loaded += (_, _) => Theming.Apply(this, _settings.State);
        AddShortcuts();

        Activated += (_, e) =>
        {
            if (e.WindowActivationState != WindowActivationState.Deactivated) _ = _store?.RequestRefresh();
        };
        Closed += (_, _) => _workspace.Dispose();
        SetUpPanels();
        Bind();
    }

    /// <summary>Restores the last session, then opens and selects the folder given on the command line.</summary>
    internal async Task StartAsync(string? path)
    {
        try
        {
            // Restore first: opening saves the list, which would otherwise replace the saved one.
            await _workspace.RestoreAsync();
            Diff.IsSplit = _workspace.SplitDiff;
            if (path is not null) await OpenAsync(path);
        }
        catch (Exception e)
        {
            // Fire-and-forget from launch: report rather than lose the failure.
            Trace.TraceError($"Startup failed: {e.GetType().Name}");
            ShowError("The last session couldn’t be restored.");
        }
    }

    private async Task OpenAsync(string path)
    {
        try
        {
            ShowError(null);
            await _workspace.OpenAsync(path);
        }
        catch (GitException e)
        {
            ShowError(e.Message);
        }
    }

    private async Task PickAsync()
    {
        try
        {
            var picker = new FolderPicker();
            picker.FileTypeFilter.Add("*");
            // Unpackaged apps must tell the picker which window owns it.
            WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
            if (await picker.PickSingleFolderAsync() is { } folder) await OpenAsync(folder.Path);
        }
        catch (Exception e)
        {
            Trace.TraceError($"Opening a repository failed: {e.GetType().Name}");
            ShowError("The folder couldn’t be opened.");
        }
    }

    private void ShowAddMenu(FrameworkElement anchor)
    {
        var menu = new MenuFlyout();
        void Add(string text, Action action)
        {
            var item = new MenuFlyoutItem { Text = text };
            item.Click += (_, _) => action();
            menu.Items.Add(item);
        }
        Add("Open repository\u2026", () => _ = PickAsync());
        Add("Clone repository\u2026", () => _ = CreateAsync(clone: true));
        Add("New repository\u2026", () => _ = CreateAsync(clone: false));
        menu.ShowAt(anchor);
    }

    private async Task CreateAsync(bool clone)
    {
        var window = WinRT.Interop.WindowNative.GetWindowHandle(this);
        var git = _settings.CustomGitPath;
        var folder = clone
            ? await CreateDialogs.CloneAsync(Root.XamlRoot, window, git)
            : await CreateDialogs.NewAsync(Root.XamlRoot, window, git);
        if (folder is not null) await OpenAllAsync([folder]);
    }

    /// <summary>One at a time, so each repository is added before the next is checked.</summary>
    private async Task OpenAllAsync(IReadOnlyList<string> paths)
    {
        try
        {
            foreach (var path in paths) await OpenAsync(path);
        }
        catch (Exception e)
        {
            Trace.TraceError($"Opening a repository failed: {e.GetType().Name}");
            ShowError("The folder couldn’t be opened.");
        }
    }

    /// <summary>Points the panels at the selected repository.</summary>
    private void Bind()
    {
        Rail.Show();
        var selected = _workspace.Selected;
        if (!ReferenceEquals(selected, _store))
        {
            if (_store is not null) _store.PropertyChanged -= OnStoreChanged;
            _store = selected;
            if (selected is not null)
            {
                selected.PropertyChanged += OnStoreChanged;
                History.Attach(selected);
                Changes.Attach(selected);
                Sidebar.Attach(selected);
            }
            ShowError(selected?.ErrorMessage);
            Title = selected is null ? "GitSync" : $"{selected.Name} — GitSync";
            if (selected?.PullBlock is not null) DispatcherQueue.TryEnqueue(ShowPullBlock);
            if (selected?.HookFailure is not null) DispatcherQueue.TryEnqueue(ShowHookFailure);
        }
        ShowAll();
    }

    /// <summary>Asked once, for the repository on screen; one in the background asks when selected.</summary>
    private void ShowHookFailure()
    {
        if (_store is not { HookFailure: { } failure } store) return;
        store.HookFailure = null;
        _ = CommitDialogs.HookFailedAsync(Root.XamlRoot, store, failure);
    }

    private void ShowPullBlock()
    {
        if (_store is not { PullBlock: { } block } store) return;
        store.PullBlock = null;
        _ = Dialogs.PullBlockedAsync(Root.XamlRoot, store, block);
    }

    private void ShowAll()
    {
        var store = _store;
        var loaded = store?.IsLoaded == true;
        Home.Visibility = When(store is null);
        if (store is null) Dashboard.Show(_workspace.Recents);
        Repository.Visibility = When(loaded);
        Loading.IsActive = store is not null && !loaded;
        SetTitleBar(loaded ? (UIElement)TopBar.DragRegion : HomeDragArea);
        ShowBusy();
        if (store is null || !loaded) return;
        _ = Avatars.LoadAsync(store.RemoteLocation);
        Banner.Show(store);
        ToolBanners.Show(store);

        var history = store.Mode == StoreMode.History;
        History.Visibility = When(history);
        Changes.Visibility = When(store.Mode == StoreMode.Changes);
        Compare.Visibility = When(store.Mode == StoreMode.Compare);
        if (store.Mode == StoreMode.Compare) Compare.Show(store);
        StashPanel.Visibility = When(store.Mode == StoreMode.Stash);
        ShowStash();
        TopBar.Show(store);
        History.ShowCommits();
        Changes.ShowFiles();
        Sidebar.Show();
        ShowDetail();
    }

    /// <summary>Right panel: commit header, files and diff in history; only the diff in changes.</summary>
    private void ShowDetail()
    {
        if (_store is not { } store) return;
        var history = store.Mode == StoreMode.History;
        var comparing = store.Mode == StoreMode.Compare;
        // Nothing to show on the right until a commit, or a compared file, is picked.
        var previewing = comparing || store.Mode == StoreMode.Stash;
        var noCommit = (history && store.SelectedCommit is null) || (previewing && store.SelectedTarget is null);
        NoCommit.Text = previewing ? "Select a file to see its changes" : "Select a commit to see its changes";
        Detail.Visibility = When(history && !noCommit);
        // A conflicted file gets the resolver instead of its diff.
        var conflict = store.Mode == StoreMode.Changes && store.SelectedTarget is { } target && target.Source == DiffSource.Conflicted
            && store.Status.Conflicted.Any(f => f.Path == target.Path)
                ? target.Path : null;
        Diff.Visibility = When(!noCommit && conflict is null);
        Conflict.Visibility = When(conflict is not null);
        NoCommit.Visibility = When(noCommit);
        if (history) Detail.Show(store);
        Conflict.Show(store, conflict);
        if (conflict is null) Diff.Show(store);
    }

    private void ShowStash()
    {
        if (_store is { Mode: StoreMode.Stash } store) StashPanel.Show(store);
    }

    private static Visibility When(bool condition) => condition ? Visibility.Visible : Visibility.Collapsed;

    private void ShowBusy()
    {
        var busy = _store?.IsBusy == true;
        Busy.IsActive = busy;
        BusyPill.Visibility = When(busy);
        BusyText.Text = _store?.BusyLabel ?? "";
    }

    private void OnStoreChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (_store is not { } store || !ReferenceEquals(sender, store)) return;
        switch (e.PropertyName)
        {
            case nameof(RepositoryStore.Commits):
            case nameof(RepositoryStore.Graph):
                History.ShowCommits();
                break;
            case nameof(RepositoryStore.CommitFiles):
            case nameof(RepositoryStore.CommitMessage):
                Detail.Show(store);
                break;
            case nameof(RepositoryStore.SelectedCommitId):
                History.ShowSelection();
                ShowDetail();
                break;
            case nameof(RepositoryStore.SelectedTarget):
                History.ShowSelection();
                Changes.ShowSelection();
                ShowStash();
                ShowDetail();
                break;
            case nameof(RepositoryStore.Diff):
            case nameof(RepositoryStore.CanPatch):
            case nameof(RepositoryStore.LineSelection):
                ShowDetail();
                break;
            case nameof(RepositoryStore.Operation):
                Banner.Show(store);
                break;
            case nameof(RepositoryStore.Bisect):
            case nameof(RepositoryStore.IsShallow):
                ToolBanners.Show(store);
                break;
            case nameof(RepositoryStore.LfsPaths):
                Changes.ShowFiles();
                break;
            case nameof(RepositoryStore.Status):
                Banner.Show(store);
                ShowDetail();
                Changes.ShowFiles();
                Sidebar.Show();
                TopBar.Show(store);
                break;
            case nameof(RepositoryStore.RemoteLocation):
                _ = Avatars.LoadAsync(store.RemoteLocation);
                Sidebar.Show();
                break;
            case nameof(RepositoryStore.LocalBranches):
            case nameof(RepositoryStore.RemoteBranches):
            case nameof(RepositoryStore.Remotes):
            case nameof(RepositoryStore.Tags):
            case nameof(RepositoryStore.Stashes):
            case nameof(RepositoryStore.ProviderTitle):
                Sidebar.Show();
                break;
            case nameof(RepositoryStore.DraftMessage):
            case nameof(RepositoryStore.Amend):
                Changes.ShowDraft();
                break;
            case nameof(RepositoryStore.IsBusy):
            case nameof(RepositoryStore.BusyLabel):
                ShowBusy();
                ShowStash();
                TopBar.Show(store);
                Changes.ShowCommitState();
                Banner.Show(store);
                ToolBanners.Show(store);
                Conflict.ShowState();
                break;
            case nameof(RepositoryStore.ErrorMessage):
                ShowError(store.ErrorMessage);
                break;
            case nameof(RepositoryStore.Comparison):
                Compare.Show(store);
                break;
            case nameof(RepositoryStore.SelectedStash):
                ShowStash();
                ShowDetail();
                break;
            case nameof(RepositoryStore.SearchResults):
                History.ShowCommits();
                break;
            case nameof(RepositoryStore.HookFailure):
                DispatcherQueue.TryEnqueue(ShowHookFailure);
                break;
            case nameof(RepositoryStore.PullBlock):
                // The dialog can start another pull, so wait until this one has finished.
                DispatcherQueue.TryEnqueue(ShowPullBlock);
                break;
            case nameof(RepositoryStore.Mode):
            case nameof(RepositoryStore.IsLoaded):
                ShowAll();
                break;
        }
    }

    private void AddShortcuts()
    {
        void Add(VirtualKey key, VirtualKeyModifiers modifiers, Action action)
        {
            var accelerator = new KeyboardAccelerator { Key = key, Modifiers = modifiers };
            accelerator.Invoked += (_, e) =>
            {
                e.Handled = true;
                action();
            };
            Root.KeyboardAccelerators.Add(accelerator);
        }
        const VirtualKeyModifiers shifted = VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift;
        Root.KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;
        Add(VirtualKey.K, VirtualKeyModifiers.Control, OpenPalette);
        Add(VirtualKey.O, VirtualKeyModifiers.Control, () => _ = PickAsync());
        // The comma key (VK_OEM_COMMA) has no named VirtualKey.
        Add((VirtualKey)188, VirtualKeyModifiers.Control, Settings.Open);
        Add(VirtualKey.F, shifted, () => _ = Idle?.FetchAsync());
        Add(VirtualKey.L, shifted, () => _ = Idle?.PullAsync());
        Add(VirtualKey.P, shifted, () => _ = Idle?.PushAsync());
        Add(VirtualKey.C, VirtualKeyModifiers.Control | VirtualKeyModifiers.Menu,
            () => _ = Idle?.OpenCompareAsync());
        AddMoreShortcuts(Add);
    }

    /// <summary>The selected repository when it can take a new operation.</summary>
    private RepositoryStore? Idle => _store is { IsLoaded: true, IsBusy: false } store ? store : null;

    private void OpenPalette()
    {
        var items = _workspace.Repos
            .Select(r => new PaletteItem(Icons.File, r.Name, "Switch repository", () => _workspace.Select(r)))
            .ToList();
        if (Idle is { } s)
        {
            void Add(Icons.Shape glyph, string title, string subtitle, Action run) =>
                items.Add(new PaletteItem(glyph, title, subtitle, run));
            if (s.Operation is { } operation)
            {
                var verb = operation.Verb.ToLowerInvariant();
                if (s.Status.Conflicted.Count == 0)
                    Add(Icons.Changes, $"Continue {verb}", "Repository action", () => _ = s.ContinueOperationAsync());
                Add(Icons.Changes, $"Abort {verb}\u2026", "Repository action",
                    () => _ = Dialogs.AbortAsync(Root.XamlRoot, s, operation));
            }
            Add(Icons.Fetch, "Fetch", "Repository action", () => _ = s.FetchAsync());
            Add(Icons.Pull, "Pull", "Repository action", () => _ = s.PullAsync());
            Add(Icons.Push, "Push", "Repository action", () => _ = s.PushAsync());
            Add(Icons.Plus, "New branch…", "Repository action",
                () => _ = Dialogs.NewBranchAsync(Root.XamlRoot, s, null));
            Add(Icons.Branch, "Clean up branches\u2026", "Repository action",
                () => _ = BranchDialogs.CleanupAsync(Root.XamlRoot, s));
            Add(Icons.Branch, "Worktrees & submodules\u2026", "Repository action",
                () => _ = CheckoutDialog.ShowAsync(Root.XamlRoot, s, WindowHandle, path => _ = OpenAsync(path)));
            Add(Icons.File, "Apply patch\u2026", "Repository action",
                () => _ = ToolDialogs.ApplyPatchesAsync(Root.XamlRoot, s, WindowHandle));
            Add(Icons.File, "Create patch from changes\u2026", "Repository action",
                () => _ = ToolDialogs.SavePatchAsync(s, WindowHandle));
            if (s.Bisect.IsActive)
                Add(Icons.History, "Stop bisect", "Repository action", () => _ = s.StopBisectAsync());
            if (s.IsShallow)
                Add(Icons.Fetch, "Fetch full history", "Sync", () => _ = s.UnshallowAsync());
            Add(Icons.Branch, "Compare refs\u2026", "Repository action", () => _ = s.OpenCompareAsync());
            Add(Icons.History, "Reflog\u2026", "Repository action",
                () => _ = HistoryDialogs.ReflogAsync(Root.XamlRoot, s));
            Add(Icons.History, "Undo last change\u2026", "Repository action",
                () => _ = HistoryDialogs.UndoAsync(Root.XamlRoot, s));
            Add(Icons.History, "Show history", "View", () => s.Mode = StoreMode.History);
            Add(Icons.Changes, "Show changes", "View", () => s.Mode = StoreMode.Changes);
            if (s.WebLinks is not null)
            {
                var site = s.ProviderTitle ?? "the web";
                Add(Icons.OpenLink, $"Open on {site}", "Repository action", () => s.OpenOnWeb(new WebTarget.Repository()));
                Add(Icons.OpenLink, $"Open branch on {site}", "Repository action", () => s.OpenOnWeb(new WebTarget.Branch()));
                Add(Icons.OpenLink, $"Create pull request on {site}", "Repository action",
                    () => s.OpenOnWeb(new WebTarget.PullRequest()));
            }
            foreach (var branch in s.LocalBranches.Where(b => !b.IsCurrent))
                Add(Icons.Branch, branch.Name, "Check out branch", () => _ = s.CheckoutAsync(branch));
        }
        items.Add(new PaletteItem(Icons.Plus, "Open repository…", "Workspace", () => _ = PickAsync()));
        items.Add(new PaletteItem(Icons.Plus, "Clone repository\u2026", "Workspace", () => _ = CreateAsync(clone: true)));
        items.Add(new PaletteItem(Icons.Plus, "New repository\u2026", "Workspace", () => _ = CreateAsync(clone: false)));
        items.Add(new PaletteItem(Icons.Plus, "Settings\u2026", "App", Settings.Open));
        CommandPalette.Open(items);
    }

    private void OnSettingsChanged(SettingsState old, SettingsState now)
    {
        if (old.Appearance != now.Appearance || old.Accent != now.Accent)
        {
            Theming.Apply(this, now);
            Rail.Show();
        }
        Diff.SyntaxEnabled = now.SyntaxHighlighting;
        Changes.SpellCheck = now.SpellCheck;
        if (old.ProfilePictures != now.ProfilePictures)
        {
            Avatars.Enabled = now.ProfilePictures;
            Avatars.Refresh();
            _ = Avatars.LoadAsync(_store?.RemoteLocation);
        }
        if (old.CommitPageSize == now.CommitPageSize && old.DiffContext == now.DiffContext && old.GitPath == now.GitPath)
            return;
        foreach (var repo in _workspace.Repos) repo.ApplySettings();
    }

    private void ShowError(string? message)
    {
        ErrorText.Text = message ?? "";
        // A new message starts from its first line.
        ErrorScroller.ChangeView(null, 0, null, true);
        Error.IsOpen = message is not null;
    }

    private void OnErrorClosed(InfoBar sender, InfoBarClosedEventArgs args)
    {
        if (_store is { } store) store.ErrorMessage = null;
    }
}
