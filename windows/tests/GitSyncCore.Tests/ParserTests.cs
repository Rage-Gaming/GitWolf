using System.Text;
using GitSync.Core;
using Xunit;

namespace GitSyncCore.Tests;

// Ported from ParserTests in apple/Tests/GitSyncCoreTests/GitSyncCoreTests.swift.
public sealed class ParserTests
{
    [Fact]
    public void ParsesStatus()
    {
        var raw = "# branch.oid abc123\0# branch.head main\0# branch.upstream origin/main\0# branch.ab +2 -1\0"
            + "1 M. N... 100644 100644 100644 h1 h2 staged.txt\0"
            + "1 .M N... 100644 100644 100644 h1 h2 dir/work file.txt\0"
            + "2 R. N... 100644 100644 100644 h1 h2 R100 new.txt\0old.txt\0"
            + "? untracked.txt\0";

        var s = StatusParser.Parse(Encoding.UTF8.GetBytes(raw));

        Assert.Equal("main", s.Branch);
        Assert.Equal("origin/main", s.Upstream);
        Assert.Equal(2, s.Ahead);
        Assert.Equal(1, s.Behind);
        Assert.Equal(["staged.txt", "new.txt"], s.Staged.Select(f => f.Path));
        Assert.Equal("old.txt", s.Staged[1].OriginalPath);
        Assert.Equal(["dir/work file.txt"], s.Unstaged.Select(f => f.Path));
        Assert.Equal(["untracked.txt"], s.Untracked.Select(f => f.Path));
    }

    [Fact]
    public void ParsesDiffWithLineNumbersAndCRLF()
    {
        var raw = "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,2 +1,3 @@\n keep\r\n-old\n+new\n+added\n";
        var d = DiffParser.Parse(Encoding.UTF8.GetBytes(raw), maxLines: 100);

        Assert.Equal(2, d.Additions);
        Assert.Equal(1, d.Deletions);
        Assert.Equal(5, d.Lines.Count);
        Assert.Equal("keep", d.Lines[1].Text);
        Assert.Equal(2, d.Lines[2].OldNumber);
        Assert.Equal(2, d.Lines[3].NewNumber);
    }

    [Fact]
    public void ParsesDecorations()
    {
        var refs = LogParser.ParseDecorations("HEAD -> main, origin/main, tag: v1, feature/x", new HashSet<string> { "origin" });

        Assert.Equal([RefKind.Local, RefKind.Remote, RefKind.Tag, RefKind.Local], refs.Select(r => r.Kind));
        Assert.True(refs[0].IsCurrent);
    }
}
