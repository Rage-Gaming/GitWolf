import CryptoKit
import Foundation

/// Tokens returned by an OAuth server. `expiresAt` is nil for tokens that never expire.
public struct OAuthTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    /// For providers whose OAuth needs a client secret (Bitbucket Cloud). Kept with the tokens, in the
    /// credential store, so refreshes work later.
    public var clientSecret: String?

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil, clientSecret: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.clientSecret = clientSecret
    }

    /// True when the access token should be refreshed before use (with a minute of slack).
    public func needsRefresh(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) < 60
    }
}

public enum OAuthFlow: Sendable { case device, pkce }

public struct DeviceCode: Sendable, Equatable {
    public var deviceCode: String
    public var userCode: String
    public var verificationURL: URL
    public var interval: Int
    public var expiresIn: Int
}

public enum OAuthError: Error, LocalizedError, Sendable, Equatable {
    case notSupported(String)
    case denied
    case expired
    case server(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .notSupported(let m): m
        case .denied: "Sign-in was denied."
        case .expired: "The sign-in expired. Try again."
        case .server(let m): m
        case .invalidResponse: "The server sent an unexpected response."
        }
    }
}

/// How each provider does OAuth. Both flows work with public clients (no client secret), so nothing
/// secret is shipped in the app: GitHub uses the device flow, GitLab and Gitea use the authorization
/// code flow with PKCE and a loopback redirect.
public extension ProviderKind {
    var oauthFlow: OAuthFlow? {
        switch self {
        case .github: .device
        case .gitlab, .gitea, .bitbucket, .azure: .pkce
        }
    }

    /// OAuth is offered for Bitbucket Cloud only (Data Center uses access tokens).
    func supportsOAuth(host: String) -> Bool {
        self != .bitbucket || host == "bitbucket.org"
    }

    /// Bitbucket Cloud's authorization-code grant has no PKCE and requires the consumer's secret.
    var oauthNeedsClientSecret: Bool { self == .bitbucket }
    var oauthUsesPKCE: Bool { self != .bitbucket }

    /// Why browser sign-in isn't offered for this provider.
    var oauthUnavailableReason: String? {
        switch self {
        case .bitbucket: "Browser sign-in is only available for Bitbucket Cloud. Use an HTTP access token for Data Center."
        default: nil
        }
    }

    /// Scopes requested at sign-in.
    var oauthScopes: String {
        switch self {
        case .github: "repo"
        // `api` covers re-running and cancelling jobs, merge requests and comments, which the narrower scopes do not.
        case .gitlab: "api read_repository write_repository"
        // Azure DevOps resource id (user_impersonation) plus a refresh token.
        case .azure: "499b84ac-1321-427f-aa17-267ca6975798/user_impersonation offline_access"
        default: ""
        }
    }
}

/// The fixed loopback address the PKCE flow redirects to. Register exactly this redirect URI on the
/// OAuth application.
public enum OAuthLoopback {
    public static let port: UInt16 = 53682
    public static let redirectURI = "http://127.0.0.1:\(port)/callback"
}

public struct PKCE: Sendable, Equatable {
    public var verifier: String
    public var challenge: String

    public static func generate() -> PKCE {
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        let verifier = base64url(Data(bytes))
        return PKCE(verifier: verifier, challenge: challenge(for: verifier))
    }

    public static func challenge(for verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public struct OAuthClient: Sendable {
    public let kind: ProviderKind
    public let origin: String
    public let clientID: String
    public let clientSecret: String?
    private let transport: HTTPTransport
    private let sleep: @Sendable (Int) async throws -> Void

    public init(
        kind: ProviderKind, origin: String, clientID: String, clientSecret: String? = nil,
        transport: @escaping HTTPTransport = ProviderClient.urlSessionTransport,
        sleep: @escaping @Sendable (Int) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.kind = kind
        self.origin = origin
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.transport = transport
        self.sleep = sleep
    }

    // MARK: Endpoints

    /// Microsoft Entra tenant used for Azure DevOps (work and school accounts).
    static let azureAuthority = "https://login.microsoftonline.com/organizations/oauth2/v2.0"

    var authorizeURL: String {
        switch kind {
        case .gitea: "\(origin)/login/oauth/authorize"
        case .bitbucket: "https://bitbucket.org/site/oauth2/authorize"
        case .azure: "\(Self.azureAuthority)/authorize"
        default: "\(origin)/oauth/authorize"
        }
    }
    var tokenURL: String {
        switch kind {
        case .gitea, .github: "\(origin)/login/oauth/access_token"
        case .bitbucket: "https://bitbucket.org/site/oauth2/access_token"
        case .azure: "\(Self.azureAuthority)/token"
        default: "\(origin)/oauth/token"
        }
    }
    var deviceURL: String { "\(origin)/login/device/code" }

    // MARK: Authorization code + PKCE

    public func authorizationURL(redirectURI: String, state: String, challenge: String) -> URL? {
        var c = URLComponents(string: authorizeURL)
        var items = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "state", value: state),
        ]
        if kind.oauthUsesPKCE {
            items.append(URLQueryItem(name: "code_challenge", value: challenge))
            items.append(URLQueryItem(name: "code_challenge_method", value: "S256"))
        }
        if kind == .azure { items.append(URLQueryItem(name: "response_mode", value: "query")) }
        if !kind.oauthScopes.isEmpty { items.append(URLQueryItem(name: "scope", value: kind.oauthScopes)) }
        c?.queryItems = items
        return c?.url
    }

