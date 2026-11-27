import GitSyncCore
import SwiftUI

/// Vertical strip of open repositories, always visible, with live status badges.
///
/// Every control is the same 40 pt rounded square so the column reads as one list. Selection is
/// shown by a solid tile plus an edge marker; nothing scales or moves on hover.
struct RepoRail: View {
    let workspace: Workspace

    fileprivate static let width: CGFloat = 64
    fileprivate static let tile: CGFloat = 40
    fileprivate static let radius: CGFloat = 11

    var body: some View {
        VStack(spacing: 8) {
            Color.clear.frame(height: 30) // traffic lights

            RailButton(symbol: "house.fill", help: "Home", selected: workspace.selected == nil) {
                workspace.select(nil)
            }
            Rectangle().fill(Color.primary.opacity(0.10)).frame(width: 24, height: 1).padding(.vertical, 2)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(workspace.repos) { store in
                        RepoTile(store: store, selected: store.id == workspace.selectedID,
                                 select: { workspace.select(store.id) },
                                 close: { workspace.close(store) },
                                 icon: workspace.repoIcons.icon(for: store.id),
                                 setIcon: { workspace.setIcon($0, for: store.id) },
                                 chooseImage: { workspace.chooseIconImage(for: store.id) })
                    }
                }
                .frame(maxWidth: .infinity)
            }

            AddMenu(workspace: workspace)
        }
        .padding(.bottom, 12)
        .frame(width: Self.width)
        .background(.black.opacity(0.04))
        .overlay(alignment: .trailing) { Rectangle().fill(Color.primary.opacity(0.07)).frame(width: 1) }
    }
}

/// The marker on the rail's left edge that shows which tile is selected.
private struct SelectionMarker: View {
    let selected: Bool
    var body: some View {
        Capsule().fill(Theme.brand)
            .frame(width: 3, height: 20)
            .opacity(selected ? 1 : 0)
            .padding(.leading, 1)
    }
}

private struct RailButton: View {
    let symbol: String
    let help: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .frame(width: RepoRail.tile, height: RepoRail.tile)
                .background(selected ? Theme.brand : Color.primary.opacity(hovering ? 0.10 : 0.06),
                            in: RoundedRectangle(cornerRadius: RepoRail.radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(width: RepoRail.width, height: RepoRail.tile)
        .overlay(alignment: .leading) { SelectionMarker(selected: selected) }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { hovering = $0 }
    }
}

private struct RepoTile: View {
    let store: RepositoryStore
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    let icon: RepoIcon?
    let setIcon: (RepoIcon?) -> Void
    let chooseImage: () -> Void
    @State private var hovering = false
    @State private var picking = false

    private var initials: String {
        let words = store.name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.count > 1 { return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased() }
        return String(store.name.prefix(2)).capitalized
    }

    private var changes: Int { store.status.changeCount }

    var body: some View {
        let color = avatarColor(for: store.name)
        let shape = RoundedRectangle(cornerRadius: RepoRail.radius, style: .continuous)
        Button(action: select) {
            tileContent(color: color)
                .frame(width: RepoRail.tile, height: RepoRail.tile)
                .background(tileFill(color), in: shape)
                .clipShape(shape)
                .overlay(alignment: .bottomTrailing) { badge }
        }
        .popover(isPresented: $picking, arrowEdge: .trailing) {
            RepoIconPicker(path: store.id, current: icon, choose: setIcon, importImage: chooseImage)
        }
        .buttonStyle(.plain)
        .frame(width: RepoRail.width, height: RepoRail.tile)
        .overlay(alignment: .leading) { SelectionMarker(selected: selected) }
        .help("\(store.name) · \(store.status.branchDisplay)")
        .accessibilityLabel(store.name)
        .accessibilityValue("\(store.status.branchDisplay), " + (changes == 0 ? "no changes" : "\(changes) changes"))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Change Icon…") { picking = true }
            if icon != nil { Button("Remove Icon") { setIcon(nil) } }
            Divider()
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.repo.root]) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(store.repo.root.path, forType: .string)
            }
            Divider()
            Button("Close Repository", role: .destructive, action: close)
        }
    }

    private func tileFill(_ color: Color) -> Color {
        if case .image = icon { return Color.primary.opacity(0.08) }
        return selected ? color : color.opacity(hovering ? 0.26 : 0.17)
    }

    @ViewBuilder private func tileContent(color: Color) -> some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name).font(.system(size: 18, weight: .semibold))
                .foregroundStyle(selected ? Color.white : color)
        case .image(let file):
            if let image = RepoIconImages.image(file) {
                Image(nsImage: image).resizable().scaledToFill()
                    .opacity(selected || hovering ? 1 : 0.88)
            } else {
                initialsText(color: color)
            }
        case nil:
            initialsText(color: color)
        }
    }

    private func initialsText(color: Color) -> some View {
        Text(initials)
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .foregroundStyle(selected ? Color.white : color)
    }

    /// Uncommitted-change count, tucked into the tile's bottom-right corner.
    @ViewBuilder private var badge: some View {
        if changes > 0 {
            Text(changes > 99 ? "99+" : "\(changes)")
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16)
                .background(Color.orange, in: Capsule())
                .overlay(Capsule().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                .offset(x: 4, y: 4)
        }
    }
}

/// The "+" tile: same size and shape as the others, opening a menu to open, clone or create.
private struct AddMenu: View {
    let workspace: Workspace
    @State private var hovering = false

    var body: some View {
        Menu {
            Button("Open Repository…") { workspace.openPanel() }
            Button("Clone Repository…") { workspace.sheet = .clone }
            Button("New Repository…") { workspace.sheet = .create }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: RepoRail.tile, height: RepoRail.tile)
                .background(Color.primary.opacity(hovering ? 0.10 : 0.06),
                            in: RoundedRectangle(cornerRadius: RepoRail.radius, style: .continuous))
                .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .frame(width: RepoRail.width, height: RepoRail.tile)
        .help("Open, clone or create a repository")
        .accessibilityLabel("Open, clone or create a repository")
        .onHover { hovering = $0 }
    }
}
