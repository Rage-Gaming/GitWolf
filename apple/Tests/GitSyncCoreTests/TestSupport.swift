import Foundation
@testable import GitSyncCore

/// A throw-away repository on disk, deleted when the test ends via `cleanup()`.
struct TestRepo {
    let repo: GitRepository
    let git: GitRunner
    let dir: URL

    static func make(name: String = "gitsync-test") async throws -> TestRepo {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let git = GitRunner(workingDirectory: dir)
        try await git.run(["init", "-b", "main"])
        try await git.run(["config", "user.name", "Tester"])
        try await git.run(["config", "user.email", "t@example.com"])
        try await git.run(["config", "commit.gpgsign", "false"])
        return TestRepo(repo: GitRepository(root: dir), git: git, dir: dir)
    }

    func write(_ text: String, _ name: String = "f.txt") throws {
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func read(_ name: String = "f.txt") throws -> String {
        try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    @discardableResult
    func commit(_ message: String, file: String = "f.txt", text: String? = nil) async throws -> String {
        if let text { try write(text, file) }
        try await git.run(["add", "-A"])
        try await git.run(["commit", "-m", message])
        return try await git.runString(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `main` and `feature` both change f.txt line 2 differently, so merging/rebasing/picking conflicts.
    static func conflicting() async throws -> TestRepo {
        let t = try await make()
        try await t.commit("base", text: "one\ntwo\nthree\n")
        try await t.git.run(["switch", "-c", "feature"])
        try await t.commit("feature change", text: "one\nFEATURE\nthree\n")
        try await t.git.run(["switch", "main"])
        try await t.commit("main change", text: "one\nMAIN\nthree\n")
        return t
    }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}
