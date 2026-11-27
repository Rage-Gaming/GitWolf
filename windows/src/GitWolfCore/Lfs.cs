using System.Globalization;
using System.Text;

namespace GitWolf.Core;

/// <summary>What a Git LFS pointer file says: the real file lives on the LFS server. Ported from LFS.swift.</summary>
public sealed record LfsPointer(string Oid, long Size)
{
    private const string Header = "version https://git-lfs.github.com/spec/v1";

    public static LfsPointer? Parse(string text)
    {
        if (!text.StartsWith(Header, StringComparison.Ordinal)) return null;
        string? oid = null;
        long? size = null;
        foreach (var line in text.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            if (line.StartsWith("oid sha256:", StringComparison.Ordinal)) oid = line["oid sha256:".Length..];
            else if (line.StartsWith("size ", StringComparison.Ordinal)
                && long.TryParse(line[5..], NumberStyles.None, CultureInfo.InvariantCulture, out var n)) size = n;
        }
        return oid is not null && size is { } bytes ? new(oid, bytes) : null;
    }
}

public sealed partial class GitRepository
{
    /// <summary>
    /// Which of <paramref name="paths"/> are stored with Git LFS, judged by .gitattributes. Works
    /// without git-lfs installed. One git process for any number of paths.
    /// </summary>
    public async Task<IReadOnlySet<string>> LfsPathsAsync(IReadOnlyList<string> paths)
    {
        var result = new HashSet<string>(StringComparer.Ordinal);
        if (paths.Count == 0) return result;
        var input = Encoding.UTF8.GetBytes(string.Join('\0', paths) + "\0");
        var data = await Git.RunAsync(["check-attr", "-z", "--stdin", "filter"], readOnly: true, input: input);
        // Path NUL attribute NUL value NUL, repeated.
        var parts = ByteSplitting.SplitBytes(data, 0);
        for (var i = 0; i + 2 < parts.Count; i += 3)
            if (parts[i + 2] == "lfs") result.Add(parts[i]);
        return result;
    }
}
