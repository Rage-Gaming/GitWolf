import GitSyncCore
import SwiftUI

struct CommitDetailView: View {
    @Bindable var store: RepositoryStore

    var body: some View {
        if let commit = store.selectedCommit {
            VStack(spacing: 0) {
                header(commit)
                Divider()
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(store.commitFiles) { change in
                            CommitFileRow(change: change,
                                          selected: store.selectedTarget?.path == change.path) {
                                store.selectChange(change, source: .commit(commit.hash))
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(height: min(max(CGFloat(store.commitFiles.count) * 33 + 14, 52), 190))
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
        VStack(alignment: .leading, spacing: 12) {
            let parts = store.commitMessage.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            Text(parts.first.map(String.init) ?? c.subject)
                .font(.system(size: 18, weight: .semibold, design: .rounded)).textSelection(.enabled)
            if parts.count > 1, !parts[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
                    .foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack(spacing: 10) {
                AvatarView(name: c.authorName, email: c.authorEmail, size: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text(c.authorName).fontWeight(.semibold)
                    Text(c.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(c.hash, forType: .string)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "doc.on.doc")
                        Text(c.shortHash).font(.system(.caption, design: .monospaced))
                    }
                    .pill()
                }
                .buttonStyle(.plain).help("Copy full hash")
            }
            if !c.parents.isEmpty {
                HStack(spacing: 6) {
                    Text(c.parents.count > 1 ? "Parents" : "Parent").font(.caption).foregroundStyle(.secondary)
                    ForEach(c.parents, id: \.self) { p in
                        Button(String(p.prefix(7))) { store.selectCommit(p) }
                            .buttonStyle(.plain).foregroundStyle(Theme.brand)
                            .font(.system(.caption, design: .monospaced).weight(.medium))
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CommitFileRow: View {
    let change: FileChange
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        FileRow(change: change)
            .padding(.horizontal, 8).frame(height: 32)
            .rowBackground(selected: selected, hovering: hovering)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
    }
}
