import Foundation
import Testing
@testable import GitSyncCore

@Suite struct ParserTests {
    @Test func parsesStatus() {
        let raw = "# branch.oid abc123\0# branch.head main\0# branch.upstream origin/main\0# branch.ab +2 -1\0"
            + "1 M. N... 100644 100644 100644 h1 h2 staged.txt\0"
            + "1 .M N... 100644 100644 100644 h1 h2 dir/work file.txt\0"
            + "2 R. N... 100644 100644 100644 h1 h2 R100 new.txt\0old.txt\0"
            + "? untracked.txt\0"
        let s = StatusParser.parse(Data(raw.utf8))
        #expect(s.branch == "main")
        #expect(s.upstream == "origin/main")
        #expect(s.ahead == 2 && s.behind == 1)
        #expect(s.staged.map(\.path) == ["staged.txt", "new.txt"])
        #expect(s.staged[1].originalPath == "old.txt")
        #expect(s.unstaged.map(\.path) == ["dir/work file.txt"])
        #expect(s.untracked.map(\.path) == ["untracked.txt"])
    }

    @Test func parsesDiffWithLineNumbersAndCRLF() {
        let raw = "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,2 +1,3 @@\n keep\r\n-old\n+new\n+added\n"
        let d = DiffParser.parse(Data(raw.utf8), maxLines: 100)
        #expect(d.additions == 2 && d.deletions == 1)
        #expect(d.lines.count == 5)
        #expect(d.lines[1].text == "keep")
        #expect(d.lines[2].oldNumber == 2 && d.lines[3].newNumber == 2)
    }

    @Test func parsesDecorations() {
        let refs = LogParser.parseDecorations("HEAD -> main, origin/main, tag: v1, feature/x", remotes: ["origin"])
        #expect(refs.map(\.kind) == [.local, .remote, .tag, .local])
        #expect(refs[0].isCurrent)
    }
}

@Suite struct GraphTests {
    private func c(_ h: String, _ p: [String]) -> Commit {
        Commit(hash: h, parents: p, authorName: "", authorEmail: "", date: .now, subject: "", refs: [])
    }

    @Test func linearHistoryStaysInOneLane() {
        let rows = GraphLayout.layout([c("c", ["b"]), c("b", ["a"]), c("a", [])])
        #expect(rows.allSatisfy { $0.lane == 0 && $0.laneCount == 1 })
    }

    @Test func mergeOpensAndClosesLane() {
        // m merges b into a-line; both descend from root r.
        let rows = GraphLayout.layout([c("m", ["a", "b"]), c("a", ["r"]), c("b", ["r"]), c("r", [])])
        #expect(rows[0].bottom.contains(GraphEdge(from: 0, to: 1)))
        #expect(rows[2].lane == 1)
        #expect(rows[3].top.contains(GraphEdge(from: 1, to: 0)))
    }
}

@Suite struct RepositoryIntegrationTests {
    @Test func commitFlowEndToEnd() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitsync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let runner = GitRunner(workingDirectory: dir)
        try await runner.run(["init", "-b", "main"])
        try await runner.run(["config", "user.name", "Tester"])
        try await runner.run(["config", "user.email", "t@example.com"])

        let repo = try await GitRepository.open(at: dir)
        try "hello\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        var status = try await repo.status()
        #expect(status.isUnborn && status.untracked.map(\.path) == ["a.txt"])

        try await repo.stage(["a.txt"])
        try await repo.commit(message: "first", amend: false)
        try "hello\nworld\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        status = try await repo.status()
        #expect(status.unstaged.map(\.path) == ["a.txt"])
        let diff = try await repo.diff(for: DiffTarget(source: .unstaged, path: "a.txt"))
        #expect(diff.additions == 1)

        let snap = try await repo.snapshot(commitLimit: 50)
        #expect(snap.commits.count == 1 && snap.commits[0].subject == "first")
        #expect(snap.localBranches.first?.isCurrent == true)
        let files = try await repo.files(in: snap.commits[0])
        #expect(files.map(\.path) == ["a.txt"])
    }
}
