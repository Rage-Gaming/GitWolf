import AppKit
import GitSyncCore
import SwiftUI

/// Bisect, patches, worktrees, submodules and shallow clones, as store actions.
extension RepositoryStore {
    // MARK: Bisect

    /// Marks a commit during a bisect, or picks the first two commits (bad, good) to start one.
    func bisectMarkCommit(_ mark: BisectMark, hash: String) {
        if bisect.isActive {
            perform("Bisecting…") { [self] repo in
                let state = try await repo.bisectMark(mark, hash: hash)
                await MainActor.run { bisectProgress = state.progress }
            }
            return
        }
        switch mark {
        case .bad: bisectBad = hash
        case .good: bisectGood = hash
        case .skip: return
        }
        guard let bad = bisectBad, let good = bisectGood else { return }
        bisectBad = nil; bisectGood = nil
        perform("Starting bisect…") { [self] repo in
            let state = try await repo.bisectStart(bad: bad, good: good)
            await MainActor.run { bisectProgress = state.progress }
        }
    }

    /// Marks the commit currently checked out for testing.
    func bisectMarkCurrent(_ mark: BisectMark) {
        perform("Bisecting…") { [self] repo in
            let state = try await repo.bisectMark(mark)
            await MainActor.run { bisectProgress = state.progress }
        }
    }

    func stopBisect() {
        bisectBad = nil; bisectGood = nil; bisectProgress = nil
        guard bisect.isActive else { return }
        perform("Ending bisect…") { try await $0.bisectReset() }
    }

    // MARK: Patches

    /// Saves each commit as a `.patch` file (author and message included) in a folder you choose.
    func exportPatch(of commits: [String]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Choose a folder for the patch file"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task {
            do {
                let files = try await repo.formatPatches(commits: commits, into: folder)
                NSWorkspace.shared.activateFileViewerSelecting(files)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    /// Saves your uncommitted changes to tracked files as a patch file.
    func createPatchFromChanges() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "changes.patch"
        panel.message = "Save your uncommitted changes (to tracked files) as a patch"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let text = try await repo.workingPatch(stagedOnly: false)
                guard !text.isEmpty else { errorMessage = "There are no changes to save."; return }
                try text.write(to: url, atomically: true, encoding: .utf8)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch { errorMessage = error.localizedDescription }
        }
    }

    /// Applies one or more patch files: as commits (for mailbox patches) or to your working tree.
    func applyPatches() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose patch files (.patch or .diff)"
        panel.prompt = "Apply"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let files = panel.urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
        Task {
            if let problem = await firstPatchProblem(files) { errorMessage = problem; return }
            let isMailbox = files.allSatisfy {
                (try? String(contentsOf: $0, encoding: .utf8))?.hasPrefix("From ") == true
            }
            let alert = NSAlert()
            alert.messageText = files.count == 1 ? "Apply “\(files[0].lastPathComponent)”?" : "Apply \(files.count) patches?"
            alert.informativeText = isMailbox
                ? "These patches keep their author and message. Apply them as commits, or only change your files."
                : "Apply the changes to your files. They can be staged too."
            if isMailbox { alert.addButton(withTitle: "Apply as Commits") }
            alert.addButton(withTitle: "Apply and Stage")
            alert.addButton(withTitle: "Apply")
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            let buttons = isMailbox ? 4 : 3
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            guard index < buttons - 1 else { return }
            let mode = isMailbox ? index : index + 1   // 0 commits, 1 stage, 2 plain
            perform(mode == 0 ? "Applying patches…" : "Applying patch…") { repo in
                switch mode {
                case 0: try await repo.applyMailbox(files)
                default: for file in files { try await repo.applyPatchFile(file, stage: mode == 1) }
                }
            }
        }
    }

    private func firstPatchProblem(_ files: [URL]) async -> String? {
        for file in files {
            if let problem = await repo.checkPatch(file) {
                // `git am` can still apply with a 3-way merge, but a plain check failing is worth showing for plain diffs.
                let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                if text.hasPrefix("From ") { continue }
                return "“\(file.lastPathComponent)” does not apply cleanly:\n\(problem)"
            }
        }
        return nil
    }

    // MARK: Shallow clones

    func refreshShallow() async {
        let value = await repo.isShallow()
        if value != isShallow { isShallow = value }
    }

    func fetchFullHistory() {
        perform("Fetching full history…") { [self] repo in
            try await repo.unshallow()
            await refreshShallow()
        }
    }
}
