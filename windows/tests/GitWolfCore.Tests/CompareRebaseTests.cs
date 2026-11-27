using GitWolf.Core;
using Xunit;

namespace GitWolfCore.Tests;

/// <summary>Ported from the CompareRefsTests and RebaseTests suites.</summary>
public sealed class CompareRebaseTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), $"gitwolf rebase's {Guid.NewGuid()}");
    private GitRunner Git => new(_dir);
    private GitRepository Repo => new(_dir);
    private static readonly HashSet<string> NoRemotes = [];

    public CompareRebaseTests() => Directory.CreateDirectory(_dir);

    public void Dispose()
    {
        try
        {
            foreach (var file in Directory.EnumerateFiles(_dir, "*", SearchOption.AllDirectories))
                File.SetAttributes(file, FileAttributes.Normal);
            Directory.Delete(_dir, recursive: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // Left in the temporary folder.
        }
    }

    private bool Exists(string file) => File.Exists(Path.Combine(_dir, file));

    private async Task<string> CommitAsync(string message, string file, string text)
    {
        File.WriteAllText(Path.Combine(_dir, file), text);
        await Git.RunAsync(["add", "-A"]);
        await Git.RunAsync(["commit", "-m", message]);
        return (await Git.RunStringAsync(["rev-parse", "HEAD"])).Trim();
    }

    private async Task InitAsync()
    {
        await Git.RunAsync(["init", "-b", "main"]);
        await Git.RunAsync(["config", "user.name", "Tester"]);
        await Git.RunAsync(["config", "user.email", "t@example.com"]);
        await Git.RunAsync(["config", "commit.gpgsign", "false"]);
        await Git.RunAsync(["config", "core.autocrlf", "false"]);
    }

    /// <summary>"base" and then c1…cN, each adding fN.txt.</summary>
    private async Task<List<string>> LinearAsync(int count)
    {
        await InitAsync();
        await CommitAsync("base", "base.txt", "b\n");
        var hashes = new List<string>();
        for (var i = 1; i <= count; i++) hashes.Add(await CommitAsync($"c{i}", $"f{i}.txt", $"{i}\n"));
        return hashes;
    }

    /// <summary>main: base, m1. feature: base, f1, f2.</summary>
    private async Task DivergedAsync()
    {
        await InitAsync();
        await CommitAsync("base", "a.txt", "a\n");
        await Git.RunAsync(["switch", "-c", "feature"]);
        await CommitAsync("f1", "f1.txt", "1\n");
        await CommitAsync("f2", "f2.txt", "2\n");
        await Git.RunAsync(["switch", "main"]);
        await CommitAsync("m1", "m1.txt", "m\n");
    }

    private async Task<List<string>> SubjectsAsync() =>
        (await Git.RunStringAsync(["log", "--reverse", "--format=%s"]))
            .Split('\n', StringSplitOptions.RemoveEmptyEntries).ToList();

    private static RebasePlan With(RebasePlan plan, params (int Index, RebaseAction Action)[] actions)
    {
        var items = plan.Items.ToList();
        foreach (var (index, action) in actions) items[index] = items[index] with { Action = action };
        return plan with { Items = items };
    }

    [Fact]
    public async Task ComparesTipsAndSinceTheCommonAncestor()
    {
        await DivergedAsync();

        var tips = await Repo.CompareAsync("main", "feature", sinceAncestor: false, NoRemotes);
        Assert.Equal(["f1.txt", "f2.txt", "m1.txt"], tips.Files.Select(f => f.Path).Order());
        Assert.Equal(["f2", "f1"], tips.Commits.Select(c => c.Subject));
        Assert.Equal((2, 1), (tips.Ahead, tips.Behind));

        var since = await Repo.CompareAsync("main", "feature", sinceAncestor: true, NoRemotes);
        Assert.Equal(["f1.txt", "f2.txt"], since.Files.Select(f => f.Path).Order());
        var diff = await Repo.DiffAsync(new(DiffSource.Between(since.Base, since.Head), "f2.txt"));
        Assert.Equal(1, diff.Additions);
    }

    [Fact]
    public async Task ComparisonRejectsUnknownAndOptionLikeRefs()
    {
        await DivergedAsync();
        await Git.RunAsync(["tag", "v1", "feature"]);

        var result = await Repo.CompareAsync("feature~1", "v1", sinceAncestor: false, NoRemotes);
        Assert.Equal(["f2"], result.Commits.Select(c => c.Subject));
        await Assert.ThrowsAsync<GitException>(() => Repo.CompareAsync("main", "nope", false, NoRemotes));
        await Assert.ThrowsAsync<GitException>(() => Repo.CompareAsync("--all", "main", false, NoRemotes));
    }

    [Fact]
    public async Task RebaseReordersSquashesFixesUpDropsAndRewords()
    {
        var hashes = await LinearAsync(5);
        var (plan, merges) = await Repo.RebaseCandidatesAsync(hashes[0]);
        Assert.False(merges);
        Assert.Equal(["c1", "c2", "c3", "c4", "c5"], plan.Items.Select(i => i.Subject));

        var items = new[] { 2, 1, 0, 4, 3 }.Select(i => plan.Items[i]).ToList();
        items[0] = items[0] with { Action = RebaseAction.Reword, Message = "third, renamed\n\nit's \"quoted\" $(echo no)" };
        plan = With(plan with { Items = items },
            (1, RebaseAction.Squash), (2, RebaseAction.Drop), (4, RebaseAction.Fixup));
        await Repo.StartInteractiveRebaseAsync(plan);

        Assert.Null(Repo.InProgressOperation());
        Assert.Equal(["base", "third, renamed", "c5"], await SubjectsAsync());
        Assert.Contains("$(echo no)", await Git.RunStringAsync(["log", "-2", "--format=%B", "--skip=1"]));
        Assert.False(Directory.Exists(Path.Combine(_dir, ".git", "gitwolf-rebase")));
        Assert.True(Exists("f2.txt"));
        Assert.False(Exists("f1.txt"));
    }

    [Fact]
    public async Task RebaseFromTheRootCommit()
    {
        await LinearAsync(2);
        var root = (await Git.RunStringAsync(["rev-list", "--max-parents=0", "HEAD"])).Trim();
        var (plan, _) = await Repo.RebaseCandidatesAsync(root);
        Assert.Null(plan.Base);

        await Repo.StartInteractiveRebaseAsync(With(plan, (2, RebaseAction.Fixup)));
        Assert.Equal(["base", "c1"], await SubjectsAsync());
    }

    [Fact]
    public async Task RebaseRefusesUnusablePlansAndAMovedBranch()
    {
        var hashes = await LinearAsync(2);
        var (plan, _) = await Repo.RebaseCandidatesAsync(hashes[0]);
        Assert.NotNull(With(plan, (0, RebaseAction.Squash)).Problem);
        Assert.NotNull(With(plan, (0, RebaseAction.Drop), (1, RebaseAction.Drop)).Problem);
        var blank = plan.Items.ToList();
        blank[0] = blank[0] with { Action = RebaseAction.Reword, Message = " " };
        Assert.NotNull((plan with { Items = blank }).Problem);

        await CommitAsync("later", "later.txt", "l\n");
        await Assert.ThrowsAsync<GitException>(
            () => Repo.StartInteractiveRebaseAsync(With(plan, (1, RebaseAction.Drop))));
        Assert.Equal(["base", "c1", "c2", "later"], await SubjectsAsync());
    }

    [Fact]
    public async Task RebaseOnlyStartsFromTheCurrentBranch()
    {
        await DivergedAsync();
        var other = (await Git.RunStringAsync(["rev-parse", "feature"])).Trim();
        await Assert.ThrowsAsync<GitException>(() => Repo.RebaseCandidatesAsync(other));
    }

    [Fact]
    public async Task RebaseOntoABranchMakesHistoryLinear()
    {
        await DivergedAsync();
        await Git.RunAsync(["switch", "feature"]);
        await Repo.RebaseOntoAsync("main");
        Assert.Equal(["base", "m1", "f1", "f2"], await SubjectsAsync());
        await Assert.ThrowsAsync<GitException>(() => Repo.RebaseOntoAsync("--exec=whoami"));
    }

    [Fact]
    public async Task ARebaseConflictStaysInProgressAndAbortCleansUp()
    {
        await InitAsync();
        await CommitAsync("base", "a.txt", "a\n");
        var first = await CommitAsync("one", "a.txt", "one\n");
        await CommitAsync("two", "a.txt", "two\n");
        var (plan, _) = await Repo.RebaseCandidatesAsync(first);

        await Repo.StartInteractiveRebaseAsync(With(plan, (0, RebaseAction.Drop)));

        var operation = Repo.InProgressOperation();
        Assert.Equal(OperationKind.Rebase, operation?.Kind);
        await Repo.AbortOperationAsync(operation!);
        Assert.Null(Repo.InProgressOperation());
        Assert.False(Directory.Exists(Path.Combine(_dir, ".git", "gitwolf-rebase")));
        Assert.Equal(["base", "one", "two"], await SubjectsAsync());
    }
}
