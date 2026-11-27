using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace GitWolf.Core;

/// <summary>The index on disk and the picture files, kept within limits.</summary>
public sealed partial class AvatarCache
{
    private const string IndexName = "index.json";
    private const int MaxAuthors = 10_000;
    private const int MaxRepositories = 500;
    private static readonly TimeSpan Unused = TimeSpan.FromDays(90);
    private static readonly TimeSpan SaveDelay = TimeSpan.FromSeconds(2);

    private sealed class AuthorEntry
    {
        public string Address { get; set; } = "";
        public DateTimeOffset Learned { get; set; }
    }

    private sealed class Schedule
    {
        public DateTimeOffset NextTry { get; set; }
        public int Failures { get; set; }
    }

    private sealed class PictureEntry
    {
        public string? File { get; set; }
        public long Size { get; set; }
        public string? ETag { get; set; }
        public DateTimeOffset? LastModified { get; set; }
        public DateTimeOffset Checked { get; set; }
        public DateTimeOffset Used { get; set; }
        public DateTimeOffset NextTry { get; set; }
        public int Failures { get; set; }
    }

    private sealed class CacheIndex
    {
        /// <summary>By a hash of the email.</summary>
        public Dictionary<string, AuthorEntry> Authors { get; set; } = [];
        /// <summary>By a hash of the repository's path.</summary>
        public Dictionary<string, Schedule> Repositories { get; set; } = [];
        /// <summary>By picture address.</summary>
        public Dictionary<string, PictureEntry> Pictures { get; set; } = [];
        public DateTimeOffset LookupsBlockedUntil { get; set; }
    }

    [GeneratedRegex(@"^[0-9a-f]{32}-[0-9a-f]{16}\.img$")]
    private static partial Regex FileName();

    private CacheIndex? _index;
    private bool _saving;

    /// <summary>Read on first use. Call while holding the gate.</summary>
    private CacheIndex Index
    {
        get
        {
            if (_index is not null) return _index;
            _index = Read();
            Prune(_index);
            DeleteStrays(_index);
            return _index;
        }
    }

    private CacheIndex Read()
    {
        try
        {
            var path = Path.Combine(_folder, IndexName);
            if (!File.Exists(path)) return new();
            var read = JsonSerializer.Deserialize<CacheIndex>(File.ReadAllBytes(path));
            if (read?.Authors is null || read.Repositories is null || read.Pictures is null) return new();
            // The file could have been edited: addresses and file names are checked again.
            foreach (var (key, author) in read.Authors.ToList())
                if (author is null || AuthorAvatars.Picture(author.Address) is null) read.Authors.Remove(key);
            foreach (var (key, picture) in read.Pictures.ToList())
            {
                if (picture is null || AuthorAvatars.Picture(key) is null) read.Pictures.Remove(key);
                else if (picture.File is { } file
                    && (!FileName().IsMatch(file) || !File.Exists(Path.Combine(_folder, file))))
                    (picture.File, picture.ETag, picture.LastModified, picture.Size, picture.Checked) =
                        (null, null, null, 0, default);
            }
            foreach (var (key, repository) in read.Repositories.ToList())
                if (repository is null) read.Repositories.Remove(key);
            return read;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException)
        {
            // A damaged cache starts over.
            Trace.TraceWarning($"Reading the picture cache failed: {e.GetType().Name}");
            return new();
        }
    }

    /// <summary>Drops pictures not shown for a long time, then the least recently shown beyond the size limit.</summary>
    private void Prune(CacheIndex index)
    {
        var now = Now;
        var total = 0L;
        foreach (var (address, picture) in index.Pictures.OrderByDescending(p => p.Value.Used).ToList())
        {
            total += picture.Size;
            if (now - picture.Used <= Unused && total <= _limit) continue;
            Delete(picture.File);
            index.Pictures.Remove(address);
        }
        Trim(index.Authors, MaxAuthors, a => a.Learned);
        Trim(index.Repositories, MaxRepositories, r => r.NextTry);
    }

    private static void Trim<T>(Dictionary<string, T> entries, int limit, Func<T, DateTimeOffset> age)
    {
        if (entries.Count <= limit) return;
        foreach (var key in entries.OrderBy(e => age(e.Value)).Take(entries.Count - limit).Select(e => e.Key).ToList())
            entries.Remove(key);
    }

    private void DeleteStrays(CacheIndex index)
    {
        var kept = index.Pictures.Values.Select(p => p.File).ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var path in Files())
        {
            var name = Path.GetFileName(path);
            if (name.EndsWith(".tmp", StringComparison.Ordinal) || (FileName().IsMatch(name) && !kept.Contains(name)))
                Delete(name);
        }
    }

    private string[] Files()
    {
        try
        {
            return Directory.Exists(_folder) ? Directory.GetFiles(_folder) : [];
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Trace.TraceWarning($"Listing the picture cache failed: {e.GetType().Name}");
            return [];
        }
    }

    private void Delete(string? name)
    {
        if (name is null) return;
        try
        {
            File.Delete(Path.Combine(_folder, name));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // In use; removed as a stray next time.
            Trace.TraceWarning($"Removing a cached picture failed: {e.GetType().Name}");
        }
    }

    /// <summary>Writes beside the target and renames, so a half-written file is never read.</summary>
    private bool Write(string name, byte[] content)
    {
        var temporary = Path.Combine(_folder, $"{Guid.NewGuid():N}.tmp");
        try
        {
            Directory.CreateDirectory(_folder);
            File.WriteAllBytes(temporary, content);
            File.Move(temporary, Path.Combine(_folder, name), overwrite: true);
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Trace.TraceWarning($"Writing the picture cache failed: {e.GetType().Name}");
            Delete(Path.GetFileName(temporary));
            return false;
        }
    }

    /// <summary>Saves shortly, so a burst of changes is written once. Call while holding the gate.</summary>
    private void SaveSoon()
    {
        if (_saving) return;
        _saving = true;
        _ = Task.Delay(SaveDelay).ContinueWith(_ => Flush(), TaskScheduler.Default);
    }

    /// <summary>Writes pending changes now.</summary>
    public void Flush()
    {
        lock (_gate)
        {
            if (!_saving) return;
            _saving = false;
            if (_index is not null) Write(IndexName, JsonSerializer.SerializeToUtf8Bytes(_index));
        }
    }

    /// <summary>Forgets everything and removes the cache's own files.</summary>
    public void Clear()
    {
        lock (_gate)
        {
            // Requests still running are ignored when they finish.
            _generation++;
            _saving = false;
            _index = new();
            foreach (var path in Files())
            {
                var name = Path.GetFileName(path);
                if (name == IndexName || name.EndsWith(".tmp", StringComparison.Ordinal) || FileName().IsMatch(name))
                    Delete(name);
            }
        }
    }

    private static string Hash(string text) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text))).ToLowerInvariant();

    private static string Hash(byte[] content) => Convert.ToHexString(SHA256.HashData(content)).ToLowerInvariant();
}
