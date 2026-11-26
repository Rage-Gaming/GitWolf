import GitSyncCore
import SwiftUI

// MARK: - Design tokens

enum Theme {
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
        content
            .background((light ? Color(nsColor: .textBackgroundColor) : Color(red: 0.118, green: 0.122, blue: 0.149)))
            .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(light ? 0.11 : 0.12), lineWidth: 1))
            .shadow(color: .black.opacity(light ? 0.09 : 0.35), radius: light ? 14 : 16, y: light ? 5 : 6)
    }
}

private struct PillStyle: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let light = scheme == .light
        content
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(light ? Color.white.opacity(0.8) : Color.primary.opacity(0.09), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(light ? 0.12 : 0.12)))
            .shadow(color: .black.opacity(light ? 0.05 : 0), radius: 2, y: 1)
    }
}

extension View {
    /// Floating rounded panel used for the main content columns.
    func panel() -> some View { modifier(PanelStyle()) }

    func pill() -> some View { modifier(PillStyle()) }

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

struct AvatarView: View {
    let name: String
    let email: String
    var size: CGFloat = 26

    var body: some View {
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        Text(initials.isEmpty ? "?" : initials)
            .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(avatarColor(for: email), in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
    }
}

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
    private var icon: String {
        switch label.kind {
        case .tag: "tag.fill"
        case .remote: "cloud.fill"
        case .head: "scope"
        case .local: "arrow.triangle.branch"
        }
    }
    private var color: Color {
        switch label.kind {
        case .tag: .orange
        case .remote: .purple
        case .head: .gray
        case .local: Theme.brand
        }
    }
}

struct FileRow: View {
    let change: FileChange
    var body: some View {
        HStack(spacing: 9) {
            StatusBadge(kind: change.kind)
            Text(change.fileName).fontWeight(.medium).lineLimit(1)
            if !change.directory.isEmpty {
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
