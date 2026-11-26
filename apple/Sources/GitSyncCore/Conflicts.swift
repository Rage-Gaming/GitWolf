import Foundation

/// How one conflict block should be resolved.
public enum ConflictChoice: String, Sendable, CaseIterable {
    case ours, theirs
    /// Ours followed by theirs.
    case both
    /// Theirs followed by ours.
    case bothReversed
}

/// One `<<<<<<<` … `>>>>>>>` block of a conflicted file.
public struct ConflictBlock: Equatable, Sendable, Identifiable {
    public let id: Int
    public var oursLabel: String
    public var theirsLabel: String
    public var ours: [String]
    /// Common ancestor lines when the file was written with `merge.conflictStyle=diff3|zdiff3`.
    public var base: [String]?
    public var theirs: [String]

    public func lines(for choice: ConflictChoice) -> [String] {
        switch choice {
        case .ours: ours
        case .theirs: theirs
        case .both: ours + theirs
        case .bothReversed: theirs + ours
        }
    }
}

public enum ConflictSegment: Equatable, Sendable {
    case common([String])
    case conflict(ConflictBlock)
}

/// A working-tree file containing conflict markers, split into plain text and conflict blocks.
/// Lines keep any trailing `\r`, so CRLF files round-trip byte for byte.
public struct ConflictDocument: Equatable, Sendable {
    public private(set) var segments: [ConflictSegment]
    /// True when the original text ended with a newline.
    private let trailingNewline: Bool

    public var blocks: [ConflictBlock] {
        segments.compactMap { if case .conflict(let b) = $0 { b } else { nil } }
    }

    public init(segments: [ConflictSegment], trailingNewline: Bool) {
        self.segments = segments
        self.trailingNewline = trailingNewline
    }

    /// Parses `text`. Returns nil when it has no complete conflict block.
    public static func parse(_ text: String) -> ConflictDocument? {
        var lines = text.components(separatedBy: "\n")
        let trailing = lines.last == ""
        if trailing { lines.removeLast() }

        enum Part { case common, ours, base, theirs }
        var segments: [ConflictSegment] = []
        var common: [String] = []
        var part = Part.common
        var ours: [String] = [], base: [String]? = nil, theirs: [String] = []
        var oursLabel = "", theirsLabel = ""
        var raw: [String] = []   // original lines of the open block, for malformed input
        var nextID = 0

        func marker(_ line: String, _ char: Character) -> Bool {
            line.hasPrefix(String(repeating: char, count: 7))
                && (line.count == 7 || line.dropFirst(7).first == " " || line.dropFirst(7).first == "\r")
        }
        func label(_ line: String) -> String {
            String(line.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        for line in lines {
            switch part {
            case .common:
                if marker(line, "<") {
                    if !common.isEmpty { segments.append(.common(common)); common = [] }
                    part = .ours; oursLabel = label(line)
                    ours = []; base = nil; theirs = []; raw = [line]
                } else { common.append(line) }
            case .ours:
                raw.append(line)
                if marker(line, "|") { part = .base; base = [] }
                else if marker(line, "=") { part = .theirs }
                else { ours.append(line) }
            case .base:
                raw.append(line)
                if marker(line, "=") { part = .theirs } else { base?.append(line) }
            case .theirs:
                raw.append(line)
                if marker(line, ">") {
                    theirsLabel = label(line)
                    segments.append(.conflict(ConflictBlock(
                        id: nextID, oursLabel: oursLabel, theirsLabel: theirsLabel,
                        ours: ours, base: base, theirs: theirs)))
                    nextID += 1
                    part = .common
                } else { theirs.append(line) }
            }
        }
        // An unterminated block is kept as plain text rather than being lost.
        if part != .common { common.append(contentsOf: raw) }
        if !common.isEmpty { segments.append(.common(common)) }
        guard nextID > 0 else { return nil }
        return ConflictDocument(segments: segments, trailingNewline: trailing)
    }

    /// The file text with each block replaced by its choice. Blocks without a choice keep their
    /// markers, so a half-resolved file can still be saved without losing anything.
    public func render(_ choices: [Int: ConflictChoice]) -> String {
        var out: [String] = []
        for segment in segments {
            switch segment {
            case .common(let lines): out += lines
            case .conflict(let block):
                if let choice = choices[block.id] {
                    out += block.lines(for: choice)
                } else {
                    out.append("<<<<<<< \(block.oursLabel)")
                    out += block.ours
                    if let base = block.base { out.append("||||||| base"); out += base }
                    out.append("=======")
                    out += block.theirs
                    out.append(">>>>>>> \(block.theirsLabel)")
                }
            }
        }
        return out.joined(separator: "\n") + (trailingNewline ? "\n" : "")
    }
}

/// Which sides of an unmerged path exist in the index (`git ls-files -u` stages 1, 2, 3).
public struct ConflictStages: Equatable, Sendable {
    public var base: Bool, ours: Bool, theirs: Bool
    public init(base: Bool, ours: Bool, theirs: Bool) { self.base = base; self.ours = ours; self.theirs = theirs }

    /// Both sides have the file, so it can contain conflict markers.
    public var hasContentConflict: Bool { ours && theirs }
    public var title: String {
        switch (base, ours, theirs) {
        case (true, true, false): "Deleted by them"
        case (true, false, true): "Deleted by us"
        case (false, true, true): "Added by both"
        case (false, true, false): "Added by us"
        case (false, false, true): "Added by them"
        case (true, false, false): "Deleted by both"
        default: "Both modified"
        }
    }
}

extension GitRepository {
    public func conflictStages(_ path: String) async throws -> ConflictStages {
        let out = try await git.runString(["ls-files", "-u", "-z", "--", path], readOnly: true)
        var stages = Set<Int>()
        for entry in out.split(separator: "\0") {
            // "<mode> <sha> <stage>\t<path>"
            let head = entry.split(separator: "\t", maxSplits: 1)[0].split(separator: " ")
            if head.count == 3, let n = Int(head[2]) { stages.insert(n) }
        }
        return ConflictStages(base: stages.contains(1), ours: stages.contains(2), theirs: stages.contains(3))
    }

    /// The working-tree text of a conflicted file, parsed. Nil when it has no markers (or is binary).
    public func conflictDocument(_ path: String) async throws -> ConflictDocument? {
        let data = try Data(contentsOf: root.appendingPathComponent(path))
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return ConflictDocument.parse(text)
    }

    /// Writes the resolved content and stages the file, which marks it resolved.
    public func resolveConflict(_ path: String, content: String) async throws {
        try Data(content.utf8).write(to: root.appendingPathComponent(path), options: .atomic)
        try await git.run(["add", "--", path])
    }

    /// Resolves a whole file by taking one side (or removing it) and stages the result.
    public func resolveConflict(_ path: String, taking side: ConflictSide) async throws {
        switch side {
        case .ours: try await git.run(["checkout", "--ours", "--", path]); try await git.run(["add", "--", path])
        case .theirs: try await git.run(["checkout", "--theirs", "--", path]); try await git.run(["add", "--", path])
        case .delete: try await git.run(["rm", "--quiet", "--", path])
        }
    }
}

public enum ConflictSide: Sendable { case ours, theirs, delete }
