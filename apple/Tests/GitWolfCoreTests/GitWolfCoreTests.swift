import Foundation
import Testing
@testable import GitWolfCore

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
            .appendingPathComponent("gitwolf-\(UUID().uuidString)", isDirectory: true)
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
            .appendingPathComponent("gitwolf-patch-\(UUID().uuidString)", isDirectory: true)
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
        #expect(GitRepository.suggestedName(forCloneURL: "https://github.com/ipuppyyt/GitWolf.git") == "GitWolf")
        #expect(GitRepository.suggestedName(forCloneURL: "git@github.com:org/repo") == "repo")
        #expect(GitRepository.suggestedName(forCloneURL: "https://host/a/b/") == "b")
        #expect(GitRepository.suggestedName(forCloneURL: "  /tmp/local/proj.git  ") == "proj")
        #expect(GitRepository.suggestedName(forCloneURL: "") == "")
    }

    @Test func initialisesAndClonesRepository() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("gitwolf-clone-\(UUID().uuidString)")
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
        #expect(RemoteLocation.parse("https://github.com/ipuppyyt/GitWolf.git") == RemoteLocation(host: "github.com", path: "ipuppyyt/GitWolf"))
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
        #expect(env["GIT_ASKPASS"] == "/tmp/ap" && env["GITWOLF_ASKPASS_USER"] == "git" && env["GITWOLF_ASKPASS_TOKEN"] == "tok")
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
            p.environment = ["GITWOLF_ASKPASS_USER": "octo", "GITWOLF_ASKPASS_TOKEN": "s3cret"]
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
        #expect(url.contains("state=s1") && url.contains("response_type=code") && url.contains("scope=api"))
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
        #expect(!FileManager.default.fileExists(atPath: t.dir.appendingPathComponent(".git/gitwolf-rebase").path))
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

@Suite struct HookTests {
    private func installHook(_ t: TestRepo, _ name: String, _ body: String) throws {
        let url = t.dir.appendingPathComponent(".git/hooks/\(name)")
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    @Test func failingPreCommitHookSurfacesItsOutput() async throws {
        let t = try await TestRepo.make()
        defer { t.cleanup() }
        _ = try await t.commit("base", file: "a.txt", text: "a")
        try installHook(t, "pre-commit", "#!/bin/sh\necho 'lint: trailing whitespace in a.txt'\necho 'details on stderr' >&2\nexit 1\n")
        try t.write("changed", "a.txt")
        try await t.git.run(["add", "a.txt"])
        do {
            try await t.repo.commit(message: "try", amend: false)
            Issue.record("commit should have failed")
        } catch let failure as HookFailedError {
            #expect(failure.hook == "pre-commit")
            #expect(failure.output.contains("lint: trailing whitespace in a.txt"))
            #expect(failure.output.contains("details on stderr"))
        }
        try await t.repo.commit(message: "try", amend: false, skipHooks: true)
        #expect(try await t.repo.headMessage() == "try")
    }

    @Test func nonHookFailuresStayPlainErrors() async throws {
        let t = try await TestRepo.make()
        defer { t.cleanup() }
        _ = try await t.commit("base", file: "a.txt", text: "a")
        try installHook(t, "pre-commit", "#!/bin/sh\nexit 0\n")
        do {
            try await t.repo.commit(message: "nothing staged", amend: false)
            Issue.record("commit should have failed")
        } catch is HookFailedError {
            Issue.record("a clean tree is not a hook failure")
        } catch {}
        let active = await t.repo.activeHooks()
        #expect(active == ["pre-commit"])
        #expect(HookDiagnosis.diagnose(stderr: "\u{1B}[31mboom\u{1B}[0m", activeHooks: ["pre-commit"])?.output == "boom")
        #expect(HookDiagnosis.diagnose(stderr: "boom", activeHooks: []) == nil)
    }
}

@Suite struct IgnoreTests {
    @Test func optionsForNestedFile() {
        let o = IgnoreRules.options(for: "build/out/app.log")
        #expect(o.map(\.pattern) == ["/build/out/app.log", "app.log", "*.log", "/build/out/"])
        #expect(IgnoreRules.options(for: "README").map(\.pattern) == ["/README", "README"])
        #expect(IgnoreRules.options(for: "#odd[1].txt").first?.pattern == "/\\#odd\\[1\\].txt")
    }

    @Test func rulesTakeEffectAndAreNotDuplicated() async throws {
        let t = try await TestRepo.make()
        defer { t.cleanup() }
        _ = try await t.commit("base", file: "keep.txt", text: "k")
        try t.write("x", "debug.log")
        try t.write("y", "cache.tmp")
        #expect(try await t.repo.status().untracked.map(\.path).sorted() == ["cache.tmp", "debug.log"])
        #expect(try await t.repo.addIgnoreRule("*.log"))
        #expect(try await t.repo.addIgnoreRule("*.log") == false)
        #expect(try await t.repo.addIgnoreRule("cache.tmp", local: true))
        let untracked = try await t.repo.status().untracked.map(\.path)
        #expect(!untracked.contains("debug.log") && !untracked.contains("cache.tmp"))
        #expect(try t.read(".gitignore") == "*.log\n")
        let exclude = try String(contentsOf: t.dir.appendingPathComponent(".git/info/exclude"), encoding: .utf8)
        #expect(exclude.contains("cache.tmp"))
    }

    @Test func ignoredTrackedFileNeedsStopTracking() async throws {
        let t = try await TestRepo.make()
        defer { t.cleanup() }
        _ = try await t.commit("base", file: "secret.env", text: "S=1")
        try await t.repo.addIgnoreRule("secret.env")
        try t.write("S=2", "secret.env")
        #expect(try await t.repo.status().unstaged.map(\.path) == ["secret.env"])
        try await t.repo.stopTracking("secret.env")
        try await t.git.run(["add", ".gitignore"])
        let status = try await t.repo.status()
        #expect(status.unstaged.isEmpty && status.untracked.isEmpty)
        #expect(try t.read("secret.env") == "S=2")
    }
}

@Suite struct CommitMessageTests {
    @Test func prefixIsAppliedAndReplaced() {
        #expect(CommitMessage.applyPrefix(type: "feat", to: "add login") == "feat: add login")
        #expect(CommitMessage.applyPrefix(type: "fix", scope: "auth", to: "feat: add login\n\nbody") == "fix(auth): add login\n\nbody")
        #expect(CommitMessage.applyPrefix(type: "chore", to: "") == "chore: ")
        #expect(CommitMessage.stripPrefix("feat(ui)!: big change") == "big change")
        #expect(CommitMessage.stripPrefix("Fix: not conventional") == "Fix: not conventional")
        #expect(CommitMessage.stripPrefix("update: x y") == "x y")
    }

    @Test func referencesGoInAFooter() {
        var m = CommitMessage.addReference(keyword: "Closes", number: 12, to: "fix crash")
        #expect(m == "fix crash\n\nCloses #12")
        m = CommitMessage.addReference(keyword: "Refs", number: 7, to: m)
        #expect(m == "fix crash\n\nCloses #12\nRefs #7")
        #expect(CommitMessage.addReference(keyword: "Refs", number: 7, to: m) == m)
        #expect(CommitMessage.addReference(keyword: "Closes", number: 1, to: "") == "Closes #1")
    }

    @Test func scopesComeFromFolders() {
        #expect(CommitMessage.suggestedScopes(for: ["README.md", "src/a.swift", "src/b.swift", "docs/x.md", "t/1", "u/2"]) == ["src", "docs", "t"])
    }

    @Test func templateAndRecentMessages() async throws {
        let t = try await TestRepo.make()
        defer { t.cleanup() }
        _ = try await t.commit("first\n\nwith body", file: "a.txt", text: "1")
        _ = try await t.commit("second", file: "a.txt", text: "2")
        #expect(await t.repo.commitTemplate() == nil)
        try t.write("# comment\nsubject here\n\n# more\nBody:\n", ".gitmessage")
        try await t.git.run(["config", "commit.template", ".gitmessage"])
        #expect(await t.repo.commitTemplate() == "subject here\n\nBody:\n")
        #expect(await t.repo.recentMessages() == ["second", "first\n\nwith body"])
    }
}

@Suite struct CollabActionTests {
    final class Recorder: @unchecked Sendable {
        var requests: [(method: String, url: String, body: [String: Any])] = []
    }

