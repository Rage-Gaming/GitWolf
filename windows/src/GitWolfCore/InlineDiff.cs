using System.Text;

namespace GitWolf.Core;

/// <summary>A stretch of a line, in UTF-16 offsets.</summary>
public readonly record struct TextSpan(int Start, int Length)
{
    public int End => Start + Length;
}

/// <summary>Word-level highlighting inside changed lines. Ported from InlineDiff.swift.</summary>
public static class InlineDiff
{
    private const int MaxTokens = 600;

    /// <summary>
    /// The ranges that differ between two lines. Both are empty when the lines are too different for
    /// highlighting to help (more than 70% of either changed) or too long to compare cheaply.
    /// </summary>
    public static (IReadOnlyList<TextSpan> Old, IReadOnlyList<TextSpan> New) Changes(string old, string @new)
    {
        if (Tokens(old) is not { Count: > 0 } a || Tokens(@new) is not { Count: > 0 } b) return ([], []);

        bool Same(int i, int j) => old.AsSpan(a[i].Start, a[i].Length).SequenceEqual(@new.AsSpan(b[j].Start, b[j].Length));

        // Longest common subsequence over tokens.
        var width = b.Count + 1;
        var table = new short[(a.Count + 1) * width];
        for (var i = a.Count - 1; i >= 0; i--)
            for (var j = b.Count - 1; j >= 0; j--)
                table[i * width + j] = Same(i, j)
                    ? (short)(table[(i + 1) * width + j + 1] + 1)
                    : Math.Max(table[(i + 1) * width + j], table[i * width + j + 1]);

        var keptA = new bool[a.Count];
        var keptB = new bool[b.Count];
        for (int i = 0, j = 0; i < a.Count && j < b.Count;)
        {
            if (Same(i, j)) { keptA[i++] = true; keptB[j++] = true; }
            else if (table[(i + 1) * width + j] >= table[i * width + j + 1]) i++;
            else j++;
        }

        var before = Merge(a, keptA);
        var after = Merge(b, keptB);
        bool Mostly(List<TextSpan> spans, string line) => spans.Sum(s => s.Length) > 0.7 * line.Length;
        return Mostly(before, old) || Mostly(after, @new) ? ([], []) : (before, after);
    }

    /// <summary>
    /// Words (letters, digits, underscore), runs of whitespace, and single other characters. Null when
    /// there are too many to compare.
    /// </summary>
    private static List<TextSpan>? Tokens(string line)
    {
        var tokens = new List<TextSpan>();
        var (position, kind) = (0, 0);
        // By code point, so a highlight never splits a surrogate pair.
        foreach (var rune in line.EnumerateRunes())
        {
            var next = Rune.IsLetterOrDigit(rune) || rune.Value == '_' ? 1 : Rune.IsWhiteSpace(rune) ? 2 : 0;
            var length = rune.Utf16SequenceLength;
            if (next != 0 && next == kind) tokens[^1] = tokens[^1] with { Length = tokens[^1].Length + length };
            else if (tokens.Count == MaxTokens) return null;
            else tokens.Add(new TextSpan(position, length));
            kind = next;
            position += length;
        }
        return tokens;
    }

    private static List<TextSpan> Merge(List<TextSpan> tokens, bool[] kept)
    {
        var spans = new List<TextSpan>();
        for (var i = 0; i < tokens.Count; i++)
        {
            if (kept[i]) continue;
            if (spans.Count > 0 && spans[^1].End == tokens[i].Start)
                spans[^1] = spans[^1] with { Length = spans[^1].Length + tokens[i].Length };
            else spans.Add(tokens[i]);
        }
        return spans;
    }

    /// <summary>
    /// Changed ranges per line id: each run of deleted lines is paired, in order, with the run of added
    /// lines that directly follows it.
    /// </summary>
    public static Dictionary<int, IReadOnlyList<TextSpan>> InlineRanges(this FileDiff diff)
    {
        var result = new Dictionary<int, IReadOnlyList<TextSpan>>();
        var lines = diff.Lines;
        for (var i = 0; i < lines.Count;)
        {
            if (lines[i].Kind != DiffLineKind.Deletion) { i++; continue; }
            var deletions = i;
            while (i < lines.Count && lines[i].Kind == DiffLineKind.Deletion) i++;
            var additions = i;
            while (i < lines.Count && lines[i].Kind == DiffLineKind.Addition) i++;
            for (var pair = 0; pair < Math.Min(additions - deletions, i - additions); pair++)
            {
                var (removed, added) = (lines[deletions + pair], lines[additions + pair]);
                var (old, @new) = Changes(removed.Text.TrimEnd('\r'), added.Text.TrimEnd('\r'));
                if (old.Count > 0) result[removed.Id] = old;
                if (@new.Count > 0) result[added.Id] = @new;
            }
        }
        return result;
    }
}
