import Foundation

/// Finds Git repositories under a folder, so a new user can open many at once instead of one by one.
public enum RepositoryScanner {
    private static let skipped: Set<String> = ["node_modules", "Library", "Pods", "build", "DerivedData", "vendor", "target"]

    /// Folders under `root` (to `maxDepth` levels below it) that hold a repository: a `.git` folder, or a `.git` file as
    /// in a worktree or submodule. A repository's own subfolders are not searched. Hidden folders and the usual build
    /// and dependency folders are skipped. Sorted by name; stops after `limit`.
    public static func find(in root: URL, maxDepth: Int = 2, limit: Int = 100) -> [URL] {
        var found: [URL] = []
        let fm = FileManager.default
        func visit(_ folder: URL, depth: Int) {
            guard found.count < limit else { return }
            if fm.fileExists(atPath: folder.appendingPathComponent(".git").path) {
                found.append(folder)
                return
            }
            guard depth < maxDepth,
                  let children = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                             options: [.skipsHiddenFiles]) else { return }
            for child in children.sorted(by: { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }) {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true, !skipped.contains(child.lastPathComponent) else { continue }
                visit(child, depth: depth + 1)
            }
        }
        visit(root, depth: 0)
        return found
    }
}
