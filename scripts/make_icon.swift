// Generates Resources/AppIcon.icns: swift scripts/make_icon.swift <output-dir>
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.09
    let body = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: body, xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(colors: [NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.26, alpha: 1),
                        NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.1, alpha: 1)])!
        .draw(in: path, angle: -90)

    // Film strip
    let strip = NSRect(x: body.minX + s * 0.08, y: s * 0.40, width: body.width - s * 0.16, height: s * 0.24)
    NSColor(white: 0.25, alpha: 1).setFill()
    NSBezierPath(roundedRect: strip, xRadius: s * 0.02, yRadius: s * 0.02).fill()
    let frames = 4
    let fw = strip.width / CGFloat(frames)
    for i in 0..<frames {
        let f = NSRect(x: strip.minX + CGFloat(i) * fw + s * 0.01, y: strip.minY + s * 0.025,
                       width: fw - s * 0.02, height: strip.height - s * 0.05)
        NSColor(calibratedHue: 0.55 + CGFloat(i) * 0.05, saturation: 0.5, brightness: 0.8, alpha: 1).setFill()
        f.fill()
    }
    // Trim selection
    let sel = NSRect(x: strip.minX + fw * 0.8, y: strip.minY - s * 0.015, width: fw * 2.2, height: strip.height + s * 0.03)
    let selPath = NSBezierPath(roundedRect: sel, xRadius: s * 0.015, yRadius: s * 0.015)
    selPath.lineWidth = s * 0.025
    NSColor.systemYellow.setStroke()
    selPath.stroke()

    // Meter bars
    let colors: [NSColor] = [.systemGreen, .systemGreen, .systemGreen, .systemYellow, .systemRed]
    for (i, c) in colors.enumerated() {
        c.setFill()
        let w = s * 0.09
        NSRect(x: body.minX + s * 0.14 + CGFloat(i) * (w + s * 0.025), y: s * 0.2, width: w, height: s * 0.07).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! draw(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! draw(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print(iconset.path)