    public func exchange(code: String, verifier: String, redirectURI: String) async throws -> OAuthTokens {
        var form = ["client_id": clientID, "grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI]
        if kind.oauthUsesPKCE { form["code_verifier"] = verifier }
        if kind == .azure { form["scope"] = kind.oauthScopes }
        return try await tokenRequest(form)
    }

    public func refresh(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        guard let refresh = tokens.refreshToken else { throw OAuthError.expired }
        var form = ["client_id": clientID, "grant_type": "refresh_token", "refresh_token": refresh]
        if kind == .azure { form["scope"] = kind.oauthScopes }
        var fresh = try await tokenRequest(form)
        if fresh.refreshToken == nil { fresh.refreshToken = refresh }
        return fresh
    }

    // MARK: Device flow

    public func startDeviceFlow() async throws -> DeviceCode {
        let json = try await post(deviceURL, ["client_id": clientID, "scope": kind.oauthScopes])
        guard let device = json["device_code"] as? String, let user = json["user_code"] as? String,
              let uri = (json["verification_uri"] as? String).flatMap(URL.init(string:)) else {
            throw OAuthError.server(json["error_description"] as? String ?? "Couldn’t start device sign-in.")
        }
        return DeviceCode(deviceCode: device, userCode: user, verificationURL: uri,
                          interval: json["interval"] as? Int ?? 5, expiresIn: json["expires_in"] as? Int ?? 900)
    }

    /// Polls until the user approves in the browser. Honours `slow_down`; throws on denial or expiry.
    public func pollDeviceFlow(_ device: DeviceCode) async throws -> OAuthTokens {
        var interval = max(device.interval, 1)
        var waited = 0
        while waited <= device.expiresIn {
            try await sleep(interval)
            waited += interval
            let json = try await post(tokenURL, [
                "client_id": clientID, "device_code": device.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            switch json["error"] as? String {
            case nil: return try Self.tokens(from: json)
            case "authorization_pending": continue
            case "slow_down": interval += 5
            case "access_denied": throw OAuthError.denied
            case "expired_token": throw OAuthError.expired
            default: throw OAuthError.server(json["error_description"] as? String ?? "Sign-in failed.")
            }
        }
        throw OAuthError.expired
    }

    // MARK: Plumbing

    private func tokenRequest(_ form: [String: String]) async throws -> OAuthTokens {
        let json = try await post(tokenURL, form)
        if let error = json["error"] as? String {
            throw OAuthError.server(json["error_description"] as? String ?? error)
        }
        var tokens = try Self.tokens(from: json)
        if kind.oauthNeedsClientSecret { tokens.clientSecret = clientSecret }
        return tokens
    }

    static func tokens(from json: [String: Any], now: Date = Date()) throws -> OAuthTokens {
        guard let access = json["access_token"] as? String, !access.isEmpty else { throw OAuthError.invalidResponse }
        let expires = (json["expires_in"] as? Int) ?? (json["expires_in"] as? String).flatMap(Int.init)
        return OAuthTokens(accessToken: access, refreshToken: json["refresh_token"] as? String,
                           expiresAt: expires.map { now.addingTimeInterval(TimeInterval($0)) })
    }

    private func post(_ url: String, _ form: [String: String]) async throws -> [String: Any] {
        guard let u = URL(string: url) else { throw OAuthError.invalidResponse }
        var r = URLRequest(url: u)
        r.httpMethod = "POST"
        r.timeoutInterval = 30
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.setValue("GitWolf", forHTTPHeaderField: "User-Agent")
        if kind.oauthNeedsClientSecret, let clientSecret, !clientSecret.isEmpty {
            let basic = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
            r.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        }
        r.httpBody = Data(Self.encode(form).utf8)
        let (data, _) = try await transport(r)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw OAuthError.invalidResponse }
        return json
    }

    static func encode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.keys.sorted().map { key in
            "\(key)=\(form[key]!.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
    }
}

public extension GitCredential {
    /// The user name git should send with an OAuth access token.
    static func oauthUsername(kind: ProviderKind, fallback: String) -> String {
        switch kind {
        case .gitlab: "oauth2"
        case .github: "x-access-token"
        case .bitbucket: "x-token-auth"
        default: fallback
        }
    }
}
