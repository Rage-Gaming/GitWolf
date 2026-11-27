using System.Net;
using System.Text;
using System.Text.Json;
using GitWolf.Core;
using Xunit;

namespace GitWolfCore.Tests;

// Ported from CollabTests, CollabActionTests, CIStatusTests, NotificationTests and the issue reference
// test in apple/Tests/GitWolfCoreTests/GitWolfCoreTests.swift.
public sealed class CollabTests
{
    private static byte[] Utf8(string text) => Encoding.UTF8.GetBytes(text);

    private static JsonElement Body(StubHttp.Call call) => JsonDocument.Parse(call.Body).RootElement;

    private static string? Text(StubHttp.Call call, string name) => Body(call).GetProperty(name).GetString();

    // MARK: Lists

    [Fact]
    public async Task GitHubPullRequestsAndIssues()
    {
        var http = new StubHttp("""[{"number":7,"title":"Add thing","user":{"login":"ann"},"state":"closed","merged_at":"2026-01-02T03:04:05Z","draft":false,"labels":[{"name":"bug"}],"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-02T03:04:05Z","html_url":"https://github.com/o/r/pull/7","body":"hi","head":{"ref":"feat"},"base":{"ref":"main"}},{"number":8,"title":"WIP","user":{"login":"bob"},"state":"open","draft":true,"labels":[]}]""");
        var items = await http.Client(ProviderKind.GitHub).CollabAsync(CollabKind.PullRequest, "o/r", CollabFilter.Closed, 2);
        Assert.Equal([7, 8], items.Select(i => i.Number));
        Assert.Equal(CollabState.Merged, items[0].State);
        Assert.True(items[1].IsDraft);
        Assert.Equal(CollabState.Open, items[1].State);
        Assert.Equal(("feat", "main"), (items[0].SourceBranch, items[0].TargetBranch));
        Assert.Equal(["bug"], items[0].Labels);
        Assert.StartsWith("https://api.github.com/repos/o/r/pulls?state=closed", http.Calls[0].Url);
        Assert.Contains("page=2", http.Calls[0].Url);

        var issues = new StubHttp("""[{"number":1,"title":"Bug","user":{"login":"a"},"state":"open","comments":3},{"number":2,"title":"A PR","state":"open","pull_request":{}}]""");
        var list = await issues.Client(ProviderKind.GitHub).CollabAsync(CollabKind.Issue, "o/r", CollabFilter.Open, 1);
        // The pull request is filtered out.
        Assert.Equal([1], list.Select(i => i.Number));
        Assert.Equal(3, list[0].Comments);
    }

    [Fact]
    public async Task GitLabMergeRequestsEncodeProjectAndMergeStates()
    {
        var http = new StubHttp(url => url.Contains("state=merged")
            ? """[{"iid":4,"title":"Merged one","state":"merged","author":{"username":"zed"},"updated_at":"2026-02-02T00:00:00Z","source_branch":"a","target_branch":"main","labels":["x"],"user_notes_count":2}]"""
            : """[{"iid":5,"title":"Closed one","state":"closed","updated_at":"2026-03-02T00:00:00Z"}]""");
        var items = await http.Client(ProviderKind.GitLab, "git.acme.io")
            .CollabAsync(CollabKind.PullRequest, "grp/sub/proj", CollabFilter.Closed, 1);
        // Newest first.
        Assert.Equal([5, 4], items.Select(i => i.Number));
        Assert.Equal((CollabState.Merged, 2), (items[1].State, items[1].Comments));
        Assert.Equal(2, http.Calls.Count);
        Assert.Contains("/projects/grp%2Fsub%2Fproj/merge_requests", http.Calls[0].Url);
        Assert.Equal("t", http.Calls[0].Header("PRIVATE-TOKEN"));
    }

