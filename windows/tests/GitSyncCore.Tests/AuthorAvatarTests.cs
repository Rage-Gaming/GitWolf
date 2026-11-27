using System.Net;
using System.Text;
using GitSync.Core;
using Xunit;

namespace GitSyncCore.Tests;

public sealed class AuthorAvatarTests
{
    private static readonly RemoteLocation Repo = new("github.com", "owner/repo");

    private static AvatarTransport Reply(string body, HttpStatusCode status = HttpStatusCode.OK) =>
        _ => Task.FromResult(new AvatarResponse(Encoding.UTF8.GetBytes(body), status));

    [Fact]
    public void PrivateGitHubAddressesNameTheirPicture()
    {
        Assert.Equal("https://avatars.githubusercontent.com/u/42?s=96",
            AuthorAvatars.FromEmail("42+Some-One@users.noreply.github.com")?.AbsoluteUri);
        Assert.Equal("https://avatars.githubusercontent.com/octocat?s=96",
            AuthorAvatars.FromEmail("octocat@users.noreply.github.com")?.AbsoluteUri);
        Assert.Null(AuthorAvatars.FromEmail("someone@example.com"));
        Assert.Null(AuthorAvatars.FromEmail("../x@users.noreply.github.com"));
        Assert.Null(AuthorAvatars.FromEmail("a@users.noreply.github.com.evil.test"));
    }

    [Fact]
    public async Task PicturesComeFromRecentCommitsAndOnlyFromThePictureHost()
    {
        const string body = """
            [
              {"commit":{"author":{"email":"a@example.com"},"committer":{"email":"c@example.com"}},
               "author":{"avatar_url":"https://avatars.githubusercontent.com/u/1?v=4"},
               "committer":{"avatar_url":"https://avatars.githubusercontent.com/u/2?v=4"}},
              {"commit":{"author":{"email":"evil@example.com"},"committer":{"email":"http@example.com"}},
               "author":{"avatar_url":"https://evil.test/u/3"},
               "committer":{"avatar_url":"http://avatars.githubusercontent.com/u/4"}},
              {"commit":{"author":{"email":"unknown@example.com"}},"author":null}
            ]
            """;

        var found = (await AuthorAvatars.FetchPageAsync(Repo, 1, Reply(body))).Found;

        Assert.Equal(["a@example.com", "c@example.com"], found.Keys.Order());
        Assert.Equal("https://avatars.githubusercontent.com/u/1?s=96", found["A@Example.com"].AbsoluteUri);
    }

    [Fact]
    public async Task FailuresAndOtherHostsGiveNoPictures()
    {
        foreach (var failing in new[]
        {
            Reply("{}", HttpStatusCode.Forbidden), Reply("not json"), _ => throw new HttpRequestException(),
        })
        {
            var page = await AuthorAvatars.FetchPageAsync(Repo, 1, failing);
            Assert.True(page.Failed);
            Assert.Empty(page.Found);
        }

        var asked = false;
        AvatarTransport never = _ => { asked = true; return Reply("[]")(_); };
        await AuthorAvatars.FetchPageAsync(new("gitlab.com", "owner/repo"), 1, never);
        await AuthorAvatars.FetchPageAsync(new("github.com", "owner/.."), 1, never);
        await AuthorAvatars.FetchPageAsync(new("github.com", "owner/repo?x=1"), 1, never);
        Assert.False(asked);
    }
}
