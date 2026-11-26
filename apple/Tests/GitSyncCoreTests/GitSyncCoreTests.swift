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
