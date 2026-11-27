using System.Text;

namespace GitWolf.Core;

/// <summary>What to do with a selection of changed lines.</summary>
public enum PatchAction
{
    /// <summary>Apply selected working-tree changes to the index.</summary>
    Stage,
    /// <summary>Remove selected changes from the index.</summary>
    Unstage,
    /// <summary>Throw selected changes away from the working tree.</summary>
    Discard,
}

internal static class PatchActionExtensions
{
    public static bool Reverse(this PatchAction action) => action != PatchAction.Stage;
    public static bool Cached(this PatchAction action) => action != PatchAction.Discard;
}

/// <summary>
/// Builds minimal patches from a parsed <see cref="FileDiff"/> and a set of selected changed
/// lines — the same idea as `git add -p` / "stage selected lines" in other clients. Ported from
/// PatchBuilder.swift.
/// </summary>
public static class PatchBuilder
{
    /// <param name="diff">the *unstaged* diff for Stage/Discard, the *staged* diff for Unstage.</param>
    /// <param name="selected">ids of <see cref="DiffLine"/>s (additions/deletions) to act on.</param>
    /// <returns>Patch text for `git apply`, or null when nothing is selected or the diff can't be patched.</returns>
    public static string? Make(FileDiff diff, ISet<int> selected, PatchAction action)
    {
        if (!diff.CanPatch || selected.Count == 0) return null;
        var reverse = action.Reverse();

        var byHunk = new Dictionary<int, List<DiffLine>>();
        foreach (var line in diff.Lines)
        {
            if (line.Kind == DiffLineKind.HunkHeader) continue;
            if (!byHunk.TryGetValue(line.HunkIndex, out var list))
                byHunk[line.HunkIndex] = list = [];
            list.Add(line);
        }

        var outLines = new List<string>(diff.Header);
        var delta = 0;
        var emitted = false;

        foreach (var hunk in diff.Hunks)
        {
            var lines = byHunk.TryGetValue(hunk.Index, out var l) ? l : [];
            if (!lines.Any(x => x.IsChange && selected.Contains(x.Id))) continue;

            var body = new List<string>();
            int oldCount = 0, newCount = 0;
            bool lastKept = false;

            foreach (var line in lines)
            {
                switch (line.Kind)
                {
                    case DiffLineKind.Context:
                        body.Add(" " + line.Raw); oldCount++; newCount++; lastKept = true;
                        break;
                    case DiffLineKind.Addition:
                        if (selected.Contains(line.Id))
                        {
                            body.Add("+" + line.Raw); newCount++; lastKept = true;
                        }
                        else if (reverse)
                        {
                            // Stays in the target file: becomes context.
                            body.Add(" " + line.Raw); oldCount++; newCount++; lastKept = true;
                        }
                        else
                        {
                            lastKept = false;
                        }
                        break;
                    case DiffLineKind.Deletion:
                        if (selected.Contains(line.Id))
                        {
                            body.Add("-" + line.Raw); oldCount++; lastKept = true;
                        }
                        else if (reverse)
                        {
                            lastKept = false; // already absent from the target
                        }
                        else
                        {
                            // Stays in the target file: becomes context.
                            body.Add(" " + line.Raw); oldCount++; newCount++; lastKept = true;
                        }
                        break;
                    case DiffLineKind.Note:
                        if (lastKept) body.Add(line.Raw);
                        break;
                    case DiffLineKind.HunkHeader:
                        break;
                }
            }

            // The side git matches against the target file keeps its exact position; the other
            // side is shifted by the changes already emitted. `git apply --recount` fixes counts.
            int oldStart, newStart;
            if (reverse)
            {
                newStart = hunk.NewStart;
                oldStart = newStart + delta;
                delta += oldCount - newCount;
            }
            else
            {
                oldStart = hunk.OldStart;
                newStart = oldStart + delta;
                delta += newCount - oldCount;
            }

            static int Start(int s, int count) => count > 0 ? Math.Max(s, 1) : s;
            outLines.Add($"@@ -{Start(oldStart, oldCount)},{oldCount} +{Start(newStart, newCount)},{newCount} @@{hunk.Section}");
            outLines.AddRange(body);
            emitted = true;
        }

        return emitted ? string.Join("\n", outLines) + "\n" : null;
    }
}
