using System.Text;

namespace GitSync.Core;

public enum RebaseAction { Pick, Reword, Squash, Fixup, Drop }

/// <summary>One commit in an interactive rebase.</summary>
/// <param name="Message">Full message; used when the action is <see cref="RebaseAction.Reword"/>.</param>
public sealed record RebaseItem(string Hash, string Subject, string Message, RebaseAction Action = RebaseAction.Pick)
{
    public string ShortHash => Hash.Length > 7 ? Hash[..7] : Hash;

    /// <summary>Folds into the commit above it.</summary>
    public bool Folds => Action is RebaseAction.Squash or RebaseAction.Fixup;
}

/// <summary>
/// An interactive rebase to run: the commits after <paramref name="Base"/>, oldest first, each with
/// an action. Ported from Rebase.swift.
/// </summary>
/// <param name="Base">The commit to rebase onto; null rebases from the root commit.</param>
/// <param name="Head">The tip the plan was made from; it must not have moved when the plan runs.</param>
public sealed record RebasePlan(string? Base, string Head, IReadOnlyList<RebaseItem> Items)
{
    /// <summary>Why this plan cannot run, or null when it can.</summary>
    public string? Problem
    {
        get
        {
            var first = Items.FirstOrDefault(i => i.Action != RebaseAction.Drop);
            if (first is null) return "Keep at least one commit, or the branch would be emptied.";
            if (first.Folds)
                return "The first commit can’t be squashed or fixed up; there is nothing above it to fold into.";
            return Items.Any(i => i.Action == RebaseAction.Reword && string.IsNullOrWhiteSpace(i.Message))
                ? "A reworded commit needs a message." : null;
        }
    }

    /// <summary>
    /// The `git-rebase-todo` text. A reword is a pick followed by `git commit --amend -F file`, placed
    /// after any commits folded into it, so it names the final commit.
    /// </summary>
    internal string Todo(Func<int, string> messageFile, string gitCommand)
    {
        static string Line(string verb, RebaseItem item) => $"{verb} {item.Hash} {item.Subject}\n";
        var text = new StringBuilder();
        var i = 0;
        while (i < Items.Count)
        {
            var item = Items[i];
            if (item.Action == RebaseAction.Drop)
            {
                text.Append(Line("drop", item));
                i++;
                continue;
            }
            text.Append(Line("pick", item));
            var next = i + 1;
            for (; next < Items.Count && (Items[next].Folds || Items[next].Action == RebaseAction.Drop); next++)
                text.Append(Line(Items[next].Action.ToString().ToLowerInvariant(), Items[next]));
            if (item.Action == RebaseAction.Reword)
                text.Append($"exec {gitCommand} commit --amend -q -F {Quote(messageFile(i))}\n");
            i = next;
        }
        return text.ToString();
    }

    /// <summary>Quotes for the POSIX shell that Git for Windows runs editors and `exec` lines with.</summary>
    internal static string Quote(string value) => "'" + value.Replace('\\', '/').Replace("'", "'\\''") + "'";
}

/// <param name="HasMerges">The range contains merge commits, which an interactive rebase would flatten.</param>
public sealed record RebaseCandidates(RebasePlan Plan, bool HasMerges);

public sealed partial class GitRepository
{
    private string RebaseSupportDirectory =>
        Path.Combine(OperationDetector.GitDirectory(Root), "gitsync-rebase");

    private async Task<string> HeadHashAsync() =>
        (await Git.RunStringAsync(["rev-parse", "--verify", "HEAD"], readOnly: true)).Trim();

