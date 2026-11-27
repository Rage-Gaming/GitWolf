using System.Net;
using GitWolf.Core;
using Xunit;

namespace GitWolfCore.Tests;

// Fork tests ported from ForkTests in apple/Tests/GitWolfCoreTests/GitWolfCoreTests.swift, plus tests of
// the account store and the Markdown subset.
public sealed class AccountForkTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("gitwolf-accounts").FullName;

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
            // Best effort: the folder is temporary.
        }
    }

    private sealed class MemorySecrets : ISecretStore
    {
        public Dictionary<string, string> Values { get; } = [];
        public void Save(string account, string secret) => Values[account] = secret;
        public string? Read(string account) => Values.GetValueOrDefault(account);
        public void Delete(string account) => Values.Remove(account);
    }

    private string AccountsPath => Path.Combine(_dir, "accounts.json");

    [Fact]
    public void AccountsPersistWithoutTheirSecrets()
    {
        var secrets = new MemorySecrets();
        var store = new AccountStore(AccountsPath, secrets);
        var changes = 0;
        store.Changed += () => changes++;
        store.Add(new ProviderAccount(ProviderKind.GitHub, "github.com", "octo"), "first-secret");
        var replacement = new ProviderAccount(ProviderKind.GitHub, "github.com", "octo");
        store.Add(replacement, "second-secret");
        Assert.Equal(2, changes);
        Assert.Equal(["second-secret"], secrets.Values.Values);
        Assert.DoesNotContain("secret", File.ReadAllText(AccountsPath));

        var reopened = new AccountStore(AccountsPath, secrets);
        Assert.Equal(replacement.Id, Assert.Single(reopened.Accounts).Id);
        Assert.NotNull(reopened.ForHost("GitHub.com"));
        Assert.Null(reopened.ForHost("github.example.com"));
        reopened.Remove(reopened.Accounts[0]);
        Assert.Empty(secrets.Values);
        Assert.Empty(new AccountStore(AccountsPath, secrets).Accounts);
    }

    [Fact]
    public void DamagedAccountFileEntriesAreIgnored()
    {
        File.WriteAllText(AccountsPath,
            """{"Accounts":[{"Id":"1","Kind":"github","Host":"evil.com?x=","Username":"u"},null]}""".Replace(",null", ""));
        Assert.Empty(new AccountStore(AccountsPath, new MemorySecrets()).Accounts);
        File.WriteAllText(AccountsPath, "not json");
        Assert.Empty(new AccountStore(AccountsPath, new MemorySecrets()).Accounts);
    }

    [Fact]
    public async Task CredentialsAreGivenOnlyForTheAccountsHost()
    {
        var store = new AccountStore(AccountsPath, new MemorySecrets());
        store.Add(new ProviderAccount(ProviderKind.Gitea, "git.lan:8080", "me", scheme: "http"), "tok");
        // The port is part of the server: another service on the same machine gets nothing.
        Assert.Null(await store.CredentialForRemoteAsync("git.lan"));
        Assert.Null(await store.CredentialForRemoteAsync("git.lan:9999"));
        var credential = await store.CredentialForRemoteAsync("git.lan:8080");
        Assert.Equal(("me", "tok", "http"), (credential!.Username, credential.Token, credential.Scheme));
        Assert.Null(await store.CredentialForRemoteAsync("github.com"));
    }

    [Fact]
    public async Task ExpiredSignInsRefreshOnce()
    {
        var refreshes = 0;
        var secrets = new MemorySecrets();
        var store = new AccountStore(AccountsPath, secrets, async (_, tokens) =>
        {
            Interlocked.Increment(ref refreshes);
            await Task.Delay(50);
            return tokens with { AccessToken = "new", ExpiresAt = DateTimeOffset.UtcNow.AddHours(1) };
        });
        var account = new ProviderAccount(ProviderKind.GitLab, "gitlab.com", "me", oauthClientId: "cid");
        store.AddOAuth(account, new OAuthTokens("old", "r", DateTimeOffset.UtcNow.AddMinutes(-1)));
        var results = await Task.WhenAll(store.SecretAsync(account), store.SecretAsync(account), store.SecretAsync(account));
        Assert.All(results, r => Assert.Equal("new", r));
        Assert.Equal(1, refreshes);
        Assert.Equal("oauth2", (await store.CredentialForRemoteAsync("gitlab.com"))!.Username);
    }

    [Fact]
    public void AskpassScriptIsWrittenWithLfAndNoBom()
    {
        var path = AccountStore.WriteAskpass(_dir)!;
        var bytes = File.ReadAllBytes(path);
        Assert.Equal((byte)'#', bytes[0]);
        Assert.DoesNotContain((byte)'\r', bytes);
        // An edited script is put back.
        File.WriteAllText(path, "echo stolen");
        AccountStore.WriteAskpass(_dir);
        Assert.Equal(bytes, File.ReadAllBytes(path));
    }

    [Theory]
    [InlineData("github.com", "github.com", null)]
    [InlineData("http://git.lan:8080/gitea/", "git.lan:8080/gitea", "http")]
    [InlineData("user@evil.com", null, null)]
    [InlineData("host/../x", null, null)]
    [InlineData("a b", null, null)]
    [InlineData("host?q=1", null, null)]
    public void ServerNamesAreValidated(string input, string? host, string? scheme)
    {
        var cleaned = ProviderAccount.CleanHost(input);
        Assert.Equal(host, cleaned?.Host);
        Assert.Equal(scheme, cleaned?.Scheme);
    }

    [Fact]
    public void WindowsCredentialStoreKeepsLargeSecrets()
    {
        if (!OperatingSystem.IsWindows()) return;
        var store = new WindowsCredentialStore();
        var name = $"gitwolf-test-{Guid.NewGuid():N}";
        // Longer than one credential can hold.
        var secret = new string('x', 6000) + "é";
        try
        {
            store.Save(name, secret);
            Assert.Equal(secret, store.Read(name));
            store.Save(name, "short");
            Assert.Equal("short", store.Read(name));
        }
        finally
        {
            store.Delete(name);
        }
        Assert.Null(store.Read(name));
    }

    [Fact]
    public void SecretsSavedUnderTheOldNameAreMovedOver()
    {
        if (!OperatingSystem.IsWindows()) return;
        var id = Guid.NewGuid().ToString("N");
        var (oldName, newName) = ($"gitwolf-test-old-{id}", $"gitwolf-test-new-{id}");
        var old = new WindowsCredentialStore(oldName, null);
        var store = new WindowsCredentialStore(newName, oldName);
        try
        {
            old.Save("me", "token");
            Assert.Equal("token", store.Read("me"));
            Assert.Null(old.Read("me"));
            Assert.Equal("token", new WindowsCredentialStore(newName, null).Read("me"));

            // Signing out removes a leftover old entry too.
            old.Save("me", "stale");
            store.Delete("me");
            Assert.Null(store.Read("me"));
        }
        finally
        {
            store.Delete("me");
        }
    }

    // MARK: Fork

    [Fact]
    public async Task ForkParsesCloneUrls()
    {
        var calls = new List<string>();
        async Task<RemoteRepository> Fork(ProviderKind kind, string reply, string path)
        {
            var http = new StubHttp(reply, HttpStatusCode.Accepted);
            var result = await http.Client(kind).ForkAsync(path);
            calls.AddRange(http.Calls.Select(c => $"{c.Method} {c.Url}"));
            return result;
        }
        var github = await Fork(ProviderKind.GitHub, """{"full_name":"me/r","clone_url":"https://github.com/me/r.git","ssh_url":"git@github.com:me/r.git"}""", "o/r");
        Assert.Equal(("me/r", "git@github.com:me/r.git"), (github.FullName, github.SshUrl));
        var gitlab = await Fork(ProviderKind.GitLab, """{"path_with_namespace":"me/p","http_url_to_repo":"https://gitlab.com/me/p.git","ssh_url_to_repo":"git@gitlab.com:me/p.git"}""", "g/p");
        Assert.Equal("https://gitlab.com/me/p.git", gitlab.HttpsUrl);
        var bitbucket = await Fork(ProviderKind.Bitbucket, """{"full_name":"me/r","links":{"clone":[{"name":"https","href":"https://me@bitbucket.org/me/r.git"},{"name":"ssh","href":"git@bitbucket.org:me/r.git"}]}}""", "w/r");
        Assert.Equal("https://bitbucket.org/me/r.git", bitbucket.HttpsUrl);
        Assert.Equal(
        [
            "POST https://api.github.com/repos/o/r/forks", "POST https://gitlab.com/api/v4/projects/g%2Fp/fork",
            "POST https://api.bitbucket.org/2.0/repositories/w/r/forks",
        ], calls);
        await Assert.ThrowsAsync<ProviderException>(() => new StubHttp().Client(ProviderKind.Azure).ForkAsync("x"));
    }

    [Fact]
    public async Task AdoptForkRewiresRemotes()
    {
        var work = Directory.CreateDirectory(Path.Combine(_dir, "work")).FullName;
        var git = new GitRunner(work);
        await git.RunAsync(["init", "-b", "main"]);
        await git.RunAsync(["config", "user.name", "Tester"]);
        await git.RunAsync(["config", "user.email", "t@example.com"]);
        await git.RunAsync(["commit", "--allow-empty", "-m", "one"]);
        // The server sends network addresses; they are pointed at local folders so the test stays offline.
        const string forkUrl = "https://example.invalid/me/r.git";
        const string originalUrl = "https://example.invalid/o/r.git";
        await git.RunAsync(["remote", "add", "origin", originalUrl]);
        var info = new RemoteRepository("me/r", "", false, forkUrl, "", null);
        var repo = new GitRepository(work);

        await repo.AdoptForkAsync(info, ForkRemoteMode.AddRemote("fork"), fetch: false);
        Assert.Equal(["fork", "origin"], (await repo.RemotesAsync()).Order());
        Assert.Equal(forkUrl, await repo.RemoteUrlAsync("fork"));

        await git.RunAsync(["remote", "remove", "fork"]);
        await repo.AdoptForkAsync(info, ForkRemoteMode.UseAsOrigin, fetch: false);
        Assert.Equal(forkUrl, await repo.RemoteUrlAsync("origin"));
        Assert.Equal(originalUrl, await repo.RemoteUrlAsync("upstream"));
        await Assert.ThrowsAsync<GitException>(() => repo.AdoptForkAsync(info, ForkRemoteMode.UseAsOrigin, fetch: false));
        await Assert.ThrowsAsync<GitException>(
            () => repo.AdoptForkAsync(info, ForkRemoteMode.AddRemote("--bad"), fetch: false));
        var local = info with { HttpsUrl = work };
        // A local path from the server is refused: git would fetch from this computer.
        await Assert.ThrowsAsync<ProviderException>(
            () => repo.AdoptForkAsync(local, ForkRemoteMode.AddRemote("local"), fetch: false));
    }

    // MARK: Markdown

    [Fact]
    public void MarkdownParsesTheSupportedBlocks()
    {
        var blocks = Markdown.Parse("## Title\r\n\r\ntext\n- [x] done\n1. one\n> quote\n> more\n```\n<b>code</b>\n```\n---\n<!-- hidden -->\n| a |\n");
        Assert.Equal(
        [
            MarkdownBlockKind.Heading, MarkdownBlockKind.Paragraph, MarkdownBlockKind.Task, MarkdownBlockKind.Numbered,
            MarkdownBlockKind.Quote, MarkdownBlockKind.Code, MarkdownBlockKind.Rule, MarkdownBlockKind.Table,
        ], blocks.Select(b => b.Kind));
        Assert.True(blocks[2].Checked);
        Assert.Equal("quote\nmore", blocks[4].Text);
        Assert.DoesNotContain(blocks, b => b.Text.Contains("hidden"));
    }

    [Theory]
    [InlineData("javascript:alert(1)")]
    [InlineData("file:///c:/windows/system32/calc.exe")]
    [InlineData("ms-settings:privacy")]
    [InlineData("https://user@evil.com/")]
    public void MarkdownDropsUnsafeLinks(string address)
    {
        Assert.Null(Markdown.SafeLink(address));
        Assert.All(Markdown.Inline($"[click]({address})"), span => Assert.Null(span.Link));
    }

    [Fact]
    public void MarkdownReadsInlineStyles()
    {
        var spans = Markdown.Inline("**bold** `code` [site](https://example.com) snake_case_name see https://x.org/a.");
        Assert.Contains(spans, s => s.Bold && s.Text == "bold");
        Assert.Contains(spans, s => s.Code && s.Text == "code");
        Assert.Contains(spans, s => s.Text == "site" && s.Link?.Host == "example.com");
        Assert.Contains(spans, s => s.Link?.AbsoluteUri == "https://x.org/a");
        Assert.DoesNotContain(spans, s => s.Italic);
        // Images are never downloaded: only a link with their description.
        Assert.Equal("logo", Assert.Single(Markdown.Inline("![logo](https://example.com/x.png)")).Text);
    }
}
