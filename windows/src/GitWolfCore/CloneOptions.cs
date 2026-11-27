using System.Globalization;

namespace GitWolf.Core;

public enum CloneFilter
{
    Full,
    /// <summary>History and folders now, file contents when needed.</summary>
    Blobless,
    /// <summary>Commits only: the smallest, and the slowest to browse.</summary>
    Treeless,
}

/// <summary>How much of a repository to download when cloning. Ported from CloneOptions.swift.</summary>
/// <param name="Depth">Only the latest N commits; null for the full history.</param>
/// <param name="Branch">A branch other than the remote's default.</param>
public sealed record CloneOptions(
    int? Depth = null, CloneFilter Filter = CloneFilter.Full, bool SingleBranch = false, string? Branch = null,
    bool RecurseSubmodules = false)
{
    public IReadOnlyList<string> Arguments
    {
        get
        {
            var args = new List<string>();
            if (Depth is { } depth && depth > 0)
                args.AddRange(["--depth", depth.ToString(CultureInfo.InvariantCulture)]);
            if (Filter == CloneFilter.Blobless) args.Add("--filter=blob:none");
            if (Filter == CloneFilter.Treeless) args.Add("--filter=tree:0");
            if (SingleBranch) args.Add("--single-branch");
            if (Branch?.Trim() is { Length: > 0 } branch && !branch.StartsWith('-')) args.AddRange(["--branch", branch]);
            if (RecurseSubmodules) args.Add("--recurse-submodules");
            return args;
        }
    }
}

public sealed partial class GitRepository
{
    /// <summary>True for a clone whose history is cut off at some depth. Only looks for a file.</summary>
    public bool IsShallow()
    {
        var git = OperationDetector.GitDirectory(Root);
        try
        {
            // A linked worktree keeps the marker in the main git directory, named by `commondir`.
            var common = Path.Combine(git, "commondir");
            if (File.Exists(common)) git = Path.GetFullPath(Path.Combine(git, File.ReadAllText(common).Trim()));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return false;
        }
        return File.Exists(Path.Combine(git, "shallow"));
    }

    /// <summary>Downloads the rest of a shallow clone's history.</summary>
    public async Task UnshallowAsync()
    {
        var remote = await BranchRemoteAsync(await CurrentBranchAsync(), push: false);
        var net = await RemoteGitAsync(remote, disableHooks: true);
        // A submodule's own configuration must not run with the token.
        await net.RunAsync(["fetch", "--unshallow", "--prune", "--no-recurse-submodules",
            .. remote is null ? Array.Empty<string>() : [Operand(remote)]]);
    }
}
