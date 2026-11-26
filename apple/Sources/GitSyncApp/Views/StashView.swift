import GitSyncCore
import SwiftUI

/// Previews a stash: what it contains, with Apply / Pop / Drop, without touching the working tree.
struct StashView: View {
    @Bindable var store: RepositoryStore

    var body: some View {
        if let stash = store.selectedStash {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(stash.message).font(.system(size: 17, weight: .semibold, design: .rounded)).lineLimit(3)
                    Text("\(stash.ref) · \(stash.date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button("Apply") { store.stashApply(stash.ref) }
                        Button("Pop") { store.stashPop(stash.ref) }
                        Button("Drop", role: .destructive) { confirmDrop(stash) }
                    }
                    .controlSize(.small)
                    .disabled(store.isBusy)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                Divider()
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(store.stashFiles) { change in
                            CommitFileRow(change: change, selected: store.selectedTarget?.path == change.path) {
                                if let hash = store.stashCommit { store.selectChange(change, source: .commit(hash)) }
                            }
                        }
                    }
                    .padding(6)
                }
                if store.stashFiles.isEmpty {
                    Text("This stash has no tracked changes.").foregroundStyle(.secondary).padding()
                }
            }
        } else {
            ContentUnavailableView("No Stash Selected", systemImage: "tray.full",
                                   description: Text("Select a stash in the sidebar to preview it."))
        }
    }

    private func confirmDrop(_ stash: Stash) {
        let alert = NSAlert()
        alert.messageText = "Drop “\(stash.message)”?"
        alert.informativeText = "The stashed changes will be deleted. They can be recovered only from the reflog of dangling commits until git cleans up."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Drop")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { store.stashDrop(stash.ref) }
    }
}
