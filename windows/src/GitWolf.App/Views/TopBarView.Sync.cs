using GitWolf.App.Services;
using GitWolf.Core;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;

namespace GitWolf.App.Views;

// Right-click (or the menu key) on Pull and Push offers the other ways to do them.
public sealed partial class TopBarView
{
    private void AddSyncMenus()
    {
        PullButton.ContextFlyout = Menu(menu =>
        {
            if (_store is not { } store) return;
            Add(menu, "Pull (merge)", () => _ = store.PullAsync(PullStrategy.Merge));
            Add(menu, "Pull (rebase)", () => _ = store.PullAsync(PullStrategy.Rebase));
            Add(menu, "Pull (fast-forward only)", () => _ = store.PullAsync(PullStrategy.FastForwardOnly));
        });
        PushButton.ContextFlyout = Menu(menu =>
        {
            if (_store is not { } store) return;
            var onBranch = store.Status.Branch is not null;
            Add(menu, "Push", () => _ = store.PushAsync());
            Add(menu, "Push with tags", () => _ = store.PushAsync(new PushOptions(IncludeTags: true)));
            Add(menu, "Force push (with lease)…",
                () => _ = RemoteDialogs.ForcePushAsync(XamlRoot, store, null), onBranch);
            if (store.Remotes.Count > 1 && onBranch)
            {
                menu.Items.Add(new MenuFlyoutSeparator());
                foreach (var remote in store.Remotes)
                    Add(menu, $"Push to {remote}", () => _ = store.PushAsync(new PushOptions(Remote: remote)));
            }
            menu.Items.Add(new MenuFlyoutSeparator());
            Add(menu, "Manage remotes…", () => _ = RemoteDialogs.ManageAsync(XamlRoot, store));
        });
    }

    /// <summary>A menu filled each time it opens, so it never has to be kept in step with the repository.</summary>
    private static MenuFlyout Menu(Action<MenuFlyout> fill)
    {
        var menu = new MenuFlyout { Placement = FlyoutPlacementMode.BottomEdgeAlignedRight };
        menu.Opening += (_, _) =>
        {
            menu.Items.Clear();
            fill(menu);
        };
        return menu;
    }

    private static void Add(MenuFlyout menu, string text, Action run, bool enabled = true)
    {
        var item = new MenuFlyoutItem { Text = text, IsEnabled = enabled };
        item.Click += (_, _) => run();
        menu.Items.Add(item);
    }
}
