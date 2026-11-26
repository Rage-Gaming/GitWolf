import Foundation

public enum RebaseAction: String, Sendable, CaseIterable, Identifiable {
    case pick, reword, squash, fixup, drop
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    /// Folds into the commit above it.
    public var folds: Bool { self == .squash || self == .fixup }
}

public struct RebaseItem: Identifiable, Equatable, Sendable {
    public var id: String { hash }
    public let hash: String
    public let subject: String
    public var action: RebaseAction = .pick
    /// New full message when `action == .reword`.
    public var message: String

    public init(hash: String, subject: String, action: RebaseAction = .pick, message: String? = nil) {
        self.hash = hash; self.subject = subject; self.action = action; self.message = message ?? subject
    }
    public var shortHash: String { String(hash.prefix(7)) }
}

/// An interactive rebase to run: the commits after `base`, oldest first, each with an action.
public struct RebasePlan: Equatable, Sendable {
    /// The commit to rebase onto; nil rebases from the root commit.
    public var base: String?
    public var items: [RebaseItem]

    public init(base: String?, items: [RebaseItem]) { self.base = base; self.items = items }

    /// Why this plan cannot run, or nil when it can.
    public var problem: String? {
        let kept = items.filter { $0.action != .drop }
        if kept.isEmpty { return "Keep at least one commit, or the branch would be emptied." }
        if kept[0].action.folds { return "The first commit can’t be squashed or fixed up; there is nothing above it to fold into." }
        if items.contains(where: { $0.action == .reword && $0.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "A reworded commit needs a message."
        }
        return nil
    }

    /// True when the plan changes nothing, so there is no point running it.
    public var isNoOp: Bool { items.allSatisfy { $0.action == .pick } }

    /// The `git-rebase-todo` text. A reword is a pick followed by `exec git commit --amend -F <file>`,
    /// placed after any squash/fixup commits folded into it, so it names the final commit.
    func todo(messageFile: (Int) -> String, gitCommand: String) -> String {
        var lines: [String] = []
        var i = 0
        while i < items.count {
            let item = items[i]
            if item.action == .drop { lines.append("drop \(item.hash) \(item.subject)"); i += 1; continue }
            lines.append("pick \(item.hash) \(item.subject)")
            var j = i + 1
            while j < items.count, items[j].action.folds || items[j].action == .drop {
                if items[j].action != .drop { lines.append("\(items[j].action.rawValue) \(items[j].hash) \(items[j].subject)") }
                else { lines.append("drop \(items[j].hash) \(items[j].subject)") }
                j += 1
            }
            if item.action == .reword {
                lines.append("exec \(gitCommand) commit --amend -q -F \(Self.quote(messageFile(i)))")
            }
            i = j
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

extension GitRepository {
    /// The commits from `commit` up to HEAD, oldest first, as a plan with every action set to pick.
    /// `hasMerges` is true when the range contains merge commits, which interactive rebase would flatten.
    public func rebaseCandidates(from commit: String) async throws -> (plan: RebasePlan, hasMerges: Bool) {
        let parents = try await git.runString(["rev-list", "--parents", "-n", "1", commit], readOnly: true)
            .split(whereSeparator: { $0 == " " || $0 == "\n" }).dropFirst()
        let base = parents.first.map(String.init)
        let range = base.map { "\($0)..HEAD" } ?? "HEAD"
        let out = try await git.runString(["log", "--reverse", "--format=%H%x1f%s", range], readOnly: true)
        var items: [RebaseItem] = []
        for line in out.split(separator: "\n") {
            let f = line.split(separator: "\u{1f}", maxSplits: 1, omittingEmptySubsequences: false)
            if f.count == 2 { items.append(RebaseItem(hash: String(f[0]), subject: String(f[1]))) }
        }
        let merges = try await git.runString(["rev-list", "--merges", "--count", range], readOnly: true)
        return (RebasePlan(base: base, items: items), (Int(merges.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0)
    }

    /// Runs an interactive rebase without opening an editor. A conflict is not an error: the
    /// rebase is left in progress for the UI to resolve and continue.
    public func startInteractiveRebase(_ plan: RebasePlan) async throws {
        if let problem = plan.problem { throw GitError(command: "rebase", exitCode: 1, stderr: problem) }
        let support = OperationDetector.gitDirectory(root: root).appendingPathComponent("gitsync-rebase", isDirectory: true)
        let fm = FileManager.default
        try? fm.removeItem(at: support)
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        let messageFile: (Int) -> String = { support.appendingPathComponent("message-\($0)").path }
        for (i, item) in plan.items.enumerated() where item.action == .reword {
            try Data(item.message.utf8).write(to: URL(fileURLWithPath: messageFile(i)))
        }
        let todoURL = support.appendingPathComponent("todo")
        try Data(plan.todo(messageFile: messageFile, gitCommand: RebasePlan.quote(gitPath)).utf8).write(to: todoURL)

        let runner = GitRunner(workingDirectory: root, gitPath: gitPath,
                               extraEnvironment: ["GIT_SEQUENCE_EDITOR": "cp \(RebasePlan.quote(todoURL.path))"])
        var args = ["rebase", "-i", "--autostash"]
        if let base = plan.base { args.append(base) } else { args.append("--root") }
        try await rebaseRun(runner, args)
        if inProgressOperation() == nil { try? fm.removeItem(at: support) }
    }

    /// Rebases the current branch onto `target`.
    public func rebase(onto target: String) async throws {
        try await rebaseRun(git, ["rebase", "--autostash", target])
    }

    private func rebaseRun(_ runner: GitRunner, _ args: [String]) async throws {
        do { try await runner.run(args) }
        catch let error as GitError {
            // Stopping on a conflict is expected; anything else is a real failure.
            if inProgressOperation() == nil { throw error }
        }
    }
}
