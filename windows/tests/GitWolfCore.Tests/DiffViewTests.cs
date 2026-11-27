using GitWolf.Core;
using Xunit;

namespace GitWolfCore.Tests;

// Word highlighting, folding, diff options and image previews.
public sealed partial class RemoteTests
{
    private static DiffTarget Changed(DiffSource source, string path) => new(source, path);

    [Fact]
    public async Task ChangedWordsArePairedAcrossRemovedAndAddedLines()
    {
        await InitAsync();
        await CommitAsync(Work, "f.txt", "a\nvalue = 1\nb\n");
        File.WriteAllText(Path.Combine(Work, "f.txt"), "a\nvalue = 2\nb\n");

        var diff = await new GitRepository(Work).DiffAsync(Changed(DiffSource.Unstaged, "f.txt"));
        var ranges = diff.InlineRanges();

        foreach (var line in diff.Lines.Where(l => l.IsChange))
            Assert.Equal([new TextSpan(8, 1)], ranges[line.Id]);
    }

    [Theory]
    [InlineData("completely different", "nothing alike here at all")]
    [InlineData("", "added")]
    public void LinesThatAreTooDifferentAreNotMarked(string old, string @new)
    {
        var (before, after) = InlineDiff.Changes(old, @new);

        Assert.Empty(before);
        Assert.Empty(after);
    }

    [Fact]
    public void ASurrogatePairIsMarkedWhole()
    {
        var (_, after) = InlineDiff.Changes("say hello there \U0001F600", "say hello there \U0001F601");

        Assert.Equal([new TextSpan(16, 2)], after);
    }

    [Fact]
    public async Task IgnoringWhitespaceAndShowingTheWholeFile()
    {
        await InitAsync();
        var lines = Enumerable.Range(1, 30).Select(i => $"line {i}").ToArray();
        await CommitAsync(Work, "f.txt", string.Join('\n', lines) + "\n");
        lines[14] = "line   15"; // whitespace only
        lines[2] = "line 3 CHANGED";
        File.WriteAllText(Path.Combine(Work, "f.txt"), string.Join('\n', lines) + "\n");
        var target = Changed(DiffSource.Unstaged, "f.txt");

        var normal = await new GitRepository(Work).DiffAsync(target);
        Assert.Equal(2, normal.Additions);
        Assert.True(normal.CanPatch);

        var ignoring = await new GitRepository(Work) { IgnoreWhitespace = true }.DiffAsync(target);
        Assert.Equal(1, ignoring.Additions);
        Assert.False(ignoring.CanPatch);

        var whole = await new GitRepository(Work) { FullFileDiffs = true }.DiffAsync(target);
        Assert.Single(whole.Hunks);
        Assert.Contains(whole.Lines, l => l.Text == "line 30");

        var folded = whole.Folded();
        var fold = folded.Last(l => l.IsFold);
        var hidden = whole.Unfold(fold).ToList();
        Assert.Equal("line 30", hidden[^1].Text);
        Assert.Equal(whole.Lines.Count,
            folded.Count(l => !l.IsFold) + folded.Where(l => l.IsFold).Sum(l => whole.Unfold(l).Count()));
        // A placeholder takes its own row side by side too.
        Assert.Contains(SideBySide.Rows(whole, folded), r => r.Header == fold);
    }

    [Fact]
    public void FoldingKeepsTheLinesBesideAChange()
    {
        static DiffLine Line(int id, DiffLineKind kind) => new(id, kind, 0, id, id, "x", " x");
        var diff = FileDiff.Empty with
        {
            Lines = [Line(0, DiffLineKind.Addition),
                .. Enumerable.Range(1, 20).Select(i => Line(i, DiffLineKind.Context)),
                Line(21, DiffLineKind.Deletion)],
        };

        Assert.Equal([(4, 18)], diff.CollapsibleRuns());
        Assert.Empty((diff with { Lines = [.. diff.Lines.Skip(1).Take(5)] }).CollapsibleRuns());
    }

    [Fact]
    public async Task BothVersionsOfAnImageAreRead()
    {
        await InitAsync();
        var file = Path.Combine(Work, "pic.png");
        var repo = new GitRepository(Work);
        var git = new GitRunner(Work);
        File.WriteAllBytes(file, [1, 2, 3]);
        await git.RunAsync(["add", "-A"]);
        await git.RunAsync(["commit", "-m", "add"]);
        File.WriteAllBytes(file, [4, 5, 6, 7]);

        async Task BothAsync(DiffSource source)
        {
            var (old, @new) = await repo.ImageVersionsAsync(Changed(source, "pic.png"));
            Assert.Equal([1, 2, 3], old);
            Assert.Equal([4, 5, 6, 7], @new);
        }

        await BothAsync(DiffSource.Unstaged);
        await git.RunAsync(["add", "-A"]);
        await BothAsync(DiffSource.Staged);
        await git.RunAsync(["commit", "-m", "edit"]);
        var head = (await git.RunStringAsync(["rev-parse", "HEAD"])).Trim();
        await BothAsync(DiffSource.ForCommit(head));

        // The first commit has no earlier version.
        var first = (await git.RunStringAsync(["rev-list", "--max-parents=0", "HEAD"])).Trim();
        var (none, added) = await repo.ImageVersionsAsync(Changed(DiffSource.ForCommit(first), "base.txt"));
        Assert.Null(none);
        Assert.NotNull(added);
        Assert.True(GitRepository.IsImagePath("a/B.PNG"));
        Assert.False(GitRepository.IsImagePath("a.svg"));
    }

    [Fact]
    public async Task AnImagePreviewNeverReadsOutsideTheRepository()
    {
        await InitAsync();
        File.WriteAllBytes(Path.Combine(_dir, "secret.png"), [9]);

        var (_, @new) = await new GitRepository(Work)
            .ImageVersionsAsync(Changed(DiffSource.Untracked, "../secret.png"));

        Assert.Null(@new);
    }
}
