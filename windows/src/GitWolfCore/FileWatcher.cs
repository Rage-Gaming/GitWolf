using System.Threading.Channels;

namespace GitWolf.Core;

/// <summary>
/// Watches a working tree (including `.git`) and emits a coalesced signal whenever something
/// git-relevant changes. Object-database churn and lock files are filtered out so our own
/// read-only commands can never cause a refresh loop. Ported from FileWatcher.swift; uses
/// <see cref="FileSystemWatcher"/> (backed by `ReadDirectoryChangesW` on Windows) in place of
/// FSEvents, per PORTING.md's platform-specific replacements table.
/// </summary>
public sealed class FileWatcher : IDisposable
{
    private readonly FileSystemWatcher _watcher;
    private readonly Channel<bool> _channel = Channel.CreateBounded<bool>(
        new BoundedChannelOptions(1) { FullMode = BoundedChannelFullMode.DropOldest });
    private readonly TimeSpan _latency;
    private readonly object _lock = new();
    private Timer? _pending;
    private bool _disposed;

    /// <summary>Coalesced change signal. Reading this is the equivalent of the Swift `events` AsyncStream.</summary>
    public ChannelReader<bool> Events => _channel.Reader;

    public FileWatcher(string root, TimeSpan? latency = null)
    {
        _latency = latency ?? TimeSpan.FromMilliseconds(250);

        _watcher = new FileSystemWatcher(root)
        {
            IncludeSubdirectories = true,
            NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName
                | NotifyFilters.LastWrite | NotifyFilters.Size | NotifyFilters.CreationTime,
            InternalBufferSize = 64 * 1024,
        };
        _watcher.Changed += OnEvent;
        _watcher.Created += OnEvent;
        _watcher.Deleted += OnEvent;
        _watcher.Renamed += OnEvent;
        // A dropped-events overflow should still trigger a refresh; treat it as relevant.
        _watcher.Error += (_, _) => Schedule();
        _watcher.EnableRaisingEvents = true;
    }

    public void Stop()
    {
        lock (_lock)
        {
            _watcher.EnableRaisingEvents = false;
            _pending?.Dispose();
            _pending = null;
        }
        _channel.Writer.TryComplete();
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        Stop();
        _watcher.Dispose();
    }

    private void OnEvent(object sender, FileSystemEventArgs e)
    {
        if (!IsRelevant(e.FullPath)) return;
        Schedule();
    }

    private void Schedule()
    {
        lock (_lock)
        {
            if (_disposed) return;
            _pending?.Dispose();
            _pending = new Timer(_ => Signal(), null, _latency, Timeout.InfiniteTimeSpan);
        }
    }

    private void Signal() => _channel.Writer.TryWrite(true);

    public static bool IsRelevant(string path)
    {
        var normalized = path.Replace('\\', '/');
        if (normalized.Contains("/.git/objects") || normalized.Contains("/.git/lfs")) return false;
        if (normalized.EndsWith(".lock", StringComparison.Ordinal) || normalized.EndsWith(".DS_Store", StringComparison.Ordinal)) return false;
        if (normalized.EndsWith("/.git/FETCH_HEAD", StringComparison.Ordinal) || normalized.Contains("/.git/logs/")) return false;
        return true;
    }
}
