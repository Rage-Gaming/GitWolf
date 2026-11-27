namespace GitSync.Core;

/// <summary>A checkout of this repository. Ported from Worktrees.swift.</summary>
/// <param name="Branch">Null when detached.</param>
/// <param name="IsPrunable">Its folder is gone; pruning removes the record.</param>
public sealed record Worktree(
    string Path, string Head, string? Branch, bool IsMain, bool IsLocked, bool IsPrunable)
{
    public string Name => System.IO.Path.GetFileName(Path.TrimEnd('/', '\\'));

    internal static List<Worktree> Parse(string text)
    {
        var result = new List<Worktree>();
        foreach (var block in text.ReplaceLineEndings("\n").Split("\n\n", StringSplitOptions.RemoveEmptyEntries))
        {
            string path = "", head = "";
            string? branch = null;
            bool locked = false, prunable = false;
            foreach (var line in block.Split('\n'))
            {
                if (line.StartsWith("worktree ", StringComparison.Ordinal)) path = line[9..];
                else if (line.StartsWith("HEAD ", StringComparison.Ordinal)) head = line[5..];
                else if (line.StartsWith("branch refs/heads/", StringComparison.Ordinal)) branch = line[18..];
                else if (line.StartsWith("branch ", StringComparison.Ordinal)) branch = line[7..];
                else if (line.StartsWith("locked", StringComparison.Ordinal)) locked = true;
                else if (line.StartsWith("prunable", StringComparison.Ordinal)) prunable = true;
            }
            if (path.Length > 0) result.Add(new(path, head, branch, result.Count == 0, locked, prunable));
        }
        return result;
    }
}

public sealed partial class GitRepository
{
    public async Task<IReadOnlyList<Worktree>> WorktreesAsync() =>
        Worktree.Parse(await Git.RunStringAsync(["worktree", "list", "--porcelain"], readOnly: true));

    /// <summary>Checks out a branch in a new folder, creating the branch when asked.</summary>
    public Task AddWorktreeAsync(string path, string branch, bool newBranch, string? startPoint = null)
    {
        if (!newBranch) return Git.RunAsync(["worktree", "add", "--", path, Operand(branch)]);
        string[] start = startPoint is null ? [] : [Operand(startPoint)];
        return Git.RunAsync(["worktree", "add", "-b", Operand(branch), "--", path, .. start]);
    }

    /// <summary>Deletes the worktree's folder. Git refuses when it has uncommitted changes.</summary>
    public Task RemoveWorktreeAsync(string path) => Git.RunAsync(["worktree", "remove", "--", path]);

    public Task PruneWorktreesAsync() => Git.RunAsync(["worktree", "prune"]);
}