    [Fact]
    public async Task GiteaAndBitbucketLists()
    {
        var gitea = new StubHttp("""[{"number":3,"title":"WIP: x","state":"open","merged":false,"user":{"login":"u"},"head":{"ref":"h"},"base":{"ref":"main"}}]""");
        var first = (await gitea.Client(ProviderKind.Gitea).CollabAsync(CollabKind.PullRequest, "u/r", CollabFilter.Open, 1))[0];
        Assert.True(first.IsDraft);
        Assert.Equal("h", first.SourceBranch);

        var http = new StubHttp("""{"values":[{"id":9,"title":"BB","state":"DECLINED","author":{"display_name":"Dee"},"source":{"branch":{"name":"s"}},"destination":{"branch":{"name":"main"}},"links":{"html":{"href":"https://bitbucket.org/w/r/pull-requests/9"}}}]}""");
        var bitbucket = http.Client(ProviderKind.Bitbucket);
        var item = (await bitbucket.CollabAsync(CollabKind.PullRequest, "w/r", CollabFilter.Closed, 1))[0];
        Assert.Equal((CollabState.Closed, "Dee"), (item.State, item.Author));
        Assert.EndsWith("/9", item.Url!.AbsoluteUri);
        Assert.Contains("state=MERGED&state=DECLINED", http.Calls[0].Url);
        await Assert.ThrowsAsync<ProviderException>(
            () => bitbucket.CollabAsync(CollabKind.Issue, "w/r", CollabFilter.Open, 1));
    }

    [Fact]
    public async Task PublicAccessSendsNoCredentials()
    {
        var http = new StubHttp("[]");
        await http.Client(ProviderKind.GitHub, token: "").CollabAsync(CollabKind.PullRequest, "o/r", CollabFilter.Open, 1);
        Assert.Null(http.Calls[0].Header("Authorization"));
        Assert.False(ProviderKind.Azure.SupportsCollab(CollabKind.Issue, "dev.azure.com"));
    }

    [Fact]
    public async Task RepositoryPathsCannotClimbOutOfTheApiPath()
    {
        var http = new StubHttp("[]");
        await Assert.ThrowsAsync<ProviderException>(() => http.Client(ProviderKind.GitHub)
            .CollabAsync(CollabKind.PullRequest, "o/../../user", CollabFilter.Open, 1));
        Assert.Empty(http.Calls);
    }

    [Fact]
    public void OnlyWebLinksSurviveParsing()
    {
        var items = ProviderClient.ParseGitHubCollab(
            Utf8("""[{"number":1,"title":"t","state":"open","html_url":"file:///c:/x.exe"}]"""), CollabKind.Issue);
        Assert.Null(items[0].Url);
    }

    // MARK: Writing

    [Fact]
    public async Task GitHubCreateMergeCloseComment()
    {
        var http = new StubHttp("""{"number":7,"title":"Add x","state":"open","user":{"login":"me"},"html_url":"https://github.com/o/r/pull/7","head":{"ref":"feat"},"base":{"ref":"main"},"draft":true}""");
        var client = http.Client(ProviderKind.GitHub);
        var item = await client.CreatePullRequestAsync("o/r", "Add x", "why", "feat", "main", draft: true);
        Assert.Equal((7, true, "feat"), (item.Number, item.IsDraft, item.SourceBranch));
        Assert.Equal(("POST", "https://api.github.com/repos/o/r/pulls"), (http.Calls[0].Method, http.Calls[0].Url));
        Assert.Equal("feat", Text(http.Calls[0], "head"));
        Assert.True(Body(http.Calls[0]).GetProperty("draft").GetBoolean());
        await client.MergeAsync("o/r", 7, MergeMethod.Squash);
        Assert.Equal("PUT", http.Calls[1].Method);
        Assert.EndsWith("/pulls/7/merge", http.Calls[1].Url);
        Assert.Equal("squash", Text(http.Calls[1], "merge_method"));
        await client.SetOpenAsync(false, CollabKind.PullRequest, "o/r", 7);
        Assert.Equal(("PATCH", "closed"), (http.Calls[2].Method, Text(http.Calls[2], "state")));
        await client.AddCommentAsync(CollabKind.Issue, "o/r", 3, "hi");
        Assert.EndsWith("/issues/3/comments", http.Calls[3].Url);
        Assert.Equal("hi", Text(http.Calls[3], "body"));
        await client.SetLabelsAsync(["bug"], CollabKind.Issue, "o/r", 3);
        Assert.Equal("PUT", http.Calls[4].Method);
        Assert.EndsWith("/issues/3/labels", http.Calls[4].Url);
    }

