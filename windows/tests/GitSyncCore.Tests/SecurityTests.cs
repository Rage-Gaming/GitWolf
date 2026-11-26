using System.Net;
using System.Text;
using GitSync.Core;
using Xunit;

namespace GitSyncCore.Tests;

public sealed class SecurityTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), $"gitsync-sec-{Guid.NewGuid()}");

    public SecurityTests() => Directory.CreateDirectory(_dir);

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch { /* best effort */ }
    }

    [Theory]
    [InlineData("https://evil.example/2.0/repositories?page=2")]
    [InlineData("http://api.bitbucket.org/2.0/repositories?page=2")]
    [InlineData("https://api.bitbucket.org:8443/2.0/repositories?page=2")]
    [InlineData("https://api.bitbucket.org@evil.example/2.0/repositories")]
    public async Task BitbucketNextPageOnAnotherOriginIsNeverRequested(string next)
    {
        var requested = new List<Uri>();
        var account = new ProviderAccount(ProviderKind.Bitbucket, "bitbucket.org", "me");
        var client = new ProviderClient(account, "secret", request =>
        {
            requested.Add(request.RequestUri!);
            var body = Encoding.UTF8.GetBytes($$"""{"values":[],"next":"{{next}}"}""");
            return Task.FromResult((body, HttpStatusCode.OK));
        });

        await Assert.ThrowsAsync<ProviderException>(() => client.RepositoriesAsync());
        Assert.Single(requested);
    }

    [Fact]
    public async Task OptionLikeNamesAreRejected()
    {
        var git = await InitAsync(_dir);
        await git.RunAsync(["branch", "keep"]);
        var repo = new GitRepository(_dir);

        await Assert.ThrowsAsync<GitException>(() => repo.CreateBranchAsync("-D", "keep"));
        await Assert.ThrowsAsync<GitException>(() => repo.CheckoutCommitAsync("--orphan=x"));
        await Assert.ThrowsAsync<GitException>(() => repo.MergeAsync("--abort"));
        await Assert.ThrowsAsync<GitException>(() => repo.CreateTagAsync("-d", "keep"));
        Assert.Contains((await repo.BranchesAsync()).Local, b => b.Name == "keep");
    }

    [Fact]
    public async Task PushingABranchStartingWithPlusDoesNotForce()
    {
        var remoteDir = Path.Combine(_dir, "remote.git");
        var workDir = Path.Combine(_dir, "work");
        Directory.CreateDirectory(workDir);
        await new GitRunner(_dir).RunAsync(["init", "--bare", remoteDir]);
        var git = await InitAsync(workDir);
        await git.RunAsync(["remote", "add", "origin", remoteDir]);
        await git.RunAsync(["switch", "-c", "+topic"]);
        var repo = new GitRepository(workDir);

        await repo.PushAsync(await repo.StatusAsync(), await repo.RemotesAsync());

        var refs = await new GitRunner(remoteDir).RunStringAsync(["for-each-ref", "--format=%(refname)"]);
        Assert.Contains("refs/heads/+topic", refs);
        Assert.Equal("origin/+topic", (await repo.StatusAsync()).Upstream);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task RepositoryHooksDoNotRunDuringCredentialedFetch(bool withCredential)
    {
        var remoteDir = Path.Combine(_dir, "remote");
        var workDir = Path.Combine(_dir, "work");
        Directory.CreateDirectory(remoteDir);
        Directory.CreateDirectory(workDir);
        await InitAsync(remoteDir);
        var git = await InitAsync(workDir);
        // `origin` picks the credential and fails fast (nothing listens there); `local` updates refs.
        await git.RunAsync(["remote", "add", "origin", "https://127.0.0.1:1/repo"]);
        await git.RunAsync(["remote", "add", "local", remoteDir]);

        var marker = Path.Combine(workDir, "hook-ran");
        var hook = Path.Combine(workDir, ".git", "hooks", "reference-transaction");
        File.WriteAllText(hook, "#!/bin/sh\necho ran > hook-ran\n", new UTF8Encoding(false));
        if (!OperatingSystem.IsWindows())
            File.SetUnixFileMode(hook, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);

        var repo = new GitRepository(workDir)
        {
            Credentials = withCredential ? host => new GitCredential(host, "me", "secret") : null,
            AskpassPath = "unused",
        };
        await Assert.ThrowsAsync<GitException>(repo.FetchAsync);

        Assert.Equal(!withCredential, File.Exists(marker));
    }

    private static async Task<GitRunner> InitAsync(string dir)
    {
        var git = new GitRunner(dir);
        await git.RunAsync(["init", "-b", "main"]);
        await git.RunAsync(["config", "user.name", "Tester"]);
        await git.RunAsync(["config", "user.email", "t@example.com"]);
        await git.RunAsync(["commit", "--allow-empty", "-m", "base"]);
        return git;
    }
}
