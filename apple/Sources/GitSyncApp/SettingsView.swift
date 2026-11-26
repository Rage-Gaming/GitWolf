import AppKit
import SwiftUI

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general = "General", git = "Git", shortcuts = "Shortcuts"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .git: "arrow.triangle.branch"
        case .shortcuts: "command"
        }
    }
    var subtitle: String {
        switch self {
        case .general: "Look, sync and diffs"
        case .git: "Git executable"
        case .shortcuts: "Keys for everything"
        }
    }
}

struct SettingsView: View {
    @State private var pane = SettingsPane.general
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(pane.rawValue)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                        switch pane {
                        case .general: GeneralSettings()
                        case .git: GitSettings()
                        case .shortcuts: ShortcutsSettings()
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
            }
            .panel()
            .padding(.trailing, 10).padding(.vertical, 10)
        }
        .frame(width: 720, height: 560)
        .containerBackground(for: .window) { WindowBackdrop() }
        .background(SettingsWindowConfigurator())
        .tint(Theme.brand)
        .modifier(AppearanceModifier())
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 9) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Theme.brand, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text("Settings").font(.system(size: 15, weight: .semibold, design: .rounded))
            }
            .padding(.horizontal, 10).padding(.bottom, 14).padding(.top, 8)

            ForEach(SettingsPane.allCases) { item in
                let selected = pane == item
                Button {
                    withAnimation(.snappy(duration: 0.22)) { pane = item }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(selected ? .white : .secondary)
                            .frame(width: 24, height: 24)
                            .background(selected ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Color.primary.opacity(0.07)),
                                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.rawValue).fontWeight(.medium)
                            Text(item.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Theme.brand.opacity(0.14))
                                .matchedGeometryEffect(id: "pane", in: selection)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("GitSync \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                .font(.caption2).foregroundStyle(.tertiary).padding(.horizontal, 10)
        }
        .padding(.horizontal, 10).padding(.top, 34).padding(.bottom, 12)
        .frame(width: 190)
    }
}

// MARK: - Building blocks

/// A titled group of rows inside the settings panel.
private struct Group<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold)).tracking(0.6)
                .foregroundStyle(.secondary).padding(.horizontal, 4)
            VStack(spacing: 0) { content }
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        }
    }
}

private struct Row<Trailing: View>: View {
    let icon: String
    let tint: Color
    let title: String
    var detail: String?
    var divider = true
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(tint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).fontWeight(.medium)
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 12)
                trailing
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            if divider { Divider().padding(.leading, 50).opacity(0.6) }
        }
    }
}

