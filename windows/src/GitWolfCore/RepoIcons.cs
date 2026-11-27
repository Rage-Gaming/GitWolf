namespace GitWolf.Core;

/// <summary>
/// A custom picture for a repository's tile in the rail: a named symbol or an imported image
/// (one of the two is set). Ported from RepoIcons.swift.
/// </summary>
public sealed record RepoIcon(string? Symbol = null, string? Image = null)
{
    public static RepoIcon OfSymbol(string name) => new(Symbol: name);
    public static RepoIcon OfImage(string file) => new(Image: file);
}

/// <summary>A named colour for a repository's tile. The app maps each name to its own flat colour.</summary>
public enum RepoTint { Red, Orange, Yellow, Green, Teal, Blue, Purple, Pink, Gray }

/// <summary>Which icon and colour each repository uses, keyed by the repository's root path.</summary>
public sealed class RepoIcons
{
    private readonly Dictionary<string, RepoIcon> _icons = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, RepoTint> _tints = new(StringComparer.OrdinalIgnoreCase);

    public IReadOnlyDictionary<string, RepoIcon> Icons => _icons;
    public IReadOnlyDictionary<string, RepoTint> Tints => _tints;

    public RepoIcon? Icon(string path) => _icons.GetValueOrDefault(path);
    public RepoTint? Tint(string path) => _tints.TryGetValue(path, out var tint) ? tint : null;

    public void SetTint(string path, RepoTint? tint)
    {
        if (tint is { } chosen) _tints[path] = chosen;
        else _tints.Remove(path);
    }

    /// <summary>Sets an icon and returns the image file name it replaced, if any, so the caller can delete it.</summary>
    public string? Set(string path, RepoIcon? icon)
    {
        var old = Icon(path);
        if (icon is null) _icons.Remove(path);
        else _icons[path] = icon;
        return old?.Image is { } image && image != icon?.Image ? image : null;
    }

    /// <summary>Drops entries for repositories that no longer exist; returns the image files now unused.</summary>
    public IReadOnlyList<string> Prune(Func<string, bool> exists)
    {
        var unused = new List<string>();
        foreach (var (path, icon) in _icons.Where(e => !exists(e.Key)).ToList())
        {
            if (icon.Image is { } image) unused.Add(image);
            _icons.Remove(path);
        }
        foreach (var path in _tints.Keys.Where(p => !exists(p)).ToList()) _tints.Remove(path);
        return unused;
    }

    /// <summary>The symbols offered in the picker. Names match the macOS app where Windows has the picture.</summary>
    public static readonly IReadOnlyList<(string Group, IReadOnlyList<string> Names)> SymbolChoices =
    [
        ("Code", ["chevron.left.forwardslash.chevron.right", "terminal", "hammer", "wrench.and.screwdriver", "cpu",
            "memorychip", "server.rack", "externaldrive", "network"]),
        ("Apps", ["app", "macwindow", "iphone", "laptopcomputer", "globe", "doc.text", "book", "paintbrush", "photo"]),
        ("Things", ["star", "heart", "flame", "bolt", "leaf", "moon", "sun.max", "cloud", "drop"]),
        ("Objects", ["shippingbox", "cube", "gearshape", "key", "lock", "flag", "tag", "folder", "briefcase"]),
        ("Fun", ["gamecontroller", "music.note", "camera", "film", "airplane", "car", "paperplane", "sparkles",
            "lightbulb"]),
    ];
}
