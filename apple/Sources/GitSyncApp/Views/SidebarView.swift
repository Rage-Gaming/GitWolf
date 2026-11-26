import GitSyncCore
import SwiftUI

struct SidebarView: View {
    @Bindable var store: RepositoryStore
    @State private var showLocal = true
    @State private var showRemote = true
    @State private var showTags = false
    @State private var showStashes = true

    var body: some View {
        List {
            Section("Workspace") {
                modeRow("History", "clock.arrow.circlepath", .history, badge: nil)
                modeRow("Changes", "square.and.pencil", .changes,
                        badge: store.status.changeCount == 0 ? nil : store.status.changeCount)
            }
            Section("Branches", isExpanded: $showLocal) {
                ForEach(store.localBranches) { branch in
                    SidebarRow(icon: branch.isCurrent ? "checkmark.circle.fill" : "arrow.triangle.branch",
                               title: branch.name, tint: branch.isCurrent ? .green : nil,
                               trailing: syncText(branch), bold: branch.isCurrent) {
                        store.reveal(hash: branch.hash)
                    }
                    .contextMenu {
                        Button("Checkout") { store.checkout(branch) }.disabled(branch.isCurrent)
                        Button("Merge into Current Branch") { store.merge(branch.name) }.disabled(branch.isCurrent)
                        Button("New Branch from Here…") { store.sheet = .newBranch(from: branch.name) }
                        Divider()
                        Button("Delete Branch", role: .destructive) { store.deleteBranch(branch.name) }.disabled(branch.isCurrent)
                    }
                }
            }
            Section("Remotes", isExpanded: $showRemote) {
                ForEach(store.remotes, id: \.self) { remote in
                    DisclosureGroup {
                        ForEach(store.remoteBranches.filter { $0.remote == remote }) { branch in
                            SidebarRow(icon: "cloud", title: branch.shortName, tint: nil, trailing: nil, bold: false) {
                                store.reveal(hash: branch.hash)
                            }
                            .contextMenu {
                                Button("Checkout as Local Branch") { store.checkout(branch) }
                                Button("Merge into Current Branch") { store.merge(branch.name) }
                            }
                        }
                    } label: {
                        Label(remote, systemImage: "externaldrive.connected.to.line.below")
                    }
                }
            }
            Section("Tags", isExpanded: $showTags) {
                ForEach(store.tags) { tag in
                    SidebarRow(icon: "tag", title: tag.name, tint: nil, trailing: nil, bold: false) {
                        store.reveal(hash: tag.hash)
                    }
                    .contextMenu { Button("Delete Tag", role: .destructive) { store.deleteTag(tag.name) } }
                }
            }
            Section("Stashes", isExpanded: $showStashes) {
                ForEach(store.stashes) { stash in
                    SidebarRow(icon: "tray.full", title: stash.message, tint: nil, trailing: nil, bold: false) {}
                        .contextMenu {
                            Button("Apply") { store.stashApply(stash.ref) }
                            Button("Pop") { store.stashPop(stash.ref) }
                            Divider()
                            Button("Drop", role: .destructive) { store.stashDrop(stash.ref) }
                        }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func syncText(_ b: Branch) -> String? {
        var parts: [String] = []
        if b.ahead > 0 { parts.append("↑\(b.ahead)") }
        if b.behind > 0 { parts.append("↓\(b.behind)") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private func modeRow(_ title: String, _ icon: String, _ mode: RepositoryStore.Mode, badge: Int?) -> some View {
        Button { store.mode = mode } label: {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                if let badge {
                    Text("\(badge)").font(.caption.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 1)
                        .background(.tint.opacity(0.18), in: Capsule())
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 6).fill(store.mode == mode ? Color.accentColor.opacity(0.2) : .clear)
                .padding(.horizontal, 6))
    }
}

struct SidebarRow: View {
    let icon: String
    let title: String
    let tint: Color?
    let trailing: String?
    let bold: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(tint ?? .secondary).frame(width: 16)
                Text(title).fontWeight(bold ? .semibold : .regular).lineLimit(1)
                Spacer(minLength: 4)
                if let trailing { Text(trailing).font(.caption).foregroundStyle(.secondary) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.07) : .clear)
                .padding(.horizontal, 6))
        .onHover { hovering = $0 }
    }
}
