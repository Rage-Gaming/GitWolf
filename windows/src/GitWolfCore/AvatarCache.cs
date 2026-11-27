using System.Diagnostics;
using System.Net;
using System.Net.Http.Headers;

namespace GitWolf.Core;

/// <summary>
/// Profile pictures and who they belong to, kept on disk. What is saved is used straight away, and is
/// checked with GitHub only when it may be out of date. Safe to use from any thread.
/// </summary>
public sealed partial class AvatarCache
{
    /// <summary>GitHub allows its pictures to be reused this long before asking again.</summary>
    private static readonly TimeSpan PictureFresh = TimeSpan.FromMinutes(5);
    private static readonly TimeSpan LookupInterval = TimeSpan.FromDays(1);
    private static readonly TimeSpan AuthorFresh = TimeSpan.FromDays(30);
    private static readonly TimeSpan LongestWait = TimeSpan.FromDays(1);
    private const int MaxPages = 3;
    private const int MaxPictureBytes = 1024 * 1024;

    private readonly string _folder;
    private readonly AvatarTransport _transport;
    private readonly TimeProvider _clock;
    private readonly long _limit;
    private readonly object _gate = new();
    private readonly SemaphoreSlim _downloads = new(4);
    private readonly Dictionary<Uri, Task<bool>> _refreshing = [];
    private readonly HashSet<string> _lookingUp = [];
    private int _generation;

    public AvatarCache(string folder, AvatarTransport? transport = null, TimeProvider? clock = null,
        long limit = 20 * 1024 * 1024)
    {
        _folder = folder;
        _transport = transport ?? AvatarHttp.Transport;
        _clock = clock ?? TimeProvider.System;
        _limit = limit;
    }

    private DateTimeOffset Now => _clock.GetUtcNow();

    private static string AuthorKey(string email) => Hash(email.Trim().ToLowerInvariant());

    /// <summary>The address of an author's picture, if known. Makes no request.</summary>
    public Uri? PictureFor(string email)
    {
        if (AuthorAvatars.FromEmail(email) is { } direct) return direct;
        var key = AuthorKey(email);
        lock (_gate)
            return Index.Authors.TryGetValue(key, out var author) ? new Uri(author.Address) : null;
    }

    /// <summary>The saved copy of a picture, if there is one. Counts as showing it.</summary>
    public string? CachedFile(Uri picture)
    {
        lock (_gate)
        {
            if (!Index.Pictures.TryGetValue(picture.AbsoluteUri, out var entry) || entry.File is null) return null;
            // Recorded once a day, which is exact enough for removing old pictures.
            if (Now - entry.Used > TimeSpan.FromDays(1))
            {
                entry.Used = Now;
                SaveSoon();
            }
            return Path.Combine(_folder, entry.File);
        }
    }

    /// <summary>Whether a repository may be looked up now.</summary>
    public bool CanAsk(RemoteLocation location)
    {
        if (!AuthorAvatars.CanLookUp(location)) return false;
        var key = Hash(location.Path.ToLowerInvariant());
        lock (_gate)
            return Now >= Index.LookupsBlockedUntil && !_lookingUp.Contains(key)
                && (!Index.Repositories.TryGetValue(key, out var schedule) || Now >= schedule.NextTry);
    }

    /// <summary>
    /// Looks up a repository's authors if any of these is unknown or was learnt long ago, at most daily.
    /// True when a picture address was learnt or changed.
    /// </summary>
    public async Task<bool> LookUpAsync(
        RemoteLocation location, IEnumerable<string> emails, string? token = null)
    {
        if (!CanAsk(location)) return false;
        var key = Hash(location.Path.ToLowerInvariant());
        HashSet<string> wanted;
        int generation;
        lock (_gate)
        {
            wanted = emails.Where(e => AuthorAvatars.FromEmail(e) is null).Select(AuthorKey)
                .Where(a => !Index.Authors.TryGetValue(a, out var known) || Now - known.Learned > AuthorFresh)
                .ToHashSet();
            if (wanted.Count == 0 || !_lookingUp.Add(key)) return false;
            generation = _generation;
        }
        var changed = false;
        try
        {
            for (var page = 1; page <= MaxPages; page++)
            {
                var reply = await AuthorAvatars.FetchPageAsync(location, page, _transport, token)
                    .ConfigureAwait(false);
                lock (_gate)
                {
                    if (generation != _generation) return false;
                    if (reply.RetryAt is { } until) Index.LookupsBlockedUntil = Earliest(until, Now + LongestWait);
                    foreach (var (email, picture) in reply.Found)
                    {
                        var author = AuthorKey(email);
                        wanted.Remove(author);
                        changed |= !Index.Authors.TryGetValue(author, out var old) || old.Address != picture.AbsoluteUri;
                        Index.Authors[author] = new() { Address = picture.AbsoluteUri, Learned = Now };
                    }
                    var schedule = Index.Repositories.GetValueOrDefault(key) ?? new Schedule();
                    schedule.Failures = reply.Failed ? schedule.Failures + 1 : 0;
                    schedule.NextTry = Now + (reply.Failed ? Backoff(schedule.Failures) : LookupInterval);
                    Index.Repositories[key] = schedule;
                    SaveSoon();
                    if (reply.Failed || !reply.HasMore || wanted.Count == 0 || reply.RetryAt is not null) break;
                }
            }
        }
        finally
        {
            lock (_gate) _lookingUp.Remove(key);
        }
        return changed;
    }

