using GitWolf.Core;
using Xunit;

namespace GitWolfCore.Tests;

public sealed class RemoteTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), $"gitwolf-remote-{Guid.NewGuid()}");
    private string Server => Path.Combine(_dir, "server.git");
    private string Work => Path.Combine(_dir, "work");
    private string Other => Path.Combine(_dir, "other");

    public RemoteTests() => Directory.CreateDirectory(_dir);

    public void Dispose()
    {
        try
        {
            foreach (var file in Directory.EnumerateFiles(_dir, "*", SearchOption.AllDirectories))
                File.SetAttributes(file, FileAttributes.Normal);
            Directory.Delete(_dir, recursive: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // Left in the temporary folder.
        }
    }

    private static async Task ConfigureAsync(string folder)
    {
        var git = new GitRunner(folder);
        await git.RunAsync(["config", "user.name", "Tester"]);
        await git.RunAsync(["config", "user.email", "t@example.com"]);
        await git.RunAsync(["config", "commit.gpgsign", "false"]);
        await git.RunAsync(["config", "tag.gpgsign", "false"]);
        await git.RunAsync(["config", "core.autocrlf", "false"]);
    }

    private static async Task CommitAsync(string folder, string file, string text)
    {
        File.WriteAllText(Path.Combine(folder, file), text);
        var git = new GitRunner(folder);
        await git.RunAsync(["add", "-A"]);
        await git.RunAsync(["commit", "-m", file]);
    }

    /// <summary>A bare server with two clones, "work" and "other".</summary>
    private async Task InitAsync()
    {
        var git = new GitRunner(_dir);
        await git.RunAsync(["init", "--bare", "-b", "main", Server]);
        await git.RunAsync(["init", "-b", "main", Work]);
        await ConfigureAsync(Work);
        await CommitAsync(Work, "base.txt", "base\n");
        var work = new GitRunner(Work);
        await work.RunAsync(["remote", "add", "origin", Server]);
        await work.RunAsync(["push", "-u", "origin", "main"]);
        await git.RunAsync(["clone", Server, Other]);
        await ConfigureAsync(Other);
    }

    private Task<string> ServerRefsAsync() =>
        new GitRunner(Server).RunStringAsync(["for-each-ref", "--format=%(refname)"]);

    [Fact]
    public async Task TagsArePushedAndDeletedOnTheRemoteOnly()
    {
        await InitAsync();
        var repo = new GitRepository(Work);
        var git = new GitRunner(Work);
        await git.RunAsync(["tag", "v1"]);
        await git.RunAsync(["tag", "v2"]);

        await repo.PushTagAsync("v1", "origin");
        Assert.Contains("refs/tags/v1", await ServerRefsAsync());
        Assert.DoesNotContain("refs/tags/v2", await ServerRefsAsync());

        await repo.PushAllTagsAsync("origin");
        Assert.Contains("refs/tags/v2", await ServerRefsAsync());

        await repo.DeleteRemoteTagAsync("v1", "origin");
        Assert.DoesNotContain("refs/tags/v1", await ServerRefsAsync());
        Assert.Contains("v1", await git.RunStringAsync(["tag"]));
    }

    [Fact]
    public async Task DeletingARemoteBranchLeavesATagOfTheSameName()
    {
        await InitAsync();
        var git = new GitRunner(Work);
        await git.RunAsync(["push", "origin", "main:refs/heads/topic", "main:refs/tags/topic"]);

        await new GitRepository(Work).DeleteRemoteBranchAsync("origin", "topic");

        var refs = await ServerRefsAsync();
        Assert.DoesNotContain("refs/heads/topic", refs);
        Assert.Contains("refs/tags/topic", refs);
    }

    [Fact]
    public async Task AnOptionIsNotAcceptedAsARemote()
    {
        await InitAsync();

        await Assert.ThrowsAsync<GitException>(() => new GitRepository(Work).PushAllTagsAsync("--mirror"));
    }

    [Fact]
    public async Task PullingWithRebaseKeepsHistoryLinear()
    {
        await InitAsync();
        await CommitAsync(Other, "theirs.txt", "theirs\n");
        await new GitRunner(Other).RunAsync(["push"]);
        await CommitAsync(Work, "mine.txt", "mine\n");

        await new GitRepository(Work).PullAsync(rebase: true);

        var git = new GitRunner(Work);
        Assert.Equal("0", (await git.RunStringAsync(["rev-list", "--merges", "--count", "HEAD"])).Trim());
        Assert.True(File.Exists(Path.Combine(Work, "theirs.txt")));
    }

    [Fact]
    public async Task ARebaseConflictLeavesTheOperationInProgress()
    {
        await InitAsync();
        await CommitAsync(Other, "base.txt", "theirs\n");
        await new GitRunner(Other).RunAsync(["push"]);
        await CommitAsync(Work, "base.txt", "mine\n");
        var repo = new GitRepository(Work);

        await repo.PullAsync(rebase: true);

        Assert.Equal(OperationKind.Rebase, repo.InProgressOperation()?.Kind);
        // A second pull during the rebase is a real failure.
        await Assert.ThrowsAsync<GitException>(() => repo.PullAsync(rebase: true));
    }

    [Theory]
    [InlineData("origin/feature/x", "origin", "feature/x")]
    [InlineData("team/fork/main", "team/fork", "main")]
    public void RemoteBranchNamesSplitAtTheLongestRemote(string name, string remote, string branch) =>
        Assert.Equal((remote, branch), GitRepository.SplitRemoteBranch(name, ["origin", "team", "team/fork"]));

    [Fact]
    public void AnUnknownRemoteDoesNotSplit() =>
        Assert.Null(GitRepository.SplitRemoteBranch("elsewhere/main", ["origin"]));
}
