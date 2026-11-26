import Foundation

/// A history query that git evaluates (message, author, or the content of changes), optionally limited to a file and dates.
public struct HistoryQuery: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        /// Commit message text (`--grep`).
        case message
        /// Author name or email (`--author`).
        case author
        /// Commits that add or remove this exact text (pickaxe `-S`).
        case contentChanged
        /// Commits whose diff has a line matching this regular expression (`-G`).
        case contentRegex
    }

    public var kind: Kind
    public var text: String
    public var path: String
    public var since: Date?
    public var until: Date?

    public init(kind: Kind = .message, text: String = "", path: String = "", since: Date? = nil, until: Date? = nil) {
        self.kind = kind
        self.text = text
        self.path = path
        self.since = since
        self.until = until
    }

    /// True when there is nothing to search for.
    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespaces).isEmpty
            && path.trimmingCharacters(in: .whitespaces).isEmpty && since == nil && until == nil
    }

    /// Arguments for `git log`, built so user text can never be read as an option.
    func arguments() -> [String] {
        var args: [String] = []
        let term = text.trimmingCharacters(in: .whitespaces)
        if !term.isEmpty {
            switch kind {
            case .message: args += ["--regexp-ignore-case", "--fixed-strings", "--grep=\(term)"]
            case .author: args += ["--regexp-ignore-case", "--author=\(term)"]
            case .contentChanged: args.append("-S\(term)")
            case .contentRegex: args.append("-G\(term)")
            }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        if let since { args.append("--since=\(formatter.string(from: since)) 00:00:00") }
        if let until { args.append("--until=\(formatter.string(from: until)) 23:59:59") }
        return args
    }
}

public extension GitRepository {
    /// Commits across all refs matching the query, newest first.
    func search(_ query: HistoryQuery, limit: Int = 500, remotes: Set<String>) async throws -> [Commit] {
        var args = ["log", "--all", "--topo-order", "-z", "-n", String(limit), "--format=\(LogParser.format)"]
        args += query.arguments()
        let path = query.path.trimmingCharacters(in: .whitespaces)
        if !path.isEmpty { args += ["--", path] }
        let data = try await git.run(args, readOnly: true)
        return LogParser.parse(data, remotes: remotes)
    }
}
