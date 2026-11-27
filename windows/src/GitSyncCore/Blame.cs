using System.Globalization;

namespace GitSync.Core;

/// <summary>One line of `git blame` output.</summary>
public sealed record BlameLine(int Line, string Hash, string Author, DateTimeOffset Date, string Summary, string Text)
{
    /// <summary>Not committed yet (git reports an all-zero hash).</summary>
    public bool IsUncommitted => Hash.All(c => c == '0');
    public string ShortHash => Hash.Length > 7 ? Hash[..7] : Hash;
}

public static class BlameParser
{
    private sealed class Meta
    {
        public string Author = "", Summary = "";
        public long Time;
    }

    /// <summary>
    /// Parses `git blame --porcelain`. A commit's details appear only the first time it is seen, so
    /// they are remembered by hash.
    /// </summary>
    public static List<BlameLine> Parse(string text)
    {
        var metas = new Dictionary<string, Meta>();
        var lines = new List<BlameLine>();
        var (hash, number) = ("", 0);
        foreach (var raw in text.Split('\n'))
        {
            if (raw.StartsWith('\t'))
            {
                var m = metas.GetValueOrDefault(hash) ?? new Meta();
                lines.Add(new BlameLine(number, hash, m.Author, DateTimeOffset.FromUnixTimeSeconds(m.Time),
                    m.Summary, raw[1..].TrimEnd('\r')));
                continue;
            }
            var parts = raw.Split(' ', 4);
            if (parts.Length >= 3 && parts[0].Length is 40 or 64 && parts[0].All(char.IsAsciiHexDigit)
                && int.TryParse(parts[2], CultureInfo.InvariantCulture, out var final))
            {
                (hash, number) = (parts[0], final);
                metas.TryAdd(hash, new Meta());
                continue;
            }
            if (!metas.TryGetValue(hash, out var meta)) continue;
            if (raw.StartsWith("author ", StringComparison.Ordinal)) meta.Author = raw[7..];
            else if (raw.StartsWith("author-time ", StringComparison.Ordinal))
                long.TryParse(raw[12..], CultureInfo.InvariantCulture, out meta.Time);
            else if (raw.StartsWith("summary ", StringComparison.Ordinal)) meta.Summary = raw[8..];
        }
        return lines;
    }
}

// File history and blame. Ported from Blame.swift.
public sealed partial class GitRepository
{
    /// <summary>Who last changed each line of <paramref name="path"/> in the working tree.</summary>
    public async Task<List<BlameLine>> BlameAsync(string path)
    {
        // --no-textconv: blame would otherwise run commands named in the repository's configuration.
        var output = await Git.RunStringAsync(["blame", "--porcelain", "--no-textconv", "--", path], readOnly: true);
        return BlameParser.Parse(output);
    }

    /// <summary>Commits that changed <paramref name="path"/>, newest first, following renames.</summary>
    public async Task<List<Commit>> FileHistoryAsync(string path, ISet<string> remotes, int limit = 300)
    {
        var data = await Git.RunAsync(
            ["--literal-pathspecs", "log", "--follow", "-z", "-n", $"{limit}", $"--format={LogParser.Format}", "--", path],
            readOnly: true);
        return LogParser.Parse(data, remotes);
    }

    /// <summary>
    /// What <paramref name="commit"/> changed in the file now called <paramref name="path"/>. Older
    /// commits know it under older names, so those are looked up first.
    /// </summary>
    public async Task<FileDiff> FileDiffAsync(string path, string commit, int maxLines = 6000)
    {
        var names = await Git.RunStringAsync(
            ["--literal-pathspecs", "-c", "core.quotepath=off", "log", "--follow", "--name-status",
                "--format=%x01%H", "--", path], readOnly: true);
        string[] paths = [path];
        foreach (var block in names.Split('\u0001', StringSplitOptions.RemoveEmptyEntries))
        {
            var rows = block.Split('\n', StringSplitOptions.RemoveEmptyEntries);
            if (rows.Length == 0 || rows[0].Trim() != commit) continue;
            var found = rows.Skip(1).SelectMany(r => r.TrimEnd('\r').Split('\t').Skip(1)).ToArray();
            if (found.Length > 0) paths = found;
            break;
        }
        var data = await Git.RunAsync(
            ["--literal-pathspecs", "show", "--format=", "-M", "--no-color", "--no-ext-diff", "--no-textconv",
                "--src-prefix=a/", "--dst-prefix=b/", $"-U{ContextLines}", Operand(commit), "--", .. paths],
            readOnly: true);
        return DiffParser.Parse(data, maxLines);
    }
}
