import Foundation

/// One row of a side-by-side diff: either a hunk header, or an old/new pair.
public struct SplitRow: Identifiable, Equatable, Sendable {
    public var id: Int
    /// Set for hunk header rows (left and right are nil).
    public var header: DiffLine?
    public var left: DiffLine?
    public var right: DiffLine?
}

public enum SideBySide {
    /// Pairs a unified diff into aligned rows. Context lines appear on both sides; within a block of
    /// changes, deletions (left) are lined up with additions (right) in order, and whichever side
    /// is shorter is left blank.
    public static func rows(for diff: FileDiff) -> [SplitRow] {
        var rows: [SplitRow] = []
        var deletions: [DiffLine] = []
        var additions: [DiffLine] = []

        func add(header: DiffLine? = nil, left: DiffLine? = nil, right: DiffLine? = nil) {
            rows.append(SplitRow(id: rows.count, header: header, left: left, right: right))
        }
        func flush() {
            for i in 0..<max(deletions.count, additions.count) {
                add(left: i < deletions.count ? deletions[i] : nil,
                    right: i < additions.count ? additions[i] : nil)
            }
            deletions.removeAll()
            additions.removeAll()
        }

        for line in diff.lines {
            switch line.kind {
            case .hunkHeader:
                flush()
                add(header: line)
            case .context:
                flush()
                add(left: line, right: line)
            case .deletion:
                // A deletion after additions starts a new change block.
                if !additions.isEmpty { flush() }
                deletions.append(line)
            case .addition:
                additions.append(line)
            case .note:
                break
            }
        }
        flush()
        return rows
    }
}
