using GitSync.Core;
using Xunit;

namespace GitSyncCore.Tests;

// Ported from RepositoryIntegrationTests.commitFlowEndToEnd in
// apple/Tests/GitSyncCoreTests/GitSyncCoreTests.swift — runs real git in a throwaway temp repo.
public sealed class GitRunnerTests : IDisposable
{
    private readonly string _dir;

    public GitRunnerTests()
    {
        _dir = Path.Combine(Path.GetTempPath(), $"gitsync-{Guid.NewGuid()}");
        Directory.CreateDirectory(_dir);
    }

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch { /* best effort */ }
    }

    [Fact]
    public async Task RunAsync_InitAndStatus_Succeeds()
    {
        var runner = new GitRunner(_dir);
        await runner.RunAsync(["init", "-b", "main"]);
        await runner.RunAsync(["config", "user.name", "Tester"]);
        await runner.RunAsync(["config", "user.email", "t@example.com"]);

        File.WriteAllText(Path.Combine(_dir, "a.txt"), "hello\n");

        var status = await runner.RunStringAsync(["status", "--porcelain=v2", "-z"], readOnly: true);
        Assert.Contains("a.txt", status);
    }

    [Fact]
    public async Task RunAsync_NonZeroExit_ThrowsGitException()
    {
        var runner = new GitRunner(_dir);
        await runner.RunAsync(["init", "-b", "main"]);

        var ex = await Assert.ThrowsAsync<GitException>(() => runner.RunAsync(["show", "does-not-exist"]));
        Assert.NotEqual(0, ex.ExitCode);
    }

    [Fact]
    public async Task RunAsync_AllowedExitCodes_DoesNotThrow()
    {
        var runner = new GitRunner(_dir);
        File.WriteAllText(Path.Combine(_dir, "one.txt"), "a\n");
        File.WriteAllText(Path.Combine(_dir, "two.txt"), "b\n");

        // `git diff --no-index` returns 1 when the files differ — exercised in GitRepository
        // for untracked/no-index diffs, so callers must be able to allow it explicitly.
        await Assert.ThrowsAsync<GitException>(() =>
            runner.RunAsync(["diff", "--no-index", "one.txt", "two.txt"]));

        var data = await runner.RunAsync(
            ["diff", "--no-index", "one.txt", "two.txt"],
            allowedExitCodes: new HashSet<int> { 0, 1 });
        Assert.NotEmpty(data);
    }
}

public sealed class CommitModelTests
{
    [Fact]
    public void ShortHash_TruncatesToSeven()
    {
        var commit = new Commit("abcdef0123456", [], "A", "a@x.com", DateTimeOffset.UnixEpoch, "s", []);
        Assert.Equal("abcdef0", commit.ShortHash);
    }

    [Fact]
    public void IsMerge_TrueWhenMultipleParents()
    {
        var commit = new Commit("h", ["p1", "p2"], "A", "a@x.com", DateTimeOffset.UnixEpoch, "s", []);
        Assert.True(commit.IsMerge);
    }
}
