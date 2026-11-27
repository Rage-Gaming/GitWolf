using GitWolf.App.Services;
using GitWolf.Core;
using GitWolf.Store;
using Microsoft.UI.Xaml;
using Windows.System;

namespace GitWolf.App;

/// <summary>Resizable panels, the extra keyboard shortcuts and notices.</summary>
public sealed partial class MainWindow
{
    private IntPtr WindowHandle => WinRT.Interop.WindowNative.GetWindowHandle(this);

    /// <summary>Confirms something briefly at the bottom of the window.</summary>
    private void ShowNotice(string message)
    {
        NoticeText.Text = message;
        NoticeAnimation.Begin();
    }

    private void SetUpPanels()
    {
        ToolDialogs.Window = WindowHandle;
        Changes.SpellCheck = _settings.State.SpellCheck;
        ShowPanelSizes(_settings.State);
        SetUpHeights();

        // The widths follow the pointer and are saved once, when the drag ends.
        var sidebar = _settings.State.SidebarWidth;
        var share = _settings.State.ListShare;
        SidebarSplitter.Dragged += dx =>
        {
            sidebar = Math.Clamp(SidebarColumn.ActualWidth + dx, 160, 600);
            SidebarColumn.Width = new GridLength(sidebar);
        };
        SidebarSplitter.Finished += () => _settings.Update(_settings.State with { SidebarWidth = sidebar });
        SidebarSplitter.Reset += () => ResetPanels(_settings.State with { SidebarWidth = new SettingsState().SidebarWidth });
        ListSplitter.Dragged += dx =>
        {
            var total = ListColumn.ActualWidth + DetailColumn.ActualWidth;
            if (total <= 0) return;
            share = Math.Clamp((ListColumn.ActualWidth + dx) / total, 0.15, 0.85);
            ShowShare(share);
        };
        ListSplitter.Finished += () => _settings.Update(_settings.State with { ListShare = share });
        ListSplitter.Reset += () => ResetPanels(_settings.State with { ListShare = new SettingsState().ListShare });

        void ResetPanels(SettingsState next)
        {
            _settings.Update(next);
            (sidebar, share) = (_settings.State.SidebarWidth, _settings.State.ListShare);
            ShowPanelSizes(_settings.State);
        }
    }

    /// <summary>The commit message box and a commit's file list can be dragged taller or shorter.</summary>
    private void SetUpHeights()
    {
        var message = _settings.State.MessageHeight;
        var files = _settings.State.FilesHeight;
        // A saved height never crowds out the rest of a smaller window.
        double MessageLimit() => Math.Max(60, Panels.ActualHeight - 260);
        double FilesLimit() => Math.Max(52, Panels.ActualHeight - 360);
        void Show()
        {
            Changes.MessageHeight = Math.Min(message, MessageLimit());
            Detail.SetFilesHeight(files > 0 ? Math.Min(files, FilesLimit()) : null);
        }
        Panels.SizeChanged += (_, _) => Show();

        // The message box is below its gap, so dragging up makes it taller.
        Changes.HeightSplitter.Dragged += dy =>
        {
            message = Math.Clamp(Changes.MessageHeight - dy, 60, Math.Min(600, MessageLimit()));
            Show();
        };
        Changes.HeightSplitter.Finished += () => _settings.Update(_settings.State with { MessageHeight = message });
        Changes.HeightSplitter.Reset += () =>
        {
            message = new SettingsState().MessageHeight;
            _settings.Update(_settings.State with { MessageHeight = message });
            Show();
        };
        Detail.HeightSplitter.Dragged += dy =>
        {
            files = Math.Clamp(Detail.FilesListHeight + dy, 52, Math.Min(800, FilesLimit()));
            Show();
        };
        Detail.HeightSplitter.Finished += () => _settings.Update(_settings.State with { FilesHeight = files });
        Detail.HeightSplitter.Reset += () =>
        {
            files = 0;
            _settings.Update(_settings.State with { FilesHeight = 0 });
            Show();
        };
    }

    private void ShowPanelSizes(SettingsState state)
    {
        SidebarColumn.Width = new GridLength(state.SidebarWidth);
        ShowShare(state.ListShare);
    }

    private void ShowShare(double share)
    {
        ListColumn.Width = new GridLength(share, GridUnitType.Star);
        DetailColumn.Width = new GridLength(1 - share, GridUnitType.Star);
    }

    private void AddMoreShortcuts(Action<VirtualKey, VirtualKeyModifiers, Action> add)
    {
        const VirtualKeyModifiers control = VirtualKeyModifiers.Control;
        const VirtualKeyModifiers shifted = control | VirtualKeyModifiers.Shift;
        const VirtualKeyModifiers alternate = control | VirtualKeyModifiers.Menu;
        add(VirtualKey.O, shifted, () => _ = CreateAsync(clone: true));
        add(VirtualKey.N, shifted, () => _ = CreateAsync(clone: false));
        add(VirtualKey.W, shifted, () =>
        {
            if (_store is { IsBusy: false } store) _workspace.Close(store);
        });
        add(VirtualKey.R, control, () => _ = _store?.RequestRefresh());
        add(VirtualKey.G, shifted, () => Idle?.OpenOnWeb(new WebTarget.Repository()));
        add(VirtualKey.Z, alternate, () =>
        {
            if (Idle is { } store) _ = HistoryDialogs.UndoAsync(Root.XamlRoot, store);
        });
        add(VirtualKey.Number1, alternate, () => ShowMode(StoreMode.History));
        add(VirtualKey.Number2, alternate, () => ShowMode(StoreMode.Changes));
        add(VirtualKey.Tab, control, () => CycleRepository(1));
        add(VirtualKey.Tab, shifted, () => CycleRepository(-1));
        for (var i = 0; i < 9; i++)
        {
            var index = i;
            add(VirtualKey.Number1 + i, control, () =>
            {
                if (index < _workspace.Repos.Count) _workspace.Select(_workspace.Repos[index]);
            });
        }
    }

    private void ShowMode(StoreMode mode)
    {
        if (_store is { IsLoaded: true } store) store.Mode = mode;
    }

    private void CycleRepository(int step)
    {
        var repos = _workspace.Repos;
        if (repos.Count == 0) return;
        var current = 0;
        for (var i = 0; i < repos.Count; i++)
            if (ReferenceEquals(repos[i], _store)) current = i;
        _workspace.Select(repos[(current + step + repos.Count) % repos.Count]);
    }
}
