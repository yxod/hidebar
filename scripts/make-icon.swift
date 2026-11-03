// Renders Resources/AppIcon.icns. Run: swift scripts/make-icon.swift
import AppKit

/// Draws into a bitmap of exactly `size` pixels; NSImage.tiffRepresentation would double it on Retina.
func render(size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    do {
        let scale = size / 1024
        let body = NSRect(x: 100, y: 100, width: 824, height: 824).applying(.init(scaleX: scale, y: scale))
        let shape = NSBezierPath(roundedRect: body, xRadius: 185 * scale, yRadius: 185 * scale)

        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 24 * scale
        shadow.shadowOffset = NSSize(width: 0, height: -10 * scale)
        shadow.set()
        NSColor.black.setFill()
        shape.fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        NSGradient(colors: [NSColor(red: 0.16, green: 0.18, blue: 0.42, alpha: 1),
                            NSColor(red: 0.42, green: 0.27, blue: 0.86, alpha: 1)])?
            .draw(in: shape, angle: 70)

        // The menu bar strip.
        let bar = NSRect(x: body.minX + 70 * scale, y: body.midY - 70 * scale,
                         width: body.width - 140 * scale, height: 140 * scale)
        NSColor.white.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 70 * scale, yRadius: 70 * scale).fill()

        // Hidden icons fade out to the left, visible ones stay bright on the right.
        let dotSize = 46 * scale
        let alphas: [CGFloat] = [0.12, 0.22, 0.34]
        for (i, alpha) in alphas.enumerated() {
            let x = bar.minX + 60 * scale + CGFloat(i) * 78 * scale
            NSColor.white.withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: bar.midY - dotSize / 2, width: dotSize, height: dotSize)).fill()
        }
        for i in 0..<2 {
            let x = bar.maxX - 60 * scale - dotSize - CGFloat(i) * 78 * scale
            NSColor.white.withAlphaComponent(0.95).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: bar.midY - dotSize / 2, width: dotSize, height: dotSize)).fill()
        }

        let config = NSImage.SymbolConfiguration(pointSize: 120 * scale, weight: .heavy)
            .applying(.init(paletteColors: [.white]))
        if let chevron = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            let chevronSize = chevron.size
            let origin = NSPoint(x: bar.midX + 10 * scale - chevronSize.width / 2, y: bar.midY - chevronSize.height / 2)
            chevron.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let pixels = CGFloat(base * factor)
        let png = render(size: pixels)
        let name = factor == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try png.write(to: iconset.appendingPathComponent(name))
    }
}

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote \(output.path)" : "iconutil failed")
