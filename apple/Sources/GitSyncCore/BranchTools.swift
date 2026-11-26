import Foundation

/// A local branch that is probably safe to delete, and why.
public struct BranchCleanupItem: Identifiable, Equatable, Sendable {
    public enum Reason: Sendable { case merged, upstreamGone }
    public var id: String { name }
    public let name: String
    public let reason: Reason
    /// Fully merged into the base, so a normal delete succeeds. When false, deleting loses commits.
    public let isMerged: Bool
    public let hash: String
}

extension GitRepository {
    /// Branch names that cleanup never offers.
    static let protectedBranches: Set<String> = ["main", "master", "develop", "dev", "trunk", "release"]

    public func renameBranch(_ old: String, to new: String) async throws {
        let name = new.trimmingCharacters(in: .whitespacesAndNewlines)
        do { try await git.run(["check-ref-format", "--branch", name], readOnly: true) }
        catch { throw GitError(command: "branch", exitCode: 1, stderr: "“\(name)” isn’t a valid branch name.") }
        try await git.run(["branch", "-m", old, name])
    }

    /// Tracks `upstream` (e.g. `origin/main`); nil stops tracking.
    public func setUpstream(of branch: String, to upstream: String?) async throws {
        if let upstream { try await git.run(["branch", "--set-upstream-to=\(upstream)", branch]) }
        else { try await git.run(["branch", "--unset-upstream", branch]) }
    }

    /// Local branches that are merged into `base` or whose remote branch is gone.
    public func cleanupCandidates(base: String) async throws -> [BranchCleanupItem] {
        let local = try await branches().local
        let mergedOut = try await git.runString(["branch", "--merged", base, "--format=%(refname:short)"], readOnly: true)
        let merged = Set(mergedOut.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) })
        return local.compactMap { b in
            guard !b.isCurrent, b.name != base, !Self.protectedBranches.contains(b.name) else { return nil }
            if b.upstreamGone { return BranchCleanupItem(name: b.name, reason: .upstreamGone, isMerged: merged.contains(b.name), hash: b.hash) }
            if merged.contains(b.name) { return BranchCleanupItem(name: b.name, reason: .merged, isMerged: true, hash: b.hash) }
            return nil
        }
    }

    /// Deletes each branch, forcing only the ones that aren't merged. Returns the names that failed.
    public func deleteBranches(_ items: [BranchCleanupItem]) async -> [String] {
        var failed: [String] = []
        for item in items {
            do { try await deleteBranch(item.name, force: !item.isMerged) } catch { failed.append(item.name) }
        }
        return failed
    }
}
