import Foundation

public enum CheckState: String, Sendable, Comparable {
    case success, pending, failure, neutral

    private var rank: Int {
        switch self {
        case .failure: 3
        case .pending: 2
        case .success: 1
        case .neutral: 0
        }
    }
    public static func < (a: CheckState, b: CheckState) -> Bool { a.rank < b.rank }
}

public struct CICheck: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var state: CheckState
    public var url: URL?
}

/// All CI checks reported for one commit, plus the overall result.
public struct CIStatus: Equatable, Sendable {
    public var checks: [CICheck]

    public init(checks: [CICheck]) { self.checks = checks }

    public var isEmpty: Bool { checks.isEmpty }

    /// Worst state wins: any failure fails it, otherwise anything pending, otherwise success.
    public var overall: CheckState? {
        checks.map(\.state).filter { $0 != .neutral }.max() ?? (checks.isEmpty ? nil : .neutral)
    }

    public var summary: String {
        guard !checks.isEmpty else { return "No checks" }
        let failed = checks.filter { $0.state == .failure }.count
        let pending = checks.filter { $0.state == .pending }.count
        if failed > 0 { return "\(failed) of \(checks.count) checks failed" }
        if pending > 0 { return "\(pending) of \(checks.count) checks running" }
        return "All \(checks.count) checks passed"
    }
}

public extension ProviderKind {
    var supportsChecks: Bool { self != .azure }
}

public extension ProviderClient {
    /// CI checks for a commit: GitHub check runs and commit statuses, GitLab pipeline jobs, Gitea and Bitbucket statuses.
    func ciStatus(repoPath: String, sha: String) async throws -> CIStatus {
        guard !sha.isEmpty, sha.allSatisfy(\.isHexDigit) else { return CIStatus(checks: []) }
        var checks: [CICheck] = []
        switch account.kind {
        case .github:
            let (runs, _) = try await fetch("\(apiBase)/repos/\(repoPath)/commits/\(sha)/check-runs?per_page=100")
            checks += try Self.parseGitHubCheckRuns(runs)
            // Older integrations report through the commit status API instead.
            if let (statuses, _) = try? await fetch("\(apiBase)/repos/\(repoPath)/commits/\(sha)/status?per_page=100") {
                checks += (try? Self.parseStatuses(statuses, list: "statuses", name: "context", state: "state", url: "target_url")) ?? []
            }
        case .gitlab:
            let (data, _) = try await fetch("\(apiBase)/projects/\(Self.gitlabProjectID(repoPath))/repository/commits/\(sha)/statuses?per_page=100")
            checks = try Self.parseStatusArray(data, name: "name", state: "status", url: "target_url")
        case .gitea:
            let (data, _) = try await fetch("\(apiBase)/repos/\(repoPath)/commits/\(sha)/status")
            checks = try Self.parseStatuses(data, list: "statuses", name: "context", state: "status", url: "target_url")
        case .bitbucket where account.host == "bitbucket.org":
            let (data, _) = try await fetch("\(apiBase)/repositories/\(repoPath)/commit/\(sha)/statuses?pagelen=100")
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let values = root["values"] as? [[String: Any]] else {
                throw ProviderError.invalidResponse
            }
            checks = values.compactMap { r in
                guard let name = r["name"] as? String ?? r["key"] as? String else { return nil }
                return CICheck(name: name, state: Self.checkState(r["state"] as? String), url: (r["url"] as? String).flatMap(URL.init(string:)))
            }
        default:
            throw ProviderError.unsupported("CI status isn’t available for \(account.kind.title).")
        }
        // The same job can be reported more than once (re-runs); keep the latest of each name.
        var seen = Set<String>()
        let unique = checks.filter { seen.insert($0.name).inserted }
        return CIStatus(checks: unique.sorted { ($0.state, $1.name) > ($1.state, $0.name) })
    }

    /// Maps each provider's wording onto four states.
    static func checkState(_ raw: String?) -> CheckState {
        switch (raw ?? "").lowercased() {
        case "success", "successful", "passed", "completed": .success
        case "failure", "failed", "error", "timed_out", "action_required", "startup_failure", "stopped": .failure
        case "pending", "running", "in_progress", "inprogress", "queued", "created", "waiting_for_resource", "preparing", "scheduled", "manual", "warning": .pending
        default: .neutral
        }
    }

    static func parseGitHubCheckRuns(_ data: Data) throws -> [CICheck] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runs = root["check_runs"] as? [[String: Any]] else { throw ProviderError.invalidResponse }
        return runs.compactMap { r in
            guard let name = r["name"] as? String else { return nil }
            let state: CheckState
            if r["status"] as? String != "completed" {
                state = .pending
            } else {
                switch r["conclusion"] as? String {
                case "success": state = .success
                case "skipped", "neutral": state = .neutral
                case "cancelled", "failure", "timed_out", "action_required", "startup_failure", "stale": state = .failure
                default: state = .neutral
                }
            }
            return CICheck(name: name, state: state, url: (r["html_url"] as? String).flatMap(URL.init(string:)))
        }
    }

    static func parseStatuses(_ data: Data, list: String, name: String, state: String, url: String) throws -> [CICheck] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root[list] as? [[String: Any]] else { throw ProviderError.invalidResponse }
        return items.compactMap { r in
            guard let n = r[name] as? String else { return nil }
            return CICheck(name: n, state: checkState(r[state] as? String), url: (r[url] as? String).flatMap(URL.init(string:)))
        }
    }

    static func parseStatusArray(_ data: Data, name: String, state: String, url: String) throws -> [CICheck] {
        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw ProviderError.invalidResponse }
        return items.compactMap { r in
            guard let n = r[name] as? String else { return nil }
            return CICheck(name: n, state: checkState(r[state] as? String), url: (r[url] as? String).flatMap(URL.init(string:)))
        }
    }
}
