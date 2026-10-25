import AppKit

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let s = CGFloat(pixels)
        let rect = NSRect(x: s * 0.065, y: s * 0.065, width: s * 0.87, height: s * 0.87)
        let shape = NSBezierPath(roundedRect: rect, xRadius: s * 0.19, yRadius: s * 0.19)
        NSGradient(starting: NSColor(red: 0.29, green: 0.59, blue: 0.98, alpha: 1),
                   ending: NSColor(red: 0.13, green: 0.29, blue: 0.69, alpha: 1))!.draw(in: shape, angle: -90)
        NSColor.white.setStroke()
        let arrow = NSBezierPath()
        arrow.lineWidth = s * 0.065
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        arrow.move(to: NSPoint(x: s * 0.5, y: s * 0.73))
        arrow.line(to: NSPoint(x: s * 0.5, y: s * 0.38))
        arrow.move(to: NSPoint(x: s * 0.36, y: s * 0.51))
        arrow.line(to: NSPoint(x: s * 0.5, y: s * 0.37))
        arrow.line(to: NSPoint(x: s * 0.64, y: s * 0.51))
        arrow.move(to: NSPoint(x: s * 0.29, y: s * 0.34))
        arrow.line(to: NSPoint(x: s * 0.29, y: s * 0.27))
        arrow.line(to: NSPoint(x: s * 0.71, y: s * 0.27))
        arrow.line(to: NSPoint(x: s * 0.71, y: s * 0.34))
        arrow.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
    }
}
// ICNS supports PNG payloads directly. Write the container without requiring
// iconutil’s system image conversion service (unavailable in some sandboxes).
func bigEndian(_ value: Int) -> Data {
    Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
          UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
}
var records = Data()
for (type, name) in [("icp4", "16x16"), ("icp5", "32x32"), ("icp6", "32x32@2x"),
                     ("ic07", "128x128"), ("ic08", "256x256"), ("ic09", "512x512"),
                     ("ic10", "512x512@2x"), ("ic11", "16x16@2x"),
                     ("ic12", "32x32@2x"), ("ic13", "128x128@2x"), ("ic14", "256x256@2x")] {
    let png = try Data(contentsOf: folder.appendingPathComponent("icon_\(name).png"))
    records.append(Data(type.utf8))
    records.append(bigEndian(png.count + 8))
    records.append(png)
}
var icns = Data("icns".utf8)
icns.append(bigEndian(records.count + 8))
icns.append(records)
try icns.write(to: folder.deletingPathExtension().appendingPathExtension("icns"))
