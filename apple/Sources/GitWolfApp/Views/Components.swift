import GitWolfCore
import SwiftUI

// MARK: - Design tokens

enum Theme {
    /// Height of every control in the top bar.
    static let barControlHeight: CGFloat = 36

    /// User-selectable accent (Settings). Views re-render when it changes via `AppearanceModifier`.
    static var brand: Color { AccentChoice.current.primary }

    static let laneColors: [Color] = [
        Color(red: 0.36, green: 0.52, blue: 1.0), Color(red: 0.74, green: 0.38, blue: 0.96),
        Color(red: 0.98, green: 0.40, blue: 0.62), Color(red: 1.0, green: 0.62, blue: 0.25),
        Color(red: 0.18, green: 0.76, blue: 0.72), Color(red: 0.30, green: 0.80, blue: 0.45),
        Color(red: 0.55, green: 0.50, blue: 1.0), Color(red: 0.95, green: 0.35, blue: 0.38),
    ]
    static func lane(_ i: Int) -> Color { laneColors[i % laneColors.count] }
    static let laneWidth: CGFloat = 14
    static let historyRowHeight: CGFloat = 50
    static let panelRadius: CGFloat = 16

    static func color(for kind: ChangeKind) -> Color {
        switch kind {
        case .added, .copied: .green
        case .deleted: .red
        case .modified, .typeChanged: .orange
        case .renamed: .blue
        case .untracked: .teal
        case .unmerged: .pink
        }
    }
}

/// Stable (non-randomised) hash so a person or repo always gets the same colour.
func stableHash(_ s: String) -> Int {
    s.utf8.reduce(5381) { ($0 &* 33) &+ Int($1) }
}

/// Flat, stable colour for a person or repository avatar.
func avatarColor(for seed: String) -> Color {
    let hue = Double(abs(stableHash(seed.lowercased())) % 360) / 360
    return Color(hue: hue, saturation: 0.5, brightness: 0.78)
}

// MARK: - Modifiers

/// Window backdrop. Dark keeps the translucent material; light uses a near-opaque soft canvas so
/// the wallpaper doesn't turn the whole window grey and muddy.
struct WindowBackdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            (scheme == .light
                ? Color(red: 0.945, green: 0.949, blue: 0.972)
                : Color(red: 0.075, green: 0.079, blue: 0.102))
                .opacity(scheme == .light ? 0.94 : 0.96)
        }
    }
}

private struct PanelStyle: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let light = scheme == .light
        let shape = RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
        // The shadow sits on a background shape, not on the content, so scrolling content is never
        // re-rendered through an offscreen shadow pass.
        content
            .background {
                shape.fill(light ? Color(nsColor: .textBackgroundColor) : Color(red: 0.118, green: 0.122, blue: 0.149))
                    .shadow(color: .black.opacity(light ? 0.09 : 0.35), radius: light ? 14 : 16, y: light ? 5 : 6)
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(light ? 0.11 : 0.12), lineWidth: 1))
    }
}

private struct PillStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(.horizontal, 11).padding(.vertical, 6).barSurface()
    }
}

/// Every control in the top bar: one height, one surface. Icon-only controls are circles.
private struct ToolbarControlStyle: ViewModifier {
    let square: Bool
    func body(content: Content) -> some View {
        content
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, square ? 0 : 14)
            .frame(width: square ? Theme.barControlHeight : nil, height: Theme.barControlHeight)
            .barSurface()
    }
}

private struct BarSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let light = scheme == .light
        content
            .background(light ? Color.white.opacity(0.8) : Color.primary.opacity(0.09), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
            .shadow(color: .black.opacity(light ? 0.05 : 0), radius: 2, y: 1)
    }
}

extension View {
    /// Floating rounded panel used for the main content columns.
    func panel() -> some View { modifier(PanelStyle()) }

    func pill() -> some View { modifier(PillStyle()) }

    /// The shared capsule fill, border and shadow of the top bar.
    func barSurface() -> some View { modifier(BarSurface()) }

    /// A top bar control at the shared height; `square` makes an icon-only circle.
    func toolbarControl(square: Bool = false) -> some View { modifier(ToolbarControlStyle(square: square)) }

    /// Exposes a tap-to-select row to VoiceOver and Full Keyboard Access as a button with a spoken label.
    func selectableRow(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        self.accessibilityElement(children: .contain)
            .accessibilityLabel(label)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, action)
    }

    func rowBackground(selected: Bool, hovering: Bool, radius: CGFloat = 10) -> some View {
        self.background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(selected ? Theme.brand.opacity(0.16) : (hovering ? Color.primary.opacity(0.055) : .clear))
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.12), value: selected))
    }
}

struct Kbd: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// Invisible draggable gap between panels.
struct SplitHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    @State private var start: Double?

    var body: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if start == nil { start = width }
                        width = min(max((start ?? width) + value.translation.width, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in start = nil })
    }
}

