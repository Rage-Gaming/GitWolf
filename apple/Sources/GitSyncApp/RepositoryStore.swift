import AppKit
import GitSyncCore
import Observation

enum StoreSheet: Identifiable {
    case newBranch(from: String?)
    case newTag(hash: String)
    case stash
    case reflog
    case rebase(RebasePlan)
    case stashHunk(Int)
    case fileHistory(String)
    var id: String {
        switch self {
        case .newBranch: "branch"
        case .newTag: "tag"
        case .stash: "stash"
        case .reflog: "reflog"
        case .rebase: "rebase"
        case .stashHunk: "stashHunk"
        case .fileHistory: "fileHistory"
        }
    }
}

private final class TaskBag: @unchecked Sendable {
    var tasks: [Task<Void, Never>] = []
    deinit { tasks.forEach { $0.cancel() } }
}

/// Single source of truth for one open repository. Refreshes are coalesced and driven by the
/// file watcher, app activation, a periodic fetch, and every mutating operation, so the UI
/// always converges on the real repository state.
@MainActor @Observable
final class RepositoryStore: Identifiable {
    enum Mode: Hashable { case history, changes, pullRequests, issues, stash }

    private let baseRepo: GitRepository
    /// The repository with the user's current settings (git path, diff context) applied.
    var repo: GitRepository { AppSettings.shared.configure(baseRepo) }
    nonisolated var id: String { baseRepo.root.path }
    var name: String { repo.name }

    // Repository state
    private(set) var status = WorkingStatus.empty
    private(set) var commits: [Commit] = []
    private(set) var graph: [GraphRow] = []
    private(set) var localBranches: [Branch] = []
    private(set) var remoteBranches: [Branch] = []
    private(set) var tags: [GitTag] = []
    private(set) var stashes: [Stash] = []
    private(set) var remotes: [String] = []
    /// A merge / rebase / cherry-pick / revert that is waiting for the user.
    private(set) var operation: InProgressOperation?
    /// Where `origin` (or the first remote) lives, for web links.
    private(set) var remoteLocation: RemoteLocation?
    private(set) var isLoaded = false

    // Selection / UI state
    var mode: Mode = .history { didSet { if mode != oldValue { clearSelection() } } }
    private(set) var selectedCommitID: String?
    private(set) var selectedTarget: DiffTarget?
    private(set) var commitFiles: [FileChange] = []
    private(set) var selectedStash: Stash?
    private(set) var stashFiles: [FileChange] = []
    private(set) var stashCommit: String?
    private(set) var commitMessage = ""
    /// Signature of the selected commit; nil when unsigned or not loaded yet.
    private(set) var selectedSignature: CommitSignature?
    private(set) var signing: SigningConfig?
    /// Sign the next commit. Starts from `commit.gpgsign`; the commit box can override it.
    var signCommit = false
    private(set) var diff: FileDiff?
    private(set) var lineSelection: Set<Int> = []
    private var selectionAnchor: Int?
    var sheet: StoreSheet?
    var draftMessage = ""
    var amend = false { didSet { if amend && draftMessage.isEmpty { loadHeadMessage() } } }

    // Activity
    private(set) var isBusy = false
    private(set) var busyLabel: String?
    var errorMessage: String?

    private var commitLimit = AppSettings.shared.commitPageSize
    private var refreshing = false
    private var needsRefresh = false
    private var diffToken = 0
    private var commitToken = 0
    private var watcher: FileWatcher?
    private let bag = TaskBag()
    private var started = false

    init(repo: GitRepository) { self.baseRepo = repo }

    var graphLaneCount: Int { min(10, max(1, graph.map(\.laneCount).max() ?? 1)) }
    var selectedCommit: Commit? { commits.first { $0.id == selectedCommitID } }
    var canLoadMore: Bool { commits.count >= commitLimit }

    // MARK: Lifecycle

    let pullRequests = CollabStore(kind: .pullRequest)
    let issues = CollabStore(kind: .issue)

    func collab(_ kind: CollabKind) -> CollabStore { kind == .pullRequest ? pullRequests : issues }

