using GitSync.App.Services;
using GitSync.Core;
using GitSync.Store;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace GitSync.App.Views;

/// <summary>Branch switcher, mode tabs, sync actions and the jump button.</summary>
public sealed partial class TopBarView : UserControl
{
    private RepositoryStore? _store;

    public TopBarView() => InitializeComponent();

    internal event Action? JumpRequested;

    /// <summary>The empty stretch that drags the window.</summary>
    internal UIElement DragRegion => DragArea;

    internal void Show(RepositoryStore store)
    {
        _store = store;
        var status = store.Status;
        BranchName.Text = status.BranchDisplay;
        ShowBranchIcon(status.Branch);
        var history = store.Mode == StoreMode.History;
        HistorySelected.Visibility = history ? Visibility.Visible : Visibility.Collapsed;
        var changes = store.Mode == StoreMode.Changes;
        ChangesSelected.Visibility = changes ? Visibility.Visible : Visibility.Collapsed;
        HistoryTab.Opacity = history ? 1 : 0.6;
        ChangesTab.Opacity = changes ? 1 : 0.6;
        Badge.Visibility = status.ChangeCount > 0 ? Visibility.Visible : Visibility.Collapsed;
        BadgeText.Text = status.ChangeCount.ToString();
        PullCount.Text = status.Behind > 0 ? status.Behind.ToString() : "";
        PushCount.Text = status.Ahead > 0 ? status.Ahead.ToString() : "";
        FetchButton.IsEnabled = PullButton.IsEnabled = PushButton.IsEnabled = BranchButton.IsEnabled = !store.IsBusy;
        StashButton.IsEnabled = !store.IsBusy && !status.IsClean;
    }

    /// <summary>The current branch's icon; the plain branch symbol in the accent colour when detached.</summary>
    private void ShowBranchIcon(string? branch)
    {
        var look = branch is null ? null : FileIcons.BranchNamed(branch);
        BranchIcon.Content = FileIconView.Symbol(look?.Value ?? "arrow.triangle.branch",
            look is null ? Palette.Ref(RefKind.Local) : FileIconView.Brush(look.Color), 14);
    }

    /// <summary>Built when opened, so it never has to be kept in step with the branch list.</summary>
    private void OnBranchMenu(object sender, RoutedEventArgs e)
    {
        if (_store is not { } store) return;
        // Hangs under the pill with their left edges level, as on macOS.
        var menu = new MenuFlyout
        {
            Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.BottomEdgeAlignedLeft,
        };
        foreach (var branch in store.LocalBranches)
        {
            // As on macOS: a check marks the current branch, the others show their icon.
            var look = FileIcons.BranchNamed(branch.Name);
            var item = new MenuFlyoutItem
            {
                Text = branch.Name,
                Icon = branch.IsCurrent
                    ? new FontIcon { Glyph = "\uE73E" }
                    : Icons.Create(SymbolShapes.Get(look.Value!), FileIconView.Brush(look.Color)),
            };
            item.Click += (_, _) =>
            {
                if (!branch.IsCurrent) _ = store.CheckoutAsync(branch);
            };
            menu.Items.Add(item);
        }
        menu.Items.Add(new MenuFlyoutSeparator());
        var create = new MenuFlyoutItem { Text = "New branch…" };
        create.Click += (_, _) => _ = Dialogs.NewBranchAsync(XamlRoot, store, null);
        menu.Items.Add(create);
        menu.ShowAt(BranchButton);
    }

    private void OnTab(object sender, RoutedEventArgs e)
    {
        if (_store is { } store)
            store.Mode = ReferenceEquals(sender, ChangesTab) ? StoreMode.Changes : StoreMode.History;
    }

    private void OnFetch(object sender, RoutedEventArgs e) => _ = _store?.FetchAsync();
    private void OnPull(object sender, RoutedEventArgs e) => _ = _store?.PullAsync();
    private void OnPush(object sender, RoutedEventArgs e) => _ = _store?.PushAsync();
    private void OnJump(object sender, RoutedEventArgs e) => JumpRequested?.Invoke();

    private void OnStash(object sender, RoutedEventArgs e)
    {
        if (_store is { } store) _ = Dialogs.StashAsync(XamlRoot, store);
    }
}
