import GitSyncCore
import SwiftUI

struct SidebarView: View {
    @Bindable var store: RepositoryStore
    @State private var showLocal = true
    @State private var showRemote = true
    @State private var showTags = false
    @State private var showStashes = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                SidebarSection(title: "Branches", count: store.localBranches.count, isOn: $showLocal) {
                    ForEach(store.localBranches) { branch in
                        SidebarRow(icon: branch.isCurrent ? "checkmark.circle.fill" : "arrow.triangle.branch",
                                   title: branch.name, tint: branch.isCurrent ? .green : nil,
                                   trailing: syncText(branch), emphasized: branch.isCurrent,
                                   onTap: { store.reveal(hash: branch.hash) },
                                   onDoubleTap: { store.checkout(branch) })
                            .contextMenu {
                                Button("Checkout") { store.checkout(branch) }.disabled(branch.isCurrent)
                                Button("Merge into Current Branch") { store.merge(branch.name) }.disabled(branch.isCurrent)
                                Button("Rebase Current Branch onto This") { store.rebase(onto: branch.name) }.disabled(branch.isCurrent)
                                Button("New Branch from Here…") { store.sheet = .newBranch(from: branch.name) }
                                Divider()
                                Button("Delete Branch", role: .destructive) { store.deleteBranch(branch.name) }.disabled(branch.isCurrent)
                            }
                    }
                }
                SidebarSection(title: "Remotes", count: store.remotes.count, isOn: $showRemote) {
                    ForEach(store.remotes, id: \.self) { remote in
                        RemoteGroup(store: store, remote: remote)
                    }
                    if store.remotes.isEmpty { emptyNote("No remotes") }
                }
                SidebarSection(title: "Tags", count: store.tags.count, isOn: $showTags) {
                    ForEach(store.tags) { tag in
                        SidebarRow(icon: "tag", title: tag.name, tint: .orange, trailing: nil, emphasized: false,
                                   onTap: { store.reveal(hash: tag.hash) }, onDoubleTap: {})
                            .contextMenu { Button("Delete Tag", role: .destructive) { store.deleteTag(tag.name) } }
                    }
                    if store.tags.isEmpty { emptyNote("No tags") }
                }
                SidebarSection(title: "Stashes", count: store.stashes.count, isOn: $showStashes) {
                    ForEach(store.stashes) { stash in
                        SidebarRow(icon: "tray.full", title: stash.message, tint: nil, trailing: nil, emphasized: false,
                                   onTap: {}, onDoubleTap: { store.stashApply(stash.ref) })
                            .contextMenu {
                                Button("Apply") { store.stashApply(stash.ref) }
                                Button("Pop") { store.stashPop(stash.ref) }
                                Divider()
                                Button("Drop", role: .destructive) { store.stashDrop(stash.ref) }
                            }
                    }
                    if store.stashes.isEmpty { emptyNote("No stashes") }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.never)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(store.name)
                .font(.system(size: 21, weight: .bold, design: .rounded))
                .lineLimit(1)
            HStack(spacing: 6) {
                Circle().fill(store.status.isClean ? Color.green : Color.orange).frame(width: 7, height: 7)
                Text(store.status.isClean ? "Clean" : "\(store.status.changeCount) change\(store.status.changeCount == 1 ? "" : "s")")
                if store.status.ahead > 0 { Text("↑\(store.status.ahead)") }
                if store.status.behind > 0 { Text("↓\(store.status.behind)") }
            }
            .font(.callout).foregroundStyle(.secondary)
            if let location = store.remoteLocation {
                Button { store.openOnWeb(.repository) } label: {
                    HStack(spacing: 4) {
                        Text(store.providerTitle.map { "\($0) · " } ?? "").foregroundStyle(.secondary)
                        Text(location.path).lineLimit(1).truncationMode(.middle)
                        Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold))
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Open on the web")
            }
        }
        .padding(.horizontal, 8).padding(.top, 4)
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.tertiary).padding(.horizontal, 10).padding(.vertical, 4)
    }

    private func syncText(_ b: Branch) -> String? {
        var parts: [String] = []
        if b.ahead > 0 { parts.append("↑\(b.ahead)") }
        if b.behind > 0 { parts.append("↓\(b.behind)") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

private struct RemoteGroup: View {
    let store: RepositoryStore
    let remote: String
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button { withAnimation(.snappy(duration: 0.2)) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0)).foregroundStyle(.tertiary).frame(width: 12)
                    Image(systemName: "cloud").foregroundStyle(.purple).frame(width: 16)
                    Text(remote).fontWeight(.medium)
                    Spacer()
                }
                .padding(.horizontal, 8).frame(height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                ForEach(store.remoteBranches.filter { $0.remote == remote }) { branch in
                    SidebarRow(icon: "arrow.triangle.branch", title: branch.shortName, tint: nil, trailing: nil,
                               emphasized: false, onTap: { store.reveal(hash: branch.hash) },
                               onDoubleTap: { store.checkout(branch) })
                        .padding(.leading, 14)
                        .contextMenu {
                            Button("Checkout as Local Branch") { store.checkout(branch) }
                            Button("Merge into Current Branch") { store.merge(branch.name) }
                            Button("Rebase Current Branch onto This") { store.rebase(onto: branch.name) }
                        }
                }
            }
        }
    }
}

private struct SidebarSection<Content: View>: View {
    let title: String
    let count: Int
    @Binding var isOn: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { withAnimation(.snappy(duration: 0.2)) { isOn.toggle() } } label: {
                HStack(spacing: 6) {
                    Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.7)
                    Text("\(count)").font(.system(size: 10, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 5).background(Color.primary.opacity(0.07), in: Capsule())
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(isOn ? 90 : 0))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8).frame(height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOn { content }
        }
    }
}

private struct SidebarRow: View {
    let icon: String
    let title: String
    let tint: Color?
    let trailing: String?
    let emphasized: Bool
    let onTap: () -> Void
    let onDoubleTap: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint ?? .secondary).frame(width: 16)
            Text(title).fontWeight(emphasized ? .semibold : .regular).lineLimit(1)
            Spacer(minLength: 4)
            if let trailing { Text(trailing).font(.caption.weight(.medium)).foregroundStyle(Theme.brand) }
        }
        .padding(.horizontal, 8).frame(height: 30)
        .rowBackground(selected: false, hovering: hovering)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: onDoubleTap)
        .onTapGesture(perform: onTap)
    }
}
