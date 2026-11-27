import Foundation

/// One way to ignore a path: the line to add and a label for the menu.
public struct IgnoreOption: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case file, name, folder, ext }
    public var kind: Kind
    public var pattern: String
    public var title: String
    public var id: String { pattern }
}

public enum IgnoreRules {
    /// The options worth offering for a repository-relative path, most specific first.
    public static func options(for path: String) -> [IgnoreOption] {
        let clean = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard !clean.isEmpty else { return [] }
        let name = (clean as NSString).lastPathComponent
        let dir = (clean as NSString).deletingLastPathComponent
        var result = [IgnoreOption(kind: .file, pattern: "/" + escape(clean), title: "This file only (/\(clean))")]
        result.append(IgnoreOption(kind: .name, pattern: escape(name), title: "Any file named “\(name)”"))
        let ext = (name as NSString).pathExtension
        if !ext.isEmpty {
            result.append(IgnoreOption(kind: .ext, pattern: "*." + escape(ext), title: "All .\(ext) files"))
        }
        if !dir.isEmpty {
            result.append(IgnoreOption(kind: .folder, pattern: "/" + escape(dir) + "/", title: "The folder “\(dir)/”"))
        }
        return result
    }

    /// Escapes characters that have a special meaning in a gitignore pattern.
    static func escape(_ text: String) -> String {
        var out = ""
        for (i, c) in text.enumerated() {
            if "*?[]\\".contains(c) || (i == 0 && (c == "#" || c == "!")) { out.append("\\") }
            out.append(c)
        }
        // A trailing space is only kept when escaped.
        if out.hasSuffix(" ") { out = String(out.dropLast()) + "\\ " }
        return out
    }
}

public extension GitRepository {
    /// Appends a pattern to `.gitignore`, or to `.git/info/exclude` (never committed) when `local` is true.
    /// Returns false when the rule was already present.
    @discardableResult
    func addIgnoreRule(_ pattern: String, local: Bool = false) async throws -> Bool {
        let file: URL
        if local {
            let raw = try await git.runString(["rev-parse", "--git-path", "info/exclude"], readOnly: true)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            file = raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : root.appendingPathComponent(raw)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        } else {
            file = root.appendingPathComponent(".gitignore")
        }
        var text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        if text.split(separator: "\n", omittingEmptySubsequences: true).contains(where: { $0.trimmingCharacters(in: .whitespaces) == pattern }) {
            return false
        }
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += pattern + "\n"
        try text.write(to: file, atomically: true, encoding: .utf8)
        return true
    }

    /// Removes a file or folder from the index but keeps it on disk, so a new ignore rule takes effect.
    func stopTracking(_ path: String) async throws {
        try await git.run(["rm", "--cached", "-r", "-q", "--", path])
    }
}