    [Fact]
    public async Task GitLabUsesNotesAndStateEvents()
    {
        var http = new StubHttp("""{"iid":4,"title":"Draft: t","state":"opened","web_url":"https://gitlab.com/g/p/-/merge_requests/4","source_branch":"a","target_branch":"main"}""");
        var client = http.Client(ProviderKind.GitLab);
        Assert.Equal(4, (await client.CreatePullRequestAsync("g/p", "t", "", "a", "main", draft: true)).Number);
        Assert.Equal("https://gitlab.com/api/v4/projects/g%2Fp/merge_requests", http.Calls[0].Url);
        Assert.Equal("Draft: t", Text(http.Calls[0], "title"));
        await client.AddCommentAsync(CollabKind.PullRequest, "g/p", 4, "x");
        Assert.EndsWith("/merge_requests/4/notes", http.Calls[1].Url);
        await client.SetOpenAsync(false, CollabKind.Issue, "g/p", 9);
        Assert.Equal(("PUT", "close"), (http.Calls[2].Method, Text(http.Calls[2], "state_event")));
        Assert.EndsWith("/issues/9", http.Calls[2].Url);
        await client.MergeAsync("g/p", 4, MergeMethod.Merge);
        Assert.False(Body(http.Calls[3]).GetProperty("squash").GetBoolean());
        await Assert.ThrowsAsync<ProviderException>(() => client.MergeAsync("g/p", 4, MergeMethod.Rebase));
    }

    [Fact]
    public async Task BitbucketAndGiteaShapes()
    {
        var http = new StubHttp("""{"id":2,"title":"t","state":"OPEN","source":{"branch":{"name":"a"}},"destination":{"branch":{"name":"main"}}}""");
        var client = http.Client(ProviderKind.Bitbucket);
        var item = await client.CreatePullRequestAsync("w/r", "t", "d", "a", "main", draft: false);
        Assert.Equal((2, "main"), (item.Number, item.TargetBranch));
        Assert.Equal("https://api.bitbucket.org/2.0/repositories/w/r/pullrequests", http.Calls[0].Url);
        await client.MergeAsync("w/r", 2, MergeMethod.Rebase);
        Assert.Equal("fast_forward", Text(http.Calls[1], "merge_strategy"));
        await client.SetOpenAsync(false, CollabKind.PullRequest, "w/r", 2);
        Assert.EndsWith("/pullrequests/2/decline", http.Calls[2].Url);
        await Assert.ThrowsAsync<ProviderException>(() => client.SetOpenAsync(true, CollabKind.PullRequest, "w/r", 2));
        await Assert.ThrowsAsync<ProviderException>(() => client.CreateIssueAsync("w/r", "x", ""));

        var gitea = new StubHttp("""{"number":1,"title":"t","state":"open"}""");
        await gitea.Client(ProviderKind.Gitea, "git.corp.io").MergeAsync("o/r", 1, MergeMethod.Squash);
        Assert.Equal(("POST", "squash"), (gitea.Calls[^1].Method, Text(gitea.Calls[^1], "Do")));
    }

    [Fact]
    public async Task ServerReasonIsReportedForRejectedWrites()
    {
        var http = new StubHttp(
            """{"message":"Validation Failed","errors":[{"message":"A pull request already exists for o:feat."}]}""",
            HttpStatusCode.UnprocessableEntity);
        var error = await Assert.ThrowsAsync<ProviderException>(() => http.Client(ProviderKind.GitHub)
            .CreatePullRequestAsync("o/r", "t", "", "feat", "main", draft: false));
        Assert.Equal(422, error.Status);
        Assert.Contains("already exists", error.Message);
    }

    [Fact]
    public async Task ParsesComments()
    {
        var github = new StubHttp("""[{"id":1,"user":{"login":"ann"},"body":"first","created_at":"2026-01-02T03:04:05Z"}]""");
        var list = await github.Client(ProviderKind.GitHub).CommentsAsync(CollabKind.Issue, "o/r", 1);
        var only = Assert.Single(list);
        Assert.Equal(("ann", "first"), (only.Author, only.Body));
        Assert.NotNull(only.Created);
        var gitlab = new StubHttp("""[{"id":5,"author":{"username":"bo"},"body":"real","system":false},{"id":6,"author":{"username":"bo"},"body":"added 1 commit","system":true}]""");
        var notes = await gitlab.Client(ProviderKind.GitLab).CommentsAsync(CollabKind.PullRequest, "g/p", 1);
        Assert.Equal(["real"], notes.Select(c => c.Body));
    }

