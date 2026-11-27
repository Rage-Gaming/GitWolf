using GitWolf.Core;

namespace GitWolf.Store;

// The offer to open a pull request after a push.
public sealed partial class RepositoryStore
{
    private static readonly string[] LongLivedBranches = ["main", "master", "develop", "trunk"];

    /// <summary>Counts offers, so an old one running out doesn't take a newer one with it.</summary>
    private int _pushOfferVersion;

    /// <summary>How long an offer stays up.</summary>
    public TimeSpan PushOfferLifetime { get; set; } = TimeSpan.FromSeconds(30);

    /// <summary>The branch just pushed that a pull request can be opened for.</summary>
    public string? PushOffer { get; private set; }

    public void DismissPushOffer()
    {
        if (PushOffer is not null) SetPushOffer(null);
    }

    /// <param name="pushed">The status the push started from.</param>
    private void OfferPullRequest(WorkingStatus pushed)
    {
        if (pushed.Branch is not { } branch || branch != Status.Branch || LongLivedBranches.Contains(branch)) return;
        // Without an account the form could not be sent.
        if (Account is not { } account || RemoteLocation?.Host is not { } host
            || !account.Kind.SupportsWriting(CollabKind.PullRequest, host)) return;
        // A first push can't have a pull request yet. Later pushes only when the loaded list shows none for it.
        var known = PullRequests.Items;
        if (pushed.Upstream is not null
            && (known.Count == 0 || known.Any(i => i.SourceBranch == branch && i.State == CollabState.Open))) return;
        SetPushOffer(branch);
        _ = ExpirePushOfferAsync(_pushOfferVersion);
    }

    private void SetPushOffer(string? branch)
    {
        _pushOfferVersion++;
        PushOffer = branch;
        Notify(nameof(PushOffer));
    }

    private async Task ExpirePushOfferAsync(int version)
    {
        try
        {
            await Task.Delay(PushOfferLifetime, _lifetime.Token);
        }
        catch (OperationCanceledException) when (_lifetime.IsCancellationRequested)
        {
            return;
        }
        if (version == _pushOfferVersion) DismissPushOffer();
    }
}
