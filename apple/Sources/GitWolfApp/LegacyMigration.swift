import Foundation
import Security

/// The app used to be called GitSync. On the first launch as GitWolf this carries over what the old
/// name had stored (preferences, the Application Support folder, saved account tokens), so nobody has to
/// set anything up again. The old names are kept here on purpose; everything else uses the new name.
enum LegacyMigration {
    private static let flag = "migratedFromGitSync"
    private static let oldDomains = ["org.gitsync.GitSync", "GitSync"]
    static let oldKeychainService = "GitSync Provider Accounts"

    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: flag) else { return }
        // Preferences: keys the new name doesn't have yet, or only has empty (a first launch may write an empty list).
        for domain in oldDomains {
            guard let old = defaults.persistentDomain(forName: domain) else { continue }
            for (key, value) in old {
                let current = defaults.object(forKey: key)
                if current == nil || (current as? [Any])?.isEmpty == true { defaults.set(value, forKey: key) }
            }
        }
        // Application Support: the whole folder moves (icons, the askpass helper).
        let fm = FileManager.default
        if let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let old = support.appendingPathComponent("GitSync", isDirectory: true)
            let new = support.appendingPathComponent("GitWolf", isDirectory: true)
            if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) { try? fm.moveItem(at: old, to: new) }
        }
        defaults.set(true, forKey: flag)
    }

    /// A token saved under the old keychain service, moved to the new one the first time it is asked for.
    static func legacySecret(for account: String) -> String? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: oldKeychainService,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteLegacySecret(for account: String) {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: oldKeychainService, kSecAttrAccount: account] as CFDictionary)
    }
}
