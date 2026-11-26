import GitSyncCore
import SwiftUI

/// Worktrees (extra checkouts of this repository) and submodules (repositories nested inside it).
struct WorktreesSheet: View {
    let store: RepositoryStore
    let workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var worktrees: [Worktree] = []
    @State private var submodules: [Submodule] = []
    @State private var branch = ""
    @State private var newBranch = false
    @State private var wtPath = ""
    @State private var subURL = ""
    @State private var subPath = ""
    @State private var error: String?
    @State private var working = false

    private var freeBranches: [String] {
        let used = Set(worktrees.compactMap(\.branch))
        return store.localBranches.map(\.name).filter { !used.contains($0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Worktrees").font(.system(size: 17, weight: .semibold, design: .rounded))
                Text("Check out another branch in its own folder, without touching this one.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(worktrees) { tree in worktreeRow(tree) }
                addWorktree
                Divider().padding(.vertical, 4)
                Text("Submodules").font(.system(size: 17, weight: .semibold, design: .rounded))
                if submodules.isEmpty { Text("This repository has no submodules.").foregroundStyle(.secondary) }
                ForEach(submodules) { sub in submoduleRow(sub) }
                if !submodules.isEmpty {
                    HStack {
                        Button("Update All") { run { try await store.repo.updateSubmodules() } }
                            .help("Clone missing submodules and check out the commits this repository records")
                        Button("Update to Latest") { run { try await store.repo.updateSubmodulesToLatest() } }
                            .help("Move each submodule to the newest commit of its tracked branch")
                    }
                }
                addSubmodule
                if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                HStack {
                    if working { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }
            }
            .padding(22)
        }
        .frame(width: 600, height: 560)
        .task { await reload() }
    }

    // MARK: Rows

    private func worktreeRow(_ tree: Worktree) -> some View {
        HStack(spacing: 10) {
            Image(systemName: tree.isMain ? "folder.fill" : "folder").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tree.branch ?? "detached @ \(tree.head.prefix(7))").fontWeight(.semibold)
                    if tree.isMain { tag("main") }
                    if tree.isLocked { tag("locked") }
                    if tree.isPrunable { tag("missing") }
                }
                Text((tree.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if tree.path != store.repo.root.path, !tree.isPrunable {
                Button("Open") { workspace.open(URL(fileURLWithPath: tree.path)); dismiss() }
            }
            if tree.isPrunable {
                Button("Prune") { run { try await store.repo.pruneWorktrees() } }
            } else if !tree.isMain {
                Button("Remove…", role: .destructive) { confirmRemove(tree) }
            }
        }
        .padding(10).rowCard()
    }

    private func submoduleRow(_ sub: Submodule) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(sub.state)).foregroundStyle(color(sub.state))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(sub.path).fontWeight(.semibold)
                    Text(sub.hash.prefix(7)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    if sub.state != .upToDate { tag(label(sub.state)) }
                }
                if !sub.url.isEmpty {
                    Text(GitRepository.redact(sub.url)).font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            if sub.state == .notInitialized {
                Button("Initialize") { run { try await store.repo.updateSubmodules(path: sub.path) } }
            } else {
                Button("Open") { workspace.open(store.repo.root.appendingPathComponent(sub.path)); dismiss() }
            }
        }
        .padding(10).rowCard()
    }

    private func tag(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Color.primary.opacity(0.08), in: Capsule()).foregroundStyle(.secondary)
    }

    private func icon(_ s: Submodule.State) -> String {
        switch s {
        case .upToDate: "checkmark.circle.fill"
        case .notInitialized: "circle.dashed"
        case .modified: "arrow.triangle.2.circlepath.circle.fill"
        case .conflicted: "exclamationmark.triangle.fill"
        }
    }
    private func color(_ s: Submodule.State) -> Color {
        switch s {
        case .upToDate: .green
        case .notInitialized: .secondary
        case .modified: .orange
        case .conflicted: .red
        }
    }
    private func label(_ s: Submodule.State) -> String {
        switch s {
        case .upToDate: ""
        case .notInitialized: "not downloaded"
        case .modified: "different commit"
        case .conflicted: "conflict"
        }
    }

    // MARK: Adding

    private var addWorktree: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("New Worktree").font(.headline)
            HStack(spacing: 8) {
                if newBranch {
                    TextField("new-branch-name", text: $branch).sheetField()
                } else {
                    Picker("Branch", selection: $branch) {
                        Text("Choose…").tag("")
                        ForEach(freeBranches, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden()
                }
                Toggle("New branch", isOn: $newBranch).onChange(of: newBranch) { _, _ in branch = "" }
            }
            HStack(spacing: 8) {
                Text(wtPath.isEmpty ? "Folder" : (wtPath as NSString).abbreviatingWithTildeInPath)
                    .foregroundStyle(wtPath.isEmpty ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading).sheetField()
                Button("Choose…") { chooseFolder() }
                Button("Add") {
                    let name = branch.trimmingCharacters(in: .whitespaces)
                    run { try await store.repo.addWorktree(at: URL(fileURLWithPath: wtPath), branch: name, newBranch: newBranch)
                        await MainActor.run { branch = ""; wtPath = "" } }
                }
                .disabled(branch.trimmingCharacters(in: .whitespaces).isEmpty || wtPath.isEmpty)
            }
        }
    }

    private var addSubmodule: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add Submodule").font(.headline)
            HStack(spacing: 8) {
                TextField("https://… or git@…", text: $subURL).sheetField()
                TextField("folder (e.g. vendor/lib)", text: $subPath).sheetField().frame(width: 170)
                Button("Add") {
                    run { try await store.repo.addSubmodule(url: subURL.trimmingCharacters(in: .whitespaces),
                                                            path: subPath.trimmingCharacters(in: .whitespaces))
                        await MainActor.run { subURL = ""; subPath = "" } }
                }
                .disabled(subURL.trimmingCharacters(in: .whitespaces).isEmpty || subPath.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder that will hold the new worktree (it must not exist yet, so pick the parent and we add the name)"
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let name = branch.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        wtPath = parent.appendingPathComponent(name.isEmpty ? "worktree" : name).path
    }

    private func confirmRemove(_ tree: Worktree) {
        let alert = NSAlert()
        alert.messageText = "Remove the worktree “\(tree.name)”?"
        alert.informativeText = "Its folder is deleted. The branch and its commits stay. Git refuses if the folder has uncommitted changes."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run { try await store.repo.removeWorktree(tree.path, force: false) }
    }

    // MARK: Plumbing

    private func reload() async {
        worktrees = (try? await store.repo.worktrees()) ?? []
        submodules = (try? await store.repo.submodules()) ?? []
    }

    private func run(_ work: @escaping @Sendable () async throws -> Void) {
        error = nil
        working = true
        Task {
            do { try await work(); store.requestRefresh() } catch { self.error = error.localizedDescription }
            working = false
            await reload()
        }
    }
}

private extension View {
    func rowCard() -> some View {
        background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
