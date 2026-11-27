import Foundation

public struct Submodule: Identifiable, Hashable, Sendable {
    public enum State: Sendable { case upToDate, notInitialized, modified, conflicted }
    public var path: String
    public var hash: String
    public var state: State
    public var url: String
    public var id: String { path }
}

enum SubmoduleParser {
    /// `git submodule status`: `<flag><sha> <path> (<describe>)`; flag is space, `-`, `+` or `U`.
    static func parse(status: String, urls: [String: String]) -> [Submodule] {
        status.split(separator: "\n").compactMap { raw in
            guard let flag = raw.first else { return nil }
            let rest = raw.dropFirst().split(separator: " ", maxSplits: 1)
            guard rest.count == 2 else { return nil }
            var path = String(rest[1])
            if let paren = path.range(of: " (", options: .backwards), path.hasSuffix(")") { path = String(path[..<paren.lowerBound]) }
            let state: Submodule.State = switch flag {
            case "-": .notInitialized
            case "+": .modified
            case "U": .conflicted
            default: .upToDate
            }
            return Submodule(path: path, hash: String(rest[0]), state: state, url: urls[path] ?? "")
        }
    }

    /// `git config -f .gitmodules --get-regexp ^submodule\..*\.path$` style output → path → url.
    static func urls(paths: String, urls: String) -> [String: String] {
        var nameToPath: [String: String] = [:]
        for line in paths.split(separator: "\n") {
            let p = line.split(separator: " ", maxSplits: 1)
            guard p.count == 2, p[0].hasPrefix("submodule."), p[0].hasSuffix(".path") else { continue }
            nameToPath[String(p[0].dropFirst(10).dropLast(5))] = String(p[1])
        }
        var result: [String: String] = [:]
        for line in urls.split(separator: "\n") {
            let p = line.split(separator: " ", maxSplits: 1)
            guard p.count == 2, p[0].hasPrefix("submodule."), p[0].hasSuffix(".url") else { continue }
            if let path = nameToPath[String(p[0].dropFirst(10).dropLast(4))] { result[path] = String(p[1]) }
        }
        return result
    }
}

public extension GitRepository {
    func submodules() async throws -> [Submodule] {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(".gitmodules").path) else { return [] }
        async let status = git.runString(["submodule", "status"], readOnly: true)
        async let paths = git.runString(["config", "-f", ".gitmodules", "--get-regexp", #"^submodule\..*\.path$"#],
                                        readOnly: true)
        async let urls = git.runString(["config", "-f", ".gitmodules", "--get-regexp", #"^submodule\..*\.url$"#],
                                       readOnly: true)
        let map = SubmoduleParser.urls(paths: (try? await paths) ?? "", urls: (try? await urls) ?? "")
        return SubmoduleParser.parse(status: try await status, urls: map)
    }

    /// Clones and checks out the commits the superproject records (`--init --recursive`). All, or just `path`.
    func updateSubmodules(path: String? = nil) async throws {
        try await networkGit().run(["submodule", "update", "--init", "--recursive"] + (path.map { ["--", $0] } ?? []))
    }

    func addSubmodule(url: String, path: String) async throws {
        guard !url.hasPrefix("-"), !path.hasPrefix("-") else {
            throw GitError(command: "submodule add", exitCode: 1, stderr: "Invalid URL or folder.")
        }
        try await networkGit().run(["submodule", "add", "--", url, path])
    }

    /// Fetches the new commits of every submodule and moves them to the latest on their tracked branch.
    func updateSubmodulesToLatest() async throws {
        try await networkGit().run(["submodule", "update", "--init", "--recursive", "--remote"])
    }
}
