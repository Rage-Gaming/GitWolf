import Foundation

/// How much of a repository to download when cloning.
public struct CloneOptions: Equatable, Sendable {
    public enum Filter: String, CaseIterable, Sendable {
        case full
        /// `--filter=blob:none`: history and trees now, file contents when needed.
        case blobless
        /// `--filter=tree:0`: commits only; the smallest and slowest to browse.
        case treeless
    }

    /// Only the latest N commits (`--depth`). nil = full history.
    public var depth: Int?
    public var filter: Filter = .full
    public var singleBranch = false
    /// Clone a branch other than the remote's default.
    public var branch: String?
    public var recurseSubmodules = false

    public init(depth: Int? = nil, filter: Filter = .full, singleBranch: Bool = false,
                branch: String? = nil, recurseSubmodules: Bool = false) {
        self.depth = depth
        self.filter = filter
        self.singleBranch = singleBranch
        self.branch = branch
        self.recurseSubmodules = recurseSubmodules
    }

    public var arguments: [String] {
        var args: [String] = []
        if let depth, depth > 0 { args += ["--depth", String(depth)] }
        switch filter {
        case .full: break
        case .blobless: args.append("--filter=blob:none")
        case .treeless: args.append("--filter=tree:0")
        }
        if singleBranch { args.append("--single-branch") }
        if let branch = branch?.trimmingCharacters(in: .whitespaces), !branch.isEmpty, !branch.hasPrefix("-") {
            args += ["--branch", branch]
        }
        if recurseSubmodules { args.append("--recurse-submodules") }
        return args
    }
}

public extension GitRepository {
    /// True for a shallow clone (history cut off at some depth).
    func isShallow() async -> Bool {
        (try? await git.runString(["rev-parse", "--is-shallow-repository"], readOnly: true))?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// Downloads the rest of the history of a shallow clone.
    func unshallow() async throws {
        try await networkGit().run(["fetch", "--unshallow", "--prune"])
    }
}
