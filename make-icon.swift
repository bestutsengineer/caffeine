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
    // Original coffee-bean artwork, drawn from independent Bezier paths.
    // App branding deliberately does not embed SF Symbols.
    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * size, y: y * size) }
    let bean = NSBezierPath()
    bean.move(to: point(0.34, 0.29))
    bean.curve(to: point(0.68, 0.73), controlPoint1: point(0.10, 0.48), controlPoint2: point(0.47, 0.91))
    bean.curve(to: point(0.34, 0.29), controlPoint1: point(0.92, 0.52), controlPoint2: point(0.55, 0.10))
    bean.close()
    NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
    bean.fill()
    let crease = NSBezierPath()
    crease.move(to: point(0.34, 0.31))
    crease.curve(to: point(0.65, 0.71), controlPoint1: point(0.62, 0.39), controlPoint2: point(0.39, 0.61))
    crease.lineWidth = size * 0.045
    crease.lineCapStyle = .round
    NSColor(calibratedRed: 0.18, green: 0.31, blue: 0.64, alpha: 1).setStroke()
    crease.stroke()
    let spark = NSBezierPath()
    spark.move(to: point(0.73, 0.45)); spark.line(to: point(0.63, 0.31))
    spark.line(to: point(0.70, 0.31)); spark.line(to: point(0.66, 0.20))
    spark.line(to: point(0.81, 0.37)); spark.line(to: point(0.73, 0.37)); spark.close()
    NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.27, alpha: 1).setFill()
    spark.fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, pixels) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                       ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(pixels).write(to: URL(fileURLWithPath: "\(output)/icon_\(name).png"))
}
