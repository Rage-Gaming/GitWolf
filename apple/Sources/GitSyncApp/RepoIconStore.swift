import AppKit
import GitSyncCore
import ImageIO
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
    let importURL: (URL) -> Void
    @State private var browsing = false
    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.fixed(40), spacing: 8), count: 8)

    var body: some View {
        if browsing {
            ImageFileBrowser(pick: { importURL($0); dismiss() }, back: { browsing = false })
        } else {
            pickerBody
        }
    }

    private var pickerBody: some View {
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
                Button("Paste") { pasteImage() }
                Button("Choose Image…") { browsing = true }
                Button("Use Initials") { choose(nil); dismiss() }.disabled(current == nil)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 8 * 40 + 7 * 8 + 36)
    }

    private func pasteImage() {
        let board = NSPasteboard.general
        if let url = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first {
            importURL(url); dismiss(); return
        }
        guard let data = board.data(forType: .png) ?? board.data(forType: .tiff) else { NSSound.beep(); return }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        guard (try? data.write(to: temp)) != nil else { return }
        importURL(temp)
        dismiss()
        // The import reads the file in the background; remove the copy afterwards.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { try? FileManager.default.removeItem(at: temp) }
    }
}


/// A small file browser for picking a picture. The system open panel hangs inside this app on some
/// Macs, so the picker brings its own: places on the left, folders and images in the list.
struct ImageFileBrowser: View {
    let pick: (URL) -> Void
    let back: () -> Void
    @State private var folder = ImageFileBrowser.start
    @State private var entries: [URL] = []
    @State private var selected: URL?
    @State private var failed = false
    @State private var preview: NSImage?

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private static var start: URL {
        let pictures = home.appendingPathComponent("Pictures")
        return FileManager.default.fileExists(atPath: pictures.path) ? pictures : home
    }
    private var places: [(String, String, URL)] {
        let h = Self.home
        return [("Home", "house", h), ("Desktop", "menubar.dock.rectangle", h.appendingPathComponent("Desktop")),
                ("Documents", "doc", h.appendingPathComponent("Documents")),
                ("Downloads", "arrow.down.circle", h.appendingPathComponent("Downloads")),
                ("Pictures", "photo", h.appendingPathComponent("Pictures"))]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose an Image").font(.headline)
            HStack(spacing: 6) {
                ForEach(places, id: \.0) { name, icon, url in
                    Button { go(url) } label: { Image(systemName: icon).frame(width: 26, height: 22) }
                        .help(name).accessibilityLabel(name)
                }
                Spacer()
                Button { go(folder.deletingLastPathComponent()) } label: { Image(systemName: "chevron.up") }
                    .help("Enclosing folder").disabled(folder.path == "/")
            }
            Text(folder.path.replacingOccurrences(of: Self.home.path, with: "~"))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            List(entries, id: \.self, selection: $selected) { url in
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
                    Text(url.lastPathComponent).lineLimit(1)
                    Spacer()
                    if isFolder(url) { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { open(url) }
                .onTapGesture { if isFolder(url) { go(url) } else { selected = url } }
            }
            .frame(maxWidth: .infinity).frame(height: 280)
            .overlay {
                if failed { ContentUnavailableView("Can’t Open This Folder", systemImage: "lock", description: Text("macOS didn’t allow access to it.")) }
                else if entries.isEmpty { Text("No images or folders here").foregroundStyle(.secondary) }
            }
            HStack {
                Button("Back") { back() }
                Spacer()
                if let selected, let preview {
                    Text(selected.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: 140, alignment: .trailing)
                    Image(nsImage: preview).resizable().scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
                        .accessibilityLabel("Preview of \(selected.lastPathComponent)")
                }
                Button("Choose") { if let selected { pick(selected) } }
                    .keyboardShortcut(.defaultAction).disabled(selected == nil || isFolder(selected!))
            }
        }
        .padding(20)
        .frame(width: 8 * 40 + 7 * 8 + 36)
        .task(id: folder) { await load() }
        .task(id: selected) { await loadPreview() }
    }

    private func isFolder(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    private func go(_ url: URL) { selected = nil; folder = url }
    private func open(_ url: URL) { if isFolder(url) { go(url) } else { pick(url) } }

    private func loadPreview() async {
        preview = nil
        guard let url = selected, !isFolder(url) else { return }
        let image: NSImage? = await Task.detached {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 132] as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        if !Task.isCancelled { preview = image }
    }

    private func load() async {
        let dir = folder
        let found: [URL]? = await Task.detached {
            guard let all = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey, .contentTypeKey], options: [.skipsHiddenFiles]) else { return nil }
            let shown = all.filter { url in
                let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey, .isPackageKey])
                if v?.isDirectory == true { return v?.isPackage != true }
                return v?.contentType?.conforms(to: .image) == true
            }
            return shown.sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                let db = (try? b.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                if da != db { return da }
                return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
            }
        }.value
        failed = found == nil
        entries = found ?? []
    }
}
