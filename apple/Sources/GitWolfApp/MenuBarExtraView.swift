import AppKit
import GitWolfCore

enum MenuBarSetting { static let key = "settings.showMenuBarExtra" }

/// The menu bar icon, as a plain AppKit status item. (A SwiftUI `MenuBarExtra` scene that observed the
/// workspace made SwiftUI rebuild the main menu in an endless loop.) The menu is built only when it
/// opens, so nothing is observed or refreshed in the background.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    static let shared = StatusItemController()

    private var item: NSStatusItem?
    var debugState: String {
        guard let item else { return "status item: none" }
        let frame = item.button?.window?.frame ?? .zero
        return "status item: visible=\(item.isVisible) title='\(item.button?.title ?? "")' image=\(item.button?.image != nil) frame=\(frame)"
    }
    private var changes = 0

    /// Shows or hides the item to match the setting (default on).
    func sync() {
        let wanted = UserDefaults.standard.object(forKey: MenuBarSetting.key) as? Bool ?? true
        if wanted, item == nil {
            let created = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let mark = BrandArt.mark?.copy() as? NSImage {
                mark.size = NSSize(width: 18, height: 17.3)
                mark.accessibilityDescription = "GitWolf"
                created.button?.image = mark
            } else {
                created.button?.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "GitWolf")
            }
            created.button?.imagePosition = .imageLeading
            let menu = NSMenu()
            menu.delegate = self
            created.menu = menu
            item = created
            apply()
        } else if !wanted, let existing = item {
            NSStatusBar.system.removeStatusItem(existing)
            item = nil
        }
    }

    /// Total changed files across open repositories, shown beside the icon.
    func update(changes count: Int) {
        guard count != changes else { return }
        changes = count
        apply()
    }

    private func apply() {
        guard let button = item?.button else { return }
        let text = BadgeLabel.text(forChanges: changes).map { " " + $0 } ?? ""
        if button.title != text { button.title = text }
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let workspace = Workspace.current
        let open = workspace?.repos ?? []
        for store in open {
            let n = store.status.changeCount
            let title = "\(store.name) · \(store.status.branchDisplay)" + (n > 0 ? " · \(n) change\(n == 1 ? "" : "s")" : "")
            let entry = NSMenuItem(title: title, action: #selector(select(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = store.id
            menu.addItem(entry)
        }
        if !open.isEmpty { menu.addItem(.separator()) }

        let recents = RecentRepositories.load().filter { url in !open.contains { $0.id == url.path } }.prefix(8)
        if !recents.isEmpty {
            let submenu = NSMenu()
            for url in recents {
                let entry = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = url
                submenu.addItem(entry)
            }
            let parent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
            parent.submenu = submenu
            menu.addItem(parent)
        }
        let openPanel = NSMenuItem(title: "Open Repository…", action: #selector(openPanel), keyEquivalent: "")
        openPanel.target = self
        menu.addItem(openPanel)
        let show = NSMenuItem(title: "Show GitWolf", action: #selector(show), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit GitWolf", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func select(_ sender: NSMenuItem) {
        Workspace.current?.select(sender.representedObject as? String)
        show()
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { Workspace.current?.open(url) }
        show()
    }

    @objc private func openPanel() {
        show()
        Workspace.current?.openPanel()
    }

    @objc private func show() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }
}
