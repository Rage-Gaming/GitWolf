using System.Net;
using System.Text;
using GitSync.Core;
using Xunit;

namespace GitSyncCore.Tests;

// Ported from ProviderTests in apple/Tests/GitSyncCoreTests/GitSyncCoreTests.swift.
public sealed class ProviderTests
{
    [Fact]
    public void ParsesRemoteUrls()
    {
        Assert.Equal(new RemoteLocation("github.com", "ipuppyyt/git-sync"), RemoteLocation.Parse("https://github.com/ipuppyyt/git-sync.git"));
        Assert.Equal(new RemoteLocation("gitlab.com", "group/sub/proj"), RemoteLocation.Parse("git@gitlab.com:group/sub/proj.git"));
        Assert.Equal(new RemoteLocation("bitbucket.org", "team/repo"), RemoteLocation.Parse("ssh://git@bitbucket.org:22/team/repo.git"));
        Assert.Equal(new RemoteLocation("example.com", "a/b"), RemoteLocation.Parse("https://user:secret@Example.COM/a/b/"));
        Assert.Equal(new RemoteLocation("dev.azure.com", "org/proj/_git/repo"), RemoteLocation.Parse("git@ssh.dev.azure.com:v3/org/proj/repo"));
        Assert.Null(RemoteLocation.Parse("/Users/me/local/repo"));
        Assert.Null(RemoteLocation.Parse(""));
    }

    [Fact]
    public void GuessesProviderFromHost()
    {
        Assert.Equal(ProviderKind.GitHub, ProviderKindExtensions.Guess("github.com"));
        Assert.Equal(ProviderKind.GitLab, ProviderKindExtensions.Guess("gitlab.example.org"));
        Assert.Equal(ProviderKind.Gitea, ProviderKindExtensions.Guess("codeberg.org"));
        Assert.Equal(ProviderKind.Azure, ProviderKindExtensions.Guess("dev.azure.com"));
        Assert.Null(ProviderKindExtensions.Guess("git.internal.corp"));
    }

    [Fact]
    public void BuildsWebLinks()
    {
        var loc = new RemoteLocation("github.com", "o/r");
        var gh = new WebLinks(ProviderKind.GitHub, loc);
        Assert.Equal("https://github.com/o/r", gh.Repository?.AbsoluteUri);
        Assert.Equal("https://github.com/o/r/tree/feature/x%20y", gh.Branch("feature/x y")?.AbsoluteUri);
        Assert.Equal("https://github.com/o/r/commit/abc", gh.Commit("abc")?.AbsoluteUri);
        Assert.Equal("https://github.com/o/r/compare/feature/x?expand=1", gh.NewPullRequest("feature/x")?.AbsoluteUri);

        var gl = new WebLinks(ProviderKind.GitLab, new RemoteLocation("gitlab.com", "g/p"));
        Assert.Equal("https://gitlab.com/g/p/-/commit/abc", gl.Commit("abc")?.AbsoluteUri);
        Assert.Contains("source_branch%5D=a%26b", gl.NewPullRequest("a&b")?.AbsoluteUri);
        Assert.Equal("Merge Request", gl.PullRequestsWord);

        var unknown = new WebLinks(null, new RemoteLocation("git.corp", "x/y"));
        Assert.Equal("https://git.corp/x/y", unknown.Branch("main")?.AbsoluteUri);
    }

    [Fact]
    public void AskpassEnvironmentIsolatesCredential()
    {
        var env = new GitCredential("github.com", "", "tok").Environment("C:\\tmp\\ap.sh", "https://github.com/o/r.git");
        Assert.Equal("C:\\tmp\\ap.sh", env["GIT_ASKPASS"]);
        Assert.Equal("git", env["GITSYNC_ASKPASS_USER"]);
        Assert.Equal("tok", env["GITSYNC_ASKPASS_TOKEN"]);
        Assert.Equal("credential.helper", env["GIT_CONFIG_KEY_0"]);
        Assert.Equal("", env["GIT_CONFIG_VALUE_0"]);
    }

