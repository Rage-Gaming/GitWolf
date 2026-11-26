using System.Text;

namespace GitSync.Core;

/// <summary>
/// High-level git operations for one repository. Stateless: each method spawns its own git
/// process. Callers are responsible for serialising mutating operations. Ported from
/// GitRepository.swift.
/// </summary>
public sealed class GitRepository
{
    public string Root { get; }
    /// <summary>Path of the `git` executable to run.</summary>
    public string? GitPath { get; }
    /// <summary>Unchanged lines shown around each diff hunk.</summary>
    public int ContextLines { get; }

    /// <summary>
    /// Resolves a saved credential for a remote host, plus where the `GIT_ASKPASS` helper lives.
    /// Only consulted for network commands (fetch, pull, push, clone).
    /// </summary>
    public Func<string, GitCredential?>? Credentials { get; init; }
    public string? AskpassPath { get; init; }

    private GitRunner Git => new(Root, GitPath);

    private const string EmptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";

    public GitRepository(string root, string? gitPath = null, int contextLines = 4)
    {
        Root = root;
        GitPath = gitPath;
        ContextLines = Math.Clamp(contextLines, 0, 50);
    }

    public string Name => new DirectoryInfo(Root).Name;

    /// <summary>
    /// Rejects names git would read as an option (e.g. a ref called `--force`) when passed as an
    /// argument.
    /// </summary>
    private static string Operand(string value) =>
        value.StartsWith('-')
            ? throw new GitException("argument", 129, $"“{value}” can’t be used: names starting with “-” are not allowed.")
            : value;

    /// <summary>A runner for network operations, carrying the account credential for this repo's remote.</summary>
    /// <param name="disableHooks">When a credential is used, stops repository hooks from inheriting it.</param>
    private async Task<GitRunner> NetworkGitAsync(bool disableHooks = false)
    {
        if (Credentials is null || AskpassPath is null) return Git;
        try
        {
            var names = await RemotesAsync();
            var name = names.Contains("origin") ? "origin" : names.FirstOrDefault();
            if (name is null) return Git;
            var url = await Git.RunStringAsync(["remote", "get-url", name], readOnly: true);
            var location = RemoteLocation.Parse(url);
            if (location is null) return Git;
            var credential = Credentials(location.Host);
            if (credential is null) return Git;
            var env = credential.Environment(AskpassPath, url);
            if (disableHooks)
            {
                env["GIT_CONFIG_COUNT"] = "2";
                env["GIT_CONFIG_KEY_1"] = "core.hooksPath";
                env["GIT_CONFIG_VALUE_1"] = "/dev/null";
            }
            return new GitRunner(Root, GitPath, env);
        }
        catch
        {
            return Git;
        }
    }

    /// <summary>Location of the `origin` (or first) remote, if it is a recognisable URL.</summary>
    public async Task<RemoteLocation?> RemoteLocationAsync()
    {
        try
        {
            var names = await RemotesAsync();
            var name = names.Contains("origin") ? "origin" : names.FirstOrDefault();
            if (name is null) return null;
            var url = await Git.RunStringAsync(["remote", "get-url", name], readOnly: true);
            return RemoteLocation.Parse(url);
        }
        catch
        {
            return null;
        }
    }

    /// <summary>Opens the repository containing <paramref name="path"/>, resolving to its top-level directory.</summary>
    public static async Task<GitRepository> OpenAsync(string path, string? gitPath = null)
    {
        var probe = new GitRunner(path, gitPath);
        string top;
        try
        {
            top = await probe.RunStringAsync(["rev-parse", "--show-toplevel"], readOnly: true);
        }
        catch
        {
            throw new GitException("rev-parse", 128, $"“{new DirectoryInfo(path).Name}” is not a Git repository.");
        }
        return new GitRepository(top.Trim(), gitPath);
    }

    // MARK: Creating

