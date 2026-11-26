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

    static func add(_ url: URL) {
        var paths = (UserDefaults.standard.stringArray(forKey: key) ?? []).filter { $0 != url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(12)), forKey: key)
    }
}

/// Per-window state: which repository (if any) is open.
@MainActor @Observable
final class WindowModel {
    var store: RepositoryStore?
    var errorMessage: String?
    var recents: [URL] = RecentRepositories.load()

    func open(_ url: URL) {
        Task {
            do {
                let repo = try await GitRepository.open(at: url)
                store?.stop()
                let newStore = RepositoryStore(repo: repo)
                store = newStore
                RecentRepositories.add(repo.root)
                recents = RecentRepositories.load()
                newStore.start()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a Git repository"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func closeRepository() {
        store?.stop()
        store = nil
    }
}

extension FocusedValues {
    @Entry var windowModel: WindowModel?
}