    // Stub transport that records requests and serves canned JSON.
    private sealed class Recorder
    {
        private readonly object _lock = new();
        private readonly List<HttpRequestMessage> _log = [];
        public IReadOnlyList<HttpRequestMessage> Requests { get { lock (_lock) return [.. _log]; } }
        public int Record(HttpRequestMessage request) { lock (_lock) { _log.Add(request); return _log.Count - 1; } }
    }

    private static ProviderClient MakeClient(
        ProviderKind kind, string[] pages, string? host = null, string username = "me",
        HttpStatusCode status = HttpStatusCode.OK, Recorder? recorder = null)
    {
        recorder ??= new Recorder();
        var account = new ProviderAccount(kind, host ?? kind.DefaultHost(), username);
        return new ProviderClient(account, "secret", request =>
        {
            var index = recorder.Record(request);
            var body = pages[Math.Min(index, pages.Length - 1)];
            return Task.FromResult((Encoding.UTF8.GetBytes(body), status));
        });
    }

    [Fact]
    public async Task ListsGitHubRepositories()
    {
        var rec = new Recorder();
        var c = MakeClient(ProviderKind.GitHub,
            ["""[{"full_name":"o/r","description":null,"private":true,"clone_url":"https://github.com/o/r.git","ssh_url":"git@github.com:o/r.git","pushed_at":"2026-01-02T03:04:05Z"}]"""],
            recorder: rec);
        var repos = await c.RepositoriesAsync();

        Assert.Single(repos);
        Assert.Equal("o/r", repos[0].FullName);
        Assert.True(repos[0].IsPrivate);
        Assert.NotNull(repos[0].Updated);
        Assert.Equal("r", repos[0].Name);
        Assert.Equal("Bearer secret", rec.Requests[0].Headers.Authorization?.ToString());
        Assert.Equal("api.github.com", rec.Requests[0].RequestUri?.Host);
    }

    [Fact]
    public async Task ListsGitLabRepositoriesFromSelfHostedHost()
    {
        var rec = new Recorder();
        var c = MakeClient(ProviderKind.GitLab,
            ["""[{"path_with_namespace":"g/p","description":"d","visibility":"internal","http_url_to_repo":"https://git.corp.io/g/p.git","ssh_url_to_repo":"git@git.corp.io:g/p.git","last_activity_at":"2026-01-02T03:04:05.123Z"}]"""],
            host: "git.corp.io", recorder: rec);
        var repos = await c.RepositoriesAsync();

        Assert.Equal("https://git.corp.io/g/p.git", repos.FirstOrDefault()?.HttpsUrl);
        Assert.True(repos.FirstOrDefault()?.IsPrivate);
        Assert.StartsWith("https://git.corp.io/api/v4/projects", rec.Requests[0].RequestUri?.AbsoluteUri);
        Assert.Equal("secret", rec.Requests[0].Headers.GetValues("PRIVATE-TOKEN").First());
    }

    [Fact]
    public async Task SupportsEnterpriseHosts()
    {
        var rec = new Recorder();
        var ghe = MakeClient(ProviderKind.GitHub, ["[]"], host: "github.acme.com", recorder: rec);
        await ghe.RepositoriesAsync();
        Assert.StartsWith("https://github.acme.com/api/v3/user/repos", rec.Requests[0].RequestUri?.AbsoluteUri);

        var rec2 = new Recorder();
        var account = new ProviderAccount(ProviderKind.GitLab, "git.lan:8080", "me", scheme: "http");
        var lan = new ProviderClient(account, "t", request =>
        {
            rec2.Record(request);
            return Task.FromResult((Encoding.UTF8.GetBytes("[]"), HttpStatusCode.OK));
        });
        await lan.RepositoriesAsync();
        Assert.StartsWith("http://git.lan:8080/api/v4/projects", rec2.Requests[0].RequestUri?.AbsoluteUri);
        Assert.Equal("git.lan", account.HostName);

        var rec3 = new Recorder();
        var dc = MakeClient(ProviderKind.Bitbucket,
            ["""{"isLastPage":true,"values":[{"slug":"r","project":{"key":"P"},"public":false,"links":{"clone":[{"name":"http","href":"https://me@bitbucket.acme.com/scm/p/r.git"},{"name":"ssh","href":"ssh://git@bitbucket.acme.com/p/r.git"}]}}]}"""],
            host: "bitbucket.acme.com", recorder: rec3);
        var repos = await dc.RepositoriesAsync();
        Assert.Equal("P/r", repos.FirstOrDefault()?.FullName);
        Assert.Equal("https://bitbucket.acme.com/scm/p/r.git", repos.FirstOrDefault()?.HttpsUrl);
        Assert.Equal("Bearer secret", rec3.Requests[0].Headers.Authorization?.ToString());
        Assert.Equal("/rest/api/1.0/repos", rec3.Requests[0].RequestUri?.AbsolutePath);
    }

