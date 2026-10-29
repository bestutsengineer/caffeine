// Renders Resources/AppIcon.icns. Run: swift make-icon.swift && iconutil -c icns Resources/AppIcon.iconset
import AppKit

let output = "Resources/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let size = CGFloat(pixels)
    let tile = NSRect(x: size * 0.1, y: size * 0.1, width: size * 0.8, height: size * 0.8)
    let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.30, alpha: 1),
                        NSColor(calibratedRed: 0.22, green: 0.38, blue: 0.78, alpha: 1)])!.draw(in: path, angle: 90)
    // Original 32-grid pixel artwork. Integer grid edges stay crisp at Retina sizes.
    // The system menu-bar symbol is configured independently in AppDelegate.swift.
    NSGraphicsContext.current?.shouldAntialias = false
    let unit = size / 32
    func block(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: NSColor) {
        color.setFill()
        NSRect(x: CGFloat(x) * unit, y: CGFloat(y) * unit,
               width: CGFloat(w) * unit, height: CGFloat(h) * unit).fill()
    }
    let porcelain = NSColor(calibratedWhite: 0.98, alpha: 1)
    let coffee = NSColor(calibratedRed: 0.22, green: 0.35, blue: 0.62, alpha: 1)
    // Stepped bowl, rim and hollow handle; no borrowed symbol outlines.
    block(9, 13, 14, 7, porcelain)
    block(10, 11, 12, 2, porcelain)
    block(12, 10, 8, 1, porcelain)
    block(10, 20, 12, 1, porcelain)
    block(11, 21, 10, 1, porcelain)
    block(11, 18, 10, 2, coffee)
    block(10, 18, 1, 1, coffee)
    block(21, 18, 1, 1, coffee)
    block(23, 15, 2, 4, porcelain)
    block(25, 16, 1, 2, porcelain)
    block(23, 16, 1, 2, coffee)
    // Separate stepped saucer leaves a clear gap under the bowl.
    block(8, 7, 16, 2, porcelain)
    block(7, 8, 1, 2, porcelain)
    block(24, 8, 1, 2, porcelain)
    block(9, 6, 14, 1, porcelain)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, pixels) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                       ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(pixels).write(to: URL(fileURLWithPath: "\(output)/icon_\(name).png"))
}
