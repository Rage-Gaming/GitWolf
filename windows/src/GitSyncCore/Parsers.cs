using System.Text;

namespace GitSync.Core;

// Ported from apple/Sources/GitSyncCore/Parsers.swift. All splitting is done at the byte level
// (ByteSplitting.SplitBytes), not on text lines, so CRLF files and odd filenames survive.

// MARK: - git status --porcelain=v2 -z --branch

public static class StatusParser
{
    public static WorkingStatus Parse(byte[] data)
    {
        string? branch = null, headOid = null, upstream = null;
        int ahead = 0, behind = 0;
        var staged = new List<FileChange>();
        var unstaged = new List<FileChange>();
        var untracked = new List<FileChange>();
        var conflicted = new List<FileChange>();

        void Add(string xy, string path, string? original)
        {
            if (xy.Length != 2) return;
            if (xy[0] != '.') staged.Add(new FileChange(path, original, ChangeKindCode.FromCode(xy[0])));
            if (xy[1] != '.') unstaged.Add(new FileChange(path, null, ChangeKindCode.FromCode(xy[1])));
        }

        var tokens = ByteSplitting.SplitBytes(data, 0);
        int i = 0;
        while (i < tokens.Count)
        {
            var token = tokens[i];
            i++;
            if (token.Length == 0) continue;
            switch (token[0])
            {
                case '#':
                {
                    var parts = token.Split(' ', 3);
                    if (parts.Length != 3) continue;
                    switch (parts[1])
                    {
                        case "branch.oid":
                            headOid = parts[2] == "(initial)" ? null : parts[2];
                            break;
                        case "branch.head":
                            branch = parts[2] == "(detached)" ? null : parts[2];
                            break;
                        case "branch.upstream":
                            upstream = parts[2];
                            break;
                        case "branch.ab":
                            var ab = parts[2].Split(' ', StringSplitOptions.RemoveEmptyEntries);
                            if (ab.Length == 2)
                            {
                                ahead = ab[0].Length > 1 && int.TryParse(ab[0][1..], out var a) ? a : 0;
                                behind = ab[1].Length > 1 && int.TryParse(ab[1][1..], out var b) ? b : 0;
                            }
                            break;
                    }
                    break;
                }
                case '1':
                {
                    var f = token.Split(' ', 9);
                    if (f.Length == 9) Add(f[1], f[8], null);
                    break;
                }
                case '2':
                {
                    var f = token.Split(' ', 10);
                    string? original = i < tokens.Count ? tokens[i] : null;
                    i++;
                    if (f.Length == 10) Add(f[1], f[9], original);
                    break;
                }
                case 'u':
                {
                    var f = token.Split(' ', 11);
                    if (f.Length == 11) conflicted.Add(new FileChange(f[10], null, ChangeKind.Unmerged));
                    break;
                }
                case '?':
                    untracked.Add(new FileChange(token[2..], null, ChangeKind.Untracked));
                    break;
            }
        }

        return new WorkingStatus
        {
            Branch = branch,
            HeadOid = headOid,
            Upstream = upstream,
            Ahead = ahead,
            Behind = behind,
            Staged = staged,
            Unstaged = unstaged,
            Untracked = untracked,
            Conflicted = conflicted,
        };
    }
}

// MARK: - git log

public static class LogParser
{
    public const string Format = "%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%D%x1f%s";

    public static List<Commit> Parse(byte[] data, ISet<string> remotes)
    {
        var commits = new List<Commit>();
        foreach (var record in ByteSplitting.SplitBytes(data, 0))
        {
            var f = ByteSplitting.SplitBytes(record, 0x1f);
            if (f.Count < 7 || f[0].Length == 0) continue;
            var hash = f[0].Trim();
            commits.Add(new Commit(
                Hash: hash,
                Parents: f[1].Split(' ', StringSplitOptions.RemoveEmptyEntries),
                AuthorName: f[2],
                AuthorEmail: f[3],
                Date: DateTimeOffset.FromUnixTimeSeconds(long.TryParse(f[4], out var t) ? t : 0),
                Subject: f[6],
                Refs: ParseDecorations(f[5], remotes)));
        }
        return commits;
    }

