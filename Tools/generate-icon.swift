import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: swift generate-icon.swift Logo.png output.iconset\n", stderr)
    exit(1)
}
guard let source = NSImage(contentsOfFile: CommandLine.arguments[1]) else {
    fputs("Cannot read the project logo.\n", stderr)
    exit(1)
}
let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for (size, scale) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
    let pixels = size * scale
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Cannot allocate icon bitmap.")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    source.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
    guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode icon.") }
    try data.write(to: directory.appendingPathComponent(name))
}
