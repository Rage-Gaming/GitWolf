import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
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
        .defaultSize(width: 1360, height: 840)
        .windowToolbarStyle(.unified)
        .commands { AppCommands() }
    }
}

struct RootView: View {
    @State private var model = WindowModel()

    var body: some View {
        Group {
            if let store = model.store {
                RepositoryView(store: store)
            } else {
                WelcomeView(model: model)
            }
        }
        .focusedSceneValue(\.windowModel, model)
        .alert("Couldn’t Open Repository", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct AppCommands: Commands {
    @FocusedValue(\.windowModel) private var model

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Repository…") { model?.openPanel() }
                .keyboardShortcut("o")
            Button("Close Repository") { model?.closeRepository() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(model?.store == nil)
        }
        CommandMenu("Repository") {
            Button("Refresh") { model?.store?.requestRefresh() }
                .keyboardShortcut("r").disabled(model?.store == nil)
            Divider()
            Button("Fetch") { model?.store?.fetch() }
                .keyboardShortcut("f", modifiers: [.command, .shift]).disabled(model?.store == nil)
            Button("Pull") { model?.store?.pull() }
                .keyboardShortcut("l", modifiers: [.command, .shift]).disabled(model?.store == nil)
            Button("Push") { model?.store?.push() }
                .keyboardShortcut("p", modifiers: [.command, .shift]).disabled(model?.store == nil)
            Divider()
            Button("Show History") { model?.store?.mode = .history }
                .keyboardShortcut("1").disabled(model?.store == nil)
            Button("Show Changes") { model?.store?.mode = .changes }
                .keyboardShortcut("2").disabled(model?.store == nil)
        }
    }
}