    /// <summary>Parses `%D`, e.g. `HEAD -&gt; main, origin/main, tag: v1.0`.</summary>
    public static List<RefLabel> ParseDecorations(string raw, ISet<string> remotes)
    {
        var labels = new List<RefLabel>();
        if (raw.Length == 0) return labels;
        foreach (var part in raw.Split(", "))
        {
            if (part.StartsWith("HEAD -> ", StringComparison.Ordinal))
            {
                labels.Add(new RefLabel(part[8..], RefKind.Local, IsCurrent: true));
            }
            else if (part == "HEAD")
            {
                labels.Add(new RefLabel("HEAD", RefKind.Head, IsCurrent: true));
            }
            else if (part.StartsWith("tag: ", StringComparison.Ordinal))
            {
                labels.Add(new RefLabel(part[5..], RefKind.Tag, IsCurrent: false));
            }
            else
            {
                var slash = part.IndexOf('/');
                if (slash >= 0 && remotes.Contains(part[..slash]))
                {
                    if (part.EndsWith("/HEAD", StringComparison.Ordinal)) continue;
                    labels.Add(new RefLabel(part, RefKind.Remote, IsCurrent: false));
                }
                else
                {
                    labels.Add(new RefLabel(part, RefKind.Local, IsCurrent: false));
                }
            }
        }
        return labels;
    }
}

// MARK: - for-each-ref / stash

public static class RefParser
{
    public const string BranchFormat =
        "%(refname)%1f%(refname:short)%1f%(HEAD)%1f%(upstream:short)%1f%(upstream:track,nobracket)%1f%(objectname)";

    public static List<Branch> ParseBranches(byte[] data)
    {
        var result = new List<Branch>();
        foreach (var line in ByteSplitting.SplitBytes(data, (byte)'\n'))
        {
            if (line.Length == 0) continue;
            var f = ByteSplitting.SplitBytes(line, 0x1f);
            if (f.Count < 6) continue;
            var full = f[0];
            var isRemote = full.StartsWith("refs/remotes/", StringComparison.Ordinal);
            if (isRemote && full.EndsWith("/HEAD", StringComparison.Ordinal)) continue;
            int ahead = 0, behind = 0;
            foreach (var piece in f[4].Split(", "))
            {
                if (piece.StartsWith("ahead ", StringComparison.Ordinal))
                    ahead = int.TryParse(piece[6..], out var a) ? a : 0;
                if (piece.StartsWith("behind ", StringComparison.Ordinal))
                    behind = int.TryParse(piece[7..], out var b) ? b : 0;
            }
            result.Add(new Branch(
                Name: f[1], FullRef: full, IsRemote: isRemote, IsCurrent: f[2] == "*",
                Upstream: f[3].Length == 0 ? null : f[3], Ahead: ahead, Behind: behind, Hash: f[5],
                UpstreamGone: f[4] == "gone"));
        }
        return result;
    }

    /// <summary>An annotated tag is a separate object, so its target commit is used as the hash.</summary>
    public const string TagFormat =
        "%(refname:short)%1f%(if)%(*objectname)%(then)%(*objectname)%(else)%(objectname)%(end)"
        + "%1f%(objecttype)%1f%(contents:subject)";

    public static List<GitTag> ParseTags(byte[] data)
    {
        var result = new List<GitTag>();
        foreach (var line in ByteSplitting.SplitBytes(data, (byte)'\n'))
        {
            var f = ByteSplitting.SplitBytes(line, 0x1f);
            if (f.Count < 2 || f[0].Length == 0) continue;
            var annotated = f.Count >= 3 && f[2] == "tag";
            result.Add(new GitTag(f[0], f[1], annotated, annotated && f.Count >= 4 ? f[3] : ""));
        }
        return result;
    }

    public static List<Stash> ParseStashes(byte[] data)
    {
        var result = new List<Stash>();
        foreach (var line in ByteSplitting.SplitBytes(data, (byte)'\n'))
        {
            var f = ByteSplitting.SplitBytes(line, 0x1f);
            if (f.Count < 3 || f[0].Length == 0) continue;
            result.Add(new Stash(f[0], f[1], DateTimeOffset.FromUnixTimeSeconds(long.TryParse(f[2], out var t) ? t : 0)));
        }
        return result;
    }

