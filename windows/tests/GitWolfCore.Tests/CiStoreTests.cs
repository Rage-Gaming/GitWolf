using System.Net;
using System.Text;
using GitWolf.Core;
using GitWolf.Store;
using Xunit;
using static GitWolfCore.Tests.RepositoryStoreTests;

namespace GitWolfCore.Tests;

public sealed class CiStoreTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("gitwolf-ci-").FullName;

    public void Dispose()
    {
        foreach (var file in Directory.EnumerateFiles(_dir, "*", SearchOption.AllDirectories))
            File.SetAttributes(file, FileAttributes.Normal);
        Directory.Delete(_dir, recursive: true);
    }

    private sealed class Settings(bool signedIn) : IStoreSettings
    {
        public string State = "failure";
        public HttpStatusCode Reply = HttpStatusCode.OK;
        public readonly List<string> Calls = [];

        public int CommitPageSize => 100;
        public int AutoFetchMinutes => 0;
        public GitRepository Configure(GitRepository repo) => repo;
        public ProviderAccount? AccountForHost(string host) =>
            signedIn ? new ProviderAccount(ProviderKind.GitHub, host, "me") : null;
        public Task<string?> SecretAsync(ProviderAccount account) => Task.FromResult<string?>("test-token");

        public HttpTransport? Transport => request =>
        {
            var url = request.RequestUri!.AbsoluteUri;
            lock (Calls) Calls.Add($"{request.Method} {url}");
            var status = State == "running" ? "in_progress" : "completed";
            var body = url.Contains("check-runs")
                ? $$"""{"check_runs":[{"name":"build","status":"{{status}}","conclusion":"{{State}}","html_url":"https://github.com/o/r/actions/runs/1/job/2"}]}"""
                : """{"statuses":[]}""";
            return Task.FromResult((Encoding.UTF8.GetBytes(body), Reply));
        };
    }

    private async Task<(RepositoryStore Store, string Head)> OpenAsync(Settings settings)
    {
        var git = new GitRunner(_dir);
        await git.RunAsync(["init", "-b", "main"]);
        await git.RunAsync(["-c", "user.name=T", "-c", "user.email=t@example.invalid", "commit",
            "--allow-empty", "-m", "base"]);
        await git.RunAsync(["remote", "add", "origin", "https://github.com/o/r.git"]);
        var store = new RepositoryStore(new GitRepository(_dir), settings, _ => { });
        await store.RequestRefresh();
        // The remote's location is read in the background.
        for (var i = 0; i < 200 && store.RemoteLocation is null; i++) await Task.Delay(50);
        return (store, store.Status.HeadOid!);
    }

    [Fact]
    public void TheCheckedOutCommitFeedsTheTileAndCanBeRerun() => SingleThread.Run(async () =>
    {
        var settings = new Settings(signedIn: true);
        var (store, head) = await OpenAsync(settings);
        using var _ = store;
        await store.LoadChecksAsync(head, force: true);
        for (var i = 0; i < 200 && store.HeadChecks is null; i++) await Task.Delay(50);
        Assert.Equal(CheckState.Failure, store.HeadChecks);
        Assert.False(store.ShouldPollChecks(head));

        var check = store.Checks(head)!.Checks[0];
        Assert.True(store.CanPerformCi(CiAction.Rerun, check));
        var changes = 0;
        store.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(RepositoryStore.Checks)) changes++; };
        await store.LoadChecksAsync(head, force: true);
        Assert.Equal(0, changes);

        settings.State = "running";
        await store.PerformCiAsync(CiAction.Rerun, head, check);
        Assert.Contains("POST https://api.github.com/repos/o/r/actions/jobs/2/rerun", settings.Calls);
        Assert.Equal(CheckState.Pending, store.HeadChecks);
        Assert.True(store.ShouldPollChecks(head));
        Assert.False(store.IsCiBusy(head, check));
        Assert.Null(store.ErrorMessage);
    });

    [Fact]
    public void WithoutAnAccountNothingIsPolledOrShownOnTheTile() => SingleThread.Run(async () =>
    {
        var settings = new Settings(signedIn: false) { State = "running" };
        var (store, head) = await OpenAsync(settings);
        using var _ = store;
        await store.LoadChecksAsync(head);
        Assert.NotNull(store.Checks(head));
        Assert.Null(store.HeadChecks);
        Assert.False(store.ShouldPollChecks(head, DateTimeOffset.UtcNow));
        Assert.False(store.CanPerformCi(CiAction.Cancel, store.Checks(head)!.Checks[0]));
    });

    [Fact]
    public void ARefusedRequestStopsPolling() => SingleThread.Run(async () =>
    {
        var settings = new Settings(signedIn: true) { Reply = HttpStatusCode.TooManyRequests };
        var (store, head) = await OpenAsync(settings);
        using var _ = store;
        await store.LoadChecksAsync(head, force: true);
        for (var i = 0; i < 200 && store.ShouldPollChecks(head, DateTimeOffset.UtcNow); i++) await Task.Delay(50);
        Assert.False(store.ShouldPollChecks(head, DateTimeOffset.UtcNow));
    });
}
