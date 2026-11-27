namespace GitSync.Core;

public enum OperationKind { Merge, Rebase, CherryPick, Revert, Am }

/// <summary>
/// A multi-step git operation that stopped and is waiting for the user, usually because of conflicts.
/// Ported from Operations.swift.
/// </summary>
/// <param name="Step">1-based position, for rebases and multi-commit picks.</param>
/// <param name="Branch">Branch being rebased, when known.</param>
public sealed record InProgressOperation(OperationKind Kind, int? Step = null, int? Total = null, string? Branch = null)
{
    /// <summary>Merges can only be continued or aborted; the others can also skip the current commit.</summary>
    public bool CanSkip => Kind != OperationKind.Merge;

    public string Verb => Kind switch
    {
        OperationKind.Merge => "Merging",
        OperationKind.Rebase => "Rebasing",
        OperationKind.CherryPick => "Cherry-picking",
        OperationKind.Am => "Applying patches",
        _ => "Reverting",
    };

    public string Title
    {
        get
        {
            var text = Verb;
            if (Step is { } step && Total is > 1) text += $" ({step} of {Total})";
            if (Kind == OperationKind.Rebase && Branch is not null) text += $" {Branch}";
            return text;
        }
    }

    internal string Command => Kind switch
    {
        OperationKind.Merge => "merge",
        OperationKind.Rebase => "rebase",
        OperationKind.CherryPick => "cherry-pick",
        OperationKind.Am => "am",
        _ => "revert",
    };
}

internal static class OperationDetector
{
    /// <summary>The real git directory, following the `gitdir:` pointer of worktrees and submodules.</summary>
    internal static string GitDirectory(string root)
    {
        var dotGit = Path.Combine(root, ".git");
        if (!File.Exists(dotGit)) return dotGit;
        var line = Read(dotGit)?.Split('\n').FirstOrDefault(l => l.StartsWith("gitdir:", StringComparison.Ordinal));
        // Combine keeps an absolute second path as it is.
        return line is null ? dotGit : Path.GetFullPath(Path.Combine(root, line["gitdir:".Length..].Trim()));
    }

    internal static InProgressOperation? Detect(string gitDir)
    {
        string At(string name) => Path.Combine(gitDir, name);
        bool Exists(string name) => File.Exists(At(name)) || Directory.Exists(At(name));
        int? Number(string name) => int.TryParse(Read(At(name)), out var n) ? n : null;
        string? BranchName(string name) =>
            Read(At(name)) is { } head && head.StartsWith("refs/heads/", StringComparison.Ordinal) ? head[11..] : null;

        if (Exists("rebase-merge"))
            return new(OperationKind.Rebase, Number("rebase-merge/msgnum"), Number("rebase-merge/end"),
                BranchName("rebase-merge/head-name"));
        if (Exists("rebase-apply/applying"))
            return new(OperationKind.Am, Number("rebase-apply/next"), Number("rebase-apply/last"));
        if (Exists("rebase-apply"))
            return new(OperationKind.Rebase, Number("rebase-apply/next"), Number("rebase-apply/last"),
                BranchName("rebase-apply/head-name"));

        var todo = Steps(At("sequencer/todo"));
        var done = Steps(At("sequencer/done"))?.Count ?? 0;
        var total = todo is null ? 0 : todo.Count + done;
        int? step = total > 0 ? done + (todo!.Count > 0 ? 1 : 0) : null;
        int? of = total > 0 ? total : null;

        if (Exists("CHERRY_PICK_HEAD")) return new(OperationKind.CherryPick, step, of);
        if (Exists("REVERT_HEAD")) return new(OperationKind.Revert, step, of);
        if (Exists("MERGE_HEAD")) return new(OperationKind.Merge);
        // A multi-commit pick or revert that stopped between commits only leaves the sequencer behind.
        if (todo is { Count: > 0 })
            return new(todo[0].StartsWith("revert", StringComparison.Ordinal) ? OperationKind.Revert : OperationKind.CherryPick,
                step, of);
        return null;
    }

    private static List<string>? Steps(string path) =>
        Read(path)?.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Where(l => !l.StartsWith('#')).ToList();

    /// <summary>Null when the file is absent, or git is replacing it at this moment.</summary>
    private static string? Read(string path)
    {
        try
        {
            return File.Exists(path) ? File.ReadAllText(path).Trim() : null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }
}

public sealed partial class GitRepository
{
    /// <summary>The operation waiting for the user, if any. Only reads the git directory, so it is cheap.</summary>
    public InProgressOperation? InProgressOperation() => OperationDetector.Detect(OperationDetector.GitDirectory(Root));

    public Task ContinueOperationAsync(InProgressOperation operation) => FinishStepAsync(operation, "--continue");
    public Task AbortOperationAsync(InProgressOperation operation) => FinishStepAsync(operation, "--abort");

    public Task SkipOperationAsync(InProgressOperation operation) =>
        operation.CanSkip ? FinishStepAsync(operation, "--skip") : Task.CompletedTask;

    private async Task FinishStepAsync(InProgressOperation operation, string step)
    {
        await Git.RunAsync([operation.Command, step]);
        if (operation.Kind == OperationKind.Rebase && InProgressOperation() is null) RemoveRebaseSupport();
    }
}
