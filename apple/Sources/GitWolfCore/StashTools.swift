import Foundation

/// What discarding would throw away, so the confirmation can be specific.
public struct DiscardSummary: Equatable, Sendable {
    public var files: Int = 0
    public var addedLines: Int = 0
    public var removedLines: Int = 0
    public var binaryFiles: Int = 0
    /// Untracked files that would be deleted (they are not in git, so can’t be recovered).
    public var untrackedFiles: Int = 0
    public var untrackedBytes: Int = 0

    /// A sentence listing exactly what is lost.
    public var sentence: String {
        var parts: [String] = []
        if files > 0 {
            var s = "Changes in \(files) file\(files == 1 ? "" : "s")"
            if addedLines + removedLines > 0 { s += " (\(addedLines) line\(addedLines == 1 ? "" : "s") added, \(removedLines) removed)" }
            if binaryFiles > 0 { s += ", \(binaryFiles) binary" }
            parts.append(s)
        }
        if untrackedFiles > 0 {
            let size = ByteCountFormatter.string(fromByteCount: Int64(untrackedBytes), countStyle: .file)
            parts.append("\(untrackedFiles) untracked file\(untrackedFiles == 1 ? "" : "s") (\(size)) will be deleted")
        }
        if parts.isEmpty { return "Nothing will change." }
        return parts.joined(separator: "; ") + (files > 0 ? " will be lost" : "") + ". This can’t be undone."
    }
}

extension GitRepository {
    /// Counts the lines and files that discarding `tracked` and deleting `untracked` would lose.
    public func discardSummary(tracked: [String], untracked: [String]) async throws -> DiscardSummary {
        var summary = DiscardSummary()
        if !tracked.isEmpty {
            let out = try await git.runString(["diff", "--numstat", "-z", "--"] + tracked, readOnly: true)
            // "<added>\t<removed>\t<path>\0" ("-" counts for binary; renames add extra fields, not used here)
            for entry in out.split(separator: "\0") {
                let f = entry.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                guard f.count == 3 else { continue }
                summary.files += 1
                if let a = Int(f[0]), let r = Int(f[1]) { summary.addedLines += a; summary.removedLines += r }
                else { summary.binaryFiles += 1 }
            }
            // Staged-only or mode-only changes have no unstaged numstat but are still affected.
            summary.files = max(summary.files, tracked.count)
        }
        for path in untracked {
            let url = root.appendingPathComponent(path)
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            summary.untrackedFiles += 1
            summary.untrackedBytes += (attrs?[.size] as? Int) ?? 0
        }
        return summary
    }

    public func stashFiles(_ ref: String) async throws -> [FileChange] {
        let data = try await git.run(["diff", "--name-status", "-z", "-M", "\(ref)^1", ref], readOnly: true)
        return RefParser.parseNameStatus(data)
    }

    /// The commit hash a stash entry points at (what `DiffTarget.Source.commit` needs).
    public func stashHash(_ ref: String) async throws -> String {
        try await git.runString(["rev-parse", ref], readOnly: true).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stashes just one hunk: records it as a normal stash entry, then removes it from the working tree.
    /// - Parameters:
    ///   - forwardPatch: the hunk as a patch that applies to the *index* version of the file.
    ///   - discardPatch: the same hunk as a patch that removes it from the working tree.
    /// The file must have no staged changes, because the stash is built on top of HEAD.
    public func stashHunk(forwardPatch: String, discardPatch: String, path: String, message: String) async throws {
        let status = try await status()
        if status.staged.contains(where: { $0.path == path || $0.originalPath == path }) {
            throw GitError(command: "stash", exitCode: 1,
                           stderr: "“\(path)” has staged changes. Unstage it first, then stash the hunk.")
        }
        let gitDir = OperationDetector.gitDirectory(root: root)
        let scratch = gitDir.appendingPathComponent("gitwolf-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let temp = GitRunner(workingDirectory: root, gitPath: gitPath, extraEnvironment: ["GIT_INDEX_FILE": scratch.path])

        // Index = HEAD + this hunk only.
        try await temp.run(["read-tree", "HEAD"])
        try await temp.run(["apply", "--cached", "--recount", "--whitespace=nowarn", "-"], input: Data(forwardPatch.utf8))
        let tree = try await temp.runString(["write-tree"]).trimmingCharacters(in: .whitespacesAndNewlines)

        let branch = status.branch ?? "(no branch)"
        let subject = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let full = "On \(branch): " + (subject.isEmpty ? "hunk of \(path)" : subject)
        let head = try await git.runString(["rev-parse", "HEAD"], readOnly: true).trimmingCharacters(in: .whitespacesAndNewlines)
        let headTree = try await git.runString(["rev-parse", "HEAD^{tree}"], readOnly: true).trimmingCharacters(in: .whitespacesAndNewlines)
        let indexCommit = try await git.runString(["commit-tree", headTree, "-p", head, "-m", "index on \(branch)"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stashCommit = try await git.runString(["commit-tree", tree, "-p", head, "-p", indexCommit, "-m", full])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try await git.run(["stash", "store", "-m", full, stashCommit])

        do { try await apply(patch: discardPatch, action: .discard) }
        catch {
            // Don't leave a stash entry for something still in the working tree.
            _ = try? await git.run(["stash", "drop", "stash@{0}"])
            throw error
        }
    }
}
