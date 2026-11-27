import Foundation

/// A commit that a Git hook (pre-commit, commit-msg…) refused, with everything the hook printed.
public struct HookFailedError: Error, LocalizedError, Sendable, Equatable {
    public var hook: String
    public var output: String

    public init(hook: String, output: String) {
        self.hook = hook
        self.output = output
    }

    public var errorDescription: String? { "The \(hook) hook failed.\n\n\(output)" }
}

public enum HookDiagnosis {
    /// Commit hooks that can stop a commit, in the order git runs them.
    public static let blockingHooks = ["pre-commit", "prepare-commit-msg", "commit-msg"]

    /// Messages git itself prints when a commit fails for reasons unrelated to hooks.
    private static let nativeFailures = [
        "nothing to commit", "no changes added to commit", "nothing added to commit", "Author identity unknown",
        "empty ident name", "Aborting commit due to empty commit message", "gpg failed to sign", "failed to write commit object",
        "cannot do a partial commit during a merge", "unable to create", "unmerged files", "You are in the middle of",
    ]

    /// Decides whether a failed commit was a hook's doing. `activeHooks` are the executable hooks that exist.
    public static func diagnose(stderr: String, activeHooks: [String]) -> HookFailedError? {
        let output = clean(stderr)
        guard !output.isEmpty else { return nil }
        if nativeFailures.contains(where: { output.localizedCaseInsensitiveContains($0) }) { return nil }
        guard let hook = blockingHooks.first(where: activeHooks.contains) else { return nil }
        return HookFailedError(hook: hook, output: output)
    }

    /// Removes terminal colour codes so hook output reads cleanly.
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public extension GitRepository {
    /// Names of executable hooks present in the repository's hooks directory (honours `core.hooksPath`).
    func activeHooks() async -> [String] {
        guard let path = try? await git.runString(["rev-parse", "--git-path", "hooks"], readOnly: true)
            .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return [] }
        let dir = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { !$0.hasSuffix(".sample") && FileManager.default.isExecutableFile(atPath: dir.appendingPathComponent($0).path) }
    }
}
