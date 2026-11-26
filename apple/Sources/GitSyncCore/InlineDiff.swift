import Foundation

/// Word-level highlighting inside changed lines.
public enum InlineDiff {
    /// Character ranges (offsets into each string) that differ between `old` and `new`.
    /// Returns empty ranges when the lines are too different for highlighting to help
    /// (more than 70% of either line changed) or too long to compare cheaply.
    public static func changes(old: String, new: String) -> (old: [Range<Int>], new: [Range<Int>]) {
        let a = tokens(old), b = tokens(new)
        guard !a.isEmpty, !b.isEmpty, a.count <= 600, b.count <= 600 else { return ([], []) }

        // Longest common subsequence over tokens.
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i].text == b[j].text ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var keptA = Set<Int>(), keptB = Set<Int>()
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i].text == b[j].text { keptA.insert(i); keptB.insert(j); i += 1; j += 1 }
            else if table[i + 1][j] >= table[i][j + 1] { i += 1 } else { j += 1 }
        }

        let oldRanges = ranges(a, kept: keptA), newRanges = ranges(b, kept: keptB)
        func changed(_ r: [Range<Int>]) -> Int { r.reduce(0) { $0 + $1.count } }
        let oldCount = old.count, newCount = new.count
        if Double(changed(oldRanges)) > 0.7 * Double(oldCount) || Double(changed(newRanges)) > 0.7 * Double(newCount) {
            return ([], [])
        }
        return (oldRanges, newRanges)
    }

    private struct Token { let text: String; let start: Int; let length: Int }

    /// Words (letters, digits, underscore), runs of whitespace, and single punctuation characters.
    private static func tokens(_ s: String) -> [Token] {
        var out: [Token] = []
        var current = ""
        var start = 0
        var kind = 0 // 0 none, 1 word, 2 space
        var offset = 0
        func flush() {
            if !current.isEmpty { out.append(Token(text: current, start: start, length: current.count)) }
            current = ""; kind = 0
        }
        for ch in s {
            let k: Int = (ch.isLetter || ch.isNumber || ch == "_") ? 1 : (ch.isWhitespace ? 2 : 0)
            if k == 0 {
                flush()
                out.append(Token(text: String(ch), start: offset, length: 1))
            } else {
                if k != kind { flush(); start = offset; kind = k }
                current.append(ch)
            }
            offset += 1
        }
        flush()
        return out
    }

    private static func ranges(_ tokens: [Token], kept: Set<Int>) -> [Range<Int>] {
        var out: [Range<Int>] = []
        for (i, token) in tokens.enumerated() where !kept.contains(i) {
            let range = token.start..<(token.start + token.length)
            if let last = out.last, last.upperBound == range.lowerBound { out[out.count - 1] = last.lowerBound..<range.upperBound }
            else { out.append(range) }
        }
        return out
    }
}

extension FileDiff {
    /// Changed character ranges per line id: each run of deleted lines is paired, in order, with the
    /// run of added lines that directly follows it.
    public func inlineRanges() -> [Int: [Range<Int>]] {
        var result: [Int: [Range<Int>]] = [:]
        var i = 0
        while i < lines.count {
            guard lines[i].kind == .deletion else { i += 1; continue }
            var deletions: [DiffLine] = []
            while i < lines.count, lines[i].kind == .deletion { deletions.append(lines[i]); i += 1 }
            var additions: [DiffLine] = []
            while i < lines.count, lines[i].kind == .addition { additions.append(lines[i]); i += 1 }
            for (d, a) in zip(deletions, additions) {
                let c = InlineDiff.changes(old: d.text, new: a.text)
                if !c.old.isEmpty { result[d.id] = c.old }
                if !c.new.isEmpty { result[a.id] = c.new }
            }
        }
        return result
    }

    /// Runs of unchanged lines long enough to fold away, as ranges of `lines` indexes. Lines next to a
    /// change stay visible (`keep` on each side); a run touching a hunk edge keeps only the side that
    /// touches a change.
    public func collapsibleRuns(minimum: Int = 8, keep: Int = 3) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var i = 0
        while i < lines.count {
            guard lines[i].kind == .context else { i += 1; continue }
            let start = i
            while i < lines.count, lines[i].kind == .context { i += 1 }
            let before = start > 0 && lines[start - 1].isChange
            let after = i < lines.count && lines[i].isChange
            let lo = start + (before ? keep : 0)
            let hi = i - (after ? keep : 0)
            if hi - lo >= minimum { runs.append(lo..<hi) }
        }
        return runs
    }
}
