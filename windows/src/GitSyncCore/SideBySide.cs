namespace GitSync.Core;

// Ported from apple/Sources/GitSyncCore/SideBySide.swift.

/// <summary>One row of a side-by-side diff: either a hunk header, or an old/new pair.</summary>
public sealed record SplitRow(int Id, DiffLine? Header, DiffLine? Left, DiffLine? Right);

public static class SideBySide
{
    /// <summary>
    /// Pairs a unified diff into aligned rows. Context lines appear on both sides; within a block
    /// of changes, deletions (left) are lined up with additions (right) in order, and whichever
    /// side is shorter is left blank.
    /// </summary>
    public static List<SplitRow> Rows(FileDiff diff)
    {
        var rows = new List<SplitRow>();
        var deletions = new List<DiffLine>();
        var additions = new List<DiffLine>();

        void Add(DiffLine? header = null, DiffLine? left = null, DiffLine? right = null) =>
            rows.Add(new SplitRow(rows.Count, header, left, right));

        void Flush()
        {
            var count = Math.Max(deletions.Count, additions.Count);
            for (int i = 0; i < count; i++)
                Add(left: i < deletions.Count ? deletions[i] : null, right: i < additions.Count ? additions[i] : null);
            deletions.Clear();
            additions.Clear();
        }

        foreach (var line in diff.Lines)
        {
            switch (line.Kind)
            {
                case DiffLineKind.HunkHeader:
                    Flush();
                    Add(header: line);
                    break;
                case DiffLineKind.Context:
                    Flush();
                    Add(left: line, right: line);
                    break;
                case DiffLineKind.Deletion:
                    // A deletion after additions starts a new change block.
                    if (additions.Count > 0) Flush();
                    deletions.Add(line);
                    break;
                case DiffLineKind.Addition:
                    additions.Add(line);
                    break;
                case DiffLineKind.Note:
                    break;
            }
        }
        Flush();
        return rows;
    }
}
