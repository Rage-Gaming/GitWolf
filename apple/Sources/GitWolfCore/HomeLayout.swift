import Foundation

/// How the home screen organises repositories: a pinned list plus named groups.
/// Paths are repository root paths. Pure value type so every platform can persist it the same way.
public struct HomeLayout: Codable, Equatable, Sendable {
    public struct Group: Codable, Equatable, Sendable, Identifiable {
        public var id: UUID
        public var name: String
        public var paths: [String]
        public init(id: UUID = UUID(), name: String, paths: [String] = []) {
            self.id = id; self.name = name; self.paths = paths
        }
    }

    public private(set) var pinned: [String] = []
    public private(set) var groups: [Group] = []

    public init() {}

    public func isPinned(_ path: String) -> Bool { pinned.contains(path) }
    public func groupIDs(containing path: String) -> [UUID] { groups.filter { $0.paths.contains(path) }.map(\.id) }

    public mutating func togglePin(_ path: String) {
        if let i = pinned.firstIndex(of: path) { pinned.remove(at: i) } else { pinned.append(path) }
    }

    /// Creates a group (names are trimmed; blank names are ignored). Returns its id.
    @discardableResult
    public mutating func addGroup(named name: String, paths: [String] = []) -> UUID? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let group = Group(name: name, paths: paths)
        groups.append(group)
        return group.id
    }

    public mutating func renameGroup(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let i = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[i].name = name
    }

    public mutating func deleteGroup(_ id: UUID) { groups.removeAll { $0.id == id } }

    public mutating func toggle(_ path: String, inGroup id: UUID) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        if let j = groups[i].paths.firstIndex(of: path) { groups[i].paths.remove(at: j) } else { groups[i].paths.append(path) }
    }

    /// Forgets a repository everywhere (pins and groups).
    public mutating func remove(_ path: String) {
        pinned.removeAll { $0 == path }
        for i in groups.indices { groups[i].paths.removeAll { $0 == path } }
    }

    /// Drops paths for which `exists` is false, e.g. folders deleted since last launch.
    public func pruned(keeping exists: (String) -> Bool) -> HomeLayout {
        var copy = self
        copy.pinned = pinned.filter(exists)
        for i in copy.groups.indices { copy.groups[i].paths = copy.groups[i].paths.filter(exists) }
        return copy
    }
}
