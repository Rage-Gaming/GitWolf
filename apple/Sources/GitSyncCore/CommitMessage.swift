import Foundation

/// Helpers for writing commit messages: conventional-commit prefixes, issue references and templates.
public enum CommitMessage {
    public struct ConventionalType: Identifiable, Equatable, Sendable {
        public var name: String
        public var summary: String
        public var id: String { name }
    }

    public static let conventionalTypes: [ConventionalType] = [
        .init(name: "feat", summary: "A new feature"),
        .init(name: "fix", summary: "A bug fix"),
        .init(name: "docs", summary: "Documentation only"),
        .init(name: "style", summary: "Formatting, no code change"),
        .init(name: "refactor", summary: "Neither a fix nor a feature"),
        .init(name: "perf", summary: "A performance improvement"),
        .init(name: "test", summary: "Adding or fixing tests"),
        .init(name: "build", summary: "Build system or dependencies"),
        .init(name: "ci", summary: "CI configuration"),
        .init(name: "chore", summary: "Other changes"),
        .init(name: "revert", summary: "Reverts an earlier commit"),
    ]

    /// Sets the `type(scope): ` prefix on the first line, replacing an existing conventional prefix.
    public static func applyPrefix(type: String, scope: String? = nil, to message: String) -> String {
        var lines = message.components(separatedBy: "\n")
        let first = lines.first ?? ""
        let subject = stripPrefix(first)
        let scopeText = scope.flatMap { $0.isEmpty ? nil : "(\($0))" } ?? ""
        lines[0] = "\(type)\(scopeText): \(subject)"
        return lines.joined(separator: "\n")
    }

    /// Removes a leading `type(scope)!: ` from a subject line, when it has one.
    public static func stripPrefix(_ subject: String) -> String {
        let pattern = #"^[a-z]+(\([^)\n]*\))?!?:\s*"#
        guard let range = subject.range(of: pattern, options: .regularExpression) else { return subject }
        return String(subject[range.upperBound...])
    }

    /// Adds `Closes #12` style footer lines (after a blank line), skipping references already present.
    public static func addReference(keyword: String, number: Int, to message: String) -> String {
        let line = "\(keyword) #\(number)"
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.components(separatedBy: "\n").contains(line) { return message }
        if trimmed.isEmpty { return line }
        let lines = trimmed.components(separatedBy: "\n")
        // Join an existing footer block of references, otherwise start a new paragraph.
        let isReference = { (l: String) in l.range(of: #"^(Closes|Fixes|Resolves|Refs|Related to) #\d+$"#, options: .regularExpression) != nil }
        if lines.count > 1, let last = lines.last, isReference(last) { return trimmed + "\n" + line }
        return trimmed + "\n\n" + line
    }

    /// Up to three top-level folders shared by the given paths, to offer as scopes.
    public static func suggestedScopes(for paths: [String]) -> [String] {
        var seen: [String] = []
        for path in paths {
            let parts = path.split(separator: "/")
            guard parts.count > 1 else { continue }
            let top = String(parts[0])
            if !seen.contains(top) { seen.append(top) }
        }
        return Array(seen.prefix(3))
    }
}

public extension GitRepository {
    /// The text of the file named by `commit.template`, if one is configured and readable.
    func commitTemplate() async -> String? {
        guard var path = try? await git.runString(["config", "--get", "commit.template"], readOnly: true)
            .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
        if path.hasPrefix("~/") { path = NSHomeDirectory() + String(path.dropFirst(1)) }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        // Git ignores lines starting with # in a template.
        let body = text.components(separatedBy: "\n").filter { !$0.hasPrefix("#") }.joined(separator: "\n")
        return body.trimmingCharacters(in: .newlines).isEmpty ? nil : body
    }

    /// Full messages of your recent commits, newest first, without duplicates, for reuse.
    func recentMessages(limit: Int = 10) async -> [String] {
        guard let out = try? await git.runString(["log", "-n", String(limit * 3), "--format=%B%x00"], readOnly: true) else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        for raw in out.components(separatedBy: "\u{0}") {
            let m = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !m.isEmpty, seen.insert(m).inserted { result.append(m) }
            if result.count == limit { break }
        }
        return result
    }
}
