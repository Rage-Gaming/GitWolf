using GitWolf.Core;
using Xunit;

namespace GitWolfCore.Tests;

/// <summary>Ported from the bisect, patch, worktree, submodule, LFS and clone option tests.</summary>
public sealed class RepositoryToolTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), $"gitwolf-tools-{Guid.NewGuid()}");

    public RepositoryToolTests() => Directory.CreateDirectory(_root);

    public void Dispose()
    {
        try
        {
            MakeWritable(_root);
            Directory.Delete(_root, recursive: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // Left in the temporary folder.
        }
    }

    /// <summary>Git marks object files read-only, which stops Windows deleting them.</summary>
    private static void MakeWritable(string directory)
    {
        foreach (var file in Directory.EnumerateFiles(directory, "*", SearchOption.AllDirectories))
            File.SetAttributes(file, FileAttributes.Normal);
    }

    private sealed record Work(string Dir)
    {
        public GitRunner Git => new(Dir);
        public GitRepository Repo => new(Dir);
        public void Write(string file, string text) => File.WriteAllText(Path.Combine(Dir, file), text);
        public string Read(string file) => File.ReadAllText(Path.Combine(Dir, file));

        public async Task<string> CommitAsync(string message, string file, string text)
        {
            Write(file, text);
            await Git.RunAsync(["add", "-A"]);
            await Git.RunAsync(["commit", "-m", message]);
            return (await Git.RunStringAsync(["rev-parse", "HEAD"])).Trim();
        }
    }

    private async Task<Work> InitAsync(string name = "work")
    {
        var work = new Work(Path.Combine(_root, name));
        Directory.CreateDirectory(work.Dir);
        await work.Git.RunAsync(["init", "-b", "main"]);
        foreach (var (key, value) in new[]
                 {
                     ("user.name", "Tester"), ("user.email", "t@example.com"), ("commit.gpgsign", "false"),
                     ("core.autocrlf", "false"), ("diff.noprefix", "true"),
                 })
            await work.Git.RunAsync(["config", key, value]);
        return work;
    }

    [Theory]
    [InlineData(5, false)]
    [InlineData(7, true)]
    public async Task BisectFindsTheFirstBadCommit(int firstBad, bool skipFirst)
    {
        var work = await InitAsync();
        var hashes = new List<string>();
        for (var i = 1; i <= 10; i++)
            hashes.Add(await work.CommitAsync($"c{i}", "n.txt", $"{(i >= firstBad ? "bad" : "ok")}\n{i}\n"));
        Assert.False(work.Repo.BisectState().IsActive);

        var state = await work.Repo.BisectStartAsync(hashes[9], hashes[0]);
        Assert.True(state.IsActive);
        Assert.NotNull(state.Progress);
        if (skipFirst)
        {
            state = await work.Repo.BisectMarkAsync(BisectMark.Skip);
            Assert.Equal(BisectMark.Skip, state.Marks[^1].Mark);
        }
        for (var steps = 0; state.FirstBad is null && steps < 10; steps++)
            state = await work.Repo.BisectMarkAsync(
                work.Read("n.txt").StartsWith("bad", StringComparison.Ordinal) ? BisectMark.Bad : BisectMark.Good);

        Assert.Equal(hashes[firstBad - 1], state.FirstBad);
        await work.Repo.BisectResetAsync();
        Assert.False(work.Repo.BisectState().IsActive);
        Assert.Equal("main", (await work.Git.RunStringAsync(["branch", "--show-current"])).Trim());
    }

    [Fact]
    public async Task PatchesRoundTripAndKeepTheMessage()
    {
        var source = await InitAsync("source");
        var start = await source.CommitAsync("base", "f.txt", "one\n");
        var target = await InitAsync("target");
        await target.Git.RunAsync(["fetch", "-q", source.Dir, "main"]);
        await target.Git.RunAsync(["reset", "--hard", start]);
        var second = await source.CommitAsync("second change", "f.txt", "one\ntwo\n");

        var files = await source.Repo.FormatPatchesAsync([second], Path.Combine(_root, "out"));
        var patch = Assert.Single(files);
        Assert.EndsWith("second-change.patch", patch);
        Assert.Null(await target.Repo.CheckPatchAsync(patch));
        await target.Repo.ApplyMailboxAsync(files);
        Assert.Equal("one\ntwo\n", target.Read("f.txt"));
        Assert.Equal("second change", (await target.Git.RunStringAsync(["log", "-1", "--format=%s"])).Trim());

        target.Write("f.txt", "one\ntwo\nthree\n");
        var diff = Path.Combine(_root, "w.diff");
        await File.WriteAllBytesAsync(diff, await target.Repo.WorkingPatchAsync(stagedOnly: false));
        await target.Git.RunAsync(["checkout", "--", "f.txt"]);
        Assert.Null(await target.Repo.CheckPatchAsync(diff));
        await target.Repo.ApplyPatchFileAsync(diff, stage: true);
        Assert.Single((await target.Repo.StatusAsync()).Staged);

        await target.Git.RunAsync(["reset", "--hard"]);
        target.Write("f.txt", "different\n");
        Assert.NotNull(await target.Repo.CheckPatchAsync(diff));
    }

    [Fact]
    public async Task AMailboxConflictIsAnOperation()
    {
        var work = await InitAsync();
        var start = await work.CommitAsync("base", "f.txt", "one\n");
        var change = await work.CommitAsync("change", "f.txt", "ONE\n");
        var files = await work.Repo.FormatPatchesAsync([change], Path.Combine(_root, "p"));
        await work.Git.RunAsync(["reset", "--hard", start]);
        await work.CommitAsync("conflicting", "f.txt", "uno\n");

        await Assert.ThrowsAsync<GitException>(() => work.Repo.ApplyMailboxAsync(files));

        var operation = work.Repo.InProgressOperation();
        Assert.Equal(OperationKind.Am, operation?.Kind);
        await work.Repo.AbortOperationAsync(operation!);
        Assert.Null(work.Repo.InProgressOperation());
    }

    [Fact]
    public async Task WorktreesAreAddedRefusedWhenDirtyAndPruned()
    {
        var work = await InitAsync();
        await work.CommitAsync("base", "f.txt", "x\n");
        var path = Path.Combine(_root, "side tree");

        await work.Repo.AddWorktreeAsync(path, "side", newBranch: true);

        var list = await work.Repo.WorktreesAsync();
        Assert.Equal(2, list.Count);
        Assert.True(list[0].IsMain);
        Assert.Equal(("main", "side"), (list[0].Branch, list[1].Branch));
        Assert.Equal("side tree", list[1].Name);
        File.WriteAllText(Path.Combine(path, "f.txt"), "dirty\n");
        await Assert.ThrowsAsync<GitException>(() => work.Repo.RemoveWorktreeAsync(list[1].Path));

        MakeWritable(path);
        Directory.Delete(path, recursive: true);
        Assert.True((await work.Repo.WorktreesAsync())[1].IsPrunable);
        await work.Repo.PruneWorktreesAsync();
        Assert.Single(await work.Repo.WorktreesAsync());
    }

    [Fact]
    public async Task ListsSubmodulesBeforeAndAfterDownload()
    {
        var lib = await InitAsync("lib");
        await lib.CommitAsync("lib", "lib.txt", "lib\n");
        var app = await InitAsync("app");
        await app.CommitAsync("app", "f.txt", "app\n");
        Assert.Empty(await app.Repo.SubmodulesAsync());
        await app.Git.RunAsync(["-c", "protocol.file.allow=always", "submodule", "add", "--", lib.Dir, "vendor/lib"]);

        var added = Assert.Single(await app.Repo.SubmodulesAsync());
        Assert.Equal(("vendor/lib", SubmoduleState.UpToDate), (added.Path, added.State));
        Assert.Equal(Path.GetFullPath(lib.Dir), Path.GetFullPath(added.Url));

        await app.Git.RunAsync(["commit", "-m", "add lib"]);
        var clone = new Work(Path.Combine(_root, "clone"));
        await app.Git.RunAsync(["clone", "-q", app.Dir, clone.Dir]);
        Assert.Equal(SubmoduleState.NotInitialized, Assert.Single(await clone.Repo.SubmodulesAsync()).State);
        await Assert.ThrowsAsync<GitException>(() => app.Repo.AddSubmoduleAsync("--evil", "x"));
    }

    [Fact]
    public async Task FindsLfsPathsAndReadsPointers()
    {
        var work = await InitAsync();
        work.Write(".gitattributes", "*.psd filter=lfs diff=lfs merge=lfs -text\n");

        var found = await work.Repo.LfsPathsAsync(["a.psd", "b.txt", "dir/c.psd"]);

        Assert.Equal(["a.psd", "dir/c.psd"], found.Order());
        Assert.Empty(await work.Repo.LfsPathsAsync([]));
        Assert.Equal(new LfsPointer("abc123", 2048),
            LfsPointer.Parse("version https://git-lfs.github.com/spec/v1\noid sha256:abc123\nsize 2048\n"));
        Assert.Null(LfsPointer.Parse("just text"));
    }

    [Fact]
    public async Task ShallowCloneCanFetchTheRest()
    {
        var origin = await InitAsync("origin");
        for (var i = 1; i <= 4; i++) await origin.CommitAsync($"c{i}", "f.txt", $"{i}\n");
        Assert.Equal(["--depth", "1", "--filter=blob:none", "--single-branch", "--branch", "main"],
            new CloneOptions(1, CloneFilter.Blobless, true, "main").Arguments);
        Assert.Empty(new CloneOptions(Branch: "--upload-pack=x").Arguments);

        // file:// so --depth is honoured for a local path.
        var destination = await GitRepository.CloneAsync(
            new Uri(origin.Dir).AbsoluteUri, _root, "shallow", options: new CloneOptions(Depth: 1));
        var repo = new GitRepository(destination);

        Assert.True(repo.IsShallow());
        Assert.Single(await repo.LogAsync(100, new HashSet<string>()));
        await repo.UnshallowAsync();
        Assert.False(repo.IsShallow());
        Assert.Equal(4, (await repo.LogAsync(100, new HashSet<string>())).Count);
    }
}
