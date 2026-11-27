using System.Net;
using System.Text;
using GitSync.Core;
using Xunit;

namespace GitSyncCore.Tests;

public sealed class AvatarCacheTests : IDisposable
{
    private static readonly RemoteLocation Repo = new("github.com", "owner/repo");
    private static readonly Uri Picture = new("https://avatars.githubusercontent.com/u/1?s=96");
    private static readonly byte[] First = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1];
    private static readonly byte[] Second = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 2];

    private readonly string _folder = Path.Combine(Path.GetTempPath(), $"gitsync-avatars-{Guid.NewGuid():N}");
    private readonly Clock _clock = new();
    private readonly List<(string Address, string? IfNoneMatch)> _requests = [];
    private Func<HttpRequestMessage, AvatarResponse> _reply = _ => Ok(First, "\"one\"");

    private sealed class Clock : TimeProvider
    {
        public DateTimeOffset Time { get; set; } = new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);
        public override DateTimeOffset GetUtcNow() => Time;
        public void Pass(TimeSpan time) => Time += time;
    }

    private static AvatarResponse Ok(byte[] body, string? tag = null) => new(body, HttpStatusCode.OK, tag);

    private static AvatarResponse Commits(string email) => Ok(Encoding.UTF8.GetBytes(
        $$$"""[{"commit":{"author":{"email":"{{{email}}}"}},"author":{"avatar_url":"{{{Picture}}}"}}]"""));

    private AvatarCache Cache(long limit = 1024 * 1024) => new(_folder, request =>
    {
        lock (_requests)
            _requests.Add((request.RequestUri!.AbsoluteUri,
                request.Headers.TryGetValues("If-None-Match", out var tags) ? tags.First() : null));
        return Task.FromResult(_reply(request));
    }, _clock, limit);

    public void Dispose()
    {
        if (Directory.Exists(_folder)) Directory.Delete(_folder, recursive: true);
    }

    [Fact]
    public async Task SavedPicturesAndAuthorsSurviveARestartWithoutRequests()
    {
        _reply = r => r.RequestUri!.Host == "api.github.com" ? Commits("a@example.com") : Ok(First);
        var cache = Cache();
        Assert.True(await cache.LookUpAsync(Repo, ["a@example.com"]));
        Assert.True(await cache.RefreshAsync(Picture));
        cache.Flush();
        _requests.Clear();

        var restarted = Cache();

        Assert.Equal(Picture, restarted.PictureFor("A@Example.com"));
        Assert.Equal(First, File.ReadAllBytes(restarted.CachedFile(Picture)!));
        Assert.False(await restarted.LookUpAsync(Repo, ["a@example.com"]));
        Assert.False(await restarted.RefreshAsync(Picture));
        Assert.Empty(_requests);
        Assert.DoesNotContain("example.com", File.ReadAllText(Path.Combine(_folder, "index.json")));
    }

    [Fact]
    public async Task AnOldPictureIsCheckedAndReplacedOnlyWhenItChanged()
    {
        var cache = Cache();
        await cache.RefreshAsync(Picture);
        var original = cache.CachedFile(Picture)!;

        _clock.Pass(TimeSpan.FromMinutes(6));
        _reply = _ => new([], HttpStatusCode.NotModified);
        Assert.False(await cache.RefreshAsync(Picture));
        Assert.Equal("\"one\"", _requests[^1].IfNoneMatch);
        Assert.False(cache.IsStale(Picture));

        _clock.Pass(TimeSpan.FromMinutes(6));
        _reply = _ => Ok(Second, "\"two\"");
        Assert.True(await cache.RefreshAsync(Picture));
        Assert.Equal(Second, File.ReadAllBytes(cache.CachedFile(Picture)!));
        Assert.False(File.Exists(original));
    }

    [Fact]
    public async Task APictureWithoutATagIsCheckedByItsDate()
    {
        var changed = new DateTimeOffset(2024, 1, 15, 3, 16, 48, TimeSpan.Zero);
        DateTimeOffset? asked = null;
        _reply = r =>
        {
            asked = r.Headers.IfModifiedSince;
            return new(First, HttpStatusCode.OK, LastModified: changed);
        };
        var cache = Cache();
        await cache.RefreshAsync(Picture);
        _clock.Pass(TimeSpan.FromMinutes(6));

        await cache.RefreshAsync(Picture);

        Assert.Equal(changed, asked);
    }

    [Fact]
    public async Task AFailureKeepsTheOldPictureAndWaitsLongerEachTime()
    {
        var cache = Cache();
        await cache.RefreshAsync(Picture);
        _clock.Pass(TimeSpan.FromMinutes(6));
        _reply = _ => throw new HttpRequestException();

        Assert.False(await cache.RefreshAsync(Picture));
        Assert.NotNull(cache.CachedFile(Picture));
        Assert.False(cache.IsStale(Picture));
        _clock.Pass(TimeSpan.FromMinutes(1));
        Assert.True(cache.IsStale(Picture));

        await cache.RefreshAsync(Picture);
        _clock.Pass(TimeSpan.FromMinutes(1));
        Assert.False(cache.IsStale(Picture));
    }

    [Fact]
    public async Task RequestsForOnePictureAreShared()
    {
        var answer = new TaskCompletionSource<AvatarResponse>();
        var count = 0;
        var cache = new AvatarCache(_folder, _ => { Interlocked.Increment(ref count); return answer.Task; }, _clock);

        var one = cache.RefreshAsync(Picture);
        var two = cache.RefreshAsync(Picture);
        answer.SetResult(Ok(First));

        Assert.True(await one);
        Assert.True(await two);
        Assert.Equal(1, count);
    }

    [Fact]
    public async Task LookupsStopUntilTheRateLimitResetsEvenAfterARestart()
    {
        _reply = _ => new([], HttpStatusCode.Forbidden, RetryAt: _clock.Time.AddHours(1));
        var cache = Cache();
        await cache.LookUpAsync(Repo, ["a@example.com"]);
        cache.Flush();

        var restarted = Cache();
        Assert.False(restarted.CanAsk(new("github.com", "other/repo")));
        _clock.Pass(TimeSpan.FromMinutes(61));
        Assert.True(restarted.CanAsk(new("github.com", "other/repo")));
    }

    [Fact]
    public async Task MorePagesAreReadOnlyWhileAuthorsAreUnknownAndOncePerDay()
    {
        var full = "[" + string.Join(",", Enumerable.Repeat("{}", 100)) + "]";
        _reply = _ => Ok(Encoding.UTF8.GetBytes(full));
        var cache = Cache();

        await cache.LookUpAsync(Repo, ["old@example.com"]);
        await cache.LookUpAsync(Repo, ["old@example.com"]);
        Assert.Equal(3, _requests.Count);

        _clock.Pass(TimeSpan.FromDays(1));
        await cache.LookUpAsync(Repo, ["1+someone@users.noreply.github.com"]);
        Assert.Equal(3, _requests.Count);
    }

    [Theory]
    [InlineData("<html>")]
    [InlineData("")]
    public async Task OnlyPicturesAreSaved(string body)
    {
        _reply = _ => Ok(Encoding.UTF8.GetBytes(body));
        var cache = Cache();
        Assert.False(await cache.RefreshAsync(Picture));
        Assert.Null(cache.CachedFile(Picture));
    }

    [Fact]
    public async Task OversizedPicturesAndOtherAddressesAreRefused()
    {
        var large = new byte[1024 * 1024 + 1];
        First.CopyTo(large, 0);
        _reply = _ => Ok(large);
        var cache = Cache(limit: 8 * 1024 * 1024);

        Assert.False(await cache.RefreshAsync(Picture));
        Assert.False(await cache.RefreshAsync(new Uri("https://evil.test/u/1")));
        Assert.Single(_requests);
    }

    [Fact]
    public async Task TheLeastRecentlyShownPicturesAreRemovedBeyondTheLimit()
    {
        var cache = Cache(limit: First.Length * 2);
        var others = Enumerable.Range(2, 2)
            .Select(i => new Uri($"https://avatars.githubusercontent.com/u/{i}?s=96")).ToList();
        await cache.RefreshAsync(Picture);
        foreach (var other in others)
        {
            _clock.Pass(TimeSpan.FromMinutes(1));
            await cache.RefreshAsync(other);
        }

        Assert.Null(cache.CachedFile(Picture));
        Assert.All(others, o => Assert.NotNull(cache.CachedFile(o)));
        Assert.Equal(2, Directory.GetFiles(_folder, "*.img").Length);
    }

    [Fact]
    public async Task ADamagedIndexStartsOverAndClearRemovesOnlyTheCachesFiles()
    {
        Directory.CreateDirectory(_folder);
        File.WriteAllText(Path.Combine(_folder, "index.json"), "{ broken");
        var other = Path.Combine(_folder, "keep.txt");
        File.WriteAllText(other, "mine");

        var cache = Cache();
        Assert.True(await cache.RefreshAsync(Picture));
        cache.Flush();
        cache.Clear();

        Assert.Equal([other], Directory.GetFiles(_folder));
        Assert.Null(cache.CachedFile(Picture));
    }
}
