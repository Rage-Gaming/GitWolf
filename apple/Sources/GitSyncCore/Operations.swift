import Foundation

/// A multi-step Git operation that stopped and is waiting for the user (usually because of conflicts).
public struct InProgressOperation: Equatable, Sendable {
    public enum Kind: String, Sendable { case merge, rebase, cherryPick, revert }

    public var kind: Kind
    /// 1-based position and total for rebases and multi-commit picks.
    public var step: Int?
    public var total: Int?
    /// Branch being rebased, when known.
    public var branch: String?

    public init(kind: Kind, step: Int? = nil, total: Int? = nil, branch: String? = nil) {
        self.kind = kind
        self.step = step
        self.total = total
        self.branch = branch
    }

    /// Merges can only be continued or aborted; the others can also skip the current commit.
    public var canSkip: Bool { kind != .merge }

    public var verb: String {
        switch kind {
        case .merge: "Merging"
        case .rebase: "Rebasing"
        case .cherryPick: "Cherry-picking"
        case .revert: "Reverting"
        }
    }

    public var title: String {
        var text = verb
        if let step, let total, total > 1 { text += " (\(step) of \(total))" }
        if kind == .rebase, let branch { text += " \(branch)" }
        return text
    }
}

enum OperationDetector {
    /// The real `.git` directory (follows the `gitdir:` pointer used by worktrees and submodules).
    static func gitDirectory(root: URL) -> URL {
        let dotGit = root.appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDir) else { return dotGit }
        if isDir.boolValue { return dotGit }
        if let text = try? String(contentsOf: dotGit, encoding: .utf8),
           let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) {
            let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            return path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        }
        return dotGit
    }

    static func detect(gitDir: URL) -> InProgressOperation? {
        let fm = FileManager.default
        func exists(_ name: String) -> Bool { fm.fileExists(atPath: gitDir.appendingPathComponent(name).path) }
        func read(_ name: String) -> String? {
            try? String(contentsOf: gitDir.appendingPathComponent(name), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func branchName(_ ref: String?) -> String? {
            guard let ref, ref.hasPrefix("refs/heads/") else { return nil }
            return String(ref.dropFirst("refs/heads/".count))
        }

        if exists("rebase-merge") {
            return InProgressOperation(
                kind: .rebase, step: read("rebase-merge/msgnum").flatMap(Int.init),
                total: read("rebase-merge/end").flatMap(Int.init), branch: branchName(read("rebase-merge/head-name")))
        }
        if exists("rebase-apply") {
            return InProgressOperation(
                kind: .rebase, step: read("rebase-apply/next").flatMap(Int.init),
                total: read("rebase-apply/last").flatMap(Int.init), branch: branchName(read("rebase-apply/head-name")))
        }
        let (step, total) = sequencerProgress(gitDir: gitDir)
        if exists("CHERRY_PICK_HEAD") { return InProgressOperation(kind: .cherryPick, step: step, total: total) }
        if exists("REVERT_HEAD") { return InProgressOperation(kind: .revert, step: step, total: total) }
        if exists("MERGE_HEAD") { return InProgressOperation(kind: .merge) }
        // A multi-commit pick/revert that stopped cleanly between commits only leaves the sequencer behind.
        if let todo = read("sequencer/todo"), let first = todo.split(separator: "\n").first {
            return InProgressOperation(kind: first.hasPrefix("revert") ? .revert : .cherryPick, step: step, total: total)
        }
        return nil
    }

    /// Position within a multi-commit cherry-pick/revert, from the sequencer's remaining todo list.
    private static func sequencerProgress(gitDir: URL) -> (Int?, Int?) {
        guard let todo = try? String(contentsOf: gitDir.appendingPathComponent("sequencer/todo"), encoding: .utf8) else { return (nil, nil) }
        let remaining = todo.split(separator: "\n").filter { !$0.hasPrefix("#") && !$0.isEmpty }.count
        let done = (try? String(contentsOf: gitDir.appendingPathComponent("sequencer/done"), encoding: .utf8))?
            .split(separator: "\n").filter { !$0.hasPrefix("#") && !$0.isEmpty }.count ?? 0
        let total = remaining + done
        return total > 0 ? (done + (remaining > 0 ? 1 : 0), total) : (nil, nil)
    }
}

public extension GitRepository {
    /// The operation currently waiting for the user, if any. Reads the git directory directly, so it is cheap.
    func inProgressOperation() -> InProgressOperation? {
        OperationDetector.detect(gitDir: OperationDetector.gitDirectory(root: root))
    }

    func continueOperation(_ op: InProgressOperation) async throws {
        try await git.run([subcommand(op), "--continue"])
    }

    func abortOperation(_ op: InProgressOperation) async throws {
        try await git.run([subcommand(op), "--abort"])
    }

    func skipOperation(_ op: InProgressOperation) async throws {
        guard op.canSkip else { return }
        try await git.run([subcommand(op), "--skip"])
    }

    private func subcommand(_ op: InProgressOperation) -> String {
        switch op.kind {
        case .merge: "merge"
        case .rebase: "rebase"
        case .cherryPick: "cherry-pick"
        case .revert: "revert"
        }
    }
}
