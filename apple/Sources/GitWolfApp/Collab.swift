import Foundation
import GitWolfCore
import Observation
import SwiftUI

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
                let merged = replacing ? result : items + result.filter { new in !items.contains { $0.number == new.number } }
                withAnimation(.easeOut(duration: 0.15)) { items = merged }
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

    // MARK: Actions (comments, merge, close, labels, create)

    private(set) var comments: [CollabComment] = []
    private(set) var isLoadingComments = false
    private(set) var isWorking = false
    private(set) var repoLabels: [String] = []
    var actionError: String?
    private var commentsFor: Int?

    var canWrite: Bool {
        guard let (account, _) = context?() else { return false }
        return account.kind.supportsWriting(kind, host: account.host) && AccountStorage.account(forHost: account.hostName) != nil
    }

    private func makeClient() async -> (ProviderClient, String)? {
        guard let (account, path) = context?() else { return nil }
        var secret = ""
        if AccountStorage.account(forHost: account.hostName) != nil { secret = await AccountStorage.secret(for: account) ?? "" }
        return (ProviderClient(account: account, token: secret), path)
    }

    func loadComments() {
        guard let number = selectedNumber else { comments = []; commentsFor = nil; return }
        guard commentsFor != number else { return }
        commentsFor = number
        comments = []
        isLoadingComments = true
        let kind = kind
        Task {
            defer { if commentsFor == number { isLoadingComments = false } }
            guard let (client, path) = await makeClient() else { return }
            let result = try? await client.comments(kind, repoPath: path, number: number)
            if commentsFor == number { withAnimation(.easeOut(duration: 0.15)) { comments = result ?? [] } }
        }
        if repoLabels.isEmpty {
            Task {
                guard let (client, path) = await makeClient() else { return }
                repoLabels = (try? await client.repositoryLabels(repoPath: path)) ?? []
            }
        }
    }

    /// Runs a change against the provider, then reloads the list and the conversation.
    private func act(_ work: @escaping @Sendable (ProviderClient, String) async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            guard let (client, path) = await makeClient() else { return }
            do {
                try await work(client, path)
                commentsFor = nil
                load()
                loadComments()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    func addComment(_ text: String) {
        guard let number = selectedNumber else { return }
        let kind = kind
        act { try await $0.addComment(kind, repoPath: $1, number: number, body: text) }
    }

    func merge(_ method: MergeMethod) {
        guard let number = selectedNumber else { return }
        act { try await $0.merge(repoPath: $1, number: number, method: method) }
    }

    func setOpen(_ open: Bool) {
        guard let number = selectedNumber else { return }
        let kind = kind
        act { try await $0.setOpen(open, kind: kind, repoPath: $1, number: number) }
    }

    func setLabels(_ labels: [String]) {
        guard let number = selectedNumber else { return }
        let kind = kind
        act { try await $0.setLabels(labels, kind: kind, repoPath: $1, number: number) }
    }

    /// Creates a pull request or issue and selects it. Throws the provider's explanation on failure.
    func create(title: String, body: String, head: String = "", base: String = "", draft: Bool = false, labels: [String] = []) async throws {
        guard let (client, path) = await makeClient() else { throw ProviderError.unsupported("No hosting account for this repository.") }
        let item: CollabItem
        if kind == .pullRequest {
            item = try await client.createPullRequest(repoPath: path, title: title, body: body, head: head, base: base, draft: draft)
        } else {
            item = try await client.createIssue(repoPath: path, title: title, body: body, labels: labels)
        }
        filter = .open
        selectedNumber = item.number
        load()
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
