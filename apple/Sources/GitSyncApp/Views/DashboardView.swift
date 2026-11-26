import SwiftUI

/// Shown when no repository is selected: open something or jump back into recents.
struct DashboardView: View {
    let workspace: Workspace
    @State private var isTargeted = false

    var body: some View {
        ScrollView {
            VStack(spacing: 34) {
                VStack(spacing: 14) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 84, height: 84)
                        .background(Theme.brandGradient, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .shadow(color: Theme.brand.opacity(0.4), radius: 18, y: 8)
                    Text("GitSync").font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("Your repositories, always in sync.").font(.title3).foregroundStyle(.secondary)
                }
                .padding(.top, 70)

                HStack(spacing: 10) {
                    Button { workspace.openPanel() } label: {
                        Label("Open Repository", systemImage: "folder.badge.plus")
                            .font(.body.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    Button { workspace.showPalette = true } label: {
                        HStack(spacing: 6) { Text("Jump to…"); Kbd(text: "⌘K") }.padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                }

                if !workspace.recents.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("RECENT").font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                            ForEach(workspace.recents.prefix(9), id: \.self) { url in
                                RecentCard(url: url) { workspace.open(url) }
                            }
                        }
                    }
                    .frame(maxWidth: 820)
                    .padding(.horizontal, 32)
                }
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
    }
}

private struct RecentCard: View {
    let url: URL
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(String(url.lastPathComponent.prefix(2)).capitalized)
                    .font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(gradient(for: url.lastPathComponent), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent).font(.body.weight(.semibold)).lineLimit(1)
                    Text(url.deletingLastPathComponent().path(percentEncoded: false))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: 0)
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
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}
