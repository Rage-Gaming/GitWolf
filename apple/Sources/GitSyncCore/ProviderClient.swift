import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct RemoteRepository: Identifiable, Hashable, Sendable {
    public var id: String { fullName }
    public var fullName: String
    public var description: String
    public var isPrivate: Bool
    public var httpsURL: String
    public var sshURL: String
    public var updated: Date?

    public var name: String { fullName.split(separator: "/").last.map(String.init) ?? fullName }
}

public enum ProviderError: Error, LocalizedError, Sendable {
    case unauthorized
    case http(Int)
    case invalidResponse
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "The server rejected this token. Check that it is valid and has repository access."
        case .http(let code): "The server returned an error (HTTP \(code))."
        case .invalidResponse: "The server sent a response GitSync couldn’t understand."
        case .unsupported(let what): what
        }
    }
}

public typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

/// Talks to a hosting provider's REST API to verify a token and list the repositories it can see.
public struct ProviderClient: Sendable {
    public let account: ProviderAccount
    private let secret: String
    private let transport: HTTPTransport

    public static let urlSessionTransport: HTTPTransport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        return (data, http)
    }

    public init(account: ProviderAccount, token: String, transport: @escaping HTTPTransport = ProviderClient.urlSessionTransport) {
        self.account = account
        self.secret = token
        self.transport = transport
    }

    // MARK: Endpoints

    private var apiBase: String {
        let h = account.host
        let o = account.origin
        switch account.kind {
        case .github:
            if h == "github.com" { return "https://api.github.com" }
            // GitHub Enterprise Cloud with data residency: api.<tenant>.ghe.com
            if h.hasSuffix(".ghe.com") { return "https://api.\(h)" }
            return "\(o)/api/v3"
        case .gitlab: return "\(o)/api/v4"
        case .bitbucket: return h == "bitbucket.org" ? "https://api.bitbucket.org/2.0" : "\(o)/rest/api/1.0"
        case .gitea: return "\(o)/api/v1"
        case .azure: return o
        }
    }

    private func request(_ url: String) throws -> URLRequest {
        guard let u = URL(string: url) else { throw ProviderError.invalidResponse }
        var r = URLRequest(url: u)
        r.timeoutInterval = 30
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue("GitSync", forHTTPHeaderField: "User-Agent")
        if account.usesOAuth {
            r.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
            if account.kind == .github { r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version") }
            return r
        }
        if account.usesPassword == true {
            let basic = Data("\(account.username):\(secret)".utf8).base64EncodedString()
            r.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
            return r
        }
        switch account.kind {
        case .github:
            r.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
            r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        case .gitlab:
            r.setValue(secret, forHTTPHeaderField: "PRIVATE-TOKEN")
        case .gitea:
            r.setValue("token \(secret)", forHTTPHeaderField: "Authorization")
        case .bitbucket where account.host != "bitbucket.org":
            // Bitbucket Data Center / Server: HTTP access tokens are Bearer tokens.
            r.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        case .bitbucket, .azure:
            let basic = Data("\(account.username):\(secret)".utf8).base64EncodedString()
            r.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        }
        return r
    }

    private func fetch(_ url: String) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await transport(try request(url))
        switch response.statusCode {
        case 200..<300: return (data, response)
        case 401, 403: throw ProviderError.unauthorized
        default: throw ProviderError.http(response.statusCode)
        }
    }

    // MARK: Verify

    /// Returns the username the token belongs to; throws `unauthorized` for a bad token.
    public func currentUser() async throws -> String {
        guard account.kind.supportsRepositoryListing else {
            throw ProviderError.unsupported("Azure DevOps tokens can’t be verified here; they are used when you clone, fetch and push.")
        }
        if account.kind == .bitbucket, account.host != "bitbucket.org" {
            // Data Center has no "current user" endpoint; listing one repository proves the token works.
            _ = try await fetch(apiBase + "/repos?limit=1")
            return account.username
        }
        let (data, _) = try await fetch(apiBase + "/user")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProviderError.invalidResponse }
        let name: String? = switch account.kind {
        case .github, .gitea: json["login"] as? String ?? json["username"] as? String
        case .gitlab: json["username"] as? String
        case .bitbucket: json["username"] as? String ?? json["nickname"] as? String ?? json["display_name"] as? String
        case .azure: nil
        }
        guard let name, !name.isEmpty else { throw ProviderError.invalidResponse }
        return name
    }

    // MARK: Repositories

    /// Repositories the token can access, most recently active first. Capped to keep it quick.
    public func repositories(maxPages: Int = 5) async throws -> [RemoteRepository] {
        var all: [RemoteRepository] = []
        switch account.kind {
        case .github:
            all = try await paged(maxPages: maxPages, perPage: 100) {
                "\(apiBase)/user/repos?per_page=100&sort=pushed&affiliation=owner,collaborator,organization_member&page=\($0)"
            } parse: { try Self.parseGitHub($0) }
        case .gitlab:
            all = try await paged(maxPages: maxPages, perPage: 100) {
                "\(apiBase)/projects?membership=true&simple=true&per_page=100&order_by=last_activity_at&page=\($0)"
            } parse: { try Self.parseGitLab($0) }
        case .gitea:
            all = try await paged(maxPages: maxPages, perPage: 50) {
                "\(apiBase)/user/repos?limit=50&page=\($0)"
            } parse: { try Self.parseGitea($0) }
        case .bitbucket where account.host != "bitbucket.org":
            var start = 0
            for _ in 0..<max(maxPages, 1) {
                let (data, _) = try await fetch("\(apiBase)/repos?limit=100&start=\(start)")
                all += try Self.parseBitbucketServer(data)
                guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      root["isLastPage"] as? Bool == false, let n = root["nextPageStart"] as? Int else { break }
                start = n
            }
        case .bitbucket:
            var next: String? = "\(apiBase)/repositories?role=member&pagelen=100&sort=-updated_on"
            var pages = 0
            while let url = next, pages < maxPages {
                let (data, _) = try await fetch(url)
                all += try Self.parseBitbucket(data)
                next = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["next"] as? String
                pages += 1
            }
        case .azure:
            throw ProviderError.unsupported("Listing repositories isn’t available for Azure DevOps. Paste a clone URL instead.")
        }
        return all
    }

    private func paged(
        maxPages: Int, perPage: Int, url: (Int) -> String, parse: (Data) throws -> [RemoteRepository]
    ) async throws -> [RemoteRepository] {
        var result: [RemoteRepository] = []
        for page in 1...max(maxPages, 1) {
            let (data, _) = try await fetch(url(page))
            let items = try parse(data)
            result += items
            if items.count < perPage { break }
        }
        return result
    }

    // MARK: Parsing (static so tests can feed sample payloads)

    private static func iso(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    private static func array(_ data: Data) throws -> [[String: Any]] {
        guard let a = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw ProviderError.invalidResponse }
        return a
    }

    static func parseGitHub(_ data: Data) throws -> [RemoteRepository] {
        try array(data).compactMap { r in
            guard let name = r["full_name"] as? String, let https = r["clone_url"] as? String else { return nil }
            return RemoteRepository(
                fullName: name, description: r["description"] as? String ?? "",
                isPrivate: r["private"] as? Bool ?? false, httpsURL: https,
                sshURL: r["ssh_url"] as? String ?? "", updated: iso(r["pushed_at"] as? String ?? r["updated_at"] as? String))
        }
    }

    static func parseGitLab(_ data: Data) throws -> [RemoteRepository] {
        try array(data).compactMap { r in
            guard let name = r["path_with_namespace"] as? String, let https = r["http_url_to_repo"] as? String else { return nil }
            return RemoteRepository(
                fullName: name, description: r["description"] as? String ?? "",
                isPrivate: (r["visibility"] as? String ?? "private") != "public", httpsURL: https,
                sshURL: r["ssh_url_to_repo"] as? String ?? "", updated: iso(r["last_activity_at"] as? String))
        }
    }

    static func parseGitea(_ data: Data) throws -> [RemoteRepository] {
        try array(data).compactMap { r in
            guard let name = r["full_name"] as? String, let https = r["clone_url"] as? String else { return nil }
            return RemoteRepository(
                fullName: name, description: r["description"] as? String ?? "",
                isPrivate: r["private"] as? Bool ?? false, httpsURL: https,
                sshURL: r["ssh_url"] as? String ?? "", updated: iso(r["updated_at"] as? String))
        }
    }

    static func parseBitbucketServer(_ data: Data) throws -> [RemoteRepository] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = root["values"] as? [[String: Any]] else { throw ProviderError.invalidResponse }
        return values.compactMap { r in
            guard let slug = r["slug"] as? String, let project = (r["project"] as? [String: Any])?["key"] as? String else { return nil }
            let clones = ((r["links"] as? [String: Any])?["clone"] as? [[String: Any]]) ?? []
            func link(_ n: String) -> String { clones.first { $0["name"] as? String == n }?["href"] as? String ?? "" }
            var https = link("http")
            if let url = URL(string: https), url.user != nil {
                var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
                c?.user = nil
                https = c?.string ?? https
            }
            return RemoteRepository(
                fullName: "\(project)/\(slug)", description: r["description"] as? String ?? "",
                isPrivate: !(r["public"] as? Bool ?? false), httpsURL: https, sshURL: link("ssh"), updated: nil)
        }
    }

    static func parseBitbucket(_ data: Data) throws -> [RemoteRepository] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = root["values"] as? [[String: Any]] else { throw ProviderError.invalidResponse }
        return values.compactMap { r in
            guard let name = r["full_name"] as? String else { return nil }
            let clones = ((r["links"] as? [String: Any])?["clone"] as? [[String: Any]]) ?? []
            func link(_ n: String) -> String { clones.first { $0["name"] as? String == n }?["href"] as? String ?? "" }
            // Bitbucket puts the username into https clone URLs; strip it so our credential is used.
            var https = link("https")
            if let url = URL(string: https), url.user != nil {
                var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
                c?.user = nil
                https = c?.string ?? https
            }
            return RemoteRepository(
                fullName: name, description: r["description"] as? String ?? "",
                isPrivate: r["is_private"] as? Bool ?? true, httpsURL: https,
                sshURL: link("ssh"), updated: iso(r["updated_on"] as? String))
        }
    }
}
