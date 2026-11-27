import AppKit
import GitWolfCore

/// Checks GitHub for a newer release and tells the user. It never downloads or installs anything:
/// "Download" opens the release page in the browser, where the notarised build is attached.
@MainActor
enum UpdateManager {
    static let autoKey = "settings.checkForUpdates"
    private static let lastCheckKey = "update.lastCheck"
    private static let skippedKey = "update.skippedVersion"

    static var currentVersion: AppVersion? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init)
    }

    /// Once a day at most, and only for packaged builds (a `swift run` binary has no version).
    static func checkInBackground() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: autoKey) as? Bool ?? true, currentVersion != nil else { return }
        if let last = defaults.object(forKey: lastCheckKey) as? Date, Date().timeIntervalSince(last) < 86_400 { return }
        Task { await check(userInitiated: false) }
    }

    static func check(userInitiated: Bool) async {
        guard let current = currentVersion else {
            if userInitiated { inform("This is a development build", "It has no version number to compare with.") }
            return
        }
        UserDefaults.standard.set(Date(), forKey: lastCheckKey)
        do {
            let release = try await UpdateChecker().newerRelease(than: current)
            guard let release else {
                if userInitiated { inform("GitWolf is up to date", "You have version \(current), the latest release.") }
                return
            }
            if !userInitiated, UserDefaults.standard.string(forKey: skippedKey) == release.tag { return }
            offer(release, current: current)
        } catch {
            if userInitiated { inform("Couldn’t check for updates", error.localizedDescription) }
        }
    }

    private static func offer(_ release: ReleaseInfo, current: AppVersion) {
        let alert = NSAlert()
        alert.messageText = "GitWolf \(release.version) is available"
        alert.informativeText = "You have \(current). " + String(release.notes.prefix(500))
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        switch alert.runModal() {
        case .alertFirstButtonReturn: NSWorkspace.shared.open(release.url)
        case .alertThirdButtonReturn: UserDefaults.standard.set(release.tag, forKey: skippedKey)
        default: break
        }
    }

    private static func inform(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }
}
