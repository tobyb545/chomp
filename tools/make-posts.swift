// Instagram feed posts (1080x1350, 4:5) from the raw App Store captures.
//   swift tools/make-posts.swift <raw captures dir> marketing
import AppKit

let raw = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/chomp-shots"
let out = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "marketing"
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().path
let icon = NSImage(contentsOfFile: root + "/ios/Chomp/Assets.xcassets/AppIcon.appiconset/icon-1024.png")!
let W: CGFloat = 1080, H: CGFloat = 1350
let lime = rgb(0xD4FF3A)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}
func font(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let f = NSFont.systemFont(ofSize: size, weight: weight)
    return NSFont(descriptor: f.fontDescriptor.withDesign(.rounded) ?? f.fontDescriptor, size: size) ?? f
}
func shot(_ name: String) -> NSImage { NSImage(contentsOfFile: "\(raw)/\(name).png")! }

/// Draws into a flipped (top-down) 1080x1350 canvas and saves an opaque PNG.
func canvas(_ name: String, _ draw: () -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    cg.translateBy(x: 0, y: H); cg.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    draw()
    NSGraphicsContext.current = nil
    let c = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    c.draw(rep.cgImage!, in: CGRect(x: 0, y: 0, width: W, height: H))
    try! NSBitmapImageRep(cgImage: c.makeImage()!).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
    print("wrote \(out)/\(name).png")
}

func background(_ shift: Int = 0) {
    let pairs: [(UInt32, UInt32)] = [(0x4F7BFF, 0x7B45F0), (0x5468FF, 0x8640EC), (0x5B5CFA, 0x913DE6), (0x6A4BF2, 0xA23AD9)]
    let p = pairs[shift % pairs.count]
    NSGradient(colors: [rgb(p.0), rgb(p.1)])!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -70)
    NSGradient(colors: [rgb(0xFFFFFF, 0.25), rgb(0xFFFFFF, 0)])!
        .draw(fromCenter: NSPoint(x: 220, y: 160), radius: 0, toCenter: NSPoint(x: 220, y: 160), radius: 760, options: [])
    // A faint street with silver beads behind everything.
    let street = NSBezierPath()
    street.move(to: NSPoint(x: -60, y: 980 - CGFloat(shift) * 60))
    street.curve(to: NSPoint(x: W + 60, y: 620 + CGFloat(shift) * 40), controlPoint1: NSPoint(x: 330, y: 1250), controlPoint2: NSPoint(x: 700, y: 380))
    street.lineWidth = 110; street.lineCapStyle = .round
    rgb(0x2A1F7A, 0.22).setStroke(); street.stroke()
}

func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, in r: NSRect, align: NSTextAlignment = .center, shadow: Bool = true) {
    let para = NSMutableParagraphStyle(); para.alignment = align; para.lineHeightMultiple = 0.92
    var attrs: [NSAttributedString.Key: Any] = [.font: font(size, weight), .foregroundColor: color, .paragraphStyle: para]
    if shadow { let sh = NSShadow(); sh.shadowColor = rgb(0x1A0F55, 0.35); sh.shadowOffset = NSSize(width: 0, height: -5); sh.shadowBlurRadius = 14; attrs[.shadow] = sh }
    NSAttributedString(string: s, attributes: attrs).draw(with: r, options: [.usesLineFragmentOrigin])
}

/// Headline with the second line in lime.
func headline(_ a: String, _ b: String, y: CGFloat, size: CGFloat = 96) {
    let para = NSMutableParagraphStyle(); para.alignment = .center; para.lineHeightMultiple = 0.92
    let sh = NSShadow(); sh.shadowColor = rgb(0x1A0F55, 0.35); sh.shadowOffset = NSSize(width: 0, height: -5); sh.shadowBlurRadius = 14
    let s = NSMutableAttributedString(string: a + "\n", attributes: [.font: font(size, .heavy), .foregroundColor: NSColor.white, .paragraphStyle: para, .shadow: sh])
    s.append(NSAttributedString(string: b, attributes: [.font: font(size, .heavy), .foregroundColor: lime, .paragraphStyle: para, .shadow: sh]))
    s.draw(with: NSRect(x: 40, y: y, width: W - 80, height: size * 2.3), options: [.usesLineFragmentOrigin])
}

