using GitWolf.Core;
using Xunit;

namespace GitWolfCore.Tests;

// Ported from SyncTests in GitWolfCoreTests.swift; shares RemoteTests' server and two clones.
public sealed partial class RemoteTests
{
    private async Task TheyPushAsync()
    {
        await CommitAsync(Other, "theirs.txt", "theirs\n");
        await new GitRunner(Other).RunAsync(["push"]);
    }

    private static async Task PushAsync(GitRepository repo, PushOptions? options = null) =>
        await repo.PushAsync(await repo.StatusAsync(), await repo.RemotesAsync(), options ?? new PushOptions());

    private static async Task<ForcePushPlan> PlanAsync(GitRepository repo, string? remote = null) =>
        await repo.PlanForcePushAsync(await repo.StatusAsync(), await repo.RemotesAsync(), remote);

    private async Task<string> ServerTipAsync(string branch = "main") =>
        (await new GitRunner(Server).RunStringAsync(["log", "-1", "--format=%s", branch])).Trim();

    [Fact]
    public async Task AForcePushPlanListsWhatWouldBeLost()
    {
        await InitAsync();
        await TheyPushAsync();
        await CommitAsync(Work, "mine.txt", "mine\n");
        var repo = new GitRepository(Work);

        var plan = await PlanAsync(repo);
        Assert.Equal(("main", "origin", "main", 1), (plan.Branch, plan.Remote, plan.Target, plan.LostCount));
        Assert.EndsWith("theirs.txt", Assert.Single(plan.Lost));

        await PushAsync(repo, new PushOptions(Force: plan));
        Assert.Equal("mine.txt", await ServerTipAsync());
    }

    [Fact]
    public async Task AFetchAfterConfirmingDoesNotWidenAForcePush()
    {
        await InitAsync();
        await CommitAsync(Work, "mine.txt", "mine\n");
        var repo = new GitRepository(Work);
        var plan = await PlanAsync(repo);

        // They push after the confirmation, and a background fetch sees it.
        await TheyPushAsync();
        await repo.FetchRemoteAsync("origin");

        var error = await Assert.ThrowsAsync<GitException>(
            () => PushAsync(repo, new PushOptions(Force: plan)));
        Assert.True(error.IsPushRejected());
        Assert.Equal("theirs.txt", await ServerTipAsync());
    }

    [Fact]
    public async Task ForcePushingANewBranchIsRefusedIfSomeoneElseCreatedIt()
    {
        await InitAsync();
        var repo = new GitRepository(Work);
        await new GitRunner(Work).RunAsync(["switch", "-c", "topic"]);
        await CommitAsync(Work, "mine.txt", "mine\n");
        var plan = await PlanAsync(repo);
        Assert.Null(plan.Expected);

        await new GitRunner(Other).RunAsync(["push", "origin", "main:refs/heads/topic"]);

        await Assert.ThrowsAsync<GitException>(() => PushAsync(repo, new PushOptions(Force: plan)));
        Assert.Equal("base.txt", await ServerTipAsync("topic"));
    }

    [Fact]
    public async Task AForcePushPlanOnlyAppliesToItsBranch()
    {
        await InitAsync();
        var repo = new GitRepository(Work);
        var plan = await PlanAsync(repo);
        await new GitRunner(Work).RunAsync(["switch", "-c", "topic"]);

        await Assert.ThrowsAsync<GitException>(() => PushAsync(repo, new PushOptions(Force: plan)));
    }

    [Fact]
    public async Task ARejectedPushWorksAfterPulling()
    {
        await InitAsync();
        await TheyPushAsync();
        await CommitAsync(Work, "mine.txt", "mine\n");
        var repo = new GitRepository(Work);

        Assert.True((await Assert.ThrowsAsync<GitException>(() => PushAsync(repo))).IsPushRejected());
        await repo.PullAsync(PullStrategy.Rebase);
        await PushAsync(repo);
        Assert.Equal(0, (await repo.StatusAsync()).Ahead);
    }

    [Fact]
    public async Task FastForwardOnlyRefusesADivergedBranch()
    {
        await InitAsync();
        await TheyPushAsync();
        await CommitAsync(Work, "mine.txt", "mine\n");

        var error = await Assert.ThrowsAsync<GitException>(
            () => new GitRepository(Work).PullAsync(PullStrategy.FastForwardOnly));

        Assert.True(error.IsDivergedPull());
    }

