using System.Text;
using GitWolf.Core;
using Xunit;

namespace GitWolfCore.Tests;

// Ported from PatchTests in apple/Tests/GitWolfCoreTests/GitWolfCoreTests.swift. GitRepository.cs
// isn't ported yet, so these drive GitRunner directly with the same `git diff` / `git apply`
// argument lists GitRepository.swift uses (see GitRepository.diff / GitRepository.apply).
public sealed class PatchBuilderTests : IDisposable
{
    private readonly string _dir;
    private readonly GitRunner _runner;

    public PatchBuilderTests()
    {
        _dir = Path.Combine(Path.GetTempPath(), $"gitwolf-patch-{Guid.NewGuid()}");
        Directory.CreateDirectory(_dir);
        _runner = new GitRunner(_dir);
    }

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch { /* best effort */ }
    }

    private async Task InitRepoAsync()
    {
        await _runner.RunAsync(["init", "-b", "main"]);
        await _runner.RunAsync(["config", "user.name", "Tester"]);
        await _runner.RunAsync(["config", "user.email", "t@example.com"]);
        // Even if the user's config would change diff prefixes, our diffs must stay applicable.
        await _runner.RunAsync(["config", "diff.noprefix", "true"]);
        // Windows defaults to core.autocrlf=true, which would rewrite our LF fixtures on
        // checkout/apply; pin it off so these tests see exactly the bytes they wrote.
        await _runner.RunAsync(["config", "core.autocrlf", "false"]);
    }

    private void Write(IEnumerable<string> lines, string name = "f.txt") =>
        File.WriteAllText(Path.Combine(_dir, name), string.Join("\n", lines) + "\n");

    private async Task<FileDiff> DiffAsync(bool staged = false)
    {
        var args = new List<string>
        {
            "diff", "--no-color", "--no-ext-diff", "--no-textconv",
            "--src-prefix=a/", "--dst-prefix=b/", "-U3", "-M",
        };
        if (staged) args.Add("--cached");
        args.AddRange(["--", "f.txt"]);
        var data = await _runner.RunAsync(args, readOnly: true);
        return DiffParser.Parse(data, maxLines: 6000);
    }

    private async Task ApplyAsync(string patch, PatchAction action)
    {
        var args = new List<string> { "apply", "--recount", "--whitespace=nowarn" };
        if (action != PatchAction.Discard) args.Add("--cached");
        if (action != PatchAction.Stage) args.Add("--reverse");
        args.Add("-");
        await _runner.RunAsync(args, input: Encoding.UTF8.GetBytes(patch));
    }

    /// <summary>40 numbered lines committed, then lines 3 and 38 edited -&gt; two separate hunks.</summary>
    private async Task TwoHunkRepoAsync()
    {
        await InitRepoAsync();
        var @base = Enumerable.Range(1, 40).Select(i => $"line {i}").ToList();
        Write(@base);
        await _runner.RunAsync(["add", "f.txt"]);
        await _runner.RunAsync(["commit", "-m", "base"]);
        var edited = new List<string>(@base);
        edited[2] = "line 3 CHANGED";
        edited[37] = "line 38 CHANGED";
        Write(edited);
    }

    [Fact]
    public async Task StagesSingleHunk()
    {
        await TwoHunkRepoAsync();

        var diff = await DiffAsync();
        Assert.Equal(2, diff.Hunks.Count);
        Assert.True(diff.CanPatch);

        // Stage only the second hunk.
        var patch = PatchBuilder.Make(diff, diff.ChangedLineIds(1), PatchAction.Stage);
        Assert.NotNull(patch);
        await ApplyAsync(patch!, PatchAction.Stage);

        var staged = await DiffAsync(staged: true);
        var unstaged = await DiffAsync();
        Assert.Single(staged.Hunks);
        Assert.Contains(staged.Lines, l => l.Text == "line 38 CHANGED");
        Assert.Single(unstaged.Hunks);
        Assert.Contains(unstaged.Lines, l => l.Text == "line 3 CHANGED");
    }

    [Fact]
    public async Task StagesSingleLinesAndUnstagesThem()
    {
        await InitRepoAsync();
        Write(["a", "b", "c"]);
        await _runner.RunAsync(["add", "f.txt"]);
        await _runner.RunAsync(["commit", "-m", "base"]);
        Write(["a", "NEW1", "b", "NEW2", "c"]);

        var diff = await DiffAsync();
        var first = diff.Lines.First(l => l.Text == "NEW1");
        var patch = PatchBuilder.Make(diff, new HashSet<int> { first.Id }, PatchAction.Stage);
        Assert.NotNull(patch);
        await ApplyAsync(patch!, PatchAction.Stage);

        var staged = await DiffAsync(staged: true);
        var unstaged = await DiffAsync();
        Assert.Equal(1, staged.Additions);
        Assert.Contains(staged.Lines, l => l.Text == "NEW1");
        Assert.Equal(1, unstaged.Additions);
        Assert.Contains(unstaged.Lines, l => l.Text == "NEW2");

        // Now unstage that single line again.
        staged = await DiffAsync(staged: true);
        var line = staged.Lines.First(l => l.Text == "NEW1");
        var unstagePatch = PatchBuilder.Make(staged, new HashSet<int> { line.Id }, PatchAction.Unstage);
        Assert.NotNull(unstagePatch);
        await ApplyAsync(unstagePatch!, PatchAction.Unstage);

        staged = await DiffAsync(staged: true);
        unstaged = await DiffAsync();
        Assert.Empty(staged.Lines);
        Assert.Equal(2, unstaged.Additions);
    }

    [Fact]
    public async Task StagesPartialDeletionsAndModifications()
    {
        await InitRepoAsync();
        Write(["a", "b", "c", "d"]);
        await _runner.RunAsync(["add", "f.txt"]);
        await _runner.RunAsync(["commit", "-m", "base"]);
        Write(["a", "B2", "d"]); // b -> B2, c deleted

        var diff = await DiffAsync();
        var delC = diff.Lines.First(l => l.Kind == DiffLineKind.Deletion && l.Text == "c");
        var patch = PatchBuilder.Make(diff, new HashSet<int> { delC.Id }, PatchAction.Stage);
        Assert.NotNull(patch);
        await ApplyAsync(patch!, PatchAction.Stage);

        var staged = await DiffAsync(staged: true);
        Assert.Equal(1, staged.Deletions);
        Assert.Equal(0, staged.Additions);
        Assert.Contains(staged.Lines, l => l.Kind == DiffLineKind.Deletion && l.Text == "c");
    }

    [Fact]
    public async Task DiscardsHunk()
    {
        await TwoHunkRepoAsync();
        var diff = await DiffAsync();
        var patch = PatchBuilder.Make(diff, diff.ChangedLineIds(0), PatchAction.Discard);
        Assert.NotNull(patch);
        await ApplyAsync(patch!, PatchAction.Discard);

        var contents = File.ReadAllText(Path.Combine(_dir, "f.txt"));
        Assert.Contains("line 3\n", contents);
        Assert.DoesNotContain("line 3 CHANGED", contents);
        Assert.Contains("line 38 CHANGED", contents);
    }

    [Fact]
    public async Task PreservesCrlfAndMissingTrailingNewline()
    {
        await InitRepoAsync();
        File.WriteAllText(Path.Combine(_dir, "f.txt"), "a\r\nb\r\nc");
        await _runner.RunAsync(["add", "f.txt"]);
        await _runner.RunAsync(["commit", "-m", "base"]);
        File.WriteAllText(Path.Combine(_dir, "f.txt"), "a\r\nB\r\nc");

        var diff = await DiffAsync();
        var selected = diff.Lines.Where(l => l.IsChange).Select(l => l.Id).ToHashSet();
        var patch = PatchBuilder.Make(diff, selected, PatchAction.Stage);
        Assert.NotNull(patch);
        await ApplyAsync(patch!, PatchAction.Stage);

        var staged = await DiffAsync(staged: true);
        var unstaged = await DiffAsync();
        Assert.Empty(unstaged.Lines);
        Assert.NotEmpty(staged.Lines);
    }
}
