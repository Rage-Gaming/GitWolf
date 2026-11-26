using GitSync.Core;
using Xunit;

namespace GitSyncCore.Tests;

// No Swift tests exist for FileWatcher.swift (it's not covered in GitSyncCoreTests.swift), so
// these are new: a unit test for the pure IsRelevant filter, and an integration smoke test
// against a real FileSystemWatcher.
public sealed class FileWatcherTests
{
    [Theory]
    [InlineData(@"C:\repo\.git\objects\ab\cdef", false)]
    [InlineData(@"C:\repo\.git\lfs\objects\x", false)]
    [InlineData(@"C:\repo\.git\index.lock", false)]
    [InlineData(@"C:\repo\.DS_Store", false)]
    [InlineData(@"C:\repo\.git\FETCH_HEAD", false)]
    [InlineData(@"C:\repo\.git\logs\HEAD", false)]
    [InlineData(@"C:\repo\.git\HEAD", true)]
    [InlineData(@"C:\repo\src\main.cs", true)]
    [InlineData(@"C:\repo\.git\index", true)]
    public void IsRelevant_FiltersGitInternals(string path, bool expected)
    {
        Assert.Equal(expected, FileWatcher.IsRelevant(path));
    }

    [Fact]
    public async Task Events_FiresOnFileChange()
    {
        var dir = Path.Combine(Path.GetTempPath(), $"gitsync-watch-{Guid.NewGuid()}");
        Directory.CreateDirectory(dir);
        try
        {
            using var watcher = new FileWatcher(dir, latency: TimeSpan.FromMilliseconds(50));
            var path = Path.Combine(dir, "a.txt");
            File.WriteAllText(path, "hello");

            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            var fired = await watcher.Events.ReadAsync(cts.Token);
            Assert.True(fired);
        }
        finally
        {
            try { Directory.Delete(dir, recursive: true); } catch { /* best effort */ }
        }
    }
}
