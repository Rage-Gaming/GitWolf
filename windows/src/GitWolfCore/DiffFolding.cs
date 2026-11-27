namespace GitWolf.Core;

/// <summary>Folding away long stretches of unchanged lines. Ported from InlineDiff.swift.</summary>
public static class DiffFolding
{
    /// <summary>
    /// Runs of unchanged lines long enough to fold, as ranges of line indexes. Lines next to a change
    /// stay visible (<paramref name="keep"/> on each side); a run touching a hunk edge keeps only the
    /// side that touches a change.
    /// </summary>
    public static List<(int Start, int End)> CollapsibleRuns(this FileDiff diff, int minimum = 8, int keep = 3)
    {
        var runs = new List<(int, int)>();
        var lines = diff.Lines;
        for (var i = 0; i < lines.Count;)
        {
            if (lines[i].Kind != DiffLineKind.Context) { i++; continue; }
            var start = i;
            while (i < lines.Count && lines[i].Kind == DiffLineKind.Context) i++;
            var low = start + (start > 0 && lines[start - 1].IsChange ? keep : 0);
            var high = i - (i < lines.Count && lines[i].IsChange ? keep : 0);
            if (high - low >= minimum) runs.Add((low, high));
        }
        return runs;
    }

    /// <summary>
    /// The lines to draw, with each foldable run replaced by one placeholder (see
    /// <see cref="DiffLine.IsFold"/>).
    /// </summary>
    public static List<DiffLine> Folded(this FileDiff diff)
    {
        var shown = new List<DiffLine>(diff.Lines.Count);
        var next = 0;
        foreach (var (start, end) in diff.CollapsibleRuns())
        {
            for (; next < start; next++) shown.Add(diff.Lines[next]);
            var label = $"↕  {end - start} unchanged lines";
            // A negative id can't be mistaken for a line of the diff; it says where the run starts and ends.
            shown.Add(new DiffLine(-(start + 1), DiffLineKind.Note, diff.Lines[start].HunkIndex, null, end - start,
                label, label));
            next = end;
        }
        for (; next < diff.Lines.Count; next++) shown.Add(diff.Lines[next]);
        return shown;
    }

    /// <summary>The lines a placeholder from <see cref="Folded"/> stands for.</summary>
    public static IEnumerable<DiffLine> Unfold(this FileDiff diff, DiffLine fold) =>
        diff.Lines.Skip(-fold.Id - 1).Take(fold.NewNumber ?? 0);
}
