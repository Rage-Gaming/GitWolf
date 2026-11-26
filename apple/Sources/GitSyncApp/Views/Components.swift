import GitSyncCore
import SwiftUI

enum Theme {
    static let laneColors: [Color] = [.blue, .purple, .pink, .orange, .teal, .green, .indigo, .red, .mint, .cyan]
    static func lane(_ i: Int) -> Color { laneColors[i % laneColors.count] }
    static let laneWidth: CGFloat = 14
    static let historyRowHeight: CGFloat = 46

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

/// Stable (non-randomised) hash so a person always gets the same avatar colour.
private func stableHash(_ s: String) -> Int {
    s.utf8.reduce(5381) { ($0 &* 33) &+ Int($1) }
}

struct AvatarView: View {
    let name: String
    let email: String
    var size: CGFloat = 26

    var body: some View {
        let hue = Double(abs(stableHash(email.lowercased())) % 360) / 360
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        Text(initials.isEmpty ? "?" : initials)
            .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(
                    colors: [Color(hue: hue, saturation: 0.55, brightness: 0.85), Color(hue: hue, saturation: 0.7, brightness: 0.62)],
                    startPoint: .top, endPoint: .bottom),
                in: Circle())
    }
}

struct StatusBadge: View {
    let kind: ChangeKind
    var body: some View {
        Text(String(kind.rawValue))
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(Theme.color(for: kind))
            .frame(width: 18, height: 18)
            .background(Theme.color(for: kind).opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
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
        .padding(.horizontal, 6).padding(.vertical, 2)
        .foregroundStyle(color)
        .background(color.opacity(label.isCurrent ? 0.25 : 0.14), in: Capsule())
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
        case .local: .blue
        }
    }
}

struct FileRow: View {
    let change: FileChange
    var body: some View {
        HStack(spacing: 8) {
            StatusBadge(kind: change.kind)
            Text(change.fileName).lineLimit(1)
            if !change.directory.isEmpty {
                Text(change.directory).foregroundStyle(.secondary).font(.caption).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Text prompt used for branch / tag / stash names.
struct PromptSheet: View {
    let title: String
    let placeholder: String
    let confirm: String
    var toggleTitle: String?
    var allowEmpty = false
    let onConfirm: (String, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var toggle = true
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
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
        .padding(20)
        .frame(width: 380)
        .onAppear { focused = true }
    }

    private func submit() {
        let value = text.trimmingCharacters(in: .whitespaces)
        guard allowEmpty || !value.isEmpty else { return }
        onConfirm(value, toggle)
        dismiss()
    }
}