    private func client(_ kind: ProviderKind, host: String? = nil, status: Int = 200, reply: String = "{}", _ rec: Recorder) -> ProviderClient {
        let account = ProviderAccount(kind: kind, host: host ?? kind.defaultHost, username: "me")
        return ProviderClient(account: account, token: "tok", transport: { r in
            let body = (r.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
            rec.requests.append((r.httpMethod ?? "GET", r.url!.absoluteString, body))
            return (Data(reply.utf8), HTTPURLResponse(url: r.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
    }

    @Test func githubCreateMergeCloseComment() async throws {
        let rec = Recorder()
        let pr = #"{"number":7,"title":"Add x","state":"open","user":{"login":"me"},"html_url":"https://github.com/o/r/pull/7","head":{"ref":"feat"},"base":{"ref":"main"},"draft":true}"#
        let c = client(.github, reply: pr, rec)
        let item = try await c.createPullRequest(repoPath: "o/r", title: "Add x", body: "why", head: "feat", base: "main", draft: true)
        #expect(item.number == 7 && item.isDraft && item.sourceBranch == "feat")
        #expect(rec.requests[0].method == "POST" && rec.requests[0].url == "https://api.github.com/repos/o/r/pulls")
        #expect(rec.requests[0].body["head"] as? String == "feat" && rec.requests[0].body["draft"] as? Bool == true)
        try await c.merge(repoPath: "o/r", number: 7, method: .squash)
        #expect(rec.requests[1].method == "PUT" && rec.requests[1].url.hasSuffix("/pulls/7/merge") && rec.requests[1].body["merge_method"] as? String == "squash")
        try await c.setOpen(false, kind: .pullRequest, repoPath: "o/r", number: 7)
        #expect(rec.requests[2].method == "PATCH" && rec.requests[2].body["state"] as? String == "closed")
        try await c.addComment(.issue, repoPath: "o/r", number: 3, body: "hi")
        #expect(rec.requests[3].url.hasSuffix("/issues/3/comments") && rec.requests[3].body["body"] as? String == "hi")
        try await c.setLabels(["bug"], kind: .issue, repoPath: "o/r", number: 3)
        #expect(rec.requests[4].method == "PUT" && rec.requests[4].url.hasSuffix("/issues/3/labels"))
    }

    @Test func gitlabUsesNotesAndStateEvents() async throws {
        let rec = Recorder()
        let mr = #"{"iid":4,"title":"Draft: t","state":"opened","web_url":"https://gitlab.com/g/p/-/merge_requests/4","source_branch":"a","target_branch":"main"}"#
        let c = client(.gitlab, reply: mr, rec)
        let item = try await c.createPullRequest(repoPath: "g/p", title: "t", body: "", head: "a", base: "main", draft: true)
        #expect(item.number == 4)
        #expect(rec.requests[0].url == "https://gitlab.com/api/v4/projects/g%2Fp/merge_requests")
        #expect(rec.requests[0].body["title"] as? String == "Draft: t")
        try await c.addComment(.pullRequest, repoPath: "g/p", number: 4, body: "x")
        #expect(rec.requests[1].url.hasSuffix("/merge_requests/4/notes"))
        try await c.setOpen(false, kind: .issue, repoPath: "g/p", number: 9)
        #expect(rec.requests[2].method == "PUT" && rec.requests[2].body["state_event"] as? String == "close" && rec.requests[2].url.hasSuffix("/issues/9"))
        try await c.merge(repoPath: "g/p", number: 4, method: .merge)
        #expect(rec.requests[3].body["squash"] as? Bool == false)
        await #expect(throws: ProviderError.self) { try await c.merge(repoPath: "g/p", number: 4, method: .rebase) }
    }

    @Test func bitbucketAndGiteaShapes() async throws {
        let rec = Recorder()
        let bb = client(.bitbucket, reply: #"{"id":2,"title":"t","state":"OPEN","source":{"branch":{"name":"a"}},"destination":{"branch":{"name":"main"}}}"#, rec)
        let item = try await bb.createPullRequest(repoPath: "w/r", title: "t", body: "d", head: "a", base: "main", draft: false)
        #expect(item.number == 2 && item.targetBranch == "main")
        #expect(rec.requests[0].url == "https://api.bitbucket.org/2.0/repositories/w/r/pullrequests")
        try await bb.merge(repoPath: "w/r", number: 2, method: .rebase)
        #expect(rec.requests[1].body["merge_strategy"] as? String == "fast_forward")
        try await bb.setOpen(false, kind: .pullRequest, repoPath: "w/r", number: 2)
        #expect(rec.requests[2].url.hasSuffix("/pullrequests/2/decline"))
        await #expect(throws: ProviderError.self) { try await bb.setOpen(true, kind: .pullRequest, repoPath: "w/r", number: 2) }
        await #expect(throws: ProviderError.self) { _ = try await bb.createIssue(repoPath: "w/r", title: "x", body: "") }

        let gt = client(.gitea, host: "git.corp.io", reply: #"{"number":1,"title":"t","state":"open"}"#, rec)
        try await gt.merge(repoPath: "o/r", number: 1, method: .squash)
        #expect(rec.requests.last?.method == "POST" && rec.requests.last?.body["Do"] as? String == "squash")
    }

    @Test func serverReasonIsReportedForRejectedWrites() async throws {
        let rec = Recorder()
        let c = client(.github, status: 422, reply: #"{"message":"Validation Failed","errors":[{"message":"A pull request already exists for o:feat."}]}"#, rec)
        do {
            _ = try await c.createPullRequest(repoPath: "o/r", title: "t", body: "", head: "feat", base: "main", draft: false)
            Issue.record("should fail")
        } catch let ProviderError.api(code, message) {
            #expect(code == 422 && message.contains("already exists"))
        }
    }

    @Test func parsesComments() async throws {
        let rec = Recorder()
        let gh = client(.github, reply: #"[{"id":1,"user":{"login":"ann"},"body":"first","created_at":"2026-01-02T03:04:05Z"}]"#, rec)
        let list = try await gh.comments(.issue, repoPath: "o/r", number: 1)
        #expect(list.count == 1 && list[0].author == "ann" && list[0].body == "first" && list[0].created != nil)
        let gl = client(.gitlab, reply: #"[{"id":5,"author":{"username":"bo"},"body":"real","system":false},{"id":6,"author":{"username":"bo"},"body":"added 1 commit","system":true}]"#, rec)
        #expect(try await gl.comments(.pullRequest, repoPath: "g/p", number: 1).map(\.body) == ["real"])
    }
}

@Suite struct CIStatusTests {
    private func client(_ kind: ProviderKind, replies: [String: String]) -> ProviderClient {
        ProviderClient(account: ProviderAccount(kind: kind, host: kind.defaultHost, username: "me"), token: "t", transport: { r in
            let url = r.url!.absoluteString
            let body = replies.first { url.contains($0.key) }?.value ?? "{}"
            return (Data(body.utf8), HTTPURLResponse(url: r.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
    }

    @Test func githubCombinesCheckRunsAndStatuses() async throws {
        let c = client(.github, replies: [
            "check-runs": #"{"check_runs":[{"name":"build","status":"completed","conclusion":"success","html_url":"https://x/1"},{"name":"test","status":"completed","conclusion":"failure"},{"name":"lint","status":"in_progress"},{"name":"docs","status":"completed","conclusion":"skipped"}]}"#,
            "/status": #"{"statuses":[{"context":"legacy/ci","state":"success","target_url":"https://ci"}]}"#,
        ])
        let s = try await c.ciStatus(repoPath: "o/r", sha: "abc123")
        #expect(s.checks.count == 5)
        #expect(s.overall == .failure)
        #expect(s.summary == "1 of 5 checks failed")
        #expect(s.checks.first?.name == "test")
        #expect(s.checks.first { $0.name == "build" }?.url?.absoluteString == "https://x/1")
        #expect(s.checks.first { $0.name == "docs" }?.state == .neutral)
    }

    @Test func otherProvidersMapStates() async throws {
        let gl = client(.gitlab, replies: ["statuses": #"[{"name":"unit","status":"success"},{"name":"unit","status":"failed"},{"name":"e2e","status":"running"},{"name":"x","status":"canceled"}]"#])
        let s = try await gl.ciStatus(repoPath: "g/p", sha: "deadbeef")
        // The second "unit" is a duplicate name and is dropped.
        #expect(s.checks.count == 3)
        #expect(s.overall == .pending || s.overall == .failure)
        let gt = client(.gitea, replies: ["status": #"{"statuses":[{"context":"ci","status":"pending"}]}"#])
        #expect(try await gt.ciStatus(repoPath: "o/r", sha: "abc").overall == .pending)
        let bb = client(.bitbucket, replies: ["statuses": #"{"values":[{"name":"pipe","state":"SUCCESSFUL","url":"https://bb"}]}"#])
        let st = try await bb.ciStatus(repoPath: "w/r", sha: "abc")
        #expect(st.overall == .success && st.summary == "All 1 checks passed")
        #expect(CIStatus(checks: []).overall == nil)
    }

    @Test func rejectsNonHexShas() async throws {
        let c = client(.github, replies: [:])
        #expect(try await c.ciStatus(repoPath: "o/r", sha: "../../x").isEmpty)
    }

    @Test func pullRequestsCarryTheirHeadCommit() throws {
        let gh = try ProviderClient.parseGitHubCollab(Data(#"[{"number":1,"title":"t","state":"open","head":{"ref":"a","sha":"abc"},"base":{"ref":"main"}}]"#.utf8), kind: .pullRequest)
        #expect(gh[0].headSHA == "abc")
        let gl = try ProviderClient.parseGitLabCollab(Data(#"[{"iid":2,"title":"t","state":"opened","sha":"def"}]"#.utf8), kind: .pullRequest)
        #expect(gl[0].headSHA == "def")
        let bb = try ProviderClient.parseBitbucketCollab(Data(#"{"values":[{"id":3,"title":"t","state":"OPEN","source":{"branch":{"name":"a"},"commit":{"hash":"123"}}}]}"#.utf8))
        #expect(bb[0].headSHA == "123")
    }
}

@Suite struct NotificationTests {
    @Test func githubThreadsBecomeWebLinks() throws {
        let json = #"[{"id":"42","unread":true,"reason":"review_requested","updated_at":"2026-05-01T10:00:00Z","subject":{"title":"Fix login","url":"https://api.github.com/repos/o/r/pulls/12","type":"PullRequest"},"repository":{"full_name":"o/r"}},{"id":"43","reason":"mention","subject":{"title":"Question","url":"https://api.github.com/repos/o/r/issues/7","type":"Issue"},"repository":{"full_name":"o/r"}},{"id":"44","reason":"ci_activity","subject":{"title":"Run failed","url":"https://api.github.com/repos/o/r/commits/abc123","type":"CheckSuite"},"repository":{"full_name":"o/r"}}]"#
        let list = try ProviderClient.parseGitHubNotifications(Data(json.utf8), webBase: "https://github.com")
        #expect(list.count == 3)
        #expect(list[0].reason == .reviewRequested && list[0].isPullRequest)
        #expect(list[0].url?.absoluteString == "https://github.com/o/r/pull/12")
        #expect(list[1].reason == .mention && list[1].url?.absoluteString == "https://github.com/o/r/issues/7")
        #expect(list[2].reason == .other && list[2].url?.absoluteString == "https://github.com/o/r/commit/abc123")
    }

    @Test func gitlabTodosAndGitea() throws {
        let todos = #"[{"id":9,"action_name":"review_requested","target_type":"MergeRequest","target":{"title":"Add thing"},"target_url":"https://gitlab.com/g/p/-/merge_requests/3","project":{"path_with_namespace":"g/p"}},{"id":10,"action_name":"directly_addressed","target_type":"Issue","body":"@me look","target_url":"https://gitlab.com/g/p/-/issues/4","project":{"path_with_namespace":"g/p"}}]"#
        let gl = try ProviderClient.parseGitLabTodos(Data(todos.utf8))
        #expect(gl.map(\.reason) == [.reviewRequested, .mention])
        #expect(gl[0].isPullRequest && !gl[1].isPullRequest && gl[1].title == "@me look")
        let gitea = #"[{"id":5,"unread":true,"subject":{"title":"Bug","type":"Issue","html_url":"https://git.x/o/r/issues/1"},"repository":{"full_name":"o/r"}}]"#
        let gt = try ProviderClient.parseGiteaNotifications(Data(gitea.utf8))
        #expect(gt[0].repository == "o/r" && gt[0].url?.host == "git.x")
    }

    @Test func markReadCallsTheRightEndpoints() async throws {
        final class Log: @unchecked Sendable { var calls: [String] = [] }
        let log = Log()
        func client(_ kind: ProviderKind) -> ProviderClient {
            ProviderClient(account: ProviderAccount(kind: kind, host: kind.defaultHost, username: "me"), token: "t", transport: { r in
                log.calls.append("\(r.httpMethod ?? "GET") \(r.url!.path)")
                return (Data("{}".utf8), HTTPURLResponse(url: r.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
        }
        let n = ProviderNotification(id: "7", title: "t", repository: "o/r", reason: .mention, isPullRequest: false, updated: nil, url: nil)
        try await client(.github).markRead(n)
        try await client(.gitlab).markRead(n)
        try await client(.github).markAllRead()
        #expect(log.calls == ["PATCH /notifications/threads/7", "POST /api/v4/todos/7/mark_as_done", "PUT /notifications"])
    }
}

@Suite struct ForkTests {
    @Test func forkParsesCloneURLs() async throws {
        final class Log: @unchecked Sendable { var calls: [String] = [] }
        let log = Log()
        func client(_ kind: ProviderKind, _ reply: String) -> ProviderClient {
            ProviderClient(account: ProviderAccount(kind: kind, host: kind.defaultHost, username: "me"), token: "t", transport: { r in
                log.calls.append("\(r.httpMethod ?? "GET") \(r.url!.absoluteString)")
                return (Data(reply.utf8), HTTPURLResponse(url: r.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!)
            })
        }
        let gh = try await client(.github, #"{"full_name":"me/r","clone_url":"https://github.com/me/r.git","ssh_url":"git@github.com:me/r.git"}"#).fork(repoPath: "o/r")
        #expect(gh.fullName == "me/r" && gh.sshURL == "git@github.com:me/r.git")
        let gl = try await client(.gitlab, #"{"path_with_namespace":"me/p","http_url_to_repo":"https://gitlab.com/me/p.git","ssh_url_to_repo":"git@gitlab.com:me/p.git"}"#).fork(repoPath: "g/p")
        #expect(gl.httpsURL == "https://gitlab.com/me/p.git")
        let bb = try await client(.bitbucket, #"{"full_name":"me/r","links":{"clone":[{"name":"https","href":"https://me@bitbucket.org/me/r.git"},{"name":"ssh","href":"git@bitbucket.org:me/r.git"}]}}"#).fork(repoPath: "w/r")
        #expect(bb.httpsURL == "https://bitbucket.org/me/r.git")
        #expect(log.calls == ["POST https://api.github.com/repos/o/r/forks", "POST https://gitlab.com/api/v4/projects/g%2Fp/fork",
                              "POST https://api.bitbucket.org/2.0/repositories/w/r/forks"])
        await #expect(throws: ProviderError.self) { _ = try await client(.azure, "{}").fork(repoPath: "x") }
    }

    @Test func adoptForkRewiresRemotes() async throws {
        let t = try await TestRepo.make()
        defer { t.cleanup() }
        _ = try await t.commit("one", file: "a.txt", text: "a")
        func bare(_ name: String) async throws -> URL {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).git")
            _ = try await GitRunner(workingDirectory: dir.deletingLastPathComponent()).run(["init", "--bare", "-q", dir.path])
            return dir
        }
        let original = try await bare("orig"), fork = try await bare("fork")
        defer { try? FileManager.default.removeItem(at: original); try? FileManager.default.removeItem(at: fork) }
        try await t.git.run(["remote", "add", "origin", original.path])
        try await t.git.run(["push", "-q", "origin", "HEAD:refs/heads/main"])
        try await t.git.run(["push", "-q", fork.path, "HEAD:refs/heads/main"])
        let info = RemoteRepository(fullName: "me/r", description: "", isPrivate: false, httpsURL: fork.path, sshURL: "", updated: nil)

        try await t.repo.adoptFork(info, mode: .addRemote("fork"))
        #expect(try await t.repo.remotes().sorted() == ["fork", "origin"])
        #expect(await t.repo.remoteURL("fork") == fork.path)

        try await t.git.run(["remote", "remove", "fork"])
        try await t.repo.adoptFork(info, mode: .useAsOrigin)
        #expect(await t.repo.remoteURL("origin") == fork.path)
        #expect(await t.repo.remoteURL("upstream") == original.path)
        await #expect(throws: GitError.self) { try await t.repo.adoptFork(info, mode: .useAsOrigin) }
        await #expect(throws: GitError.self) { try await t.repo.adoptFork(info, mode: .addRemote("--bad")) }
    }
}

@Suite struct SyncTests {
    private func bare() async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(UUID().uuidString).git")
        _ = try await GitRunner(workingDirectory: dir.deletingLastPathComponent()).run(["init", "--bare", "-q", "-b", "main", dir.path])
        return dir
    }

    @Test func manageRemotes() async throws {
        let t = try await TestRepo.make()
        defer { t.cleanup() }
        try await t.repo.addRemote("origin", url: "https://example.com/a.git")
        try await t.repo.addRemote("backup", url: "git@example.com:a.git")
        var list = try await t.repo.remoteInfos()
        #expect(list.map(\.name).sorted() == ["backup", "origin"])
        #expect(list.first { $0.name == "backup" }?.fetchURL == "git@example.com:a.git")
        try await t.repo.renameRemote("backup", to: "mirror")
        try await t.repo.setRemoteURL("origin", url: "https://example.com/b.git")
        list = try await t.repo.remoteInfos()
        #expect(list.map(\.name).sorted() == ["mirror", "origin"])
        #expect(list.first { $0.name == "origin" }?.fetchURL == "https://example.com/b.git")
        try await t.repo.removeRemote("mirror")
        #expect(try await t.repo.remoteInfos().count == 1)
        await #expect(throws: GitError.self) { try await t.repo.addRemote("x y", url: "https://e.com/a") }
        await #expect(throws: GitError.self) { try await t.repo.addRemote("-bad", url: "https://e.com/a") }
        await #expect(throws: GitError.self) { try await t.repo.addRemote("ok", url: "https://me:secret@e.com/a") }
        await #expect(throws: GitError.self) { try await t.repo.setRemoteURL("origin", url: "--upload-pack=evil") }
        #expect(GitRepository.redact("https://me:pw@e.com/a") == "https://me@e.com/a")
    }

    @Test func pushVariantsAndRejection() async throws {
        let t = try await TestRepo.make()
        defer { t.cleanup() }
        let remote = try await bare()
        defer { try? FileManager.default.removeItem(at: remote) }
        _ = try await t.commit("one", file: "a.txt", text: "1")
        try await t.git.run(["branch", "-M", "main"])
        try await t.git.run(["remote", "add", "origin", remote.path])
        try await t.git.run(["remote", "add", "second", remote.path])
        var status = try await t.repo.status()
        try await t.repo.push(status: status, remotes: ["origin", "second"])
        status = try await t.repo.status()
        #expect(status.upstream == "origin/main")

        // Someone else pushes first.
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("other-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: other) }
        let g = GitRunner(workingDirectory: FileManager.default.temporaryDirectory)
        _ = try await g.run(["clone", "-q", remote.path, other.path])
        let og = GitRunner(workingDirectory: other)
        _ = try await og.run(["-c", "user.name=o", "-c", "user.email=o@e.c", "commit", "-q", "--allow-empty", "-m", "theirs"])
        _ = try await og.run(["push", "-q"])

        _ = try await t.commit("two", file: "a.txt", text: "2")
        status = try await t.repo.status()
        do {
            try await t.repo.push(status: status, remotes: ["origin"])
            Issue.record("push should be rejected")
        } catch let e as GitError {
            #expect(e.isPushRejected)
        }
        // A stale lease is also refused: our remote-tracking ref doesn't know about their commit... until we fetch.
        try await t.repo.fetch()
        do {
            try await t.repo.pull(strategy: .fastForwardOnly)
            Issue.record("diverged pull should fail with ff-only")
        } catch let e as GitError {
            #expect(e.isDivergedPull)
        }
        try await t.repo.push(status: try await t.repo.status(), remotes: ["origin"], options: PushOptions(forceWithLease: true))
        let log = try await og.runString(["fetch", "-q"]) + (try await og.runString(["log", "--format=%s", "origin/main"]))
        #expect(log.contains("two") && !log.contains("theirs"))

        try await t.git.run(["tag", "v1"])
        try await t.repo.push(status: try await t.repo.status(), remotes: ["origin"], options: PushOptions(includeTags: true))
        #expect(String(decoding: try await t.git.run(["ls-remote", "--tags", "origin"], readOnly: true), as: UTF8.self).contains("v1"))

        // Publish to another remote and start tracking it.
        try await t.repo.push(status: try await t.repo.status(), remotes: ["origin"], options: PushOptions(remote: "second", setUpstream: true))
        #expect(try await t.repo.status().upstream == "second/main")
    }
}

// MARK: - Scale and power features

@Suite("Scale")
struct ScaleTests {
    @Test func bisectFindsTheBadCommit() async throws {
        let t = try await TestRepo.make()
        defer { t.cleanup() }
        var hashes: [String] = []
        for i in 1...8 { hashes.append(try await t.commit("c\(i)", file: "n.txt", text: (i >= 5 ? "bad" : "ok") + "\n\(i)\n")) }
        #expect(!t.repo.bisectState().isActive)
        var state = try await t.repo.bisectStart(bad: hashes[7], good: hashes[0])
        #expect(state.isActive)
        #expect(state.progress != nil)
        var steps = 0
        while state.firstBad == nil, steps < 10 {
            let isBad = try t.read("n.txt").hasPrefix("bad")
            state = try await t.repo.bisectMark(isBad ? .bad : .good)
            steps += 1
        }
        #expect(state.firstBad == hashes[4])
        #expect(state.marks.count >= 3)
        try await t.repo.bisectReset()
        #expect(!t.repo.bisectState().isActive)
        let branch = try await t.git.runString(["branch", "--show-current"]).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(branch == "main")
    }

    @Test func patchesRoundTrip() async throws {
        let src = try await TestRepo.make()
        let dst = try await TestRepo.make()
        defer { src.cleanup(); dst.cleanup() }
        let base = try await src.commit("base", text: "one\n")
        try await dst.git.run(["fetch", src.dir.path, "main"])
        try await dst.git.run(["reset", "--hard", base])
        let c2 = try await src.commit("second change", text: "one\ntwo\n")
        let out = src.dir.appendingPathComponent("out")
        let files = try await src.repo.formatPatches(commits: [c2], into: out)
        #expect(files.count == 1)
        #expect(files[0].lastPathComponent.hasSuffix("second-change.patch"))
        #expect(await dst.repo.checkPatch(files[0]) == nil)
        try await dst.repo.applyMailbox(files)
        #expect(try dst.read() == "one\ntwo\n")
        let log = try await dst.git.runString(["log", "-1", "--format=%s"]).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(log == "second change")

        // Plain diff apply, staged and not.
        try dst.write("one\ntwo\nthree\n")
        let diff = try await dst.repo.workingPatch(stagedOnly: false)
        let file = dst.dir.appendingPathComponent("w.diff")
        try diff.write(to: file, atomically: true, encoding: .utf8)
        try await dst.git.run(["checkout", "--", "f.txt"])
        #expect(await dst.repo.checkPatch(file) == nil)
        try await dst.repo.applyPatchFile(file, stage: true)
        #expect(try await dst.repo.status().staged.count == 1)
        // A patch that no longer applies explains why.
        try await dst.git.run(["reset", "--hard"])
        try dst.write("different\n")
        #expect(await dst.repo.checkPatch(file) != nil)
    }

    @Test func amConflictIsAnOperation() async throws {
        let a = try await TestRepo.make()
        defer { a.cleanup() }
        let base = try await a.commit("base", text: "one\n")
        let c2 = try await a.commit("change", text: "ONE\n")
        let files = try await a.repo.formatPatches(commits: [c2], into: a.dir.appendingPathComponent("p"))
        try await a.git.run(["reset", "--hard", base])
        try await a.commit("conflicting", text: "uno\n")
        _ = try? await a.repo.applyMailbox(files)
        let op = a.repo.inProgressOperation()
        #expect(op?.kind == .am)
        try await a.repo.abortOperation(try #require(op))
        #expect(a.repo.inProgressOperation() == nil)
    }

    @Test func worktrees() async throws {
        let t = try await TestRepo.make()
        defer { t.cleanup() }
        try await t.commit("base", text: "x\n")
        let path = t.dir.deletingLastPathComponent().appendingPathComponent("wt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: path) }
        try await t.repo.addWorktree(at: path, branch: "side", newBranch: true)
        var list = try await t.repo.worktrees()
        #expect(list.count == 2)
        #expect(list[0].isMain && list[0].branch == "main")
        #expect(list[1].branch == "side")
        try await t.repo.removeWorktree(list[1].path, force: false)
        list = try await t.repo.worktrees()
        #expect(list.count == 1)
    }

    @Test func submodules() async throws {
        let lib = try await TestRepo.make()
        let app = try await TestRepo.make()
        defer { lib.cleanup(); app.cleanup() }
        try await lib.commit("lib", file: "lib.txt", text: "lib\n")
        try await app.commit("app", text: "app\n")
        #expect(try await app.repo.submodules().isEmpty)
        try await app.git.run(["-c", "protocol.file.allow=always", "submodule", "add", "--", lib.dir.path, "vendor/lib"])
        var subs = try await app.repo.submodules()
        #expect(subs.count == 1)
        #expect(subs[0].path == "vendor/lib")
        #expect(subs[0].url == lib.dir.path)
        #expect(subs[0].state == .upToDate)
        try await app.git.run(["commit", "-m", "add lib"])
        // A fresh clone has it uninitialised until updated.
        let clone = FileManager.default.temporaryDirectory.appendingPathComponent("sub-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: clone) }
        try await GitRunner(workingDirectory: app.dir).run(["clone", app.dir.path, clone.path])
        let repo = GitRepository(root: clone)
        subs = try await repo.submodules()
        #expect(subs.first?.state == .notInitialized)
        try await GitRunner(workingDirectory: clone).run(["-c", "protocol.file.allow=always", "submodule", "update", "--init"])
        #expect(try await repo.submodules().first?.state == .upToDate)
        #expect(FileManager.default.fileExists(atPath: clone.appendingPathComponent("vendor/lib/lib.txt").path))
        await #expect(throws: GitError.self) { try await repo.addSubmodule(url: "--evil", path: "x") }
    }

    @Test func lfsDetection() async throws {
        let t = try await TestRepo.make()
        defer { t.cleanup() }
        try t.write("*.psd filter=lfs diff=lfs merge=lfs -text\n", ".gitattributes")
        let found = await t.repo.lfsPaths(among: ["a.psd", "b.txt", "dir/c.psd"])
        #expect(found == ["a.psd", "dir/c.psd"])
        #expect(await t.repo.lfsPaths(among: []).isEmpty)
        let pointer = "version https://git-lfs.github.com/spec/v1\noid sha256:abc123\nsize 2048\n"
        let parsed = try #require(LFSPointer.parse(pointer))
        #expect(parsed.oid == "abc123" && parsed.size == 2048)
        #expect(LFSPointer.parse("just text") == nil)
        // git-lfs may not be installed, so commit the pointer without the filter attribute active.
        try FileManager.default.removeItem(at: t.dir.appendingPathComponent(".gitattributes"))
        try await t.commit("pointer", file: "a.psd", text: pointer)
        try await t.commit("other", file: "o.txt", text: "plain\n")
        #expect(await t.repo.lfsPointer(path: "a.psd")?.size == 2048)
        #expect(await t.repo.lfsPointer(path: "o.txt") == nil)
    }

    @Test func commitGraphCache() async throws {
        let t = try await TestRepo.make()
        defer { t.cleanup() }
        for i in 1...5 { try await t.commit("c\(i)", text: "\(i)\n") }
        let before = try await t.repo.log(limit: 100, remotes: []).map(\.hash)
        #expect(!(await t.repo.hasCommitGraph()))
        try await t.repo.writeCommitGraph()
        #expect(await t.repo.hasCommitGraph())
        #expect(try await t.repo.log(limit: 100, remotes: []).map(\.hash) == before)
    }

    @Test func shallowAndFilteredClones() async throws {
        let origin = try await TestRepo.make()
        defer { origin.cleanup() }
        for i in 1...4 { try await origin.commit("c\(i)", text: "\(i)\n") }
        #expect(CloneOptions(depth: 1, filter: .blobless, singleBranch: true, branch: "main").arguments
                == ["--depth", "1", "--filter=blob:none", "--single-branch", "--branch", "main"])
        #expect(CloneOptions(branch: "--upload-pack=x").arguments.isEmpty)
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("cl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        // file:// so --depth is honoured for a local path.
        let dest = try await GitRepository.clone(url: "file://" + origin.dir.path, into: parent, name: "shallow",
                                                 options: CloneOptions(depth: 1))
        let repo = GitRepository(root: dest)
        #expect(await repo.isShallow())
        #expect(try await repo.log(limit: 100, remotes: []).count == 1)
        try await repo.unshallow()
        #expect(!(await repo.isShallow()))
        #expect(try await repo.log(limit: 100, remotes: []).count == 4)
    }
}

// MARK: - End-to-end scenarios (two people, a server, a backup remote)

@Suite("Scenarios")
struct ScenarioTests {
    struct World {
        let root: URL, alice: GitRepository, bob: GitRepository
        let aliceRunner: GitRunner, bobRunner: GitRunner, origin: URL, backup: URL
    }

    func world() async throws -> World {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("world-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let r = GitRunner(workingDirectory: root)
        for bare in ["origin.git", "backup.git"] { try await r.run(["init", "-q", "--bare", "-b", "main", bare]) }
        for who in ["alice", "bob"] {
            try await r.run(["clone", "-q", "origin.git", who])
            let g = GitRunner(workingDirectory: root.appendingPathComponent(who))
            try await g.run(["config", "user.name", who]); try await g.run(["config", "user.email", "\(who)@e.com"])
            try await g.run(["config", "commit.gpgsign", "false"])
        }
        let a = GitRunner(workingDirectory: root.appendingPathComponent("alice"))
        let b = GitRunner(workingDirectory: root.appendingPathComponent("bob"))
        try await a.run(["checkout", "-q", "-b", "main"])
        for i in 1...3 {
            try "line \(i)\n".appending(i > 1 ? "" : "").write(to: root.appendingPathComponent("alice/app\(i).txt"), atomically: true, encoding: .utf8)
            try await a.run(["add", "-A"]); try await a.run(["commit", "-qm", "base \(i)"])
        }
        try await a.run(["push", "-q", "-u", "origin", "main"])
        try await b.run(["pull", "-q", "origin", "main"])
        try await b.run(["checkout", "-q", "main"])
        return World(root: root, alice: GitRepository(root: root.appendingPathComponent("alice")),
                     bob: GitRepository(root: root.appendingPathComponent("bob")),
                     aliceRunner: a, bobRunner: b, origin: root.appendingPathComponent("origin.git"),
                     backup: root.appendingPathComponent("backup.git"))
    }

    func commit(_ g: GitRunner, _ file: String, _ text: String, _ msg: String) async throws {
        try text.write(to: g.workingDirectory.appendingPathComponent(file), atomically: true, encoding: .utf8)
        try await g.run(["add", "-A"]); try await g.run(["commit", "-qm", msg])
    }

    func status(_ repo: GitRepository) async throws -> WorkingStatus { try await repo.status() }

    @Test func divergedPullStrategies() async throws {
        let w = try await world()
        defer { try? FileManager.default.removeItem(at: w.root) }
        try await commit(w.bobRunner, "bob.txt", "b\n", "bob work")
        try await w.bobRunner.run(["push", "-q", "origin", "main"])
        try await commit(w.aliceRunner, "alice.txt", "a\n", "alice work")
        try await w.alice.fetch()
        var st = try await status(w.alice)
        #expect(st.ahead == 1 && st.behind == 1)

        // Fast-forward only refuses, and says why.
        do { try await w.alice.pull(strategy: .fastForwardOnly); Issue.record("expected failure") }
        catch let e as GitError { #expect(e.isDivergedPull) }

        // Rebase with a dirty tree: local change is kept (autostash), history stays linear.
        try "dirty\n".write(to: w.alice.root.appendingPathComponent("app1.txt"), atomically: true, encoding: .utf8)
        try await w.alice.pull(strategy: .rebase)
        st = try await status(w.alice)
        #expect(st.behind == 0 && st.ahead == 1)
        #expect(st.unstaged.count == 1)
        let merges = try await w.aliceRunner.runString(["rev-list", "--merges", "--count", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(merges == "0")
    }

    @Test func divergedPullMerge() async throws {
        let w = try await world()
        defer { try? FileManager.default.removeItem(at: w.root) }
        try await commit(w.bobRunner, "bob.txt", "b\n", "bob work")
        try await w.bobRunner.run(["push", "-q", "origin", "main"])
        try await commit(w.aliceRunner, "alice.txt", "a\n", "alice work")
        try await w.alice.pull(strategy: .merge)
        let merges = try await w.aliceRunner.runString(["rev-list", "--merges", "--count", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(merges == "1")
        #expect(try await status(w.alice).behind == 0)
    }

    @Test func rejectedPushThenPullThenPush() async throws {
        let w = try await world()
        defer { try? FileManager.default.removeItem(at: w.root) }
        try await commit(w.bobRunner, "bob.txt", "b\n", "bob work")
        try await w.bobRunner.run(["push", "-q", "origin", "main"])
        try await commit(w.aliceRunner, "alice.txt", "a\n", "alice work")
        var st = try await status(w.alice)
        let remotes = try await w.alice.remotes()
        do { try await w.alice.push(status: st, remotes: remotes); Issue.record("expected rejection") }
        catch let e as GitError { #expect(e.isPushRejected) }
        // A lease push right after is rejected too (alice hasn't fetched bob's commit).
        do { try await w.alice.push(status: st, remotes: remotes, options: PushOptions(forceWithLease: true)); Issue.record("lease should refuse") }
        catch let e as GitError { #expect(e.isPushRejected) }
        try await w.alice.pull(strategy: .rebase)
        st = try await status(w.alice)
        try await w.alice.push(status: st, remotes: remotes)
        #expect(try await status(w.alice).ahead == 0)
    }

    @Test func forcePushAfterRewrite() async throws {
        let w = try await world()
        defer { try? FileManager.default.removeItem(at: w.root) }
        try await w.aliceRunner.run(["commit", "--amend", "-qm", "rewritten base 3"])
        let st = try await status(w.alice)
        let remotes = try await w.alice.remotes()
        do { try await w.alice.push(status: st, remotes: remotes); Issue.record("plain push must be rejected") }
        catch let e as GitError { #expect(e.isPushRejected) }
        try await w.alice.push(status: st, remotes: remotes, options: PushOptions(forceWithLease: true))
        let remoteHead = try await GitRunner(workingDirectory: w.origin).runString(["log", "-1", "--format=%s", "main"]).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(remoteHead == "rewritten base 3")
    }

    @Test func tagsAndSecondRemote() async throws {
        let w = try await world()
        defer { try? FileManager.default.removeItem(at: w.root) }
        try await w.alice.addRemote("backup", url: w.backup.path)
        #expect(Set(try await w.alice.remoteInfos().map(\.name)) == ["origin", "backup"])
        try await w.aliceRunner.run(["tag", "v1.0"])
        let st = try await status(w.alice)
        let remotes = try await w.alice.remotes()
        try await w.alice.push(status: st, remotes: remotes, options: PushOptions(remote: "backup", includeTags: true))
        let tags = try await GitRunner(workingDirectory: w.backup).runString(["tag"]).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(tags == "v1.0")
        try await w.alice.setRemoteURL("backup", url: w.origin.path)
        #expect(try await w.alice.remoteInfos().first { $0.name == "backup" }?.fetchURL == w.origin.path)
        try await w.alice.renameRemote("backup", to: "mirror")
        try await w.alice.removeRemote("mirror")
        #expect(try await w.alice.remoteInfos().map(\.name) == ["origin"])
        await #expect(throws: GitError.self) { try await w.alice.addRemote("x", url: "https://u:secret@host/x.git") }
    }

    @Test func bisectWithSkipAndExplicitHash() async throws {
        let t = try await TestRepo.make()
        defer { t.cleanup() }
        var h: [String] = []
        for i in 1...10 { h.append(try await t.commit("c\(i)", file: "n.txt", text: (i >= 7 ? "bad" : "ok") + "\n\(i)\n")) }
        var s = try await t.repo.bisectStart(bad: h[9], good: h[0])
        s = try await t.repo.bisectMark(.skip)           // can't test this one
        #expect(s.marks.last?.mark == .skip)
        s = try await t.repo.bisectMark(.good, hash: h[5])  // mark an explicit commit
        #expect(s.marks.contains { $0.hash == h[5] && $0.mark == .good })
        var guardCount = 0
        while s.firstBad == nil, guardCount < 10 {
            s = try await t.repo.bisectMark(try t.read("n.txt").hasPrefix("bad") ? .bad : .good); guardCount += 1
        }
        #expect(s.firstBad == h[6])
        try await t.repo.bisectReset()
    }

    @Test func patchSeriesBetweenPeople() async throws {
        let w = try await world()
        defer { try? FileManager.default.removeItem(at: w.root) }
        try await commit(w.bobRunner, "one.txt", "1\n", "feature part 1")
        try await commit(w.bobRunner, "two.txt", "2\n", "feature part 2")
        let hashes = try await w.bobRunner.runString(["rev-list", "--reverse", "-2", "HEAD"]).split(separator: "\n").map(String.init)
        let out = w.root.appendingPathComponent("patches")
        let files = try await w.bob.formatPatches(commits: hashes, into: out)
        #expect(files.count == 2)
        #expect(files[0].lastPathComponent.hasPrefix("0001-") && files[1].lastPathComponent.hasPrefix("0002-"))
        try await w.alice.applyMailbox(files)
        let log = try await w.aliceRunner.runString(["log", "-2", "--format=%an: %s"]).split(separator: "\n").map(String.init)
        #expect(log == ["bob: feature part 2", "bob: feature part 1"])
    }

    @Test func worktreeWithDirtyChangesRefusesRemoval() async throws {
        let w = try await world()
        defer { try? FileManager.default.removeItem(at: w.root) }
        let path = w.root.appendingPathComponent("alice-wt")
        try await w.alice.addWorktree(at: path, branch: "topic", newBranch: true)
        try "dirty\n".write(to: path.appendingPathComponent("app1.txt"), atomically: true, encoding: .utf8)
        await #expect(throws: GitError.self) { try await w.alice.removeWorktree(path.path, force: false) }
        #expect(try await w.alice.worktrees().count == 2)
        try FileManager.default.removeItem(at: path)         // folder deleted behind git's back
        #expect(try await w.alice.worktrees().last?.isPrunable == true)
        try await w.alice.pruneWorktrees()
        #expect(try await w.alice.worktrees().count == 1)
    }
}

@Suite("FileIcons")
struct FileIconTests {
    @Test func mapsByExtensionAndName() {
        #expect(FileIcons.icon(forPath: "src/App.tsx").glyph == .react)
        #expect(FileIcons.icon(forPath: "a/b/Button.JSX").glyph == .react)
        #expect(FileIcons.icon(forPath: "x.ts").glyph == .letters("TS"))
        #expect(FileIcons.icon(forPath: "types/index.d.ts").name == "TypeScript declarations")
        #expect(FileIcons.icon(forPath: "main.swift").glyph == .symbol("swift"))
        #expect(FileIcons.icon(forPath: "package.json").name == "npm")
        #expect(FileIcons.icon(forPath: "data.json").glyph == .letters("{}"))
        #expect(FileIcons.icon(forPath: "Dockerfile").name == "Docker")
        #expect(FileIcons.icon(forPath: "Dockerfile.dev").name == "Docker")
        #expect(FileIcons.icon(forPath: ".env.local").name == "Environment")
        #expect(FileIcons.icon(forPath: "LICENSE").name == "License")
        #expect(FileIcons.icon(forPath: "docs/README.md").name == "Readme")
        #expect(FileIcons.icon(forPath: "vendor/app.min.js").name == "Minified")
        #expect(FileIcons.icon(forPath: "logo.PNG").name == "Image")
        #expect(FileIcons.icon(forPath: "weird.zzz").name == "File")
        #expect(FileIcons.icon(forPath: "noextension").name == "File")
        #expect(FileIcons.icon(forPath: ".gitignore").name == "Git")
    }

    @Test func branchesByName() {
        #expect(FileIcons.branchIcon(named: "main").name == "Main branch")
        #expect(FileIcons.branchIcon(named: "Master").name == "Main branch")
        #expect(FileIcons.branchIcon(named: "develop").name == "Development")
        #expect(FileIcons.branchIcon(named: "feature/login-form").name == "Feature")
        #expect(FileIcons.branchIcon(named: "feat-login").name == "Feature")
        #expect(FileIcons.branchIcon(named: "fix/crash-on-start").name == "Bug fix")
        #expect(FileIcons.branchIcon(named: "hotfix/1.2.1").name == "Hotfix")
        #expect(FileIcons.branchIcon(named: "release/2.0").name == "Release")
        #expect(FileIcons.branchIcon(named: "dependabot/npm_and_yarn/x").name == "Dependencies")
        #expect(FileIcons.branchIcon(named: "123-fix-login").name == "Issue")
        #expect(FileIcons.branchIcon(named: "dhanush/experiment").name == "Branch")
        #expect(FileIcons.branchIcon(named: "some-random").name == "Branch")
        #expect(FileIcons.branchIcon(named: "").name == "Branch")
    }

    @Test func tagsByName() {
        #expect(FileIcons.tagIcon(named: "v2.0.0").name == "Major release")
        #expect(FileIcons.tagIcon(named: "1.0").name == "Major release")
        #expect(FileIcons.tagIcon(named: "v1.4.2").name == "Release")
        #expect(FileIcons.tagIcon(named: "v0.3.0").name == "Release")
        #expect(FileIcons.tagIcon(named: "v1.5.0-rc.1").name == "Release candidate")
        #expect(FileIcons.tagIcon(named: "v1.5.0-beta.2").name == "Pre-release")
        #expect(FileIcons.tagIcon(named: "v3.0.0-alpha").name == "Pre-release")
        #expect(FileIcons.tagIcon(named: "nightly-2026-11-27").name == "Nightly")
        #expect(FileIcons.tagIcon(named: "latest").name == "Latest")
        #expect(FileIcons.tagIcon(named: "release-lts").name == "Long-term support")
        #expect(FileIcons.tagIcon(named: "deploy-prod-42").name == "Deploy")
        #expect(FileIcons.tagIcon(named: "old-backup").name == "Archive")
        #expect(FileIcons.tagIcon(named: "milestone").name == "Tag")
        #expect(FileIcons.tagIcon(named: "milestone", isAnnotated: false).glyph == .symbol("tag"))
        #expect(FileIcons.tagIcon(named: "").name == "Tag")
    }

    @Test func foldersByName() {
        #expect(FileIcons.folderIcon(named: "src").name == "Source")
        #expect(FileIcons.folderIcon(named: "Docs").name == "Docs")
        #expect(FileIcons.folderIcon(named: "node_modules").name == "Dependencies")
        #expect(FileIcons.folderIcon(named: ".github").name == "CI")
        #expect(FileIcons.folderIcon(named: "randomthing").glyph == .folder(nil))
        #expect(FileIcons.folderIcon(containing: "src/components/Button.tsx")?.name == "Components")
        #expect(FileIcons.folderIcon(containing: "README.md") == nil)
        #expect(FileIcons.folderIcon(containing: "node_modules/react/lib/x.js")?.name == "Library")
        #expect(FileIcons.folderIcon(containing: "node_modules/react/x.js")?.name == "Dependencies")
        #expect(FileIcons.folderIcon(containing: ".github/workflows/ci.yml")?.name == "CI")
        #expect(FileIcons.folderIcon(containing: "src/random/x.ts")?.name == "Folder")
    }

    @Test func everyIconHasAFlatBrandColour() {
        for icon in Array(FileIcons.extensions.values) + Array(FileIcons.names.values) + Array(FileIcons.folders.values) {
            #expect(icon.color <= 0xFFFFFF)
        }
    }
}

@Suite("Avatars")
struct AvatarTests {
    @Test func noreplyAddresses() {
        #expect(AvatarURLs.fromNoreply(email: "12345+octo-cat@users.noreply.github.com")?.absoluteString
                == "https://avatars.githubusercontent.com/u/12345?s=96")
        #expect(AvatarURLs.fromNoreply(email: "octocat@users.noreply.github.com")?.absoluteString
                == "https://github.com/octocat.png?size=96")
        #expect(AvatarURLs.fromNoreply(email: "42-jane@users.noreply.gitlab.com")?.absoluteString
                == "https://gitlab.com/uploads/-/system/user/avatar/42/avatar.png?width=96")
        #expect(AvatarURLs.fromNoreply(email: "someone@example.com") == nil)
        // Nothing smuggled into the path.
        #expect(AvatarURLs.fromNoreply(email: "../evil@users.noreply.github.com") == nil)
        #expect(AvatarURLs.fromNoreply(email: "") == nil)
    }

    @Test func onlyWebAddresses() {
        #expect(AvatarURLs.safe("https://avatars.githubusercontent.com/u/1?v=4") != nil)
        #expect(AvatarURLs.safe("file:///etc/passwd") == nil)
        #expect(AvatarURLs.safe("javascript:alert(1)") == nil)
        #expect(AvatarURLs.safe(nil) == nil)
        #expect(AvatarURLs.safe("") == nil)
    }

    @Test func providerResponses() async throws {
        let gh = Data(#"[{"sha":"a","author":{"login":"o","avatar_url":"https://avatars.githubusercontent.com/u/9?v=4"}}]"#.utf8)
        #expect(try ProviderClient.parseCommitListAvatar(gh)?.absoluteString == "https://avatars.githubusercontent.com/u/9?v=4")
        #expect(try ProviderClient.parseCommitListAvatar(Data(#"[{"sha":"a","author":null}]"#.utf8)) == nil)
        #expect(try ProviderClient.parseCommitListAvatar(Data("[]".utf8)) == nil)
        #expect(try ProviderClient.parseGitLabAvatar(Data(#"{"avatar_url":"https://gitlab.com/a.png"}"#.utf8))?.host == "gitlab.com")
        let bb = Data(#"{"author":{"user":{"links":{"avatar":{"href":"https://bitbucket.org/a.png"}}}}}"#.utf8)
        #expect(try ProviderClient.parseBitbucketCommitAvatar(bb)?.host == "bitbucket.org")
        #expect(throws: ProviderError.self) { try ProviderClient.parseGitLabAvatar(Data("[]".utf8)) }
    }

    @Test func requestsGoToThePlatformOnly() async throws {
        final class Seen: @unchecked Sendable { var urls: [String] = []; let lock = NSLock()
            func add(_ s: String) { lock.lock(); urls.append(s); lock.unlock() } }
        let seen = Seen()
        func client(_ kind: ProviderKind, host: String) -> ProviderClient {
            ProviderClient(account: ProviderAccount(kind: kind, host: host, username: "u"), token: "t") { request in
                seen.add(request.url!.absoluteString)
                let body: String = switch kind {
                case .gitlab: #"{"avatar_url":"https://gitlab.com/a.png"}"#
                case .bitbucket: #"{"author":{"user":{"links":{"avatar":{"href":"https://x/a.png"}}}}}"#
                default: #"[{"author":{"avatar_url":"https://x/a.png"}}]"#
                }
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let sha = String(repeating: "a", count: 40)
        #expect(try await client(.github, host: "github.com").commitAuthorAvatar(repoPath: "o/r", sha: sha, email: "e@x.com") != nil)
        #expect(try await client(.gitlab, host: "gitlab.com").commitAuthorAvatar(repoPath: "o/r", sha: sha, email: "e+tag@x.com") != nil)
        #expect(try await client(.gitea, host: "codeberg.org").commitAuthorAvatar(repoPath: "o/r", sha: sha, email: "e@x.com") != nil)
        #expect(try await client(.bitbucket, host: "bitbucket.org").commitAuthorAvatar(repoPath: "o/r", sha: sha, email: "e@x.com") != nil)
        #expect(try await client(.azure, host: "dev.azure.com").commitAuthorAvatar(repoPath: "o/r", sha: sha, email: "e@x.com") == nil)
        // A malformed "sha" is never sent anywhere.
        #expect(try await client(.github, host: "github.com").commitAuthorAvatar(repoPath: "o/r", sha: "../x", email: "e@x.com") == nil)
        #expect(seen.urls.count == 4)
        #expect(seen.urls[0].hasPrefix("https://api.github.com/repos/o/r/commits?sha="))
        #expect(seen.urls[1] == "https://gitlab.com/api/v4/avatar?email=e%2Btag%40x.com&size=96")
        #expect(seen.urls.allSatisfy { !$0.contains("gravatar") })
    }
}

@Suite struct BadgeTests {
    @Test func badgeText() {
        #expect(BadgeLabel.text(forChanges: 0) == nil)
        #expect(BadgeLabel.text(forChanges: 7) == "7")
        #expect(BadgeLabel.text(forChanges: 99) == "99")
        #expect(BadgeLabel.text(forChanges: 100) == "99+")
    }
}

@Suite struct HomeLayoutTests {
    @Test func pinAndGroups() throws {
        var layout = HomeLayout()
        layout.togglePin("/a"); layout.togglePin("/b")
        #expect(layout.pinned == ["/a", "/b"])
        layout.togglePin("/a")
        #expect(layout.pinned == ["/b"])

        #expect(layout.addGroup(named: "   ") == nil)
        let created = layout.addGroup(named: " Work ")
        let work = try #require(created)
        #expect(layout.groups.first?.name == "Work")
        layout.toggle("/b", inGroup: work); layout.toggle("/c", inGroup: work)
        #expect(layout.groupIDs(containing: "/b") == [work])
        layout.toggle("/c", inGroup: work)
        #expect(layout.groups[0].paths == ["/b"])
        layout.renameGroup(work, to: "Day job")
        #expect(layout.groups[0].name == "Day job")

        layout.remove("/b")
        #expect(layout.pinned.isEmpty && layout.groups[0].paths.isEmpty)
        layout.deleteGroup(work)
        #expect(layout.groups.isEmpty)
    }

    @Test func codableAndPrune() throws {
        var layout = HomeLayout()
        layout.togglePin("/keep"); layout.togglePin("/gone")
        let created = layout.addGroup(named: "G", paths: ["/keep", "/gone"])
        let id = try #require(created)
        let decoded = try JSONDecoder().decode(HomeLayout.self, from: JSONEncoder().encode(layout))
        #expect(decoded == layout)
        let pruned = decoded.pruned { $0 == "/keep" }
        #expect(pruned.pinned == ["/keep"])
        #expect(pruned.groups.first { $0.id == id }?.paths == ["/keep"])
    }
}

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gs-act-\(UUID().uuidString)").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite struct CustomActionTests {
    @Test func runsAtRepoRootWithEnvironment() async throws {
        let dir = try makeTempDir()
        let action = CustomAction(name: "Show", command: "pwd; echo \"branch=$GITWOLF_BRANCH\"; echo \"repo=$GITWOLF_REPO\"")
        let result = await CustomActionRunner.run(action, root: dir, branch: "feature/x y")
        #expect(result.succeeded)
        #expect(result.output.contains("branch=feature/x y"))
        #expect(result.output.contains("repo=\(dir.path)"))
    }

    @Test func reportsFailure() async throws {
        let dir = try makeTempDir()
        let result = await CustomActionRunner.run(CustomAction(name: "Fail", command: "echo oops >&2; exit 3"), root: dir, branch: nil)
        #expect(result.exitCode == 3)
        #expect(result.output.contains("oops"))
    }

    @Test func validation() {
        #expect(!CustomAction(name: " ", command: "ls").isValid)
        #expect(!CustomAction(name: "x", command: "").isValid)
        #expect(CustomAction(name: "x", command: "ls").isValid)
    }
}

@Suite struct DiffImprovementTests {
    private func makeRepo() async throws -> (GitRepository, GitRunner, URL) {
        let dir = try makeTempDir()
        let runner = GitRunner(workingDirectory: dir)
        try await runner.run(["init", "-b", "main"])
        try await runner.run(["config", "user.name", "Tester"])
        try await runner.run(["config", "user.email", "t@example.com"])
        return (GitRepository(root: dir), runner, dir)
    }

    @Test func wordLevelChanges() {
        let c = InlineDiff.changes(old: "let total = price * qty", new: "let total = price * quantity")
        #expect(c.old == [20..<23])
        #expect(c.new == [20..<28])
        // Unrelated lines get no inline highlight.
        let none = InlineDiff.changes(old: "alpha beta gamma", new: "one two three four")
        #expect(none.old.isEmpty && none.new.isEmpty)
        // Identical lines have nothing to highlight.
        #expect(InlineDiff.changes(old: "same", new: "same").old.isEmpty)
    }

    @Test func inlineRangesPairDeletionsWithAdditions() async throws {
        let (repo, _, dir) = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "a\nvalue = 1\nb\n".write(to: dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try await repo.stage(["f.txt"]); try await repo.commit(message: "base", amend: false)
        try "a\nvalue = 2\nb\n".write(to: dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let diff = try await repo.diff(for: DiffTarget(source: .unstaged, path: "f.txt"))
        let ranges = diff.inlineRanges()
        let del = try #require(diff.lines.first { $0.kind == .deletion })
        let add = try #require(diff.lines.first { $0.kind == .addition })
        #expect(ranges[del.id] == [8..<9])
        #expect(ranges[add.id] == [8..<9])
    }

    @Test func ignoreWhitespaceAndFullFile() async throws {
        var (repo, _, dir) = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let base = (1...30).map { "line \($0)" }
        try (base.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try await repo.stage(["f.txt"]); try await repo.commit(message: "base", amend: false)
        var edited = base
        edited[14] = "line   15"          // whitespace only
        edited[2] = "line 3 CHANGED"
        try (edited.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)

        let normal = try await repo.diff(for: DiffTarget(source: .unstaged, path: "f.txt"))
        #expect(normal.additions == 2 && normal.canPatch)

        repo.ignoreWhitespace = true
        let ignoring = try await repo.diff(for: DiffTarget(source: .unstaged, path: "f.txt"))
        #expect(ignoring.additions == 1)
        #expect(!ignoring.canPatch)
        repo.ignoreWhitespace = false

        repo.fullFileDiffs = true
        let full = try await repo.diff(for: DiffTarget(source: .unstaged, path: "f.txt"))
        #expect(full.hunks.count == 1)
        #expect(full.lines.filter { $0.kind == .context }.count == 28)
        // Long unchanged stretches can be folded, keeping 3 lines beside each change.
        let runs = full.collapsibleRuns()
        #expect(!runs.isEmpty)
        for run in runs { #expect(full.lines[run].allSatisfy { $0.kind == .context }) }
    }

    @Test func collapsibleRunsRespectsEdges() {
        func line(_ id: Int, _ kind: DiffLine.Kind) -> DiffLine {
            DiffLine(id: id, kind: kind, hunkIndex: 0, oldNumber: id, newNumber: id, text: "x", raw: " x")
        }
        var diff = FileDiff.empty
        diff.lines = [line(0, .addition)] + (1...20).map { line($0, .context) } + [line(21, .deletion)]
        #expect(diff.collapsibleRuns() == [4..<18])
        diff.lines = (0..<5).map { line($0, .context) }
        #expect(diff.collapsibleRuns().isEmpty)
    }

    @Test func imageVersionsReadBothSides() async throws {
        let (repo, runner, dir) = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("pic.png")
        try Data([1, 2, 3]).write(to: file)
        try await repo.stage(["pic.png"]); try await repo.commit(message: "add", amend: false)
        try Data([4, 5, 6, 7]).write(to: file)

        let unstaged = await repo.imageVersions(for: DiffTarget(source: .unstaged, path: "pic.png"))
        #expect(unstaged.old == Data([1, 2, 3]) && unstaged.new == Data([4, 5, 6, 7]))
        try await repo.stage(["pic.png"])
        let staged = await repo.imageVersions(for: DiffTarget(source: .staged, path: "pic.png"))
        #expect(staged.old == Data([1, 2, 3]) && staged.new == Data([4, 5, 6, 7]))
        try await repo.commit(message: "edit", amend: false)
        let hash = try await runner.runString(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let commit = await repo.imageVersions(for: DiffTarget(source: .commit(hash), path: "pic.png"))
        #expect(commit.old == Data([1, 2, 3]) && commit.new == Data([4, 5, 6, 7]))
        // The first commit has no parent version.
        let first = try await runner.runString(["rev-list", "--max-parents=0", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let added = await repo.imageVersions(for: DiffTarget(source: .commit(first), path: "pic.png"))
        #expect(added.old == nil && added.new == Data([1, 2, 3]))
        #expect(GitRepository.isImagePath("a/B.PNG") && !GitRepository.isImagePath("a.svg"))
    }
}

@Suite struct AppVersionTests {
    @Test func versionOrdering() throws {
        let v = { try #require(AppVersion($0)) }
        #expect(try v("1.10.0") > v("1.9.9"))
        #expect(try v("v2.0") == v("2.0.0"))
        #expect(try v("2.0.0-beta.2") < v("2.0.0"))
        #expect(try v("2.0.0-beta.2") < v("2.0.0-beta.10"))
        #expect(AppVersion("dev") == nil)
    }
}

@Suite struct RepoIconTests {
    @Test func setReplaceAndClear() {
        var icons = RepoIcons()
        #expect(icons.set(.symbol("star"), for: "/a") == nil)
        #expect(icons.icon(for: "/a") == .symbol("star"))
        #expect(icons.set(.image("one.png"), for: "/a") == nil)
        // Replacing an image reports the file that is now unused.
        #expect(icons.set(.symbol("flame"), for: "/a") == "one.png")
        #expect(icons.set(.image("two.png"), for: "/b") == nil)
        #expect(icons.set(nil, for: "/b") == "two.png")
        #expect(icons.icon(for: "/b") == nil)
    }

    @Test func settingTheSameImageKeepsItsFile() {
        var icons = RepoIcons()
        icons.set(.image("x.png"), for: "/a")
        #expect(icons.set(.image("x.png"), for: "/a") == nil)
    }

    @Test func prunesMissingRepositories() {
        var icons = RepoIcons()
        icons.set(.image("gone.png"), for: "/gone")
        icons.set(.symbol("star"), for: "/kept")
        let unused = icons.pruned { $0 == "/kept" }
        #expect(unused == ["gone.png"])
        #expect(icons.icon(for: "/gone") == nil)
        #expect(icons.icon(for: "/kept") == .symbol("star"))
    }

    @Test func roundTripsThroughJSON() throws {
        var icons = RepoIcons()
        icons.set(.symbol("bolt"), for: "/a")
        icons.set(.image("p.png"), for: "/b")
        let back = try JSONDecoder().decode(RepoIcons.self, from: JSONEncoder().encode(icons))
        #expect(back == icons)
    }
}


@Suite struct CIActionTests {
    private func client(_ kind: ProviderKind, log: @escaping @Sendable (String) -> Void) -> ProviderClient {
        ProviderClient(account: ProviderAccount(kind: kind, host: kind.defaultHost, username: "me"), token: "t", transport: { r in
            log("\(r.httpMethod ?? "GET") \(r.url!.absoluteString)")
            return (Data("{}".utf8), HTTPURLResponse(url: r.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        })
    }

    @Test func githubRunAndJobIDsComeFromTheCheckLink() throws {
        let json = #"{"check_runs":[{"name":"macos","status":"in_progress","html_url":"https://github.com/o/r/actions/runs/123/job/456"}]}"#
        let checks = try ProviderClient.parseGitHubCheckRuns(Data(json.utf8))
        #expect(checks[0].runID == "123" && checks[0].jobID == "456")
    }

    @Test func aRefusedRerunReportsTheServersReason() async throws {
        let body = #"{"message":"Resource not accessible by personal access token"}"#
        let gh = ProviderClient(account: ProviderAccount(kind: .github, host: "github.com", username: "me"), token: "t", transport: { r in
            (Data(body.utf8), HTTPURLResponse(url: r.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
        })
        let check = CICheck(name: "a", state: .failure, url: nil, runID: "1", jobID: "2")
        do { try await gh.perform(.rerun, on: check, repoPath: "o/r"); Issue.record("should have thrown") }
        catch let ProviderError.forbidden(code, message) {
            #expect(code == 403 && message == "Resource not accessible by personal access token")
        }
    }

    @Test func rerunAndCancelHitTheRightEndpoints() async throws {
        final class Log: @unchecked Sendable { var calls: [String] = [] }
        let log = Log()
        let gh = client(.github) { log.calls.append($0) }
        let gl = client(.gitlab) { log.calls.append($0) }
        let done = CICheck(name: "a", state: .failure, url: nil, runID: "1", jobID: "2")
        let running = CICheck(name: "b", state: .pending, url: nil, runID: "1", jobID: "2")
        try await gh.perform(.rerun, on: done, repoPath: "o/r")
        try await gh.perform(.cancel, on: running, repoPath: "o/r")
        try await gl.perform(.rerun, on: done, repoPath: "g/p")
        try await gl.perform(.cancel, on: running, repoPath: "g/p")
        #expect(log.calls == ["POST https://api.github.com/repos/o/r/actions/jobs/2/rerun",
                              "POST https://api.github.com/repos/o/r/actions/runs/1/cancel",
                              "POST https://gitlab.com/api/v4/projects/g%2Fp/jobs/2/retry",
                              "POST https://gitlab.com/api/v4/projects/g%2Fp/jobs/2/cancel"])
    }

    @Test func onlyMatchingStatesOfferAnAction() {
        let gh = client(.github) { _ in }
        let running = CICheck(name: "b", state: .pending, url: nil, runID: "1", jobID: "2")
        let done = CICheck(name: "a", state: .success, url: nil, runID: "1", jobID: "2")
        #expect(gh.canPerform(.cancel, on: running) && !gh.canPerform(.rerun, on: running))
        #expect(gh.canPerform(.rerun, on: done) && !gh.canPerform(.cancel, on: done))
        #expect(!client(.gitea) { _ in }.canPerform(.rerun, on: done))
        #expect(!gh.canPerform(.rerun, on: CICheck(name: "old", state: .failure, url: nil)))
    }
}


@Suite struct RepoTintTests {
    @Test func tintsRoundTripAndPrune() throws {
        var icons = RepoIcons()
        icons.setTint(.teal, for: "/a")
        icons.setTint(.pink, for: "/b")
        icons.setTint(nil, for: "/b")
        #expect(icons.tint(for: "/a") == .teal && icons.tint(for: "/b") == nil)
        let back = try JSONDecoder().decode(RepoIcons.self, from: JSONEncoder().encode(icons))
        #expect(back == icons)
        _ = icons.pruned(keeping: { _ in false })
        #expect(icons.tint(for: "/a") == nil)
    }

    @Test func settingsSavedBeforeColoursStillLoad() throws {
        let old = #"{"icons":{"/a":{"symbol":{"_0":"star"}}}}"#
        let icons = try JSONDecoder().decode(RepoIcons.self, from: Data(old.utf8))
        #expect(icons.icon(for: "/a") == .symbol("star") && icons.tints.isEmpty)
    }
}


@Suite struct UpdateFeedTests {
    @Test func signaturesVerifyAndTamperingIsCaught() throws {
        let pair = UpdateSigning.generate()
        let archive = Data("GitWolf-1.0.0.zip bytes".utf8)
        let signature = try UpdateSigning.sign(archive, privateKey: pair.privateKey)
        #expect(UpdateSigning.verify(signature, for: archive, publicKey: pair.publicKey))
        #expect(!UpdateSigning.verify(signature, for: Data("tampered".utf8), publicKey: pair.publicKey))
        #expect(!UpdateSigning.verify(signature, for: archive, publicKey: UpdateSigning.generate().publicKey))
        #expect(try UpdateSigning.publicKey(forPrivateKey: pair.privateKey) == pair.publicKey)
        #expect(Data(base64Encoded: pair.publicKey)?.count == 32 && Data(base64Encoded: signature)?.count == 64)
        #expect(throws: UpdateSigning.Failure.self) { _ = try UpdateSigning.sign(archive, privateKey: "not a key") }
    }

    @Test func buildNumbersSortLikeVersions() {
        #expect(AppVersion("1.2.3")?.buildNumber == 1_002_003)
        #expect(AppVersion("v2.0")!.buildNumber > AppVersion("1.99.99")!.buildNumber)
        #expect(AppVersion("0.1.0")!.buildNumber < AppVersion("0.1.1")!.buildNumber)
    }

    @Test func feedRoundTripsAndKeepsNewestFirst() {
        func item(_ v: String, notes: String = "") -> AppcastItem {
            AppcastItem(version: v, build: String(AppVersion(v)!.buildNumber), url: "https://x/GitWolf-\(v).zip", length: 10,
                        signature: "c2ln", notesHTML: notes, date: Date(timeIntervalSince1970: 1_700_000_000))
        }
        var feed: [AppcastItem] = []
        for v in ["0.1.0", "0.3.0", "0.2.0"] { feed = Appcast.merging(item(v), into: feed) }
        #expect(feed.map(\.version) == ["0.3.0", "0.2.0", "0.1.0"])
        feed = Appcast.merging(item("0.2.0", notes: "<p>fixed</p>"), into: feed)   // same version replaces
        #expect(feed.count == 3 && feed[1].notesHTML == "<p>fixed</p>")

        let xml = Appcast.render(feed)
        #expect(xml.contains("sparkle:edSignature=\"c2ln\"") && xml.contains("<sparkle:shortVersionString>0.3.0<"))
        let back = Appcast.parse(Data(xml.utf8))
        #expect(back.map(\.version) == ["0.3.0", "0.2.0", "0.1.0"])
        #expect(back[1].notesHTML == "<p>fixed</p>" && back[0].url == "https://x/GitWolf-0.3.0.zip" && back[0].length == 10)
        #expect(back[0].signature == "c2ln" && back[0].build == "3000")
    }

    @Test func feedIsCappedAndEscaped() {
        var feed: [AppcastItem] = []
        for i in 0..<30 {
            feed = Appcast.merging(AppcastItem(version: "1.0.\(i)", build: "\(1_000_000 + i)", url: "https://x/a?b=1&c=2", length: 1, signature: "s"), into: feed)
        }
        #expect(feed.count == Appcast.maxItems && feed[0].version == "1.0.29")
        #expect(Appcast.render([feed[0]]).contains("a?b=1&amp;c=2"))
    }
}


@Suite struct ContributorsTests {
    @Test func parsesSortsAndDropsBots() {
        let json = """
        [{"login":"rage","type":"User","contributions":9,"avatar_url":"https://a/1","html_url":"https://github.com/rage"},
         {"login":"dependabot[bot]","type":"Bot","contributions":50},
         {"login":"ipuppyyt","type":"User","contributions":300,"avatar_url":"https://a/2","html_url":"https://github.com/ipuppyyt"}]
        """
        let people = Contributors.parse(Data(json.utf8))
        #expect(people.map(\.login) == ["ipuppyyt", "rage"])
        #expect(people[1].contributions == 9 && people[1].profileURL?.absoluteString == "https://github.com/rage")
    }

    @Test func theMaintainerIsAlwaysListed() {
        let people = Contributors.parse(Data(#"[{"login":"rage","type":"User","contributions":4}]"#.utf8))
        #expect(people.map(\.login) == ["rage", "ipuppyyt"])
        #expect(Contributors.isMaintainer(people[1]))
        #expect(Contributors.parse(Data("not json".utf8)).map(\.login) == ["ipuppyyt"])
    }
}


@Suite struct RepositoryScannerTests {
    private func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(UUID().uuidString)")
        let fm = FileManager.default
        for path in ["a/.git", "b/inner/.git", "c/.git", "c/nested/.git", "plain/notes", "node_modules/x/.git", ".hidden/.git", "d/e/f/.git"] {
            try fm.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        // A worktree or submodule has a `.git` file instead of a folder.
        try fm.createDirectory(at: root.appendingPathComponent("wt"), withIntermediateDirectories: true)
        try Data("gitdir: ../x".utf8).write(to: root.appendingPathComponent("wt/.git"))
        return root
    }

    @Test func findsRepositoriesTwoLevelsDown() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        // The temp folder is listed as /private/var… while the root says /var…, so compare relative to the resolved path.
        let base = root.resolvingSymlinksInPath().path + "/"
        let names = RepositoryScanner.find(in: root).map { $0.resolvingSymlinksInPath().path.replacingOccurrences(of: base, with: "") }
        // Not: c/nested (inside a repository), node_modules, hidden folders, d/e/f (too deep).
        #expect(names == ["a", "b/inner", "c", "wt"])
    }

    @Test func aRepositoryRootIsItselfTheResultAndTheLimitHolds() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(RepositoryScanner.find(in: root.appendingPathComponent("a")).count == 1)
        #expect(RepositoryScanner.find(in: root, limit: 2).count == 2)
    }
}

@Suite struct EverydayWorkflowTests {
    private func entry(_ i: Int, _ hash: String, _ msg: String) -> ReflogEntry {
        ReflogEntry(index: i, hash: hash, message: msg, date: Date())
    }

    @Test func undoingACheckoutSwitchesBack() {
        let plan = UndoPlan.plan(for: [entry(0, "b", "checkout: moving from main to feature/x"), entry(1, "a", "commit: hi")])
        #expect(plan == .switchBack(to: "main", detached: false, from: "feature/x"))
        let hash = String(repeating: "a", count: 40)
        let detached = UndoPlan.plan(for: [entry(0, "b", "checkout: moving from \(hash) to main"), entry(1, "a", "x")])
        #expect(detached == .switchBack(to: hash, detached: true, from: "main"))
    }

    @Test func undoingARebaseGoesBackToBeforeItStarted() {
        let log = [entry(0, "n3", "rebase (finish): returning to refs/heads/x"), entry(1, "n2", "rebase (pick): two"),
                   entry(2, "n1", "rebase (pick): one"), entry(3, "onto", "rebase (start): checkout main"),
                   entry(4, "orig", "commit: original")]
        #expect(UndoPlan.plan(for: log) == .reset(to: "orig", label: "rebase", from: "rebase (finish): returning to refs/heads/x"))
    }

    @Test func undoingAnythingElseStepsBackOneEntry() {
        let plan = UndoPlan.plan(for: [entry(0, "m", "merge dev: Merge made"), entry(1, "p", "commit: x")])
        #expect(plan == .reset(to: "p", label: "merge dev: Merge made", from: "merge dev: Merge made"))
        #expect(UndoPlan.plan(for: [entry(0, "a", "commit (initial): x")]) == nil)
    }

    @Test func switchingBackWorksAgainstRealGit() async throws {
        let t = try await TestRepo.make()
        defer { t.cleanup() }
        try await t.commit("one", text: "1\n")
        try await t.git.run(["switch", "-c", "other"])
        let log = try await t.repo.reflog(limit: 5)
        guard case let .switchBack(to, detached, _)? = UndoPlan.plan(for: log) else { Issue.record("no plan"); return }
        try await t.repo.switchBack(to: to, detached: detached)
        let branch = try await t.git.runString(["rev-parse", "--abbrev-ref", "HEAD"], readOnly: true)
        #expect(branch.trimmingCharacters(in: .whitespacesAndNewlines) == "main")
    }

    @Test func breakingChangeIsMarkedAndUnmarked() {
        let marked = CommitMessage.setBreaking(true, in: "feat(api): drop v1")
        #expect(marked == "feat(api)!: drop v1\n\nBREAKING CHANGE: ")
        #expect(CommitMessage.setBreaking(true, in: marked) == marked)
        #expect(CommitMessage.isBreaking(marked))
        #expect(CommitMessage.setBreaking(false, in: marked) == "feat(api): drop v1")
        #expect(!CommitMessage.isBreaking("feat: x"))
    }

    @Test func changelogGroupsByType() {
        let notes = CommitMessage.changelog(from: ["feat(ui): add tabs", "fix: crash", "feat!: new format", "random words", "chore: bump"])
        #expect(notes == """
        ### Breaking changes
        - new format

        ### Features
        - **ui:** add tabs
        - new format

        ### Fixes
        - crash

        ### Chores
        - bump

        ### Other
        - random words
        """)
    }
}

@Suite struct LaunchRequestTests {
    @Test func foldersFilesAndLinksResolveToAFolder() async throws {
        let t = try await TestRepo.make()
        defer { t.cleanup() }
        try t.write("x", "a.txt")
        #expect(LaunchRequest.folder(from: t.dir)?.path == t.dir.path)
        #expect(LaunchRequest.folder(from: t.dir.appendingPathComponent("a.txt"))?.path == t.dir.path)
        let link = try #require(LaunchRequest.link(for: t.dir))
        #expect(link.scheme == "gitwolf")
        #expect(LaunchRequest.folder(from: link)?.path == t.dir.path)
    }

    @Test func badRequestsAreIgnored() {
        #expect(LaunchRequest.folder(from: URL(string: "https://example.com/open?path=/tmp")!) == nil)
        #expect(LaunchRequest.folder(from: URL(string: "gitwolf://open?path=relative")!) == nil)
        #expect(LaunchRequest.folder(from: URL(string: "gitwolf://open?path=/definitely/not/here")!) == nil)
        #expect(LaunchRequest.folder(from: URL(string: "gitwolf://delete?path=/tmp")!) == nil)
    }
}
