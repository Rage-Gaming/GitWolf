import GitSyncCore
import SwiftUI

struct ChangesView: View {
    @Bindable var store: RepositoryStore

    private var selection: Binding<DiffTarget?> {
        Binding(get: { store.selectedTarget }, set: { store.selectTarget($0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            if store.status.isClean {
                ContentUnavailableView("Working Tree Clean", systemImage: "checkmark.circle",
                                       description: Text("No changes to commit."))
            } else {
                List(selection: selection) {
                    if !store.status.conflicted.isEmpty {
                        Section("Conflicts (\(store.status.conflicted.count))") {
                            rows(store.status.conflicted, .conflicted)
                        }
                    }
                    if !store.status.staged.isEmpty {
                        Section {
                            rows(store.status.staged, .staged)
                        } header: {
                            header("Staged", store.status.staged.count, "Unstage All") { store.unstageAll() }
                        }
                    }
                    let unstaged = store.status.unstaged
                    let untracked = store.status.untracked
                    if !unstaged.isEmpty || !untracked.isEmpty {
                        Section {
                            rows(unstaged, .unstaged)
                            rows(untracked, .untracked)
                        } header: {
                            header("Changes", unstaged.count + untracked.count, "Stage All") { store.stageAll() }
                        }
                    }
                }
                .listStyle(.inset)
            }
            Divider()
            composer
        }
    }

    private func header(_ title: String, _ count: Int, _ action: String, _ perform: @escaping () -> Void) -> some View {
        HStack {
            Text("\(title) (\(count))")
            Spacer()
            Button(action, action: perform).buttonStyle(.link).font(.caption)
        }
    }

    @ViewBuilder
    private func rows(_ changes: [FileChange], _ source: DiffTarget.Source) -> some View {
        ForEach(changes) { change in
            HStack {
                FileRow(change: change)
                if source == .staged {
                    RowButton(icon: "minus.circle", help: "Unstage") { store.unstage([change.path]) }
                } else if source != .conflicted {
                    RowButton(icon: "plus.circle", help: "Stage") { store.stage([change.path]) }
                }
            }
            .tag(DiffTarget(source: source, path: change.path, originalPath: change.originalPath))
            .contextMenu {
                if source == .staged {
                    Button("Unstage") { store.unstage([change.path]) }
                } else {
                    Button("Stage") { store.stage([change.path]) }
                    Button("Discard Changes…", role: .destructive) { confirmDiscard(change, untracked: source == .untracked) }
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.repo.root.appendingPathComponent(change.path)])
                }
            }
        }
    }

    private func confirmDiscard(_ change: FileChange, untracked: Bool) {
        let alert = NSAlert()
        alert.messageText = "Discard changes to “\(change.fileName)”?"
        alert.informativeText = untracked ? "This untracked file will be deleted. This can’t be undone."
                                          : "Your modifications will be lost. This can’t be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { store.discard([change], untracked: untracked) }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $store.draftMessage)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                if store.draftMessage.isEmpty {
                    Text("Commit message").foregroundStyle(.tertiary).padding(.horizontal, 11).padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 92)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack {
                Toggle("Amend last commit", isOn: $store.amend).toggleStyle(.checkbox).controlSize(.small)
                Spacer()
                Button {
                    store.commit()
                } label: {
                    Text(store.amend ? "Amend" : "Commit \(store.status.staged.count) file\(store.status.staged.count == 1 ? "" : "s")")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canCommit)
            }
        }
        .padding(12)
    }

    private var canCommit: Bool {
        if store.isBusy { return false }
        if store.amend { return true }
        return !store.status.staged.isEmpty
            && !store.draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct RowButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: icon).foregroundStyle(.secondary) }
            .buttonStyle(.plain).help(help)
    }
}