    /// <summary>A folder name for a clone URL: `https://host/org/repo.git` -&gt; `repo`, `git@host:org/repo` -&gt; `repo`.</summary>
    public static string SuggestedName(string cloneUrl)
    {
        var s = cloneUrl.Trim();
        while (s.EndsWith('/')) s = s[..^1];
        if (s.EndsWith(".git", StringComparison.Ordinal)) s = s[..^4];
        var parts = s.Split(['/', ':', '\\'], StringSplitOptions.RemoveEmptyEntries);
        return parts.Length > 0 ? parts[^1] : "";
    }

    /// <summary>
    /// Clones <paramref name="url"/> into <paramref name="parent"/>/<paramref name="name"/> and
    /// returns the new repository's folder. <paramref name="onProgress"/> receives git's progress
    /// output (e.g. "Receiving objects: 40%").
    /// </summary>
    public static async Task<string> CloneAsync(
        string url, string parent, string name,
        string? gitPath = null,
        GitCredential? credential = null,
        string? askpassPath = null,
        Action<string>? onProgress = null,
        CancellationToken cancellationToken = default)
    {
        var destination = Path.Combine(parent, name);
        if (Directory.Exists(destination) && Directory.EnumerateFileSystemEntries(destination).Any())
        {
            throw new GitException("clone", 128, $"“{name}” already exists in that location and isn’t empty.");
        }
        var env = credential is not null && askpassPath is not null
            ? credential.Environment(askpassPath, url)
            : new Dictionary<string, string>();
        var runner = new GitRunner(parent, gitPath, env);
        await runner.RunAsync(["clone", "--progress", "--", url, name], onProgress: onProgress, cancellationToken: cancellationToken);
        return destination;
    }

    /// <summary>Creates (if needed) <paramref name="directory"/> and initialises a repository in it.</summary>
    public static async Task<string> InitializeAsync(string directory, string initialBranch, string? gitPath = null)
    {
        Directory.CreateDirectory(directory);
        var runner = new GitRunner(directory, gitPath);
        var args = new List<string> { "init" };
        var branch = initialBranch.Trim();
        if (branch.Length > 0) args.AddRange(["--initial-branch", branch]);
        await runner.RunAsync(args);
        return directory;
    }

    // MARK: Reading

    public async Task<RepositorySnapshot> SnapshotAsync(int commitLimit)
    {
        var statusTask = StatusAsync();
        var branchesTask = BranchesAsync();
        var tagsTask = TagsAsync();
        var stashesTask = StashesAsync();
        var remotes = await RemotesAsync();
        var commits = await LogAsync(commitLimit, new HashSet<string>(remotes));
        var graph = GraphLayout.Layout(commits);
        var (local, remote) = await branchesTask;

        return new RepositorySnapshot
        {
            Status = await statusTask,
            Commits = commits,
            Graph = graph,
            LocalBranches = local,
            RemoteBranches = remote,
            Tags = await tagsTask,
            Stashes = await stashesTask,
            Remotes = remotes,
        };
    }

    public async Task<WorkingStatus> StatusAsync()
    {
        var data = await Git.RunAsync(["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"], readOnly: true);
        return StatusParser.Parse(data);
    }

    public async Task<List<string>> RemotesAsync()
    {
        var @out = await Git.RunStringAsync(["remote"], readOnly: true);
        return [.. @out.Split('\n', StringSplitOptions.RemoveEmptyEntries)];
    }

    public async Task<(List<Branch> Local, List<Branch> Remote)> BranchesAsync()
    {
        var data = await Git.RunAsync(
            ["for-each-ref", $"--format={RefParser.BranchFormat}", "--sort=refname", "refs/heads", "refs/remotes"],
            readOnly: true);
        var all = RefParser.ParseBranches(data);
        return (all.Where(b => !b.IsRemote).ToList(), all.Where(b => b.IsRemote).ToList());
    }

    public async Task<List<GitTag>> TagsAsync()
    {
        var data = await Git.RunAsync(
            ["for-each-ref", "--format=%(refname:short)%1f%(objectname)", "--sort=-creatordate", "refs/tags"],
            readOnly: true);
        return RefParser.ParseTags(data);
    }

    public async Task<List<Stash>> StashesAsync()
    {
        var data = await Git.RunAsync(["stash", "list", "--format=%gd%x1f%gs%x1f%at"], readOnly: true);
        return RefParser.ParseStashes(data);
    }

