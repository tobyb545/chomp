// Instagram reels (1080x1920, 30 fps, no audio: add a trending sound in Instagram).
// Footage comes from ChompUITests/ScreenshotTests/testReelFootage recorded with
// `xcrun simctl io <sim> recordVideo` (see marketing/README.md).
//   swiftc -O tools/make-reels.swift -o /tmp/make-reels && /tmp/make-reels <footage dir> marketing
import AVFoundation
import AppKit
import QuartzCore

let dir = CommandLine.arguments[1], out = CommandLine.arguments[2]
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().path
let iconImage = NSImage(contentsOfFile: root + "/ios/Chomp/Assets.xcassets/AppIcon.appiconset/icon-1024.png")!
    .cgImage(forProposedRect: nil, context: nil, hints: nil)!

let asset = AVURLAsset(url: URL(fileURLWithPath: dir + "/raw.mp4"))
let track = asset.tracks(withMediaType: .video)[0]
let recStart = Double(try! String(contentsOfFile: dir + "/recstart.txt").trimmingCharacters(in: .whitespacesAndNewlines))!
let marks = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: dir + "/marks.json"))) as! [String: Double]
// The recording began a moment before recstart.txt was written: line the end mark up with the video's end.
let lead = CMTimeGetSeconds(asset.duration) - (marks["end"]! - recStart) - 0.2
func at(_ mark: String, _ plus: Double = 0) -> Double { marks[mark]! - recStart + lead + plus }

let W: CGFloat = 1080, H: CGFloat = 1920
let phoneH: CGFloat = 1360, phoneW = phoneH * 1320 / 2868
let screen = CGRect(x: (W - phoneW) / 2, y: 480, width: phoneW, height: phoneH)   // top-down
let radius = phoneH * 0.058

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}
func font(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let f = NSFont.systemFont(ofSize: size, weight: weight)
    return NSFont(descriptor: f.fontDescriptor.withDesign(.rounded) ?? f.fontDescriptor, size: size) ?? f
}
func gradientLayer() -> CAGradientLayer {
    let g = CAGradientLayer()
    g.frame = CGRect(x: 0, y: 0, width: W, height: H)
    g.colors = [rgb(0x4F7BFF), rgb(0x8640EC)]
    g.startPoint = CGPoint(x: 0, y: 0); g.endPoint = CGPoint(x: 1, y: 1)
    let glow = CAGradientLayer(); glow.type = .radial; glow.frame = CGRect(x: -500, y: -500, width: 1400, height: 1400)
    glow.colors = [rgb(0xFFFFFF, 0.25), rgb(0xFFFFFF, 0)]; glow.startPoint = CGPoint(x: 0.5, y: 0.5); glow.endPoint = CGPoint(x: 1, y: 1)
    g.addSublayer(glow)
    return g
}

/// Fades a layer in at `from` and out at `to` (seconds), with a small pop.
func show(_ layer: CALayer, from: Double, to: Double, total: Double, pop: Bool = true) {
    let f = 0.25
    let times = [0, from, from + f, max(from + f, to - f), to, total].map { NSNumber(value: min(max($0 / total, 0), 1)) }
    let o = CAKeyframeAnimation(keyPath: "opacity")
    o.values = [0, 0, 1, 1, to >= total ? 1 : 0, to >= total ? 1 : 0]; o.keyTimes = times
    let s = CAKeyframeAnimation(keyPath: "transform.scale")
    s.values = pop ? [0.85, 0.85, 1, 1, 1, 1] : [1, 1, 1, 1, 1, 1]; s.keyTimes = times
    for a in [o, s] {
        a.beginTime = AVCoreAnimationBeginTimeAtZero; a.duration = total
        a.isRemovedOnCompletion = false; a.fillMode = .both
        layer.add(a, forKey: a.keyPath)
    }
    layer.opacity = 0
}