    [Fact]
    public async Task PasswordAccountsUseBasicAuth()
    {
        var rec = new Recorder();
        var account = new ProviderAccount(ProviderKind.Gitea, "git.corp.io", "me", usesPassword: true);
        var c = new ProviderClient(account, "pw", request =>
        {
            rec.Record(request);
            return Task.FromResult((Encoding.UTF8.GetBytes("[]"), HttpStatusCode.OK));
        });
        await c.RepositoriesAsync();

        var expected = "Basic " + Convert.ToBase64String(Encoding.UTF8.GetBytes("me:pw"));
        Assert.Equal(expected, rec.Requests[0].Headers.Authorization?.ToString());
    }

    [Fact]
    public async Task ListsGiteaAndBitbucketRepositories()
    {
        var gitea = MakeClient(ProviderKind.Gitea,
            ["""[{"full_name":"u/r","clone_url":"https://codeberg.org/u/r.git","ssh_url":"x","private":false,"updated_at":"2026-01-02T03:04:05Z"}]"""]);
        Assert.Equal("u/r", (await gitea.RepositoriesAsync()).FirstOrDefault()?.FullName);

        var bb = MakeClient(ProviderKind.Bitbucket, username: "me", pages:
        [
            """{"values":[{"full_name":"t/a","is_private":true,"links":{"clone":[{"name":"https","href":"https://me@bitbucket.org/t/a.git"},{"name":"ssh","href":"git@bitbucket.org:t/a.git"}]}}],"next":"https://api.bitbucket.org/2.0/repositories?page=2"}""",
            """{"values":[{"full_name":"t/b","is_private":false,"links":{"clone":[{"name":"https","href":"https://bitbucket.org/t/b.git"}]}}]}""",
        ]);
        var repos = await bb.RepositoriesAsync();
        Assert.Equal(["t/a", "t/b"], repos.Select(r => r.FullName));
        Assert.Equal("https://bitbucket.org/t/a.git", repos[0].HttpsUrl); // username stripped
    }

    [Fact]
    public async Task VerifiesTokenAndReportsRejection()
    {
        var ok = MakeClient(ProviderKind.GitHub, ["""{"login":"octo"}"""]);
        Assert.Equal("octo", await ok.CurrentUserAsync());

        var bad = MakeClient(ProviderKind.GitLab, ["{}"], status: HttpStatusCode.Unauthorized);
        await Assert.ThrowsAsync<ProviderException>(() => bad.CurrentUserAsync());
    }

    [Fact]
    public async Task PaginatesUntilShortPage()
    {
        var rec = new Recorder();
        var full = "[" + string.Join(",", Enumerable.Range(0, 100).Select(i => $$"""{"full_name":"o/r{{i}}","clone_url":"u"}""")) + "]";
        var c = MakeClient(ProviderKind.GitHub, [full, """[{"full_name":"o/last","clone_url":"u"}]"""], recorder: rec);
        var repos = await c.RepositoriesAsync();

        Assert.Equal(101, repos.Count);
        Assert.Equal(2, rec.Requests.Count);
    }
}
