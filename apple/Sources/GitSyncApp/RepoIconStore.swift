import AppKit
import GitSyncCore
import SwiftUI

/// Persists `RepoIcons` and the imported image files.
/// Images are stored in `~/Library/Application Support/GitSync/RepoIcons`, never in the repository.
enum RepoIconStore {
    private static let key = "repoIcons"
    static let imageSize = 128

    static func load() -> RepoIcons {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(RepoIcons.self, from: $0) } ?? RepoIcons()
    }

    static func save(_ icons: RepoIcons) {
        if let data = try? JSONEncoder().encode(icons) { UserDefaults.standard.set(data, forKey: key) }
    }

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("GitSync/RepoIcons", isDirectory: true)
    }

    static func imageURL(_ name: String) -> URL { folder.appendingPathComponent(name) }

    static func deleteImage(_ name: String) { try? FileManager.default.removeItem(at: imageURL(name)) }

    /// Reads any picture, crops it to a centred square and saves a small PNG. Returns the stored file name.
    static func importImage(from url: URL) -> String? {
        guard let source = NSImage(contentsOf: url), source.size.width > 0, source.size.height > 0 else { return nil }
        let side = min(source.size.width, source.size.height)
        let crop = NSRect(x: (source.size.width - side) / 2, y: (source.size.height - side) / 2, width: side, height: side)
        let px = imageSize
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: crop, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let name = UUID().uuidString + ".png"
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: imageURL(name), options: .atomic)
            return name
        } catch { return nil }
    }
}

/// Loads icon images once; tiles redraw often.
@MainActor
enum RepoIconImages {
    private static var cache: [String: NSImage] = [:]
    static func image(_ name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        guard let image = NSImage(contentsOf: RepoIconStore.imageURL(name)) else { return nil }
        cache[name] = image
        return image
    }
}

/// The sheet for choosing a repository's tile icon.
struct RepoIconPicker: View {
    let current: RepoIcon?
    let choose: (RepoIcon?) -> Void
    let importImage: (URL) -> Void
    @State private var showImporter = false
    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.fixed(40), spacing: 8), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Repository Icon").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(RepoIcons.symbolChoices, id: \.0) { group, names in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.7)
                                .foregroundStyle(.secondary)
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                                ForEach(names, id: \.self) { name in
                                    let on = current == .symbol(name)
                                    Button { choose(.symbol(name)); dismiss() } label: {
                                        Image(systemName: name).font(.system(size: 17))
                                            .frame(width: 40, height: 40)
                                            .foregroundStyle(on ? Color.white : Color.primary)
                                            .background(on ? Theme.brand : Color.primary.opacity(0.07),
                                                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(name.replacingOccurrences(of: ".", with: " "))
                                }
                            }
                        }
                    }
                }
            }
            .frame(height: 300)
            Divider()
            HStack {
                Button("Choose Image…") { showImporter = true }
                Button("Use Initials") { choose(nil); dismiss() }.disabled(current == nil)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 5 * 40 + 4 * 8 + 36)
        // The file dialog slides down from this sheet, so it stays attached to the window.
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { importImage(url); dismiss() }
        }
    }
}
