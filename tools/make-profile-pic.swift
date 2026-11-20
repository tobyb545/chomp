// Instagram profile picture (1080x1080) from the app icon, zoomed in so the ball and
// coins read at Instagram's small circular size.
//   swift tools/make-profile-pic.swift marketing
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "marketing"
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().path
let icon = NSImage(contentsOfFile: root + "/ios/Chomp/Assets.xcassets/AppIcon.appiconset/icon-1024.png")!
let size = 1080

func render(_ px: Int, circlePreview: Bool) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    ctx.imageInterpolation = .high
    NSGraphicsContext.current = ctx
    let full = NSRect(x: 0, y: 0, width: px, height: px)
    if circlePreview {
        NSColor.white.setFill(); full.fill()
        NSBezierPath(ovalIn: full).addClip()
    }
    // The central 82% of the icon (in its own 1024 space), nudged towards the ball.
    let crop: CGFloat = 840
    let src = NSRect(x: 512 - crop / 2 + 20, y: 1024 - (512 + crop / 2) + 10, width: crop, height: crop)
    icon.draw(in: full, from: src, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
try! render(size, circlePreview: false).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/instagram-profile.png"))
print("wrote \(out)/instagram-profile.png")
if CommandLine.arguments.count > 2 {   // preview of how Instagram shows it
    try! render(Int(CommandLine.arguments[2])!, circlePreview: true).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "\(out)/preview-circle.png"))
}
