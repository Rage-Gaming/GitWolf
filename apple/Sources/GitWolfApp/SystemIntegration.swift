import AppKit
import GitWolfCore
import SwiftUI
import UserNotifications

/// macOS notifications for finished CI runs. Needs the packaged app (a bare development binary has no
/// bundle identifier, and the notification centre refuses it), so development builds stay silent.
@MainActor
final class CheckNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CheckNotifier()
    static let key = "settings.notifyChecks"

    private var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }
    private var enabled: Bool { UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true }

    func start() {
        guard available else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    /// A commit's checks went from running to finished while GitWolf is in the background.
    func finished(repo: String, repoID: String, branch: String?, state: CheckState) {
        guard available, enabled, !NSApp.isActive, state == .success || state == .failure else { return }
        let title = state == .success ? "Checks passed" : "Checks failed"
        let body = repo + (branch.map { " · \($0)" } ?? "")
        let loud = state == .failure
        // Only plain strings cross into the task; the notification centre is used there and nowhere else.
        Task { await Self.post(title: title, body: body, repoID: repoID, loud: loud) }
    }

    private nonisolated static func post(title: String, body: String, repoID: String, loud: Bool) async {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["repo": repoID]
        if loud { content.sound = .default }
        try? await center.add(UNNotificationRequest(identifier: "checks-\(repoID)", content: content, trigger: nil))
    }

    // The completion-handler forms of the delegate methods: they take no non-Sendable value across an await,
    // which older Swift toolchains reject for the async forms.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["repo"] as? String
        completionHandler()
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if let id { Workspace.current?.select(id) }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([])
    }
}

/// Installs the `gitwolf` command (a small script that opens a folder in the app) into `~/.local/bin`.
enum CommandLineTool {
    static var target: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/gitwolf") }
    static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: target.path) }
    static var onPath: Bool {
        let dir = target.deletingLastPathComponent().path
        return (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains { String($0) == dir }
    }

    /// Copies the bundled script. Throws a readable message when there is none (development builds) or it can't be written.
    static func install() throws {
        guard let source = Bundle.main.url(forResource: "gitwolf", withExtension: nil) else {
            throw NSError(domain: "GitWolf", code: 1, userInfo: [NSLocalizedDescriptionKey: "The command line tool is part of the packaged app, not development builds."])
        }
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: target)
        try fm.copyItem(at: source, to: target)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
    }

    static func uninstall() { try? FileManager.default.removeItem(at: target) }
}
