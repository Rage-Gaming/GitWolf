import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        #if DEBUG
        // GITSYNC_SNAPSHOT=/path.png renders the window to a PNG after a delay, then quits.
        // GITSYNC_APPEARANCE=dark|light forces an appearance for the capture.
        if let path = ProcessInfo.processInfo.environment["GITSYNC_SNAPSHOT"] {
            let dark = ProcessInfo.processInfo.environment["GITSYNC_APPEARANCE"] == "dark"
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let target = ProcessInfo.processInfo.environment["GITSYNC_SNAPSHOT_WINDOW"]
            let wantSettings = target == "settings"
            let wantSheet = target?.hasPrefix("sheet:") == true
            if wantSettings || wantSheet {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    // `settings` opens the first menu's Settings item; `sheet:<Title>` any menu item by title.
                    let title = wantSheet ? String(target!.dropFirst(6)) : "Settings"
                    let menus = wantSheet ? (NSApp.mainMenu?.items.compactMap(\.submenu) ?? []) : [NSApp.mainMenu?.items.first?.submenu].compactMap { $0 }
                    for menu in menus {
                        if let i = menu.items.firstIndex(where: { $0.title.hasPrefix(title) }) {
                            menu.performActionForItem(at: i)
                            break
                        }
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                let main = NSApp.windows.first { $0.canBecomeMain && $0.isVisible && $0.title != "Settings" }
                let window = wantSettings
                    ? NSApp.windows.first { $0.title == "Settings" && $0.isVisible }
                    : (wantSheet ? main?.attachedSheet : main)
                if let view = window?.contentView,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    do { try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path)) }
                    catch { NSLog("snapshot write failed: \(error)") }
                } else { NSLog("snapshot: no view/rep") }
                if wantSheet { exit(0) }
                NSApp.terminate(nil)
            }
        }
        #endif
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct GitSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 880)
        .commands { AppCommands() }

        // A regular window (not the `Settings` scene) so it gets the same hidden-title-bar chrome
        // as the main window; the Settings scene re-applies its own opaque title bar.
        Window("Settings", id: "settings") { SettingsView() }
            .windowStyle(.hiddenTitleBar)
            .windowResizability(.contentSize)
            .defaultPosition(.center)
    }
}

struct AppearanceModifier: ViewModifier {
    @AppStorage(SettingsKey.appearance) private var appearance = AppearanceChoice.system.rawValue

    @AppStorage(SettingsKey.accent) private var accent = AccentChoice.indigo.rawValue

    func body(content: Content) -> some View {
        content
            .tint(Theme.brand)
            // Theme colours are read from settings, so rebuild the tree when the accent changes.
            .id(accent)
            // Set the app-wide NSAppearance instead of `preferredColorScheme`: going back to
            // "System" with the latter leaves windows (materials, backdrops) half-updated.
            .onChange(of: appearance, initial: true) { _, value in
                AppearanceChoice(rawValue: value)?.apply()
            }
    }
}

struct RootView: View {
    @State private var workspace = Workspace()