    // MARK: CI checks

    private static ProviderClient Checks(ProviderKind kind, params (string Contains, string Body)[] replies) =>
        new StubHttp(url => replies.FirstOrDefault(r => url.Contains(r.Contains)).Body ?? "{}").Client(kind);

    [Fact]
    public async Task GitHubCombinesCheckRunsAndStatuses()
    {
        var client = Checks(ProviderKind.GitHub,
            ("check-runs", """{"check_runs":[{"name":"build","status":"completed","conclusion":"success","html_url":"https://x/1"},{"name":"test","status":"completed","conclusion":"failure"},{"name":"lint","status":"in_progress"},{"name":"docs","status":"completed","conclusion":"skipped"}]}"""),
            ("/status", """{"statuses":[{"context":"legacy/ci","state":"success","target_url":"https://ci"}]}"""));
        var status = await client.CiStatusAsync("o/r", "abc123");
        Assert.Equal(5, status.Checks.Count);
        Assert.Equal(CheckState.Failure, status.Overall);
        Assert.Equal("1 of 5 checks failed", status.Summary);
        Assert.Equal("test", status.Checks[0].Name);
        Assert.Equal("https://x/1", status.Checks.First(c => c.Name == "build").Url?.AbsoluteUri);
        Assert.Equal(CheckState.Neutral, status.Checks.First(c => c.Name == "docs").State);
    }

    [Fact]
    public async Task OtherProvidersMapCheckStates()
    {
        var gitlab = await Checks(ProviderKind.GitLab, ("statuses", """[{"name":"unit","status":"success"},{"name":"unit","status":"failed"},{"name":"e2e","status":"running"},{"name":"x","status":"canceled"}]"""))
            .CiStatusAsync("g/p", "deadbeef");
        // The second "unit" is a duplicate name and is dropped.
        Assert.Equal(3, gitlab.Checks.Count);
        Assert.Contains(gitlab.Overall, new CheckState?[] { CheckState.Pending, CheckState.Failure });
        var gitea = await Checks(ProviderKind.Gitea, ("status", """{"statuses":[{"context":"ci","status":"pending"}]}"""))
            .CiStatusAsync("o/r", "abc");
        Assert.Equal(CheckState.Pending, gitea.Overall);
        var bitbucket = await Checks(ProviderKind.Bitbucket, ("statuses", """{"values":[{"name":"pipe","state":"SUCCESSFUL","url":"https://bb"}]}"""))
            .CiStatusAsync("w/r", "abc");
        Assert.Equal(CheckState.Success, bitbucket.Overall);
        Assert.Equal("All 1 checks passed", bitbucket.Summary);
        Assert.Null(CiStatus.None.Overall);
    }

    [Fact]
    public async Task RejectsNonHexShas()
    {
        var http = new StubHttp();
        Assert.True((await http.Client(ProviderKind.GitHub).CiStatusAsync("o/r", "../../x")).IsEmpty);
        Assert.Empty(http.Calls);
    }

    [Fact]
    public void PullRequestsCarryTheirHeadCommit()
    {
        var github = ProviderClient.ParseGitHubCollab(Utf8("""[{"number":1,"title":"t","state":"open","head":{"ref":"a","sha":"abc"},"base":{"ref":"main"}}]"""), CollabKind.PullRequest);
        Assert.Equal("abc", github[0].HeadSha);
        var gitlab = ProviderClient.ParseGitLabCollab(Utf8("""[{"iid":2,"title":"t","state":"opened","sha":"def"}]"""), CollabKind.PullRequest);
        Assert.Equal("def", gitlab[0].HeadSha);
        var bitbucket = ProviderClient.ParseBitbucketCollab(Utf8("""{"values":[{"id":3,"title":"t","state":"OPEN","source":{"branch":{"name":"a"},"commit":{"hash":"123"}}}]}"""));
        Assert.Equal("123", bitbucket[0].HeadSha);
    }

