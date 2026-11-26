import Foundation

public extension GitRepository {
    /// Writes one `.patch` file (mbox format, with the author and message) per commit into `directory`.
    /// `revisions` are commit hashes; the files are numbered in the order given.
    func formatPatches(commits revisions: [String], into directory: URL) async throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [URL] = []
        for (i, rev) in revisions.enumerated() {
            let out = try await git.runString(
                ["format-patch", "-1", "--start-number", String(i + 1), "-o", directory.path, rev])
            written += out.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
        }
        return written
    }

    /// A plain diff of your uncommitted work as patch text (staged changes only, or everything tracked).
    func workingPatch(stagedOnly: Bool) async throws -> String {
        try await git.runString(["diff", "--binary"] + (stagedOnly ? ["--cached"] : ["HEAD"]))
    }

    /// Whether `git apply` would accept the patch, with git's complaint when it would not.
    func checkPatch(_ file: URL) async -> String? {
        do { try await git.run(["apply", "--check", "--", file.path]); return nil } catch {
            return error.localizedDescription
        }
    }

    /// Applies a patch to the working tree (and the index when `stage` is true) without committing.
    func applyPatchFile(_ file: URL, stage: Bool) async throws {
        try await git.run(["apply"] + (stage ? ["--index"] : []) + ["--", file.path])
    }

    /// Applies mailbox patches as commits, keeping author and message. Stops on conflict, leaving an
    /// "applying patches" operation to continue, skip or abort.
    func applyMailbox(_ files: [URL]) async throws {
        try await git.run(["am", "--3way", "--"] + files.map(\.path))
    }
}
