import Foundation

public struct Worktree: Identifiable, Hashable, Sendable {
    public var path: String
    public var head: String
    /// Branch name, nil when detached.
    public var branch: String?
    public var isMain: Bool
    public var isLocked: Bool
    /// Its folder is gone; `git worktree prune` removes the record.
    public var isPrunable: Bool
    public var id: String { path }
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

enum WorktreeParser {
    static func parse(_ text: String) -> [Worktree] {
        var result: [Worktree] = []
        for block in text.components(separatedBy: "\n\n") {
            var path = "", head = "", branch: String?, locked = false, prunable = false
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst(9)) }
                else if line.hasPrefix("HEAD ") { head = String(line.dropFirst(5)) }
                else if line.hasPrefix("branch ") {
                    let ref = String(line.dropFirst(7))
                    branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst(11)) : ref
                } else if line.hasPrefix("locked") { locked = true }
                else if line.hasPrefix("prunable") { prunable = true }
            }
            guard !path.isEmpty else { continue }
            result.append(Worktree(path: path, head: head, branch: branch, isMain: result.isEmpty,
                                   isLocked: locked, isPrunable: prunable))
        }
        return result
    }
}

public extension GitRepository {
    func worktrees() async throws -> [Worktree] {
        WorktreeParser.parse(try await git.runString(["worktree", "list", "--porcelain"], readOnly: true))
    }

    /// Checks out `branch` in a new folder. With `newBranch`, creates it from `startPoint` (or HEAD).
    func addWorktree(at path: URL, branch: String, newBranch: Bool, startPoint: String? = nil) async throws {
        var args = ["worktree", "add"]
        if newBranch { args += ["-b", branch, "--", path.path] + (startPoint.map { [$0] } ?? []) }
        else { args += ["--", path.path, branch] }
        try await git.run(args)
    }

    func removeWorktree(_ path: String, force: Bool) async throws {
        try await git.run(["worktree", "remove"] + (force ? ["--force"] : []) + ["--", path])
    }

    func pruneWorktrees() async throws { try await git.run(["worktree", "prune"]) }
}
