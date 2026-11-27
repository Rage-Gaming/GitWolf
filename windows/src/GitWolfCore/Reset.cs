using System.Globalization;

namespace GitWolf.Core;

public enum ResetMode
{
    /// <summary>Move the branch only; everything stays staged.</summary>
    Soft,
    /// <summary>Move the branch and unstage; working files are kept.</summary>
    Mixed,
    /// <summary>Move the branch and overwrite the working tree. Uncommitted changes are lost.</summary>
    Hard,
    /// <summary>Like hard, but refuses to overwrite uncommitted changes. Used by Undo.</summary>
    Keep,
}

/// <summary>Where HEAD was, and what moved it there. `HEAD@{Index}` names the entry.</summary>
public sealed record ReflogEntry(int Index, string Hash, string Message, DateTimeOffset Date)
{
    public string ShortHash => Hash.Length > 7 ? Hash[..7] : Hash;
}

/// <summary>What a reset would throw away, so the UI can say so before doing it.</summary>
public sealed record ResetImpact(int DroppedCommits, int ModifiedFiles);

// Ported from Reset.swift.
public sealed partial class GitRepository
{
    public Task ResetAsync(string target, ResetMode mode) =>
        Git.RunAsync(["reset", $"--{mode.ToString().ToLowerInvariant()}", Operand(target), "--"]);

    public async Task<List<ReflogEntry>> ReflogAsync(int limit = 200)
    {
        var output = await Git.RunStringAsync(
            ["reflog", "show", "--no-show-signature", "-n", $"{limit}", "--format=%H%x1f%ct%x1f%gs", "HEAD", "--"], readOnly: true);
        var entries = new List<ReflogEntry>();
        foreach (var line in output.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            var f = line.TrimEnd('\r').Split('\u001f', 3);
            if (f.Length != 3 || !long.TryParse(f[1], CultureInfo.InvariantCulture, out var time)) continue;
            entries.Add(new ReflogEntry(entries.Count, f[0], f[2], DateTimeOffset.FromUnixTimeSeconds(time)));
        }
        return entries;
    }

    /// <summary>
    /// Moves back to where HEAD was before its last change, keeping uncommitted work. Refused when
    /// HEAD is no longer at <paramref name="expectedHead"/>, which the user confirmed undoing.
    /// </summary>
    public async Task UndoAsync(string expectedHead, string target)
    {
        var head = (await Git.RunStringAsync(["rev-parse", "HEAD"], readOnly: true)).Trim();
        if (head != expectedHead)
            throw new GitException("reset", 1, "The repository changed, so nothing was undone. Try again.");
        await ResetAsync(target, ResetMode.Keep);
    }

    public async Task<ResetImpact> ResetImpactAsync(string target)
    {
        var count = await Git.RunStringAsync(["rev-list", "--count", $"{Operand(target)}..HEAD"], readOnly: true);
        var status = await StatusAsync();
        return new ResetImpact(int.Parse(count.Trim(), CultureInfo.InvariantCulture),
            status.Staged.Concat(status.Unstaged).Select(f => f.Path).Distinct().Count());
    }
}
