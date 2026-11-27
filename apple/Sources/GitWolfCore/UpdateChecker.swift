import Foundation

/// A dotted version such as `1.4.0` or `v2.0.0-beta.1`. Pre-releases sort before their release.
public struct AppVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let numbers: [Int]
    public let prerelease: String?

    public init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let parts = s.split(separator: "-", maxSplits: 1).map(String.init)
        guard let core = parts.first, !core.isEmpty else { return nil }
        let nums = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !nums.isEmpty, nums.allSatisfy({ $0 != nil }) else { return nil }
        numbers = nums.compactMap { $0 }
        prerelease = parts.count > 1 ? parts[1] : nil
    }

    public var description: String { numbers.map(String.init).joined(separator: ".") + (prerelease.map { "-" + $0 } ?? "") }

    /// `2.0` equals `2.0.0`.
    public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        let count = max(a.numbers.count, b.numbers.count)
        for i in 0..<count {
            let x = i < a.numbers.count ? a.numbers[i] : 0, y = i < b.numbers.count ? b.numbers[i] : 0
            if x != y { return x < y }
        }
        switch (a.prerelease, b.prerelease) {
        case (nil, nil): return false
        case (_?, nil): return true
        case (nil, _?): return false
        case (let p?, let q?): return p.compare(q, options: .numeric) == .orderedAscending
        }
    }
}

public struct ReleaseInfo: Equatable, Sendable {
    public let version: AppVersion
    public let tag: String
    public let notes: String
    public let url: URL
}

/// Looks for a newer GitWolf release on GitHub. Read-only, unauthenticated, and sends nothing about
/// the user or their repositories; it never downloads or installs anything.
public struct UpdateChecker: Sendable {
    public let repository: String
    private let transport: HTTPTransport

    public init(repository: String = "ipuppyyt/GitWolf", transport: @escaping HTTPTransport = ProviderClient.urlSessionTransport) {
        self.repository = repository
        self.transport = transport
    }

    /// The latest published (non-draft, non-pre-release) release, if it is newer than `current`.
    public func newerRelease(than current: AppVersion) async throws -> ReleaseInfo? {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("GitWolf", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, response) = try await transport(request)
        if response.statusCode == 404 { return nil } // no releases yet
        guard (200..<300).contains(response.statusCode) else { throw URLError(.badServerResponse) }
        return Self.parse(data).flatMap { $0.version > current ? $0 : nil }
    }

    static func parse(_ data: Data) -> ReleaseInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String, let version = AppVersion(tag),
              (json["draft"] as? Bool) != true, (json["prerelease"] as? Bool) != true,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
              page.scheme == "https", page.host == "github.com"
        else { return nil }
        return ReleaseInfo(version: version, tag: tag, notes: (json["body"] as? String) ?? "", url: page)
    }
}
