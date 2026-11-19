// Draws the Chomp app icon (1024x1024, opaque) and writes it to the iPhone and
// watch asset catalogues.  Run:  swift tools/make-icon.swift
// Original artwork: a street of coins being collected, gold behind the runner,
// silver ahead. Same coin style as the map (CoinIcon in GameMapView.swift).
import AppKit
import CoreGraphics

let S: CGFloat = 1024
let space = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
// Work top-down like UIKit.
ctx.translateBy(x: 0, y: S)
ctx.scaleBy(x: 1, y: -1)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}
func grad(_ colors: [CGColor], _ locs: [CGFloat]) -> CGGradient { CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locs)! }

// Background: bright indigo to violet, lit from the top left.
ctx.drawLinearGradient(grad([rgb(0x4F7BFF), rgb(0x5B4BF5), rgb(0x8B3FE8)], [0, 0.5, 1]),
                       start: CGPoint(x: 0, y: 0), end: CGPoint(x: S, y: S), options: [])
ctx.drawRadialGradient(grad([rgb(0xFFFFFF, 0.28), rgb(0xFFFFFF, 0)], [0, 1]),
                       startCenter: CGPoint(x: 230, y: 180), startRadius: 0, endCenter: CGPoint(x: 230, y: 180), endRadius: 700, options: [])

// City blocks: soft rounded tiles between quiet side streets.
ctx.saveGState()
ctx.rotate(by: -0.0)
let blocks: [CGRect] = [
    CGRect(x: -40, y: -40, width: 300, height: 250), CGRect(x: 310, y: -40, width: 330, height: 250), CGRect(x: 690, y: -40, width: 400, height: 250),
    CGRect(x: -40, y: 830, width: 420, height: 260), CGRect(x: 430, y: 830, width: 300, height: 260), CGRect(x: 780, y: 830, width: 300, height: 260),
]
for b in blocks {
    ctx.addPath(CGPath(roundedRect: b, cornerWidth: 46, cornerHeight: 46, transform: nil))
    ctx.setFillColor(rgb(0xFFFFFF, 0.10))
    ctx.fillPath()
}
ctx.restoreGState()

// The main street: a gentle S-curve across the icon.
let street = CGMutablePath()
street.move(to: CGPoint(x: -60, y: 690))
street.addCurve(to: CGPoint(x: 1084, y: 360), control1: CGPoint(x: 330, y: 760), control2: CGPoint(x: 640, y: 300))
ctx.saveGState()
ctx.setLineCap(.round)
ctx.addPath(street); ctx.setStrokeColor(rgb(0x2A1F7A, 0.35)); ctx.setLineWidth(250); ctx.strokePath()
ctx.addPath(street); ctx.setStrokeColor(rgb(0x3B2E9E, 0.55)); ctx.setLineWidth(205); ctx.strokePath()
ctx.restoreGState()

// Points along the street (cubic Bezier).
func point(_ t: CGFloat) -> CGPoint {
    let p0 = CGPoint(x: -60, y: 690), p1 = CGPoint(x: 330, y: 760), p2 = CGPoint(x: 640, y: 300), p3 = CGPoint(x: 1084, y: 360)
    let u = 1 - t
    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
    return CGPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x, y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
}

func shade(_ hex: UInt32, _ k: CGFloat) -> CGColor {
    let r = CGFloat((hex >> 16) & 255) / 255, g = CGFloat((hex >> 8) & 255) / 255, b = CGFloat(hex & 255) / 255
    return CGColor(red: min(1, r * k), green: min(1, g * k), blue: min(1, b * k), alpha: 1)
}

