using GitWolf.App.Services;
using GitWolf.App.Views;
using GitWolf.Core;
using GitWolf.Store;

namespace GitWolf.App;

/// <summary>Refused pushes, and the sync actions in the jump palette.</summary>
public sealed partial class MainWindow
{
    private void ShowRejectedPush()
    {
        if (_store is not { RejectedPush: { } options } store) return;
        store.RejectedPush = null;
        _ = RemoteDialogs.PushRejectedAsync(Root.XamlRoot, store, options);
    }

    private void AddSyncItems(List<PaletteItem> items, RepositoryStore store)
    {
        void Add(Icons.Shape glyph, string title, Action run) =>
            items.Add(new PaletteItem(glyph, title, "Sync", run));
        Add(Icons.Pull, "Pull (rebase)", () => _ = store.PullAsync(PullStrategy.Rebase));
        Add(Icons.Pull, "Pull (fast-forward only)", () => _ = store.PullAsync(PullStrategy.FastForwardOnly));
        Add(Icons.Push, "Push with tags", () => _ = store.PushAsync(new PushOptions(IncludeTags: true)));
        if (store.Status.Branch is not null)
            Add(Icons.Push, "Force push (with lease)…",
                () => _ = RemoteDialogs.ForcePushAsync(Root.XamlRoot, store, null));
        Add(Icons.Branch, "Manage remotes…", () => _ = RemoteDialogs.ManageAsync(Root.XamlRoot, store));
    }
}