    // MARK: Notifications

    [Fact]
    public void GitHubThreadsBecomeWebLinks()
    {
        var list = ProviderClient.ParseGitHubNotifications(Utf8("""[{"id":"42","unread":true,"reason":"review_requested","updated_at":"2026-05-01T10:00:00Z","subject":{"title":"Fix login","url":"https://api.github.com/repos/o/r/pulls/12","type":"PullRequest"},"repository":{"full_name":"o/r"}},{"id":"43","reason":"mention","subject":{"title":"Question","url":"https://api.github.com/repos/o/r/issues/7","type":"Issue"},"repository":{"full_name":"o/r"}},{"id":"44","reason":"ci_activity","subject":{"title":"Run failed","url":"https://api.github.com/repos/o/r/commits/abc123","type":"CheckSuite"},"repository":{"full_name":"o/r"}}]"""), "https://github.com");
        Assert.Equal(3, list.Count);
        Assert.Equal(NotificationReason.ReviewRequested, list[0].Reason);
        Assert.True(list[0].IsPullRequest);
        Assert.Equal("https://github.com/o/r/pull/12", list[0].Url?.AbsoluteUri);
        Assert.Equal(NotificationReason.Mention, list[1].Reason);
        Assert.Equal("https://github.com/o/r/issues/7", list[1].Url?.AbsoluteUri);
        Assert.Equal(NotificationReason.Other, list[2].Reason);
        Assert.Equal("https://github.com/o/r/commit/abc123", list[2].Url?.AbsoluteUri);
    }

    [Fact]
    public void GitLabTodosAndGitea()
    {
        var todos = ProviderClient.ParseGitLabTodos(Utf8("""[{"id":9,"action_name":"review_requested","target_type":"MergeRequest","target":{"title":"Add thing"},"target_url":"https://gitlab.com/g/p/-/merge_requests/3","project":{"path_with_namespace":"g/p"}},{"id":10,"action_name":"directly_addressed","target_type":"Issue","body":"@me look","target_url":"https://gitlab.com/g/p/-/issues/4","project":{"path_with_namespace":"g/p"}}]"""));
        Assert.Equal([NotificationReason.ReviewRequested, NotificationReason.Mention], todos.Select(n => n.Reason));
        Assert.True(todos[0].IsPullRequest);
        Assert.False(todos[1].IsPullRequest);
        Assert.Equal("@me look", todos[1].Title);
        var gitea = ProviderClient.ParseGiteaNotifications(Utf8("""[{"id":5,"unread":true,"subject":{"title":"Bug","type":"Issue","html_url":"https://git.x/o/r/issues/1"},"repository":{"full_name":"o/r"}}]"""));
        Assert.Equal("o/r", gitea[0].Repository);
        Assert.Equal("git.x", gitea[0].Url?.Host);
    }

    [Fact]
    public async Task MarkReadCallsTheRightEndpoints()
    {
        var http = new StubHttp();
        var note = new ProviderNotification("7", "t", "o/r", NotificationReason.Mention, false, null, null, true);
        await http.Client(ProviderKind.GitHub).MarkReadAsync(note);
        await http.Client(ProviderKind.GitLab).MarkReadAsync(note);
        await http.Client(ProviderKind.GitHub).MarkAllReadAsync();
        Assert.Equal(
            ["PATCH /notifications/threads/7", "POST /api/v4/todos/7/mark_as_done", "PUT /notifications"],
            http.Calls.Select(c => $"{c.Method} {new Uri(c.Url).AbsolutePath}"));
    }

    // MARK: Issue references

    [Fact]
    public void ReferencesGoInAFooter()
    {
        var message = CommitMessage.AddReference("Closes", 12, "fix crash");
        Assert.Equal("fix crash\n\nCloses #12", message);
        message = CommitMessage.AddReference("Refs", 7, message);
        Assert.Equal("fix crash\n\nCloses #12\nRefs #7", message);
        Assert.Equal(message, CommitMessage.AddReference("Refs", 7, message));
        Assert.Equal("Closes #1", CommitMessage.AddReference("Closes", 1, ""));
    }
}
