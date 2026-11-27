import GitWolfCore
import SwiftUI

/// Shown when no repository is selected: open something or jump back into recents.
struct DashboardView: View {
    let workspace: Workspace
    @State private var isTargeted = false
    @State private var groupDialog: GroupDialog?
    @State private var groupName = ""

    /// A pending "name this group" prompt: creating one (optionally seeded with a repository) or renaming.
    private enum GroupDialog: Identifiable {
        case create(seed: String?)
        case rename(UUID)
        var id: String {
            switch self {
            case .create(let seed): "create-\(seed ?? "")"
            case .rename(let id): "rename-\(id)"
            }
        }
    }

    /// The shared look of the buttons under the title: same font, same padding, same height.
    private func homeLabel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(.body.weight(.semibold))
            .padding(.horizontal, 6)
            .frame(height: Theme.barControlHeight - 8)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 34) {
                VStack(spacing: 14) {
                    if let art = BrandArt.icon {
                        Image(nsImage: art).resizable().scaledToFit().frame(width: 104, height: 104)
                            .accessibilityHidden(true)
                    }
                    Text("GitWolf").font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("Your repositories, always in sync.").font(.title3).foregroundStyle(.secondary)
                }
                .padding(.top, 70)

                // One height, one font weight and one padding for every action, so they line up exactly.
                HStack(spacing: 10) {
                    Button { workspace.openPanel() } label: {
                        homeLabel { Label("Open Repository", systemImage: "folder.badge.plus") }
                    }
                    .buttonStyle(.borderedProminent)
                    Button { workspace.sheet = .clone } label: {
                        homeLabel { Label("Clone", systemImage: "square.and.arrow.down") }
                    }
                    .buttonStyle(.bordered)
                    Button { workspace.sheet = .create } label: {
                        homeLabel { Label("New", systemImage: "plus.rectangle.on.folder") }
                    }
                    .buttonStyle(.bordered)
                    Button { workspace.showPalette = true } label: {
                        homeLabel { HStack(spacing: 8) { Text("Jump to…"); Kbd(text: "⌘K") } }
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)

                VStack(alignment: .leading, spacing: 26) {
                    if !workspace.home.pinned.isEmpty {
                        section("PINNED", paths: workspace.home.pinned)
                    }
                    ForEach(workspace.home.groups) { group in
                        section(group.name.uppercased(), paths: group.paths, group: group)
                    }
                    if !workspace.recents.isEmpty {
                        section("RECENT", paths: workspace.recents.prefix(9).map(\.path))
                    }
                    Button { groupName = ""; groupDialog = .create(seed: nil) } label: {
                        Label("New Group", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.link)
                }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(.horizontal, 32)
                Spacer(minLength: 30)
            }
            .frame(maxWidth: .infinity)
        }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Theme.brand, style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .background(Theme.brand.opacity(0.06))
                    .padding(14)
                    .overlay(Text("Drop a folder to open").font(.title3.weight(.semibold)).foregroundStyle(Theme.brand))
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            urls.forEach(workspace.open)
            return !urls.isEmpty
        } isTargeted: { isTargeted = $0 }
        .alert(groupDialog.map { if case .rename = $0 { "Rename Group" } else { "New Group" } } ?? "",
               isPresented: Binding(get: { groupDialog != nil }, set: { if !$0 { groupDialog = nil } })) {
            TextField("Name", text: $groupName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                switch groupDialog {
                case .create(let seed): workspace.editHome { $0.addGroup(named: groupName, paths: seed.map { [$0] } ?? []) }
                case .rename(let id): workspace.editHome { $0.renameGroup(id, to: groupName) }
                case nil: break
                }
            }
        }
    }

    private func section(_ title: String, paths: [String], group: HomeLayout.Group? = nil) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
                if let group {
                    Spacer()
                    Menu {
                        Button("Rename…") { groupName = group.name; groupDialog = .rename(group.id) }
                        Button("Delete Group", role: .destructive) { workspace.editHome { $0.deleteGroup(group.id) } }
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel("Group options")
                }
            }
            if paths.isEmpty {
                Text("Right-click a repository and choose Add to Group.").font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                ForEach(paths, id: \.self) { path in
                    let url = URL(fileURLWithPath: path, isDirectory: true)
                    RecentCard(url: url, pinned: workspace.home.isPinned(path)) { workspace.open(url) }
                        .contextMenu { menu(for: path) }
                }
            }
        }
    }

    @ViewBuilder private func menu(for path: String) -> some View {
        Button(workspace.home.isPinned(path) ? "Unpin" : "Pin") { workspace.editHome { $0.togglePin(path) } }
        Menu("Add to Group") {
            ForEach(workspace.home.groups) { group in
                Button { workspace.editHome { $0.toggle(path, inGroup: group.id) } } label: {
                    if group.paths.contains(path) { Label(group.name, systemImage: "checkmark") } else { Text(group.name) }
                }
            }
            if !workspace.home.groups.isEmpty { Divider() }
            Button("New Group…") { groupName = ""; groupDialog = .create(seed: path) }
        }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        Divider()
        Button("Remove from Home") { workspace.forget(path) }
    }
}

private struct RecentCard: View {
    let url: URL
    var pinned = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(String(url.lastPathComponent.prefix(2)).capitalized)
                    .font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(avatarColor(for: url.lastPathComponent), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent).font(.body.weight(.semibold)).lineLimit(1)
                    Text(url.deletingLastPathComponent().path(percentEncoded: false))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: 0)
                if pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary) }
            }
            .padding(12)
            .background(Color(nsColor: .textBackgroundColor).opacity(hovering ? 1 : 0.7),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(hovering ? Theme.brand.opacity(0.5) : Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(hovering ? 0.10 : 0.04), radius: hovering ? 10 : 4, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(url.lastPathComponent)
        .accessibilityHint("Opens the repository")
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}
