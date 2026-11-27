using System.Collections.Concurrent;
using GitWolf.Core;
using GitWolf.Store;
using Xunit;

namespace GitWolfCore.Tests;

// No Swift tests exist for RepositoryStore.swift; these cover the invariants in PORTING.md.
public sealed class RepositoryStoreTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), $"gitwolf-store-{Guid.NewGuid()}");

    public RepositoryStoreTests() => Directory.CreateDirectory(_dir);

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch { /* best effort */ }
    }

    private sealed class Settings : IStoreSettings
    {
        public int CommitPageSize => 100;
        public int AutoFetchMinutes => 0;
        public GitRepository Configure(GitRepository repo) => repo;
        public ProviderKind? AccountKindForHost(string host) => null;
    }

    private async Task<RepositoryStore> DirtyRepoStoreAsync()
    {
        var git = new GitRunner(_dir);
        await git.RunAsync(["init", "-b", "main"]);
        await git.RunAsync(["config", "user.name", "Tester"]);
        await git.RunAsync(["config", "user.email", "t@example.com"]);
        await git.RunAsync(["config", "core.autocrlf", "false"]);
        File.WriteAllText(Path.Combine(_dir, "a.txt"), "one\n");
        await git.RunAsync(["add", "."]);
        await git.RunAsync(["commit", "-m", "base"]);
        File.WriteAllText(Path.Combine(_dir, "a.txt"), "one\ntwo\n");
        return new RepositoryStore(new GitRepository(_dir), new Settings(), _ => { });
    }

    [Fact]
    public void UnchangedRefreshRaisesNoNotifications() => SingleThread.Run(async () =>
    {
        using var store = await DirtyRepoStoreAsync();
        await store.RequestRefresh();
        store.SelectChange(store.Status.Unstaged[0], DiffSource.Unstaged);
        await store.PendingLoad;

        var changed = new List<string?>();
        store.PropertyChanged += (_, e) => changed.Add(e.PropertyName);
        await store.RequestRefresh();
        await store.PendingLoad;

        Assert.Equal(StoreMode.Changes, store.Mode);
        Assert.Empty(changed);
    });

    [Fact]
    public void SelectionFollowsAFileThatGetsStaged() => SingleThread.Run(async () =>
    {
        using var store = await DirtyRepoStoreAsync();
        await store.RequestRefresh();
        store.SelectChange(store.Status.Unstaged[0], DiffSource.Unstaged);
        await store.PendingLoad;
        Assert.True(store.CanPatch);

        Assert.True(await store.StageAsync(["a.txt"]));
        await store.RequestRefresh();
        await store.PendingLoad;

        Assert.Equal(DiffSource.Staged, store.SelectedTarget?.Source);
        Assert.Equal(1, store.Diff?.Additions);
    });

    [Fact]
    public void CommitClearsDraftOnlyOnSuccess() => SingleThread.Run(async () =>
    {
        using var store = await DirtyRepoStoreAsync();
        await store.RequestRefresh();
        store.DraftMessage = "second";

        Assert.False(await store.CommitAsync()); // nothing staged
        Assert.Equal("second", store.DraftMessage);
        Assert.NotNull(store.ErrorMessage);

        await store.StageAllAsync();
        Assert.True(await store.CommitAsync());
        await store.RequestRefresh();

        Assert.Equal("", store.DraftMessage);
        Assert.Equal("second", store.Commits[0].Subject);
    });

    [Fact]
    public void StaleDiffResultsAreDropped() => SingleThread.Run(async () =>
    {
        using var store = await DirtyRepoStoreAsync();
        await store.RequestRefresh();
        store.SelectChange(store.Status.Unstaged[0], DiffSource.Unstaged);
        var stale = store.PendingLoad;
        store.SelectTarget(null);
        await stale;

        Assert.Null(store.Diff);
    });

    [Fact]
    public void ADiscardIsRefusedOnceTheShownDiffHasChanged() => SingleThread.Run(async () =>
    {
        using var store = await DirtyRepoStoreAsync();
        await store.RequestRefresh();
        store.SelectChange(store.Status.Unstaged[0], DiffSource.Unstaged);
        await store.PendingLoad;
        var target = store.SelectedTarget!.Value;
        var shown = store.Diff!;
        var ids = shown.ChangedLineIds(0);
        var file = Path.Combine(_dir, "a.txt");

        File.WriteAllText(file, "one\ntwo\nthree\n");
        await store.RequestRefresh();
        await store.PendingLoad;

        Assert.False(await store.ApplyShownAsync(target, shown, ids, PatchAction.Discard));
        Assert.Equal("one\ntwo\nthree\n", File.ReadAllText(file));

        Assert.True(await store.ApplyShownAsync(target, store.Diff!, store.Diff!.ChangedLineIds(0), PatchAction.Discard));
        Assert.Equal("one\n", File.ReadAllText(file));
    });

    /// <summary>Runs an async test on one thread, like the UI thread the store requires.</summary>
    private static class SingleThread
    {
        public static void Run(Func<Task> test)
        {
            var previous = SynchronizationContext.Current;
            using var context = new Context();
            SynchronizationContext.SetSynchronizationContext(context);
            try
            {
                var task = test();
                task.ContinueWith(_ => context.Queue.CompleteAdding(), TaskScheduler.Default);
                foreach (var (callback, state) in context.Queue.GetConsumingEnumerable()) callback(state);
                task.GetAwaiter().GetResult();
            }
            finally
            {
                SynchronizationContext.SetSynchronizationContext(previous);
            }
        }

        private sealed class Context : SynchronizationContext, IDisposable
        {
            public BlockingCollection<(SendOrPostCallback, object?)> Queue { get; } = [];

            public override void Post(SendOrPostCallback d, object? state)
            {
                // Fire-and-forget work may finish after the test; it is safe to drop.
                try { Queue.Add((d, state)); } catch (InvalidOperationException) { }
            }

            public void Dispose() => Queue.Dispose();
        }
    }
}