    var body: some View {
        HStack(spacing: 0) {
            RepoRail(workspace: workspace)
            ZStack {
                if let store = workspace.selected {
                    RepositoryView(store: store, workspace: workspace).id(store.id)
                } else {
                    DashboardView(workspace: workspace)
                }
            }
        }
        .frame(minWidth: 1080, minHeight: 640)
        .containerBackground(for: .window) { WindowBackdrop() }
        .overlay { if workspace.showPalette { CommandPalette(workspace: workspace) } }
        .sheet(item: Binding(get: { workspace.sheet }, set: { workspace.sheet = $0 })) { sheet in
            switch sheet {
            case .clone: CloneSheet(workspace: workspace)
            case .create: CreateRepositorySheet(workspace: workspace)
            case .account: AddAccountSheet()
            }
        }
        .focusedSceneValue(\.workspace, workspace)
        .modifier(AppearanceModifier())
        .task {
            await workspace.bootstrap()
            #if DEBUG
            if let name = ProcessInfo.processInfo.environment["GITSYNC_SHEET"] { workspace.sheet = WorkspaceSheet(rawValue: name) }
            #endif
        }
        .alert("Couldn’t Open Repository", isPresented: Binding(
            get: { workspace.errorMessage != nil },
            set: { if !$0 { workspace.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(workspace.errorMessage ?? "")
        }
    }
}

struct AppCommands: Commands {
    @FocusedValue(\.workspace) private var workspace
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { openWindow(id: "settings") }
                .keyboardShortcut(",")
        }
        CommandGroup(after: .newItem) {
            Button("Open Repository…") { workspace?.openPanel() }
                .keyboardShortcut("o")
            Button("Clone Repository…") { workspace?.sheet = .clone }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("New Repository…") { workspace?.sheet = .create }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Close Repository") { if let s = workspace?.selected { workspace?.close(s) } }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(workspace?.selected == nil)
        }
        CommandMenu("Repository") {
            Button("Jump To…") { workspace?.showPalette.toggle() }
                .keyboardShortcut("k")
            Divider()
            Button("Refresh") { workspace?.selected?.requestRefresh() }
                .keyboardShortcut("r").disabled(workspace?.selected == nil)
            Button("Fetch") { workspace?.selected?.fetch() }
                .keyboardShortcut("f", modifiers: [.command, .shift]).disabled(workspace?.selected == nil)
            Button("Pull") { workspace?.selected?.pull() }
                .keyboardShortcut("l", modifiers: [.command, .shift]).disabled(workspace?.selected == nil)
            Button("Push") { workspace?.selected?.push() }
                .keyboardShortcut("p", modifiers: [.command, .shift]).disabled(workspace?.selected == nil)
            if let store = workspace?.selected, store.webLinks != nil {
                Divider()
                Button("Open on \(store.providerTitle ?? "Web")") { store.openOnWeb(.repository) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Open Branch on \(store.providerTitle ?? "Web")") { store.openOnWeb(.branch) }
                Button("Create \(store.webLinks?.pullRequestsWord ?? "Pull Request") on \(store.providerTitle ?? "Web")") { store.openOnWeb(.pullRequest) }
            }
            Divider()
            Button("Undo Last Change…") { workspace?.selected?.undoLastChange() }
                .keyboardShortcut("z", modifiers: [.command, .option]).disabled(workspace?.selected == nil)
            Button("Reflog…") { workspace?.selected?.sheet = .reflog }.disabled(workspace?.selected == nil)
            Divider()
            Button("Show History") { workspace?.selected?.mode = .history }
                .keyboardShortcut("1", modifiers: [.command, .option]).disabled(workspace?.selected == nil)
            Button("Show Changes") { workspace?.selected?.mode = .changes }
                .keyboardShortcut("2", modifiers: [.command, .option]).disabled(workspace?.selected == nil)
            if let store = workspace?.selected, store.supports(.pullRequest) {
                Button("Show \(store.pullRequestsTitle)") { store.mode = .pullRequests }
            }
            if let store = workspace?.selected, store.supports(.issue) {
                Button("Show Issues") { store.mode = .issues }
            }
        }
        CommandMenu("Repositories") {
            Button("Next Repository") { workspace?.cycle(1) }
                .keyboardShortcut(.tab, modifiers: .control)
            Button("Previous Repository") { workspace?.cycle(-1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            Divider()
            Button("Repository 1") { workspace?.selectIndex(0) }
                .keyboardShortcut("1")
            Button("Repository 2") { workspace?.selectIndex(1) }
                .keyboardShortcut("2")
            Button("Repository 3") { workspace?.selectIndex(2) }
                .keyboardShortcut("3")
            Button("Repository 4") { workspace?.selectIndex(3) }
                .keyboardShortcut("4")
            Button("Repository 5") { workspace?.selectIndex(4) }
                .keyboardShortcut("5")
            Button("Repository 6") { workspace?.selectIndex(5) }
                .keyboardShortcut("6")
            Button("Repository 7") { workspace?.selectIndex(6) }
                .keyboardShortcut("7")
            Button("Repository 8") { workspace?.selectIndex(7) }
                .keyboardShortcut("8")
            Button("Repository 9") { workspace?.selectIndex(8) }
                .keyboardShortcut("9")
        }
    }
}
