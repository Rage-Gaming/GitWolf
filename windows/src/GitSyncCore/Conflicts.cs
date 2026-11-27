using System.Text;

namespace GitSync.Core;

/// <summary>How one conflict block should be resolved. BothReversed is theirs followed by ours.</summary>
public enum ConflictChoice { Ours, Theirs, Both, BothReversed }

public enum ConflictSide { Ours, Theirs, Delete }

/// <summary>One `&lt;&lt;&lt;&lt;&lt;&lt;&lt;` … `&gt;&gt;&gt;&gt;&gt;&gt;&gt;` block of a conflicted file.</summary>
/// <param name="Base">Common ancestor lines, with `merge.conflictStyle=diff3|zdiff3`.</param>
public sealed record ConflictBlock(
    int Id, string OursLabel, string TheirsLabel,
    IReadOnlyList<string> Ours, IReadOnlyList<string>? Base, IReadOnlyList<string> Theirs)
{
    public IReadOnlyList<string> Lines(ConflictChoice choice) => choice switch
    {
        ConflictChoice.Ours => Ours,
        ConflictChoice.Theirs => Theirs,
        ConflictChoice.Both => [.. Ours, .. Theirs],
        _ => [.. Theirs, .. Ours],
    };
}

/// <summary>Either plain lines or a conflict block.</summary>
public sealed record ConflictSegment(IReadOnlyList<string> Common, ConflictBlock? Block = null);

/// <summary>
/// A file containing conflict markers, split into plain text and conflict blocks. Lines keep any
/// trailing `\r`, so CRLF files round-trip byte for byte. Ported from Conflicts.swift.
/// </summary>
public sealed class ConflictDocument
{
    private readonly bool _trailingNewline;

    private ConflictDocument(string source, List<ConflictSegment> segments, bool trailingNewline)
    {
        Source = source;
        Segments = segments;
        _trailingNewline = trailingNewline;
        Blocks = segments.Where(s => s.Block is not null).Select(s => s.Block!).ToList();
    }

    /// <summary>The text that was parsed, to detect edits made while the user was choosing.</summary>
    public string Source { get; }
    public IReadOnlyList<ConflictSegment> Segments { get; }
    public IReadOnlyList<ConflictBlock> Blocks { get; }

    private enum Part { Common, Ours, Base, Theirs }

    /// <summary>Null when <paramref name="text"/> has no complete conflict block.</summary>
    public static ConflictDocument? Parse(string text)
    {
        var lines = text.Split('\n').ToList();
        var trailing = lines[^1].Length == 0;
        if (trailing) lines.RemoveAt(lines.Count - 1);

        var segments = new List<ConflictSegment>();
        List<string> common = [], ours = [], theirs = [], raw = [];
        List<string>? ancestor = null;
        var oursLabel = "";
        var part = Part.Common;
        var blocks = 0;

        // Exactly seven characters, so longer rules (e.g. in Markdown) stay ordinary text.
        static bool Marker(string line, char c) =>
            line.Length >= 7 && line.AsSpan(0, 7).IndexOfAnyExcept(c) < 0 && (line.Length == 7 || line[7] is ' ' or '\r');

        foreach (var line in lines)
        {
            if (part != Part.Common) raw.Add(line);
            switch (part)
            {
                case Part.Common when Marker(line, '<'):
                    if (common.Count > 0) segments.Add(new(common));
                    common = [];
                    (part, oursLabel, ours, ancestor, theirs, raw) = (Part.Ours, line[7..].Trim(), [], null, [], [line]);
                    break;
                case Part.Common:
                    common.Add(line);
                    break;
                case Part.Ours when Marker(line, '|'):
                    (part, ancestor) = (Part.Base, []);
                    break;
                case Part.Ours or Part.Base when Marker(line, '='):
                    part = Part.Theirs;
                    break;
                case Part.Ours:
                    ours.Add(line);
                    break;
                case Part.Base:
                    ancestor!.Add(line);
                    break;
                case Part.Theirs when Marker(line, '>'):
                    segments.Add(new([], new(blocks++, oursLabel, line[7..].Trim(), ours, ancestor, theirs)));
                    part = Part.Common;
                    break;
                default:
                    theirs.Add(line);
                    break;
            }
        }
        // An unterminated block is kept as plain text rather than being lost.
        if (part != Part.Common) common.AddRange(raw);
        if (common.Count > 0) segments.Add(new(common));
        return blocks == 0 ? null : new ConflictDocument(text, segments, trailing);
    }

    /// <summary>
    /// The file text with each block replaced by its choice. Blocks without a choice keep their
    /// markers, so a half-resolved file loses nothing.
    /// </summary>
    public string Render(IReadOnlyDictionary<int, ConflictChoice> choices)
    {
        var output = new List<string>();
        foreach (var segment in Segments)
        {
            if (segment.Block is not { } block)
            {
                output.AddRange(segment.Common);
            }
            else if (choices.TryGetValue(block.Id, out var choice))
            {
                output.AddRange(block.Lines(choice));
            }
            else
            {
                output.Add($"<<<<<<< {block.OursLabel}");
                output.AddRange(block.Ours);
                if (block.Base is { } ancestor)
                {
                    output.Add("||||||| base");
                    output.AddRange(ancestor);
                }
                output.Add("=======");
                output.AddRange(block.Theirs);
                output.Add($">>>>>>> {block.TheirsLabel}");
            }
        }
        return string.Join('\n', output) + (_trailingNewline ? "\n" : "");
    }
}

