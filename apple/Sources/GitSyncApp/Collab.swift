import Foundation
import GitSyncCore
import Observation

/// Pull requests or issues for one repository, loaded page by page from the hosting provider.
@MainActor @Observable
final class CollabStore {
    let kind: CollabKind
    /// Resolves the provider account and `owner/repo` path; set by the owning `RepositoryStore`.
    var context: (@MainActor () -> (account: ProviderAccount, path: String)?)?

    var filter = CollabFilter.open {
        didSet { if filter != oldValue { load() } }
    }
    var query = ""
    var selectedNumber: Int?
    private(set) var items: [CollabItem] = []
    private(set) var isLoading = false
    private(set) var hasMore = false
    private(set) var error: String?
    private(set) var loadedAt: Date?
    private var page = 1
    private var generation = 0

    init(kind: CollabKind) { self.kind = kind }

    var selected: CollabItem? { items.first { $0.number == selectedNumber } }

    var visibleItems: [CollabItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter {
            $0.title.lowercased().contains(q) || $0.author.lowercased().contains(q)
                || "#\($0.number)" == q || String($0.number) == q || $0.labels.contains { $0.lowercased().contains(q) }
        }
    }

    /// Loads on first use and refreshes when the data is more than a minute old.
    func loadIfNeeded() {
        if let loadedAt, Date().timeIntervalSince(loadedAt) < 60 { return }
        if !isLoading { load() }
    }

    func load() {
        fetch(page: 1, replacing: true)
    }

    func loadMore() {
        guard hasMore, !isLoading else { return }
        fetch(page: page + 1, replacing: false)
    }

    private func fetch(page requested: Int, replacing: Bool) {
        generation += 1
        let token = generation
        guard let (account, path) = context?() else {
            error = "This repository’s remote isn’t on a supported hosting provider."
            items = []
            return
        }
        isLoading = true
        error = nil
        let kind = kind, filter = filter
        Task {
            var secret = ""
            if AccountStorage.account(forHost: account.hostName) != nil { secret = await AccountStorage.secret(for: account) ?? "" }
            do {
                let client = ProviderClient(account: account, token: secret)
                let result = try await client.collab(kind, repoPath: path, filter: filter, page: requested)
                guard token == generation else { return }
                page = requested
                hasMore = result.count >= ProviderClient.collabPageSize
                items = replacing ? result : items + result.filter { new in !items.contains { $0.number == new.number } }
                loadedAt = Date()
                if let n = selectedNumber, !items.contains(where: { $0.number == n }) { selectedNumber = nil }
            } catch {
                guard token == generation else { return }
                self.error = Self.describe(error, signedIn: !secret.isEmpty, provider: account.kind.title)
                if replacing { items = [] ; hasMore = false }
            }
            isLoading = false
        }
    }

    private static func describe(_ error: Error, signedIn: Bool, provider: String) -> String {
        if case ProviderError.unauthorized = error {
            return signedIn
                ? "\(provider) rejected the saved credentials. Re-add the account in Settings → Accounts."
                : "This repository is private or rate-limited. Add a \(provider) account in Settings → Accounts."
        }
        if case ProviderError.http(404) = error {
            return signedIn ? "Not found. The repository may be private to another account, or this feature is turned off."
                            : "Not found. If the repository is private, add a \(provider) account in Settings → Accounts."
        }
        return error.localizedDescription
    }
}
