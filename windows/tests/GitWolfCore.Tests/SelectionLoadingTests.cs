using GitWolf.Core;
using GitWolf.Store;
using Xunit;
using static GitWolfCore.Tests.RepositoryStoreTests;

namespace GitWolfCore.Tests;

public sealed class SelectionLoadingTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), $"gitwolf-loading-{Guid.NewGuid()}");

    public SelectionLoadingTests() => Directory.CreateDirectory(_dir);

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // Git marks its objects read-only; the temporary folder is cleaned by the system.
        }
    }

    private sealed class Settings : IStoreSettings
    {
        public int CommitPageSize => 500;
        public int AutoFetchMinutes => 0;
        public int DiffContext => 3;
        public bool PullRebase => false;
        public GitRepository Configure(GitRepository repo) => repo;
        public ProviderKind? AccountKindForHost(string host) => null;
    }

    private async Task<RepositoryStore> StoreAsync()
    {
        var git = new GitRunner(_dir);
        await git.RunAsync(["init", "-b", "main"]);
        await git.RunAsync(["config", "user.name", "Tester"]);
        await git.RunAsync(["config", "user.email", "t@example.com"]);
        foreach (var name in new[] { "a.txt", "b.txt" })
        {
            File.WriteAllText(Path.Combine(_dir, name), $"{name}\n");
            await git.RunAsync(["add", "."]);
            await git.RunAsync(["commit", "-m", name]);
        }
        var store = new RepositoryStore(new GitRepository(_dir), new Settings(), _ => { });
        await store.RequestRefresh();
        return store;
    }

    [Fact]
    public void ACommitIsLoadingUntilItsFilesAndDiffAreRead() => SingleThread.Run(async () =>
    {
        using var store = await StoreAsync();
        // What a view sees each time it is told the loading is over.
        var finished = new List<(int Files, bool HasDiff)>();
        var drawnEarly = false;
        store.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(RepositoryStore.IsLoadingSelection))
            {
                if (!store.IsLoadingSelection) finished.Add((store.CommitFiles.Count, store.Diff is not null));
            }
            else if (e.PropertyName == nameof(RepositoryStore.SelectedCommitId))
            {
                drawnEarly |= !store.IsLoadingSelection;
            }
        };

        store.SelectCommit(store.Commits[0].Id);
        Assert.True(store.IsLoadingSelection);
        await store.PendingLoad;

        Assert.False(store.IsLoadingSelection);
        Assert.False(drawnEarly);
        Assert.Equal([(1, true)], finished);
    });

    [Fact]
    public void AnotherPickOrNoneLeavesNothingLoading() => SingleThread.Run(async () =>
    {
        using var store = await StoreAsync();

        store.SelectCommit(store.Commits[0].Id);
        var first = store.PendingLoad;
        store.SelectCommit(store.Commits[1].Id);
        await first;
        await store.PendingLoad;
        Assert.False(store.IsLoadingSelection);
        Assert.Equal("a.txt", store.SelectedTarget?.Path);

        store.SelectCommit(store.Commits[0].Id);
        var abandoned = store.PendingLoad;
        store.SelectCommit(null);
        Assert.False(store.IsLoadingSelection);
        await abandoned;
        Assert.False(store.IsLoadingSelection);
    });

    [Fact]
    public void LinesCannotBeStagedWhileAnotherFileIsLoading() => SingleThread.Run(async () =>
    {
        using var store = await StoreAsync();
        File.AppendAllText(Path.Combine(_dir, "a.txt"), "more\n");
        File.AppendAllText(Path.Combine(_dir, "b.txt"), "more\n");
        await store.RequestRefresh();
        store.Mode = StoreMode.Changes;
        store.SelectChange(store.Status.Unstaged[0], DiffSource.Unstaged);
        await store.PendingLoad;
        Assert.True(store.CanPatch);

        store.SelectChange(store.Status.Unstaged[1], DiffSource.Unstaged);
        Assert.False(store.CanPatch);
        await store.PendingLoad;

        Assert.True(store.CanPatch);
    });
}
