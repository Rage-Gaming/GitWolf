import Foundation

/// One line of `git blame` output.
public struct BlameLine: Identifiable, Equatable, Sendable {
    public var id: Int { line }
    public let line: Int
    public let hash: String
    public let author: String
    public let date: Date
    public let summary: String
    public let text: String
    /// Not committed yet (git reports an all-zero hash).
    public var isUncommitted: Bool { hash.allSatisfy { $0 == "0" } }
    public var shortHash: String { String(hash.prefix(7)) }
}

enum BlameParser {
    /// Parses `git blame --porcelain`. Commit metadata appears only the first time a commit is
    /// seen, so it is remembered by hash.
    static func parse(_ text: String) -> [BlameLine] {
        struct Meta { var author = "", summary = ""; var time: TimeInterval = 0 }
        var metas: [String: Meta] = [:]
        var lines: [BlameLine] = []
        var currentHash = "", currentLine = 0

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if raw.hasPrefix("\t") {
                let m = metas[currentHash] ?? Meta()
                lines.append(BlameLine(line: currentLine, hash: currentHash, author: m.author,
                                       date: Date(timeIntervalSince1970: m.time), summary: m.summary,
                                       text: String(raw.dropFirst())))
                continue
            }
            let parts = raw.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
            if parts.count >= 3, parts[0].count == 40, parts[0].allSatisfy(\.isHexDigit), let final = Int(parts[2]) {
                currentHash = String(parts[0]); currentLine = final
                if metas[currentHash] == nil { metas[currentHash] = Meta() }
            } else if raw.hasPrefix("author ") {
                metas[currentHash]?.author = String(raw.dropFirst(7))
            } else if raw.hasPrefix("author-time ") {
                metas[currentHash]?.time = TimeInterval(raw.dropFirst(12)) ?? 0
            } else if raw.hasPrefix("summary ") {
                metas[currentHash]?.summary = String(raw.dropFirst(8))
            }
        }
        return lines
    }
}

extension GitRepository {
    /// Who last changed each line of `path` (in the working tree, or as of `revision`).
    public func blame(path: String, revision: String? = nil) async throws -> [BlameLine] {
        var args = ["blame", "--porcelain"]
        if let revision { args.append(revision) }
        args += ["--", path]
        let data = try await git.run(args, readOnly: true)
        return BlameParser.parse(String(decoding: data, as: UTF8.self))
    }

    /// Commits that changed `path`, newest first, following renames.
    public func fileHistory(path: String, limit: Int = 300, remotes: Set<String> = []) async throws -> [Commit] {
        let data = try await git.run(
            ["log", "--follow", "-z", "-n", String(limit), "--format=\(LogParser.format)", "--", path],
            readOnly: true)
        return LogParser.parse(data, remotes: remotes)
    }

    /// What `commit` changed in `path` (the file's current name), including the rename if it moved
    /// the file. Older commits know the file under older names, so those are looked up first.
    public func fileDiff(path: String, at commit: String, maxLines: Int = 6000) async throws -> FileDiff {
        let names = try await git.runString(
            ["-c", "core.quotepath=off", "log", "--follow", "--name-status", "--format=%x01%H", "--", path],
            readOnly: true)
        var paths: [String] = [path]
        for block in names.split(separator: "\u{1}") {
            let rows = block.split(separator: "\n").map(String.init)
            guard rows.first == commit else { continue }
            let found = rows.dropFirst().flatMap { $0.split(separator: "\t").dropFirst().map(String.init) }
            if !found.isEmpty { paths = found }
            break
        }
        let data = try await git.run(
            ["show", "--format=", "-M", "--no-color", "--no-ext-diff", "--no-textconv",
             "--src-prefix=a/", "--dst-prefix=b/", "-U\(contextLines)", commit, "--"] + paths,
            readOnly: true)
        return DiffParser.parse(data, maxLines: maxLines)
    }
}
