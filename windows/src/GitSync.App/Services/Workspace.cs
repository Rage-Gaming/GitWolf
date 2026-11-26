using System.Diagnostics;
using System.Text.Json;
using GitSync.Core;
using GitSync.Store;

namespace GitSync.App.Services;

/// <summary>What is remembered between launches. Paths and view preferences only, never credentials.</summary>
internal sealed record WorkspaceState(List<string>? Open = null, string? Selected = null, bool SplitDiff = false);

/// <summary>
/// All repositories open in the window. Each keeps its own store (and file watcher) alive so rail
/// badges stay current. Ported from Workspace.swift. UI thread only.
/// </summary>
internal sealed class Workspace : IDisposable
{
    private const int MaxRestored = 20;

    private static readonly string StatePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "GitSync", "workspace.json");

    private readonly List<RepositoryStore> _repos = [];
    private readonly AppSettings _settings;
    private readonly Action<Uri> _openUri;
    private bool _restoring;
    private bool _splitDiff;

    public Workspace(AppSettings settings, Action<Uri> openUri)
    {
        _settings = settings;
        _openUri = openUri;
    }

    public IReadOnlyList<RepositoryStore> Repos => _repos;
    public RepositoryStore? Selected { get; private set; }

    /// <summary>Raised when the list or the selection changes.</summary>
    public event Action? Changed;

    public bool SplitDiff
    {
        get => _splitDiff;
        set
        {
            _splitDiff = value;
            Save();
        }
    }

    /// <summary>Opens and selects a repository. Throws <see cref="GitException"/> if the folder isn't one.</summary>
    public async Task OpenAsync(string path)
    {
        var git = _settings.CustomGitPath;
        var repo = await Task.Run(() => GitRepository.OpenAsync(path, git));
        var existing = _repos.FirstOrDefault(r => string.Equals(r.Id, repo.Root, StringComparison.OrdinalIgnoreCase));
        if (existing is not null)
        {
            Select(existing);
            return;
        }
        var store = new RepositoryStore(repo, _settings, _openUri);
        _repos.Add(store);
        store.Start();
        Select(store);
    }

    public void Select(RepositoryStore? store)
    {
        Selected = store;
        Save();
        Changed?.Invoke();
    }

    public void Close(RepositoryStore store)
    {
        if (!_repos.Remove(store)) return;
        if (ReferenceEquals(Selected, store)) Selected = _repos.LastOrDefault();
        Save();
        Changed?.Invoke();
        store.Dispose();
    }

    /// <summary>Reopens last session's repositories. Ones that no longer open are skipped.</summary>
    public async Task RestoreAsync()
    {
        var state = Load();
        _splitDiff = state.SplitDiff;
        _restoring = true;
        try
        {
            foreach (var path in (state.Open ?? []).Where(Directory.Exists).Take(MaxRestored))
            {
                try
                {
                    await OpenAsync(path);
                }
                catch (GitException e)
                {
                    Trace.TraceWarning($"A repository could not be restored: {e.GetType().Name}");
                }
            }
        }
        finally
        {
            _restoring = false;
        }
        Select(_repos.FirstOrDefault(r => r.Id == state.Selected) ?? Selected);
    }

    private static WorkspaceState Load()
    {
        try
        {
            return File.Exists(StatePath)
                ? JsonSerializer.Deserialize<WorkspaceState>(File.ReadAllText(StatePath)) ?? new()
                : new();
        }
        catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException)
        {
            Trace.TraceWarning($"Workspace state could not be read: {e.GetType().Name}");
            return new();
        }
    }

    private void Save()
    {
        if (_restoring) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(StatePath)!);
            var state = new WorkspaceState(_repos.Select(r => r.Id).ToList(), Selected?.Id, _splitDiff);
            // Write then rename, so a crash can't leave a half-written file.
            var temporary = StatePath + ".tmp";
            File.WriteAllText(temporary, JsonSerializer.Serialize(state));
            File.Move(temporary, StatePath, overwrite: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Trace.TraceWarning($"Workspace state could not be saved: {e.GetType().Name}");
        }
    }

    public void Dispose()
    {
        foreach (var store in _repos) store.Dispose();
        _repos.Clear();
        Selected = null;
    }
}