    /// <summary>`git diff --name-status -z` output.</summary>
    public static List<FileChange> ParseNameStatus(byte[] data)
    {
        var tokens = ByteSplitting.SplitBytes(data, 0);
        var changes = new List<FileChange>();
        int i = 0;
        while (i < tokens.Count)
        {
            var code = tokens[i];
            i++;
            if (code.Length == 0) continue;
            var kind = ChangeKindCode.FromCode(code[0]);
            if ((kind is ChangeKind.Renamed or ChangeKind.Copied) && i + 1 < tokens.Count)
            {
                changes.Add(new FileChange(tokens[i + 1], tokens[i], kind));
                i += 2;
            }
            else if (i < tokens.Count)
            {
                changes.Add(new FileChange(tokens[i], null, kind));
                i += 1;
            }
        }
        return changes;
    }
}

// MARK: - Unified diff

public static class DiffParser
{
    public static FileDiff Parse(byte[] data, int maxLines)
    {
        var header = new List<string>();
        var hunks = new List<DiffHunk>();
        var lines = new List<DiffLine>();
        bool isBinary = false, isTruncated = false;
        int additions = 0, deletions = 0;

        int oldNo = 0, newNo = 0;
        bool inHunk = false;
        int hunk = -1;

        void Append(DiffLineKind kind, string text, string raw, int? old = null, int? newN = null)
        {
            lines.Add(new DiffLine(lines.Count, kind, hunk, old, newN, text, raw));
        }

        foreach (var raw in ByteSplitting.SplitBytes(data, (byte)'\n'))
        {
            if (raw.StartsWith("@@", StringComparison.Ordinal))
            {
                inHunk = true;
                if (lines.Count >= maxLines) { isTruncated = true; break; }
                hunk++;
                if (TryParseHunkHeader(raw, out var o, out var n, out var section))
                {
                    oldNo = o; newNo = n;
                    hunks.Add(new DiffHunk(hunk, o, n, section));
                }
                else
                {
                    hunks.Add(new DiffHunk(hunk, oldNo, newNo, ""));
                }
                Append(DiffLineKind.HunkHeader, raw, raw);
                continue;
            }
            if (!inHunk)
            {
                if (raw.StartsWith("Binary files", StringComparison.Ordinal) || raw.StartsWith("GIT binary patch", StringComparison.Ordinal))
                    isBinary = true;
                if (raw.Length > 0) header.Add(raw);
                continue;
            }
            if (raw.Length == 0) continue;
            if (lines.Count >= maxLines) { isTruncated = true; break; }
            var marker = raw[0];
            var body = raw[1..];
            var text = body.EndsWith('\r') ? body[..^1] : body;
            switch (marker)
            {
                case '+':
                    Append(DiffLineKind.Addition, text, body, newN: newNo);
                    newNo++;
                    additions++;
                    break;
                case '-':
                    Append(DiffLineKind.Deletion, text, body, old: oldNo);
                    oldNo++;
                    deletions++;
                    break;
                case ' ':
                    Append(DiffLineKind.Context, text, body, old: oldNo, newN: newNo);
                    oldNo++;
                    newNo++;
                    break;
                case '\\':
                    Append(DiffLineKind.Note, raw, raw);
                    break;
            }
        }

        return new FileDiff
        {
            Header = header,
            Hunks = hunks,
            Lines = lines,
            IsBinary = isBinary,
            Additions = additions,
            Deletions = deletions,
            IsTruncated = isTruncated,
        };
    }

    /// <summary>`@@ -12,5 +14,7 @@ func foo()` -&gt; (12, 14, " func foo()")</summary>
    public static bool TryParseHunkHeader(string header, out int oldStart, out int newStart, out string section)
    {
        oldStart = 0; newStart = 0; section = "";
        var parts = header.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 3 || !parts[1].StartsWith('-') || !parts[2].StartsWith('+')) return false;

        var oldPart = parts[1][1..].Split(',')[0];
        var newPart = parts[2][1..].Split(',')[0];
        if (!int.TryParse(oldPart, out oldStart) || !int.TryParse(newPart, out newStart)) return false;

        var closeIndex = header.IndexOf(" @@", 2, StringComparison.Ordinal);
        if (closeIndex >= 0) section = header[(closeIndex + 3)..];
        return true;
    }
}
