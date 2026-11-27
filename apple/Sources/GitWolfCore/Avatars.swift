import Foundation

/// Profile pictures from the hosting platform. Never from third-party services: an email address is only
/// ever sent to the platform the repository is already on.
public enum AvatarURLs {
    private static func match(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<m.numberOfRanges).compactMap { Range(m.range(at: $0), in: text).map { String(text[$0]) } }
    }

    /// GitHub and GitLab "noreply" addresses name the account, so no request is needed:
    /// `12345+login@users.noreply.github.com`, `login@users.noreply.github.com`, `7-login@users.noreply.gitlab.com`.
    public static func fromNoreply(email: String, size: Int = 96) -> URL? {
        let e = email.trimmingCharacters(in: .whitespaces)
        if let g = match(#"^(\d+)\+[A-Za-z0-9-]+@users\.noreply\.github\.com$"#, e), let id = g.first {
            return URL(string: "https://avatars.githubusercontent.com/u/\(id)?s=\(size)")
        }
        if let g = match(#"^([A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)@users\.noreply\.github\.com$"#, e), let login = g.first {
            return URL(string: "https://github.com/\(login).png?size=\(size)")
        }
        if let g = match(#"^(\d+)-[A-Za-z0-9._-]+@users\.noreply\.gitlab\.com$"#, e), let id = g.first {
            return URL(string: "https://gitlab.com/uploads/-/system/user/avatar/\(id)/avatar.png?width=\(size)")
        }
        return nil
    }

    /// Only web addresses are ever loaded as pictures.
    public static func safe(_ s: String?) -> URL? {
        guard let s, let url = URL(string: s), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host != nil else { return nil }
        return url
    }
}

public extension ProviderClient {
    /// The platform's profile picture for the author of commit `sha`, or nil when the platform can't tie the
    /// commit to an account (for example an email that isn't linked to anyone).
    func commitAuthorAvatar(repoPath: String, sha: String, email: String) async throws -> URL? {
        guard !sha.isEmpty, sha.allSatisfy(\.isHexDigit) else { return nil }
        switch account.kind {
        case .github, .gitea:
            // The commit list returns the linked account without the (large) file list.
            let query = account.kind == .gitea ? "sha=\(sha)&limit=1&stat=false&files=false" : "sha=\(sha)&per_page=1"
            let (data, _) = try await fetch("\(apiBase)/repos/\(repoPath)/commits?\(query)")
            return try Self.parseCommitListAvatar(data)
        case .gitlab:
            // `+` must be escaped too, or the server reads "a+tag@x.com" as "a tag@x.com".
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            guard !email.isEmpty, let encoded = email.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
            let (data, _) = try await fetch("\(apiBase)/avatar?email=\(encoded)&size=96")
            return try Self.parseGitLabAvatar(data)
        case .bitbucket where account.host == "bitbucket.org":
            let (data, _) = try await fetch("\(apiBase)/repositories/\(repoPath)/commit/\(sha)")
            return try Self.parseBitbucketCommitAvatar(data)
        case .bitbucket, .azure:
            return nil
        }
    }

    /// GitHub / Gitea: `[ { "author": { "avatar_url": … } } ]`. `author` is null when no account matches.
    static func parseCommitListAvatar(_ data: Data) throws -> URL? {
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw ProviderError.invalidResponse }
        return AvatarURLs.safe((list.first?["author"] as? [String: Any])?["avatar_url"] as? String)
    }

    /// GitLab `GET /avatar?email=`: `{ "avatar_url": … }`.
    static func parseGitLabAvatar(_ data: Data) throws -> URL? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProviderError.invalidResponse }
        return AvatarURLs.safe(json["avatar_url"] as? String)
    }

    /// Bitbucket Cloud commit: `author.user.links.avatar.href`.
    static func parseBitbucketCommitAvatar(_ data: Data) throws -> URL? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProviderError.invalidResponse }
        let user = (json["author"] as? [String: Any])?["user"] as? [String: Any]
        let avatar = (user?["links"] as? [String: Any])?["avatar"] as? [String: Any]
        return AvatarURLs.safe(avatar?["href"] as? String)
    }
}
