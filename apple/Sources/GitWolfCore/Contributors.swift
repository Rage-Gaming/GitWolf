import Foundation

/// A person who has contributed to GitWolf, as listed by GitHub's public contributors endpoint.
public struct Contributor: Codable, Identifiable, Equatable, Sendable {
    public var login: String
    public var avatarURL: URL?
    public var profileURL: URL?
    public var contributions: Int
    public var id: String { login }

    public init(login: String, avatarURL: URL? = nil, profileURL: URL? = nil, contributions: Int = 0) {
        self.login = login
        self.avatarURL = avatarURL
        self.profileURL = profileURL
        self.contributions = contributions
    }
}

public enum Contributors {
    public static let repository = "ipuppyyt/GitWolf"
    /// The project's owner, always listed (and shown as the maintainer) even when the lookup fails.
    public static let maintainer = "ipuppyyt"
    public static let apiURL = URL(string: "https://api.github.com/repos/\(repository)/contributors?per_page=100")!

    /// What is shown with no network and nothing cached.
    public static var fallback: [Contributor] {
        [Contributor(login: maintainer, avatarURL: URL(string: "https://github.com/\(maintainer).png"),
                     profileURL: URL(string: "https://github.com/\(maintainer)"))]
    }

    /// Reads GitHub's response. Bots are left out, people are sorted by contributions then name, and the
    /// maintainer is always present.
    public static func parse(_ data: Data) -> [Contributor] {
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return fallback }
        var people: [Contributor] = items.compactMap { item in
            guard let login = item["login"] as? String, (item["type"] as? String) != "Bot", !login.hasSuffix("[bot]") else { return nil }
            return Contributor(login: login,
                               avatarURL: (item["avatar_url"] as? String).flatMap(URL.init(string:)),
                               profileURL: (item["html_url"] as? String).flatMap(URL.init(string:)),
                               contributions: item["contributions"] as? Int ?? 0)
        }
        if !people.contains(where: { $0.login.lowercased() == maintainer }) { people.append(contentsOf: fallback) }
        return people.sorted {
            $0.contributions != $1.contributions ? $0.contributions > $1.contributions
                : $0.login.localizedCaseInsensitiveCompare($1.login) == .orderedAscending
        }
    }

    public static func isMaintainer(_ person: Contributor) -> Bool { person.login.lowercased() == maintainer }
}
