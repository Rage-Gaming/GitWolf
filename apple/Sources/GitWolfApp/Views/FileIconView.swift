import AppKit
import GitWolfCore
import SwiftUI

extension Color {
    /// 0xRRGGBB.
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// A flat, colourful icon for a file type (React atom for .tsx/.jsx, brand logos for languages, tiles for the rest).
struct FileIconView: View {
    let icon: FileIcon
    var size: CGFloat = 17

    init(path: String, size: CGFloat = 17) { self.icon = FileIcons.icon(forPath: path); self.size = size }
    init(icon: FileIcon, size: CGFloat = 17) { self.icon = icon; self.size = size }

    var body: some View {
        let color = Color(hex: icon.color)
        Group {
            switch icon.glyph {
            case .react:
                ReactAtom().stroke(color, style: StrokeStyle(lineWidth: size * 0.075, lineCap: .round))
                    .overlay(Circle().fill(color).frame(width: size * 0.16, height: size * 0.16))
            case .symbol(let name):
                Image(systemName: name).font(.system(size: size * 0.82, weight: .semibold))
                    .symbolRenderingMode(.monochrome).foregroundStyle(color)
            case .folder(let inner):
                Image(systemName: "folder.fill").font(.system(size: size * 0.95)).foregroundStyle(color)
                    .overlay {
                        if let inner {
                            Image(systemName: inner).font(.system(size: size * 0.34, weight: .heavy))
                                .foregroundStyle(.white.opacity(0.95)).offset(y: size * 0.07)
                        }
                    }
            case .logo(let slug):
                if let image = LanguageLogoImage.image(slug, hex: icon.color) {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFit().frame(width: size * 0.92, height: size * 0.92)
                } else {
                    Image(systemName: "doc").font(.system(size: size * 0.82, weight: .semibold)).foregroundStyle(color)
                }
            case .letters(let text):
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(color)
                    .overlay(
                        Text(text).font(.system(size: size * (text.count > 2 ? 0.40 : 0.50), weight: .heavy, design: .rounded))
                            .foregroundStyle(icon.darkText ? Color.black.opacity(0.78) : .white)
                            .minimumScaleFactor(0.5).lineLimit(1)
                    )
            }
        }
        .frame(width: size, height: size)
        .help(icon.name)
        .accessibilityLabel(icon.name)
    }
}

/// Three ellipses crossing at 0°, 60° and 120°.
private struct ReactAtom: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        let ellipse = CGRect(x: -w * 0.5, y: -h * 0.19, width: w, height: h * 0.38)
        for angle in [0.0, 60, 120] {
            let t = CGAffineTransform(translationX: rect.midX, y: rect.midY)
                .rotated(by: angle * .pi / 180)
            path.addPath(Path(ellipseIn: ellipse).applying(t))
        }
        return path
    }
}

/// A language logo as a flat one-colour image in the brand colour (very dark brands are lightened so they show on a dark window).
@MainActor enum LanguageLogoImage {
    private static var cache: [String: NSImage] = [:]
    static func image(_ slug: String, hex: UInt32) -> NSImage? {
        let key = "\(slug)\(hex)"
        if let hit = cache[key] { return hit }
        guard let path = LanguageLogos.paths[slug] else { return nil }
        var r = Double((hex >> 16) & 0xFF), g = Double((hex >> 8) & 0xFF), b = Double(hex & 0xFF)
        let luma = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
        if luma < 0.28 { let t = 0.55; r += (255 - r) * t; g += (255 - g) * t; b += (255 - b) * t }
        let fill = String(format: "#%02X%02X%02X", Int(r), Int(g), Int(b))
        let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="96" height="96">\
            <path fill="\(fill)" d="\(path)"/></svg>
            """
        guard let image = NSImage(data: Data(svg.utf8)) else { return nil }
        cache[key] = image
        return image
    }
}
