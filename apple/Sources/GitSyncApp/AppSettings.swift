import Foundation
import GitSyncCore
import SwiftUI

enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Keys shared between `@AppStorage` in the settings UI and `AppSettings` readers.
enum SettingsKey {
    static let appearance = "settings.appearance"
    static let autoFetchMinutes = "settings.autoFetchMinutes"
    static let commitPageSize = "settings.commitPageSize"
    static let diffContext = "settings.diffContext"
    static let gitPath = "settings.gitPath"
}

/// Read-side access to user settings for non-view code. Always reads current values, so changes
/// apply immediately without restarting.
struct AppSettings: Sendable {
    static let shared = AppSettings()
    static let defaultGitPath = "/usr/bin/git"

    private var defaults: UserDefaults { .standard }

    var autoFetchMinutes: Int {
        defaults.object(forKey: SettingsKey.autoFetchMinutes) as? Int ?? 5
    }
    var commitPageSize: Int {
        max(100, defaults.object(forKey: SettingsKey.commitPageSize) as? Int ?? 1000)
    }
    var diffContext: Int {
        defaults.object(forKey: SettingsKey.diffContext) as? Int ?? 4
    }
    var gitPath: String {
        let custom = (defaults.string(forKey: SettingsKey.gitPath) ?? "").trimmingCharacters(in: .whitespaces)
        guard !custom.isEmpty, FileManager.default.isExecutableFile(atPath: custom) else { return Self.defaultGitPath }
        return custom
    }

    func configure(_ repo: GitRepository) -> GitRepository {
        var r = repo
        r.gitPath = gitPath
        r.contextLines = diffContext
        return r
    }
}