    public async Task<List<Commit>> LogAsync(int limit, ISet<string> remotes)
    {
        var data = await Git.RunAsync(
            ["log", "--all", "--topo-order", "-z", "-n", limit.ToString(), $"--format={LogParser.Format}"],
            readOnly: true);
        return LogParser.Parse(data, remotes);
    }

    /// <summary>Full commit message (subject + body).</summary>
    public async Task<string> MessageAsync(string hash)
    {
        var @out = await Git.RunStringAsync(["show", "-s", "--format=%B", hash], readOnly: true);
        return @out.Trim();
    }

    public Task<string> HeadMessageAsync() => MessageAsync("HEAD");

    public async Task<List<FileChange>> FilesAsync(Commit commit)
    {
        var @base = commit.Parents.Count > 0 ? commit.Parents[0] : EmptyTree;
        var data = await Git.RunAsync(["diff", "--name-status", "-z", "-M", @base, commit.Hash], readOnly: true);
        return RefParser.ParseNameStatus(data);
    }

    public async Task<FileDiff> DiffAsync(DiffTarget target, int maxLines = 6000)
    {
        var paths = new List<string> { target.Path };
        if (target.OriginalPath is { } original) paths.Insert(0, original);

        // Explicit prefixes and no external tools so output is stable regardless of user config
        // (diff.noprefix, diff.mnemonicPrefix, ...), which `git apply` depends on.
        var common = new List<string>
        {
            "diff", "--no-color", "--no-ext-diff", "--no-textconv",
            "--src-prefix=a/", "--dst-prefix=b/", $"-U{ContextLines}", "-M",
        };

        byte[] data;
        switch (target.Source.Kind)
        {
            case DiffSourceKind.Unstaged:
            case DiffSourceKind.Conflicted:
                data = await Git.RunAsync([.. common, "--", .. paths], readOnly: true);
                break;
            case DiffSourceKind.Staged:
                data = await Git.RunAsync([.. common, "--cached", "--", .. paths], readOnly: true);
                break;
            case DiffSourceKind.Untracked:
                data = await Git.RunAsync(
                    ["diff", "--no-color", "--no-index", $"-U{ContextLines}", "--", "/dev/null", target.Path],
                    readOnly: true, allowedExitCodes: new HashSet<int> { 0, 1 });
                break;
            case DiffSourceKind.Commit:
                var hash = target.Source.CommitHash!;
                var baseHash = await ParentOrEmptyTreeAsync(hash);
                data = await Git.RunAsync([.. common, baseHash, hash, "--", .. paths], readOnly: true);
                break;
            default:
                throw new ArgumentOutOfRangeException(nameof(target));
        }
        return DiffParser.Parse(data, maxLines);
    }

    private async Task<string> ParentOrEmptyTreeAsync(string hash)
    {
        var @out = await Git.RunStringAsync(["rev-list", "--parents", "-n", "1", hash], readOnly: true);
        var parts = @out.Split([' ', '\n'], StringSplitOptions.RemoveEmptyEntries);
        return parts.Length > 1 ? parts[1] : EmptyTree;
    }

    // MARK: Staging & committing

    /// <summary>Applies a patch built by <see cref="PatchBuilder"/> (hunk/line staging, unstaging and discarding).</summary>
    public async Task ApplyAsync(string patch, PatchAction action)
    {
        var args = new List<string> { "apply", "--recount", "--whitespace=nowarn" };
        if (action.Cached()) args.Add("--cached");
        if (action.Reverse()) args.Add("--reverse");
        args.Add("-");
        await Git.RunAsync(args, input: Encoding.UTF8.GetBytes(patch));
    }

    public async Task StageAsync(IReadOnlyList<string> paths)
    {
        if (paths.Count == 0) return;
        await Git.RunAsync(["add", "--", .. paths]);
    }

    public Task StageAllAsync() => Git.RunAsync(["add", "-A"]);

    public async Task UnstageAsync(IReadOnlyList<string> paths)
    {
        if (paths.Count == 0) return;
        await Git.RunAsync(["reset", "-q", "--", .. paths]);
    }