    [Fact]
    public async Task ForcePushingReplacesOnlyTheTrackedBranch()
    {
        await InitAsync();
        var git = new GitRunner(Work);
        // `push.default=matching` would force every branch the server also has.
        await git.RunAsync(["push", "origin", "main:refs/heads/second"]);
        await git.RunAsync(["branch", "second", "main"]);
        await git.RunAsync(["config", "push.default", "matching"]);
        await git.RunAsync(["commit", "--amend", "-m", "rewritten"]);
        await git.RunAsync(["branch", "-f", "second", "HEAD"]);

        var repo = new GitRepository(Work);
        await PushAsync(repo, new PushOptions(Force: await PlanAsync(repo)));

        var server = new GitRunner(Server);
        Assert.Equal("rewritten", (await server.RunStringAsync(["log", "-1", "--format=%s", "main"])).Trim());
        Assert.Equal("base.txt", (await server.RunStringAsync(["log", "-1", "--format=%s", "second"])).Trim());
    }

    [Fact]
    public async Task PushingWithTagsAndToASecondRemote()
    {
        await InitAsync();
        var backup = Path.Combine(_dir, "backup.git");
        await new GitRunner(_dir).RunAsync(["init", "--bare", "-b", "main", backup]);
        var repo = new GitRepository(Work);
        await repo.AddRemoteAsync("backup", backup);
        await new GitRunner(Work).RunAsync(["tag", "v1"]);

        await PushAsync(repo, new PushOptions(Remote: "backup", IncludeTags: true));
        Assert.Contains("v1", await new GitRunner(backup).RunStringAsync(["tag"]));
        Assert.Equal("origin/main", (await repo.StatusAsync()).Upstream);

        await PushAsync(repo, new PushOptions(Remote: "backup", SetUpstream: true));
        Assert.Equal("backup/main", (await repo.StatusAsync()).Upstream);
    }

    [Fact]
    public async Task RemotesAreAddedEditedAndRemoved()
    {
        await InitAsync();
        var repo = new GitRepository(Work);
        await repo.AddRemoteAsync("backup", "git@example.com:a.git");
        Assert.Equal("git@example.com:a.git",
            (await repo.RemoteInfosAsync()).Single(r => r.Name == "backup").FetchUrl);

        await repo.RenameRemoteAsync("backup", "mirror");
        await repo.SetRemoteUrlAsync("mirror", "https://example.com/b.git");
        var mirror = (await repo.RemoteInfosAsync()).Single(r => r.Name == "mirror");
        Assert.Equal("https://example.com/b.git", mirror.FetchUrl);
        Assert.Equal(mirror.FetchUrl, mirror.PushUrl);

        await repo.RemoveRemoteAsync("mirror");
        Assert.Equal(["origin"], (await repo.RemoteInfosAsync()).Select(r => r.Name));
    }

    [Theory]
    [InlineData("x y", "https://e.com/a")]
    [InlineData("-bad", "https://e.com/a")]
    [InlineData("ok", "https://me:secret@e.com/a")]
    [InlineData("ok", "https://:secret@e.com/a")]
    [InlineData("ok", "--upload-pack=evil")]
    [InlineData("ok", "ext::sh -c id")]
    [InlineData("ok", "   ")]
    public async Task UnsafeRemotesAreRefused(string name, string url)
    {
        await InitAsync();

        await Assert.ThrowsAsync<GitException>(() => new GitRepository(Work).AddRemoteAsync(name, url));
    }

    [Theory]
    [InlineData("https://me:pw@e.com/a", "https://me@e.com/a")]
    [InlineData("https://me:p@ss@e.com/a", "https://me@e.com/a")]
    [InlineData("https://:token@e.com/a", "https://e.com/a")]
    [InlineData("https://e.com:8443/a", "https://e.com:8443/a")]
    [InlineData("git@e.com:a.git", "git@e.com:a.git")]
    public void PasswordsAreHidden(string url, string shown) => Assert.Equal(shown, GitRepository.Redact(url));
}
