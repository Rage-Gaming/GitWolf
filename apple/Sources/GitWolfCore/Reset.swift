import Foundation

public enum ResetMode: String, Sendable, CaseIterable {
    /// Move the branch only; everything stays staged.
    case soft
    /// Move the branch and unstage; working files are kept.
    case mixed
    /// Move the branch and overwrite the working tree. Uncommitted changes are lost.
    case hard
    /// Like hard, but refuses if it would overwrite uncommitted changes. Used by Undo.
    case keep

    public var title: String {
        switch self {
        case .soft: "Soft"
        case .mixed: "Mixed"
        case .hard: "Hard"
        case .keep: "Keep"
        }
    }
}

/// One line of `git reflog`: where HEAD was, and what moved it there.
public struct ReflogEntry: Equatable, Sendable, Identifiable {
    /// Position, so `HEAD@{index}` names this entry.
    public let index: Int
    public let hash: String
    public let message: String
    public let date: Date
    public var id: Int { index }
    public var shortHash: String { String(hash.prefix(7)) }
    public var selector: String { "HEAD@{\(index)}" }
}

/// What a reset would throw away, so the UI can say so before doing it.
public struct ResetImpact: Equatable, Sendable {
    /// Commits on the current branch that the target does not contain.
    public var droppedCommits: Int
    /// Uncommitted changes (staged, unstaged, untracked excluded) a hard reset would overwrite.
    public var modifiedFiles: Int
}

extension GitRepository {
    public func reset(to target: String, mode: ResetMode) async throws {
        try await git.run(["reset", "--\(mode.rawValue)", target, "--"])
    }

    public func reflog(limit: Int = 200) async throws -> [ReflogEntry] {
        let out = try await git.runString(
            ["reflog", "show", "--date=unix", "-n", "\(limit)", "--format=%H%x1f%ct%x1f%gs", "HEAD", "--"],
            readOnly: true)
        var entries: [ReflogEntry] = []
        for line in out.split(separator: "\n") {
            let f = line.split(separator: "\u{1f}", maxSplits: 2, omittingEmptySubsequences: false)
            guard f.count == 3, let t = TimeInterval(f[1]) else { continue }
            entries.append(ReflogEntry(index: entries.count, hash: String(f[0]), message: String(f[2]),
                                       date: Date(timeIntervalSince1970: t)))
        }
        return entries
    }

    public func resetImpact(to target: String) async throws -> ResetImpact {
        let count = try await git.runString(["rev-list", "--count", "\(target)..HEAD"], readOnly: true)
        let status = try await status()
        return ResetImpact(droppedCommits: Int(count.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0,
                           modifiedFiles: status.staged.count + status.unstaged.count)
    }
}

/// What "Undo" should do, worked out from the reflog.
public enum UndoPlan: Equatable, Sendable {
    /// Move HEAD back to this commit, keeping uncommitted work.
    case reset(to: String, label: String, from: String)
    /// Switch back to where a checkout came from (a branch name, or a commit when detached).
    case switchBack(to: String, detached: Bool, from: String)

    /// Chooses the undo for the newest reflog entries (newest first); nil when there is nothing to undo.
    public static func plan(for log: [ReflogEntry]) -> UndoPlan? {
        guard log.count > 1 else { return nil }
        let newest = log[0].message
        if newest.hasPrefix("checkout: moving from "), let range = newest.range(of: " to ", options: .backwards) {
            let from = String(newest[newest.index(newest.startIndex, offsetBy: "checkout: moving from ".count)..<range.lowerBound])
            let detached = from.count >= 40 && from.allSatisfy(\.isHexDigit)
            return .switchBack(to: from, detached: detached, from: String(newest[range.upperBound...]))
        }
        // A rebase is many entries; undo the whole thing back to before it started.
        if newest.hasPrefix("rebase") {
            if let before = log.first(where: { !$0.message.hasPrefix("rebase") }) {
                return .reset(to: before.hash, label: "rebase", from: newest)
            }
            return nil
        }
        return .reset(to: log[1].hash, label: newest, from: newest)
    }
}

public extension GitRepository {
    /// Switches to a branch, or detaches at a commit.
    func switchBack(to name: String, detached: Bool) async throws {
        if detached { try await git.run(["checkout", "--detach", name, "--"]) }
        else { try await git.run(["switch", name, "--"]) }
    }
}
