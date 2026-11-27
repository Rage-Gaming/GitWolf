using GitWolf.Core;
using Xunit;

namespace GitWolfCore.Tests;

/// <summary>Ported from the StashSafetyTests, BranchToolsTests and TagToolsTests suites.</summary>
public sealed class BranchStashTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), $"gitwolf-branch-{Guid.NewGuid()}");
    private string Dir => Path.Combine(_root, "work");
    private string Bare => Path.Combine(_root, "remote.git");
    private GitRunner Git => new(Dir);
    private GitRepository Repo => new(Dir);

    public BranchStashTests() => Directory.CreateDirectory(Dir);

    public void Dispose()
    {
        try
        {
            foreach (var file in Directory.EnumerateFiles(_root, "*", SearchOption.AllDirectories))
                File.SetAttributes(file, FileAttributes.Normal);
            Directory.Delete(_root, recursive: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // Left in the temporary folder.
        }
    }

    private async Task<string> CommitAsync(string message, string file, string text)
    {
        Write(file, text);
        await Git.RunAsync(["add", "-A"]);
        await Git.RunAsync(["commit", "-m", message]);
        return (await Git.RunStringAsync(["rev-parse", "HEAD"])).Trim();
    }

    private void Write(string file, string text) => File.WriteAllText(Path.Combine(Dir, file), text);
    private string Read(string file) => File.ReadAllText(Path.Combine(Dir, file));

    private async Task InitAsync()
    {
        await Git.RunAsync(["init", "-b", "main"]);
        await Git.RunAsync(["config", "user.name", "Tester"]);
        await Git.RunAsync(["config", "user.email", "t@example.com"]);
        await Git.RunAsync(["config", "commit.gpgsign", "false"]);
        await Git.RunAsync(["config", "tag.gpgsign", "false"]);
        await Git.RunAsync(["config", "core.autocrlf", "false"]);
    }

    private async Task<GitRunner> WithRemoteAsync()
    {
        await InitAsync();
        await CommitAsync("base", "a.txt", "a\n");
        await Git.RunAsync(["init", "-q", "--bare", Bare]);
        await Git.RunAsync(["remote", "add", "origin", Bare]);
        await Git.RunAsync(["push", "-q", "-u", "origin", "main"]);
        return new GitRunner(Bare);
    }

    private async Task<Branch> LocalAsync(string name) =>
        (await Repo.BranchesAsync()).Local.Single(b => b.Name == name);

    private async Task<FileDiff> TwoHunksAsync()
    {
        await InitAsync();
        var lines = Enumerable.Range(1, 30).Select(i => $"line {i}").ToList();
        await CommitAsync("base", "f.txt", string.Join("\n", lines) + "\n");
        lines[1] = "TOP CHANGED";
        lines[27] = "BOTTOM CHANGED";
        Write("f.txt", string.Join("\n", lines) + "\n");
        return await Repo.DiffAsync(new DiffTarget(DiffSource.Unstaged, "f.txt", null));
    }

    private Task StashTopAsync(FileDiff diff, string message)
    {
        var ids = diff.ChangedLineIds(0);
        return Repo.StashHunkAsync(
            PatchBuilder.Make(diff, ids, PatchAction.Stage)!,
            PatchBuilder.Make(diff, ids, PatchAction.Discard)!, "f.txt", message);
    }

    [Fact]
    public async Task StashesOnlyTheChosenHunk()
    {
        var diff = await TwoHunksAsync();

        await StashTopAsync(diff, "top only");

        Assert.Contains("line 2\n", Read("f.txt"));
        Assert.DoesNotContain("TOP CHANGED", Read("f.txt"));
        Assert.Contains("BOTTOM CHANGED", Read("f.txt"));
        var stash = Assert.Single(await Repo.StashesAsync());
        Assert.Contains("top only", stash.Message);
        var contents = await Repo.StashContentsAsync(stash.Ref);
        Assert.Equal(["f.txt"], contents.Files.Select(f => f.Path));
        var stashed = await Repo.DiffAsync(new DiffTarget(contents.Source, "f.txt", null));
        Assert.Equal(1, stashed.Additions);
        Assert.Contains(stashed.Lines, l => l.Raw.Contains("TOP CHANGED"));
        Assert.DoesNotContain(stashed.Lines, l => l.Raw.Contains("BOTTOM CHANGED"));
        Assert.Empty(Directory.GetFiles(Path.Combine(Dir, ".git"), "gitwolf-index-*"));

        // Plain `stash pop` refuses here, because the file has the other change.
        await Repo.StashPopAsync("stash@{0}");

        Assert.Contains("TOP CHANGED", Read("f.txt"));
        Assert.Contains("BOTTOM CHANGED", Read("f.txt"));
        Assert.Empty(await Repo.StashesAsync());
    }

    [Fact]
    public async Task HunkStashRefusesAFileWithStagedChanges()
    {
        var diff = await TwoHunksAsync();
        await Repo.StageAsync(["f.txt"]);

        await Assert.ThrowsAsync<GitException>(() => StashTopAsync(diff, ""));

        Assert.Empty(await Repo.StashesAsync());
        Assert.Contains("TOP CHANGED", Read("f.txt"));
    }

    [Fact]
    public async Task HunkStashLeavesNothingBehindWhenTheFileMovedOn()
    {
        var diff = await TwoHunksAsync();
        Write("f.txt", Read("f.txt").Replace("TOP CHANGED", "EDITED AGAIN"));

        await Assert.ThrowsAsync<GitException>(() => StashTopAsync(diff, ""));

        Assert.Empty(await Repo.StashesAsync());
        Assert.Contains("EDITED AGAIN", Read("f.txt"));
    }

    [Fact]
    public async Task StashContentsListUntrackedFiles()
    {
        await InitAsync();
        await CommitAsync("base", "f.txt", "one\n");
        Write("f.txt", "two\n");
        Write("new.txt", "fresh\n");
        await Repo.StashPushAsync("both");

        var contents = await Repo.StashContentsAsync("stash@{0}");

        Assert.Equal(["f.txt"], contents.Files.Select(f => f.Path));
        Assert.Equal(["new.txt"], contents.UntrackedFiles.Select(f => f.Path));
        var diff = await Repo.DiffAsync(new DiffTarget(contents.UntrackedSource!.Value, "new.txt", null));
        Assert.Equal(1, diff.Additions);
        await Assert.ThrowsAsync<GitException>(() => Repo.StashContentsAsync("stash@{5}"));
    }

    [Fact]
    public async Task RenamesAndValidates()
    {
        await InitAsync();
        await CommitAsync("base", "a.txt", "a\n");
        await Git.RunAsync(["branch", "old"]);

        await Repo.RenameBranchAsync("old", "new-name");

        Assert.Contains((await Repo.BranchesAsync()).Local, b => b.Name == "new-name");
        foreach (var bad in new[] { "bad name~", "-f", "@{-1}", "" })
            await Assert.ThrowsAsync<GitException>(() => Repo.RenameBranchAsync("new-name", bad));
        await Assert.ThrowsAsync<GitException>(() => Repo.RenameBranchAsync("new-name", "main"));
    }

    [Fact]
    public async Task SetsAndClearsUpstream()
    {
        await WithRemoteAsync();
        await Git.RunAsync(["push", "-q", "origin", "main:other"]);

        await Repo.SetUpstreamAsync("main", "origin/other");
        Assert.Equal("origin/other", (await LocalAsync("main")).Upstream);

        await Repo.SetUpstreamAsync("main", null);
        Assert.Null((await LocalAsync("main")).Upstream);
    }

    [Fact]
    public async Task CleanupFindsMergedAndGoneBranchesAndKeepsTheRest()
    {
        var remote = await WithRemoteAsync();
        await Git.RunAsync(["branch", "merged-one"]);
        await Git.RunAsync(["switch", "-q", "-c", "wip"]);
        await CommitAsync("wip", "w.txt", "w\n");
        await Git.RunAsync(["switch", "-q", "-c", "shipped", "main"]);
        await CommitAsync("ship", "s.txt", "s\n");
        await Git.RunAsync(["push", "-q", "-u", "origin", "shipped"]);
        await Git.RunAsync(["switch", "-q", "main"]);
        await remote.RunAsync(["branch", "-D", "shipped"]);
        await Git.RunAsync(["fetch", "-q", "--prune"]);

        var items = await Repo.CleanupCandidatesAsync("main");

        Assert.Equal(["merged-one", "shipped"], items.Select(i => i.Name).Order());
        var gone = items.Single(i => i.Name == "shipped");
        Assert.Equal(CleanupReason.UpstreamGone, gone.Reason);
        Assert.False(gone.IsMerged);
        Assert.True(items.Single(i => i.Name == "merged-one").IsMerged);

        Assert.Empty(await Repo.DeleteBranchesAsync(items));
        Assert.Equal(["main", "wip"], (await Repo.BranchesAsync()).Local.Select(b => b.Name).Order());
    }

    [Fact]
    public async Task CleanupKeepsABranchThatMovedAfterItWasListed()
    {
        await InitAsync();
        await CommitAsync("base", "a.txt", "a\n");
        await Git.RunAsync(["branch", "later"]);
        var items = await Repo.CleanupCandidatesAsync("main");
        await Git.RunAsync(["switch", "-q", "later"]);
        await CommitAsync("new work", "n.txt", "n\n");
        await Git.RunAsync(["switch", "-q", "main"]);

        Assert.Equal(["later"], await Repo.DeleteBranchesAsync(items));

        Assert.Contains((await Repo.BranchesAsync()).Local, b => b.Name == "later");
    }

    [Fact]
    public async Task AnnotatedAndLightweightTags()
    {
        await InitAsync();
        var head = await CommitAsync("one", "a.txt", "a");
        await Repo.CreateTagAsync("light", head);
        await Repo.CreateTagAsync("v1", head, "Release one\n\nbody");

        var tags = await Repo.TagsAsync();

        var light = tags.Single(t => t.Name == "light");
        var annotated = tags.Single(t => t.Name == "v1");
        Assert.False(light.IsAnnotated);
        Assert.True(annotated.IsAnnotated);
        Assert.Equal("Release one", annotated.Message);
        Assert.Equal(head, annotated.Hash);
        Assert.Equal(head, light.Hash);
    }
}
