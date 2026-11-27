import Foundation

public enum MergeMethod: String, CaseIterable, Sendable, Identifiable {
    case merge, squash, rebase
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .merge: "Create a merge commit"
        case .squash: "Squash and merge"
        case .rebase: "Rebase and merge"
        }
    }
}

/// A comment on a pull request or issue.
public struct CollabComment: Identifiable, Hashable, Sendable {
    public var id: String
    public var author: String
    public var body: String
    public var created: Date?
    /// The author's profile picture from the platform, when the API gives one.
    public var avatarURL: URL? = nil
}

/// A pull request's review state, reduced to what a list needs.
public enum ReviewState: String, Sendable { case approved, changesRequested, pending }

public extension ProviderKind {
    /// Whether GitWolf can create and change pull requests / issues (not just list them) for this provider.
    func supportsWriting(_ kind: CollabKind, host: String) -> Bool {
        switch self {
        case .github, .gitlab, .gitea: true
        case .bitbucket: kind == .pullRequest && host == "bitbucket.org"
        case .azure: false
        }
    }
}

public extension ProviderClient {
    private func guardWriting(_ kind: CollabKind) throws {
        guard account.kind.supportsWriting(kind, host: account.host) else {
            throw ProviderError.unsupported("\(account.kind.title) \(kind == .issue ? "issues" : "pull requests") can’t be changed from GitWolf yet.")
        }
    }

    private func resource(_ kind: CollabKind) -> String {
        switch account.kind {
        case .gitlab: kind == .pullRequest ? "merge_requests" : "issues"
        default: kind == .pullRequest ? "pulls" : "issues"
        }
    }

    // MARK: Create

    /// Opens a pull / merge request from `head` into `base` and returns it.
    func createPullRequest(repoPath: String, title: String, body: String, head: String, base: String, draft: Bool) async throws -> CollabItem {
        try guardWriting(.pullRequest)
        let data: Data
        switch account.kind {
        case .github:
            (data, _) = try await send("POST", "\(apiBase)/repos/\(repoPath)/pulls",
                                       json: ["title": title, "body": body, "head": head, "base": base, "draft": draft])
            return try Self.parseGitHubCollab(Self.wrap(data), kind: .pullRequest)._firstOrThrow()
        case .gitlab:
            (data, _) = try await send("POST", "\(apiBase)/projects/\(Self.gitlabProjectID(repoPath))/merge_requests",
                                       json: ["title": draft ? "Draft: \(title)" : title, "description": body,
                                              "source_branch": head, "target_branch": base])
            return try Self.parseGitLabCollab(Self.wrap(data), kind: .pullRequest)._firstOrThrow()
        case .gitea:
            (data, _) = try await send("POST", "\(apiBase)/repos/\(repoPath)/pulls",
                                       json: ["title": draft ? "WIP: \(title)" : title, "body": body, "head": head, "base": base])
            return try Self.parseGiteaCollab(Self.wrap(data), kind: .pullRequest)._firstOrThrow()
        case .bitbucket:
            (data, _) = try await send("POST", "\(apiBase)/repositories/\(repoPath)/pullrequests", json: [
                "title": title, "description": body,
                "source": ["branch": ["name": head]], "destination": ["branch": ["name": base]],
            ])
            return try Self.parseBitbucketCollab(Self.wrapValues(data))._firstOrThrow()
        case .azure:
            throw ProviderError.unsupported("Azure DevOps isn’t supported here yet.")
        }
    }

    func createIssue(repoPath: String, title: String, body: String, labels: [String] = []) async throws -> CollabItem {
        try guardWriting(.issue)
        switch account.kind {
        case .github:
            var json: [String: Any] = ["title": title, "body": body]
            if !labels.isEmpty { json["labels"] = labels }
            let (data, _) = try await send("POST", "\(apiBase)/repos/\(repoPath)/issues", json: json)
            return try Self.parseGitHubCollab(Self.wrap(data), kind: .issue)._firstOrThrow()
        case .gitlab:
            var json: [String: Any] = ["title": title, "description": body]
            if !labels.isEmpty { json["labels"] = labels.joined(separator: ",") }
            let (data, _) = try await send("POST", "\(apiBase)/projects/\(Self.gitlabProjectID(repoPath))/issues", json: json)
            return try Self.parseGitLabCollab(Self.wrap(data), kind: .issue)._firstOrThrow()
        case .gitea:
            let (data, _) = try await send("POST", "\(apiBase)/repos/\(repoPath)/issues", json: ["title": title, "body": body])
            return try Self.parseGiteaCollab(Self.wrap(data), kind: .issue)._firstOrThrow()
        case .bitbucket, .azure:
            throw ProviderError.unsupported("Creating issues isn’t supported for \(account.kind.title).")
        }
    }

