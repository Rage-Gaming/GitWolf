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

/// Accent colour presets. Each has a primary and a secondary tone used for gradients.
enum AccentChoice: String, CaseIterable, Identifiable {
    case indigo, blue, purple, pink, red, orange, green, teal
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var primary: Color {
        switch self {
        case .indigo: Color(red: 0.42, green: 0.38, blue: 0.98)
        case .blue: Color(red: 0.12, green: 0.50, blue: 1.0)
        case .purple: Color(red: 0.66, green: 0.36, blue: 0.96)
        case .pink: Color(red: 0.96, green: 0.30, blue: 0.58)
        case .red: Color(red: 0.94, green: 0.30, blue: 0.32)
        case .orange: Color(red: 0.98, green: 0.52, blue: 0.14)
        case .green: Color(red: 0.20, green: 0.70, blue: 0.40)
        case .teal: Color(red: 0.10, green: 0.68, blue: 0.70)
        }
    }
    var secondary: Color {
        switch self {
        case .indigo: Color(red: 0.20, green: 0.56, blue: 1.0)
        case .blue: Color(red: 0.20, green: 0.78, blue: 0.95)
        case .purple: Color(red: 0.42, green: 0.40, blue: 0.98)
        case .pink: Color(red: 0.98, green: 0.52, blue: 0.40)
        case .red: Color(red: 0.98, green: 0.52, blue: 0.30)
        case .orange: Color(red: 0.98, green: 0.74, blue: 0.20)
        case .green: Color(red: 0.16, green: 0.78, blue: 0.70)
        case .teal: Color(red: 0.20, green: 0.56, blue: 0.98)
        }
    }

    static var current: AccentChoice {
        AccentChoice(rawValue: UserDefaults.standard.string(forKey: SettingsKey.accent) ?? "") ?? .indigo
    }
}

/// Keys shared between `@AppStorage` in the settings UI and `AppSettings` readers.
enum SettingsKey {
    static let appearance = "settings.appearance"
    static let accent = "settings.accent"
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