func coin(at c: CGPoint, radius r: CGFloat, base: UInt32, struck: Bool) {
    let outer = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: r * 0.16), blur: r * 0.35, color: rgb(0x1A0F55, 0.55))
    ctx.setFillColor(shade(base, 0.55)); ctx.fillEllipse(in: outer)
    ctx.restoreGState()
    // Rim
    ctx.saveGState(); ctx.addEllipse(in: outer); ctx.clip()
    ctx.drawLinearGradient(grad([shade(base, 1.2), shade(base, 0.8), shade(base, 0.5)], [0, 0.5, 1]),
                           start: CGPoint(x: outer.minX, y: outer.minY), end: CGPoint(x: outer.maxX, y: outer.maxY), options: [])
    ctx.restoreGState()
    // Face
    let face = outer.insetBy(dx: r * 0.13, dy: r * 0.13)
    ctx.saveGState(); ctx.addEllipse(in: face); ctx.clip()
    ctx.drawRadialGradient(grad([shade(base, 1.3), rgb(base), shade(base, 0.82)], [0, 0.55, 1]),
                           startCenter: CGPoint(x: face.minX + face.width * 0.34, y: face.minY + face.height * 0.3), startRadius: 0,
                           endCenter: CGPoint(x: face.midX, y: face.midY), endRadius: face.width * 0.62, options: [.drawsAfterEndLocation])
    ctx.restoreGState()
    if struck {
        ctx.setStrokeColor(shade(base, 0.62)); ctx.setLineWidth(r * 0.06)
        ctx.strokeEllipse(in: face.insetBy(dx: r * 0.08, dy: r * 0.08))
        func star(_ o: CGPoint, _ rr: CGFloat) -> CGPath {
            let p = CGMutablePath()
            for i in 0..<8 {
                let a = CGFloat(i) * .pi / 4 - .pi / 2
                let d = i % 2 == 0 ? rr : rr * 0.36
                let pt = CGPoint(x: o.x + cos(a) * d, y: o.y + sin(a) * d)
                i == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
            p.closeSubpath(); return p
        }
        let sr = face.width * 0.3
        ctx.addPath(star(CGPoint(x: c.x + r * 0.04, y: c.y + r * 0.05), sr)); ctx.setFillColor(shade(base, 0.55)); ctx.fillPath()
        ctx.addPath(star(CGPoint(x: c.x - r * 0.03, y: c.y - r * 0.035), sr)); ctx.setFillColor(rgb(0xFFFFFF, 0.75)); ctx.fillPath()
        ctx.addPath(star(c, sr)); ctx.setFillColor(shade(base, 1.08)); ctx.fillPath()
    }
    // Gloss
    ctx.saveGState(); ctx.addEllipse(in: face); ctx.clip()
    ctx.addEllipse(in: CGRect(x: face.minX + face.width * 0.14, y: face.minY - face.height * 0.04, width: face.width * 0.72, height: face.height * 0.4))
    ctx.clip()
    ctx.drawLinearGradient(grad([rgb(0xFFFFFF, 0.55), rgb(0xFFFFFF, 0)], [0, 1]),
                           start: CGPoint(x: face.midX, y: face.minY), end: CGPoint(x: face.midX, y: face.minY + face.height * 0.4), options: [])
    ctx.restoreGState()
}

// Silver beads ahead of the runner (still to grab), then the gold coins behind (collected).
for t in stride(from: 0.70, through: 1.0, by: 0.075) { coin(at: point(t), radius: 34, base: 0xD9DEF2, struck: false) }

// Comet trail behind the runner.
ctx.saveGState()
ctx.setLineCap(.round)
let trail = CGMutablePath()
trail.move(to: point(0.06))
for t in stride(from: 0.08, through: 0.55, by: 0.02) { trail.addLine(to: point(t)) }
ctx.addPath(trail); ctx.setStrokeColor(rgb(0xC6FF00, 0.22)); ctx.setLineWidth(70); ctx.strokePath()
ctx.restoreGState()

for (t, r) in [(0.10, 70.0), (0.25, 78.0), (0.40, 86.0)] as [(CGFloat, CGFloat)] { coin(at: point(t), radius: r, base: 0xFFC83D, struck: true) }

// The runner: a lime puck with a white ring and a glow, about to take the next coin.
let runner = point(0.56)
ctx.saveGState()
ctx.drawRadialGradient(grad([rgb(0xC6FF00, 0.55), rgb(0xC6FF00, 0)], [0, 1]),
                       startCenter: runner, startRadius: 0, endCenter: runner, endRadius: 210, options: [])
ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 26, color: rgb(0x1A0F55, 0.6))
ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillEllipse(in: CGRect(x: runner.x - 104, y: runner.y - 104, width: 208, height: 208))
ctx.restoreGState()
ctx.saveGState()
let puck = CGRect(x: runner.x - 84, y: runner.y - 84, width: 168, height: 168)
ctx.addEllipse(in: puck); ctx.clip()
ctx.drawRadialGradient(grad([rgb(0xE8FF7A), rgb(0xC6FF00), rgb(0x8FC400)], [0, 0.55, 1]),
                       startCenter: CGPoint(x: puck.minX + 55, y: puck.minY + 50), startRadius: 0,
                       endCenter: CGPoint(x: puck.midX, y: puck.midY), endRadius: 110, options: [.drawsAfterEndLocation])
ctx.restoreGState()
ctx.setFillColor(rgb(0xFFFFFF, 0.7))
ctx.fillEllipse(in: CGRect(x: puck.minX + 38, y: puck.minY + 30, width: 46, height: 30))

// Write.
let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
let png = rep.representation(using: .png, properties: [:])!
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
for path in ["ios/Chomp/Assets.xcassets/AppIcon.appiconset/icon-1024.png", "ios/ChompWatch/Assets.xcassets/AppIcon.appiconset/icon-1024.png"] {
    let url = root.appendingPathComponent(path)
    try? FileManager.default.removeItem(at: url)
    try! png.write(to: url)
    print("wrote", path)
}