/// <summary>Which sides of an unmerged path exist in the index (stages 1, 2 and 3).</summary>
public sealed record ConflictStages(bool Base, bool Ours, bool Theirs)
{
    /// <summary>Both sides have the file, so it can contain conflict markers.</summary>
    public bool HasContentConflict => Ours && Theirs;

    public string Title => (Base, Ours, Theirs) switch
    {
        (true, true, false) => "Deleted by them",
        (true, false, true) => "Deleted by us",
        (false, true, true) => "Added by both",
        (false, true, false) => "Added by us",
        (false, false, true) => "Added by them",
        (true, false, false) => "Deleted by both",
        _ => "Both modified",
    };
}

public sealed partial class GitRepository
{
    /// <summary>Larger files are not opened in the resolver.</summary>
    private const long MaxConflictBytes = 2 * 1024 * 1024;

    private static readonly UTF8Encoding StrictUtf8 = new(false, throwOnInvalidBytes: true);

    public async Task<ConflictStages> ConflictStagesAsync(string path)
    {
        var output = await Git.RunStringAsync(["--literal-pathspecs", "ls-files", "-u", "-z", "--", path], readOnly: true);
        // "<mode> <sha> <stage>\t<path>"
        var stages = output.Split('\0', StringSplitOptions.RemoveEmptyEntries)
            .Select(entry => entry.Split('\t')[0].Split(' '))
            .Where(head => head.Length == 3)
            .Select(head => head[2])
            .ToHashSet();
        return new ConflictStages(stages.Contains("1"), stages.Contains("2"), stages.Contains("3"));
    }

    /// <summary>The parsed working-tree file; null when it has no markers or isn't editable text.</summary>
    public async Task<ConflictDocument?> ConflictDocumentAsync(string path) =>
        await ReadTextAsync(path) is { } text ? ConflictDocument.Parse(text) : null;

    /// <summary>
    /// Writes the resolved content and stages the file, which marks it resolved. Refused when the file
    /// no longer holds <paramref name="expected"/>, so edits made meanwhile are not overwritten.
    /// </summary>
    public async Task ResolveConflictAsync(string path, string content, string expected)
    {
        if (await ReadTextAsync(path) != expected)
            throw new GitException("resolve", 1, "The file changed, so nothing was saved. Choose again.");
        await File.WriteAllBytesAsync(Path.Combine(Root, path), StrictUtf8.GetBytes(content));
        await StageAsync([path]);
    }

    /// <summary>Resolves a whole file by taking one side, or removing it, and stages the result.</summary>
    public async Task ResolveConflictAsync(string path, ConflictSide side)
    {
        if (side == ConflictSide.Delete)
        {
            await Git.RunAsync(["--literal-pathspecs", "rm", "--quiet", "--", path]);
            return;
        }
        var stages = await ConflictStagesAsync(path);
        // Taking a side that deleted the file means deleting it.
        if (!(side == ConflictSide.Ours ? stages.Ours : stages.Theirs))
        {
            await ResolveConflictAsync(path, ConflictSide.Delete);
            return;
        }
        var flag = side == ConflictSide.Ours ? "--ours" : "--theirs";
        await Git.RunAsync(["--literal-pathspecs", "checkout", flag, "--", path]);
        await StageAsync([path]);
    }

    /// <summary>
    /// Null for missing, large, binary or non-UTF-8 files, and for anything reached through a link: a
    /// repository can contain links that lead outside it, which must never be read or written.
    /// </summary>
    private async Task<string?> ReadTextAsync(string path)
    {
        var root = Path.GetFullPath(Root);
        var full = Path.GetFullPath(Path.Combine(root, path));
        if (!full.StartsWith(Path.TrimEndingDirectorySeparator(root) + Path.DirectorySeparatorChar, StringComparison.Ordinal))
            return null;
        var info = new FileInfo(full);
        if (!info.Exists || info.Length > MaxConflictBytes) return null;
        for (FileSystemInfo? part = info; part is not null && part.FullName.Length > root.Length;
             part = part is FileInfo file ? file.Directory : ((DirectoryInfo)part).Parent)
        {
            if (part.LinkTarget is not null) return null;
        }
        var data = await File.ReadAllBytesAsync(full);
        if (Array.IndexOf(data, (byte)0) >= 0) return null;
        try
        {
            // A byte order mark survives as a character, so it is written back unchanged.
            return StrictUtf8.GetString(data);
        }
        catch (DecoderFallbackException)
        {
            return null;
        }
    }
}
