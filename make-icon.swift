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
    // Original flat artwork; the menu-bar system symbol is independent.
    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * size, y: y * size) }
    let porcelain = NSColor(calibratedWhite: 0.98, alpha: 1)
    let handle = NSBezierPath(roundedRect: NSRect(x: size * 0.59, y: size * 0.38,
                                                width: size * 0.17, height: size * 0.22),
                              xRadius: size * 0.075, yRadius: size * 0.075)
    porcelain.setStroke()
    handle.lineWidth = size * 0.045
    handle.stroke()
    let cup = NSBezierPath()
    cup.move(to: point(0.29, 0.64))
    cup.line(to: point(0.65, 0.64))
    cup.line(to: point(0.65, 0.46))
    cup.curve(to: point(0.50, 0.31), controlPoint1: point(0.65, 0.36), controlPoint2: point(0.59, 0.31))
    cup.line(to: point(0.44, 0.31))
    cup.curve(to: point(0.29, 0.46), controlPoint1: point(0.35, 0.31), controlPoint2: point(0.29, 0.36))
    cup.close()
    porcelain.setFill()
    cup.fill()
    NSBezierPath(roundedRect: NSRect(x: size * 0.26, y: size * 0.24,
                                    width: size * 0.46, height: size * 0.035),
                 xRadius: size * 0.0175, yRadius: size * 0.0175).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, pixels) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                       ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(pixels).write(to: URL(fileURLWithPath: "\(output)/icon_\(name).png"))
}
