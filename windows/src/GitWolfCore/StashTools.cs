using System.Text;

namespace GitWolf.Core;

/// <summary>What a stash holds. Untracked files are kept in a commit of their own.</summary>
public sealed record StashContents(
    string BaseHash, string Hash, IReadOnlyList<FileChange> Files,
    string? UntrackedHash, IReadOnlyList<FileChange> UntrackedFiles)
{
    /// <summary>Where the diff of a tracked file in this stash comes from.</summary>
    public DiffSource Source => DiffSource.Between(BaseHash, Hash);

    /// <summary>Where the diff of an untracked file comes from; null when there are none.</summary>
    public DiffSource? UntrackedSource =>
        UntrackedHash is { } hash ? DiffSource.Between(GitRepository.EmptyTree, hash) : null;
}

// Ported from StashTools.swift and the stash section of GitRepository.swift.
public sealed partial class GitRepository
{
    public async Task StashPushAsync(string message)
    {
        var args = new List<string> { "stash", "push", "--include-untracked" };
        if (message.Length > 0) args.AddRange(["-m", message]);
        await Git.RunAsync(args);
    }

    public async Task StashApplyAsync(string reference)
    {
        try
        {
            await Git.RunAsync(["stash", "apply", Operand(reference)]);
        }
        catch (GitException e)
        {
            if (!await ApplyStashAsPatchAsync(reference, e)) throw;
        }
    }

    public async Task StashPopAsync(string reference)
    {
        try
        {
            await Git.RunAsync(["stash", "pop", Operand(reference)]);
        }
        catch (GitException e)
        {
            if (!await ApplyStashAsPatchAsync(reference, e)) throw;
            await StashDropAsync(reference);
        }
    }

    public Task StashDropAsync(string reference) => Git.RunAsync(["stash", "drop", Operand(reference)]);

    /// <summary>
    /// `git stash apply` refuses when a file the stash touches has other local changes. If the stash
    /// holds only tracked changes (as a stashed hunk does), applying its diff as a patch still works
    /// whenever the changes don't overlap. True when the patch was applied.
    /// </summary>
    private async Task<bool> ApplyStashAsPatchAsync(string reference, GitException error)
    {
        if (!error.Stderr.Contains("would be overwritten", StringComparison.Ordinal)) return false;
        if (await ResolveAsync($"{reference}^3") is not null) return false;
        try
        {
            var patch = await Git.RunAsync(
                ["diff", "--binary", "--no-color", "--no-ext-diff", "--no-textconv",
                    "--src-prefix=a/", "--dst-prefix=b/", $"{reference}^1", reference], readOnly: true);
            await Git.RunAsync(["apply", "--recount", "--whitespace=nowarn", "-"], input: patch);
            return true;
        }
        catch (GitException)
        {
            // The changes do overlap: report why the stash itself was refused.
            return false;
        }
    }

    /// <summary>The object a name points at, or null when there is none.</summary>
    private async Task<string?> ResolveAsync(string name)
    {
        var output = await Git.RunAsync(
            ["rev-parse", "--verify", "--quiet", "--end-of-options", name], readOnly: true,
            allowedExitCodes: new HashSet<int> { 0, 1 });
        return Encoding.UTF8.GetString(output).Trim() is { Length: > 0 } hash ? hash : null;
    }

    /// <summary>Reads a stash without touching the working tree.</summary>
    public async Task<StashContents> StashContentsAsync(string reference)
    {
        // Resolved once, so the list can't mix two entries if stash numbers shift meanwhile.
        var hash = await ResolveAsync(reference)
            ?? throw new GitException("stash", 1, "That stash no longer exists.");
        var baseHash = await ResolveAsync($"{hash}^1")
            ?? throw new GitException("stash", 1, "That entry isn’t a stash.");
        var files = RefParser.ParseNameStatus(await Git.RunAsync(
            ["diff", "--name-status", "-z", "-M", baseHash, hash], readOnly: true));
        var untracked = await ResolveAsync($"{hash}^3");
        var added = untracked is null ? [] : RefParser.ParseNameStatus(await Git.RunAsync(
            ["diff", "--name-status", "-z", EmptyTree, untracked], readOnly: true));
        return new StashContents(baseHash, hash, files, untracked, added);
    }

    /// <summary>
    /// Stashes one hunk: records it as a normal stash entry, then removes it from the working tree.
    /// The file must have no staged changes, because the stash is built on top of HEAD.
    /// </summary>
    /// <param name="forwardPatch">The hunk as a patch that applies to the index version of the file.</param>
    /// <param name="discardPatch">The same hunk as a patch that removes it from the working tree.</param>
    public async Task StashHunkAsync(string forwardPatch, string discardPatch, string path, string message)
    {
        var status = await StatusAsync();
        if (status.Staged.Any(f => f.Path == path || f.OriginalPath == path))
            throw new GitException("stash", 1,
                $"“{path}” has staged changes. Unstage it first, then stash the hunk.");
        var head = await ResolveAsync("HEAD")
            ?? throw new GitException("stash", 1, "Make a first commit before stashing a hunk.");

        var scratch = Path.Combine(OperationDetector.GitDirectory(Root), $"gitwolf-index-{Guid.NewGuid():N}");
        string tree;
        try
        {
            // A scratch index holding HEAD plus this hunk only; the real index is left alone.
            var temporary = new GitRunner(Root, GitPath,
                new Dictionary<string, string> { ["GIT_INDEX_FILE"] = scratch });
            await temporary.RunAsync(["read-tree", head]);
            await temporary.RunAsync(["apply", "--cached", "--recount", "--whitespace=nowarn", "-"],
                input: Encoding.UTF8.GetBytes(forwardPatch));
            tree = (await temporary.RunStringAsync(["write-tree"])).Trim();
        }
        finally
        {
            File.Delete(scratch);
        }

        var branch = status.Branch ?? "(no branch)";
        var subject = message.Trim();
        var full = $"On {branch}: {(subject.Length == 0 ? $"hunk of {path}" : subject)}";
        var indexCommit = (await Git.RunStringAsync(
            ["commit-tree", $"{head}^{{tree}}", "-p", head, "-m", $"index on {branch}"])).Trim();
        var stash = (await Git.RunStringAsync(
            ["commit-tree", tree, "-p", head, "-p", indexCommit, "-m", full])).Trim();
        await Git.RunAsync(["stash", "store", "-m", full, stash]);

        try
        {
            await ApplyAsync(discardPatch, PatchAction.Discard);
        }
        catch (GitException)
        {
            // Don't keep a stash of something still in the working tree. Only ever drop our own.
            if (await ResolveAsync("stash@{0}") == stash) await StashDropAsync("stash@{0}");
            throw;
        }
    }
}