    public Task UnstageAllAsync() => Git.RunAsync(["reset", "-q"]);

    /// <summary>Discards working-tree changes. Destructive.</summary>
    public async Task DiscardAsync(IReadOnlyList<string> tracked, IReadOnlyList<string> untracked)
    {
        if (tracked.Count > 0) await Git.RunAsync(["restore", "--", .. tracked]);
        if (untracked.Count > 0) await Git.RunAsync(["clean", "-f", "--", .. untracked]);
    }

    public async Task CommitAsync(string message, bool amend)
    {
        var args = new List<string> { "commit" };
        if (amend) args.Add("--amend");
        if (message.Trim().Length == 0) args.Add("--no-edit");
        else args.AddRange(["-m", message]);
        await Git.RunAsync(args);
    }

    // MARK: Branches

    public Task CheckoutAsync(Branch branch) =>
        branch.IsRemote ? Git.RunAsync(["switch", "--track", Operand(branch.Name)]) : Git.RunAsync(["switch", Operand(branch.Name)]);

    public Task CheckoutCommitAsync(string hash) => Git.RunAsync(["switch", "--detach", Operand(hash)]);

    public async Task CreateBranchAsync(string name, string? startPoint = null, bool checkout = false)
    {
        var args = checkout ? new List<string> { "switch", "-c", Operand(name) } : new List<string> { "branch", Operand(name) };
        if (startPoint is not null) args.Add(Operand(startPoint));
        await Git.RunAsync(args);
    }

    public Task DeleteBranchAsync(string name, bool force) => Git.RunAsync(["branch", force ? "-D" : "-d", Operand(name)]);

    public Task MergeAsync(string name) => Git.RunAsync(["merge", "--no-edit", Operand(name)]);

    public Task CherryPickAsync(string hash) => Git.RunAsync(["cherry-pick", Operand(hash)]);
    public Task RevertAsync(string hash) => Git.RunAsync(["revert", "--no-edit", Operand(hash)]);

    // MARK: Tags

    public Task CreateTagAsync(string name, string hash) => Git.RunAsync(["tag", Operand(name), Operand(hash)]);
    public Task DeleteTagAsync(string name) => Git.RunAsync(["tag", "-d", Operand(name)]);

    // MARK: Stash

    public async Task StashPushAsync(string message)
    {
        var args = new List<string> { "stash", "push", "--include-untracked" };
        if (message.Length > 0) args.AddRange(["-m", message]);
        await Git.RunAsync(args);
    }

    public Task StashApplyAsync(string reference) => Git.RunAsync(["stash", "apply", Operand(reference)]);
    public Task StashPopAsync(string reference) => Git.RunAsync(["stash", "pop", Operand(reference)]);
    public Task StashDropAsync(string reference) => Git.RunAsync(["stash", "drop", Operand(reference)]);

    // MARK: Remotes

    public async Task FetchAsync()
    {
        // Fetch also runs unattended in the background, so no hook may see the credential. Pull
        // and push keep hooks: Git LFS and users' own checks depend on them.
        var net = await NetworkGitAsync(disableHooks: true);
        await net.RunAsync(["fetch", "--all", "--prune"]);
    }

    public async Task PullAsync()
    {
        var net = await NetworkGitAsync();
        try
        {
            await net.RunAsync(["pull", "--no-edit"]);
        }
        catch (GitException error) when (error.Stderr.Contains("divergent branches"))
        {
            await net.RunAsync(["pull", "--no-edit", "--no-rebase"]);
        }
    }

    public async Task PushAsync(WorkingStatus status, IReadOnlyList<string> remotes)
    {
        var net = await NetworkGitAsync();
        if (status.Upstream is null && status.Branch is { } branch)
        {
            var remote = remotes.Contains("origin") ? "origin" : remotes.FirstOrDefault() ?? "origin";
            await net.RunAsync(["push", "--set-upstream", Operand(remote), $"refs/heads/{branch}"]);
        }
        else
        {
            await net.RunAsync(["push"]);
        }
    }
}
