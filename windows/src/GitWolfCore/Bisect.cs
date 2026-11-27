namespace GitWolf.Core;

public enum BisectMark { Good, Bad, Skip }

public sealed record BisectEntry(string Hash, BisectMark Mark);

/// <summary>Where a bisect session stands. Ported from Bisect.swift.</summary>
public sealed record BisectState
{
    public static BisectState Inactive { get; } = new();

    public bool IsActive { get; init; }
    /// <summary>Commits marked so far, oldest mark first.</summary>
    public IReadOnlyList<BisectEntry> Marks { get; init; } = [];
    /// <summary>Set once git has narrowed it down to one commit.</summary>
    public string? FirstBad { get; init; }
    /// <summary>Git's own estimate, e.g. "3 revisions left to test after this (roughly 2 steps)".</summary>
    public string? Progress { get; init; }

    public bool Equals(BisectState? other) =>
        other is not null && IsActive == other.IsActive && FirstBad == other.FirstBad && Progress == other.Progress
        && Marks.SequenceEqual(other.Marks);

    public override int GetHashCode() => HashCode.Combine(IsActive, FirstBad, Progress, Marks.Count);

    /// <summary>
    /// Reads BISECT_LOG: `git bisect bad &lt;hash&gt;` lines, and the `# first bad commit: [hash] subject`
    /// comment git writes once it is done.
    /// </summary>
    internal static BisectState Parse(string log)
    {
        // Newer git quotes the term: "# first 'bad' commit: [hash]".
        string[] found = ["# first bad commit: [", "# first 'bad' commit: ["];
        var marks = new List<BisectEntry>();
        string? firstBad = null;
        foreach (var line in log.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var prefix = found.FirstOrDefault(f => line.StartsWith(f, StringComparison.Ordinal));
            if (prefix is not null && line.IndexOf(']', prefix.Length) is var end && end > 0)
            {
                firstBad = line[prefix.Length..end];
                continue;
            }
            var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length != 4 || parts[0] != "git" || parts[1] != "bisect") continue;
            BisectMark? mark = parts[2] switch
            {
                "good" => BisectMark.Good,
                "bad" => BisectMark.Bad,
                "skip" => BisectMark.Skip,
                _ => null,
            };
            if (mark is { } value) marks.Add(new(parts[3].Trim('\''), value));
        }
        return new BisectState { IsActive = true, Marks = marks, FirstBad = firstBad };
    }

    /// <summary>"Bisecting: 3 revisions left…" gives the part after the colon.</summary>
    internal static string? ProgressFrom(string output) => output
        .Split('\n').FirstOrDefault(l => l.StartsWith("Bisecting:", StringComparison.Ordinal))?["Bisecting:".Length..]
        .Trim();
}

public sealed partial class GitRepository
{
    public BisectState BisectState()
    {
        var path = Path.Combine(OperationDetector.GitDirectory(Root), "BISECT_LOG");
        try
        {
            return File.Exists(path) ? Core.BisectState.Parse(File.ReadAllText(path)) : Core.BisectState.Inactive;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // Git is replacing the file at this moment; the next refresh reads it.
            return Core.BisectState.Inactive;
        }
    }

    /// <summary>Starts a session; git checks out the first commit to test.</summary>
    public async Task<BisectState> BisectStartAsync(string bad, string good)
    {
        var output = await Git.RunStringAsync(["bisect", "start", Operand(bad), Operand(good), "--"]);
        return BisectState() with { Progress = Core.BisectState.ProgressFrom(output) };
    }

    /// <summary>Marks the commit being tested (HEAD), or <paramref name="hash"/>.</summary>
    public async Task<BisectState> BisectMarkAsync(BisectMark mark, string? hash = null)
    {
        var term = mark switch { BisectMark.Good => "good", BisectMark.Bad => "bad", _ => "skip" };
        var output = await Git.RunStringAsync(hash is null ? ["bisect", term] : ["bisect", term, Operand(hash)]);
        return BisectState() with { Progress = Core.BisectState.ProgressFrom(output) };
    }

    /// <summary>Ends the session and returns to the branch you started on.</summary>
    public Task BisectResetAsync() => Git.RunAsync(["bisect", "reset"]);
}
