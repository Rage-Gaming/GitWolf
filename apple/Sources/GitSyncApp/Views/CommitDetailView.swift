import GitSyncCore
import SwiftUI

struct CommitDetailView: View {
    @Bindable var store: RepositoryStore

    var body: some View {
        if let commit = store.selectedCommit {
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    header(commit)
                    Divider()
                    List(selection: Binding(
                        get: { store.selectedTarget?.path },
                        set: { path in
                            if let change = store.commitFiles.first(where: { $0.path == path }) {
                                store.selectChange(change, source: .commit(commit.hash))
                            }
                        })
                    ) {
                        ForEach(store.commitFiles) { change in
                            FileRow(change: change).tag(change.path)
                        }
                    }
                    .listStyle(.plain)
                    // Sized to its content (capped) so the diff gets the remaining space.
                    .frame(height: min(max(CGFloat(store.commitFiles.count) * 30 + 8, 48), 200))
                }
                Divider()
                DiffPane(diff: store.diff, path: store.selectedTarget?.path)
                    .frame(maxHeight: .infinity)
            }
        } else {
            ContentUnavailableView("No Commit Selected", systemImage: "arrow.triangle.branch",
                                   description: Text("Select a commit to see its changes."))
        }
    }

    private func header(_ c: Commit) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            let parts = store.commitMessage.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            Text(parts.first.map(String.init) ?? c.subject).font(.title3.weight(.semibold)).textSelection(.enabled)
            if parts.count > 1, !parts[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
                    .foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack(spacing: 10) {
                AvatarView(name: c.authorName, email: c.authorEmail, size: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text(c.authorName).fontWeight(.medium)
                    Text(c.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(c.hash, forType: .string)
                } label: {
                    Label(c.shortHash, systemImage: "doc.on.doc").font(.system(.caption, design: .monospaced))
                }
                .buttonStyle(.bordered).controlSize(.small).help("Copy full hash")
            }
            if !c.parents.isEmpty {
                HStack(spacing: 4) {
                    Text(c.parents.count > 1 ? "Parents" : "Parent").font(.caption).foregroundStyle(.secondary)
                    ForEach(c.parents, id: \.self) { p in
                        Button(String(p.prefix(7))) { store.selectCommit(p) }
                            .buttonStyle(.link).font(.system(.caption, design: .monospaced))
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
