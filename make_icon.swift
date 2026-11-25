import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: make_icon.swift OUTPUT.iconset\n", stderr)
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func flame() -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: 548, y: 853))
    p.curve(to: NSPoint(x: 570, y: 586), controlPoint1: NSPoint(x: 510, y: 748), controlPoint2: NSPoint(x: 604, y: 694))
    p.curve(to: NSPoint(x: 695, y: 683), controlPoint1: NSPoint(x: 644, y: 602), controlPoint2: NSPoint(x: 673, y: 643))
    p.curve(to: NSPoint(x: 733, y: 416), controlPoint1: NSPoint(x: 748, y: 600), controlPoint2: NSPoint(x: 786, y: 496))
    p.curve(to: NSPoint(x: 509, y: 210), controlPoint1: NSPoint(x: 690, y: 290), controlPoint2: NSPoint(x: 619, y: 210))
    p.curve(to: NSPoint(x: 290, y: 416), controlPoint1: NSPoint(x: 387, y: 210), controlPoint2: NSPoint(x: 283, y: 285))
    p.curve(to: NSPoint(x: 412, y: 686), controlPoint1: NSPoint(x: 276, y: 535), controlPoint2: NSPoint(x: 347, y: 598))
    p.curve(to: NSPoint(x: 447, y: 529), controlPoint1: NSPoint(x: 403, y: 612), controlPoint2: NSPoint(x: 406, y: 553))
    p.curve(to: NSPoint(x: 548, y: 853), controlPoint1: NSPoint(x: 487, y: 623), controlPoint2: NSPoint(x: 445, y: 748))
    p.close()
    return p
}

func drawIcon(size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let rect = NSRect(x: 32, y: 32, width: 960, height: 960)
    let background = NSBezierPath(roundedRect: rect, xRadius: 216, yRadius: 216)
    NSGradient(starting: NSColor(calibratedRed: 0.075, green: 0.12, blue: 0.21, alpha: 1),
               ending: NSColor(calibratedRed: 0.018, green: 0.035, blue: 0.075, alpha: 1))!.draw(in: background, angle: -90)
    NSColor(calibratedRed: 0.24, green: 0.29, blue: 0.37, alpha: 0.6).setStroke()
    background.lineWidth = 3
    background.stroke()
    let ring = NSBezierPath(ovalIn: NSRect(x: 170, y: 170, width: 684, height: 684))
    NSColor(calibratedRed: 0.97, green: 0.59, blue: 0.13, alpha: 0.12).setStroke()
    ring.lineWidth = 3
    ring.stroke()
    let f = flame()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(calibratedRed: 1, green: 0.30, blue: 0.04, alpha: 0.45)
    shadow.shadowBlurRadius = 58
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSGradient(colors: [NSColor(calibratedRed: 1, green: 0.33, blue: 0.07, alpha: 1),
                        NSColor(calibratedRed: 1, green: 0.72, blue: 0.22, alpha: 1)])!.draw(in: f, angle: 90)
    NSShadow().set()
    let core = NSBezierPath()
    core.move(to: NSPoint(x: 526, y: 563))
    core.curve(to: NSPoint(x: 615, y: 352), controlPoint1: NSPoint(x: 528, y: 474), controlPoint2: NSPoint(x: 632, y: 429))
    core.curve(to: NSPoint(x: 506, y: 260), controlPoint1: NSPoint(x: 605, y: 293), controlPoint2: NSPoint(x: 564, y: 260))
    core.curve(to: NSPoint(x: 416, y: 351), controlPoint1: NSPoint(x: 450, y: 260), controlPoint2: NSPoint(x: 404, y: 303))
    core.curve(to: NSPoint(x: 526, y: 563), controlPoint1: NSPoint(x: 420, y: 429), controlPoint2: NSPoint(x: 491, y: 449))
    core.close()
    NSGradient(starting: NSColor(calibratedRed: 1, green: 0.72, blue: 0.20, alpha: 1),
               ending: NSColor(calibratedRed: 1, green: 0.96, blue: 0.77, alpha: 1))!.draw(in: core, angle: 90)
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    try drawIcon(size: points).write(to: output.appendingPathComponent("icon_\(points)x\(points).png"))
    try drawIcon(size: points * 2).write(to: output.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

// ICNS supports PNG payloads directly. Build the container without depending
// on iconutil's image conversion service (unavailable in some build sessions).
func bigEndian(_ value: Int) -> Data {
    var word = UInt32(value).bigEndian
    return withUnsafeBytes(of: &word) { Data($0) }
}
var chunks = Data()
for (tag, size) in [("icp4", 16), ("icp5", 32), ("icp6", 64),
                    ("ic07", 128), ("ic08", 256), ("ic09", 512), ("ic10", 1024),
                    ("ic11", 32), ("ic12", 64), ("ic13", 256), ("ic14", 512)] {
    let png = drawIcon(size: size)
    chunks.append(Data(tag.utf8))
    chunks.append(bigEndian(png.count + 8))
    chunks.append(png)
}
var icns = Data("icns".utf8)
icns.append(bigEndian(chunks.count + 8))
icns.append(chunks)
try icns.write(to: output.deletingPathExtension().appendingPathExtension("icns"))
