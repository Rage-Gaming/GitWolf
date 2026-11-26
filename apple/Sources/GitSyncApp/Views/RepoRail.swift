import GitSyncCore
import SwiftUI

/// Vertical strip of open repositories, always visible, with live status badges.
struct RepoRail: View {
    let workspace: Workspace

    var body: some View {
        VStack(spacing: 12) {
            Color.clear.frame(height: 34) // traffic lights

            RailIconButton(symbol: "house.fill", help: "Home", selected: workspace.selected == nil) {
                workspace.select(nil)
            }
            Capsule().fill(Color.primary.opacity(0.12)).frame(width: 26, height: 1.5)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 12) {
                    ForEach(workspace.repos) { store in
                        RepoTile(store: store, selected: store.id == workspace.selectedID,
                                 select: { workspace.select(store.id) },
                                 close: { workspace.close(store) })
                    }
                }
                .padding(.vertical, 2)
            }

            RailIconButton(symbol: "plus", help: "Open repository (⌘O)", selected: false) { workspace.openPanel() }
        }
        .padding(.bottom, 14)
        .frame(width: 76)
        .background(.black.opacity(0.04))
        .overlay(alignment: .trailing) { Rectangle().fill(Color.primary.opacity(0.07)).frame(width: 1) }
    }
}

private struct RailIconButton: View {
    let symbol: String
    let help: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: selected ? 14 : 18, style: .continuous)
                        .fill(selected ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.10 : 0.06))))
                .scaleEffect(hovering ? 1.05 : 1)
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.18), value: hovering)
        .animation(.snappy(duration: 0.18), value: selected)
    }
}

private struct RepoTile: View {
    let store: RepositoryStore
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    private var initials: String {
        let words = store.name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.count > 1 { return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased() }
        return String(store.name.prefix(2)).capitalized
    }

    var body: some View {
        Button(action: select) {
            ZStack(alignment: .topTrailing) {
                Text(initials)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(gradient(for: store.name),
                                in: RoundedRectangle(cornerRadius: selected ? 14 : 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: selected ? 14 : 18, style: .continuous)
                        .strokeBorder(.white.opacity(0.22), lineWidth: 0.75))
                    .shadow(color: .black.opacity(selected ? 0.25 : 0.12), radius: selected ? 8 : 4, y: 2)
                    .scaleEffect(hovering && !selected ? 1.06 : 1)

                if store.status.changeCount > 0 {
                    Text(store.status.changeCount > 99 ? "99+" : "\(store.status.changeCount)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).frame(minWidth: 17, minHeight: 17)
                        .background(Color.orange, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                        .offset(x: 6, y: -6)
                }
            }
            .frame(width: 76, height: 48)
            .overlay(alignment: .leading) {
                Capsule().fill(Theme.brand)
                    .frame(width: 4, height: selected ? 28 : (hovering ? 12 : 0))
                    .offset(x: -2)
            }
        }
        .buttonStyle(.plain)
        .help("\(store.name) · \(store.status.branchDisplay)")
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.2), value: selected)
        .animation(.snappy(duration: 0.18), value: hovering)
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.repo.root]) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(store.repo.root.path, forType: .string)
            }
            Divider()
            Button("Close Repository", role: .destructive, action: close)
        }
    }
}
