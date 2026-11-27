using GitWolf.App.Services;
using GitWolf.Core;
using Microsoft.UI.Xaml;

namespace GitWolf.App;

/// <summary>The offer to open a pull request after a push. Ported from PushOfferBanner in RepositoryView.swift.</summary>
public sealed partial class MainWindow
{
    private void ShowPushOffer()
    {
        var branch = _store?.PushOffer;
        PushOfferPill.Visibility = When(branch is not null);
        if (_store is not { } store || branch is null) return;
        PushOfferBranch.Text = branch;
        PushOfferOpen.Content = $"Open {store.PullRequestsTitle.TrimEnd('s')}";
    }

    private void OnOpenPushOffer(object sender, RoutedEventArgs e)
    {
        if (_store is not { PushOffer: not null } store) return;
        store.DismissPushOffer();
        _ = ProviderDialogs.NewCollabAsync(Root.XamlRoot, store, CollabKind.PullRequest);
    }

    private void OnDismissPushOffer(object sender, RoutedEventArgs e) => _store?.DismissPushOffer();
}
