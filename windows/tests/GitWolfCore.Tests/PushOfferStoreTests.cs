using System.Net;
using System.Text;
using GitWolf.Core;
using GitWolf.Store;
using Xunit;
using static GitWolfCore.Tests.RepositoryStoreTests;

namespace GitWolfCore.Tests;

public sealed class PushOfferStoreTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("gitwolf-offer-").FullName;
    private string Work => Path.Combine(_dir, "work");

    public void Dispose()
    {
        foreach (var file in Directory.EnumerateFiles(_dir, "*", SearchOption.AllDirectories))
            File.SetAttributes(file, FileAttributes.Normal);
        Directory.Delete(_dir, recursive: true);
    }

    private sealed class Settings(bool signedIn) : IStoreSettings
    {
        public string PullRequests = "[]";

        public int CommitPageSize => 100;
        public int AutoFetchMinutes => 0;
        public GitRepository Configure(GitRepository repo) => repo;
        public ProviderAccount? AccountForHost(string host) =>
            signedIn ? new ProviderAccount(ProviderKind.GitHub, host, "me") : null;
        public Task<string?> SecretAsync(ProviderAccount account) => Task.FromResult<string?>("test-token");

        public HttpTransport? Transport => request =>
        {
            var url = request.RequestUri!.AbsoluteUri;
            var body = url.Contains("/pulls") ? PullRequests
                : url.Contains("check-runs") ? """{"check_runs":[]}""" : """{"statuses":[]}""";
            return Task.FromResult((Encoding.UTF8.GetBytes(body), HttpStatusCode.OK));
        };
    }

    /// <summary>A repository on a branch, fetching from a provider address but pushing to a local folder.</summary>
    private async Task<RepositoryStore> OpenAsync(Settings settings, string branch)
    {
        Directory.CreateDirectory(Work);
        var git = new GitRunner(Work);
        await git.RunAsync(["init", "--bare", "-b", "main", Path.Combine(_dir, "server.git")]);
        await git.RunAsync(["init", "-b", branch]);
        await git.RunAsync(["config", "user.name", "T"]);
        await git.RunAsync(["config", "user.email", "t@example.invalid"]);
        await git.RunAsync(["commit", "--allow-empty", "-m", "base"]);
        await git.RunAsync(["remote", "add", "origin", "https://github.com/o/r.git"]);
        await git.RunAsync(["config", "remote.origin.pushurl", Path.Combine(_dir, "server.git")]);
        var store = new RepositoryStore(new GitRepository(Work), settings, _ => { });
        await store.RequestRefresh();
        // The remote's location is read in the background.
        for (var i = 0; i < 200 && store.RemoteLocation is null; i++) await Task.Delay(50);
        return store;
    }

    private async Task PushNewCommitAsync(RepositoryStore store)
    {
        await new GitRunner(Work).RunAsync(["commit", "--allow-empty", "-m", "next"]);
        await store.RequestRefresh();
        Assert.True(await store.PushAsync(), store.ErrorMessage);
    }

    [Fact]
    public void AFirstPushOffersAPullRequestUntilTheBranchChanges() => SingleThread.Run(async () =>
    {
        using var store = await OpenAsync(new Settings(signedIn: true), "feature");
        Assert.True(await store.PushAsync(), store.ErrorMessage);
        Assert.Equal("feature", store.PushOffer);

        await store.RequestRefresh();
        Assert.Equal("feature", store.PushOffer);
        await new GitRunner(Work).RunAsync(["switch", "-c", "other"]);
        await store.RequestRefresh();
        Assert.Null(store.PushOffer);
        await SettleAsync(store);
    });

    [Fact]
    public void ALaterPushOffersOnlyWhenTheLoadedListShowsNoneForTheBranch() => SingleThread.Run(async () =>
    {
        var settings = new Settings(signedIn: true);
        using var store = await OpenAsync(settings, "feature");
        Assert.True(await store.PushAsync(), store.ErrorMessage);
        await store.RequestRefresh();
        store.DismissPushOffer();

        // Nothing loaded yet, so there may be one already.
        await PushNewCommitAsync(store);
        Assert.Null(store.PushOffer);

        settings.PullRequests = Pulls("another");
        await store.PullRequests.LoadAsync();
        await PushNewCommitAsync(store);
        Assert.Equal("feature", store.PushOffer);

        store.DismissPushOffer();
        settings.PullRequests = Pulls("feature");
        await store.PullRequests.LoadAsync();
        await PushNewCommitAsync(store);
        Assert.Null(store.PushOffer);
        await SettleAsync(store);
    });

    [Theory]
    [InlineData("main", true)]
    [InlineData("feature", false)]
    public void NoOfferForALongLivedBranchOrWithoutAnAccount(string branch, bool signedIn) =>
        SingleThread.Run(async () =>
        {
            using var store = await OpenAsync(new Settings(signedIn), branch);
            Assert.True(await store.PushAsync(), store.ErrorMessage);
            Assert.Null(store.PushOffer);
            await SettleAsync(store);
        });

    [Fact]
    public void TheOfferRunsOut() => SingleThread.Run(async () =>
    {
        using var store = await OpenAsync(new Settings(signedIn: true), "feature");
        store.PushOfferLifetime = TimeSpan.FromMilliseconds(100);
        Assert.True(await store.PushAsync(), store.ErrorMessage);
        for (var i = 0; i < 200 && store.PushOffer is not null; i++) await Task.Delay(50);
        Assert.Null(store.PushOffer);
        await SettleAsync(store);
    });

    /// <summary>Waits for the refresh a push starts, so no git process outlives the folder.</summary>
    private static Task SettleAsync(RepositoryStore store) => store.RequestRefresh();

    private static string Pulls(string branch) =>
        $$$"""[{"number":1,"title":"t","state":"open","head":{"ref":"{{{branch}}}"},"base":{"ref":"main"},"user":{"login":"me"}}]""";
}
