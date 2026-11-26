namespace GitSync.Core;

/// <summary>One way to ignore a path: the line to add and a label for the menu.</summary>
public sealed record IgnoreOption(string Pattern, string Title, string Untracks);

/// <summary>Ported from Ignore.swift.</summary>
public static class IgnoreRules
{
    /// <summary>The options worth offering for a repository-relative path, most specific first.</summary>
    public static IReadOnlyList<IgnoreOption> Options(string path)
    {
        var clean = path.TrimEnd('/');
        if (clean.Length == 0) return [];
        var slash = clean.LastIndexOf('/');
        var (folder, name) = slash < 0 ? ("", clean) : (clean[..slash], clean[(slash + 1)..]);
        var result = new List<IgnoreOption>
        {
            new("/" + Escape(clean), $"This file only (/{clean})", clean),
            new(Escape(name), $"Any file named “{name}”", clean),
        };
        var dot = name.LastIndexOf('.');
        if (dot > 0 && dot < name.Length - 1)
            result.Add(new("*." + Escape(name[(dot + 1)..]), $"All {name[dot..]} files", clean));
        if (folder.Length > 0) result.Add(new("/" + Escape(folder) + "/", $"The folder “{folder}/”", folder));
        return result;
    }

    /// <summary>Escapes characters that have a special meaning in a gitignore pattern.</summary>
    private static string Escape(string text)
    {
        var result = new System.Text.StringBuilder();
        for (var i = 0; i < text.Length; i++)
        {
            if ("*?[]\\".Contains(text[i]) || (i == 0 && text[i] is '#' or '!')) result.Append('\\');
            result.Append(text[i]);
        }
        // A trailing space is only kept when escaped.
        if (text.EndsWith(' ')) result.Insert(result.Length - 1, '\\');
        return result.ToString();
    }
}

public sealed partial class GitRepository
{
    /// <summary>
    /// Appends a pattern to `.gitignore`, or to `info/exclude` (never committed) when
    /// <paramref name="local"/>. False when the rule was already there.
    /// </summary>
    public async Task<bool> AddIgnoreRuleAsync(string pattern, bool local = false)
    {
        if (pattern.IndexOfAny(['\r', '\n']) >= 0)
            throw new GitException("argument", 129, "That name can’t be written as an ignore rule.");
        var path = local
            ? Path.Combine(Root, (await Git.RunStringAsync(["rev-parse", "--git-path", "info/exclude"], readOnly: true)).Trim())
            : Path.Combine(Root, ".gitignore");
        // A repository can contain .gitignore as a link to a file elsewhere.
        if (new FileInfo(path).LinkTarget is not null)
            throw new GitException("argument", 128, "The ignore file is a link, so it wasn’t changed.");
        var text = File.Exists(path) ? await File.ReadAllTextAsync(path) : "";
        if (text.Split('\n').Any(line => line.TrimEnd('\r') == pattern)) return false;
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var gap = text.Length == 0 || text.EndsWith('\n') ? "" : "\n";
        // Appended, so the file's existing bytes are left alone.
        await File.AppendAllTextAsync(path, gap + pattern + "\n");
        return true;
    }

    /// <summary>Removes a file or folder from the index but keeps it on disk.</summary>
    public Task StopTrackingAsync(string path) => Git.RunAsync(
        ["--literal-pathspecs", "rm", "--cached", "-r", "-q", "--ignore-unmatch", "--", path]);
}