    // MARK: Comments

    func comments(_ kind: CollabKind, repoPath: String, number: Int) async throws -> [CollabComment] {
        try guardWriting(kind)
        switch account.kind {
        case .github, .gitea:
            let (data, _) = try await fetch("\(apiBase)/repos/\(repoPath)/issues/\(number)/comments?per_page=100")
            return try Self.parseComments(data, author: ["user", "login"], body: "body", id: "id", date: "created_at")
        case .gitlab:
            let (data, _) = try await fetch("\(apiBase)/projects/\(Self.gitlabProjectID(repoPath))/\(resource(kind))/\(number)/notes?sort=asc&per_page=100")
            // System notes ("added 1 commit", "changed the description") are noise here.
            let all = try Self.parseComments(data, author: ["author", "username"], body: "body", id: "id", date: "created_at", skipping: "system")
            return all
        case .bitbucket:
            let (data, _) = try await fetch("\(apiBase)/repositories/\(repoPath)/pullrequests/\(number)/comments?pagelen=100&sort=created_on")
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let values = root["values"] as? [[String: Any]] else {
                throw ProviderError.invalidResponse
            }
            return values.compactMap { r in
                guard let id = r["id"] as? Int, let raw = (r["content"] as? [String: Any])?["raw"] as? String, r["deleted"] as? Bool != true else { return nil }
                let user = r["user"] as? [String: Any]
                let avatar = ((user?["links"] as? [String: Any])?["avatar"] as? [String: Any])?["href"] as? String
                return CollabComment(id: String(id), author: user?["display_name"] as? String ?? user?["nickname"] as? String ?? "",
                                     body: raw, created: Self.isoDate(r["created_on"] as? String), avatarURL: AvatarURLs.safe(avatar))
            }
        case .azure:
            throw ProviderError.unsupported("Azure DevOps isn’t supported here yet.")
        }
    }

    func addComment(_ kind: CollabKind, repoPath: String, number: Int, body: String) async throws {
        try guardWriting(kind)
        switch account.kind {
        case .github, .gitea:
            _ = try await send("POST", "\(apiBase)/repos/\(repoPath)/issues/\(number)/comments", json: ["body": body])
        case .gitlab:
            _ = try await send("POST", "\(apiBase)/projects/\(Self.gitlabProjectID(repoPath))/\(resource(kind))/\(number)/notes", json: ["body": body])
        case .bitbucket:
            _ = try await send("POST", "\(apiBase)/repositories/\(repoPath)/pullrequests/\(number)/comments", json: ["content": ["raw": body]])
        case .azure:
            throw ProviderError.unsupported("Azure DevOps isn’t supported here yet.")
        }
    }

    // MARK: Merge and close

    func merge(repoPath: String, number: Int, method: MergeMethod) async throws {
        try guardWriting(.pullRequest)
        switch account.kind {
        case .github:
            _ = try await send("PUT", "\(apiBase)/repos/\(repoPath)/pulls/\(number)/merge", json: ["merge_method": method.rawValue])
        case .gitlab:
            if method == .rebase {
                throw ProviderError.unsupported("GitLab merges with fast-forward only if the project is set to it. Choose merge or squash.")
            }
            _ = try await send("PUT", "\(apiBase)/projects/\(Self.gitlabProjectID(repoPath))/merge_requests/\(number)/merge",
                               json: ["squash": method == .squash])
        case .gitea:
            _ = try await send("POST", "\(apiBase)/repos/\(repoPath)/pulls/\(number)/merge", json: ["Do": method.rawValue])
        case .bitbucket:
            let strategy = ["merge": "merge_commit", "squash": "squash", "rebase": "fast_forward"][method.rawValue] ?? "merge_commit"
            _ = try await send("POST", "\(apiBase)/repositories/\(repoPath)/pullrequests/\(number)/merge", json: ["merge_strategy": strategy])
        case .azure:
            throw ProviderError.unsupported("Azure DevOps isn’t supported here yet.")
        }
    }

