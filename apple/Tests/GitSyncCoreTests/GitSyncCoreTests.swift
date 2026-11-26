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

// MARK: - Syntax highlighting

@Suite struct SyntaxTests {
    private func kinds(_ text: String, _ ext: String = "swift") -> [(String, SyntaxKind)] {
        var state = SyntaxHighlighter.State()
        let lang = SyntaxHighlighter.Language.forPath("f.\(ext)")!
        let chars = Array(text)
        return SyntaxHighlighter.tokenize(text, lang, &state).map { (String(chars[$0.start..<$0.end]), $0.kind) }
    }

    @Test func swiftBasics() {
        let t = kinds("let name: String = \"hi // not a comment\" // real foo(42)")
        #expect(t.contains { $0 == ("let", .keyword) })
        #expect(t.contains { $0 == ("String", .type) })
        #expect(t.contains { $0.1 == .string && $0.0.contains("not a comment") })
        #expect(t.last?.1 == .comment && t.last?.0.hasPrefix("// real") == true)
        #expect(!t.contains { $0.0 == "foo" })  // swallowed by the trailing comment
    }

    @Test func blockCommentsSpanLines() {
        let diff = DiffParser.parse(Data("diff --git a/f.c b/f.c\n--- a/f.c\n+++ b/f.c\n@@ -1,3 +1,3 @@\n /* start\n+middle\n end */ int x;\n".utf8), maxLines: 100)
        let tokens = SyntaxHighlighter.tokens(for: diff, path: "f.c")
        let middle = diff.lines.first { $0.text == "middle" }!
        #expect(tokens[middle.id]?.first?.kind == .comment)
    }

    @Test func unknownExtensionIsPlain() {
        #expect(SyntaxHighlighter.Language.forPath("notes.xyz") == nil)
    }
}

@Suite struct SideBySideTests {
    @Test func pairsDeletionsWithAdditions() {
        let raw = "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,5 +1,6 @@\n keep\n-old1\n-old2\n+new1\n+new2\n+new3\n tail\n"
        let diff = DiffParser.parse(Data(raw.utf8), maxLines: 100)
        let rows = SideBySide.rows(for: diff)
        #expect(rows.count == 6) // header, keep, 3 change rows, tail
        #expect(rows[0].header != nil)
        #expect(rows[1].left?.text == "keep" && rows[1].right?.text == "keep")
        #expect(rows[2].left?.text == "old1" && rows[2].right?.text == "new1")
        #expect(rows[3].left?.text == "old2" && rows[3].right?.text == "new2")
        #expect(rows[4].left == nil && rows[4].right?.text == "new3")
        #expect(rows[5].left?.text == "tail")
    }

    @Test func pureDeletionLeavesRightBlank() {
        let raw = "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,2 +1,1 @@\n a\n-b\n"
        let rows = SideBySide.rows(for: DiffParser.parse(Data(raw.utf8), maxLines: 100))
        #expect(rows.last?.left?.text == "b" && rows.last?.right == nil)
    }
}

// MARK: - Clone / init

@Suite struct CreateRepositoryTests {
    @Test func suggestsNamesFromCloneURLs() {
        #expect(GitRepository.suggestedName(forCloneURL: "https://github.com/ipuppyyt/git-sync.git") == "git-sync")
        #expect(GitRepository.suggestedName(forCloneURL: "git@github.com:org/repo") == "repo")
        #expect(GitRepository.suggestedName(forCloneURL: "https://host/a/b/") == "b")
        #expect(GitRepository.suggestedName(forCloneURL: "  /tmp/local/proj.git  ") == "proj")
        #expect(GitRepository.suggestedName(forCloneURL: "") == "")
    }

    @Test func initialisesAndClonesRepository() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("gitsync-clone-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }

        let source = try await GitRepository.initialize(at: base.appendingPathComponent("origin/nested"), initialBranch: "trunk")
        let runner = GitRunner(workingDirectory: source)
        try await runner.run(["config", "user.name", "T"])
        try await runner.run(["config", "user.email", "t@example.com"])
        try "x\\n".write(to: source.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await runner.run(["add", "."])
        try await runner.run(["commit", "-m", "init"])
        let branch = try await runner.runString(["branch", "--show-current"])
        #expect(branch.trimmingCharacters(in: .whitespacesAndNewlines) == "trunk")

        let clones = base.appendingPathComponent("clones")
        try FileManager.default.createDirectory(at: clones, withIntermediateDirectories: true)
        let dest = try await GitRepository.clone(url: source.path, into: clones, name: "copy")
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("a.txt").path))

        // Cloning again into the same non-empty folder is refused.
        await #expect(throws: GitError.self) {
            _ = try await GitRepository.clone(url: source.path, into: clones, name: "copy")
        }
    }
}

// MARK: - Providers

@Suite struct ProviderTests {
    @Test func parsesRemoteURLs() {
        #expect(RemoteLocation.parse("https://github.com/ipuppyyt/git-sync.git") == RemoteLocation(host: "github.com", path: "ipuppyyt/git-sync"))
        #expect(RemoteLocation.parse("git@gitlab.com:group/sub/proj.git") == RemoteLocation(host: "gitlab.com", path: "group/sub/proj"))
        #expect(RemoteLocation.parse("ssh://git@bitbucket.org:22/team/repo.git") == RemoteLocation(host: "bitbucket.org", path: "team/repo"))
        #expect(RemoteLocation.parse("https://user:secret@Example.COM/a/b/") == RemoteLocation(host: "example.com", path: "a/b"))
        #expect(RemoteLocation.parse("git@ssh.dev.azure.com:v3/org/proj/repo") == RemoteLocation(host: "dev.azure.com", path: "org/proj/_git/repo"))
        #expect(RemoteLocation.parse("/Users/me/local/repo") == nil)
        #expect(RemoteLocation.parse("") == nil)
    }

    @Test func guessesProviderFromHost() {
        #expect(ProviderKind.guess(host: "github.com") == .github)
        #expect(ProviderKind.guess(host: "gitlab.example.org") == .gitlab)
        #expect(ProviderKind.guess(host: "codeberg.org") == .gitea)
        #expect(ProviderKind.guess(host: "dev.azure.com") == .azure)
        #expect(ProviderKind.guess(host: "git.internal.corp") == nil)
    }

    @Test func buildsWebLinks() {
        let loc = RemoteLocation(host: "github.com", path: "o/r")
        let gh = WebLinks(kind: .github, location: loc)
        #expect(gh.repository?.absoluteString == "https://github.com/o/r")
        #expect(gh.branch("feature/x y")?.absoluteString == "https://github.com/o/r/tree/feature/x%20y")
        #expect(gh.commit("abc")?.absoluteString == "https://github.com/o/r/commit/abc")
        #expect(gh.newPullRequest(from: "feature/x")?.absoluteString == "https://github.com/o/r/compare/feature/x?expand=1")

        let gl = WebLinks(kind: .gitlab, location: RemoteLocation(host: "gitlab.com", path: "g/p"))
        #expect(gl.commit("abc")?.absoluteString == "https://gitlab.com/g/p/-/commit/abc")
        #expect(gl.newPullRequest(from: "a&b")?.absoluteString.contains("source_branch%5D=a%26b") == true)
        #expect(gl.pullRequestsWord == "Merge Request")

        let unknown = WebLinks(kind: nil, location: RemoteLocation(host: "git.corp", path: "x/y"))
        #expect(unknown.branch("main")?.absoluteString == "https://git.corp/x/y")
    }

    @Test func askpassEnvironmentIsolatesCredential() {
        let env = GitCredential(host: "github.com", username: "", token: "tok").environment(askpassPath: "/tmp/ap")
        #expect(env["GIT_ASKPASS"] == "/tmp/ap" && env["GITSYNC_ASKPASS_USER"] == "git" && env["GITSYNC_ASKPASS_TOKEN"] == "tok")
        #expect(env["GIT_CONFIG_KEY_0"] == "credential.helper" && env["GIT_CONFIG_VALUE_0"] == "")
    }

