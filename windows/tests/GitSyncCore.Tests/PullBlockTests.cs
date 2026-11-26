using GitSync.Core;
using Xunit;

namespace GitSyncCore.Tests;

public sealed class PullBlockTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), $"gitsync-pull-{Guid.NewGuid()}");
    private string Remote => Path.Combine(_dir, "remote");
    private string Local => Path.Combine(_dir, "local");

    public PullBlockTests() => Directory.CreateDirectory(Remote);

    public void Dispose()
    {
        try
        {
            // Git marks object files read-only.
            foreach (var file in Directory.EnumerateFiles(_dir, "*", SearchOption.AllDirectories))
                File.SetAttributes(file, FileAttributes.Normal);
            Directory.Delete(_dir, recursive: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // Left in the temporary folder.
        }
    }

    private static async Task ConfigureAsync(GitRunner git)
    {
        await git.RunAsync(["config", "user.name", "Tester"]);
        await git.RunAsync(["config", "user.email", "t@example.com"]);
        await git.RunAsync(["config", "core.autocrlf", "false"]);
    }

    private static async Task CommitAsync(string root, string file, string text)
    {
        var git = new GitRunner(root);
        File.WriteAllText(Path.Combine(root, file), text);
        await git.RunAsync(["add", "."]);
        await git.RunAsync(["commit", "-m", file]);
    }

    /// <summary>A clone that is one commit behind: the remote changed the first line of a.txt.</summary>
    private async Task<GitRepository> BehindAsync()
    {
        var remote = new GitRunner(Remote);
        await remote.RunAsync(["init", "-b", "main"]);
        await ConfigureAsync(remote);
        await CommitAsync(Remote, "a.txt", "1\n2\n3\n4\n5\n6\n7\n8\n");
        await new GitRunner(_dir).RunAsync(["clone", "-c", "core.autocrlf=false", Remote, Local]);
        await ConfigureAsync(new GitRunner(Local));
        await CommitAsync(Remote, "a.txt", "remote\n2\n3\n4\n5\n6\n7\n8\n");
        return new GitRepository(Local);
    }

    private string Read(string file) => File.ReadAllText(Path.Combine(Local, file));
    private void Write(string file, string text) => File.WriteAllText(Path.Combine(Local, file), text);

    [Fact]
    public async Task ARefusedPullNamesTheFiles()
    {
        var repo = await BehindAsync();
        Write("a.txt", "local\n");

        var error = await Assert.ThrowsAsync<GitException>(repo.PullAsync);

        Assert.Equal(["a.txt"], PullBlock.Parse(error.Stderr)?.Files);
        Assert.Equal("local\n", Read("a.txt"));
    }

    [Fact]
    public async Task UntrackedFilesInTheWayAreNamed()
    {
        var repo = await BehindAsync();
        await CommitAsync(Remote, "new.txt", "theirs\n");
        Write("new.txt", "mine\n");

        var error = await Assert.ThrowsAsync<GitException>(repo.PullAsync);

        Assert.Equal(["new.txt"], PullBlock.Parse(error.Stderr)?.Files);
    }

    [Fact]
    public void OtherFailuresAreNotABlock() =>
        Assert.Null(PullBlock.Parse("fatal: unable to access 'https://example.com/': Could not resolve host"));

    [Fact]
    public async Task StashAndPullKeepsStagedAndUntrackedWork()
    {
        var repo = await BehindAsync();
        Write("a.txt", "1\n2\n3\n4\n5\n6\n7\nlocal\n");
        await new GitRunner(Local).RunAsync(["add", "a.txt"]);
        Write("notes.txt", "keep\n");

        Assert.True(await repo.PullWithStashAsync());

        Assert.Equal("remote\n2\n3\n4\n5\n6\n7\nlocal\n", Read("a.txt"));
        Assert.Equal("keep\n", Read("notes.txt"));
        Assert.Empty(await repo.StashesAsync());
    }

    [Fact]
    public async Task ConflictingWorkStaysInTheStash()
    {
        var repo = await BehindAsync();
        Write("a.txt", "local\n2\n3\n4\n5\n6\n7\n8\n");

        Assert.False(await repo.PullWithStashAsync());

        Assert.Single(await repo.StashesAsync());
        Assert.Contains("local", Read("a.txt"));
    }

    [Fact]
    public async Task AFailedPullPutsTheWorkBack()
    {
        var repo = await BehindAsync();
        await new GitRunner(Local).RunAsync(["remote", "set-url", "origin", Path.Combine(_dir, "missing")]);
        Write("a.txt", "local\n");

        await Assert.ThrowsAsync<GitException>(repo.PullWithStashAsync);

        Assert.Equal("local\n", Read("a.txt"));
        Assert.Empty(await repo.StashesAsync());
    }

    [Fact]
    public async Task AnOlderStashIsLeftAlone()
    {
        var repo = await BehindAsync();
        Write("old.txt", "old\n");
        await repo.StashPushAsync("older");

        // Nothing new to set aside, so the older stash must not be popped.
        Assert.True(await repo.PullWithStashAsync());

        Assert.Single(await repo.StashesAsync());
        Assert.False(File.Exists(Path.Combine(Local, "old.txt")));
    }
}
