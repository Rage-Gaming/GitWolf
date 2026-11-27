using System.Text;
using GitWolf.Core;
using Xunit;

namespace GitWolfCore.Tests;

// Ported from SyntaxTests in apple/Tests/GitWolfCoreTests/GitWolfCoreTests.swift.
public sealed class SyntaxHighlighterTests
{
    private static List<(string Text, SyntaxKind Kind)> Kinds(string text, string ext = "swift")
    {
        var state = new SyntaxHighlighter.State();
        var lang = SyntaxHighlighter.Language.ForPath($"f.{ext}")!;
        var tokens = SyntaxHighlighter.Tokenize(text, lang, ref state);
        return tokens.Select(t => (text[t.Start..t.End], t.Kind)).ToList();
    }

    [Fact]
    public void SwiftBasics()
    {
        var t = Kinds("let name: String = \"hi // not a comment\" // real foo(42)");

        Assert.Contains(t, x => x == ("let", SyntaxKind.Keyword));
        Assert.Contains(t, x => x == ("String", SyntaxKind.Type));
        Assert.Contains(t, x => x.Kind == SyntaxKind.String && x.Text.Contains("not a comment"));
        Assert.Equal(SyntaxKind.Comment, t[^1].Kind);
        Assert.StartsWith("// real", t[^1].Text);
        Assert.DoesNotContain(t, x => x.Text == "foo"); // swallowed by the trailing comment
    }

    [Fact]
    public void BlockCommentsSpanLines()
    {
        var raw = "diff --git a/f.c b/f.c\n--- a/f.c\n+++ b/f.c\n@@ -1,3 +1,3 @@\n /* start\n+middle\n end */ int x;\n";
        var diff = DiffParser.Parse(Encoding.UTF8.GetBytes(raw), maxLines: 100);
        var tokens = SyntaxHighlighter.Tokens(diff, "f.c");
        var middle = diff.Lines.First(l => l.Text == "middle");

        Assert.Equal(SyntaxKind.Comment, tokens[middle.Id][0].Kind);
    }

    [Fact]
    public void UnknownExtensionIsPlain()
    {
        Assert.Null(SyntaxHighlighter.Language.ForPath("notes.xyz"));
    }
}
