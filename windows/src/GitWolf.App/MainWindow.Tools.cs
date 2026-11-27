using GitWolf.App.Services;
using GitWolf.Core;
using GitWolf.Store;
using Microsoft.UI.Xaml;
using Windows.System;

namespace GitWolf.App;

/// <summary>Resizable panels and the extra keyboard shortcuts.</summary>
public sealed partial class MainWindow
{
    private IntPtr WindowHandle => WinRT.Interop.WindowNative.GetWindowHandle(this);

    private void SetUpPanels()
    {
        ToolDialogs.Window = WindowHandle;
        Changes.SpellCheck = _settings.State.SpellCheck;
        ShowPanelSizes(_settings.State);

        // The widths follow the pointer and are saved once, when the drag ends.
        var sidebar = _settings.State.SidebarWidth;
        var share = _settings.State.ListShare;
        SidebarSplitter.Dragged += dx =>
        {
            sidebar = Math.Clamp(SidebarColumn.ActualWidth + dx, 180, 480);
            SidebarColumn.Width = new GridLength(sidebar);
        };
        SidebarSplitter.Finished += () => _settings.Update(_settings.State with { SidebarWidth = sidebar });
        SidebarSplitter.Reset += () => ResetPanels(_settings.State with { SidebarWidth = new SettingsState().SidebarWidth });
        ListSplitter.Dragged += dx =>
        {
            var total = ListColumn.ActualWidth + DetailColumn.ActualWidth;
            if (total <= 0) return;
            share = Math.Clamp((ListColumn.ActualWidth + dx) / total, 0.2, 0.8);
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