/// A horizontal divider the user drags up and down to size the pane next to it.
/// `inverted` is for a pane below the handle, which grows when the handle moves up.
struct VSplitHandle: View {
    @Binding var height: Double
    let range: ClosedRange<Double>
    var inverted = false
    @State private var start: Double?

    var body: some View {
        Color.clear
            .frame(height: 9)
            .overlay(Divider())
            .contentShape(Rectangle())
            .pointerStyle(.rowResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if start == nil { start = height }
                        let delta = inverted ? -value.translation.height : value.translation.height
                        height = min(max((start ?? height) + delta, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in start = nil })
    }
}

struct SearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
            TextField(prompt, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
        .background(Color.primary.opacity(0.055), in: Capsule())
    }
}

// MARK: - Small views

struct StatusBadge: View {
    let kind: ChangeKind
    var body: some View {
        Text(String(kind.rawValue))
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(Theme.color(for: kind))
            .frame(width: 19, height: 19)
            .background(Theme.color(for: kind).opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct RefChip: View {
    let label: RefLabel
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8, weight: .bold))
            Text(label.name).lineLimit(1)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .padding(.horizontal, 7).padding(.vertical, 2.5)
        .foregroundStyle(color)
        .background(color.opacity(label.isCurrent ? 0.22 : 0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(label.isCurrent ? 0.35 : 0.0)))
    }
    /// Branches and tags use the same icons as in the sidebar, chosen from the name.
    private var branchLook: FileIcon? {
        switch label.kind {
        case .local: return FileIcons.branchIcon(named: label.name)
        case .tag: return FileIcons.tagIcon(named: label.name)
        case .remote:
            // "origin/feature/x" → look at "feature/x".
            let name = label.name.split(separator: "/", maxSplits: 1).dropFirst().first.map(String.init) ?? label.name
            return FileIcons.branchIcon(named: name)
        default: return nil
        }
    }
    private var icon: String {
        if let look = branchLook, case .symbol(let symbol) = look.glyph { return symbol }
        switch label.kind {
        case .tag: return "tag.fill"
        case .remote: return "cloud.fill"
        case .head: return "scope"
        case .local: return "arrow.triangle.branch"
        }
    }
    private var color: Color {
        if let look = branchLook { return Color(hex: look.color) }
        switch label.kind {
        case .tag: return .orange
        case .head: return .gray
        default: return Theme.brand
        }
    }
}

private struct LFSPathsKey: EnvironmentKey { static let defaultValue: Set<String> = [] }
extension EnvironmentValues {
    /// Paths of changed files stored with Git LFS.
    var lfsPaths: Set<String> {
        get { self[LFSPathsKey.self] }
        set { self[LFSPathsKey.self] = newValue }
    }
}

struct FileRow: View {
    let change: FileChange
    @Environment(\.lfsPaths) private var lfsPaths
    var body: some View {
        HStack(spacing: 9) {
            StatusBadge(kind: change.kind)
            FileIconView(path: change.path)
            Text(change.fileName).fontWeight(.medium).lineLimit(1)
            if lfsPaths.contains(change.path) {
                Text("LFS").font(.system(size: 9.5, weight: .bold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.teal.opacity(0.18), in: Capsule()).foregroundStyle(.teal)
                    .help("Stored with Git LFS")
            }
            if !change.directory.isEmpty {
                if let folder = FileIcons.folderIcon(containing: change.path) { FileIconView(icon: folder, size: 13) }
                Text(change.directory).foregroundStyle(.secondary).font(.caption).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
    }
}

struct BusyPill: View {
    let label: String
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(label).font(.callout.weight(.medium))
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .padding(.bottom, 22)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// Text prompt used for branch / tag / stash names.
struct PromptSheet: View {
    let title: String
    let placeholder: String
    let confirm: String
    var toggleTitle: String?
    var allowEmpty = false
    var initial = ""
    let onConfirm: (String, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var toggle = true
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: 17, weight: .semibold, design: .rounded))
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .focused($focused)
                .onSubmit(submit)
            if let toggleTitle { Toggle(toggleTitle, isOn: $toggle) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(confirm, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!allowEmpty && text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 400)
        .onAppear { text = initial; focused = true }
    }

    private func submit() {
        let value = text.trimmingCharacters(in: .whitespaces)
        guard allowEmpty || !value.isEmpty else { return }
        onConfirm(value, toggle)
        dismiss()
    }
}

/// A button that puts `text` on the clipboard and shows "copied" for a moment. `label` gets whether it just copied,
/// so the caller decides how the confirmation looks (a tick, a word).
struct CopyButton<Label: View>: View {
    let text: String
    @ViewBuilder var label: (_ copied: Bool) -> Label
    @State private var copied = false
    @State private var reset: Task<Void, Never>?

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation(.snappy(duration: 0.18)) { copied = true }
            reset?.cancel()
            reset = Task {
                try? await Task.sleep(for: .seconds(1.6))
                if !Task.isCancelled { withAnimation(.snappy(duration: 0.18)) { copied = false } }
            }
        } label: { label(copied) }
        .onDisappear { reset?.cancel() }
    }
}
