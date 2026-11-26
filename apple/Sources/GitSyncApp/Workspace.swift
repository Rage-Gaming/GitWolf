import AppKit
import GitSyncCore
import Observation
import SwiftUI

enum RecentRepositories {
    private static let key = "recentRepositories"

    static func load() -> [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func remove(_ path: String) {
        let paths = (UserDefaults.standard.stringArray(forKey: key) ?? []).filter { $0 != path }
        UserDefaults.standard.set(paths, forKey: key)
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }

    static func add(_ url: URL) {
        var paths = (UserDefaults.standard.stringArray(forKey: key) ?? []).filter { $0 != url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(12)), forKey: key)
    }
}

enum HomeLayoutStore {
    private static let key = "homeLayout"

    static func load() -> HomeLayout {
        let saved = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(HomeLayout.self, from: $0) }
        return (saved ?? HomeLayout()).pruned { FileManager.default.fileExists(atPath: $0) }
    }

    static func save(_ layout: HomeLayout) {
        if let data = try? JSONEncoder().encode(layout) { UserDefaults.standard.set(data, forKey: key) }
    }
}

/// All repositories open in one window. Every open repository keeps its own store (and file
/// watcher) alive, so badges and state stay current even when it is not the visible one.
@MainActor @Observable
final class Workspace {
    private(set) var repos: [RepositoryStore] = []
    var selectedID: String?
    var errorMessage: String?
    var showPalette = false
    var sheet: WorkspaceSheet?
    private(set) var recents: [URL] = RecentRepositories.load()
    private(set) var home = HomeLayoutStore.load()

    /// The window's workspace, for AppKit hooks (Dock menu) that live outside SwiftUI.
    static weak var current: Workspace?
    private static var didBootstrap = false
    private static let openKey = "openRepositories"
    private static let selectedKey = "selectedRepository"
    private var isRestoring = false

    var selected: RepositoryStore? { repos.first { $0.id == selectedID } }

    /// Files with uncommitted changes across every open repository.
    var totalChanges: Int { repos.reduce(0) { $0 + $1.status.changeCount } }

    init() {
        Self.current = self
        trackDockBadge()
    }

    /// Keeps the Dock icon's badge equal to `totalChanges`, re-arming after every change.
    private func trackDockBadge() {
        let count = withObservationTracking {
            totalChanges
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackDockBadge() }
        }
        NSApp?.dockTile.badgeLabel = BadgeLabel.text(forChanges: count)
    }

    /// Edits the home layout and saves it.
    func editHome(_ change: (inout HomeLayout) -> Void) {
        change(&home)
        HomeLayoutStore.save(home)
    }

    /// Removes a repository from recents, pins and groups (the folder itself is untouched).
    func forget(_ path: String) {
        RecentRepositories.remove(path)
        recents = RecentRepositories.load()
        editHome { $0.remove(path) }
    }

    func clearRecents() {
        RecentRepositories.clear()
        recents = []
    }

    // MARK: Opening & closing

    func open(_ url: URL) { Task { await openAsync(url) } }

    func openAsync(_ url: URL) async {
        do {
            let repo = try await GitRepository.open(at: url)
            let id = repo.root.path
            if repos.contains(where: { $0.id == id }) { selectedID = id; persist(); return }
            let store = RepositoryStore(repo: repo)
            repos.append(store)
            selectedID = id
            store.start()
            RecentRepositories.add(repo.root)
            recents = RecentRepositories.load()
            persist()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Open"
        panel.message = "Choose Git repositories"
        if panel.runModal() == .OK { panel.urls.forEach(open) }
    }

    func close(_ store: RepositoryStore) {
        store.stop()
        repos.removeAll { $0.id == store.id }
        if selectedID == store.id { selectedID = repos.last?.id }
        persist()
    }

    func select(_ id: String?) {
        selectedID = id
        persist()
    }

    func selectIndex(_ index: Int) {
        guard repos.indices.contains(index) else { return }
        select(repos[index].id)
    }

    func cycle(_ delta: Int) {
        guard !repos.isEmpty else { return }
        let current = repos.firstIndex { $0.id == selectedID } ?? (delta > 0 ? -1 : 0)
        select(repos[(current + delta + repos.count) % repos.count].id)
    }

    // MARK: Persistence

    private func persist() {
        guard !isRestoring else { return }
        UserDefaults.standard.set(repos.map(\.id), forKey: Self.openKey)
        UserDefaults.standard.set(selectedID, forKey: Self.selectedKey)
    }

    /// Opens repositories given on the command line, otherwise restores last session's tabs.
    func bootstrap() async {
        guard !Self.didBootstrap else { return }
        Self.didBootstrap = true
        // `GitSync --open=/path/to/repo` (repeatable). A bare path would be treated by AppKit
        // as a document to open and suppress the window, hence the explicit flag.
        let args = CommandLine.arguments.dropFirst().filter { $0.hasPrefix("--open=") }.map { String($0.dropFirst(7)) }
        if !args.isEmpty {
            for path in args { await openAsync(URL(fileURLWithPath: path, isDirectory: true)) }
            return
        }
        isRestoring = true
        let paths = UserDefaults.standard.stringArray(forKey: Self.openKey) ?? []
        let selected = UserDefaults.standard.string(forKey: Self.selectedKey)
        for path in paths where FileManager.default.fileExists(atPath: path) {
            await openAsync(URL(fileURLWithPath: path, isDirectory: true))
        }
        isRestoring = false
        if let selected, repos.contains(where: { $0.id == selected }) { selectedID = selected }
        persist()
    }
}

extension FocusedValues {
    @Entry var workspace: Workspace?
}
