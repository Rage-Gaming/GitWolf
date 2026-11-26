import Foundation

public enum BisectMark: String, Sendable { case good, bad, skip }

/// Where a bisect session stands.
public struct BisectState: Equatable, Sendable {
    public var isActive = false
    /// Commits marked so far, oldest mark first.
    public var marks: [(hash: String, mark: BisectMark)] = []
    /// Set once git has narrowed it down to one commit.
    public var firstBad: String?
    /// Git's own estimate, e.g. "3 revisions left to test (roughly 2 steps)".
    public var progress: String?

    public static func == (a: BisectState, b: BisectState) -> Bool {
        a.isActive == b.isActive && a.firstBad == b.firstBad && a.progress == b.progress
            && a.marks.map(\.hash) == b.marks.map(\.hash) && a.marks.map(\.mark) == b.marks.map(\.mark)
    }

    public init() {}
}

enum BisectParser {
    /// Reads `BISECT_LOG`: `git bisect bad <hash>` / `good` / `skip` lines, and the
    /// `# first bad commit: [hash] subject` comment git writes once it is done.
    static func parse(log: String) -> BisectState {
        var state = BisectState()
        state.isActive = true
        for line in log.split(separator: "\n") {
            if line.hasPrefix("# first bad commit: ["), let end = line.firstIndex(of: "]") {
                state.firstBad = String(line[line.index(line.startIndex, offsetBy: "# first bad commit: [".count)..<end])
                continue
            }
            let parts = line.split(separator: " ")
            guard parts.count == 4, parts[0] == "git", parts[1] == "bisect",
                  let mark = BisectMark(rawValue: String(parts[2])) else { continue }
            state.marks.append((String(parts[3]), mark))
        }
        return state
    }

    /// "Bisecting: 3 revisions left to test after this (roughly 2 steps)" → the part after the colon.
    static func progress(from output: String) -> String? {
        output.split(separator: "\n").first { $0.hasPrefix("Bisecting:") }
            .map { String($0.dropFirst("Bisecting:".count)).trimmingCharacters(in: .whitespaces) }
    }
}

public extension GitRepository {
    private var bisectLogURL: URL { OperationDetector.gitDirectory(root: root).appendingPathComponent("BISECT_LOG") }

    func bisectState() -> BisectState {
        guard let log = try? String(contentsOf: bisectLogURL, encoding: .utf8) else { return BisectState() }
        return BisectParser.parse(log: log)
    }

    /// Starts a session with a known bad and good commit; git checks out the first commit to test.
    @discardableResult
    func bisectStart(bad: String, good: String) async throws -> BisectState {
        let out = try await git.runString(["bisect", "start", bad, good, "--"])
        var state = bisectState()
        state.progress = BisectParser.progress(from: out)
        return state
    }

    /// Marks the commit being tested (HEAD) good, bad or skipped, or an explicit `hash`.
    @discardableResult
    func bisectMark(_ mark: BisectMark, hash: String? = nil) async throws -> BisectState {
        let out = try await git.runString(["bisect", mark.rawValue] + (hash.map { [$0] } ?? []))
        var state = bisectState()
        state.progress = BisectParser.progress(from: out)
        return state
    }

    /// Ends the session and returns to the branch you started on.
    func bisectReset() async throws { try await git.run(["bisect", "reset"]) }
}
