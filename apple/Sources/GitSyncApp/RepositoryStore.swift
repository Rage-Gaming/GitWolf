import AppKit
import GitSyncCore
import Observation

enum StoreSheet: Identifiable {
    case newBranch(from: String?)
    case newTag(hash: String)
    case stash
    var id: String {
        switch self {
        case .newBranch: "branch"
        case .newTag: "tag"
        case .stash: "stash"
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
    enum Mode: Hashable { case history, changes }

    let repo: GitRepository
    nonisolated var id: String { repo.root.path }
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
    private(set) var isLoaded = false

    // Selection / UI state
    var mode: Mode = .history { didSet { if mode != oldValue { clearSelection() } } }
    private(set) var selectedCommitID: String?
    private(set) var selectedTarget: DiffTarget?
    private(set) var commitFiles: [FileChange] = []
    private(set) var commitMessage = ""
    private(set) var diff: FileDiff?
    var sheet: StoreSheet?
    var draftMessage = ""
    var amend = false { didSet { if amend && draftMessage.isEmpty { loadHeadMessage() } } }

    // Activity
    private(set) var isBusy = false
    private(set) var busyLabel: String?
    var errorMessage: String?

    private var commitLimit = 1000
    private var refreshing = false
    private var needsRefresh = false
    private var diffToken = 0
    private var commitToken = 0
    private var watcher: FileWatcher?
    private let bag = TaskBag()
    private var started = false

    init(repo: GitRepository) { self.repo = repo }

    var graphLaneCount: Int { min(10, max(1, graph.map(\.laneCount).max() ?? 1)) }
    var selectedCommit: Commit? { commits.first { $0.id == selectedCommitID } }
    var canLoadMore: Bool { commits.count >= commitLimit }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        requestRefresh()

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
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard let self, !self.isBusy else { continue }
                try? await self.repo.fetch()
                self.requestRefresh()
            }
        })
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
        if stashes != s.stashes { stashes = s.stashes }
        if remotes != s.remotes { remotes = s.remotes }
        if !isLoaded {
            isLoaded = true
            if !s.status.isClean { mode = .changes }
            #if DEBUG
            if ProcessInfo.processInfo.environment["GITSYNC_MODE"] == "history" {
                mode = .history
                selectCommit(s.commits.first?.id)
            } else if let c = s.status.unstaged.first {
                selectChange(c, source: .unstaged)
            }
            #endif
        }
        reconcileSelection()
    }

    func loadMoreCommits() {
        guard canLoadMore else { return }
        commitLimit += 1000
        requestRefresh()
    }

    // MARK: Selection

    private func clearSelection() {
        selectedTarget = nil
        selectedCommitID = nil
        diff = nil
        commitFiles = []
        commitMessage = ""
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
        }
    }

    func selectCommit(_ id: String?) {
        guard id != selectedCommitID else { return }
        selectedCommitID = id
        selectedTarget = nil
        diff = nil
        commitFiles = []
        commitMessage = ""
        diffToken += 1
        commitToken += 1
        guard let id, let commit = commits.first(where: { $0.id == id }) else { return }
        let token = commitToken
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

    func selectChange(_ change: FileChange, source: DiffTarget.Source) {
        selectTarget(DiffTarget(source: source, path: change.path, originalPath: change.originalPath))
    }

    func selectTarget(_ target: DiffTarget?) {
        guard target != selectedTarget else { return }
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
            if diff != result { diff = result }
        }
    }

    private func loadHeadMessage() {
        Task { if let m = try? await repo.headMessage(), draftMessage.isEmpty { draftMessage = m } }
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

    func fetch() { perform("Fetching…") { try await $0.fetch() } }
    func pull() { perform("Pulling…") { try await $0.pull() } }
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
        perform("Committing…") { try await $0.commit(message: message, amend: amend) }
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
