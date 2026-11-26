import Foundation

/// The difference between two refs.
public struct RefComparison: Equatable, Sendable {
    /// Resolved commit hashes actually diffed. With `sinceAncestor`, `base` is the merge base.
    public var base: String
    public var head: String
    public var files: [FileChange]
    /// Commits reachable from `head` but not from the original `from` ref, newest first.
    public var commits: [Commit]
    /// Commits only in `from` (what `head` is missing).
    public var behind: Int
    public var ahead: Int { commits.count }
}

extension GitRepository {
    private func resolve(_ ref: String) async throws -> String {
        let name = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("-") else {
            throw GitError(command: "rev-parse", exitCode: 1, stderr: "Enter a branch, tag or commit.")
        }
        do {
            return try await git.runString(["rev-parse", "--verify", "--quiet", "\(name)^{commit}"], readOnly: true)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw GitError(command: "rev-parse", exitCode: 1, stderr: "“\(name)” isn’t a branch, tag or commit in this repository.")
        }
    }

    /// Compares `to` against `from`. With `sinceAncestor` the changes are those made on `to` since the
    /// two diverged (`git diff from...to`); otherwise every difference between the two tips.
    public func compare(from: String, to: String, sinceAncestor: Bool, remotes: Set<String> = []) async throws -> RefComparison {
        let fromHash = try await resolve(from)
        let toHash = try await resolve(to)
        var base = fromHash
        if sinceAncestor {
            base = (try? await git.runString(["merge-base", fromHash, toHash], readOnly: true))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if base.isEmpty { base = fromHash }
        }
        let files = RefParser.parseNameStatus(
            try await git.run(["diff", "--name-status", "-z", "-M", base, toHash], readOnly: true))
        let commits = LogParser.parse(
            try await git.run(["log", "--topo-order", "-z", "-n", "500", "--format=\(LogParser.format)", "\(fromHash)..\(toHash)"],
                              readOnly: true), remotes: remotes)
        let behind = try await git.runString(["rev-list", "--count", "\(toHash)..\(fromHash)"], readOnly: true)
        return RefComparison(base: base, head: toHash, files: files, commits: commits,
                             behind: Int(behind.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
    }
}
