// Draws the app icon: a black notch-shaped bar on a dark tile, a red recording dot and a waveform.
// Run: swift scripts/make_icon.swift Resources/AppIcon.iconset
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: the tile is 824/1024 of the canvas, centred.
    let inset = s * 100 / 1024
    let tile = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    NSGradient(colors: [NSColor(white: 0.17, alpha: 1), NSColor(white: 0.06, alpha: 1)])!.draw(in: tilePath, angle: -90)

    // The notch, hanging from the top edge.
    let notch = NSRect(x: tile.midX - tile.width * 0.3, y: tile.maxY - tile.height * 0.2,
                       width: tile.width * 0.6, height: tile.height * 0.2)
    NSColor.black.setFill()
    let notchPath = NSBezierPath(roundedRect: notch, xRadius: notch.height * 0.45, yRadius: notch.height * 0.45)
    notchPath.append(NSBezierPath(rect: NSRect(x: notch.minX, y: notch.midY, width: notch.width, height: notch.height / 2)))
    notchPath.fill()

    // Red dot inside the notch.
    let red = NSColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 1)
    let dot = notch.height * 0.36
    red.setFill()
    NSBezierPath(ovalIn: NSRect(x: notch.minX + notch.height * 0.45, y: notch.midY - dot / 2 - notch.height * 0.05, width: dot, height: dot)).fill()

    // Waveform in the middle of the tile.
    let bars: [CGFloat] = [0.18, 0.36, 0.62, 0.86, 0.54, 0.74, 0.42, 0.24]
    let barWidth = tile.width * 0.055
    let gap = tile.width * 0.035
    let total = CGFloat(bars.count) * barWidth + CGFloat(bars.count - 1) * gap
    let centre = tile.midY - tile.height * 0.08
    for (i, h) in bars.enumerated() {
        let height = tile.height * 0.5 * h
        let rect = NSRect(x: tile.midX - total / 2 + CGFloat(i) * (barWidth + gap), y: centre - height / 2, width: barWidth, height: height)
        NSGradient(colors: [red, NSColor(red: 1.0, green: 0.55, blue: 0.35, alpha: 1)])!
            .draw(in: NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2), angle: 90)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! draw(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try! draw(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
