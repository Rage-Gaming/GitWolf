#!/usr/bin/env swift
// Renders the app icon (flat blue squircle with the white wolf from ../assets/gitwolf-mark.svg, no gradients)
// to Resources/AppIcon.icns. Usage: swift Scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let markURL = root.deletingLastPathComponent().appendingPathComponent("assets/gitwolf-mark.svg")
guard let mark = NSImage(contentsOf: markURL) else { fatalError("missing \(markURL.path)") }

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.098
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    NSColor(srgbRed: 1 / 255, green: 42 / 255, blue: 165 / 255, alpha: 1).setFill() // #012AA5
    NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225).fill()

    // The wolf, centred, about 58% of the icon wide.
    let aspect = mark.size.height / mark.size.width
    let w = s * 0.58, h = w * aspect
    mark.draw(in: NSRect(x: (s - w) / 2, y: (s - h) / 2, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let out = root.appendingPathComponent("Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try task.run(); task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(task.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")
