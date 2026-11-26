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
    var hunkSummary: @MainActor (Int) -> String
    var lineSummary: @MainActor () -> String
    /// Nil when this file's hunks can't be stashed (e.g. it has staged changes).
    var stashHunk: (@MainActor (Int) -> Void)?
}

struct DiffPane: View {
    let diff: FileDiff?
    let path: String?
    var staging: DiffStaging?
    /// Re-reads the diff after a display option changes. Nil hides the options (read-only previews).
    var reload: (() -> Void)?
    /// Loads both versions of an image file. Nil shows binary files as plain "Binary File".
    var images: (() async -> (old: Data?, new: Data?))?

    @AppStorage(SettingsKey.syntaxHighlighting) private var syntaxOn = true
    @AppStorage(SettingsKey.ignoreWhitespace) private var ignoreWhitespace = false
    @AppStorage(SettingsKey.fullFileDiffs) private var fullFile = false
    @State private var expandedRuns: Set<Int> = []
    @State private var imageData: (old: Data?, new: Data?)?
    @AppStorage(SettingsKey.diffLayout) private var layoutRaw = DiffLayout.unified.rawValue
    @State private var highlights: [Int: AttributedString] = [:]

    private var layout: DiffLayout { DiffLayout(rawValue: layoutRaw) ?? .unified }

