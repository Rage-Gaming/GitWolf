using System.Text;
using GitWolf.Core;
using Xunit;

namespace GitWolfCore.Tests;

// Ported from SideBySideTests in apple/Tests/GitWolfCoreTests/GitWolfCoreTests.swift.
public sealed class SideBySideTests
{
    [Fact]
    public void PairsDeletionsWithAdditions()
    {
        var raw = "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,5 +1,6 @@\n keep\n-old1\n-old2\n+new1\n+new2\n+new3\n tail\n";
        var diff = DiffParser.Parse(Encoding.UTF8.GetBytes(raw), maxLines: 100);
        var rows = SideBySide.Rows(diff);

        Assert.Equal(6, rows.Count); // header, keep, 3 change rows, tail
        Assert.NotNull(rows[0].Header);
        Assert.Equal("keep", rows[1].Left?.Text);
        Assert.Equal("keep", rows[1].Right?.Text);
        Assert.Equal("old1", rows[2].Left?.Text);
        Assert.Equal("new1", rows[2].Right?.Text);
        Assert.Equal("old2", rows[3].Left?.Text);
        Assert.Equal("new2", rows[3].Right?.Text);
        Assert.Null(rows[4].Left);
        Assert.Equal("new3", rows[4].Right?.Text);
        Assert.Equal("tail", rows[5].Left?.Text);
    }

    [Fact]
    public void PureDeletionLeavesRightBlank()
    {
        var raw = "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,2 +1,1 @@\n a\n-b\n";
        var rows = SideBySide.Rows(DiffParser.Parse(Encoding.UTF8.GetBytes(raw), maxLines: 100));

        Assert.Equal("b", rows[^1].Left?.Text);
        Assert.Null(rows[^1].Right);
    }
}
