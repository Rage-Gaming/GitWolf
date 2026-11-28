using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace GitWolf.Core;

/// <summary>
/// Persists <see cref="RepoIcons"/> and owns the folder of imported images. Both live in the app's data
/// folder, never in a repository. Not thread-safe: use from one thread.
/// </summary>
public sealed class RepoIconStore
{
    private static readonly JsonSerializerOptions Options = new() { Converters = { new JsonStringEnumConverter() } };

    private sealed record State(Dictionary<string, RepoIcon>? Icons, Dictionary<string, RepoTint>? Tints);

    private readonly string _folder;
    private readonly string _file;

    /// <param name="dataFolder">The app's data folder.</param>
    public RepoIconStore(string dataFolder)
    {
        _folder = Path.Combine(dataFolder, "RepoIcons");
        _file = Path.Combine(dataFolder, "repo-icons.json");
        Load();
    }

    public RepoIcons Icons { get; } = new();

    /// <summary>
    /// Only names made by <see cref="NewImageName"/> are accepted, so an edited settings file can't point
    /// at, or delete, a file elsewhere.
    /// </summary>
    public static bool IsImageName(string? name) =>
        name is not null && name.EndsWith(".png", StringComparison.Ordinal)
        && Guid.TryParseExact(name[..^4], "N", out _);

    public static string NewImageName() => $"{Guid.NewGuid():N}.png";

    /// <summary>Where an imported image is kept; the folder is created.</summary>
    public string ImagePath(string name)
    {
        if (!IsImageName(name)) throw new ArgumentException("Not an icon file name.", nameof(name));
        Directory.CreateDirectory(_folder);
        return Path.Combine(_folder, name);
    }

    /// <summary>Sets or removes an icon, deleting the image it replaced. False when it couldn't be saved.</summary>
    public bool Set(string path, RepoIcon? icon)
    {
        var unused = Icons.Set(path, icon);
        // Deleted only once nothing on disk refers to it.
        if (!Save()) return false;
        if (unused is not null) Delete(unused);
        return true;
    }

    public bool SetTint(string path, RepoTint? tint)
    {
        Icons.SetTint(path, tint);
        return Save();
    }

    private void Delete(string name)
    {
        try
        {
            File.Delete(ImagePath(name));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Trace.TraceWarning($"An unused icon could not be deleted: {e.GetType().Name}");
        }
    }

    private void Load()
    {
        try
        {
            if (!File.Exists(_file)) return;
            var state = JsonSerializer.Deserialize<State>(File.ReadAllText(_file), Options);
            foreach (var (path, icon) in state?.Icons ?? [])
            {
                if (icon is not null && (icon.Symbol is not null && icon.Image is null || IsImageName(icon.Image)))
                    Icons.Set(path, icon);
            }
            foreach (var (path, tint) in state?.Tints ?? [])
            {
                if (Enum.IsDefined(tint)) Icons.SetTint(path, tint);
            }
        }
        catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException)
        {
            Trace.TraceWarning($"Repository icons could not be read: {e.GetType().Name}");
        }
    }

    private bool Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_file)!);
            var state = new State(
                Icons.Icons.ToDictionary(e => e.Key, e => e.Value),
                Icons.Tints.ToDictionary(e => e.Key, e => e.Value));
            // Write then rename, so a crash can't leave a half-written file.
            var temporary = _file + ".tmp";
            File.WriteAllText(temporary, JsonSerializer.Serialize(state, Options));
            File.Move(temporary, _file, overwrite: true);
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Trace.TraceWarning($"Repository icons could not be saved: {e.GetType().Name}");
            return false;
        }
    }
}