    /// Whether this repository's remote is on a provider whose pull requests / issues we can list.
    func supports(_ kind: CollabKind) -> Bool {
        guard let location = remoteLocation, let provider = providerKind else { return false }
        let host = AccountStorage.account(forHost: location.host)?.host ?? location.host
        return provider.supportsCollab(kind, host: host)
    }

    /// "Pull Requests" or "Merge Requests" depending on the provider.
    var pullRequestsTitle: String { webLinks?.pullRequestsWord.appending("s") ?? "Pull Requests" }

    private func collabContext() -> (account: ProviderAccount, path: String)? {
        guard let location = remoteLocation, let provider = providerKind else { return nil }
        let account = AccountStorage.account(forHost: location.host) ?? ProviderAccount(kind: provider, host: location.host, username: "")
        return (account, location.path)
    }

    func start() {
        guard !started else { return }
        started = true
        pullRequests.context = { [weak self] in self?.collabContext() }
        Task {
            let config = await repo.signingConfig()
            signing = config
            signCommit = config.signsByDefault
        }
        #if DEBUG
        if let requested = ProcessInfo.processInfo.environment["GITSYNC_MODE"] {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                switch requested {
                case "pulls": mode = .pullRequests
                case "issues": mode = .issues
                default: break
                }
            }
        }
        #endif
        issues.context = { [weak self] in self?.collabContext() }
        requestRefresh()
        refreshRemoteLocation()

