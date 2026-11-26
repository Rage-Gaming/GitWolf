import GitSyncCore
import SwiftUI

/// A flat, colourful icon for a file type (React atom for .tsx/.jsx, brand tiles for languages).
struct FileIconView: View {
    let icon: FileIcon
    var size: CGFloat = 17

    init(path: String, size: CGFloat = 17) { self.icon = FileIcons.icon(forPath: path); self.size = size }
    init(icon: FileIcon, size: CGFloat = 17) { self.icon = icon; self.size = size }

    var body: some View {
        let color = Color(red: Double((icon.color >> 16) & 0xFF) / 255,
                          green: Double((icon.color >> 8) & 0xFF) / 255,
                          blue: Double(icon.color & 0xFF) / 255)
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
