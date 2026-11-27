using GitSync.Core;
using Xunit;

namespace GitSyncCore.Tests;

public sealed class DiscardTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), $"gitsync-discard-{Guid.NewGuid()}");

    public DiscardTests() => Directory.CreateDirectory(_dir);

    public void Dispose()
    {
        try
        {
            // Git marks object files read-only.
            foreach (var file in Directory.EnumerateFiles(_dir, "*", SearchOption.AllDirectories))
                File.SetAttributes(file, FileAttributes.Normal);
            Directory.Delete(_dir, recursive: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // Left in the temporary folder.
        }
    }

    private void Write(string file, string text) => File.WriteAllText(Path.Combine(_dir, file), text);
    private string Read(string file) => File.ReadAllText(Path.Combine(_dir, file));

    private async Task<GitRepository> CommittedAsync(params string[] files)
    {
        var git = new GitRunner(_dir);
        await git.RunAsync(["init", "-b", "main"]);
        await git.RunAsync(["config", "user.name", "Tester"]);
        await git.RunAsync(["config", "user.email", "t@example.com"]);
        await git.RunAsync(["config", "core.autocrlf", "false"]);
        foreach (var file in files) Write(file, "one\n");
        await git.RunAsync(["add", "."]);
        await git.RunAsync(["commit", "-m", "start"]);
        return new GitRepository(_dir);
    }

    [Fact]
    public async Task ABracketedNameTouchesOnlyThatFile()
    {
        // As a pattern, "[id].txt" would also match "i.txt".
        var repo = await CommittedAsync("[id].txt", "i.txt");
        Write("[id].txt", "changed\n");
        Write("i.txt", "keep\n");

        var diff = await repo.DiffAsync(new DiffTarget(DiffSource.Unstaged, "[id].txt"));
        Assert.Single(diff.Hunks);
        Assert.Equal(1, (await repo.DiscardSummaryAsync(["[id].txt"], [])).AddedLines);

        await repo.DiscardAsync(["[id].txt"], []);

        Assert.Equal("one\n", Read("[id].txt"));
        Assert.Equal("keep\n", Read("i.txt"));
    }

    [Fact]
    public async Task DeletingAnUntrackedBracketedNameLeavesOthers()
    {
        var repo = await CommittedAsync("a.txt");
        Write("[id].md", "new\n");
        Write("d.md", "keep\n");

        await repo.DiscardAsync([], ["[id].md"]);

        Assert.False(File.Exists(Path.Combine(_dir, "[id].md")));
        Assert.True(File.Exists(Path.Combine(_dir, "d.md")));
    }

    [Fact]
    public async Task StagingAndUnstagingABracketedNameLeavesOthers()
    {
        var repo = await CommittedAsync("[id].txt", "i.txt");
        Write("[id].txt", "changed\n");
        Write("i.txt", "changed\n");
        var git = new GitRunner(_dir);
        async Task<string> StagedAsync() =>
            await git.RunStringAsync(["diff", "--cached", "--name-only"], readOnly: true);

        await repo.StageAsync(["[id].txt"]);
        Assert.Equal("[id].txt", (await StagedAsync()).Trim());

        await repo.StageAsync(["i.txt"]);
        await repo.UnstageAsync(["[id].txt"]);
        Assert.Equal("i.txt", (await StagedAsync()).Trim());
    }

    [Fact]
    public async Task TheSummaryCountsLinesAndFiles()
    {
        var repo = await CommittedAsync("a.txt");
        Write("a.txt", "two\nthree\n");
        Write("new.txt", "12345");

        var summary = await repo.DiscardSummaryAsync(["a.txt"], ["new.txt"]);

        Assert.Equal(new DiscardSummary(1, 2, 1, 0, 1, 5), summary);
        Assert.Equal(
            "Changes in 1 file (2 lines added, 1 removed); 1 untracked file (5 bytes) will be deleted will be lost. "
            + "This can’t be undone.",
            summary.Sentence);
    }

    [Fact]
    public void AnEmptyDiscardSaysSo() => Assert.Equal("Nothing will change.", new DiscardSummary().Sentence);
}
