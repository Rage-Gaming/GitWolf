import Foundation

/// What to do with a selection of changed lines.
public enum PatchAction: Sendable {
    /// Apply selected working-tree changes to the index.
    case stage
    /// Remove selected changes from the index.
    case unstage
    /// Throw selected changes away from the working tree.
    case discard

    var reverse: Bool { self != .stage }
    var cached: Bool { self != .discard }
}

/// Builds minimal patches from a parsed `FileDiff` and a set of selected changed lines, the same
/// idea as `git add -p` / "stage selected lines" in other clients.
public enum PatchBuilder {
    /// - Parameters:
    ///   - diff: the *unstaged* diff for `.stage` / `.discard`, the *staged* diff for `.unstage`.
    ///   - selected: ids of `DiffLine`s (additions/deletions) to act on.
    /// - Returns: patch text for `git apply`, or nil when nothing is selected or the diff can't be patched.
    public static func make(diff: FileDiff, selecting selected: Set<Int>, action: PatchAction) -> String? {
        guard diff.canPatch, !selected.isEmpty else { return nil }
        let reverse = action.reverse
        let byHunk = Dictionary(grouping: diff.lines.filter { $0.kind != .hunkHeader }, by: \.hunkIndex)

        var out = diff.header
        var delta = 0
        var emitted = false

        for hunk in diff.hunks {
            let lines = byHunk[hunk.index] ?? []
            guard lines.contains(where: { $0.isChange && selected.contains($0.id) }) else { continue }

            var body: [String] = []
            var oldCount = 0, newCount = 0
            var lastKept = false

            for line in lines {
                switch line.kind {
                case .context:
                    body.append(" " + line.raw); oldCount += 1; newCount += 1; lastKept = true
                case .addition:
                    if selected.contains(line.id) {
                        body.append("+" + line.raw); newCount += 1; lastKept = true
                    } else if reverse {
                        // Stays in the target file: becomes context.
                        body.append(" " + line.raw); oldCount += 1; newCount += 1; lastKept = true
                    } else {
                        lastKept = false
                    }
                case .deletion:
                    if selected.contains(line.id) {
                        body.append("-" + line.raw); oldCount += 1; lastKept = true
                    } else if reverse {
                        lastKept = false // already absent from the target
                    } else {
                        // Stays in the target file: becomes context.
                        body.append(" " + line.raw); oldCount += 1; newCount += 1; lastKept = true
                    }
                case .note:
                    if lastKept { body.append(line.raw) }
                case .hunkHeader:
                    break
                }
            }

            // The side git matches against the target file keeps its exact position; the other
            // side is shifted by the changes already emitted. `git apply --recount` fixes counts.
            let oldStart: Int, newStart: Int
            if reverse {
                newStart = hunk.newStart
                oldStart = newStart + delta
                delta += oldCount - newCount
            } else {
                oldStart = hunk.oldStart
                newStart = oldStart + delta
                delta += newCount - oldCount
            }
            func start(_ s: Int, _ count: Int) -> Int { count > 0 ? max(s, 1) : s }
            out.append("@@ -\(start(oldStart, oldCount)),\(oldCount) +\(start(newStart, newCount)),\(newCount) @@\(hunk.section)")
            out.append(contentsOf: body)
            emitted = true
        }
        return emitted ? out.joined(separator: "\n") + "\n" : nil
    }
}
