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
    /// Uses ImageIO's thumbnail decoder, which reads only what it needs, so huge photos import quickly.
    /// Safe to call off the main thread.
    nonisolated static func importImage(from url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let px = imageSize
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: px * 4,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let side = min(thumb.width, thumb.height)
        guard side > 0,
              let square = thumb.cropping(to: CGRect(x: (thumb.width - side) / 2, y: (thumb.height - side) / 2, width: side, height: side)),
              let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(square, in: CGRect(x: 0, y: 0, width: px, height: px))
        guard let out = ctx.makeImage() else { return nil }
        let name = UUID().uuidString + ".png"
        let folder = Self.folder
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch { return nil }
        guard let dest = CGImageDestinationCreateWithURL(folder.appendingPathComponent(name) as CFURL,
                                                         "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, out, nil)
        return CGImageDestinationFinalize(dest) ? name : nil
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
    let chooseImage: () -> Void
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
                Button("Choose Image…") { dismiss(); chooseImage() }
                Button("Use Initials") { choose(nil); dismiss() }.disabled(current == nil)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 5 * 40 + 4 * 8 + 36)
    }
}
