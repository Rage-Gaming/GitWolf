import Foundation
import GitSyncCore
import Observation

/// Review requests, mentions and assignments across every connected account, refreshed every few minutes.
@MainActor @Observable
final class NotificationsStore {
    static let shared = NotificationsStore()

    struct Entry: Identifiable, Hashable {
        var account: ProviderAccount
        var note: ProviderNotification
        var id: String { account.id + "/" + note.id }
    }

    struct Problem: Identifiable, Hashable {
        var account: ProviderAccount
        var message: String
        var id: String { account.id }
    }

    private(set) var entries: [Entry] = []
    private(set) var problems: [Problem] = []
    private(set) var isLoading = false
    private(set) var loadedAt: Date?
    private var polling: Task<Void, Never>?

    /// Number shown on the toolbar bell.
    var unreadCount: Int { entries.filter(\.note.unread).count }

    /// Whether any saved account can have notifications.
    var hasAccounts: Bool { !AccountStorage.load().filter { $0.kind.supportsNotifications }.isEmpty }

    func startPolling() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        var all: [Entry] = []
        var failures: [Problem] = []
        for account in AccountStorage.load() where account.kind.supportsNotifications {
            guard let secret = await AccountStorage.secret(for: account), !secret.isEmpty else { continue }
            do {
                let notes = try await ProviderClient(account: account, token: secret).notifications()
                all += notes.map { Entry(account: account, note: $0) }
            } catch ProviderError.unauthorized {
                failures.append(Problem(account: account, message: account.kind == .github
                    ? "This token can’t read notifications. Create one with the “notifications” scope, or sign in with OAuth again."
                    : "This account’s credentials were rejected."))
            } catch {
                failures.append(Problem(account: account, message: error.localizedDescription))
            }
        }
        entries = all.sorted { ($0.note.updated ?? .distantPast) > ($1.note.updated ?? .distantPast) }
        problems = failures
        loadedAt = Date()
    }

    #if DEBUG
    /// Sample data for screenshots (GITSYNC_REPO_SHEET=notes).
    func loadSamples() {
        let account = ProviderAccount(kind: .github, host: "github.com", username: "me")
        func note(_ id: String, _ title: String, _ repo: String, _ reason: NotificationReason, pr: Bool, ago: TimeInterval) -> Entry {
            Entry(account: account, note: ProviderNotification(id: id, title: title, repository: repo, reason: reason, isPullRequest: pr,
                                                              updated: Date().addingTimeInterval(-ago), url: nil))
        }
        entries = [
            note("1", "Add retry to the upload worker", "acme/api", .reviewRequested, pr: true, ago: 1_800),
            note("2", "Crash when opening a repository with no commits", "acme/app", .mention, pr: false, ago: 7_200),
            note("3", "Bump swift-markdown to 0.5", "acme/app", .assigned, pr: true, ago: 90_000),
        ]
        loadedAt = Date()
    }
    #endif

    func markRead(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        Task {
            guard let secret = await AccountStorage.secret(for: entry.account) else { return }
            try? await ProviderClient(account: entry.account, token: secret).markRead(entry.note)
        }
    }

    func markAllRead() {
        let accounts = Set(entries.map(\.account))
        entries = []
        Task {
            for account in accounts {
                guard let secret = await AccountStorage.secret(for: account) else { continue }
                try? await ProviderClient(account: account, token: secret).markAllRead()
            }
        }
    }
}
