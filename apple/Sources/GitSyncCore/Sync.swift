import Foundation

public enum PullStrategy: String, CaseIterable, Sendable {
    /// Merge when histories diverged (the default).
    case merge
    /// Rebase local commits on top of the upstream, stashing local changes around it.
    case rebase
    /// Only move forward; fail if the branch has diverged.
    case fastForwardOnly

    public var title: String {
        switch self {
        case .merge: "Pull (merge)"
        case .rebase: "Pull (rebase)"
        case .fastForwardOnly: "Pull (fast-forward only)"
        }
    }
}

public struct PushOptions: Equatable, Sendable {
    /// Push to this remote instead of the branch's upstream.
    public var remote: String?
    /// `--force-with-lease`: overwrite the remote branch only if nobody pushed since you last fetched.
    public var forceWithLease = false
    public var includeTags = false
    /// Track the remote branch afterwards.
    public var setUpstream = false

    public init(remote: String? = nil, forceWithLease: Bool = false, includeTags: Bool = false, setUpstream: Bool = false) {
        self.remote = remote
        self.forceWithLease = forceWithLease
        self.includeTags = includeTags
        self.setUpstream = setUpstream
    }
}

public extension GitError {
    /// The remote refused a push because it has commits you don't, or your view of it was stale.
    var isPushRejected: Bool {
        let text = stderr
        return text.contains("[rejected]") || text.contains("non-fast-forward") || text.contains("fetch first")
            || text.contains("stale info")
    }

    /// A pull that stopped because the branches diverged and fast-forward was required.
    var isDivergedPull: Bool {
        stderr.contains("Not possible to fast-forward") || stderr.contains("divergent branches")
    }
}

public struct RemoteInfo: Identifiable, Hashable, Sendable {
    public var name: String
    public var fetchURL: String
    public var pushURL: String
    public var id: String { name }
}

public extension GitRepository {
    /// Remotes with their fetch and push URLs. Any password embedded in a URL is hidden.
    func remoteInfos() async throws -> [RemoteInfo] {
        let out = try await git.runString(["remote", "-v"], readOnly: true)
        var fetch: [String: String] = [:], push: [String: String] = [:], order: [String] = []
        for line in out.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
            guard parts.count >= 3 else { continue }
            if !order.contains(parts[0]) { order.append(parts[0]) }
            let url = Self.redact(parts[1])
            if parts[2] == "(fetch)" { fetch[parts[0]] = url } else { push[parts[0]] = url }
        }
        return order.map { RemoteInfo(name: $0, fetchURL: fetch[$0] ?? "", pushURL: push[$0] ?? fetch[$0] ?? "") }
    }

    /// `https://user:secret@host/x` becomes `https://user@host/x`.
    static func redact(_ url: String) -> String {
        guard let parsed = URL(string: url), parsed.password != nil, var c = URLComponents(url: parsed, resolvingAgainstBaseURL: false) else { return url }
        c.password = nil
        return c.string ?? url
    }

    private func validate(name: String? = nil, url: String? = nil) throws {
        if let name {
            guard !name.isEmpty, !name.hasPrefix("-"), !name.contains(where: \.isWhitespace) else {
                throw GitError(command: "remote", exitCode: 1, stderr: "“\(name)” isn’t a valid remote name.")
            }
        }
        if let url {
            let trimmed = url.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else {
                throw GitError(command: "remote", exitCode: 1, stderr: "Enter the remote’s URL.")
            }
            // Secrets never go into URLs: they would end up in .git/config in plain text.
            if let parsed = URL(string: trimmed), parsed.password != nil {
                throw GitError(command: "remote", exitCode: 1, stderr: "Don’t put a password in the URL. Connect an account in Settings → Accounts instead.")
            }
        }
    }

    func addRemote(_ name: String, url: String) async throws {
        try validate(name: name, url: url)
        try await git.run(["remote", "add", name, url.trimmingCharacters(in: .whitespaces)])
    }

    func removeRemote(_ name: String) async throws {
        try validate(name: name)
        try await git.run(["remote", "remove", name])
    }

    func renameRemote(_ old: String, to new: String) async throws {
        try validate(name: old)
        try validate(name: new)
        try await git.run(["remote", "rename", old, new])
    }

    func setRemoteURL(_ name: String, url: String) async throws {
        try validate(name: name, url: url)
        try await git.run(["remote", "set-url", name, url.trimmingCharacters(in: .whitespaces)])
    }
}
