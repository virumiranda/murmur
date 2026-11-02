// Draws Murmur's app icon and writes Resources/Murmur.icns.
//   swift scripts/make-icon.swift
import AppKit

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: size / 1024, y: size / 1024)

    // macOS icon grid: an 824-point rounded square centered on a 1024 canvas, with a soft shadow.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill()
    shape.fill()
    ctx.restoreGState()

    ctx.saveGState()
    shape.addClip()
    NSGradient(colors: [NSColor(calibratedRed: 0.19, green: 0.19, blue: 0.22, alpha: 1),
                        NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.06, alpha: 1)])!
        .draw(in: body, angle: -90)
    // A faint violet glow behind the waveform.
    NSGradient(colors: [NSColor(calibratedRed: 0.52, green: 0.42, blue: 1, alpha: 0.38),
                        NSColor(calibratedRed: 0.52, green: 0.42, blue: 1, alpha: 0)])!
        .draw(fromCenter: NSPoint(x: 512, y: 500), radius: 0, toCenter: NSPoint(x: 512, y: 500), radius: 380, options: [])
    ctx.restoreGState()

    // Thin light rim.
    NSColor.white.withAlphaComponent(0.10).setStroke()
    let rim = NSBezierPath(roundedRect: body.insetBy(dx: 2, dy: 2), xRadius: 184, yRadius: 184)
    rim.lineWidth = 4
    rim.stroke()

    // The waveform: bars mirrored around the middle, like the recording pill.
    let heights: [CGFloat] = [0.20, 0.38, 0.62, 0.88, 0.62, 0.38, 0.20]
    let barWidth: CGFloat = 58
    let gap: CGFloat = 36
    let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    var x = 512 - total / 2
    for h in heights {
        let height = max(barWidth, 470 * h)
        let bar = NSRect(x: x, y: 512 - height / 2, width: barWidth, height: height)
        NSGradient(colors: [NSColor.white, NSColor(calibratedWhite: 0.86, alpha: 1)])!
            .draw(in: NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2), angle: -90)
        x += barWidth + gap
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Murmur-\(UUID().uuidString).iconset")
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = drawIcon(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try! data.write(to: iconset.appendingPathComponent(name))
    }
}
let output = root.appendingPathComponent("Resources/Murmur.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try! task.run()
task.waitUntilExit()
try? FileManager.default.copyItem(at: iconset.appendingPathComponent("icon_512x512@2x.png"),
                                  to: FileManager.default.temporaryDirectory.appendingPathComponent("murmur-icon-preview.png"))
try? FileManager.default.removeItem(at: iconset)
print(task.terminationStatus == 0 ? "Wrote \(output.path)" : "iconutil failed")
