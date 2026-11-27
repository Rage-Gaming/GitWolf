import Foundation

public extension ProviderKind {
    var supportsForking: Bool { self != .azure }
}

public extension ProviderClient {
    /// Forks the repository into your account (or returns the existing fork) and gives its clone URLs.
    /// GitHub finishes the copy in the background, so a fetch right away can take a few seconds to work.
    func fork(repoPath: String) async throws -> RemoteRepository {
        let data: Data
        let parsed: [RemoteRepository]
        switch account.kind {
        case .github:
            (data, _) = try await send("POST", "\(apiBase)/repos/\(repoPath)/forks", json: [:])
            parsed = try Self.parseGitHub(Self.arrayOf(data))
        case .gitea:
            (data, _) = try await send("POST", "\(apiBase)/repos/\(repoPath)/forks", json: [:])
            parsed = try Self.parseGitea(Self.arrayOf(data))
        case .gitlab:
            (data, _) = try await send("POST", "\(apiBase)/projects/\(Self.gitlabProjectID(repoPath))/fork", json: [:])
            parsed = try Self.parseGitLab(Self.arrayOf(data))
        case .bitbucket where account.host == "bitbucket.org":
            (data, _) = try await send("POST", "\(apiBase)/repositories/\(repoPath)/forks", json: [:])
            parsed = try Self.parseBitbucket(Self.valuesOf(data))
        case .bitbucket, .azure:
            throw ProviderError.unsupported("Forking isn’t supported for \(account.kind.title) here.")
        }
        guard let fork = parsed.first else { throw ProviderError.invalidResponse }
        return fork
    }

    private static func arrayOf(_ data: Data) throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProviderError.invalidResponse }
        return try JSONSerialization.data(withJSONObject: [object])
    }

    private static func valuesOf(_ data: Data) throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProviderError.invalidResponse }
        return try JSONSerialization.data(withJSONObject: ["values": [object]])
    }
}

/// What to do with a fork once it exists.
public enum ForkRemoteMode: Sendable, Equatable {
    /// Add the fork as an extra remote with this name; `origin` stays as it is.
    case addRemote(String)
    /// The usual contribution setup: the original becomes `upstream`, the fork becomes `origin`.
    case useAsOrigin
}

public extension GitRepository {
    /// URL of a remote, if it exists.
    func remoteURL(_ name: String) async -> String? {
        try? await git.runString(["remote", "get-url", name], readOnly: true).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Points this repository at a fork, using SSH when the current remote does, otherwise HTTPS, then fetches it.
    /// - Parameter fetch: pass `false` to only rewire the remotes (the caller fetches, for example with a retry).
    /// - Returns: the name of the remote that now points at the fork.
    @discardableResult
    func adoptFork(_ fork: RemoteRepository, mode: ForkRemoteMode, fetch shouldFetch: Bool = true) async throws -> String {
        let current = await remoteURL("origin") ?? ""
        let usesSSH = current.hasPrefix("git@") || current.hasPrefix("ssh://")
        let url = usesSSH && !fork.sshURL.isEmpty ? fork.sshURL : fork.httpsURL
        guard !url.isEmpty, !url.hasPrefix("-") else { throw ProviderError.invalidResponse }
        let remote: String
        switch mode {
        case .addRemote(let name):
            guard !name.isEmpty, !name.hasPrefix("-"), !name.contains(where: \.isWhitespace) else {
                throw GitError(command: "remote add", exitCode: 1, stderr: "“\(name)” isn’t a valid remote name.")
            }
            try await git.run(["remote", "add", name, url])
            remote = name
        case .useAsOrigin:
            let names = (try? await remotes()) ?? []
            if names.contains("upstream") {
                throw GitError(command: "remote rename", exitCode: 1, stderr: "A remote named “upstream” already exists. Use “Add as a remote” instead.")
            }
            try await git.run(["remote", "rename", "origin", "upstream"])
            try await git.run(["remote", "add", "origin", url])
            remote = "origin"
        }
        if shouldFetch { try await fetch(remote: remote) }
        return remote
    }
}
