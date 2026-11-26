import AppKit
import GitSyncCore
import SwiftUI

/// User-defined actions, kept as JSON in UserDefaults.
enum CustomActionStore {
    static let key = "settings.customActions"
    static let editorKey = "settings.editorApp"
    static let defaultEditor = "Visual Studio Code"

    static func load() -> [CustomAction] {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([CustomAction].self, from: $0) } ?? []
    }

    static func save(_ actions: [CustomAction]) {
        if let data = try? JSONEncoder().encode(actions) { UserDefaults.standard.set(data, forKey: key) }
    }

    static var editorApp: String {
        let name = (UserDefaults.standard.string(forKey: editorKey) ?? "").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? defaultEditor : name
    }
}

/// Open the repository in Finder, Terminal or an editor, and run custom actions at its root.
extension RepositoryStore {
    var rootURL: URL { URL(fileURLWithPath: id, isDirectory: true) }

    func openInFinder() { NSWorkspace.shared.activateFileViewerSelecting([rootURL]) }

    func openInTerminal() { openWithApp("Terminal") }

    func openInEditor() { openWithApp(CustomActionStore.editorApp) }

    /// `open -a <app> <path>`; the path is an argument, never part of a shell string.
    private func openWithApp(_ app: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", app, rootURL.path]
        let errors = Pipe()
        process.standardError = errors
        process.terminationHandler = { [weak self] p in
            guard p.terminationStatus != 0 else { return }
            let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
            Task { @MainActor in self?.errorMessage = message.isEmpty ? "Couldn’t open \(app)." : message }
        }
        do { try process.run() } catch { errorMessage = error.localizedDescription }
    }

    func run(_ action: CustomAction) {
        let root = rootURL, branch = status.branch
        Task {
            let result = await CustomActionRunner.run(action, root: root, branch: branch)
            guard !result.succeeded else { return }
            let tail = String(result.output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(600))
            errorMessage = "“\(action.name)” failed (exit code \(result.exitCode)).\(tail.isEmpty ? "" : "\n\n\(tail)")"
        }
    }
}
