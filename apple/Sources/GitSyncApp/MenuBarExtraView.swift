import AppKit
import GitSyncCore
import SwiftUI

/// Lets scenes outside the window (the menu bar extra) observe the window's workspace.
@MainActor @Observable
final class MenuBarModel {
    static let shared = MenuBarModel()
    var workspace: Workspace?
}

enum MenuBarSetting { static let key = "settings.showMenuBarExtra" }

/// Menu bar icon: open repositories with their branch and change count, recents, and a few actions.
struct MenuBarContent: View {
    private var workspace: Workspace? { MenuBarModel.shared.workspace }

    var body: some View {
        if let workspace, !workspace.repos.isEmpty {
            ForEach(workspace.repos) { store in
                Button {
                    workspace.select(store.id)
                    Self.showWindow()
                } label: {
                    let n = store.status.changeCount
                    Text("\(store.name) · \(store.status.branchDisplay)" + (n > 0 ? " · \(n) change\(n == 1 ? "" : "s")" : ""))
                }
            }
            Divider()
        }
        let recents = (workspace?.recents ?? RecentRepositories.load()).filter { url in
            !(workspace?.repos.contains { $0.id == url.path } ?? false)
        }
        if !recents.isEmpty {
            Menu("Open Recent") {
                ForEach(recents.prefix(8), id: \.self) { url in
                    Button(url.lastPathComponent) { workspace?.open(url); Self.showWindow() }
                }
            }
        }
        Button("Open Repository…") { Self.showWindow(); workspace?.openPanel() }
        Button("Show GitSync") { Self.showWindow() }
        Divider()
        Button("Quit GitSync") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    static func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }
}

/// The menu bar label: the branch icon, plus the total number of changed files when there are any.
struct MenuBarLabel: View {
    var body: some View {
        let total = MenuBarModel.shared.workspace?.totalChanges ?? 0
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.branch")
            if total > 0 { Text(BadgeLabel.text(forChanges: total) ?? "") }
        }
    }
}