    /// Closes or reopens a pull request or issue. (Bitbucket can only decline; it can't reopen.)
    func setOpen(_ open: Bool, kind: CollabKind, repoPath: String, number: Int) async throws {
        try guardWriting(kind)
        switch account.kind {
        case .github:
            _ = try await send("PATCH", "\(apiBase)/repos/\(repoPath)/\(resource(kind))/\(number)", json: ["state": open ? "open" : "closed"])
        case .gitea:
            _ = try await send("PATCH", "\(apiBase)/repos/\(repoPath)/\(resource(kind))/\(number)", json: ["state": open ? "open" : "closed"])
        case .gitlab:
            _ = try await send("PUT", "\(apiBase)/projects/\(Self.gitlabProjectID(repoPath))/\(resource(kind))/\(number)",
                               json: ["state_event": open ? "reopen" : "close"])
        case .bitbucket:
            guard !open else { throw ProviderError.unsupported("Bitbucket can’t reopen a declined pull request.") }
            _ = try await send("POST", "\(apiBase)/repositories/\(repoPath)/pullrequests/\(number)/decline")
        case .azure:
            throw ProviderError.unsupported("Azure DevOps isn’t supported here yet.")
        }
    }

    // MARK: Labels

    /// Replaces an item's labels (GitHub and GitLab; Gitea addresses labels by id and isn't supported).
    func setLabels(_ labels: [String], kind: CollabKind, repoPath: String, number: Int) async throws {
        try guardWriting(kind)
        switch account.kind {
        case .github:
            _ = try await send("PUT", "\(apiBase)/repos/\(repoPath)/issues/\(number)/labels", json: ["labels": labels])
        case .gitlab:
            _ = try await send("PUT", "\(apiBase)/projects/\(Self.gitlabProjectID(repoPath))/\(resource(kind))/\(number)",
                               json: ["labels": labels.joined(separator: ",")])
        default:
            throw ProviderError.unsupported("Editing labels isn’t supported for \(account.kind.title).")
        }
    }

    /// Names of the labels defined in the repository.
    func repositoryLabels(repoPath: String) async throws -> [String] {
        switch account.kind {
        case .github, .gitea:
            let (data, _) = try await fetch("\(apiBase)/repos/\(repoPath)/labels?per_page=100")
            return try Self.namesFrom(data)
        case .gitlab:
            let (data, _) = try await fetch("\(apiBase)/projects/\(Self.gitlabProjectID(repoPath))/labels?per_page=100")
            return try Self.namesFrom(data)
        default:
            return []
        }
    }

    // MARK: Helpers

    private static func namesFrom(_ data: Data) throws -> [String] {
        guard let a = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw ProviderError.invalidResponse }
        return a.compactMap { $0["name"] as? String }
    }

    /// The parsers expect arrays; a create call returns one object.
    private static func wrap(_ data: Data) throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProviderError.invalidResponse }
        return try JSONSerialization.data(withJSONObject: [object])
    }

    private static func wrapValues(_ data: Data) throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProviderError.invalidResponse }
        return try JSONSerialization.data(withJSONObject: ["values": [object]])
    }

    static func isoDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    static func parseComments(_ data: Data, author: [String], body: String, id: String, date: String, skipping flag: String? = nil) throws -> [CollabComment] {
        guard let a = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw ProviderError.invalidResponse }
        return a.compactMap { r in
            if let flag, r[flag] as? Bool == true { return nil }
            guard let text = r[body] as? String else { return nil }
            let identifier = (r[id] as? Int).map(String.init) ?? (r[id] as? String) ?? UUID().uuidString
            let user = r[author[0]] as? [String: Any]
            let name = user?[author[1]] as? String ?? ""
            return CollabComment(id: identifier, author: name, body: text, created: isoDate(r[date] as? String),
                                 avatarURL: AvatarURLs.safe(user?["avatar_url"] as? String))
        }
    }
}

private extension Array {
    func _firstOrThrow() throws -> Element {
        guard let first else { throw ProviderError.invalidResponse }
        return first
    }
}
