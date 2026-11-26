import SwiftUI
import UniformTypeIdentifiers

struct WelcomeView: View {
    let model: WindowModel
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.tint)
                .padding(20)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            VStack(spacing: 6) {
                Text("GitSync").font(.largeTitle.weight(.bold))
                Text("Open a repository to get started.").foregroundStyle(.secondary)
            }
            Button { model.openPanel() } label: {
                Label("Open Repository…", systemImage: "folder")
                    .padding(.horizontal, 10).padding(.vertical, 3)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)

            if !model.recents.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recent").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 10)
                    ForEach(model.recents.prefix(6), id: \.self) { url in
                        Button { model.open(url) } label: {
                            HStack {
                                Image(systemName: "folder.fill").foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(url.lastPathComponent)
                                    Text(url.deletingLastPathComponent().path(percentEncoded: false))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .padding(.horizontal, 10).padding(.vertical, 5)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 360)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isTargeted ? AnyShapeStyle(.tint.opacity(0.08)) : AnyShapeStyle(.background))
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.open(url)
            return true
        } isTargeted: { isTargeted = $0 }
        .navigationTitle("GitSync")
    }
}
