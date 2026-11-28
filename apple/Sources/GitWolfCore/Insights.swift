import Foundation

/// Statistics about a repository's history, computed from one `git log --numstat`.
public struct RepositoryInsights: Equatable, Sendable {
    public struct Contributor: Equatable, Sendable, Identifiable {
        public var name: String
        public var email: String
        public var commits: Int
        public var added: Int
        public var deleted: Int
        public var id: String { email.lowercased() }
    }
    public struct FileStat: Equatable, Sendable, Identifiable {
        public var path: String
        public var commits: Int
        public var added: Int
        public var deleted: Int
        public var churn: Int { added + deleted }
        public var id: String { path }
    }
    public struct Week: Equatable, Sendable, Identifiable {
        public var start: Date
        public var commits: Int
        public var id: Date { start }
    }
    /// Who changes a top-level folder the most (share of changed lines).
    public struct Ownership: Equatable, Sendable, Identifiable {
        public var folder: String
        public var owner: String
        /// 0...1: the owner's share of the changed lines in the folder.
        public var share: Double
        public var lines: Int
        public var id: String { folder }
    }

    public var commits = 0
    public var added = 0
    public var deleted = 0
    public var first: Date?
    public var last: Date?
    /// Whether the history was longer than what was read.
    public var truncated = false
    public var weeks: [Week] = []
    public var contributors: [Contributor] = []
    public var hotFiles: [FileStat] = []
    public var churnFiles: [FileStat] = []
    public var ownership: [Ownership] = []

    public init() {}

    static let recordSeparator: Character = "\u{1e}"
    static let fieldSeparator: Character = "\u{1f}"

    /// Parses the output of `log --format=%x1e%an%x1f%ae%x1f%ct --numstat` (see `GitRepository.insights`).
    public static func parse(_ output: String) -> RepositoryInsights {
        let calendar = Calendar.gregorian
        var result = RepositoryInsights()
        var people: [String: Contributor] = [:]
        var files: [String: FileStat] = [:]
        var weekCounts: [Date: Int] = [:]
        // folder -> (author email -> lines), plus display names
        var folders: [String: [String: Int]] = [:]
        var names: [String: String] = [:]

        for record in output.split(separator: recordSeparator, omittingEmptySubsequences: true) {
            var lines = record.split(separator: "\n", omittingEmptySubsequences: true)
            guard let header = lines.first else { continue }
            lines.removeFirst()
            let f = header.split(separator: fieldSeparator, maxSplits: 2, omittingEmptySubsequences: false)
            guard f.count == 3, let t = TimeInterval(f[2].trimmingCharacters(in: .whitespaces)) else { continue }
            let name = String(f[0]), email = String(f[1]).lowercased()
            let date = Date(timeIntervalSince1970: t)
            result.commits += 1
            if result.first.map({ date < $0 }) ?? true { result.first = date }
            if result.last.map({ date > $0 }) ?? true { result.last = date }
            weekCounts[calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date, default: 0] += 1
            names[email] = names[email] ?? name
            var person = people[email] ?? Contributor(name: name, email: email, commits: 0, added: 0, deleted: 0)
            person.commits += 1
            for line in lines {
                let cols = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                guard cols.count == 3 else { continue }
                // Binary files report "-" for both counts: they count as a change with no lines.
                let add = Int(cols[0]) ?? 0, del = Int(cols[1]) ?? 0
                let path = Self.resolveRename(String(cols[2]))
                result.added += add; result.deleted += del
                person.added += add; person.deleted += del
                var stat = files[path] ?? FileStat(path: path, commits: 0, added: 0, deleted: 0)
                stat.commits += 1; stat.added += add; stat.deleted += del
                files[path] = stat
                let top = path.contains("/") ? String(path.split(separator: "/")[0]) : "(root)"
                folders[top, default: [:]][email, default: 0] += add + del
            }
            people[email] = person
        }

        result.weeks = weekCounts.map { Week(start: $0.key, commits: $0.value) }.sorted { $0.start < $1.start }
        result.contributors = people.values.sorted { ($0.commits, $1.name) > ($1.commits, $0.name) }
        result.hotFiles = files.values.sorted { ($0.commits, $1.path) > ($1.commits, $0.path) }
        result.churnFiles = files.values.filter { $0.churn > 0 }.sorted { ($0.churn, $1.path) > ($1.churn, $0.path) }
        result.ownership = folders.compactMap { folder, byAuthor in
            let total = byAuthor.values.reduce(0, +)
            guard total > 0, let top = byAuthor.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) else { return nil }
            return Ownership(folder: folder, owner: names[top.key] ?? top.key, share: Double(top.value) / Double(total), lines: total)
        }.sorted { ($0.lines, $1.folder) > ($1.lines, $0.folder) }
        return result
    }

    /// `old => new` and `dir/{old => new}/file` renames name the file by its new path.
    static func resolveRename(_ path: String) -> String {
        guard path.contains(" => ") else { return path }
        if let open = path.firstIndex(of: "{"), let close = path.firstIndex(of: "}"), open < close {
            let inner = path[path.index(after: open)..<close]
            let new = inner.components(separatedBy: " => ").last ?? ""
            let joined = String(path[..<open]) + new + String(path[path.index(after: close)...])
            return joined.replacingOccurrences(of: "//", with: "/")
        }
        return path.components(separatedBy: " => ").last ?? path
    }
}

extension Calendar {
    /// Weeks start on Monday, in UTC, so results don't depend on the machine's settings.
    static let gregorian: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone(identifier: "UTC") ?? .current
        return c
    }()
}

public extension GitRepository {
    /// Statistics for the current branch's history (merges excluded), reading at most `limit` commits.
    func insights(limit: Int = 20_000) async throws -> RepositoryInsights {
        let out = try await git.runString(
            ["log", "--no-merges", "-n", "\(limit + 1)", "--no-renames", "--format=%x1e%an%x1f%ae%x1f%ct", "--numstat"],
            readOnly: true)
        var result = RepositoryInsights.parse(out)
        if result.commits > limit {
            // One extra commit was read only to learn that the history is longer.
            result.truncated = true
        }
        return result
    }
}
