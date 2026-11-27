using System.Diagnostics;
using System.Text.Json;
using GitSync.Core;
using GitSync.Store;

namespace GitSync.App.Services;

internal enum AppearanceChoice { System, Light, Dark }

internal enum AccentChoice { Indigo, Blue, Purple, Pink, Red, Orange, Green, Teal }

/// <summary>The saved preferences. Never holds credentials.</summary>
internal sealed record SettingsState(
    AppearanceChoice Appearance = AppearanceChoice.System,
    AccentChoice Accent = AccentChoice.Blue,
    int AutoFetchMinutes = 5,
    int CommitPageSize = 1000,
    int DiffContext = 4,
    bool SyntaxHighlighting = true,
    string GitPath = "", bool PullRebase = false, bool ProfilePictures = true,
    bool SpellCheck = true, double SidebarWidth = 248, double ListShare = 0.45);

/// <summary>
/// User settings, kept in %LOCALAPPDATA%\GitSync\settings.json and read on every use so changes
/// apply without a restart. Ported from AppSettings.swift. With no saved credential, git uses the
/// user's own sign-in (Git Credential Manager or SSH).
/// </summary>
internal sealed class AppSettings : IStoreSettings
{
    private static readonly string StatePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "GitSync", "settings.json");

    public AppSettings() => State = Load();

    public SettingsState State { get; private set; }

    /// <summary>Raised with the old and new values after a change.</summary>
    public event Action<SettingsState, SettingsState>? Changed;

    public int CommitPageSize => State.CommitPageSize;
    public int AutoFetchMinutes => State.AutoFetchMinutes;
    public bool PullRebase => State.PullRebase;

    /// <summary>The custom git executable, or null to use the one found on PATH.</summary>
    public string? CustomGitPath => IsUsableGit(State.GitPath) ? State.GitPath : null;

    public GitRepository Configure(GitRepository repo) => new(repo.Root, CustomGitPath, State.DiffContext)
    {
        Credentials = repo.Credentials,
        AskpassPath = repo.AskpassPath,
    };

    public ProviderKind? AccountKindForHost(string host) => null;

    /// <summary>
    /// A full path to a local .exe. Relative and network paths are refused: the app runs this file.
    /// </summary>
    public static bool IsUsableGit(string path) =>
        Path.IsPathFullyQualified(path) && !path.StartsWith(@"\\", StringComparison.Ordinal)
        && !path.StartsWith("//", StringComparison.Ordinal)
        && path.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) && File.Exists(path);

    public void Update(SettingsState next)
    {
        next = Sanitize(next);
        var previous = State;
        if (next == previous) return;
        State = next;
        Save();
        Changed?.Invoke(previous, next);
    }

    /// <summary>The file can be edited by hand, so every value is brought into range.</summary>
    private static SettingsState Sanitize(SettingsState s) => s with
    {
        Appearance = Enum.IsDefined(s.Appearance) ? s.Appearance : AppearanceChoice.System,
        Accent = Enum.IsDefined(s.Accent) ? s.Accent : AccentChoice.Blue,
        AutoFetchMinutes = Math.Clamp(s.AutoFetchMinutes, 0, 1440),
        CommitPageSize = Math.Clamp(s.CommitPageSize, 100, 20000),
        DiffContext = Math.Clamp(s.DiffContext, 0, 50),
        GitPath = (s.GitPath ?? "").Trim().Trim('"'),
        SidebarWidth = double.IsFinite(s.SidebarWidth) ? Math.Clamp(s.SidebarWidth, 180, 480) : 248,
        ListShare = double.IsFinite(s.ListShare) ? Math.Clamp(s.ListShare, 0.2, 0.8) : 0.45,
    };

    private static SettingsState Load()
    {
        try
        {
            return File.Exists(StatePath)
                ? Sanitize(JsonSerializer.Deserialize<SettingsState>(File.ReadAllText(StatePath)) ?? new())
                : new();
        }
        catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException)
        {
            Trace.TraceWarning($"Settings could not be read: {e.GetType().Name}");
            return new();
        }
    }

    private void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(StatePath)!);
            // Write then rename, so a crash can't leave a half-written file.
            var temporary = StatePath + ".tmp";
            File.WriteAllText(temporary, JsonSerializer.Serialize(State));
            File.Move(temporary, StatePath, overwrite: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Trace.TraceWarning($"Settings could not be saved: {e.GetType().Name}");
        }
    }
}
