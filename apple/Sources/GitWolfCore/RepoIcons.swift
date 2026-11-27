import Foundation

/// A custom picture for a repository's tile in the rail: a named symbol or an imported image.
/// Pure value types so every platform persists icons the same way (`docs/FEATURES.md`).
public enum RepoIcon: Codable, Equatable, Sendable {
    /// A symbol from the platform's icon set (SF Symbols on macOS), identified by a stable name.
    case symbol(String)
    /// An imported picture, stored by the app as a file with this name in its icon folder.
    case image(String)
}

/// A named colour for a repository's tile. The platform maps each name to its own flat colour.
public enum RepoTint: String, Codable, CaseIterable, Sendable {
    case red, orange, yellow, green, teal, blue, purple, pink, gray
}

/// Which icon and colour each repository uses, keyed by the repository's root path.
public struct RepoIcons: Codable, Equatable, Sendable {
    public private(set) var icons: [String: RepoIcon] = [:]
    /// Tile colours; a repository without one gets a colour derived from its name.
    public private(set) var tints: [String: RepoTint] = [:]

    public init() {}

    // Settings saved before colours existed have no `tints`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        icons = try c.decodeIfPresent([String: RepoIcon].self, forKey: .icons) ?? [:]
        tints = try c.decodeIfPresent([String: RepoTint].self, forKey: .tints) ?? [:]
    }

    public func tint(for path: String) -> RepoTint? { tints[path] }

    public mutating func setTint(_ tint: RepoTint?, for path: String) {
        if let tint { tints[path] = tint } else { tints.removeValue(forKey: path) }
    }

    public func icon(for path: String) -> RepoIcon? { icons[path] }

    /// Sets an icon and returns the image file name it replaced, if any, so the caller can delete it.
    @discardableResult
    public mutating func set(_ icon: RepoIcon?, for path: String) -> String? {
        let old = icons[path]
        if let icon { icons[path] = icon } else { icons.removeValue(forKey: path) }
        if case .image(let name) = old, old != icon { return name }
        return nil
    }

    /// Drops icons for repositories that no longer exist; returns the image files that are now unused.
    public mutating func pruned(keeping exists: (String) -> Bool) -> [String] {
        var unused: [String] = []
        for (path, icon) in icons where !exists(path) {
            if case .image(let name) = icon { unused.append(name) }
            icons.removeValue(forKey: path)
        }
        for path in tints.keys where !exists(path) { tints.removeValue(forKey: path) }
        return unused
    }

    /// The curated symbols offered in the picker, as `(group, names)`.
    public static let symbolChoices: [(String, [String])] = [
        ("Code", ["chevron.left.forwardslash.chevron.right", "terminal", "curlybraces", "hammer", "wrench.and.screwdriver", "cpu", "memorychip", "server.rack", "externaldrive", "network"]),
        ("Apps", ["app", "macwindow", "iphone", "laptopcomputer", "globe", "safari", "doc.text", "book", "paintbrush", "photo"]),
        ("Things", ["star", "heart", "flame", "bolt", "leaf", "moon", "sun.max", "cloud", "snowflake", "drop"]),
        ("Objects", ["shippingbox", "cube", "gearshape", "key", "lock", "flag", "bookmark", "tag", "folder", "briefcase"]),
        ("Fun", ["gamecontroller", "music.note", "camera", "film", "pawprint", "airplane", "car", "paperplane", "sparkles", "lightbulb"])
    ]
}
