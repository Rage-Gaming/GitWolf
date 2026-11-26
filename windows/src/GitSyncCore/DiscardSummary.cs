namespace GitSync.Core;

/// <summary>What discarding would throw away, so the confirmation can be specific. Ported from StashTools.swift.</summary>
/// <param name="UntrackedFiles">Files that would be deleted; git has no copy of them.</param>
public sealed record DiscardSummary(
    int Files = 0, int AddedLines = 0, int RemovedLines = 0, int BinaryFiles = 0,
    int UntrackedFiles = 0, long UntrackedBytes = 0)
{
    /// <summary>A sentence listing exactly what is lost.</summary>
    public string Sentence
    {
        get
        {
            var parts = new List<string>();
            if (Files > 0)
            {
                var text = $"Changes in {Count(Files, "file")}";
                if (AddedLines + RemovedLines > 0)
                    text += $" ({Count(AddedLines, "line")} added, {RemovedLines} removed)";
                if (BinaryFiles > 0) text += $", {BinaryFiles} binary";
                parts.Add(text);
            }
            if (UntrackedFiles > 0)
                parts.Add($"{Count(UntrackedFiles, "untracked file")} ({Size(UntrackedBytes)}) will be deleted");
            if (parts.Count == 0) return "Nothing will change.";
            return string.Join("; ", parts) + (Files > 0 ? " will be lost" : "") + ". This can’t be undone.";
        }
    }

    private static string Count(int number, string noun) => $"{number} {noun}{(number == 1 ? "" : "s")}";

    private static string Size(long bytes) => bytes switch
    {
        1 => "1 byte",
        < 1000 => $"{bytes} bytes",
        < 1_000_000 => $"{bytes / 1000.0:0} KB",
        < 1_000_000_000 => $"{bytes / 1_000_000.0:0.#} MB",
        _ => $"{bytes / 1_000_000_000.0:0.##} GB",
    };
}

public sealed partial class GitRepository
{
    /// <summary>Counts what discarding <paramref name="tracked"/> and deleting <paramref name="untracked"/> would lose.</summary>
    public async Task<DiscardSummary> DiscardSummaryAsync(IReadOnlyList<string> tracked, IReadOnlyList<string> untracked)
    {
        int files = 0, added = 0, removed = 0, binary = 0;
        if (tracked.Count > 0)
        {
            var output = await Git.RunStringAsync(
                ["--literal-pathspecs", "diff", "--numstat", "--no-renames", "-z", "--", .. tracked], readOnly: true);
            // "<added>\t<removed>\t<path>\0"; "-" counts mean a binary file.
            foreach (var entry in output.Split('\0', StringSplitOptions.RemoveEmptyEntries))
            {
                var fields = entry.Split('\t', 3);
                if (fields.Length != 3) continue;
                files++;
                if (int.TryParse(fields[0], out var a) && int.TryParse(fields[1], out var r))
                {
                    added += a;
                    removed += r;
                }
                else
                {
                    binary++;
                }
            }
            // Mode-only changes have no counts but are still affected.
            files = Math.Max(files, tracked.Count);
        }
        long bytes = 0;
        foreach (var path in untracked)
        {
            var info = new FileInfo(Path.Combine(Root, path));
            if (info.Exists) bytes += info.Length;
        }
        return new DiscardSummary(files, added, removed, binary, untracked.Count, bytes);
    }
}
