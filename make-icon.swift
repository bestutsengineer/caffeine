// Rebuilds AppIcon.icns representations from the checked-in high-resolution master artwork.
// Run: swift make-icon.swift && iconutil -c icns Resources/AppIcon.iconset
import AppKit
let output = "Resources/AppIcon.iconset"
let source = NSImage(contentsOfFile: "Resources/AppIcon.png")!
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
for (name, pixels) in [("16x16",16),("16x16@2x",32),("32x32",32),("32x32@2x",64),("128x128",128),("128x128@2x",256),("256x256",256),("256x256@2x",512),("512x512",512),("512x512@2x",1024)] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    // Preserve the supplied artwork's proportions within each square representation.
    let edge = CGFloat(pixels)
    let scale = min(edge / source.size.width, edge / source.size.height)
    let width = source.size.width * scale, height = source.size.height * scale
    source.draw(in: NSRect(x: (edge - width) / 2, y: (edge - height) / 2,
                           width: width, height: height), from: .zero,
                operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(output)/icon_\(name).png"))
}