    /// <summary>The commits from <paramref name="commit"/> up to HEAD, oldest first, all set to pick.</summary>
    public async Task<RebaseCandidates> RebaseCandidatesAsync(string commit)
    {
        var hash = await ResolveCommitAsync(commit);
        var head = await HeadHashAsync();
        // Rebasing from a commit on another line would move this branch onto that line.
        try
        {
            await Git.RunAsync(["merge-base", "--is-ancestor", hash, head], readOnly: true);
        }
        catch (GitException error) when (error.ExitCode == 1)
        {
            throw new GitException("rebase", 1, "That commit isn’t part of the current branch.");
        }
        var parents = (await Git.RunStringAsync(["rev-list", "--parents", "-n", "1", hash], readOnly: true))
            .Split([' ', '\n', '\r'], StringSplitOptions.RemoveEmptyEntries);
        var @base = parents.Length > 1 ? parents[1] : null;
        var range = @base is null ? head : $"{@base}..{head}";
        var output = await Git.RunStringAsync(
            ["log", "--reverse", "--topo-order", "-z", "--format=%H%x1f%s%x1f%B", range, "--"], readOnly: true);
        var items = output.Split('\0', StringSplitOptions.RemoveEmptyEntries)
            .Select(record => record.Split('\u001f', 3))
            .Where(f => f.Length == 3)
            .Select(f => new RebaseItem(f[0].Trim(), f[1], f[2].TrimEnd()))
            .ToList();
        var merges = (await Git.RunStringAsync(["rev-list", "--merges", "--count", range, "--"], readOnly: true)).Trim();
        return new RebaseCandidates(new RebasePlan(@base, head, items), merges != "0");
    }

    /// <summary>
    /// Runs an interactive rebase without opening an editor. A conflict is not an error: the rebase
    /// is left in progress for the user to resolve and continue.
    /// </summary>
    public async Task StartInteractiveRebaseAsync(RebasePlan plan)
    {
        if (plan.Problem is { } problem) throw new GitException("rebase", 1, problem);
        // Also protects the files a rebase already under way still needs.
        if (InProgressOperation() is not null)
            throw new GitException("rebase", 1, "Finish or abort the operation in progress first.");
        // A commit made since the plan was built is not in it, and the rebase would drop it.
        if (await HeadHashAsync() != plan.Head)
            throw new GitException("rebase", 1, "The branch changed, so nothing was done. Start the rebase again.");

        var support = RebaseSupportDirectory;
        RemoveRebaseSupport();
        Directory.CreateDirectory(support);
        string MessageFile(int index) => Path.Combine(support, $"message-{index}");
        for (var i = 0; i < plan.Items.Count; i++)
            if (plan.Items[i].Action == RebaseAction.Reword)
                await File.WriteAllTextAsync(MessageFile(i), plan.Items[i].Message);
        var todo = Path.Combine(support, "todo");
        await File.WriteAllTextAsync(todo, plan.Todo(MessageFile, RebasePlan.Quote(Git.GitPath)));

        var runner = new GitRunner(Root, Git.GitPath, new Dictionary<string, string>(Git.ExtraEnvironment)
        {
            ["GIT_SEQUENCE_EDITOR"] = $"cp {RebasePlan.Quote(todo)}",
        });
        try
        {
            await RunRebaseAsync(runner,
                ["rebase", "-i", "--autostash", "--no-rebase-merges", plan.Base ?? "--root"]);
        }
        finally
        {
            if (InProgressOperation() is null) RemoveRebaseSupport();
        }
    }

    /// <summary>Rebases the current branch onto <paramref name="target"/>.</summary>
    public Task RebaseOntoAsync(string target) => RunRebaseAsync(Git, ["rebase", "--autostash", Operand(target)]);

    private async Task RunRebaseAsync(GitRunner runner, IReadOnlyList<string> arguments)
    {
        try
        {
            await runner.RunAsync(arguments);
        }
        catch (GitException)
        {
            // Stopping on a conflict is expected. Anything else, such as a hook refusing a reworded
            // message, is reported even though the rebase stays in progress.
            if (InProgressOperation() is null) throw;
            var unmerged = await Git.RunAsync(["diff", "--name-only", "--diff-filter=U"], readOnly: true);
            if (unmerged.Length == 0) throw;
        }
    }

    /// <summary>The todo and message files are only needed while the rebase runs.</summary>
    private void RemoveRebaseSupport()
    {
        try
        {
            if (Directory.Exists(RebaseSupportDirectory)) Directory.Delete(RebaseSupportDirectory, recursive: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // Left in the git directory; the next rebase tries again.
            System.Diagnostics.Trace.TraceWarning($"Removing rebase files failed: {e.GetType().Name}");
        }
    }
}
