import AppKit
import Foundation

// Production vector geometry for the approved waveform-to-text mark.
// Transparent canvas; four white components, no tile or sparkle.
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let scratch = URL(fileURLWithPath: CommandLine.arguments[2])
let iconset = scratch.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let brand = root.appendingPathComponent("Brand")
try FileManager.default.createDirectory(at: brand, withIntermediateDirectories: true)

func render(size: Int) throws -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let cg = context.cgContext
    cg.clear(CGRect(x: 0, y: 0, width: size, height: size))
    cg.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    cg.translateBy(x: 0, y: 1024); cg.scaleBy(x: 1, y: -1)
    NSColor.white.setFill()
    for rect in [NSRect(x: 144, y: 412, width: 88, height: 216),
                 NSRect(x: 264, y: 296, width: 88, height: 432),
                 NSRect(x: 384, y: 382, width: 88, height: 270),
                 NSRect(x: 488, y: 468, width: 392, height: 88),
                 NSRect(x: 496, y: 600, width: 384, height: 88)] {
        NSBezierPath(roundedRect: rect, xRadius: 44, yRadius: 44).fill()
    }
    let elbow = NSBezierPath()
    elbow.move(to: NSPoint(x: 472, y: 512))
    elbow.curve(to: NSPoint(x: 544, y: 468), controlPoint1: NSPoint(x: 494, y: 480), controlPoint2: NSPoint(x: 510, y: 468))
    elbow.line(to: NSPoint(x: 544, y: 556))
    elbow.curve(to: NSPoint(x: 472, y: 608), controlPoint1: NSPoint(x: 500, y: 556), controlPoint2: NSPoint(x: 480, y: 584))
    elbow.close(); elbow.fill()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "Icon", code: 1) }
    return png
}
for size in [16, 32, 128, 256, 512] {
    try render(size: size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size: size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try render(size: 1024).write(to: brand.appendingPathComponent("LocalTranscript-mark-white.png"))
let svg = """
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024" fill="white">
  <rect x="144" y="412" width="88" height="216" rx="44"/>
  <rect x="264" y="296" width="88" height="432" rx="44"/>
  <rect x="384" y="382" width="88" height="270" rx="44"/>
  <rect x="488" y="468" width="392" height="88" rx="44"/>
  <path d="M472 512 C494 480 510 468 544 468 L544 556 C500 556 480 584 472 608Z"/>
  <rect x="496" y="600" width="384" height="88" rx="44"/>
</svg>
"""
try svg.write(to: brand.appendingPathComponent("LocalTranscript-mark-white.svg"), atomically: true, encoding: .utf8)
