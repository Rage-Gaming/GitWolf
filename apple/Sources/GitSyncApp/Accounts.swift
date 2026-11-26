import Foundation
import GitSyncCore
import Observation
import Security

/// Secrets live in the login Keychain, never in preferences or on disk elsewhere.
enum Keychain {
    private static let service = "GitSync Provider Accounts"

    struct Failure: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
        }
    }

    static func save(_ secret: String, for account: String) throws {
        delete(account)
        let status = SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: Data(secret.utf8),
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked,
        ] as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    static func read(_ account: String) -> String? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(_ account: String) -> Bool {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ] as CFDictionary) == errSecSuccess
    }
}

/// Thread-safe access to saved accounts (metadata in UserDefaults, secrets in the Keychain), so git
/// operations running off the main actor can look credentials up.
enum AccountStorage {
    private static let key = "providerAccounts"

    static func load() -> [ProviderAccount] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let accounts = try? JSONDecoder().decode([ProviderAccount].self, from: data) else { return [] }
        return accounts
    }

    static func save(_ accounts: [ProviderAccount]) {
        if let data = try? JSONEncoder().encode(accounts) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func token(for account: ProviderAccount) -> String? { Keychain.read(account.id) }

    /// The credential git should use for a remote on `host`, if the user added an account for it.
    static func credential(forHost host: String) -> GitCredential? {
        let h = host.lowercased()
        // Azure DevOps remotes may live on org.visualstudio.com; match on the provider's own hosts too.
        guard let account = load().first(where: { $0.hostName == h }),
              let token = token(for: account) else { return nil }
        return GitCredential(host: account.hostName, username: account.username, token: token)
    }

    static func account(forHost host: String) -> ProviderAccount? {
        load().first { $0.hostName == host.lowercased() }
    }
}

/// Writes the `GIT_ASKPASS` helper once and hands out its path.
enum AskPass {
    static let path: String? = {
        let fm = FileManager.default
        guard let support = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return nil }
        let dir = support.appendingPathComponent("GitSync", isDirectory: true)
        let file = dir.appendingPathComponent("askpass.sh")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if (try? String(contentsOf: file, encoding: .utf8)) != GitCredential.askpassScript {
                try GitCredential.askpassScript.write(to: file, atomically: true, encoding: .utf8)
            }
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            return file.path
        } catch {
            return nil
        }
    }()
}

@MainActor @Observable
final class AccountStore {
    static let shared = AccountStore()
    private(set) var accounts: [ProviderAccount] = AccountStorage.load()

    /// Saves (or replaces) an account and its secret.
    func add(_ account: ProviderAccount, token: String) throws {
        var list = accounts
        if let i = list.firstIndex(where: { $0.kind == account.kind && $0.host == account.host && $0.username == account.username }) {
            Keychain.delete(list[i].id)
            list.remove(at: i)
        }
        try Keychain.save(token, for: account.id)
        list.append(account)
        accounts = list
        AccountStorage.save(list)
    }

    func remove(_ account: ProviderAccount) {
        Keychain.delete(account.id)
        accounts.removeAll { $0.id == account.id }
        AccountStorage.save(accounts)
    }
}
