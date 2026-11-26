import Foundation

public enum NotificationReason: String, Sendable, CaseIterable {
    case reviewRequested, mention, assigned, other

    public var title: String {
        switch self {
        case .reviewRequested: "Review requested"
        case .mention: "Mentioned"
        case .assigned: "Assigned"
        case .other: "Activity"
        }
    }
}

/// Something that needs your attention on a hosting provider (a review request, a mention…).
public struct ProviderNotification: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var repository: String
    public var reason: NotificationReason
    public var isPullRequest: Bool
    public var updated: Date?
    public var url: URL?
    public var unread: Bool

    public init(id: String, title: String, repository: String, reason: NotificationReason, isPullRequest: Bool,
                updated: Date?, url: URL?, unread: Bool = true) {
        self.id = id; self.title = title; self.repository = repository; self.reason = reason
        self.isPullRequest = isPullRequest; self.updated = updated; self.url = url; self.unread = unread
    }
}

public extension ProviderKind {
    var supportsNotifications: Bool {
        switch self {
        case .github, .gitlab, .gitea: true
        case .bitbucket, .azure: false
        }
    }
}

public extension ProviderClient {
    /// Review requests, mentions and assignments waiting for you.
    /// GitHub needs the `notifications` token scope; GitLab uses your to-do list.
    func notifications() async throws -> [ProviderNotification] {
        switch account.kind {
        case .github:
            let (data, _) = try await fetch("\(apiBase)/notifications?participating=true&per_page=50")
            return try Self.parseGitHubNotifications(data, webBase: account.origin)
        case .gitlab:
            let (data, _) = try await fetch("\(apiBase)/todos?state=pending&per_page=50")
            return try Self.parseGitLabTodos(data)
        case .gitea:
            let (data, _) = try await fetch("\(apiBase)/notifications?status-types=unread&limit=50")
            return try Self.parseGiteaNotifications(data)
        case .bitbucket, .azure:
            throw ProviderError.unsupported("\(account.kind.title) has no notifications API.")
        }
    }

    func markRead(_ notification: ProviderNotification) async throws {
        switch account.kind {
        case .github: _ = try await send("PATCH", "\(apiBase)/notifications/threads/\(notification.id)")
        case .gitea: _ = try await send("PATCH", "\(apiBase)/notifications/threads/\(notification.id)")
        case .gitlab: _ = try await send("POST", "\(apiBase)/todos/\(notification.id)/mark_as_done")
        case .bitbucket, .azure: break
        }
    }

    func markAllRead() async throws {
        switch account.kind {
        case .github: _ = try await send("PUT", "\(apiBase)/notifications", json: [:])
        case .gitea: _ = try await send("PUT", "\(apiBase)/notifications")
        case .gitlab: _ = try await send("POST", "\(apiBase)/todos/mark_as_done")
        case .bitbucket, .azure: break
        }
    }

    // MARK: Parsing

    private static func objects(_ data: Data) throws -> [[String: Any]] {
        guard let a = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw ProviderError.invalidResponse }
        return a
    }

    static func reason(_ raw: String?) -> NotificationReason {
        switch raw ?? "" {
        case "review_requested", "approval_required": .reviewRequested
        case "mention", "team_mention", "mentioned", "directly_addressed": .mention
        case "assign", "assigned": .assigned
        default: .other
        }
    }

    /// `https://api.github.com/repos/o/r/pulls/12` → `https://github.com/o/r/pull/12`.
    static func githubWebURL(api: String?, webBase: String) -> URL? {
        guard let api, let url = URL(string: api) else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard let repos = parts.firstIndex(of: "repos"), parts.count >= repos + 4 else { return nil }
        let owner = parts[repos + 1], repo = parts[repos + 2], kind = parts[repos + 3]
        let number = parts.count > repos + 4 ? parts[repos + 4] : nil
        var path = "/\(owner)/\(repo)"
        switch (kind, number) {
        case ("pulls", let n?): path += "/pull/\(n)"
        case ("issues", let n?): path += "/issues/\(n)"
        case ("commits", let sha?): path += "/commit/\(sha)"
        default: break
        }
        return URL(string: webBase + path)
    }

    static func parseGitHubNotifications(_ data: Data, webBase: String) throws -> [ProviderNotification] {
        try objects(data).compactMap { r in
            guard let id = r["id"] as? String, let subject = r["subject"] as? [String: Any],
                  let title = subject["title"] as? String else { return nil }
            let repo = (r["repository"] as? [String: Any])?["full_name"] as? String ?? ""
            return ProviderNotification(
                id: id, title: title, repository: repo, reason: reason(r["reason"] as? String),
                isPullRequest: subject["type"] as? String == "PullRequest", updated: isoDate(r["updated_at"] as? String),
                url: githubWebURL(api: subject["url"] as? String, webBase: webBase), unread: r["unread"] as? Bool ?? true)
        }
    }

    static func parseGitLabTodos(_ data: Data) throws -> [ProviderNotification] {
        try objects(data).compactMap { r in
            guard let id = r["id"] as? Int else { return nil }
            let target = r["target"] as? [String: Any]
            let title = target?["title"] as? String ?? r["body"] as? String ?? ""
            guard !title.isEmpty else { return nil }
            return ProviderNotification(
                id: String(id), title: title, repository: (r["project"] as? [String: Any])?["path_with_namespace"] as? String ?? "",
                reason: reason(r["action_name"] as? String), isPullRequest: r["target_type"] as? String == "MergeRequest",
                updated: isoDate(r["updated_at"] as? String), url: (r["target_url"] as? String).flatMap(URL.init(string:)))
        }
    }

    static func parseGiteaNotifications(_ data: Data) throws -> [ProviderNotification] {
        try objects(data).compactMap { r in
            guard let id = r["id"] as? Int, let subject = r["subject"] as? [String: Any], let title = subject["title"] as? String else { return nil }
            let repo = (r["repository"] as? [String: Any])?["full_name"] as? String ?? ""
            return ProviderNotification(
                id: String(id), title: title, repository: repo, reason: .other,
                isPullRequest: subject["type"] as? String == "Pull", updated: isoDate(r["updated_at"] as? String),
                url: (subject["html_url"] as? String).flatMap(URL.init(string:)), unread: r["unread"] as? Bool ?? true)
        }
    }
}
