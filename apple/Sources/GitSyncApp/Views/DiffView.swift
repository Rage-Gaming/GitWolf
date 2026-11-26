import GitSyncCore
import SwiftUI

struct DiffPane: View {
    let diff: FileDiff?
    let path: String?

    var body: some View {
        VStack(spacing: 0) {
            if let path {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                    let dir = (path as NSString).deletingLastPathComponent
                    if !dir.isEmpty { Text(dir + "/").foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
                    Text((path as NSString).lastPathComponent).fontWeight(.semibold).lineLimit(1)
                    Spacer()
                    if let diff, !diff.isBinary {
                        Text("+\(diff.additions)").foregroundStyle(.green)
                            .padding(.horizontal, 7).padding(.vertical, 2).background(Color.green.opacity(0.12), in: Capsule())
                        Text("−\(diff.deletions)").foregroundStyle(.red)
                            .padding(.horizontal, 7).padding(.vertical, 2).background(Color.red.opacity(0.12), in: Capsule())
                    }
                }
                .font(.system(.callout, design: .monospaced).weight(.medium))
                .padding(.horizontal, 14).frame(height: 40)
                Divider()
            }
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if let diff {
            if diff.isBinary {
                ContentUnavailableView("Binary File", systemImage: "doc.zipper", description: Text("No preview available."))
            } else if diff.lines.isEmpty {
                ContentUnavailableView("No Differences", systemImage: "equal.circle")
            } else {
                GeometryReader { geo in
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(diff.lines) { DiffLineRow(line: $0, minWidth: geo.size.width) }
                            if diff.isTruncated {
                                Text("Diff truncated — file is too large to display in full.")
                                    .font(.caption).foregroundStyle(.secondary).padding(12)
                            }
                        }
                        .textSelection(.enabled)
                    }
                    .defaultScrollAnchor(.topLeading)
                }
            }
        } else {
            ContentUnavailableView("No File Selected", systemImage: "doc.text.magnifyingglass",
                                   description: Text("Select a file to view its changes."))
        }
    }
}

private struct DiffLineRow: View {
    let line: DiffLine
    let minWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Text(line.oldNumber.map(String.init) ?? "").frame(width: 46, alignment: .trailing).foregroundStyle(.tertiary)
            Text(line.newNumber.map(String.init) ?? "").frame(width: 46, alignment: .trailing).foregroundStyle(.tertiary)
            Text(marker).frame(width: 22).foregroundStyle(markerColor)
            Text(line.text.isEmpty ? " " : line.text).lineLimit(1).fixedSize()
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(line.kind == .hunkHeader ? Color.accentColor : Color.primary)
        .padding(.vertical, line.kind == .hunkHeader ? 4 : 1)
        .frame(minWidth: minWidth, alignment: .leading)
        .background(background)
    }

    private var marker: String {
        switch line.kind {
        case .addition: "+"
        case .deletion: "−"
        default: ""
        }
    }
    private var markerColor: Color { line.kind == .addition ? .green : .red }
    private var background: Color {
        switch line.kind {
        case .addition: .green.opacity(0.13)
        case .deletion: .red.opacity(0.12)
        case .hunkHeader: .accentColor.opacity(0.08)
        default: .clear
        }
    }
}
