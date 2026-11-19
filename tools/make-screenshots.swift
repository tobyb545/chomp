// Frames raw simulator captures (1320x2868, iPhone 6.9") as App Store screenshots
// with a caption. Original artwork only.
//   swift tools/make-screenshots.swift <raw dir> <out dir>
// Raw captures come from ChompUITests/ScreenshotTests (see docs/APP_STORE.md).
import AppKit

let args = CommandLine.arguments
let rawDir = args.count > 1 ? args[1] : "/tmp/chomp-shots"
let outDir = args.count > 2 ? args[2] : "docs/screenshots"

// (raw file, output name, headline, accent line, subline)
let shots: [(String, String, String, String, String)] = [
    ("01-map",         "1-make-running-fun", "Make running",  "fun again",       "Every street is covered in coins."),
    ("02-run",         "2-run-it-own-it",    "Run it.",       "Own it.",         "Grab every coin you pass. Steal your rivals' too."),
    ("05-leaderboard", "3-compete",          "Compete with",  "the world",       "Nearby, worldwide, friends and clubs."),
    ("03-route",       "4-take-the-block",   "Plan a loop,",  "take the block",  "Routes that grab the most territory."),
    ("04-summary",     "5-every-run-counts", "Every run",     "counts",          "Coins, new streets and a replay of your run."),
    ("06-goals",       "6-streaks",          "Keep your",     "streak alive",    "New goals every week. Same rules for everyone."),
]

let W: CGFloat = 1320, H: CGFloat = 2868
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}
func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let f = NSFont.systemFont(ofSize: size, weight: weight)
    return NSFont(descriptor: f.fontDescriptor.withDesign(.rounded) ?? f.fontDescriptor, size: size) ?? f
}

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

for (i, shot) in shots.enumerated() {
    guard let raw = NSImage(contentsOfFile: "\(rawDir)/\(shot.0).png") else { print("missing", shot.0); continue }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    let ns = NSGraphicsContext(bitmapImageRep: rep)!
    let cg = ns.cgContext
    cg.translateBy(x: 0, y: H); cg.scaleBy(x: 1, y: -1)      // top-down
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)

    // Background: same indigo-violet as the app icon, shifting a little per shot so the set flows.
    let hues: [(UInt32, UInt32)] = [(0x4F7BFF, 0x7B45F0), (0x5468FF, 0x8640EC), (0x5B5CFA, 0x913DE6),
                                    (0x6152F6, 0x9A3BE0), (0x6A4BF2, 0xA23AD9), (0x7345EE, 0xAA39D2)]
    NSGradient(colors: [rgb(hues[i].0), rgb(hues[i].1)])!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -70)
    NSGradient(colors: [rgb(0xFFFFFF, 0.25), rgb(0xFFFFFF, 0)])!
        .draw(fromCenter: NSPoint(x: 260, y: 220), radius: 0, toCenter: NSPoint(x: 260, y: 220), radius: 900, options: [])

    // A faint street of silver beads crossing behind the phone.
    let street = NSBezierPath()
    street.move(to: NSPoint(x: -80, y: 1500 + CGFloat(i % 2) * 300))
    street.curve(to: NSPoint(x: W + 80, y: 1100 + CGFloat(i % 3) * 200), controlPoint1: NSPoint(x: 400, y: 1900), controlPoint2: NSPoint(x: 900, y: 700))
    street.lineWidth = 120; street.lineCapStyle = .round
    rgb(0x2A1F7A, 0.22).setStroke(); street.stroke()

    // Caption.
    let para = NSMutableParagraphStyle(); para.alignment = .center; para.lineSpacing = 0
    let head = NSMutableAttributedString(string: shot.2 + "\n", attributes: [.font: rounded(128, .heavy), .foregroundColor: NSColor.white, .paragraphStyle: para])
    head.append(NSAttributedString(string: shot.3, attributes: [.font: rounded(128, .heavy), .foregroundColor: rgb(0xD4FF3A), .paragraphStyle: para]))
    let shadow = NSShadow(); shadow.shadowColor = rgb(0x1A0F55, 0.35); shadow.shadowOffset = NSSize(width: 0, height: -6); shadow.shadowBlurRadius = 18
    head.addAttribute(.shadow, value: shadow, range: NSRange(location: 0, length: head.length))
    head.draw(with: NSRect(x: 60, y: 150, width: W - 120, height: 330), options: [.usesLineFragmentOrigin])
    NSAttributedString(string: shot.4, attributes: [.font: rounded(52, .semibold), .foregroundColor: rgb(0xFFFFFF, 0.88), .paragraphStyle: para])
        .draw(with: NSRect(x: 80, y: 500, width: W - 160, height: 80), options: [.usesLineFragmentOrigin])

    // Phone: the capture in a dark bezel with a soft shadow.
    let scale: CGFloat = 0.74
    let sw = W * scale, sh = H * scale
    let screen = NSRect(x: (W - sw) / 2, y: 650, width: sw, height: sh)
    let bezel = screen.insetBy(dx: -22, dy: -22)
    NSGraphicsContext.saveGraphicsState()
    let ds = NSShadow(); ds.shadowColor = rgb(0x140A40, 0.55); ds.shadowOffset = NSSize(width: 0, height: -30); ds.shadowBlurRadius = 70; ds.set()
    rgb(0x0B0B12).setFill(); NSBezierPath(roundedRect: bezel, xRadius: 150, yRadius: 150).fill()
    NSGraphicsContext.restoreGraphicsState()
    rgb(0x3A3A4A).setStroke()
    let rim = NSBezierPath(roundedRect: bezel.insetBy(dx: 3, dy: 3), xRadius: 147, yRadius: 147); rim.lineWidth = 4; rim.stroke()
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: screen, xRadius: 128, yRadius: 128).addClip()
    raw.draw(in: screen, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.current = nil
    // App Store wants no alpha: flatten to an opaque JPEG-free PNG.
    let flat = NSBitmapImageRep(cgImage: {
        let c = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        c.draw(rep.cgImage!, in: CGRect(x: 0, y: 0, width: W, height: H)); return c.makeImage()!
    }())
    try! flat.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outDir)/\(shot.1).png"))
    print("wrote", "\(outDir)/\(shot.1).png")
}
