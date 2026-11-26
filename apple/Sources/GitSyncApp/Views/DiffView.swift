import AppKit
import GitSyncCore
import SwiftUI

/// Hunk and line staging controls for a diff. `nil` means the diff is read-only.
struct DiffStaging {
    /// True when showing the staged side (actions un-stage); false for the working-tree side.
    var staged: Bool
    var selection: Set<Int>
    var toggle: @MainActor (Int, Bool) -> Void
    var clear: @MainActor () -> Void
    var hunk: @MainActor (Int, PatchAction) -> Void
    var lines: @MainActor (PatchAction) -> Void
}

struct DiffPane: View {
    let diff: FileDiff?
    let path: String?
    var staging: DiffStaging?

    @AppStorage(SettingsKey.syntaxHighlighting) private var syntaxOn = true
    @State private var highlights: [Int: AttributedString] = [:]

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
        .task(id: HighlightKey(path: path, enabled: syntaxOn, diff: diff)) { await computeHighlights() }
    }

    private static let charWidth: CGFloat =
        NSFont.monospacedSystemFont(ofSize: 12, weight: .regular).maximumAdvancement.width

    /// Gutters (selection, two line numbers, marker) plus the longest line, with some slack.
    private static func contentWidth(of diff: FileDiff, staged hasSelectionGutter: Bool) -> CGFloat {
        let longest = diff.lines.reduce(0) { max($0, $1.text.utf8.count) }
        let gutters: CGFloat = (hasSelectionGutter ? 22 : 0) + 46 + 46 + 22
        return gutters + CGFloat(longest) * charWidth + 32
    }

    /// Re-run highlighting only when the diff, file or setting changes (not on selection changes).
    private struct HighlightKey: Hashable {
        let path: String?
        let enabled: Bool
        let signature: Int

        init(path: String?, enabled: Bool, diff: FileDiff?) {
            self.path = path
            self.enabled = enabled
            var hasher = Hasher()
            if let diff {
                hasher.combine(diff.lines.count)
                for line in diff.lines { hasher.combine(line.text) }
            }
            signature = hasher.finalize()
        }
    }

    private func computeHighlights() async {
        guard syntaxOn, let diff, let path, !diff.isBinary else {
            if !highlights.isEmpty { highlights = [:] }
            return
        }
        let result = await Task.detached(priority: .userInitiated) { () -> [Int: AttributedString] in
            let tokens = SyntaxHighlighter.tokens(for: diff, path: path)
            var out: [Int: AttributedString] = [:]
            for line in diff.lines {
                guard let spans = tokens[line.id] else { continue }
                var text = AttributedString(line.text)
                for span in spans {
                    let chars = text.characters
                    guard span.start < chars.count, span.end <= chars.count else { continue }
                    let lower = chars.index(chars.startIndex, offsetBy: span.start)
                    let upper = chars.index(chars.startIndex, offsetBy: span.end)
                    text[lower..<upper].foregroundColor = SyntaxPalette.color(span.kind)
                }
                out[line.id] = text
            }
            return out
        }.value
        if !Task.isCancelled { highlights = result }
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
                    // Lazy stacks don't report the width of rows that aren't on screen yet, so give
                    // the content an explicit width; otherwise long lines can't be scrolled to.
                    let width = max(geo.size.width, Self.contentWidth(of: diff, staged: staging != nil))
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(diff.lines) { line in
                                if line.kind == .hunkHeader {
                                    HunkHeaderRow(line: line, minWidth: width, staging: staging, confirmDiscard: confirmDiscard)
                                } else {
                                    DiffLineRow(line: line, minWidth: width, staging: staging, highlight: highlights[line.id])
                                }
                            }
                            if diff.isTruncated {
                                Text("Diff truncated — file is too large to display in full.")
                                    .font(.caption).foregroundStyle(.secondary).padding(12)
                            }
                            Color.clear.frame(height: 60)
                        }
                        .frame(width: width, alignment: .leading)
                    }
                    .defaultScrollAnchor(.topLeading)
                }
                .overlay(alignment: .bottom) { selectionBar }
            }
        } else {
            ContentUnavailableView("No File Selected", systemImage: "doc.text.magnifyingglass",
                                   description: Text("Select a file to view its changes."))
        }
    }

    @ViewBuilder private var selectionBar: some View {
        if let staging, !staging.selection.isEmpty {
            let n = staging.selection.count
            HStack(spacing: 12) {
                Text("\(n) line\(n == 1 ? "" : "s") selected").font(.callout.weight(.medium))
                Button(staging.staged ? "Unstage Lines" : "Stage Lines") {
                    staging.lines(staging.staged ? .unstage : .stage)
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                if !staging.staged {
                    Button("Discard", role: .destructive) {
                        confirmDiscard("\(n) selected line\(n == 1 ? "" : "s")") { staging.lines(.discard) }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                Button { staging.clear() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("Clear selection")
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
            .padding(.bottom, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func confirmDiscard(_ what: String, _ action: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "Discard \(what)?"
        alert.informativeText = "These changes will be removed from your working tree. This can’t be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { action() }
    }
}

private struct HunkHeaderRow: View {
    let line: DiffLine
    let minWidth: CGFloat
    let staging: DiffStaging?
    let confirmDiscard: (String, @escaping () -> Void) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(line.text).lineLimit(1)
            Spacer(minLength: 12)
            if let staging {
                Button {
                    staging.hunk(line.hunkIndex, staging.staged ? .unstage : .stage)
                } label: {
                    Text(staging.staged ? "Unstage Hunk" : "Stage Hunk")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(Theme.brandGradient, in: Capsule())
                }
                .buttonStyle(.plain)
                if !staging.staged {
                    Button {
                        confirmDiscard("this hunk") { staging.hunk(line.hunkIndex, .discard) }
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.red.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain).help("Discard hunk")
                }
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(Color.accentColor)
        .padding(.leading, 70).padding(.trailing, 12).padding(.vertical, 5)
        .frame(minWidth: minWidth, alignment: .leading)
        .background(Color.accentColor.opacity(0.08))
    }
}

private struct DiffLineRow: View {
    let line: DiffLine
    let minWidth: CGFloat
    let staging: DiffStaging?
    var highlight: AttributedString?
    @State private var hovering = false

    private var selected: Bool { staging?.selection.contains(line.id) ?? false }

    var body: some View {
        HStack(spacing: 0) {
            // Gutter: click to select a line, shift-click to select a range.
            HStack(spacing: 0) {
                if let staging, line.isChange {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 12))
                        .foregroundStyle(selected ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(.tertiary))
                        .opacity(selected || hovering ? 1 : 0.35)
                        .frame(width: 22)
                        .help(staging.staged ? "Select line to unstage" : "Select line to stage")
                } else if staging != nil {
                    Color.clear.frame(width: 22)
                }
                Text(line.oldNumber.map(String.init) ?? "").frame(width: 46, alignment: .trailing).foregroundStyle(.tertiary)
                Text(line.newNumber.map(String.init) ?? "").frame(width: 46, alignment: .trailing).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard let staging, line.isChange else { return }
                staging.toggle(line.id, NSEvent.modifierFlags.contains(.shift))
            }

            Text(marker).frame(width: 22).foregroundStyle(markerColor)
            Group {
                if let highlight { Text(highlight) } else { Text(line.text.isEmpty ? " " : line.text) }
            }
            .lineLimit(1).fixedSize().textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, 1)
        .frame(minWidth: minWidth, alignment: .leading)
        .background(background)
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(Theme.brand).frame(width: 3) }
        }
        .onHover { hovering = $0 }
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
        let base: Color
        switch line.kind {
        case .addition: base = .green.opacity(0.13)
        case .deletion: base = .red.opacity(0.12)
        default: base = .clear
        }
        return selected ? Theme.brand.opacity(0.22) : base
    }
}

/// Syntax colours (Xcode-like), adapting to light and dark appearance.
enum SyntaxPalette {
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }

    static let keyword = dynamic(light: 0xAD3DA4, dark: 0xFF7AB2)
    static let type = dynamic(light: 0x0B6E99, dark: 0x5DD8FF)
    static let string = dynamic(light: 0xC41A16, dark: 0xFF8170)
    static let comment = dynamic(light: 0x6C7986, dark: 0x7F8C98)
    static let number = dynamic(light: 0x1C00CF, dark: 0xD9C97C)
    static let function = dynamic(light: 0x4B21B0, dark: 0xB48CFF)
    static let attribute = dynamic(light: 0x9B2393, dark: 0xFFA14F)

    static func color(_ kind: SyntaxKind) -> Color {
        switch kind {
        case .keyword: keyword
        case .type: type
        case .string: string
        case .comment: comment
        case .number: number
        case .function: function
        case .attribute: attribute
        }
    }
}
