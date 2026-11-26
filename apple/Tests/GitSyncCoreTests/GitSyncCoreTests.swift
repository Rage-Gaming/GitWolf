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

// MARK: - Hunk / line staging

@Suite struct PatchTests {
    private func makeRepo() async throws -> (GitRepository, GitRunner, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitsync-patch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let runner = GitRunner(workingDirectory: dir)
        try await runner.run(["init", "-b", "main"])
        try await runner.run(["config", "user.name", "Tester"])
        try await runner.run(["config", "user.email", "t@example.com"])
        // Even if the user's config would change diff prefixes, our diffs must stay applicable.
        try await runner.run(["config", "diff.noprefix", "true"])
        return (GitRepository(root: dir), runner, dir)
    }

    private func write(_ lines: [String], to dir: URL, name: String = "f.txt") throws {
        try (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// 40 numbered lines committed, then lines 3 and 38 edited → two separate hunks.
    private func twoHunkRepo() async throws -> (GitRepository, GitRunner, URL) {
        let (repo, runner, dir) = try await makeRepo()
        let base = (1...40).map { "line \($0)" }
        try write(base, to: dir)
        try await repo.stage(["f.txt"])
        try await repo.commit(message: "base", amend: false)
        var edited = base
        edited[2] = "line 3 CHANGED"
        edited[37] = "line 38 CHANGED"
        try write(edited, to: dir)
        return (repo, runner, dir)
    }

    @Test func stagesSingleHunk() async throws {
        let (repo, _, dir) = try await twoHunkRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        let diff = try await repo.diff(for: DiffTarget(source: .unstaged, path: "f.txt"))
        #expect(diff.hunks.count == 2 && diff.canPatch)

        // Stage only the second hunk.
        let patch = try #require(PatchBuilder.make(diff: diff, selecting: diff.changedLineIDs(inHunk: 1), action: .stage))
        try await repo.apply(patch: patch, action: .stage)

        let staged = try await repo.diff(for: DiffTarget(source: .staged, path: "f.txt"))
        let unstaged = try await repo.diff(for: DiffTarget(source: .unstaged, path: "f.txt"))
        #expect(staged.hunks.count == 1 && staged.lines.contains { $0.text == "line 38 CHANGED" })
        #expect(unstaged.hunks.count == 1 && unstaged.lines.contains { $0.text == "line 3 CHANGED" })
    }

    @Test func stagesSingleLinesAndUnstagesThem() async throws {
        let (repo, _, dir) = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(["a", "b", "c"], to: dir)
        try await repo.stage(["f.txt"])
        try await repo.commit(message: "base", amend: false)
        try write(["a", "NEW1", "b", "NEW2", "c"], to: dir)

        var diff = try await repo.diff(for: DiffTarget(source: .unstaged, path: "f.txt"))
        let first = try #require(diff.lines.first { $0.text == "NEW1" })
        try await repo.apply(patch: try #require(PatchBuilder.make(diff: diff, selecting: [first.id], action: .stage)), action: .stage)

        var staged = try await repo.diff(for: DiffTarget(source: .staged, path: "f.txt"))
        var unstaged = try await repo.diff(for: DiffTarget(source: .unstaged, path: "f.txt"))
        #expect(staged.additions == 1 && staged.lines.contains { $0.text == "NEW1" })
        #expect(unstaged.additions == 1 && unstaged.lines.contains { $0.text == "NEW2" })

        // Now unstage that single line again.
        staged = try await repo.diff(for: DiffTarget(source: .staged, path: "f.txt"))
        let line = try #require(staged.lines.first { $0.text == "NEW1" })
        try await repo.apply(patch: try #require(PatchBuilder.make(diff: staged, selecting: [line.id], action: .unstage)), action: .unstage)
        staged = try await repo.diff(for: DiffTarget(source: .staged, path: "f.txt"))
        unstaged = try await repo.diff(for: DiffTarget(source: .unstaged, path: "f.txt"))
        #expect(staged.lines.isEmpty)
        #expect(unstaged.additions == 2)
    }

    @Test func stagesPartialDeletionsAndModifications() async throws {
        let (repo, _, dir) = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(["a", "b", "c", "d"], to: dir)
        try await repo.stage(["f.txt"])
        try await repo.commit(message: "base", amend: false)
        try write(["a", "B2", "d"], to: dir) // b→B2, c deleted

        let diff = try await repo.diff(for: DiffTarget(source: .unstaged, path: "f.txt"))
        let delC = try #require(diff.lines.first { $0.kind == .deletion && $0.text == "c" })
        try await repo.apply(patch: try #require(PatchBuilder.make(diff: diff, selecting: [delC.id], action: .stage)), action: .stage)

        let staged = try await repo.diff(for: DiffTarget(source: .staged, path: "f.txt"))
        #expect(staged.deletions == 1 && staged.additions == 0)
        #expect(staged.lines.contains { $0.kind == .deletion && $0.text == "c" })
    }

    @Test func discardsHunk() async throws {
        let (repo, _, dir) = try await twoHunkRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let diff = try await repo.diff(for: DiffTarget(source: .unstaged, path: "f.txt"))
        let patch = try #require(PatchBuilder.make(diff: diff, selecting: diff.changedLineIDs(inHunk: 0), action: .discard))
        try await repo.apply(patch: patch, action: .discard)

        let contents = try String(contentsOf: dir.appendingPathComponent("f.txt"), encoding: .utf8)
        #expect(contents.contains("line 3\n") && !contents.contains("line 3 CHANGED"))
        #expect(contents.contains("line 38 CHANGED"))
    }

    @Test func preservesCRLFAndMissingTrailingNewline() async throws {
        let (repo, _, dir) = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "a\r\nb\r\nc".write(to: dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try await repo.stage(["f.txt"])
        try await repo.commit(message: "base", amend: false)
        try "a\r\nB\r\nc".write(to: dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)

        let diff = try await repo.diff(for: DiffTarget(source: .unstaged, path: "f.txt"))
        try await repo.apply(patch: try #require(PatchBuilder.make(diff: diff, selecting: Set(diff.lines.filter(\.isChange).map(\.id)), action: .stage)), action: .stage)
        let status = try await repo.status()
        #expect(status.unstaged.isEmpty && status.staged.map(\.path) == ["f.txt"])
    }
}