    // Stub transport that records requests and serves canned JSON.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [URLRequest] = []
        private var index = 0
        var requests: [URLRequest] { lock.withLock { log } }
        func record(_ request: URLRequest) -> Int {
            lock.withLock { log.append(request); index += 1; return index - 1 }
        }
    }

    private func client(_ kind: ProviderKind, host: String? = nil, username: String = "me",
                        pages: [String], status: Int = 200, recorder: Recorder = Recorder()) -> ProviderClient {
        let account = ProviderAccount(kind: kind, host: host ?? kind.defaultHost, username: username)
        return ProviderClient(account: account, token: "secret") { request in
            let index = recorder.record(request)
            let body = pages[min(index, pages.count - 1)]
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }

    @Test func listsGitHubRepositories() async throws {
        let rec = Recorder()
        let c = client(.github, pages: [#"[{"full_name":"o/r","description":null,"private":true,"clone_url":"https://github.com/o/r.git","ssh_url":"git@github.com:o/r.git","pushed_at":"2026-01-02T03:04:05Z"}]"#], recorder: rec)
        let repos = try await c.repositories()
        #expect(repos.count == 1 && repos[0].fullName == "o/r" && repos[0].isPrivate && repos[0].updated != nil && repos[0].name == "r")
        #expect(rec.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(rec.requests[0].url?.host == "api.github.com")
    }

    @Test func listsGitLabRepositoriesFromSelfHostedHost() async throws {
        let rec = Recorder()
        let c = client(.gitlab, host: "git.corp.io", pages: [#"[{"path_with_namespace":"g/p","description":"d","visibility":"internal","http_url_to_repo":"https://git.corp.io/g/p.git","ssh_url_to_repo":"git@git.corp.io:g/p.git","last_activity_at":"2026-01-02T03:04:05.123Z"}]"#], recorder: rec)
        let repos = try await c.repositories()
        #expect(repos.first?.httpsURL == "https://git.corp.io/g/p.git" && repos.first?.isPrivate == true)
        #expect(rec.requests[0].url?.absoluteString.hasPrefix("https://git.corp.io/api/v4/projects") == true)
        #expect(rec.requests[0].value(forHTTPHeaderField: "PRIVATE-TOKEN") == "secret")
    }

    @Test func supportsEnterpriseHosts() async throws {
        let rec = Recorder()
        let ghe = client(.github, host: "github.acme.com", pages: ["[]"], recorder: rec)
        _ = try await ghe.repositories()
        #expect(rec.requests[0].url?.absoluteString.hasPrefix("https://github.acme.com/api/v3/user/repos") == true)

        let rec2 = Recorder()
        let account = ProviderAccount(kind: .gitlab, host: "git.lan:8080", username: "me", scheme: "http")
        let lan = ProviderClient(account: account, token: "t") { request in
            _ = rec2.record(request)
            return (Data("[]".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        _ = try await lan.repositories()
        #expect(rec2.requests[0].url?.absoluteString.hasPrefix("http://git.lan:8080/api/v4/projects") == true)
        #expect(account.hostName == "git.lan")

        let rec3 = Recorder()
        let dc = client(.bitbucket, host: "bitbucket.acme.com", pages: [#"{"isLastPage":true,"values":[{"slug":"r","project":{"key":"P"},"public":false,"links":{"clone":[{"name":"http","href":"https://me@bitbucket.acme.com/scm/p/r.git"},{"name":"ssh","href":"ssh://git@bitbucket.acme.com/p/r.git"}]}}]}"#], recorder: rec3)
        let repos = try await dc.repositories()
        #expect(repos.first?.fullName == "P/r" && repos.first?.httpsURL == "https://bitbucket.acme.com/scm/p/r.git")
        #expect(rec3.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(rec3.requests[0].url?.path == "/rest/api/1.0/repos")
    }

    @Test func passwordAccountsUseBasicAuth() async throws {
        let rec = Recorder()
        let account = ProviderAccount(kind: .gitea, host: "git.corp.io", username: "me", usesPassword: true)
        let c = ProviderClient(account: account, token: "pw") { request in
            _ = rec.record(request)
            return (Data("[]".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        _ = try await c.repositories()
        #expect(rec.requests[0].value(forHTTPHeaderField: "Authorization") == "Basic " + Data("me:pw".utf8).base64EncodedString())
    }

    @Test func listsGiteaAndBitbucketRepositories() async throws {
        let gitea = client(.gitea, pages: [#"[{"full_name":"u/r","clone_url":"https://codeberg.org/u/r.git","ssh_url":"x","private":false,"updated_at":"2026-01-02T03:04:05Z"}]"#])
        #expect(try await gitea.repositories().first?.fullName == "u/r")

        let bb = client(.bitbucket, username: "me", pages: [
            #"{"values":[{"full_name":"t/a","is_private":true,"links":{"clone":[{"name":"https","href":"https://me@bitbucket.org/t/a.git"},{"name":"ssh","href":"git@bitbucket.org:t/a.git"}]}}],"next":"https://api.bitbucket.org/2.0/repositories?page=2"}"#,
            #"{"values":[{"full_name":"t/b","is_private":false,"links":{"clone":[{"name":"https","href":"https://bitbucket.org/t/b.git"}]}}]}"#])
        let repos = try await bb.repositories()
        #expect(repos.map(\.fullName) == ["t/a", "t/b"])
        #expect(repos[0].httpsURL == "https://bitbucket.org/t/a.git")   // username stripped
    }

    @Test func verifiesTokenAndReportsRejection() async throws {
        let ok = client(.github, pages: [#"{"login":"octo"}"#])
        #expect(try await ok.currentUser() == "octo")
        let bad = client(.gitlab, pages: ["{}"], status: 401)
        await #expect(throws: ProviderError.self) { _ = try await bad.currentUser() }
    }

    @Test func paginatesUntilShortPage() async throws {
        let rec = Recorder()
        let full = "[" + (0..<100).map { #"{"full_name":"o/r\#($0)","clone_url":"u"}"# }.joined(separator: ",") + "]"
        let c = client(.github, pages: [full, #"[{"full_name":"o/last","clone_url":"u"}]"#], recorder: rec)
        let repos = try await c.repositories()
        #expect(repos.count == 101 && rec.requests.count == 2)
    }

    @Test func askpassScriptAnswersPrompts() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("askpass.sh")
        try GitCredential.askpassScript.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        func ask(_ prompt: String) throws -> String {
            let p = Process()
            p.executableURL = script
            p.arguments = [prompt]
            p.environment = ["GITSYNC_ASKPASS_USER": "octo", "GITSYNC_ASKPASS_TOKEN": "s3cret"]
            let out = Pipe()
            p.standardOutput = out
            try p.run(); p.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .newlines)
        }
        #expect(try ask("Username for 'https://github.com': ") == "octo")
        #expect(try ask("Password for 'https://octo@github.com': ") == "s3cret")
    }
}

@Suite struct OAuthTests {
    private final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var bodies: [String]
        private(set) var requests: [URLRequest] = []
        private(set) var sleeps: [Int] = []
        init(_ bodies: [String]) { self.bodies = bodies }
        func next(_ r: URLRequest) -> String {
            lock.withLock { requests.append(r); return bodies.count > 1 ? bodies.removeFirst() : bodies[0] }
        }
        func slept(_ s: Int) { lock.withLock { sleeps.append(s) } }
    }

    private func client(_ kind: ProviderKind, _ script: Script, origin: String = "https://github.com") -> OAuthClient {
        OAuthClient(kind: kind, origin: origin, clientID: "cid", transport: { request in
            (Data(script.next(request).utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, sleep: { script.slept($0) })
    }

    @Test func pkceMatchesRFC7636Vector() {
        #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let p = PKCE.generate()
        #expect(p.verifier.count >= 43 && PKCE.challenge(for: p.verifier) == p.challenge)
        #expect(!p.challenge.contains("=") && !p.challenge.contains("+") && !p.challenge.contains("/"))
    }

    @Test func buildsAuthorizationURLs() {
        let gl = client(.gitlab, Script(["{}"]), origin: "https://gitlab.acme.com")
        let url = gl.authorizationURL(redirectURI: OAuthLoopback.redirectURI, state: "s1", challenge: "ch")?.absoluteString ?? ""
        #expect(url.hasPrefix("https://gitlab.acme.com/oauth/authorize?"))
        #expect(url.contains("client_id=cid") && url.contains("code_challenge=ch") && url.contains("code_challenge_method=S256"))
        #expect(url.contains("state=s1") && url.contains("response_type=code") && url.contains("scope=read_api"))
        let gitea = client(.gitea, Script(["{}"]), origin: "https://codeberg.org")
        #expect(gitea.authorizationURL(redirectURI: "r", state: "s", challenge: "c")?.absoluteString.hasPrefix("https://codeberg.org/login/oauth/authorize?") == true)
    }

    @Test func exchangesCodeAndRefreshes() async throws {
        let script = Script([#"{"access_token":"a1","refresh_token":"r1","expires_in":7200}"#,
                             #"{"access_token":"a2","expires_in":7200}"#])
        let c = client(.gitlab, script, origin: "https://gitlab.com")
        let tokens = try await c.exchange(code: "the code", verifier: "ver", redirectURI: OAuthLoopback.redirectURI)
        #expect(tokens.accessToken == "a1" && tokens.refreshToken == "r1" && tokens.expiresAt != nil && !tokens.needsRefresh())
        let body = String(decoding: script.requests[0].httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("grant_type=authorization_code") && body.contains("code=the%20code") && body.contains("code_verifier=ver"))
        #expect(script.requests[0].url?.absoluteString == "https://gitlab.com/oauth/token")

        let fresh = try await c.refresh(OAuthTokens(accessToken: "a1", refreshToken: "r1", expiresAt: Date().addingTimeInterval(-5)))
        #expect(fresh.accessToken == "a2" && fresh.refreshToken == "r1")  // refresh token kept when not rotated
        #expect(OAuthTokens(accessToken: "x", expiresAt: Date().addingTimeInterval(-1)).needsRefresh())
        #expect(!OAuthTokens(accessToken: "x").needsRefresh())
    }

    @Test func deviceFlowPollsUntilApproved() async throws {
        let script = Script([
            #"{"device_code":"dc","user_code":"ABCD-1234","verification_uri":"https://github.com/login/device","interval":5,"expires_in":900}"#,
            #"{"error":"authorization_pending"}"#,
            #"{"error":"slow_down"}"#,
            #"{"access_token":"gho_x","token_type":"bearer"}"#,
        ])
        let c = client(.github, script)
        let device = try await c.startDeviceFlow()
        #expect(device.userCode == "ABCD-1234" && device.interval == 5)
        let tokens = try await c.pollDeviceFlow(device)
        #expect(tokens.accessToken == "gho_x" && tokens.expiresAt == nil)
        #expect(script.sleeps == [5, 5, 10])  // slow_down adds 5 seconds
        #expect(script.requests[1].url?.absoluteString == "https://github.com/login/oauth/access_token")
    }

    @Test func deviceFlowReportsDenialAndExpiry() async {
        let denied = client(.github, Script([#"{"error":"access_denied"}"#]))
        let device = DeviceCode(deviceCode: "d", userCode: "u", verificationURL: URL(string: "https://x")!, interval: 1, expiresIn: 30)
        await #expect(throws: OAuthError.denied) { try await denied.pollDeviceFlow(device) }
        let expired = client(.github, Script([#"{"error":"expired_token"}"#]))
        await #expect(throws: OAuthError.expired) { try await expired.pollDeviceFlow(device) }
    }

    @Test func oauthAccountsUseBearerAndProviderFlows() async throws {
        #expect(ProviderKind.github.oauthFlow == .device && ProviderKind.gitlab.oauthFlow == .pkce && ProviderKind.bitbucket.oauthFlow == .pkce && ProviderKind.azure.oauthFlow == .pkce)
        #expect(GitCredential.oauthUsername(kind: .gitlab, fallback: "me") == "oauth2")
        let account = ProviderAccount(kind: .gitlab, host: "gitlab.com", username: "me", oauthClientID: "cid")
        #expect(account.usesOAuth)
        let script = Script(["[]"])
        let c = ProviderClient(account: account, token: "tok") { request in
            _ = script.next(request)
            return (Data("[]".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        _ = try await c.repositories()
        #expect(script.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(script.requests[0].value(forHTTPHeaderField: "PRIVATE-TOKEN") == nil)
    }
}

@Suite struct CollabTests {
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URLRequest] = []
        var requests: [URLRequest] { lock.withLock { urls } }
        func add(_ r: URLRequest) { lock.withLock { urls.append(r) } }
    }

    private func client(_ kind: ProviderKind, host: String? = nil, token: String = "t", body: @escaping @Sendable (URLRequest) -> String, log: Log = Log()) -> ProviderClient {
        let account = ProviderAccount(kind: kind, host: host ?? kind.defaultHost, username: "me")
        return ProviderClient(account: account, token: token) { r in
            log.add(r)
            return (Data(body(r).utf8), HTTPURLResponse(url: r.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test func githubPullRequestsAndIssues() async throws {
        let log = Log()
        let prs = client(.github, body: { _ in
            #"[{"number":7,"title":"Add thing","user":{"login":"ann"},"state":"closed","merged_at":"2026-01-02T03:04:05Z","draft":false,"labels":[{"name":"bug"}],"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-02T03:04:05Z","html_url":"https://github.com/o/r/pull/7","body":"hi","head":{"ref":"feat"},"base":{"ref":"main"}},{"number":8,"title":"WIP","user":{"login":"bob"},"state":"open","draft":true,"labels":[]}]"#
        }, log: log)
        let items = try await prs.collab(.pullRequest, repoPath: "o/r", filter: .closed, page: 2)
        #expect(items.map(\.number) == [7, 8] && items[0].state == .merged && items[1].isDraft && items[1].state == .open)
        #expect(items[0].sourceBranch == "feat" && items[0].targetBranch == "main" && items[0].labels == ["bug"])
        let url = log.requests[0].url?.absoluteString ?? ""
        #expect(url.hasPrefix("https://api.github.com/repos/o/r/pulls?state=closed") && url.contains("page=2"))

        let issues = client(.github, body: { _ in
            #"[{"number":1,"title":"Bug","user":{"login":"a"},"state":"open","comments":3},{"number":2,"title":"A PR","state":"open","pull_request":{}}]"#
        })
        let list = try await issues.collab(.issue, repoPath: "o/r", filter: .open, page: 1)
        #expect(list.map(\.number) == [1] && list[0].comments == 3)  // the pull request is filtered out
    }

    @Test func gitlabMergeRequestsEncodeProjectAndMergeStates() async throws {
        let log = Log()
        let c = client(.gitlab, host: "git.acme.io", body: { r in
            r.url!.absoluteString.contains("state=merged")
                ? #"[{"iid":4,"title":"Merged one","state":"merged","author":{"username":"zed"},"updated_at":"2026-02-02T00:00:00Z","source_branch":"a","target_branch":"main","labels":["x"],"user_notes_count":2}]"#
                : #"[{"iid":5,"title":"Closed one","state":"closed","updated_at":"2026-03-02T00:00:00Z"}]"#
        }, log: log)
        let items = try await c.collab(.pullRequest, repoPath: "grp/sub/proj", filter: .closed, page: 1)
        #expect(items.map(\.number) == [5, 4] && items[1].state == .merged && items[1].comments == 2)  // newest first
        #expect(log.requests.count == 2)
        #expect(log.requests[0].url?.absoluteString.contains("/projects/grp%2Fsub%2Fproj/merge_requests") == true)
        #expect(log.requests[0].value(forHTTPHeaderField: "PRIVATE-TOKEN") == "t")
    }

    @Test func giteaAndBitbucket() async throws {
        let gitea = client(.gitea, body: { _ in #"[{"number":3,"title":"WIP: x","state":"open","merged":false,"user":{"login":"u"},"head":{"ref":"h"},"base":{"ref":"main"}}]"# })
        let g = try await gitea.collab(.pullRequest, repoPath: "u/r", filter: .open, page: 1)
        #expect(g.first?.isDraft == true && g.first?.sourceBranch == "h")

        let log = Log()
        let bb = client(.bitbucket, body: { _ in #"{"values":[{"id":9,"title":"BB","state":"DECLINED","author":{"display_name":"Dee"},"source":{"branch":{"name":"s"}},"destination":{"branch":{"name":"main"}},"links":{"html":{"href":"https://bitbucket.org/w/r/pull-requests/9"}}}]}"# }, log: log)
        let b = try await bb.collab(.pullRequest, repoPath: "w/r", filter: .closed, page: 1)
        #expect(b.first?.state == .closed && b.first?.author == "Dee" && b.first?.url?.lastPathComponent == "9")
        #expect(log.requests[0].url?.absoluteString.contains("state=MERGED&state=DECLINED") == true)
        await #expect(throws: ProviderError.self) { try await bb.collab(.issue, repoPath: "w/r", filter: .open, page: 1) }
    }

    @Test func publicAccessSendsNoCredentials() async throws {
        let log = Log()
        let c = client(.github, token: "", body: { _ in "[]" }, log: log)
        _ = try await c.collab(.pullRequest, repoPath: "o/r", filter: .open, page: 1)
        #expect(log.requests[0].value(forHTTPHeaderField: "Authorization") == nil)
        #expect(ProviderKind.azure.supportsCollab(.issue, host: "dev.azure.com") == false)
    }
}

@Suite struct OAuthBitbucketAzureTests {
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [URLRequest] = []
        var requests: [URLRequest] { lock.withLock { items } }
        func add(_ r: URLRequest) { lock.withLock { items.append(r) } }
    }

    private func client(_ kind: ProviderKind, secret: String? = nil, log: Log, body: String) -> OAuthClient {
        OAuthClient(kind: kind, origin: "https://\(kind.defaultHost)", clientID: "cid", clientSecret: secret, transport: { r in
            log.add(r)
            return (Data(body.utf8), HTTPURLResponse(url: r.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
    }

    @Test func bitbucketUsesClientSecretWithoutPKCE() async throws {
        let log = Log()
        let c = client(.bitbucket, secret: "shh", log: log, body: #"{"access_token":"bb","refresh_token":"br","expires_in":7200}"#)
        let url = c.authorizationURL(redirectURI: OAuthLoopback.redirectURI, state: "s", challenge: "ch")?.absoluteString ?? ""
        #expect(url.hasPrefix("https://bitbucket.org/site/oauth2/authorize?") && !url.contains("code_challenge"))
        let tokens = try await c.exchange(code: "c", verifier: "v", redirectURI: OAuthLoopback.redirectURI)
        #expect(tokens.accessToken == "bb" && tokens.clientSecret == "shh")
        let r = log.requests[0]
        #expect(r.url?.absoluteString == "https://bitbucket.org/site/oauth2/access_token")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("cid:shh".utf8).base64EncodedString())
        let body = String(decoding: r.httpBody ?? Data(), as: UTF8.self)
        #expect(!body.contains("code_verifier") && body.contains("grant_type=authorization_code"))
        let fresh = try await c.refresh(tokens)
        #expect(fresh.clientSecret == "shh")
        #expect(GitCredential.oauthUsername(kind: .bitbucket, fallback: "me") == "x-token-auth")
        #expect(ProviderKind.bitbucket.supportsOAuth(host: "bitbucket.org") && !ProviderKind.bitbucket.supportsOAuth(host: "bb.acme.com"))
    }

    @Test func azureUsesEntraPKCEWithScope() async throws {
        let log = Log()
        let c = client(.azure, log: log, body: #"{"access_token":"az","refresh_token":"zr","expires_in":3600}"#)
        let url = c.authorizationURL(redirectURI: OAuthLoopback.redirectURI, state: "s", challenge: "ch")?.absoluteString ?? ""
        #expect(url.hasPrefix("https://login.microsoftonline.com/organizations/oauth2/v2.0/authorize?"))
        #expect(url.contains("code_challenge=ch") && url.contains("user_impersonation") && url.contains("offline_access"))
        _ = try await c.exchange(code: "c", verifier: "v", redirectURI: OAuthLoopback.redirectURI)
        let body = String(decoding: log.requests[0].httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("code_verifier=v") && body.contains("scope="))
        #expect(log.requests[0].value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func bearerHeaderCredentialStaysOffTheCommandLine() {
        let c = GitCredential(host: "dev.azure.com", username: "u", token: "tok", useBearerHeader: true)
        let env = c.environment(askpassPath: "/x")
        #expect(env["GIT_CONFIG_COUNT"] == "2" && env["GIT_CONFIG_KEY_1"] == "http.extraheader")
        #expect(env["GIT_CONFIG_VALUE_1"] == "Authorization: Bearer tok")
        #expect(GitCredential(host: "h", username: "u", token: "t").environment(askpassPath: "/x")["GIT_CONFIG_COUNT"] == "1")
    }

    @Test func azureProfileVerifiesSignedInUser() async throws {
        let log = Log()
        let account = ProviderAccount(kind: .azure, host: "dev.azure.com", username: "", oauthClientID: "cid")
        let c = ProviderClient(account: account, token: "az") { r in
            log.add(r)
            return (Data(#"{"displayName":"Dee","emailAddress":"dee@acme.com"}"#.utf8), HTTPURLResponse(url: r.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(try await c.currentUser() == "dee@acme.com")
        #expect(log.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer az")
        #expect(log.requests[0].url?.host == "app.vssps.visualstudio.com")
    }
}

@Suite struct InProgressOperationTests {
    @Test func cleanRepositoryHasNoOperation() async throws {
        let t = try await TestRepo.make()
        defer { t.cleanup() }
        try await t.commit("base", text: "a\n")
        #expect(t.repo.inProgressOperation() == nil)
    }

    @Test func mergeConflictCanBeAborted() async throws {
        let t = try await TestRepo.conflicting()
        defer { t.cleanup() }
        _ = try? await t.git.run(["merge", "feature"])
        let op = try #require(t.repo.inProgressOperation())
        #expect(op.kind == .merge && !op.canSkip && op.title == "Merging")
        #expect(try await t.repo.status().conflicted.count == 1)
        try await t.repo.abortOperation(op)
        #expect(t.repo.inProgressOperation() == nil)
        #expect(try t.read() == "one\nMAIN\nthree\n")
    }

    @Test func mergeConflictCanBeContinuedAfterResolving() async throws {
        let t = try await TestRepo.conflicting()
        defer { t.cleanup() }
        _ = try? await t.git.run(["merge", "feature"])
        let op = try #require(t.repo.inProgressOperation())
        try t.write("one\nBOTH\nthree\n")
        try await t.git.run(["add", "f.txt"])
        try await t.repo.continueOperation(op)
        #expect(t.repo.inProgressOperation() == nil)
        #expect(try await t.repo.status().isClean)
    }

    @Test func rebaseConflictReportsStepAndSkips() async throws {
        let t = try await TestRepo.conflicting()
        defer { t.cleanup() }
        try await t.git.run(["switch", "feature"])
        _ = try? await t.git.run(["rebase", "main"])
        let op = try #require(t.repo.inProgressOperation())
        #expect(op.kind == .rebase && op.canSkip && op.branch == "feature")
        #expect(op.step == 1 && op.total == 1)
        try await t.repo.skipOperation(op)
        #expect(t.repo.inProgressOperation() == nil)
        #expect(try t.read() == "one\nMAIN\nthree\n")
    }

    @Test func cherryPickAndRevertConflicts() async throws {
        let t = try await TestRepo.conflicting()
        defer { t.cleanup() }
        let featureHead = try await t.git.runString(["rev-parse", "feature"]).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try? await t.git.run(["cherry-pick", featureHead])
        let pick = try #require(t.repo.inProgressOperation())
        #expect(pick.kind == .cherryPick)
        try await t.repo.abortOperation(pick)
        #expect(t.repo.inProgressOperation() == nil)

        let base = try await t.git.runString(["rev-parse", "HEAD~1"]).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try? await t.git.run(["revert", "--no-edit", base])
        let revert = t.repo.inProgressOperation()
        #expect(revert == nil || revert?.kind == .revert)
        if let revert { try await t.repo.abortOperation(revert) }
    }

    @Test func snapshotCarriesTheOperation() async throws {
        let t = try await TestRepo.conflicting()
        defer { t.cleanup() }
        _ = try? await t.git.run(["merge", "feature"])
        let snap = try await t.repo.snapshot(commitLimit: 50)
        #expect(snap.operation?.kind == .merge)
    }
}

@Suite struct ConflictResolutionTests {
    @Test func parsesBlocksAndRendersChoices() throws {
        let text = "a\n<<<<<<< HEAD\nmine\n=======\ntheirs\n>>>>>>> feature\nb\n<<<<<<< HEAD\nx\n||||||| base\nw\n=======\ny\n>>>>>>> feature\n"
        let doc = try #require(ConflictDocument.parse(text))
        #expect(doc.blocks.count == 2)
        #expect(doc.blocks[0].oursLabel == "HEAD" && doc.blocks[0].theirsLabel == "feature")
        #expect(doc.blocks[1].base == ["w"])
        #expect(doc.render([0: .ours, 1: .theirs]) == "a\nmine\nb\ny\n")
        #expect(doc.render([0: .both, 1: .bothReversed]) == "a\nmine\ntheirs\nb\ny\nx\n")
        // Unresolved blocks keep their markers (diff3 base included).
        #expect(doc.render([0: .ours]).contains("||||||| base"))
        #expect(doc.render([:]).hasPrefix("a\n<<<<<<< HEAD\nmine\n=======\ntheirs\n>>>>>>> feature\n"))
    }

    @Test func keepsLineEndingsAndMissingFinalNewline() throws {
        let text = "a\r\n<<<<<<< HEAD\r\nmine\r\n=======\r\ntheirs\r\n>>>>>>> f\r\nend"
        let doc = try #require(ConflictDocument.parse(text))
        #expect(doc.render([0: .theirs]) == "a\r\ntheirs\r\nend")
    }

    @Test func ignoresFilesWithoutCompleteBlocks() {
        #expect(ConflictDocument.parse("plain\n") == nil)
        #expect(ConflictDocument.parse("<<<<<<< HEAD\nonly start\n") == nil)
        // Markers that are not seven characters wide (e.g. Markdown rules) are ordinary text.
        #expect(ConflictDocument.parse("=======\n>>>>>>>>\n") == nil)
    }

    @Test func resolvesFileAndStagesIt() async throws {
        let t = try await TestRepo.conflicting()
        defer { t.cleanup() }
        let repo = t.repo
        _ = try? await t.git.run(["merge", "feature"])
        let stages = try await repo.conflictStages("f.txt")
        #expect(stages.hasContentConflict)
        let doc = try #require(try await repo.conflictDocument("f.txt"))
        try await repo.resolveConflict("f.txt", content: doc.render([0: .both]))
        let status = try await repo.status()
        #expect(status.conflicted.isEmpty)
        #expect(status.staged.contains { $0.path == "f.txt" })
        #expect(try t.read() == "one\nMAIN\nFEATURE\nthree\n")
        try await repo.continueOperation(try #require(repo.inProgressOperation()))
        #expect(repo.inProgressOperation() == nil)
    }

    @Test func takesOneSideOfDeleteModifyConflict() async throws {
        let t = try await TestRepo.make()
        defer { t.cleanup() }
        try await t.commit("base", file: "g.txt", text: "1\n")
        try await t.git.run(["switch", "-c", "feature"])
        try await t.git.run(["rm", "g.txt"]); try await t.git.run(["commit", "-m", "del"])
        try await t.git.run(["switch", "main"])
        try await t.commit("edit", file: "g.txt", text: "2\n")
        _ = try? await t.git.run(["merge", "feature"])
        let stages = try await t.repo.conflictStages("g.txt")
        #expect(!stages.hasContentConflict && stages.title == "Deleted by them")
        try await t.repo.resolveConflict("g.txt", taking: .delete)
        #expect(try await t.repo.status().conflicted.isEmpty)
    }
}

@Suite struct ResetAndReflogTests {
    private func history() async throws -> (TestRepo, [String]) {
        let t = try await TestRepo.make()
        var hashes: [String] = []
        for i in 1...3 { hashes.append(try await t.commit("c\(i)", text: "v\(i)\n")) }
        return (t, hashes)
    }

    @Test func softMixedHardKeepDifferInWhatTheyTouch() async throws {
        let (t, h) = try await history()
        defer { t.cleanup() }
        try await t.repo.reset(to: h[1], mode: .soft)
        var s = try await t.repo.status()
        var text = try t.read()
        #expect(s.staged.count == 1 && text == "v3\n")
        try await t.repo.reset(to: h[0], mode: .mixed)
        s = try await t.repo.status()
        text = try t.read()
        #expect(s.staged.isEmpty && s.unstaged.count == 1 && text == "v3\n")
        try await t.repo.reset(to: h[0], mode: .hard)
        s = try await t.repo.status()
        text = try t.read()
        #expect(s.isClean && text == "v1\n")
    }

    @Test func keepRefusesToOverwriteLocalEdits() async throws {
        let (t, h) = try await history()
        defer { t.cleanup() }
        try t.write("local\n")
        await #expect(throws: (any Error).self) { try await t.repo.reset(to: h[0], mode: .keep) }
        #expect(try t.read() == "local\n")
    }

    @Test func reflogListsMovesAndUndoRestoresADroppedCommit() async throws {
        let (t, h) = try await history()
        defer { t.cleanup() }
        try await t.repo.reset(to: h[0], mode: .hard)
        let log = try await t.repo.reflog()
        #expect(log.first?.hash == h[0] && log.first?.index == 0)
        #expect(log.first?.message.hasPrefix("reset") == true)
        #expect(log.first?.selector == "HEAD@{0}")
        let before = try #require(log.dropFirst().first)
        #expect(before.hash == h[2])
        try await t.repo.reset(to: before.hash, mode: .keep)
        #expect(try t.read() == "v3\n")
    }

    @Test func impactCountsDroppedCommitsAndModifiedFiles() async throws {
        let (t, h) = try await history()
        defer { t.cleanup() }
        try t.write("dirty\n")
        let impact = try await t.repo.resetImpact(to: h[0])
        #expect(impact == ResetImpact(droppedCommits: 2, modifiedFiles: 1))
    }
}

@Suite struct RebaseTests {
    private func commits(_ t: TestRepo, _ n: Int) async throws -> [String] {
        var out: [String] = []
        try await t.commit("base", file: "base.txt", text: "b\n")
        for i in 1...n { out.append(try await t.commit("c\(i)", file: "f\(i).txt", text: "\(i)\n")) }
        return out
    }
    private func subjects(_ t: TestRepo) async throws -> [String] {
        try await t.git.runString(["log", "--reverse", "--format=%s"]).split(separator: "\n").map(String.init)
    }

    @Test func candidatesListCommitsOldestFirst() async throws {
        let t = try await TestRepo.make(); defer { t.cleanup() }
        let h = try await commits(t, 3)
        let (plan, merges) = try await t.repo.rebaseCandidates(from: h[0])
        #expect(plan.items.map(\.subject) == ["c1", "c2", "c3"] && !merges)
        #expect(plan.base != nil && plan.isNoOp && plan.problem == nil)
    }

    @Test func reordersSquashesFixesUpDropsAndRewords() async throws {
        let t = try await TestRepo.make(); defer { t.cleanup() }
        let h = try await commits(t, 5)
        var (plan, _) = try await t.repo.rebaseCandidates(from: h[0])
        // c1 c2 c3 c4 c5  ->  c3 (reworded) + c2 squashed, c1 dropped, c4 fixup into c5's slot
        plan.items = [plan.items[2], plan.items[1], plan.items[0], plan.items[4], plan.items[3]]
        plan.items[0].action = .reword; plan.items[0].message = "third, renamed\n\nwith a body"
        plan.items[1].action = .squash
        plan.items[2].action = .drop
        plan.items[4].action = .fixup
        #expect(plan.problem == nil)
        try await t.repo.startInteractiveRebase(plan)
        #expect(t.repo.inProgressOperation() == nil)
        let log = try await subjects(t)
        #expect(log == ["base", "third, renamed", "c5"])
        let body = try await t.git.runString(["log", "-2", "--format=%B", "--skip=1"])
        #expect(body.contains("with a body"))
        #expect(!FileManager.default.fileExists(atPath: t.dir.appendingPathComponent(".git/gitsync-rebase").path))
        // Content of all kept commits survives; the dropped one is gone.
        #expect(FileManager.default.fileExists(atPath: t.dir.appendingPathComponent("f2.txt").path))
        #expect(!FileManager.default.fileExists(atPath: t.dir.appendingPathComponent("f1.txt").path))
    }

    @Test func rewordsMessagesWithQuotesSafely() async throws {
        let t = try await TestRepo.make(); defer { t.cleanup() }
        let h = try await commits(t, 1)
        var (plan, _) = try await t.repo.rebaseCandidates(from: h[0])
        plan.items[0].action = .reword; plan.items[0].message = "it's \"quoted\" $(echo no) `x`"
        try await t.repo.startInteractiveRebase(plan)
        #expect(try await subjects(t).last == "it's \"quoted\" $(echo no) `x`")
    }

    @Test func rejectsPlansThatCannotRun() {
        let a = RebaseItem(hash: "a", subject: "a", action: .squash)
        #expect(RebasePlan(base: "x", items: [a]).problem != nil)
        #expect(RebasePlan(base: "x", items: [RebaseItem(hash: "a", subject: "a", action: .drop)]).problem != nil)
        #expect(RebasePlan(base: "x", items: [RebaseItem(hash: "a", subject: "a", action: .reword, message: " ")]).problem != nil)
    }

    @Test func rebasesRootCommitRange() async throws {
        let t = try await TestRepo.make(); defer { t.cleanup() }
        let h = try await commits(t, 2)
        let root = try await t.git.runString(["rev-list", "--max-parents=0", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        var (plan, _) = try await t.repo.rebaseCandidates(from: root)
        #expect(plan.base == nil && plan.items.count == 3)
        plan.items[2].action = .fixup
        try await t.repo.startInteractiveRebase(plan)
        #expect(try await subjects(t) == ["base", "c1"])
        _ = h
    }

    @Test func conflictLeavesRebaseInProgressWithoutThrowing() async throws {
        let t = try await TestRepo.conflicting(); defer { t.cleanup() }
        try await t.git.run(["switch", "feature"])
        try await t.repo.rebase(onto: "main")
        let op = try #require(t.repo.inProgressOperation())
        #expect(op.kind == .rebase)
        try await t.repo.abortOperation(op)
        #expect(t.repo.inProgressOperation() == nil)
    }

    @Test func plainRebaseMakesBranchLinear() async throws {
        let t = try await TestRepo.make(); defer { t.cleanup() }
        try await t.commit("base", file: "a.txt", text: "a\n")
        try await t.git.run(["switch", "-c", "topic"])
        try await t.commit("topic", file: "t.txt", text: "t\n")
        try await t.git.run(["switch", "main"])
        try await t.commit("main", file: "m.txt", text: "m\n")
        try await t.git.run(["switch", "topic"])
        try await t.repo.rebase(onto: "main")
        #expect(try await subjects(t) == ["base", "main", "topic"])
    }

    @Test func pullWithRebaseKeepsHistoryLinear() async throws {
        let remote = try await TestRepo.make(name: "remote"); defer { remote.cleanup() }
        try await remote.commit("one", file: "a.txt", text: "1\n")
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("clone-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dest) }
        try await GitRunner(workingDirectory: FileManager.default.temporaryDirectory).run(["clone", "-q", remote.dir.path, dest.path])
        let local = GitRunner(workingDirectory: dest)
        try await local.run(["config", "user.name", "T"]); try await local.run(["config", "user.email", "t@e.c"])
        try await local.run(["config", "commit.gpgsign", "false"])
        try await remote.commit("upstream", file: "u.txt", text: "u\n")
        try "l\n".write(to: dest.appendingPathComponent("l.txt"), atomically: true, encoding: .utf8)
        try await local.run(["add", "-A"]); try await local.run(["commit", "-m", "local"])
        try await GitRepository(root: dest).pull(rebase: true)
        let log = try await local.runString(["log", "--reverse", "--format=%s"]).split(separator: "\n").map(String.init)
        #expect(log == ["one", "upstream", "local"])
        let merges = try await local.runString(["rev-list", "--merges", "--count", "HEAD"])
        #expect(merges.trimmingCharacters(in: .whitespacesAndNewlines) == "0")
    }
}

@Suite struct StashSafetyTests {
    private func twoHunks() async throws -> (TestRepo, FileDiff) {
        let t = try await TestRepo.make()
        let base = (1...30).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try await t.commit("base", text: base)
        var lines = base.split(separator: "\n").map(String.init)
        lines[1] = "TOP CHANGED"; lines[27] = "BOTTOM CHANGED"
        try t.write(lines.joined(separator: "\n") + "\n")
        let diff = try await t.repo.diff(for: DiffTarget(source: .unstaged, path: "f.txt", originalPath: nil))
        return (t, diff)
    }

    @Test func stashesOnlyTheChosenHunk() async throws {
        let (t, diff) = try await twoHunks()
        defer { t.cleanup() }
        #expect(diff.hunks.count == 2)
        let ids = diff.changedLineIDs(inHunk: 0)
        let fwd = try #require(PatchBuilder.make(diff: diff, selecting: ids, action: .stage))
        let back = try #require(PatchBuilder.make(diff: diff, selecting: ids, action: .discard))
        try await t.repo.stashHunk(forwardPatch: fwd, discardPatch: back, path: "f.txt", message: "top only")

        let now = try t.read()
        #expect(now.contains("line 2\n") && !now.contains("TOP CHANGED") && now.contains("BOTTOM CHANGED"))
        let stashes = try await t.repo.stashes()
        #expect(stashes.count == 1 && stashes[0].message.contains("top only"))
        let files = try await t.repo.stashFiles("stash@{0}")
        #expect(files.map(\.path) == ["f.txt"])
        let hash = try await t.repo.stashHash("stash@{0}")
        let stashed = try await t.repo.diff(for: DiffTarget(source: .commit(hash), path: "f.txt", originalPath: nil))
        #expect(stashed.hunks.count == 1 && stashed.additions == 1 && stashed.lines.contains { $0.raw == "TOP CHANGED" })
        #expect(!stashed.lines.contains { $0.raw == "BOTTOM CHANGED" })

        try await t.repo.stashPop("stash@{0}")
        let restored = try t.read()
        #expect(restored.contains("TOP CHANGED") && restored.contains("BOTTOM CHANGED"))
        #expect(try await t.repo.stashes().isEmpty)
    }

    @Test func refusesWhenFileHasStagedChanges() async throws {
        let (t, diff) = try await twoHunks()
        defer { t.cleanup() }
        try await t.repo.stage(["f.txt"])
        let ids = diff.changedLineIDs(inHunk: 0)
        let fwd = try #require(PatchBuilder.make(diff: diff, selecting: ids, action: .stage))
        let back = try #require(PatchBuilder.make(diff: diff, selecting: ids, action: .discard))
        await #expect(throws: (any Error).self) {
            try await t.repo.stashHunk(forwardPatch: fwd, discardPatch: back, path: "f.txt", message: "")
        }
        #expect(try await t.repo.stashes().isEmpty)
    }

    @Test func discardSummaryCountsWhatWouldBeLost() async throws {
        let (t, _) = try await twoHunks()
        defer { t.cleanup() }
        try t.write("12345", "new.txt")
        let s = try await t.repo.discardSummary(tracked: ["f.txt"], untracked: ["new.txt"])
        #expect(s.files == 1 && s.addedLines == 2 && s.removedLines == 2)
        #expect(s.untrackedFiles == 1 && s.untrackedBytes == 5)
        #expect(s.sentence.contains("2 lines added") && s.sentence.contains("1 untracked file"))
        #expect(DiscardSummary().sentence == "Nothing will change.")
    }
}

@Suite struct SigningTests {
    /// A repo configured to sign with a freshly generated SSH key.
    private func sshRepo() async throws -> TestRepo {
        let t = try await TestRepo.make()
        let key = t.dir.deletingLastPathComponent().appendingPathComponent("key-\(UUID().uuidString)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        p.arguments = ["-q", "-t", "ed25519", "-N", "", "-C", "t@example.com", "-f", key.path]
        try p.run(); p.waitUntilExit()
        let pub = try String(contentsOf: URL(fileURLWithPath: key.path + ".pub"), encoding: .utf8)
        let allowed = key.path + ".allowed"
        try ("t@example.com " + pub).write(toFile: allowed, atomically: true, encoding: .utf8)
        try await t.git.run(["config", "gpg.format", "ssh"])
        try await t.git.run(["config", "user.signingkey", key.path + ".pub"])
        try await t.git.run(["config", "gpg.ssh.allowedSignersFile", allowed])
        return t
    }

    @Test func unsignedCommitHasNoSignature() async throws {
        let t = try await TestRepo.make(); defer { t.cleanup() }
        let h = try await t.commit("plain", text: "x\n")
        #expect(try await t.repo.signature(of: h) == nil)
        let cfg = await t.repo.signingConfig()
        #expect(!cfg.signsByDefault && cfg.format == .gpg && !cfg.isConfigured)
    }

    @Test func verifiesSshSignedCommitAndOptsInPerCommit() async throws {
        let t = try await sshRepo(); defer { t.cleanup() }
        let cfg = await t.repo.signingConfig()
        #expect(cfg.format == .ssh && cfg.key != nil && cfg.isConfigured && !cfg.signsByDefault)

        try t.write("a\n"); try await t.git.run(["add", "-A"])
        try await t.repo.commit(message: "signed", amend: false, sign: true)
        let h = try await t.git.runString(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let sig = try #require(try await t.repo.signature(of: h))
        #expect(sig.format == .ssh && sig.state == .good && sig.signer == "t@example.com")
        #expect(sig.title == "Verified SSH signature")

        try t.write("b\n"); try await t.git.run(["add", "-A"])
        try await t.repo.commit(message: "unsigned", amend: false, sign: false)
        let h2 = try await t.git.runString(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(try await t.repo.signature(of: h2) == nil)
    }

    @Test func unknownSignerIsReportedAsUnverifiable() async throws {
        let t = try await sshRepo(); defer { t.cleanup() }
        try await t.git.run(["config", "--unset", "gpg.ssh.allowedSignersFile"])
        try t.write("a\n"); try await t.git.run(["add", "-A"])
        try await t.repo.commit(message: "signed", amend: false, sign: true)
        let h = try await t.git.runString(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let sig = try #require(try await t.repo.signature(of: h))
        #expect(sig.format == .ssh && sig.state == .unverifiable && !sig.state.isVerified)
    }

    @Test func defaultSigningFollowsConfig() async throws {
        let t = try await sshRepo(); defer { t.cleanup() }
        try await t.git.run(["config", "commit.gpgsign", "true"])
        #expect(await t.repo.signingConfig().signsByDefault)
        try t.write("a\n"); try await t.git.run(["add", "-A"])
        try await t.repo.commit(message: "auto", amend: false)
        let h = try await t.git.runString(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(try await t.repo.signature(of: h)?.state == .good)
    }
}

@Suite struct BlameAndFileHistoryTests {
    private func setup() async throws -> (TestRepo, String, String) {
        let t = try await TestRepo.make()
        let a = try await t.commit("first", text: "one\ntwo\nthree\n")
        try t.write("one\nTWO\nthree\nfour\n")
        try await t.git.run(["add", "-A"])
        try await t.git.run(["commit", "-m", "second edit", "--author", "Other Person <o@example.com>"])
        let b = try await t.git.runString(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (t, a, b)
    }

    @Test func blameAttributesEachLine() async throws {
        let (t, a, b) = try await setup(); defer { t.cleanup() }
        let lines = try await t.repo.blame(path: "f.txt")
        #expect(lines.map(\.text) == ["one", "TWO", "three", "four"])
        #expect(lines.map(\.hash) == [a, b, a, b])
        #expect(lines[1].author == "Other Person" && lines[0].author == "Tester")
        #expect(lines[1].summary == "second edit" && !lines[1].isUncommitted)
    }

    @Test func blameMarksUncommittedLinesAndHonoursRevision() async throws {
        let (t, a, _) = try await setup(); defer { t.cleanup() }
        try t.write("one\nTWO\nthree\nfour\nLOCAL\n")
        let now = try await t.repo.blame(path: "f.txt")
        #expect(now.last?.isUncommitted == true && now.last?.text == "LOCAL")
        let old = try await t.repo.blame(path: "f.txt", revision: a)
        #expect(old.count == 3 && Set(old.map(\.hash)) == [a])
    }

    @Test func fileHistoryFollowsRenamesAndDiffsPerCommit() async throws {
        let (t, a, b) = try await setup(); defer { t.cleanup() }
        try await t.git.run(["mv", "f.txt", "g.txt"])
        try await t.git.run(["commit", "-m", "rename"])
        let c = try await t.git.runString(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try await t.commit("other file", file: "z.txt", text: "z\n")

        let history = try await t.repo.fileHistory(path: "g.txt")
        #expect(history.map(\.hash) == [c, b, a])
        let edit = try await t.repo.fileDiff(path: "g.txt", at: b)
        #expect(edit.additions == 2 && edit.deletions == 1)
        let first = try await t.repo.fileDiff(path: "g.txt", at: a)
        #expect(first.additions == 3)
    }
}

@Suite struct CompareRefsTests {
    /// main: base, m1.  feature: base, f1, f2.
    private func diverged() async throws -> TestRepo {
        let t = try await TestRepo.make()
        try await t.commit("base", file: "a.txt", text: "a\n")
        try await t.git.run(["switch", "-c", "feature"])
        try await t.commit("f1", file: "f1.txt", text: "1\n")
        try await t.commit("f2", file: "f2.txt", text: "2\n")
        try await t.git.run(["switch", "main"])
        try await t.commit("m1", file: "m1.txt", text: "m\n")
        return t
    }

    @Test func listsFilesAndCommitsBetweenTips() async throws {
        let t = try await diverged(); defer { t.cleanup() }
        let c = try await t.repo.compare(from: "main", to: "feature", sinceAncestor: false)
        #expect(Set(c.files.map(\.path)) == ["f1.txt", "f2.txt", "m1.txt"])
        #expect(c.commits.map(\.subject) == ["f2", "f1"] && c.ahead == 2 && c.behind == 1)
    }

    @Test func sinceAncestorShowsOnlyChangesMadeOnTheBranch() async throws {
        let t = try await diverged(); defer { t.cleanup() }
        let c = try await t.repo.compare(from: "main", to: "feature", sinceAncestor: true)
        #expect(Set(c.files.map(\.path)) == ["f1.txt", "f2.txt"])
        let mergeBase = try await t.git.runString(["merge-base", "main", "feature"]).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(c.base == mergeBase)
    }

    @Test func diffsAFileBetweenTheResolvedCommits() async throws {
        let t = try await diverged(); defer { t.cleanup() }
        let c = try await t.repo.compare(from: "main", to: "feature", sinceAncestor: true)
        let d = try await t.repo.diff(for: DiffTarget(source: .compare(base: c.base, head: c.head), path: "f2.txt"))
        #expect(d.additions == 1 && d.lines.contains { $0.raw == "2" })
    }

    @Test func comparesTagsAndHashesAndRejectsUnknownRefs() async throws {
        let t = try await diverged(); defer { t.cleanup() }
        let hash = try await t.git.runString(["rev-parse", "feature~1"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try await t.git.run(["tag", "v1", "feature"])
        let c = try await t.repo.compare(from: hash, to: "v1", sinceAncestor: false)
        #expect(c.commits.map(\.subject) == ["f2"])
        await #expect(throws: (any Error).self) { try await t.repo.compare(from: "main", to: "nope", sinceAncestor: false) }
        await #expect(throws: (any Error).self) { try await t.repo.compare(from: "--all", to: "main", sinceAncestor: false) }
    }
}

@Suite struct BranchToolsTests {
    /// A clone of a bare "remote" with main pushed.
    private func cloned() async throws -> (TestRepo, GitRunner, URL) {
        let t = try await TestRepo.make()
        try await t.commit("base", file: "a.txt", text: "a\n")
        let bare = FileManager.default.temporaryDirectory.appendingPathComponent("bare-\(UUID().uuidString).git")
        try await GitRunner(workingDirectory: t.dir).run(["init", "-q", "--bare", bare.path])
        try await t.git.run(["remote", "add", "origin", bare.path])
        try await t.git.run(["push", "-q", "-u", "origin", "main"])
        return (t, GitRunner(workingDirectory: bare), bare)
    }

    @Test func renamesAndValidates() async throws {
        let t = try await TestRepo.make(); defer { t.cleanup() }
        try await t.commit("base", text: "a\n")
        try await t.git.run(["branch", "old"])
        try await t.repo.renameBranch("old", to: "new-name")
        #expect(try await t.repo.branches().local.map(\.name).contains("new-name"))
        await #expect(throws: (any Error).self) { try await t.repo.renameBranch("new-name", to: "bad name~") }
    }

    @Test func setsAndClearsUpstream() async throws {
        let (t, _, bare) = try await cloned(); defer { t.cleanup(); try? FileManager.default.removeItem(at: bare) }
        try await t.git.run(["push", "-q", "origin", "main:other"])
        try await t.git.run(["fetch", "-q"])
        try await t.repo.setUpstream(of: "main", to: "origin/other")
        #expect(try await t.repo.branches().local.first { $0.name == "main" }?.upstream == "origin/other")
        try await t.repo.setUpstream(of: "main", to: nil)
        #expect(try await t.repo.branches().local.first { $0.name == "main" }?.upstream == nil)
    }

    @Test func deletesBranchOnRemote() async throws {
        let (t, remote, bare) = try await cloned(); defer { t.cleanup(); try? FileManager.default.removeItem(at: bare) }
        try await t.git.run(["push", "-q", "origin", "main:topic"])
        #expect(try await remote.runString(["branch", "--list", "topic"]).contains("topic"))
        try await t.repo.deleteRemoteBranch(remote: "origin", branch: "topic")
        #expect(try await remote.runString(["branch", "--list", "topic"]).isEmpty)
    }

    @Test func cleanupFindsMergedAndGoneBranchesAndKeepsTheRest() async throws {
        let (t, remote, bare) = try await cloned(); defer { t.cleanup(); try? FileManager.default.removeItem(at: bare) }
        // merged: points at main already
        try await t.git.run(["branch", "merged-one"])
        // unmerged work that must NOT be listed
        try await t.git.run(["switch", "-q", "-c", "wip"]); try await t.commit("wip", file: "w.txt", text: "w\n")
        // gone: pushed, then deleted on the remote
        try await t.git.run(["switch", "-q", "-c", "shipped"]); try await t.commit("ship", file: "s.txt", text: "s\n")
        try await t.git.run(["push", "-q", "-u", "origin", "shipped"])
        try await t.git.run(["switch", "-q", "main"])
        try await remote.run(["branch", "-D", "shipped"])
        try await t.git.run(["fetch", "-q", "--prune"])

        let items = try await t.repo.cleanupCandidates(base: "main")
        #expect(Set(items.map(\.name)) == ["merged-one", "shipped"])
        let gone = try #require(items.first { $0.name == "shipped" })
        #expect(gone.reason == .upstreamGone && !gone.isMerged)
        #expect(try #require(items.first { $0.name == "merged-one" }).isMerged)

        let failed = await t.repo.deleteBranches(items)
        #expect(failed.isEmpty)
        let left = Set(try await t.repo.branches().local.map(\.name))
        #expect(left == ["main", "wip"])
    }
}

@Suite struct TagToolsTests {
    @Test func annotatedAndLightweightTags() async throws {
        let t = try await TestRepo.make()
        defer { t.cleanup() }
        let head = try await t.commit("one", file: "a.txt", text: "a")
        try await t.repo.createTag("light", at: head)
        try await t.repo.createTag("v1", at: head, message: "Release one\n\nbody")
        let tags = try await t.repo.tags()
        let light = try #require(tags.first { $0.name == "light" })
        let ann = try #require(tags.first { $0.name == "v1" })
        #expect(!light.isAnnotated)
        #expect(ann.isAnnotated)
        #expect(ann.message == "Release one")
        #expect(ann.hash == head)
        #expect(light.hash == head)
    }

    @Test func pushAndDeleteOnRemote() async throws {
        let t = try await TestRepo.make()
        defer { t.cleanup() }
        let head = try await t.commit("one", file: "a.txt", text: "a")
        let bare = FileManager.default.temporaryDirectory.appendingPathComponent("tag-remote-\(UUID().uuidString).git")
        defer { try? FileManager.default.removeItem(at: bare) }
        _ = try await GitRunner(workingDirectory: bare.deletingLastPathComponent()).run(["init", "--bare", "-q", bare.path])
        try await t.git.run(["remote", "add", "origin", bare.path])
        try await t.repo.createTag("v1", at: head, message: "m")
        try await t.repo.createTag("v2", at: head)
        try await t.repo.pushTag("v1", remote: "origin")
        var remoteTags = String(decoding: try await t.git.run(["ls-remote", "--tags", "origin"], readOnly: true), as: UTF8.self)
        #expect(remoteTags.contains("refs/tags/v1"))
        #expect(!remoteTags.contains("refs/tags/v2"))
        try await t.repo.pushAllTags(remote: "origin")
        remoteTags = String(decoding: try await t.git.run(["ls-remote", "--tags", "origin"], readOnly: true), as: UTF8.self)
        #expect(remoteTags.contains("refs/tags/v2"))
        try await t.repo.deleteRemoteTag("v1", remote: "origin")
        remoteTags = String(decoding: try await t.git.run(["ls-remote", "--tags", "origin"], readOnly: true), as: UTF8.self)
        #expect(!remoteTags.contains("refs/tags/v1"))
    }
}

@Suite struct HistorySearchTests {
    @Test func searchesByMessageAuthorContentPathAndDate() async throws {
        let t = try await TestRepo.make()
        defer { t.cleanup() }
        _ = try await t.commit("add greeting", file: "hello.txt", text: "hello world\n")
        _ = try await t.commit("tune config", file: "config.txt", text: "timeout=30\n")
        _ = try await t.commit("rename greeting", file: "hello.txt", text: "hello there\n")
        let remotes: Set<String> = []

        let message = try await t.repo.search(HistoryQuery(kind: .message, text: "GREETING"), remotes: remotes)
        #expect(message.map(\.subject) == ["rename greeting", "add greeting"])

        let pickaxe = try await t.repo.search(HistoryQuery(kind: .contentChanged, text: "timeout=30"), remotes: remotes)
        #expect(pickaxe.map(\.subject) == ["tune config"])

        let regex = try await t.repo.search(HistoryQuery(kind: .contentRegex, text: "hello (world|there)"), remotes: remotes)
        #expect(regex.count == 2)

        let byPath = try await t.repo.search(HistoryQuery(kind: .message, text: "", path: "config.txt"), remotes: remotes)
        #expect(byPath.map(\.subject) == ["tune config"])

        let future = try await t.repo.search(HistoryQuery(since: Date().addingTimeInterval(86_400 * 2)), remotes: remotes)
        #expect(future.isEmpty)
        let today = try await t.repo.search(HistoryQuery(since: Date().addingTimeInterval(-86_400), until: Date().addingTimeInterval(86_400)), remotes: remotes)
        #expect(today.count == 3)

        let byAuthor = try await t.repo.search(HistoryQuery(kind: .author, text: "nobody-like-this"), remotes: remotes)
        #expect(byAuthor.isEmpty)
    }

    @Test func optionLikeTextIsNotAnOption() async throws {
        let t = try await TestRepo.make()
        defer { t.cleanup() }
        _ = try await t.commit("one", file: "a.txt", text: "a")
        let found = try await t.repo.search(HistoryQuery(kind: .message, text: "--all"), remotes: [])
        #expect(found.isEmpty)
        let hyphen = try await t.repo.search(HistoryQuery(kind: .contentChanged, text: "-x"), remotes: [])
        #expect(hyphen.isEmpty)
    }
}