/// Text drawn into an image (CATextLayer doesn't render during offscreen export).
func imageLayer(_ text: NSAttributedString, frame: CGRect) -> CALayer {
    let img = NSImage(size: frame.size, flipped: true) { r in
        text.draw(with: r, options: [.usesLineFragmentOrigin]); return true
    }
    let l = CALayer()
    var rect = CGRect(origin: .zero, size: CGSize(width: frame.width * 2, height: frame.height * 2))
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(rect.width), pixelsHigh: Int(rect.height), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = frame.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(origin: .zero, size: frame.size))
    NSGraphicsContext.restoreGraphicsState()
    l.contents = rep.cgImage(forProposedRect: &rect, context: nil, hints: nil) ?? rep.cgImage
    l.frame = frame
    return l
}

func textLayer(_ top: String, _ bottom: String?, size: CGFloat, y: CGFloat, height: CGFloat) -> CALayer {
    let para = NSMutableParagraphStyle(); para.alignment = .center; para.lineHeightMultiple = 0.9
    let shadow = NSShadow(); shadow.shadowColor = NSColor(cgColor: rgb(0x1A0F55, 0.45)); shadow.shadowOffset = NSSize(width: 0, height: -5); shadow.shadowBlurRadius = 16
    let s = NSMutableAttributedString()
    if !top.isEmpty {
        s.append(NSAttributedString(string: top, attributes: [.font: font(size, .heavy), .foregroundColor: NSColor.white, .paragraphStyle: para, .shadow: shadow]))
    }
    if let b = bottom {
        s.append(NSAttributedString(string: (top.isEmpty ? "" : "\n") + b, attributes: [.font: font(size, .heavy), .foregroundColor: NSColor(cgColor: rgb(0xD4FF3A))!, .paragraphStyle: para, .shadow: shadow]))
    }
    return imageLayer(s, frame: CGRect(x: 40, y: y, width: W - 80, height: height))
}

func endCard(from: Double, total: Double) -> CALayer {
    let card = gradientLayer()
    let icon = CALayer(); icon.contents = iconImage
    icon.frame = CGRect(x: W / 2 - 170, y: 520, width: 340, height: 340)
    icon.cornerRadius = 340 * 0.2237; icon.masksToBounds = true
    card.addSublayer(icon)
    card.addSublayer(textLayer("Chomp", nil, size: 150, y: 920, height: 190))
    card.addSublayer(textLayer("", "The running game.", size: 68, y: 1080, height: 180))
    let pill = CALayer(); pill.backgroundColor = rgb(0xD4FF3A); pill.cornerRadius = 55
    pill.frame = CGRect(x: W / 2 - 330, y: 1290, width: 660, height: 110)
    pill.shadowColor = rgb(0x140A40); pill.shadowOpacity = 0.4; pill.shadowRadius = 20; pill.shadowOffset = CGSize(width: 0, height: 8)
    card.addSublayer(pill)
    let para = NSMutableParagraphStyle(); para.alignment = .center
    card.addSublayer(imageLayer(NSAttributedString(string: "Free on the App Store", attributes: [.font: font(48, .heavy), .foregroundColor: NSColor(cgColor: rgb(0x16123A))!, .paragraphStyle: para]),
                                frame: CGRect(x: pill.frame.minX, y: pill.frame.minY + 26, width: pill.frame.width, height: 64)))
    let bio = textLayer("Link in bio", nil, size: 44, y: 1440, height: 70)
    card.addSublayer(bio)
    show(card, from: from, to: total, total: total, pop: false)
    return card
}

struct Clip { var start: Double; var length: Double; var speed: Double }
struct Caption { var top: String; var bottom: String?; var from: Double; var to: Double }

