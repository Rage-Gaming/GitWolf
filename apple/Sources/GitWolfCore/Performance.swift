import Foundation

public extension GitRepository {
    /// Whether git has a commit-graph cache, which makes history queries on big repositories much faster.
    func hasCommitGraph() async -> Bool {
        for name in ["objects/info/commit-graph", "objects/info/commit-graphs"] {
            guard let path = try? await git.runString(["rev-parse", "--git-path", name], readOnly: true)
                .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { continue }
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path) { return true }
        }
        return false
    }

    /// Writes git's commit-graph cache (the same file `git gc` and `git maintenance` keep). It only adds a
    /// cache under `.git`; history, branches and files are untouched. On a 100,000-commit repository it cuts
    /// loading the history from about 0.4s to about 0.015s.
    func writeCommitGraph() async throws {
        try await git.run(["commit-graph", "write", "--reachable", "--changed-paths"])
    }
}
