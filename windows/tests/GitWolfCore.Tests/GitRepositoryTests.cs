using GitWolf.Core;
using Xunit;

namespace GitWolfCore.Tests;

// Ported from RepositoryIntegrationTests and CreateRepositoryTests in
// apple/Tests/GitWolfCoreTests/GitWolfCoreTests.swift.
public sealed class GitRepositoryTests
{
    [Fact]
    public async Task CommitFlowEndToEnd()
    {
        var dir = Path.Combine(Path.GetTempPath(), $"gitwolf-{Guid.NewGuid()}");
        Directory.CreateDirectory(dir);
        try
        {
            var runner = new GitRunner(dir);
            await runner.RunAsync(["init", "-b", "main"]);
            await runner.RunAsync(["config", "user.name", "Tester"]);
            await runner.RunAsync(["config", "user.email", "t@example.com"]);

            var repo = await GitRepository.OpenAsync(dir);
            File.WriteAllText(Path.Combine(dir, "a.txt"), "hello\n");

            var status = await repo.StatusAsync();
            Assert.True(status.IsUnborn);
            Assert.Equal(["a.txt"], status.Untracked.Select(f => f.Path));

            await repo.StageAsync(["a.txt"]);
            await repo.CommitAsync("first", amend: false);
            File.WriteAllText(Path.Combine(dir, "a.txt"), "hello\nworld\n");

            status = await repo.StatusAsync();
            Assert.Equal(["a.txt"], status.Unstaged.Select(f => f.Path));

            var diff = await repo.DiffAsync(new DiffTarget(DiffSource.Unstaged, "a.txt"));
            Assert.Equal(1, diff.Additions);

            var snap = await repo.SnapshotAsync(50);
            Assert.Single(snap.Commits);
            Assert.Equal("first", snap.Commits[0].Subject);
            Assert.True(snap.LocalBranches.FirstOrDefault()?.IsCurrent);

            var files = await repo.FilesAsync(snap.Commits[0]);
            Assert.Equal(["a.txt"], files.Select(f => f.Path));
        }
        finally
        {
            try { Directory.Delete(dir, recursive: true); } catch { /* best effort */ }
        }
    }

    [Theory]
    [InlineData("https://github.com/ipuppyyt/git-sync.git", "git-sync")]
    [InlineData("git@github.com:org/repo", "repo")]
    [InlineData("https://host/a/b/", "b")]
    [InlineData("  /tmp/local/proj.git  ", "proj")]
    [InlineData("", "")]
    public void SuggestsNamesFromCloneUrls(string url, string expected)
    {
        Assert.Equal(expected, GitRepository.SuggestedName(url));
    }

    [Fact]
    public async Task InitialisesAndClonesRepository()
    {
        var baseDir = Path.Combine(Path.GetTempPath(), $"gitwolf-clone-{Guid.NewGuid()}");
        try
        {
            var sourceDir = Path.Combine(baseDir, "origin", "nested");
            var source = await GitRepository.InitializeAsync(sourceDir, "trunk");
            var runner = new GitRunner(source);
            await runner.RunAsync(["config", "user.name", "T"]);
            await runner.RunAsync(["config", "user.email", "t@example.com"]);
            File.WriteAllText(Path.Combine(source, "a.txt"), "x\n");
            await runner.RunAsync(["add", "."]);
            await runner.RunAsync(["commit", "-m", "init"]);
            var branch = await runner.RunStringAsync(["branch", "--show-current"]);
            Assert.Equal("trunk", branch.Trim());

            var clones = Path.Combine(baseDir, "clones");
            Directory.CreateDirectory(clones);
            var dest = await GitRepository.CloneAsync(source, clones, "copy");
            Assert.True(File.Exists(Path.Combine(dest, "a.txt")));

            // Cloning again into the same non-empty folder is refused.
            await Assert.ThrowsAsync<GitException>(() => GitRepository.CloneAsync(source, clones, "copy"));
        }
        finally
        {
            try { Directory.Delete(baseDir, recursive: true); } catch { /* best effort */ }
        }
    }
}
