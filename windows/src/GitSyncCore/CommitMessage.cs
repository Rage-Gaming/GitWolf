using System.Text.RegularExpressions;

namespace GitSync.Core;

/// <summary>Helpers for writing commit messages. Ported from CommitMessage.swift.</summary>
public static partial class CommitMessage
{
    public const int SubjectLimit = 72;

    public static readonly IReadOnlyList<(string Name, string Summary)> ConventionalTypes =
    [
        ("feat", "A new feature"), ("fix", "A bug fix"), ("docs", "Documentation only"),
        ("style", "Formatting, no code change"), ("refactor", "Neither a fix nor a feature"),
        ("perf", "A performance improvement"), ("test", "Adding or fixing tests"),
        ("build", "Build system or dependencies"), ("ci", "CI configuration"), ("chore", "Other changes"),
        ("revert", "Reverts an earlier commit"),
    ];

    /// <summary>Sets the `type(scope): ` prefix on the first line, replacing an existing one.</summary>
    public static string ApplyPrefix(string type, string? scope, string message)
    {
        var lines = message.Split('\n');
        var scopeText = string.IsNullOrEmpty(scope) ? "" : $"({scope})";
        lines[0] = $"{type}{scopeText}: {Prefix().Replace(lines[0], "")}";
        return string.Join('\n', lines);
    }

    /// <summary>Up to three top-level folders of the paths, to offer as scopes.</summary>
    public static IReadOnlyList<string> SuggestedScopes(IEnumerable<string> paths) =>
        paths.Where(p => p.IndexOf('/') > 0).Select(p => p[..p.IndexOf('/')]).Distinct().Take(3).ToList();

    /// <summary>The first line's length when it is over the limit, otherwise null.</summary>
    public static int? LongSubject(string message)
    {
        var end = message.IndexOf('\n');
        var length = (end < 0 ? message : message[..end]).TrimEnd().Length;
        return length > SubjectLimit ? length : null;
    }

    [GeneratedRegex(@"^[a-z]+(\([^)\n]*\))?!?:\s*")]
    private static partial Regex Prefix();
}

public sealed partial class GitRepository
{
    private const long MaxTemplateBytes = 64 * 1024;

    /// <summary>The file named by `commit.template`, if one is configured and readable.</summary>
    public async Task<string?> CommitTemplateAsync()
    {
        try
        {
            // --path expands "~/".
            var path = (await Git.RunStringAsync(["config", "--path", "--get", "commit.template"], readOnly: true)).Trim();
            if (path.Length == 0 || IsNetworkPath(path)) return null;
            var file = new FileInfo(Path.Combine(Root, path));
            if (!file.Exists || file.Length > MaxTemplateBytes) return null;
            var text = (await File.ReadAllTextAsync(file.FullName)).Replace("\r\n", "\n");
            // Git ignores lines starting with # in a template.
            var body = string.Join('\n', text.Split('\n').Where(l => !l.StartsWith('#'))).Trim('\n');
            return body.Length == 0 ? null : body;
        }
        catch (Exception e) when (e is GitException or IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    /// <summary>Full messages of recent commits, newest first, without duplicates, for reuse.</summary>
    public async Task<IReadOnlyList<string>> RecentMessagesAsync(int limit = 10)
    {
        try
        {
            var output = await Git.RunStringAsync(["log", "-n", $"{limit * 3}", "--format=%B%x00"], readOnly: true);
            return output.Split('\0').Select(m => m.Trim()).Where(m => m.Length > 0).Distinct().Take(limit).ToList();
        }
        catch (GitException)
        {
            return []; // No commits yet.
        }
    }
}
