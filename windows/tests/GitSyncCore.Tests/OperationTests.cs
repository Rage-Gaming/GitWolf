using GitSync.Core;
using Xunit;

namespace GitSyncCore.Tests;

// Ported from InProgressOperationTests and ConflictResolutionTests.
public sealed class OperationTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), $"gitsync-operation-{Guid.NewGuid()}");
    private GitRunner Git => new(_dir);
    private GitRepository Repo => new(_dir);

    public OperationTests() => Directory.CreateDirectory(_dir);

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

    private void Write(string text, string file = "f.txt") => File.WriteAllText(Path.Combine(_dir, file), text);
    private string Read(string file = "f.txt") => File.ReadAllText(Path.Combine(_dir, file));

    private async Task CommitAsync(string message, string text, string file = "f.txt")
    {
        Write(text, file);
        await Git.RunAsync(["add", "-A"]);
        await Git.RunAsync(["commit", "-m", message]);
    }

    private async Task InitAsync()
    {
        await Git.RunAsync(["init", "-b", "main"]);
        await Git.RunAsync(["config", "user.name", "Tester"]);
        await Git.RunAsync(["config", "user.email", "t@example.com"]);
        await Git.RunAsync(["config", "commit.gpgsign", "false"]);
        await Git.RunAsync(["config", "core.autocrlf", "false"]);
    }

    /// <summary>`main` and `feature` change the same line, so merging or rebasing conflicts.</summary>
    private async Task ConflictingAsync()
    {
        await InitAsync();
        await CommitAsync("base", "one\ntwo\nthree\n");
        await Git.RunAsync(["switch", "-c", "feature"]);
        await CommitAsync("feature change", "one\nFEATURE\nthree\n");
        await Git.RunAsync(["switch", "main"]);
        await CommitAsync("main change", "one\nMAIN\nthree\n");
    }

    private Task StopOnConflictAsync(params string[] command) =>
        Assert.ThrowsAsync<GitException>(() => Git.RunAsync(command));

    [Fact]
    public async Task AMergeConflictCanBeAborted()
    {
        await ConflictingAsync();
        Assert.Null(Repo.InProgressOperation());
        await StopOnConflictAsync("merge", "feature");

        var operation = Repo.InProgressOperation()!;
        Assert.Equal((OperationKind.Merge, false, "Merging"), (operation.Kind, operation.CanSkip, operation.Title));
        Assert.Equal(operation, (await Repo.SnapshotAsync(10)).Operation);
        await Repo.AbortOperationAsync(operation);

        Assert.Null(Repo.InProgressOperation());
        Assert.Equal("one\nMAIN\nthree\n", Read());
    }

    [Fact]
    public async Task AResolvedMergeCanBeContinued()
    {
        await ConflictingAsync();
        await StopOnConflictAsync("merge", "feature");
        Assert.True((await Repo.ConflictStagesAsync("f.txt")).HasContentConflict);
        var document = (await Repo.ConflictDocumentAsync("f.txt"))!;

        var choices = new Dictionary<int, ConflictChoice> { [0] = ConflictChoice.Both };
        await Repo.ResolveConflictAsync("f.txt", document.Render(choices), document.Source);

        Assert.Empty((await Repo.StatusAsync()).Conflicted);
        Assert.Equal("one\nMAIN\nFEATURE\nthree\n", Read());
        await Repo.ContinueOperationAsync(Repo.InProgressOperation()!);
        Assert.Null(Repo.InProgressOperation());
    }

    [Fact]
    public async Task ResolvingAFileEditedMeanwhileChangesNothing()
    {
        await ConflictingAsync();
        await StopOnConflictAsync("merge", "feature");
        var document = (await Repo.ConflictDocumentAsync("f.txt"))!;
        Write("edited elsewhere\n");

        await Assert.ThrowsAsync<GitException>(() => Repo.ResolveConflictAsync("f.txt", "mine\n", document.Source));

        Assert.Equal("edited elsewhere\n", Read());
    }

    [Fact]
    public async Task ARebaseConflictReportsItsStepAndCanBeSkipped()
    {
        await ConflictingAsync();
        await Git.RunAsync(["switch", "feature"]);
        await StopOnConflictAsync("rebase", "main");

        var operation = Repo.InProgressOperation()!;
        Assert.Equal(new InProgressOperation(OperationKind.Rebase, 1, 1, "feature"), operation);
        await Repo.SkipOperationAsync(operation);

        Assert.Null(Repo.InProgressOperation());
        Assert.Equal("one\nMAIN\nthree\n", Read());
    }

    [Fact]
    public async Task ACherryPickConflictIsDetected()
    {
        await ConflictingAsync();
        await StopOnConflictAsync("cherry-pick", "feature");

        var operation = Repo.InProgressOperation()!;
        Assert.Equal(OperationKind.CherryPick, operation.Kind);
        await Repo.AbortOperationAsync(operation);
        Assert.Null(Repo.InProgressOperation());
    }

    [Theory]
    [InlineData(ConflictSide.Theirs)]
    [InlineData(ConflictSide.Delete)]
    public async Task ADeletedSideCanBeTaken(ConflictSide side)
    {
        await InitAsync();
        await CommitAsync("base", "1\n");
        await Git.RunAsync(["switch", "-c", "feature"]);
        await Git.RunAsync(["rm", "f.txt"]);
        await Git.RunAsync(["commit", "-m", "delete"]);
        await Git.RunAsync(["switch", "main"]);
        await CommitAsync("edit", "2\n");
        await StopOnConflictAsync("merge", "feature");
        Assert.Equal("Deleted by them", (await Repo.ConflictStagesAsync("f.txt")).Title);

        await Repo.ResolveConflictAsync("f.txt", side);

        Assert.Empty((await Repo.StatusAsync()).Conflicted);
        Assert.False(File.Exists(Path.Combine(_dir, "f.txt")));
    }

    [Fact]
    public void BlocksParseAndRenderChoices()
    {
        var text = "a\n<<<<<<< HEAD\nmine\n=======\ntheirs\n>>>>>>> feature\nb\n"
            + "<<<<<<< HEAD\nx\n||||||| base\nw\n=======\ny\n>>>>>>> feature\n";
        var document = ConflictDocument.Parse(text)!;

        Assert.Equal(2, document.Blocks.Count);
        Assert.Equal(("HEAD", "feature"), (document.Blocks[0].OursLabel, document.Blocks[0].TheirsLabel));
        Assert.Equal(["w"], document.Blocks[1].Base!);
        Assert.Equal("a\nmine\nb\ny\n", document.Render(new Dictionary<int, ConflictChoice>
            { [0] = ConflictChoice.Ours, [1] = ConflictChoice.Theirs }));
        Assert.Equal("a\nmine\ntheirs\nb\ny\nx\n", document.Render(new Dictionary<int, ConflictChoice>
            { [0] = ConflictChoice.Both, [1] = ConflictChoice.BothReversed }));
        Assert.Equal(text, document.Render(new Dictionary<int, ConflictChoice>()));
    }

    [Fact]
    public void LineEndingsAndAMissingFinalNewlineSurvive()
    {
        var document = ConflictDocument.Parse("a\r\n<<<<<<< HEAD\r\nmine\r\n=======\r\ntheirs\r\n>>>>>>> f\r\nend")!;

        Assert.Equal("a\r\ntheirs\r\nend",
            document.Render(new Dictionary<int, ConflictChoice> { [0] = ConflictChoice.Theirs }));
    }

    [Theory]
    [InlineData("plain\n")]
    [InlineData("<<<<<<< HEAD\nonly start\n")]
    [InlineData("=======\n>>>>>>>>\n")]
    public void TextWithoutCompleteBlocksIsIgnored(string text) => Assert.Null(ConflictDocument.Parse(text));
}
