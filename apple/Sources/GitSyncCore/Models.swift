import Foundation

// MARK: - Commits

public struct RefLabel: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case head, local, remote, tag }
    public var name: String
    public var kind: Kind
    /// True for the branch HEAD currently points at.
    public var isCurrent: Bool
}

public struct Commit: Identifiable, Hashable, Sendable {
    public var id: String { hash }
    public var hash: String
    public var parents: [String]
    public var authorName: String
    public var authorEmail: String
    public var date: Date
    public var subject: String
    public var refs: [RefLabel]

    public var shortHash: String { String(hash.prefix(7)) }
    public var isMerge: Bool { parents.count > 1 }
}

// MARK: - Working tree

public enum ChangeKind: Character, Hashable, Sendable {
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case typeChanged = "T"
    case untracked = "?"
    case unmerged = "U"

    init(code: Character) {
        self = ChangeKind(rawValue: code) ?? .modified
    }
}

public struct FileChange: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var path: String
    public var originalPath: String?
    public var kind: ChangeKind

    public var fileName: String { (path as NSString).lastPathComponent }
    public var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir
    }
}

public struct WorkingStatus: Equatable, Sendable {
    public var branch: String?
    public var headOID: String?
    public var upstream: String?
    public var ahead: Int = 0
    public var behind: Int = 0
    public var staged: [FileChange] = []
    public var unstaged: [FileChange] = []
    public var untracked: [FileChange] = []
    public var conflicted: [FileChange] = []

    public static let empty = WorkingStatus()

    public var isDetached: Bool { branch == nil && headOID != nil }
    public var isUnborn: Bool { headOID == nil }
    public var isClean: Bool { changeCount == 0 }
    public var changeCount: Int {
        staged.count + unstaged.count + untracked.count + conflicted.count
    }
    public var branchDisplay: String {
        if let branch { return branch }
        if let headOID { return "detached @ \(headOID.prefix(7))" }
        return "no commits yet"
    }
}

// MARK: - Refs

public struct Branch: Identifiable, Hashable, Sendable {
    public var id: String { fullRef }
    public var name: String
    public var fullRef: String
    public var isRemote: Bool
    public var isCurrent: Bool
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    public var hash: String
    /// The upstream branch was deleted on the remote (`[gone]`).
    public var upstreamGone: Bool = false

    /// `origin` for `refs/remotes/origin/main`.
    public var remote: String? {
        guard isRemote else { return nil }
        return fullRef.dropFirst("refs/remotes/".count).split(separator: "/").first.map(String.init)
    }
    /// Branch name without the remote prefix.
    public var shortName: String {
        guard let remote else { return name }
        return String(name.dropFirst(remote.count + 1))
    }
}

public struct GitTag: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var hash: String
}

public struct Stash: Identifiable, Hashable, Sendable {
    public var id: String { ref }
    public var ref: String
    public var message: String
    public var date: Date
}

// MARK: - Diffs

public struct DiffLine: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case context, addition, deletion, hunkHeader, note }
    /// Index into `FileDiff.lines`.
    public var id: Int
    public var kind: Kind
    public var hunkIndex: Int
    public var oldNumber: Int?
    public var newNumber: Int?
    /// Display text (trailing CR removed).
    public var text: String
    /// Exact content as git emitted it (CR kept), used to build patches.
    public var raw: String

    public var isChange: Bool { kind == .addition || kind == .deletion }
}

public struct DiffHunk: Hashable, Sendable {
    public var index: Int
    public var oldStart: Int
    public var newStart: Int
    /// Text after the closing `@@` (usually the enclosing function), including its leading space.
    public var section: String
}

public struct FileDiff: Equatable, Sendable {
    /// Lines before the first hunk (`diff --git`, `index`, `---`, `+++`).
    public var header: [String]
    public var hunks: [DiffHunk]
    public var lines: [DiffLine]
    public var isBinary: Bool
    public var additions: Int
    public var deletions: Int
    public var isTruncated: Bool

    public static let empty = FileDiff(
        header: [], hunks: [], lines: [], isBinary: false, additions: 0, deletions: 0, isTruncated: false)

    /// Whether hunks/lines of this diff can safely be turned back into a patch.
    public var canPatch: Bool {
        !isBinary && !isTruncated && !hunks.isEmpty && !header.isEmpty
            && !lines.contains { $0.raw.contains("\u{FFFD}") }
    }

    public func changedLineIDs(inHunk index: Int) -> Set<Int> {
        Set(lines.filter { $0.hunkIndex == index && $0.isChange }.map(\.id))
    }
}

public struct DiffTarget: Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        case staged, unstaged, untracked, conflicted
        case commit(String)
        /// Everything between two commits (resolved hashes), as in `git diff base head`.
        case compare(base: String, head: String)
    }
    public var source: Source
    public var path: String
    public var originalPath: String?

    public init(source: Source, path: String, originalPath: String? = nil) {
        self.source = source
        self.path = path
        self.originalPath = originalPath
    }
}

// MARK: - Snapshot

/// Everything the UI needs, captured in one pass so views never see a half-updated repository.
public struct RepositorySnapshot: Equatable, Sendable {
    public var status: WorkingStatus
    public var commits: [Commit]
    public var graph: [GraphRow]
    public var localBranches: [Branch]
    public var remoteBranches: [Branch]
    public var tags: [GitTag]
    public var stashes: [Stash]
    public var remotes: [String]
    public var operation: InProgressOperation?

    public static let empty = RepositorySnapshot(
        status: .empty, commits: [], graph: [], localBranches: [], remoteBranches: [],
        tags: [], stashes: [], remotes: [], operation: nil)
}