        let watcher = FileWatcher(root: repo.root)
        self.watcher = watcher
        bag.tasks.append(Task { [weak self] in
            for await _ in watcher.events {
                guard let self else { return }
                self.requestRefresh()
            }
        })
        bag.tasks.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                guard let self else { return }
                self.requestRefresh()
            }
        })
        // Background fetch keeps ahead/behind counts honest without user action.
        bag.tasks.append(Task { [weak self] in
            var elapsed = 0
            while !Task.isCancelled {
                // Tick every 30s so changes to the interval in Settings apply promptly.
                try? await Task.sleep(for: .seconds(30))
                elapsed += 30
                let minutes = AppSettings.shared.autoFetchMinutes
                guard minutes > 0, elapsed >= minutes * 60 else { continue }
                elapsed = 0
                guard let self, !self.isBusy else { continue }
                try? await self.repo.fetch()
                self.requestRefresh()
            }
        })
    }

    // MARK: Provider web links

    private func refreshRemoteLocation() {
        Task { [weak self] in
            guard let self else { return }
            let location = await self.repo.remoteLocation()
            if location != self.remoteLocation { self.remoteLocation = location }
        }
    }

    private var providerKind: ProviderKind? {
        guard let host = remoteLocation?.host else { return nil }
        return AccountStorage.account(forHost: host)?.kind ?? ProviderKind.guess(host: host)
    }

    var webLinks: WebLinks? { remoteLocation.map { WebLinks(kind: providerKind, location: $0) } }
    /// "GitHub", "GitLab"... or nil when the remote isn't a recognised provider.
    var providerTitle: String? { providerKind?.title }

    enum WebTarget { case repository, branch, pullRequest, commit(String) }

    func openOnWeb(_ target: WebTarget) {
        guard let links = webLinks else { return }
        let branch = status.branch
        let url: URL?
        switch target {
        case .repository: url = links.repository
        case .branch: url = branch.map { links.branch($0) } ?? links.repository
        case .pullRequest: url = branch.map { links.newPullRequest(from: $0) } ?? links.repository
        case .commit(let hash): url = links.commit(hash)
        }
        if let url { NSWorkspace.shared.open(url) }
    }

    func stop() {
        watcher?.stop()
        bag.tasks.forEach { $0.cancel() }
        bag.tasks.removeAll()
    }

    // MARK: Refresh

    func requestRefresh() {
        if refreshing { needsRefresh = true; return }
        refreshing = true
        Task {
            repeat {
                needsRefresh = false
                await performRefresh()
            } while needsRefresh
            refreshing = false
        }
    }

    private func performRefresh() async {
        do {
            let snap = try await repo.snapshot(commitLimit: commitLimit)
            apply(snap)
        } catch {
            if !isLoaded { errorMessage = error.localizedDescription }
        }
    }

    private func apply(_ s: RepositorySnapshot) {
        // Only assign what changed so SwiftUI doesn't re-render (and flicker) needlessly.
        if status != s.status { status = s.status }
        if commits != s.commits { commits = s.commits; graph = s.graph }
        if localBranches != s.localBranches { localBranches = s.localBranches }
        if remoteBranches != s.remoteBranches { remoteBranches = s.remoteBranches }
        if tags != s.tags { tags = s.tags }
        if stashes != s.stashes {
            stashes = s.stashes
            // Stash refs shift when entries come and go, so leave the preview rather than show the wrong one.
            if mode == .stash, let sel = selectedStash, !s.stashes.contains(sel) { selectedStash = nil; mode = .changes }
        }
        if remotes != s.remotes { remotes = s.remotes; refreshRemoteLocation() }
        if operation != s.operation { operation = s.operation }
        if !isLoaded {
            isLoaded = true
            if !s.status.isClean { mode = .changes }
            #if DEBUG
            if ProcessInfo.processInfo.environment["GITSYNC_REPO_SHEET"] == "reflog" { sheet = .reflog }
            if let v = ProcessInfo.processInfo.environment["GITSYNC_REPO_SHEET"], v.hasPrefix("history:") { sheet = .fileHistory(String(v.dropFirst(8))) }
            if ProcessInfo.processInfo.environment["GITSYNC_REPO_SHEET"] == "stash", let first = s.stashes.first { selectStash(first) }
            if ProcessInfo.processInfo.environment["GITSYNC_REPO_SHEET"] == "rebase", s.commits.count > 4 { beginInteractiveRebase(from: s.commits[3].hash) }
            if ProcessInfo.processInfo.environment["GITSYNC_MODE"] == "history" {
                mode = .history
                selectCommit(s.commits.first?.id)
            } else if let c = s.status.conflicted.first {
                selectChange(c, source: .conflicted)
            } else if let c = s.status.unstaged.first {
                selectChange(c, source: .unstaged)
            }
            #endif
        }
        reconcileSelection()
    }

    func loadMoreCommits() {
        guard canLoadMore else { return }
        commitLimit += AppSettings.shared.commitPageSize
        requestRefresh()
    }

    // MARK: Selection

    private func clearSelection() {
        selectedTarget = nil
        selectedCommitID = nil
        diff = nil
        clearLineSelection()
        commitFiles = []
        commitMessage = ""
        selectedSignature = nil
        diffToken += 1
        commitToken += 1
    }

    /// Keeps selection valid after the repository changes underneath it. A file that moved
    /// between areas (e.g. just staged) is followed rather than dropped.
    private func reconcileSelection() {
        switch mode {
        case .changes:
            guard let t = selectedTarget else { return }
            let candidates: [(DiffTarget.Source, [FileChange])] = [
                (.staged, status.staged), (.unstaged, status.unstaged),
                (.untracked, status.untracked), (.conflicted, status.conflicted),
            ]
            if let hit = candidates.first(where: { $0.0 == t.source && $0.1.contains { $0.path == t.path } }) {
                _ = hit
                loadDiff(for: t)
            } else if let hit = candidates.first(where: { $0.1.contains { $0.path == t.path } }),
                      let change = hit.1.first(where: { $0.path == t.path }) {
                selectChange(change, source: hit.0)
            } else {
                selectedTarget = nil; diff = nil
            }
        case .history:
            if let id = selectedCommitID {
                if commits.contains(where: { $0.id == id }) {
                    // Commits are immutable; nothing to reload.
                } else { clearSelection() }
            }
        case .pullRequests, .issues, .stash:
            break
        }
    }

    func selectCommit(_ id: String?) {
        guard id != selectedCommitID else { return }
        selectedCommitID = id
        selectedTarget = nil
        diff = nil
        commitFiles = []
        commitMessage = ""
        selectedSignature = nil
        diffToken += 1
        commitToken += 1
        guard let id, let commit = commits.first(where: { $0.id == id }) else { return }
        let token = commitToken
        Task {
            let signature = try? await repo.signature(of: commit.hash)
            if token == commitToken { selectedSignature = signature }
        }
        Task {
            async let files = try? repo.files(in: commit)
            async let message = try? repo.message(of: commit.hash)
            let (f, m) = (await files ?? [], await message ?? commit.subject)
            guard token == commitToken else { return }
            commitFiles = f
            commitMessage = m
            if let first = f.first { selectChange(first, source: .commit(commit.hash)) }
        }
    }

    func reveal(hash: String) {
        mode = .history
        selectCommit(hash)
    }

    /// Shows what a stash contains (files and diffs) without applying it.
    func selectStash(_ stash: Stash) {
        mode = .stash
        selectedStash = stash
        stashFiles = []; stashCommit = nil
        selectedTarget = nil; diff = nil; diffToken += 1
        Task {
            guard let hash = try? await repo.stashHash(stash.ref), let files = try? await repo.stashFiles(stash.ref),
                  selectedStash == stash else { return }
            stashCommit = hash; stashFiles = files
            if let first = files.first { selectChange(first, source: .commit(hash)) }
        }
    }

    func selectChange(_ change: FileChange, source: DiffTarget.Source) {
        selectTarget(DiffTarget(source: source, path: change.path, originalPath: change.originalPath))
    }

    func selectTarget(_ target: DiffTarget?) {
        guard target != selectedTarget else { return }
        clearLineSelection()
        selectedTarget = target
        guard let target else { diff = nil; diffToken += 1; return }
        loadDiff(for: target)
    }

    private func loadDiff(for target: DiffTarget) {
        diffToken += 1
        let token = diffToken
        Task {
            let result = (try? await repo.diff(for: target)) ?? .empty
            guard token == diffToken else { return }
            if diff != result {
                diff = result; clearLineSelection()
                #if DEBUG
                demoHook(result)
                #endif
            }
        }
    }

    private func loadHeadMessage() {
        Task { if let m = try? await repo.headMessage(), draftMessage.isEmpty { draftMessage = m } }
    }

    #if DEBUG
    private var demoDone = false
    /// GITSYNC_DEMO=select|stagehunk exercises the real store actions for screenshots.
    private func demoHook(_ d: FileDiff) {
        guard !demoDone, d.hunks.count > 1, let mode = ProcessInfo.processInfo.environment["GITSYNC_DEMO"] else { return }
        demoDone = true
        if mode == "stagehunk" { applyHunk(1, action: .stage) }
        if mode == "select" { d.lines.filter(\.isChange).prefix(2).forEach { toggleLine($0.id, extend: false) } }
    }
    #endif

    // MARK: Hunk & line staging

    /// Hunk/line operations are offered for plain staged or unstaged text diffs only
    /// (not renames, binaries, truncated or non-UTF-8 diffs, which can't be patched safely).
    var canPatch: Bool {
        guard mode == .changes, let t = selectedTarget, t.originalPath == nil, diff?.canPatch == true else { return false }
        return t.source == .staged || t.source == .unstaged
    }

    func clearLineSelection() {
        if !lineSelection.isEmpty { lineSelection = [] }
        selectionAnchor = nil
    }

    /// Toggles a changed line; with `extend` selects every changed line between the anchor and `id`.
    func toggleLine(_ id: Int, extend: Bool) {
        guard let diff, diff.lines.indices.contains(id), diff.lines[id].isChange else { return }
        if extend, let anchor = selectionAnchor, diff.lines.indices.contains(anchor) {
            for i in min(anchor, id)...max(anchor, id) where diff.lines[i].isChange { lineSelection.insert(i) }
        } else {
            if lineSelection.contains(id) { lineSelection.remove(id) } else { lineSelection.insert(id) }
            selectionAnchor = id
        }
    }

    func applyHunk(_ index: Int, action: PatchAction) {
        guard let diff else { return }
        applyPatch(diff, ids: diff.changedLineIDs(inHunk: index), action: action)
    }

    /// "+3 −1" for the given changed lines of the current diff.
    func changeSummary(_ ids: Set<Int>) -> String {
        guard let diff else { return "" }
        let lines = diff.lines.filter { ids.contains($0.id) }
        return "+\(lines.filter { $0.kind == .addition }.count) −\(lines.filter { $0.kind == .deletion }.count)"
    }
    func hunkSummary(_ index: Int) -> String { changeSummary(diff?.changedLineIDs(inHunk: index) ?? []) }

    /// A hunk can be stashed from the unstaged diff of a file that has nothing staged.
    var canStashHunk: Bool {
        guard canPatch, let t = selectedTarget, t.source == .unstaged else { return false }
        return !status.staged.contains { $0.path == t.path }
    }

    func stashHunk(_ index: Int, message: String) {
        guard let diff, let target = selectedTarget else { return }
        let ids = diff.changedLineIDs(inHunk: index)
        guard let forward = PatchBuilder.make(diff: diff, selecting: ids, action: .stage),
              let back = PatchBuilder.make(diff: diff, selecting: ids, action: .discard) else { return }
        perform("Stashing hunk…") {
            try await $0.stashHunk(forwardPatch: forward, discardPatch: back, path: target.path, message: message)
        }
    }

    /// Asks before discarding, saying exactly how many lines and files are lost.
    func confirmDiscard(_ changes: [FileChange], untracked: Bool) {
        let paths = changes.map(\.path)
        Task {
            let summary = try? await repo.discardSummary(tracked: untracked ? [] : paths, untracked: untracked ? paths : [])
            let alert = NSAlert()
            alert.messageText = changes.count == 1 ? "Discard changes to “\(changes[0].fileName)”?" : "Discard changes to \(changes.count) files?"
            alert.informativeText = summary?.sentence ?? "This can’t be undone."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { discard(changes, untracked: untracked) }
        }
    }

    func applySelectedLines(action: PatchAction) {
        guard let diff else { return }
        applyPatch(diff, ids: lineSelection, action: action)
    }

    private func applyPatch(_ diff: FileDiff, ids: Set<Int>, action: PatchAction) {
        guard let patch = PatchBuilder.make(diff: diff, selecting: ids, action: action) else { return }
        let label = action == .stage ? "Staging…" : (action == .unstage ? "Unstaging…" : "Discarding…")
        perform(label) { try await $0.apply(patch: patch, action: action) }
    }

    // MARK: Operations

    private func perform(_ label: String, _ op: @escaping @Sendable (GitRepository) async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        busyLabel = label
        Task {
            do { try await op(repo) } catch { errorMessage = error.localizedDescription }
            isBusy = false
            busyLabel = nil
            requestRefresh()
        }
    }

    func resolveConflict(_ path: String, content: String) {
        perform("Resolving…") { try await $0.resolveConflict(path, content: content) }
    }
    func resolveConflict(_ path: String, taking side: ConflictSide) {
        perform("Resolving…") { try await $0.resolveConflict(path, taking: side) }
    }

    /// Resets the current branch to `target`. A hard reset says what it will lose and asks first.
    func reset(to target: String, label: String, mode: ResetMode) {
        Task {
            let impact = try? await repo.resetImpact(to: target)
            if mode == .hard {
                let alert = NSAlert()
                alert.messageText = "Hard reset to \(label)?"
                var lost: [String] = []
                if let n = impact?.droppedCommits, n > 0 { lost.append("\(n) commit\(n == 1 ? "" : "s") will no longer be on this branch (still reachable from the reflog)") }
                if let n = impact?.modifiedFiles, n > 0 { lost.append("uncommitted changes in \(n) file\(n == 1 ? "" : "s") will be permanently lost") }
                alert.informativeText = lost.isEmpty ? "The working tree will match that commit." : lost.joined(separator: "; ").capitalizedFirst + "."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Hard Reset")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            perform("Resetting…") { try await $0.reset(to: target, mode: mode) }
        }
    }

    /// Moves HEAD back to where it was before the last reflog entry, keeping uncommitted work
    /// (git refuses rather than overwrite it).
    func undoLastChange() {
        Task {
            guard let log = try? await repo.reflog(limit: 2), log.count > 1 else {
                errorMessage = "There is nothing to undo."; return
            }
            let alert = NSAlert()
            alert.messageText = "Undo “\(log[0].message)”?"
            alert.informativeText = "HEAD moves back to \(log[1].shortHash). Uncommitted changes are kept; if they would be overwritten, nothing happens."
            alert.addButton(withTitle: "Undo")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let target = log[1].hash
            perform("Undoing…") { try await $0.reset(to: target, mode: .keep) }
        }
    }

    func continueOperation() {
        guard let op = operation else { return }
        perform("Continuing…") { try await $0.continueOperation(op) }
    }
    func skipOperation() {
        guard let op = operation else { return }
        perform("Skipping…") { try await $0.skipOperation(op) }
    }
    func abortOperation() {
        guard let op = operation else { return }
        perform("Aborting…") { try await $0.abortOperation(op) }
    }

    func fetch() { perform("Fetching…") { try await $0.fetch() } }
    func pull() {
        let rebase = AppSettings.shared.pullRebase
        perform(rebase ? "Pulling (rebase)…" : "Pulling…") { try await $0.pull(rebase: rebase) }
    }

    /// Opens the interactive rebase editor for `commit` and everything after it on this branch.
    func beginInteractiveRebase(from commit: String) {
        guard operation == nil else { errorMessage = "Finish or abort the current \(operation!.verb.lowercased()) first."; return }
        Task {
            do {
                let (plan, merges) = try await repo.rebaseCandidates(from: commit)
                guard !plan.items.isEmpty else { errorMessage = "There are no commits to rebase."; return }
                if merges {
                    errorMessage = "This range contains merge commits, which an interactive rebase would flatten. Pick a more recent commit."
                    return
                }
                sheet = .rebase(plan)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func startRebase(_ plan: RebasePlan) { perform("Rebasing…") { try await $0.startInteractiveRebase(plan) } }
    func rebase(onto target: String) { perform("Rebasing…") { try await $0.rebase(onto: target) } }
    func push() {
        let (s, r) = (status, remotes)
        perform("Pushing…") { try await $0.push(status: s, remotes: r) }
    }

    func stage(_ paths: [String]) { perform("Staging…") { try await $0.stage(paths) } }
    func unstage(_ paths: [String]) { perform("Unstaging…") { try await $0.unstage(paths) } }
    func stageAll() { perform("Staging…") { try await $0.stageAll() } }
    func unstageAll() { perform("Unstaging…") { try await $0.unstageAll() } }

    func discard(_ changes: [FileChange], untracked: Bool) {
        let paths = changes.map(\.path)
        perform("Discarding…") { repo in
            if untracked { try await repo.discard(tracked: [], untracked: paths) }
            else { try await repo.discard(tracked: paths, untracked: []) }
        }
    }

    func commit() {
        let message = draftMessage
        let amend = amend
        // Only pass an explicit choice when it differs from git's own default.
        let sign: Bool? = signing.map { $0.signsByDefault == signCommit ? nil : signCommit } ?? nil
        perform(signCommit ? "Signing & committing…" : "Committing…") { try await $0.commit(message: message, amend: amend, sign: sign) }
        // Cleared optimistically; restored if the commit fails.
        Task {
            while isBusy { try? await Task.sleep(for: .milliseconds(50)) }
            if errorMessage == nil { draftMessage = ""; self.amend = false }
        }
    }

    func checkout(_ branch: Branch) { perform("Switching…") { try await $0.checkout(branch) } }
    func checkout(commit hash: String) { perform("Checking out…") { try await $0.checkout(commit: hash) } }
    func createBranch(_ name: String, from: String?, checkout: Bool) {
        perform("Creating branch…") { try await $0.createBranch(name, at: from, checkout: checkout) }
    }
    func deleteBranch(_ name: String, force: Bool = false) {
        perform("Deleting…") { try await $0.deleteBranch(name, force: force) }
    }
    func merge(_ name: String) { perform("Merging…") { try await $0.merge(name) } }
    func cherryPick(_ hash: String) { perform("Cherry-picking…") { try await $0.cherryPick(hash) } }
    func revert(_ hash: String) { perform("Reverting…") { try await $0.revert(hash) } }
    func createTag(_ name: String, at hash: String) { perform("Tagging…") { try await $0.createTag(name, at: hash) } }
    func deleteTag(_ name: String) { perform("Deleting tag…") { try await $0.deleteTag(name) } }
    func stashPush(_ message: String) { perform("Stashing…") { try await $0.stashPush(message: message) } }
    func stashApply(_ ref: String) { perform("Applying stash…") { try await $0.stashApply(ref) } }
    func stashPop(_ ref: String) { perform("Popping stash…") { try await $0.stashPop(ref) } }
    func stashDrop(_ ref: String) { perform("Dropping stash…") { try await $0.stashDrop(ref) } }
}
