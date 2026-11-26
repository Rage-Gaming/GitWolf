import Foundation

/// High-level git operations for one repository. Stateless and `Sendable`: each method spawns
/// its own git process. Callers are responsible for serialising mutating operations.
public struct GitRepository: Sendable {
    public let root: URL
    /// Path of the `git` executable to run.
    public var gitPath: String
    /// Unchanged lines shown around each diff hunk.
    public var contextLines: Int

    /// Resolves a saved credential for a remote host, plus where the `GIT_ASKPASS` helper lives.
    /// Only consulted for network commands (fetch, pull, push, clone).
    public var credentials: (@Sendable (String) async -> GitCredential?)?
    public var askpassPath: String?

    var git: GitRunner { GitRunner(workingDirectory: root, gitPath: gitPath) }

    /// A runner for network operations, carrying the account credential for this repo's remote.
    private func networkGit() async -> GitRunner {
        guard let credentials, let askpassPath,
              let names = try? await remotes(), let name = names.contains("origin") ? "origin" : names.first,
              let url = try? await git.runString(["remote", "get-url", name], readOnly: true),
              let location = RemoteLocation.parse(url),
              let credential = await credentials(location.host)
        else { return git }
        return GitRunner(workingDirectory: root, gitPath: gitPath,
                         extraEnvironment: credential.environment(askpassPath: askpassPath))
    }

    /// Location of the `origin` (or first) remote, if it is a recognisable URL.
    public func remoteLocation() async -> RemoteLocation? {
        guard let names = try? await remotes(), let name = names.contains("origin") ? "origin" : names.first,
              let url = try? await git.runString(["remote", "get-url", name], readOnly: true)
        else { return nil }
        return RemoteLocation.parse(url)
    }

    public var name: String { root.lastPathComponent }

    private static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    public init(root: URL, gitPath: String = "/usr/bin/git", contextLines: Int = 4) {
        self.root = root
        self.gitPath = gitPath
        self.contextLines = min(max(contextLines, 0), 50)
    }

    /// Opens the repository containing `url`, resolving to its top-level directory.
    public static func open(at url: URL) async throws -> GitRepository {
        let probe = GitRunner(workingDirectory: url)
        let top: String
        do {
            top = try await probe.runString(["rev-parse", "--show-toplevel"], readOnly: true)
        } catch {
            throw GitError(command: "rev-parse", exitCode: 128, stderr: "“\(url.lastPathComponent)” is not a Git repository.")
        }
        let path = top.trimmingCharacters(in: .whitespacesAndNewlines)
        return GitRepository(root: URL(fileURLWithPath: path, isDirectory: true))
    }

    // MARK: Creating

    /// A folder name for a clone URL: `https://host/org/repo.git` → `repo`, `git@host:org/repo` → `repo`.
    public static func suggestedName(forCloneURL url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix(".git") { s.removeLast(4) }
        let last = s.split(whereSeparator: { $0 == "/" || $0 == ":" || $0 == "\\" }).last.map(String.init) ?? ""
        return last
    }

    /// Clones `url` into `parent/name` and returns the new repository's folder.
    /// `onProgress` receives git's progress output (e.g. "Receiving objects: 40%").
    public static func clone(
        url: String, into parent: URL, name: String,
        gitPath: String = "/usr/bin/git",
        credential: GitCredential? = nil,
        askpassPath: String? = nil,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> URL {
        let destination = parent.appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path),
           let contents = try? FileManager.default.contentsOfDirectory(atPath: destination.path), !contents.isEmpty {
            throw GitError(command: "clone", exitCode: 128, stderr: "“\(name)” already exists in that location and isn’t empty.")
        }
        var env: [String: String] = [:]
        if let credential, let askpassPath { env = credential.environment(askpassPath: askpassPath) }
        let runner = GitRunner(workingDirectory: parent, gitPath: gitPath, extraEnvironment: env)
        try await runner.run(["clone", "--progress", "--", url, name], onProgress: onProgress)
        return destination
    }