func makeReel(name: String, clips: [Clip], captions: [Caption], endCardLength: Double = 3.2) {
    let comp = AVMutableComposition()
    let v = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
    var cursor = CMTime.zero
    for (i, c) in clips.enumerated() {
        var length = c.length
        if i == clips.count - 1 { length += endCardLength * c.speed }   // keeps video under the end card
        let src = CMTimeRange(start: CMTime(seconds: c.start, preferredTimescale: 600), duration: CMTime(seconds: length, preferredTimescale: 600))
        try! v.insertTimeRange(src, of: track, at: cursor)
        let inserted = CMTimeRange(start: cursor, duration: src.duration)
        let scaled = CMTime(seconds: length / c.speed, preferredTimescale: 600)
        v.scaleTimeRange(inserted, toDuration: scaled)
        cursor = cursor + scaled
    }
    let total = CMTimeGetSeconds(cursor)
    let endStart = total - endCardLength

    let vc = AVMutableVideoComposition()
    vc.renderSize = CGSize(width: W, height: H)
    vc.frameDuration = CMTime(value: 1, timescale: 30)
    let ins = AVMutableVideoCompositionInstruction()
    ins.timeRange = CMTimeRange(start: .zero, duration: cursor)
    let li = AVMutableVideoCompositionLayerInstruction(assetTrack: v)
    let natural = track.naturalSize
    let scale = phoneH / natural.height
    // Video pixel space is top-left origin.
    li.setTransform(CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(translationX: screen.minX, y: screen.minY)), at: .zero)
    ins.layerInstructions = [li]
    vc.instructions = [ins]

    // Core Animation tree (top-down via geometryFlipped).
    let parent = CALayer(); parent.frame = CGRect(x: 0, y: 0, width: W, height: H); parent.isGeometryFlipped = true
    let videoLayer = CALayer(); videoLayer.frame = parent.frame
    parent.addSublayer(videoLayer)
    let bg = gradientLayer()
    let hole = CAShapeLayer()
    let path = CGMutablePath(); path.addRect(parent.frame)
    path.addRoundedRect(in: screen, cornerWidth: radius, cornerHeight: radius)
    hole.path = path; hole.fillRule = .evenOdd
    bg.mask = hole
    parent.addSublayer(bg)
    let bezel = CAShapeLayer()
    bezel.path = CGPath(roundedRect: screen.insetBy(dx: -10, dy: -10), cornerWidth: radius + 10, cornerHeight: radius + 10, transform: nil)
    bezel.fillColor = nil; bezel.strokeColor = rgb(0x0B0B12); bezel.lineWidth = 22
    bezel.shadowColor = rgb(0x140A40); bezel.shadowOpacity = 0.5; bezel.shadowRadius = 30; bezel.shadowOffset = CGSize(width: 0, height: 20)
    parent.addSublayer(bezel)
    for c in captions {
        let t = textLayer(c.top, c.bottom, size: 92, y: 210, height: 250)
        show(t, from: c.from, to: min(c.to, endStart), total: total)
        parent.addSublayer(t)
    }
    parent.addSublayer(endCard(from: endStart, total: total))
    vc.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)

    let url = URL(fileURLWithPath: "\(out)/\(name).mp4")
    try? FileManager.default.removeItem(at: url)
    let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality)!
    ex.videoComposition = vc; ex.outputURL = url; ex.outputFileType = .mp4
    var finished = false
    ex.exportAsynchronously { finished = true }
    while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    print(name, ex.status == .completed ? "written (\(String(format: "%.1f", total))s)" : "FAILED \(String(describing: ex.error))")
}

// REEL 1 — "POV: your run just became a game"
makeReel(name: "reel1-run-is-a-game", clips: [
    Clip(start: at("map"), length: 3.5, speed: 1),
    Clip(start: at("run", 1.5), length: 32, speed: 4),
    Clip(start: at("summary", 2), length: 5, speed: 1.25),
], captions: [
    Caption(top: "POV: your run", bottom: "just became a game", from: 0.1, to: 3.5),
    Caption(top: "The map is", bottom: "covered in coins", from: 3.5, to: 7.5),
    Caption(top: "Run past them.", bottom: "Ka-ching.", from: 7.5, to: 11.5),
    Caption(top: "Every run", bottom: "pays out", from: 11.5, to: 99),
])

// REEL 2 — "Steal coins, climb the world"
makeReel(name: "reel2-steal-and-compete", clips: [
    Clip(start: at("run", 1.5), length: 3, speed: 1),
    Clip(start: at("run", 4.5), length: 44, speed: 8),
    Clip(start: at("leaderboard", 0.4), length: 4.4, speed: 1),
], captions: [
    Caption(top: "Your neighbourhood", bottom: "is up for grabs", from: 0.1, to: 3),
    Caption(top: "Grab them before", bottom: "your rivals do", from: 3, to: 8.5),
    Caption(top: "Then flex on", bottom: "the leaderboard", from: 8.5, to: 99),
])
