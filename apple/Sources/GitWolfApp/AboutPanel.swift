import AppKit

/// The standard macOS About window, filled in with the GitWolf artwork, version, links and licence.
@MainActor
enum AboutPanel {
    static let repository = URL(string: "https://github.com/ipuppyyt/GitWolf")!

    static func show() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = info?["CFBundleVersion"] as? String ?? version
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "GitWolf",
            .applicationVersion: version,
            .version: build,
            .credits: credits(),
        ]
        if let icon = BrandArt.icon { options[.applicationIcon] = icon }
        // The copyright line comes from Info.plist in a packaged app; a development build has none.
        if info?["NSHumanReadableCopyright"] == nil { options[NSApplication.AboutPanelOptionKey(rawValue: "Copyright")] = "© 2026 GitWolf contributors" }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    private static func credits() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 4
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph,
        ]
        let text = NSMutableAttributedString(string: "A fast, clean, native Git client.\nFree and open source under the MIT licence.\n", attributes: base)
        let links: [(String, String)] = [
            ("GitHub", repository.absoluteString),
            ("Documentation", repository.appendingPathComponent("tree/main/docs").absoluteString),
            ("Report an Issue", repository.appendingPathComponent("issues").absoluteString),
            ("Licence", repository.appendingPathComponent("blob/main/LICENSE").absoluteString),
        ]
        for (i, link) in links.enumerated() {
            if i > 0 { text.append(NSAttributedString(string: "  ·  ", attributes: base)) }
            var attrs = base
            attrs[.link] = URL(string: link.1)
            text.append(NSAttributedString(string: link.0, attributes: attrs))
        }
        return text
    }
}