/// A phone showing `image`, `height` tall, centred at `center`, optionally tilted.
func phone(_ image: NSImage, center: NSPoint, height: CGFloat, angle: CGFloat = 0, crop: CGFloat = 1) {
    let h = height, w = h * 1320 / 2868 
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform(); t.translateX(by: center.x, yBy: center.y); t.rotate(byDegrees: angle); t.concat()
    let screen = NSRect(x: -w / 2, y: -h / 2, width: w, height: h)
    let bezel = screen.insetBy(dx: -h * 0.0085, dy: -h * 0.0085)
    let r = h * 0.058
    NSGraphicsContext.saveGraphicsState()
    let ds = NSShadow(); ds.shadowColor = rgb(0x140A40, 0.55); ds.shadowOffset = NSSize(width: 0, height: -h * 0.012); ds.shadowBlurRadius = h * 0.03; ds.set()
    rgb(0x0B0B12).setFill(); NSBezierPath(roundedRect: bezel, xRadius: r * 1.12, yRadius: r * 1.12).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: screen, xRadius: r, yRadius: r).addClip()
    image.draw(in: screen, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
}

func appIcon(at r: NSRect) {
    NSGraphicsContext.saveGraphicsState()
    let ds = NSShadow(); ds.shadowColor = rgb(0x140A40, 0.5); ds.shadowOffset = NSSize(width: 0, height: -10); ds.shadowBlurRadius = 30; ds.set()
    rgb(0x000000).setFill(); NSBezierPath(roundedRect: r, xRadius: r.width * 0.2237, yRadius: r.width * 0.2237).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: r, xRadius: r.width * 0.2237, yRadius: r.width * 0.2237).addClip()
    icon.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    NSGraphicsContext.restoreGraphicsState()
}

/// "Free on the App Store · link in bio" pill.
func cta(y: CGFloat, label: String = "Free on the App Store  ·  link in bio") {
    let f = font(36, .heavy)
    let size = (label as NSString).size(withAttributes: [.font: f])
    let r = NSRect(x: (W - size.width) / 2 - 44, y: y, width: size.width + 88, height: 84)
    NSGraphicsContext.saveGraphicsState()
    let ds = NSShadow(); ds.shadowColor = rgb(0x140A40, 0.4); ds.shadowOffset = NSSize(width: 0, height: -8); ds.shadowBlurRadius = 20; ds.set()
    lime.setFill(); NSBezierPath(roundedRect: r, xRadius: 42, yRadius: 42).fill()
    NSGraphicsContext.restoreGraphicsState()
    text(label, 36, .heavy, rgb(0x16123A), in: NSRect(x: r.minX, y: r.minY + 19, width: r.width, height: 50), shadow: false)
}

func slideDots(_ i: Int, of n: Int) {
    for k in 0..<n {
        (k == i ? NSColor.white : rgb(0xFFFFFF, 0.4)).setFill()
        NSBezierPath(ovalIn: NSRect(x: W / 2 - CGFloat(n) * 14 + CGFloat(k) * 28, y: H - 46, width: 12, height: 12)).fill()
    }
}

try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

// POST 1 — carousel (swipe through four slides).
canvas("post1-carousel-1") {
    background(0)
    headline("Your run just", "became a game", y: 70)
    text("Swipe →", 34, .bold, rgb(0xFFFFFF, 0.85), in: NSRect(x: 0, y: 300, width: W, height: 50))
    phone(shot("01-map"), center: NSPoint(x: W / 2, y: 900), height: 1000)
}
canvas("post1-carousel-2") {
    background(1)
    headline("The map is", "covered in coins", y: 70)
    text("Run past them. Ka-ching. They're yours.", 38, .semibold, rgb(0xFFFFFF, 0.9), in: NSRect(x: 0, y: 300, width: W, height: 60))
    phone(shot("02-run"), center: NSPoint(x: W / 2, y: 900), height: 1000)
}
canvas("post1-carousel-3") {
    background(2)
    headline("Pinch your", "rivals' coins", y: 70)
    text("Then flex on the global leaderboard.", 38, .semibold, rgb(0xFFFFFF, 0.9), in: NSRect(x: 0, y: 300, width: W, height: 60))
    phone(shot("05-leaderboard"), center: NSPoint(x: W / 2, y: 900), height: 1000)
}
canvas("post1-carousel-4") {
    background(3)
    appIcon(at: NSRect(x: W / 2 - 150, y: 230, width: 300, height: 300))
    text("Chomp", 120, .heavy, .white, in: NSRect(x: 0, y: 580, width: W, height: 150))
    text("The running game.", 52, .bold, lime, in: NSRect(x: 0, y: 730, width: W, height: 70))
    text("Any road, any town, any pace.\nLace up and go get 'em.", 38, .semibold, rgb(0xFFFFFF, 0.88), in: NSRect(x: 100, y: 830, width: W - 200, height: 120))
    cta(y: 1040)
}

// POST 2 — single image, two phones.
canvas("post2-make-running-fun") {
    background(1)
    headline("Make running", "fun again", y: 60, size: 104)
    phone(shot("01-map"), center: NSPoint(x: W / 2 - 200, y: 790), height: 760, angle: 6)
    phone(shot("02-run"), center: NSPoint(x: W / 2 + 200, y: 820), height: 760, angle: -5)
    cta(y: 1210)
}