    var body: some View {
        VStack(spacing: 0) {
            if let path {
                HStack(spacing: 8) {
                    FileIconView(path: path)
                    let dir = (path as NSString).deletingLastPathComponent
                    if !dir.isEmpty, let folder = FileIcons.folderIcon(containing: path) { FileIconView(icon: folder, size: 14) }
                    if !dir.isEmpty { Text(dir + "/").foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
                    Text((path as NSString).lastPathComponent).fontWeight(.semibold).lineLimit(1)
                    Spacer()
                    if reload != nil, let diff, !diff.isBinary || ignoreWhitespace || fullFile {
                        optionToggle("Ignore whitespace", systemImage: "text.alignleft", isOn: $ignoreWhitespace)
                        optionToggle("Show whole file", systemImage: "doc.plaintext", isOn: $fullFile)
                    }
                    if let diff, !diff.isBinary {
                        layoutToggle
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

    private func optionToggle(_ title: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
            expandedRuns = []
            reload?()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isOn.wrappedValue ? Color.white : Color.secondary)
                .frame(width: 26, height: 20)
                .background(isOn.wrappedValue ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Color.primary.opacity(0.07)),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
    }

    private var layoutToggle: some View {
        HStack(spacing: 2) {
            ForEach(DiffLayout.allCases) { option in
                let on = layout == option
                Button { layoutRaw = option.rawValue } label: {
                    Image(systemName: option.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                        .frame(width: 26, height: 20)
                        .background(on ? Color(nsColor: .textBackgroundColor) : .clear,
                                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .shadow(color: .black.opacity(on ? 0.12 : 0), radius: 1.5, y: 0.5)
                }
                .buttonStyle(.plain)
                .help(option.title)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .padding(.trailing, 4)
    }

    private static let charWidth: CGFloat =
        NSFont.monospacedSystemFont(ofSize: 12, weight: .regular).maximumAdvancement.width

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

    private struct ImageKey: Hashable { let path: String; let signature: [String] }

    private func computeHighlights() async {
        guard let diff, let path, !diff.isBinary else {
            if !highlights.isEmpty { highlights = [:] }
            return
        }
        let syntaxOn = syntaxOn
        let result = await Task.detached(priority: .userInitiated) { () -> [Int: AttributedString] in
            let tokens = syntaxOn ? SyntaxHighlighter.tokens(for: diff, path: path) : [:]
            let inline = diff.inlineRanges()
            var out: [Int: AttributedString] = [:]
            for line in diff.lines {
                guard tokens[line.id] != nil || inline[line.id] != nil else { continue }
                let spans = tokens[line.id] ?? []
                var text = AttributedString(line.text)
                for range in inline[line.id] ?? [] {
                    let chars = text.characters
                    guard range.upperBound <= chars.count else { continue }
                    let lower = chars.index(chars.startIndex, offsetBy: range.lowerBound)
                    let upper = chars.index(chars.startIndex, offsetBy: range.upperBound)
                    text[lower..<upper].backgroundColor = (line.kind == .addition ? Color.green : Color.red).opacity(0.38)
                }
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
                if let path, let images, GitRepository.isImagePath(path) {
                    ImageDiffView(data: imageData)
                        .task(id: ImageKey(path: path, signature: diff.header)) { imageData = nil; imageData = await images() }
                } else {
                    ContentUnavailableView("Binary File", systemImage: "doc.zipper", description: Text("No preview available."))
                }
            } else if diff.lines.isEmpty {
                ContentUnavailableView("No Differences", systemImage: "equal.circle")
            } else {
                let staging = diff.ignoresWhitespace ? nil : staging
                let runs = diff.collapsibleRuns().filter { !expandedRuns.contains($0.lowerBound) }
                let hidden = Set(runs.flatMap { Array($0) })
                let runStarts = Dictionary(uniqueKeysWithValues: runs.map { ($0.lowerBound, $0.count) })
                GeometryReader { geo in
                    // Lazy stacks don't report the width of rows that aren't on screen yet, so give
                    // the content an explicit width; otherwise long lines can't be scrolled to.
                    let longest = diff.lines.reduce(0) { max($0, $1.text.utf8.count) }
                    let text = CGFloat(longest) * Self.charWidth + 32
                    let select: CGFloat = staging != nil ? 22 : 0
                    let unifiedWidth = max(geo.size.width, select + 46 + 46 + 22 + text)
                    // Side by side wraps long lines so both halves always fit the panel.
                    let half = geo.size.width / 2
                    let width = layout == .split ? geo.size.width : unifiedWidth
                    ScrollView(layout == .split ? [.vertical] : [.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if layout == .split {
                                ForEach(SideBySide.rows(for: diff).filter { row in
                                    guard let l = row.left, row.left?.id == row.right?.id else { return true }
                                    return !hidden.contains(l.id) || runStarts[l.id] != nil
                                }) { row in
                                    if let l = row.left, row.left?.id == row.right?.id, let count = runStarts[l.id] {
                                        FoldedRow(count: count, minWidth: width) { expandedRuns.insert(l.id) }
                                    } else if let header = row.header {
                                        HunkHeaderRow(line: header, minWidth: width, staging: staging, confirmDiscard: confirmDiscard)
                                    } else {
                                        HStack(alignment: .top, spacing: 0) {
                                            SplitHalf(line: row.left, side: .left, width: half, staging: staging,
                                                      highlight: row.left.flatMap { highlights[$0.id] })
                                            SplitHalf(line: row.right, side: .right, width: half, staging: staging,
                                                      highlight: row.right.flatMap { highlights[$0.id] })
                                        }
                                    }
                                }
                            } else {
                                ForEach(diff.lines.filter { !hidden.contains($0.id) || runStarts[$0.id] != nil }) { line in
                                    if let count = runStarts[line.id] {
                                        FoldedRow(count: count, minWidth: width) { expandedRuns.insert(line.id) }
                                    } else if line.kind == .hunkHeader {
                                        HunkHeaderRow(line: line, minWidth: width, staging: staging, confirmDiscard: confirmDiscard)
                                    } else {
                                        DiffLineRow(line: line, minWidth: width, staging: staging, highlight: highlights[line.id])
                                    }
                                }
                            }
                            if diff.ignoresWhitespace {
                                Text("Whitespace changes are hidden, so staging is turned off for this view.")
                                    .font(.caption).foregroundStyle(.secondary).padding(12)
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
                        confirmDiscard("\(n) selected line\(n == 1 ? "" : "s") (\(staging.lineSummary()))") { staging.lines(.discard) }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                Button { staging.clear() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("Clear selection").accessibilityLabel("Clear selection")
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
        alert.informativeText = "These changes will be removed from your working tree and can’t be recovered."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { action() }
    }
}

/// A long stretch of unchanged lines, folded away until clicked.
private struct FoldedRow: View {
    let count: Int
    let minWidth: CGFloat
    let expand: () -> Void

    var body: some View {
        Button(action: expand) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.and.down.text.horizontal")
                Text("\(count) unchanged lines")
                Spacer(minLength: 0)
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.leading, 70).padding(.vertical, 4)
            .frame(minWidth: minWidth, alignment: .leading)
            .background(Color.primary.opacity(0.05))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(count) unchanged lines, folded")
        .accessibilityHint("Shows the unchanged lines")
    }
}

/// Old and new versions of an image side by side.
private struct ImageDiffView: View {
    let data: (old: Data?, new: Data?)?

    var body: some View {
        if let data {
            HStack(spacing: 1) {
                pane("Before", data.old, tint: .red)
                pane("After", data.new, tint: .green)
            }
            .background(Color.primary.opacity(0.10))
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func pane(_ title: String, _ data: Data?, tint: Color) -> some View {
        VStack(spacing: 8) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(tint)
            if let data, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("\(title) image")
                let rep = image.representations.first
                Text("\(rep?.pixelsWide ?? Int(image.size.width)) × \(rep?.pixelsHigh ?? Int(image.size.height)) px · \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
            } else if data != nil {
                Text("Can’t preview this image").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(title == "Before" ? "Did not exist" : "Deleted").foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
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
                        .background(Theme.brand, in: Capsule())
                }
                .buttonStyle(.plain)
                if let stash = staging.stashHunk {
                    Button { stash(line.hunkIndex) } label: {
                        Image(systemName: "tray.and.arrow.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain).help("Stash this hunk").accessibilityLabel("Stash this hunk")
                }
                if !staging.staged {
                    Button {
                        confirmDiscard("this hunk (\(staging.hunkSummary(line.hunkIndex)))") { staging.hunk(line.hunkIndex, .discard) }
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.red.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain).help("Discard hunk").accessibilityLabel("Discard hunk")
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

/// One half (old or new) of a side-by-side row.
private struct SplitHalf: View {
    enum Side { case left, right }
    let line: DiffLine?
    let side: Side
    let width: CGFloat
    let staging: DiffStaging?
    var highlight: AttributedString?
    @State private var hovering = false

    private var selected: Bool { line.map { staging?.selection.contains($0.id) ?? false } ?? false }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if let line {
                HStack(alignment: .top, spacing: 0) {
                    if let staging {
                        if line.isChange {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 12))
                                .foregroundStyle(selected ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(.tertiary))
                                .opacity(selected || hovering ? 1 : 0.35)
                                .frame(width: 20)
                        } else {
                            Color.clear.frame(width: 20)
                        }
                    }
                    Text((side == .left ? line.oldNumber : line.newNumber).map(String.init) ?? "")
                        .frame(width: 36, alignment: .trailing).foregroundStyle(.tertiary)
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard let staging, line.isChange else { return }
                    staging.toggle(line.id, NSEvent.modifierFlags.contains(.shift))
                }
                Text(marker(line)).frame(width: 18).foregroundStyle(line.kind == .addition ? Color.green : Color.red)
                    .frame(maxHeight: .infinity, alignment: .top)
                Group {
                    if let highlight { Text(highlight) } else { Text(line.text.isEmpty ? " " : line.text) }
                }
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.trailing, 8)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, 1)
        .frame(width: width, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(background)
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(Theme.brand).frame(width: 3) }
        }
        .overlay(alignment: .trailing) {
            if side == .left { Rectangle().fill(Color.primary.opacity(0.10)).frame(width: 1) }
        }
        .onHover { hovering = $0 }
    }

    private func marker(_ line: DiffLine) -> String {
        switch line.kind {
        case .addition: "+"
        case .deletion: "−"
        default: ""
        }
    }

    private var background: Color {
        guard let line else { return Color.primary.opacity(0.035) }
        if selected { return Theme.brand.opacity(0.22) }
        switch line.kind {
        case .addition: return .green.opacity(0.13)
        case .deletion: return .red.opacity(0.12)
        default: return .clear
        }
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