/// Pill-styled menu picker that matches the rest of the app.
private struct PillPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(label: String, value: Value)]

    var body: some View {
        Menu {
            ForEach(options.indices, id: \.self) { i in
                Button {
                    selection = options[i].value
                } label: {
                    if options[i].value == selection { Label(options[i].label, systemImage: "checkmark") }
                    else { Text(options[i].label) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(options.first { $0.value == selection }?.label ?? "—").font(.callout)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .tint(.primary)
        .fixedSize()
        .pill()
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @AppStorage(SettingsKey.appearance) private var appearance = AppearanceChoice.system.rawValue
    @AppStorage(SettingsKey.accent) private var accent = AccentChoice.indigo.rawValue
    @AppStorage(SettingsKey.autoFetchMinutes) private var autoFetch = 5
    @AppStorage(SettingsKey.commitPageSize) private var pageSize = 1000
    @AppStorage(SettingsKey.diffContext) private var context = 4
    @AppStorage(SettingsKey.syntaxHighlighting) private var syntax = true

    var body: some View {
        Group(title: "Appearance") {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    ForEach(AppearanceChoice.allCases) { choice in
                        AppearanceCard(choice: choice, selected: appearance == choice.rawValue) {
                            withAnimation(.snappy(duration: 0.2)) { appearance = choice.rawValue }
                        }
                    }
                }
                .padding(10)
                Divider().opacity(0.6)
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Accent color").fontWeight(.medium)
                        Text(AccentChoice(rawValue: accent)?.title ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    HStack(spacing: 6) {
                        ForEach(AccentChoice.allCases) { choice in
                            let selected = accent == choice.rawValue
                            Button {
                                withAnimation(.snappy(duration: 0.2)) { accent = choice.rawValue }
                            } label: {
                                Circle()
                                    .fill(choice.primary)
                                    .frame(width: 20, height: 20)
                                    .overlay {
                                        if selected { Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white) }
                                    }
                                    .padding(3)
                                    .overlay(Circle().strokeBorder(selected ? choice.primary : .clear, lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                            .help(choice.title)
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }

        Group(title: "Sync") {
            Row(icon: "arrow.triangle.2.circlepath", tint: .blue, title: "Background fetch",
                detail: "Keeps ahead/behind counts up to date", divider: false) {
                PillPicker(selection: $autoFetch, options: [
                    ("Never", 0), ("Every minute", 1), ("Every 5 minutes", 5),
                    ("Every 15 minutes", 15), ("Every 30 minutes", 30)])
            }
        }

        Group(title: "History & Diffs") {
            Row(icon: "clock.arrow.circlepath", tint: .purple, title: "Commits per page",
                detail: "How many commits to load at a time") {
                PillPicker(selection: $pageSize, options: [("500", 500), ("1,000", 1000), ("2,000", 2000), ("5,000", 5000)])
            }
            Row(icon: "chevron.left.forwardslash.chevron.right", tint: .pink, title: "Syntax highlighting",
                detail: "Color keywords, strings and comments in diffs") {
                Toggle("", isOn: $syntax).labelsHidden().toggleStyle(.switch)
            }
            Row(icon: "text.alignleft", tint: .orange, title: "Diff context",
                detail: "Unchanged lines around each change", divider: false) {
                PillPicker(selection: $context, options: [1, 3, 4, 6, 10].map { ("\($0) lines", $0) })
            }
        }
    }
}

private struct AppearanceCard: View {
    let choice: AppearanceChoice
    let selected: Bool
    let action: () -> Void

    private var icon: String {
        switch choice {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                preview
                    .frame(height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                HStack(spacing: 5) {
                    Image(systemName: icon).font(.system(size: 11))
                    Text(choice.title).font(.callout.weight(.medium))
                }
                .foregroundStyle(selected ? Theme.brand : .secondary)
            }
            .padding(7)
            .frame(maxWidth: .infinity)
            .background(selected ? Theme.brand.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Theme.brand : Color.primary.opacity(0.08), lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var preview: some View {
        switch choice {
        case .light: mini(dark: false)
        case .dark: mini(dark: true)
        case .system:
            HStack(spacing: 0) {
                mini(dark: false).frame(maxWidth: .infinity)
                mini(dark: true).frame(maxWidth: .infinity)
            }
        }
    }

    private func mini(dark: Bool) -> some View {
        let bg = dark ? Color(red: 0.09, green: 0.09, blue: 0.12) : Color(red: 0.94, green: 0.95, blue: 0.97)
        let card = dark ? Color(red: 0.14, green: 0.14, blue: 0.18) : Color.white
        return ZStack {
            bg
            VStack(spacing: 4) {
                Capsule().fill(Theme.brand).frame(width: 34, height: 5)
                Capsule().fill(card).frame(width: 42, height: 5)
                Capsule().fill(card).frame(width: 30, height: 5)
            }
            .padding(6)
            .background(card.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

// MARK: - Git

private struct GitSettings: View {
    @AppStorage(SettingsKey.gitPath) private var gitPath = ""

    private var trimmed: String { gitPath.trimmingCharacters(in: .whitespaces) }
    private var isValid: Bool { trimmed.isEmpty || FileManager.default.isExecutableFile(atPath: trimmed) }

    var body: some View {
        Group(title: "Git Executable") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    TextField(AppSettings.defaultGitPath, text: $gitPath)
                        .textFieldStyle(.plain)
                        .font(.system(.callout, design: .monospaced))
                        .padding(.horizontal, 11).padding(.vertical, 7)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                        .overlay(Capsule().strokeBorder(isValid ? Color.primary.opacity(0.1) : Color.orange.opacity(0.7)))
                    Button("Choose…", action: choose).buttonStyle(.plain).font(.callout).pill()
                    if !gitPath.isEmpty {
                        Button("Reset") { gitPath = "" }.buttonStyle(.plain).font(.callout).pill()
                    }
                }
                if isValid {
                    Label("Using \(AppSettings.shared.gitPath)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Not an executable file. Falling back to \(AppSettings.defaultGitPath).",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Text("Leave empty to use the system Git, or point to a Homebrew or custom build.")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(12)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { gitPath = url.path }
    }
}

// MARK: - Shortcuts

private struct ShortcutsSettings: View {
    private struct Item: Identifiable {
        let id = UUID()
        let title: String
        let keys: [String]
    }
    private struct Section: Identifiable {
        let id = UUID()
        let title: String
        let items: [Item]
    }

    private let sections: [Section] = [
        Section(title: "Repositories", items: [
            Item(title: "Open repository…", keys: ["⌘", "O"]),
            Item(title: "Close repository", keys: ["⇧", "⌘", "W"]),
            Item(title: "Jump to…", keys: ["⌘", "K"]),
            Item(title: "Switch to repository 1–9", keys: ["⌘", "1…9"]),
            Item(title: "Next repository", keys: ["⌃", "⇥"]),
            Item(title: "Previous repository", keys: ["⌃", "⇧", "⇥"]),
        ]),
        Section(title: "Views", items: [
            Item(title: "Show history", keys: ["⌥", "⌘", "1"]),
            Item(title: "Show changes", keys: ["⌥", "⌘", "2"]),
        ]),
        Section(title: "Sync", items: [
            Item(title: "Refresh", keys: ["⌘", "R"]),
            Item(title: "Fetch", keys: ["⇧", "⌘", "F"]),
            Item(title: "Pull", keys: ["⇧", "⌘", "L"]),
            Item(title: "Push", keys: ["⇧", "⌘", "P"]),
        ]),
        Section(title: "App", items: [
            Item(title: "Settings", keys: ["⌘", ","]),
        ]),
    ]

    var body: some View {
        ForEach(sections) { section in
            Group(title: section.title) {
                ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                    VStack(spacing: 0) {
                        HStack(spacing: 4) {
                            Text(item.title)
                            Spacer(minLength: 12)
                            ForEach(item.keys, id: \.self) { Kbd(text: $0) }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        if index < section.items.count - 1 { Divider().padding(.leading, 12).opacity(0.6) }
                    }
                }
            }
        }
    }
}

// MARK: - Window chrome

/// Keeps only the close button, like a preferences window should.
private struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { Self.configure(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private static func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isMovableByWindowBackground = true
    }
}
