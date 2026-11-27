import Foundation

/// What a Git LFS pointer file says: the real file lives on the LFS server, keyed by hash.
public struct LFSPointer: Equatable, Sendable {
    public var oid: String
    public var size: Int64

    public var sizeDescription: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }

    /// Parses pointer text (`version https://git-lfs.github.com/spec/v1`, `oid sha256:…`, `size N`).
    public static func parse(_ text: String) -> LFSPointer? {
        guard text.hasPrefix("version https://git-lfs.github.com/spec/v1") else { return nil }
        var oid: String?, size: Int64?
        for line in text.split(separator: "\n") {
            if line.hasPrefix("oid sha256:") { oid = String(line.dropFirst("oid sha256:".count)) }
            else if line.hasPrefix("size ") { size = Int64(line.dropFirst(5)) }
        }
        guard let oid, let size else { return nil }
        return LFSPointer(oid: oid, size: size)
    }
}

public extension GitRepository {
    /// Which of `paths` are stored with Git LFS, judged by `.gitattributes` (`filter=lfs`).
    /// Works without git-lfs installed.
    func lfsPaths(among paths: [String]) async -> Set<String> {
        guard !paths.isEmpty else { return [] }
        let input = Data((paths.joined(separator: "\0") + "\0").utf8)
        guard let data = try? await git.run(["check-attr", "-z", "--stdin", "filter"], readOnly: true, input: input)
        else { return [] }
        // Output: path NUL attribute NUL value NUL, repeated.
        let parts = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var result: Set<String> = []
        var i = 0
        while i + 2 < parts.count {
            if parts[i + 2] == "lfs" { result.insert(parts[i]) }
            i += 3
        }
        return result
    }

    /// Whether the git-lfs extension is installed (needed to download or upload the real files).
    func lfsInstalled() async -> Bool {
        (try? await git.run(["lfs", "version"], readOnly: true)) != nil
    }

    /// Pointer details when the working-tree or committed content at `revision:path` is an LFS pointer.
    func lfsPointer(path: String, revision: String = "HEAD") async -> LFSPointer? {
        guard let text = try? await git.runString(["show", "\(revision):\(path)"], readOnly: true),
              text.utf8.count < 1024 else { return nil }
        return LFSPointer.parse(text)
    }
}