    /// Creates (if needed) `directory` and initialises a repository in it.
    public static func initialize(at directory: URL, initialBranch: String, gitPath: String = "/usr/bin/git") async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let runner = GitRunner(workingDirectory: directory, gitPath: gitPath)
        var args = ["init"]
        let branch = initialBranch.trimmingCharacters(in: .whitespaces)
        if !branch.isEmpty { args += ["--initial-branch", branch] }
        try await runner.run(args)
        return directory
    }

    // MARK: Reading

    public func snapshot(commitLimit: Int) async throws -> RepositorySnapshot {
        async let status = self.status()
        async let branches = self.branches()
        async let tags = self.tags()
        async let stashes = self.stashes()
        let remotes = try await self.remotes()
        let commits = try await self.log(limit: commitLimit, remotes: Set(remotes))
        let graph = GraphLayout.layout(commits)
        let (local, remote) = try await branches
        return RepositorySnapshot(
            status: try await status, commits: commits, graph: graph,
            localBranches: local, remoteBranches: remote,
            tags: try await tags, stashes: try await stashes, remotes: remotes,
            operation: inProgressOperation())
    }

    public func status() async throws -> WorkingStatus {
        let data = try await git.run(
            ["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"], readOnly: true)
        return StatusParser.parse(data)
    }

    public func remotes() async throws -> [String] {
        let out = try await git.runString(["remote"], readOnly: true)
        return out.split(separator: "\n").map(String.init)
    }

    public func branches() async throws -> (local: [Branch], remote: [Branch]) {
        let data = try await git.run(
            ["for-each-ref", "--format=\(RefParser.branchFormat)", "--sort=refname", "refs/heads", "refs/remotes"],
            readOnly: true)
        let all = RefParser.parseBranches(data)
        return (all.filter { !$0.isRemote }, all.filter { $0.isRemote })
    }

    public func tags() async throws -> [GitTag] {
        let data = try await git.run(
            ["for-each-ref",
             "--format=%(refname:short)%1f%(if)%(*objectname)%(then)%(*objectname)%(else)%(objectname)%(end)%1f%(objecttype)%1f%(contents:subject)",
             "--sort=-creatordate", "refs/tags"],
            readOnly: true)
        return RefParser.parseTags(data)
    }

    public func stashes() async throws -> [Stash] {
        let data = try await git.run(["stash", "list", "--format=%gd%x1f%gs%x1f%at"], readOnly: true)
        return RefParser.parseStashes(data)
    }

    public func log(limit: Int, remotes: Set<String>) async throws -> [Commit] {
        let data = try await git.run(
            ["log", "--all", "--topo-order", "-z", "-n", String(limit), "--format=\(LogParser.format)"],
            readOnly: true)
        return LogParser.parse(data, remotes: remotes)
    }

    /// Full commit message (subject + body).
    public func message(of hash: String) async throws -> String {
        let out = try await git.runString(["show", "-s", "--format=%B", hash], readOnly: true)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func headMessage() async throws -> String {
        try await message(of: "HEAD")
    }

    public func files(in commit: Commit) async throws -> [FileChange] {
        let base = commit.parents.first ?? Self.emptyTree
        let data = try await git.run(
            ["diff", "--name-status", "-z", "-M", base, commit.hash], readOnly: true)
        return RefParser.parseNameStatus(data)
    }

    public func diff(for target: DiffTarget, commits: [String: Commit] = [:], maxLines: Int = 6000) async throws -> FileDiff {
        var paths = [target.path]
        if let original = target.originalPath { paths.insert(original, at: 0) }
        // Explicit prefixes and no external tools so output is stable regardless of user config
        // (diff.noprefix, diff.mnemonicPrefix, ...), which `git apply` depends on.
        let common = ["diff", "--no-color", "--no-ext-diff", "--no-textconv",
                      "--src-prefix=a/", "--dst-prefix=b/", "-U\(contextLines)", "-M"]
        let data: Data
        switch target.source {
        case .unstaged, .conflicted:
            data = try await git.run(common + ["--"] + paths, readOnly: true)
        case .staged:
            data = try await git.run(common + ["--cached", "--"] + paths, readOnly: true)
        case .untracked:
            data = try await git.run(
                ["diff", "--no-color", "--no-index", "-U\(contextLines)", "--", "/dev/null", target.path],
                readOnly: true, allowedExitCodes: [0, 1])
        case .commit(let hash):
            let base = try await parentOrEmptyTree(of: hash)
            data = try await git.run(common + [base, hash, "--"] + paths, readOnly: true)
        case .compare(let base, let head):
            data = try await git.run(common + [base, head, "--"] + paths, readOnly: true)
        }
        return DiffParser.parse(data, maxLines: maxLines)
    }

    private func parentOrEmptyTree(of hash: String) async throws -> String {
        let out = try await git.runString(["rev-list", "--parents", "-n", "1", hash], readOnly: true)
        let parts = out.split(whereSeparator: { $0 == " " || $0 == "\n" })
        return parts.count > 1 ? String(parts[1]) : Self.emptyTree
    }

    // MARK: Staging & committing

    /// Applies a patch built by `PatchBuilder` (hunk / line staging, unstaging and discarding).
    public func apply(patch: String, action: PatchAction) async throws {
        var args = ["apply", "--recount", "--whitespace=nowarn"]
        if action.cached { args.append("--cached") }
        if action.reverse { args.append("--reverse") }
        args.append("-")
        try await git.run(args, input: Data(patch.utf8))
    }

    public func stage(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try await git.run(["add", "--"] + paths)
    }

    public func stageAll() async throws { try await git.run(["add", "-A"]) }

    public func unstage(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try await git.run(["reset", "-q", "--"] + paths)
    }

    public func unstageAll() async throws { try await git.run(["reset", "-q"]) }

    /// Discards working-tree changes. Destructive.
    public func discard(tracked: [String], untracked: [String]) async throws {
        if !tracked.isEmpty { try await git.run(["restore", "--"] + tracked) }
        if !untracked.isEmpty { try await git.run(["clean", "-f", "--"] + untracked) }
    }

    /// - Parameter sign: `true` forces `-S`, `false` forces `--no-gpg-sign`, nil follows git config.
    /// - Parameter skipHooks: passes `--no-verify` (skips pre-commit and commit-msg).
    /// - Throws: `HookFailedError` when a hook refused the commit.
    public func commit(message: String, amend: Bool, sign: Bool? = nil, skipHooks: Bool = false) async throws {
        var args = ["commit"]
        if amend { args.append("--amend") }
        if skipHooks { args.append("--no-verify") }
        if let sign { args.append(sign ? "--gpg-sign" : "--no-gpg-sign") }
        if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args.append("--no-edit")
        } else {
            args += ["-m", message]
        }
        do {
            try await git.run(args)
        } catch let error as GitError {
            if !skipHooks, let failure = HookDiagnosis.diagnose(stderr: error.stderr, activeHooks: await activeHooks()) { throw failure }
            throw error
        }
    }

    // MARK: Branches

    public func checkout(_ branch: Branch) async throws {
        if branch.isRemote {
            try await git.run(["switch", "--track", branch.name])
        } else {
            try await git.run(["switch", branch.name])
        }
    }

    public func checkout(commit hash: String) async throws {
        try await git.run(["switch", "--detach", hash])
    }

    public func createBranch(_ name: String, at startPoint: String? = nil, checkout: Bool) async throws {
        var args = checkout ? ["switch", "-c", name] : ["branch", name]
        if let startPoint { args.append(startPoint) }
        try await git.run(args)
    }

    public func deleteBranch(_ name: String, force: Bool) async throws {
        try await git.run(["branch", force ? "-D" : "-d", name])
    }

    public func merge(_ name: String) async throws {
        try await git.run(["merge", "--no-edit", name])
    }

    public func cherryPick(_ hash: String) async throws { try await git.run(["cherry-pick", hash]) }
    public func revert(_ hash: String) async throws { try await git.run(["revert", "--no-edit", hash]) }

    // MARK: Tags

    /// A non-empty `message` makes an annotated tag (with tagger and date); otherwise a lightweight one.
    public func createTag(_ name: String, at hash: String, message: String = "") async throws {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            try await git.run(["tag", name, hash])
        } else {
            try await git.run(["tag", "-a", name, "-m", text, hash])
        }
    }

    public func pushTag(_ name: String, remote: String) async throws {
        try await networkGit().run(["push", remote, "refs/tags/\(name)"])
    }

    public func pushAllTags(remote: String) async throws {
        try await networkGit().run(["push", remote, "--tags"])
    }

    public func deleteRemoteTag(_ name: String, remote: String) async throws {
        try await networkGit().run(["push", remote, "--delete", "refs/tags/\(name)"])
    }

    public func deleteTag(_ name: String) async throws {
        try await git.run(["tag", "-d", name])
    }

    // MARK: Stash

    public func stashPush(message: String) async throws {
        var args = ["stash", "push", "--include-untracked"]
        if !message.isEmpty { args += ["-m", message] }
        try await git.run(args)
    }

    public func stashApply(_ ref: String) async throws {
        do { try await git.run(["stash", "apply", ref]) }
        catch let error as GitError {
            if !(await applyStashAsPatch(ref, after: error)) { throw error }
        }
    }

    public func stashPop(_ ref: String) async throws {
        do { try await git.run(["stash", "pop", ref]) }
        catch let error as GitError {
            if !(await applyStashAsPatch(ref, after: error)) { throw error }
            try await git.run(["stash", "drop", ref])
        }
    }

    /// `git stash apply` refuses when a file the stash touches has other local changes. If the
    /// stash is plain tracked changes (the case for a stashed hunk), applying its diff as a patch
    /// still works whenever the changes don't overlap. Returns true when the patch was applied.
    private func applyStashAsPatch(_ ref: String, after error: GitError) async -> Bool {
        guard error.stderr.contains("would be overwritten") else { return false }
        if (try? await git.run(["rev-parse", "--verify", "--quiet", "\(ref)^3"], readOnly: true)) != nil { return false }
        guard let patch = try? await git.run(["diff", "--binary", "--no-color", "--no-ext-diff", "\(ref)^1", ref], readOnly: true),
              (try? await git.run(["apply", "--recount", "--whitespace=nowarn", "-"], input: patch)) != nil
        else { return false }
        return true
    }
    public func stashDrop(_ ref: String) async throws { try await git.run(["stash", "drop", ref]) }

    // MARK: Remotes

    public func fetch() async throws {
        try await networkGit().run(["fetch", "--all", "--prune"])
    }

    /// Fetches and integrates the upstream branch, by merging or (with `rebase`) rebasing.
    public func pull(rebase: Bool = false) async throws {
        let net = await networkGit()
        if rebase {
            do { try await net.run(["pull", "--rebase", "--autostash", "--no-edit"]) }
            catch let error as GitError { if inProgressOperation() == nil { throw error } }
            return
        }
        do {
            try await net.run(["pull", "--no-edit"])
        } catch let error as GitError where error.stderr.contains("divergent branches") {
            try await net.run(["pull", "--no-edit", "--no-rebase"])
        }
    }

    /// Deletes a branch on the remote (`git push <remote> --delete <branch>`).
    public func deleteRemoteBranch(remote: String, branch: String) async throws {
        try await networkGit().run(["push", remote, "--delete", branch])
    }

    public func push(status: WorkingStatus, remotes: [String]) async throws {
        if status.upstream == nil, let branch = status.branch {
            let remote = remotes.contains("origin") ? "origin" : (remotes.first ?? "origin")
            try await networkGit().run(["push", "--set-upstream", remote, branch])
        } else {
            try await networkGit().run(["push"])
        }
    }
}
