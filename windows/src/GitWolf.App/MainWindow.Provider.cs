using GitWolf.App.Services;
using GitWolf.App.Views;
using GitWolf.Core;
using GitWolf.Store;
using Microsoft.UI.Xaml;

namespace GitWolf.App;

/// <summary>Pull requests, issues, forking, notifications and private profile pictures.</summary>
public sealed partial class MainWindow
{
    private NotificationsStore _notifications = null!;

    /// <summary>Called once from the constructor, after the workspace exists.</summary>
    private void AttachProvider()
    {
        var accounts = _settings.Accounts;
        _notifications = new NotificationsStore(accounts);
        _notifications.Changed += () => TopBar.ShowUnread(_notifications.UnreadCount);
        TopBar.NotificationsRequested += ShowNotifications;
        // Runs after the workspace has updated the repositories, which subscribed first.
        accounts.Changed += () =>
        {
            Avatars.Forget();
            ShowAll();
            _ = _notifications.RefreshAsync();
        };
        // Polling waits for the window, so awaits resume on the UI thread.
        Root.Loaded += (_, _) => _notifications.StartPolling();
    }

    private void ShowNotifications() => _ = ProviderDialogs.NotificationsAsync(Root.XamlRoot, _notifications);

    private static CollabKind? CollabKindOf(StoreMode mode) => mode switch
    {
        StoreMode.PullRequests => CollabKind.PullRequest,
        StoreMode.Issues => CollabKind.Issue,
        _ => null,
    };

    private void ShowCollab()
    {
        if (_store is not { } store) return;
        var kind = CollabKindOf(store.Mode);
        // The new remote may be on a provider without this list.
        if (kind is { } wanted && !store.Supports(wanted))
        {
            store.Mode = StoreMode.History;
            return;
        }
        CollabList.Visibility = CollabDetail.Visibility = When(kind is not null);
        if (kind is not { } shown) return;
        CollabList.Show(store, shown);
        CollabDetail.Show(store, shown);
    }

    /// <summary>A saved github.com account also finds the authors of private repositories.</summary>
    private void LoadAvatars(RepositoryStore store) =>
        _ = Avatars.LoadAsync(store.RemoteLocation, store.Commits, _settings.Accounts);

    private void AddProviderItems(List<PaletteItem> items, RepositoryStore store)
    {
        void Add(Icons.Shape glyph, string title, string subtitle, Action run) =>
            items.Add(new PaletteItem(glyph, title, subtitle, run));
        void Create(CollabKind kind, string word) => Add(Icons.Plus, $"New {word}…", "Repository action",
            () => _ = ProviderDialogs.NewCollabAsync(Root.XamlRoot, store, kind));

        if (store.Supports(CollabKind.PullRequest))
        {
            var title = store.PullRequestsTitle.ToLowerInvariant();
            Add(Icons.Pull, $"Show {title}", "View", () => store.Mode = StoreMode.PullRequests);
            if (store.HasProviderAccount) Create(CollabKind.PullRequest, title.TrimEnd('s'));
        }
        if (store.Supports(CollabKind.Issue))
        {
            Add(Icons.File, "Show issues", "View", () => store.Mode = StoreMode.Issues);
            if (store.HasProviderAccount) Create(CollabKind.Issue, "issue");
        }
        if (store.CanFork)
            Add(Icons.Branch, "Fork repository…", "Repository action",
                () => _ = ProviderDialogs.ForkAsync(Root.XamlRoot, store));
        Add(Icons.File, "Notifications", "App", ShowNotifications);
    }
}
