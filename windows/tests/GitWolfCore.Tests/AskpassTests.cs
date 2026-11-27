using System.Text;
using GitWolf.Core;
using Xunit;

namespace GitWolfCore.Tests;

/// <summary>Real git invokes the helper, so these also pin git's prompt format.</summary>
public sealed class AskpassTests : IDisposable
{
    private const string Token = "s3&cr|et%PATH%^\"x";

    private readonly string _dir = Path.Combine(Path.GetTempPath(), $"gitwolf ap {Guid.NewGuid()}");
    private readonly string _script;

    public AskpassTests()
    {
        Directory.CreateDirectory(_dir);
        _script = Path.Combine(_dir, GitCredential.AskpassScriptFileName);
        File.WriteAllText(_script, GitCredential.AskpassScript, new UTF8Encoding(false));
        if (!OperatingSystem.IsWindows())
            File.SetUnixFileMode(_script, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
    }

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch { /* best effort */ }
    }

    private async Task<string> FillAsync(GitCredential credential, string remoteUrl, string request, bool useHttpPath = false)
    {
        var git = new GitRunner(_dir, extraEnvironment: credential.Environment(_script, remoteUrl));
        var output = await git.RunAsync(
            ["-c", $"credential.useHttpPath={(useHttpPath ? "true" : "false")}", "credential", "fill"],
            input: Encoding.UTF8.GetBytes(request + "\n"));
        return Encoding.UTF8.GetString(output);
    }

    [Theory]
    [InlineData("https://example.invalid/o/r.git", "protocol=https\nhost=example.invalid\n", false)]
    [InlineData("git@example.invalid:o/r.git", "protocol=https\nhost=example.invalid\n", false)]
    [InlineData("https://me@Example.Invalid/o/r", "protocol=https\nhost=Example.Invalid\n", false)]
    [InlineData("https://example.invalid/o/r", "protocol=https\nhost=example.invalid\npath=o/r\n", true)]
    public async Task AnswersForTheAccountsHost(string remoteUrl, string request, bool useHttpPath)
    {
        // Shell metacharacters in the token must come through literally.
        var text = await FillAsync(new GitCredential("example.invalid", "octo", Token), remoteUrl, request, useHttpPath);

        Assert.Contains("username=octo\n", text);
        Assert.Contains($"password={Token}\n", text);
    }

    [Fact]
    public async Task ThePortIsTheAccountsNotTheRemotes()
    {
        const string other = "protocol=https\nhost=example.invalid:9999\n";
        var account = new GitCredential("example.invalid:8443", "octo", Token);

        var text = await FillAsync(account, "https://example.invalid:8443/o/r",
            "protocol=https\nhost=example.invalid:8443\n");
        Assert.Contains($"password={Token}\n", text);
        await Assert.ThrowsAsync<GitException>(() => FillAsync(account, "https://example.invalid:9999/o/r", other));
    }

    [Theory]
    [InlineData("protocol=https\nhost=evil.invalid\n")]
    [InlineData("protocol=https\nhost=example.invalid.evil.invalid\n")]
    [InlineData("protocol=https\nhost=example.invalid:8443\n")]
    [InlineData("protocol=http\nhost=example.invalid\n")]
    [InlineData("protocol=https\nhost=evil.invalid\nusername=example.invalid\n")]
    [InlineData("protocol=https\nhost=evil.invalid\nusername=a@example.invalid/\n")]
    [InlineData("protocol=https\nhost=evil.invalid\npath=@example.invalid\n")]
    public async Task RefusesEveryOtherOrigin(string request)
    {
        var credential = new GitCredential("example.invalid", "octo", Token);

        var error = await Assert.ThrowsAsync<GitException>(
            () => FillAsync(credential, "https://example.invalid/o/r", request, useHttpPath: true));
        Assert.DoesNotContain(Token, error.Message);
    }

    [Fact]
    public async Task PlainHttpNeedsAnHttpAccount()
    {
        const string request = "protocol=http\nhost=nas.invalid:3000\n";
        var secure = new GitCredential("nas.invalid:3000", "me", "t");

        await Assert.ThrowsAsync<GitException>(() => FillAsync(secure, "http://nas.invalid:3000/o/r", request));
        var text = await FillAsync(secure with { Scheme = "http" }, "http://nas.invalid:3000/o/r", request);

        Assert.Contains("password=t\n", text);
    }
}