    /// <summary>
    /// Allows every repository to be looked up again, for example after signing in, which brings its own
    /// request limit. What was learnt is kept.
    /// </summary>
    public void Forget()
    {
        lock (_gate)
        {
            Index.Repositories.Clear();
            Index.LookupsBlockedUntil = default;
            SaveSoon();
        }
    }

    /// <summary>Whether a picture is missing or old enough to be checked.</summary>
    public bool IsStale(Uri picture)
    {
        lock (_gate)
        {
            if (_refreshing.ContainsKey(picture)) return false;
            return !Index.Pictures.TryGetValue(picture.AbsoluteUri, out var entry)
                || (Now >= entry.NextTry && (entry.File is null || Now - entry.Checked >= PictureFresh));
        }
    }

    /// <summary>
    /// Downloads a picture, or asks whether the saved one changed. True when there is a new file to show.
    /// A request already running for the same picture is shared.
    /// </summary>
    public Task<bool> RefreshAsync(Uri picture)
    {
        if (AuthorAvatars.Picture(picture.AbsoluteUri) is null) return Task.FromResult(false);
        lock (_gate)
        {
            if (_refreshing.TryGetValue(picture, out var running)) return running;
            if (!IsStale(picture)) return Task.FromResult(false);
            var generation = _generation;
            // Started on another thread, so it cannot finish before it is recorded.
            return _refreshing[picture] = Task.Run(() => DownloadAsync(picture, generation));
        }
    }

    private async Task<bool> DownloadAsync(Uri picture, int generation)
    {
        await _downloads.WaitAsync().ConfigureAwait(false);
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, picture);
            request.Headers.UserAgent.Add(new ProductInfoHeaderValue("GitWolf", "1.0"));
            lock (_gate)
            {
                if (generation != _generation) return false;
                if (Index.Pictures.TryGetValue(picture.AbsoluteUri, out var saved) && saved.File is not null)
                {
                    // Not every picture has a tag; those are compared by date.
                    if (saved.ETag is { } tag) request.Headers.TryAddWithoutValidation("If-None-Match", tag);
                    request.Headers.IfModifiedSince = saved.LastModified;
                }
            }
            AvatarResponse? reply = null;
            try
            {
                reply = await _transport(request).ConfigureAwait(false);
            }
            catch (Exception e) when (e is HttpRequestException or TaskCanceledException or IOException)
            {
                // Offline or slow: the saved copy stays.
                Trace.TraceWarning($"Downloading a profile picture failed: {e.GetType().Name}");
            }
            lock (_gate) return generation == _generation && Store(picture.AbsoluteUri, reply);
        }
        finally
        {
            _downloads.Release();
            lock (_gate) _refreshing.Remove(picture);
        }
    }

    /// <summary>Records an answer. Call while holding the gate.</summary>
    private bool Store(string address, AvatarResponse? reply)
    {
        var entry = Index.Pictures.GetValueOrDefault(address) ?? new PictureEntry { Used = Now };
        Index.Pictures[address] = entry;
        SaveSoon();
        if (reply?.Status == HttpStatusCode.NotModified && entry.File is not null)
        {
            (entry.Checked, entry.Failures, entry.NextTry) = (Now, 0, default);
            return false;
        }
        if (reply is { Status: HttpStatusCode.OK, Body.Length: > 0 and <= MaxPictureBytes } && IsPicture(reply.Body))
        {
            // Named by content too, so a changed picture has a new path and is loaded afresh.
            var name = $"{Hash(address)[..32]}-{Hash(reply.Body)[..16]}.img";
            var changed = name != entry.File;
            if (!changed || Write(name, reply.Body))
            {
                if (changed) Delete(entry.File);
                (entry.File, entry.Size) = (name, reply.Body.Length);
                (entry.ETag, entry.LastModified) = (reply.ETag, reply.LastModified);
                (entry.Checked, entry.Used, entry.Failures, entry.NextTry) = (Now, Now, 0, default);
                Prune(Index);
                return changed;
            }
        }
        entry.Failures++;
        var wait = Now + Backoff(entry.Failures);
        entry.NextTry = reply?.RetryAt is { } until && until > wait ? Earliest(until, Now + LongestWait) : wait;
        return false;
    }

    /// <summary>Drops a saved picture that could not be displayed, so it is downloaded again later.</summary>
    public void Discard(Uri picture)
    {
        lock (_gate)
        {
            if (!Index.Pictures.TryGetValue(picture.AbsoluteUri, out var entry)) return;
            Delete(entry.File);
            (entry.File, entry.ETag, entry.LastModified, entry.Size) = (null, null, null, 0);
            entry.NextTry = Now + Backoff(++entry.Failures);
            SaveSoon();
        }
    }

    private static bool IsPicture(ReadOnlySpan<byte> content) =>
        content.StartsWith((ReadOnlySpan<byte>)[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        || content.StartsWith((ReadOnlySpan<byte>)[0xFF, 0xD8, 0xFF])
        || content.StartsWith("GIF87a"u8) || content.StartsWith("GIF89a"u8);

    /// <summary>One minute, doubling with each failure, up to a day.</summary>
    private static TimeSpan Backoff(int failures) =>
        TimeSpan.FromMinutes(Math.Min(Math.Pow(2, Math.Clamp(failures - 1, 0, 20)), LongestWait.TotalMinutes));

    private static DateTimeOffset Earliest(DateTimeOffset a, DateTimeOffset b) => a < b ? a : b;
}
