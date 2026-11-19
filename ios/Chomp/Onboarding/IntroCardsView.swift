import SwiftUI
import ChompKit

/// Swipeable cards explaining how Chomp works. Shown once on first launch
/// (before onboarding), and any time from Profile → How Chomp works.
struct IntroCardsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Opened from Profile: finishing just closes the screen.
    var replay = false
    @State private var page = 0

    private var accent: String { model.profile.colorHex }

    private var cards: [IntroCard] {
        let r = model.rules
        let days = Int(r.decay.days)
        let frenzyMin = Int(r.frenzy.durationSeconds / 60)
        let importDays = Int(r.imports.captureWindowHours / 24)
        return [
            IntroCard(scene: .tokens, title: "The map is full of coins",
                      body: "Wherever you are, the roads and paths around you are lined with silver coins. Run past them to collect them."),
            IntroCard(scene: .capture, title: "Run past coins to make them yours",
                      body: "Every coin you run past turns gold: it's yours. Running the pavement counts for the road beside it."),
            IntroCard(scene: .rivals, title: "Defend your coins",
                      body: r.decay.isEnabled
                        ? "Rivals can take your coins by running past them. Coins you don't run past again fade back to silver after \(days) days."
                        : "Your coins stay yours until someone else runs past them. Rivals can take them, so keep an eye on your patch."),
            IntroCard(scene: .power, title: "Power-ups and bonus coins",
                      body: "Run past the glowing pink landmark for a \(frenzyMin)-minute frenzy: double points, and rivals' coins are easier to steal. Some coins glow pink for bonus points at certain times."),
            IntroCard(scene: .health, title: "Forgot to press start?",
                      body: "Import it from Strava afterwards (Settings → History). Runs from the last \(importDays) days still collect coins."),
            IntroCard(scene: .leaderboard, title: "Climb the leaderboard",
                      body: "Rankings count the coins you've collected: nearby, worldwide, with friends and in your club. Invite a friend and you both get a month of Pro."),
        ]
    }

    var body: some View {
        let cards = cards
        ZStack {
            Color(hex: "07070E").ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    if page < cards.count - 1 {
                        Button("Skip") { finish() }.font(.body.weight(.semibold)).foregroundStyle(Theme.hudSecondary)
                    }
                }
                .frame(height: 44)
                .padding(.horizontal, 24)

                TabView(selection: $page) {
                    ForEach(Array(cards.enumerated()), id: \.offset) { i, c in
                        CardPage(card: c, accent: accent, active: page == i).tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                HStack(spacing: 8) {
                    ForEach(0..<cards.count, id: \.self) { i in
                        Capsule().fill(i == page ? Color(hex: accent) : .white.opacity(0.2))
                            .frame(width: i == page ? 24 : 8, height: 8)
                    }
                }
                .animation(.spring(duration: 0.3), value: page)
                .accessibilityElement()
                .accessibilityLabel("Card \(page + 1) of \(cards.count)")
                .padding(.bottom, 20)

                Button {
                    if page < cards.count - 1 { withAnimation { page += 1 } } else { finish() }
                } label: { Text(page < cards.count - 1 ? "Next" : (replay ? "Done" : "Let's play")) }
                    .buttonStyle(ChunkyButtonStyle(colorHex: accent, height: 60))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
            }
        }
        .environment(\.colorScheme, .dark)
        .toolbar(replay ? .hidden : .automatic, for: .navigationBar)
    }

    private func finish() {
        if replay { dismiss(); return }
        model.profile.seenIntro = true
    }
}

struct IntroCard {
    enum Scene { case tokens, capture, rivals, power, block, health, leaderboard }
    var scene: Scene
    var title: String
    var body: String
}

private struct CardPage: View {
    let card: IntroCard
    let accent: String
    let active: Bool

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 8)
            IntroScene(scene: card.scene, accent: accent, running: active)
                .frame(height: 230)
                .frame(maxWidth: 340)
                .background(Color(hex: "11111F"), in: RoundedRectangle(cornerRadius: 28))
                .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(.white.opacity(0.08)))
                .accessibilityHidden(true)
            VStack(spacing: 12) {
                Text(card.title).font(Theme.display(.title)).multilineTextAlignment(.center).foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
                Text(card.body).font(.title3.weight(.medium)).multilineTextAlignment(.center).foregroundStyle(Theme.hudSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 28)
    }
}

/// Small looping illustrations, drawn in code in Chomp's own style.
private struct IntroScene: View {
    let scene: IntroCard.Scene
    let accent: String
    let running: Bool

    private let pellet = Color(hex: "FFF1C1")
    private let street = Color(hex: "2A2A4A")
    private let pink = Color(hex: "FF2BD6")
    private let bot = Color(hex: "7C8CFF")

    var body: some View {
        TimelineView(.animation(paused: !running)) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                draw(&ctx, size, t)
            }
        }
    }

    // MARK: helpers

    private func line(_ ctx: inout GraphicsContext, _ a: CGPoint, _ b: CGPoint, _ c: Color, _ w: CGFloat, blur: CGFloat = 0) {
        var p = Path(); p.move(to: a); p.addLine(to: b)
        var g = ctx
        if blur > 0 { g.addFilter(.blur(radius: blur)) }
        g.stroke(p, with: .color(c), style: StrokeStyle(lineWidth: w, lineCap: .round))
    }

    /// A row of coins. Coins before `taken` are drawn in `takenColor` (or left out if nil).
    private func dots(_ ctx: inout GraphicsContext, _ a: CGPoint, _ b: CGPoint, n: Int, from: Double = 0, to: Double = 1,
                      color: Color? = nil, taken: Double = 0, takenColor: Color? = nil, takenOpacity: Double = 1) {
        for i in 0...n {
            let f = Double(i) / Double(n)
            guard f <= to + 0.0001 else { continue }
            let p = CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
            if f < taken || f < from - 0.0001 {
                if let takenColor { coin(&ctx, p, takenColor, opacity: takenOpacity) }
            } else {
                coin(&ctx, p, color)
            }
        }
    }

    private let gold = Color(hex: "FFC83D")

    private let silver = Color(hex: MapStyle.neutralCoin(.dusk))

    /// The same coin art as the map (CoinIcon). Unclaimed coins are drawn small and silver.
    private func coin(_ ctx: inout GraphicsContext, _ p: CGPoint, _ c: Color?, r: CGFloat = 6.5, opacity: Double = 1) {
        var g = ctx
        g.opacity = opacity
        let img = c.map { CoinIcon.render(color: $0) } ?? CoinIcon.render(colorHex: MapStyle.neutralCoin(.dusk), unclaimed: true)
        let side = r * 2 * CoinIcon.points / 21
        g.draw(Image(uiImage: img), in: CGRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side))
    }

    private func runner(_ ctx: inout GraphicsContext, _ p: CGPoint, _ c: Color) {
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - 16, y: p.y - 16, width: 32, height: 32)), with: .color(c.opacity(0.3)))
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)), with: .color(c))
        ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)), with: .color(.white), lineWidth: 3)
    }

    private func lerp(_ a: CGPoint, _ b: CGPoint, _ f: Double) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f) }
    private func phase(_ t: Double, _ period: Double) -> Double { (t.truncatingRemainder(dividingBy: period)) / period }

    // MARK: scenes

    private func draw(_ ctx: inout GraphicsContext, _ s: CGSize, _ t: Double) {
        let me = Color(hex: accent)
        let w = s.width, h = s.height
        switch scene {
        case .tokens:
            let rows: [CGFloat] = [h * 0.3, h * 0.7]
            for y in rows { line(&ctx, CGPoint(x: 24, y: y), CGPoint(x: w - 24, y: y), street, 8) }
            line(&ctx, CGPoint(x: w * 0.5, y: 24), CGPoint(x: w * 0.5, y: h - 24), street, 8)
            dots(&ctx, CGPoint(x: 24, y: rows[0]), CGPoint(x: w - 24, y: rows[0]), n: 12)
            dots(&ctx, CGPoint(x: w * 0.5, y: 24), CGPoint(x: w * 0.5, y: h - 24), n: 8)
            let f = min(1, phase(t, 3.2) * 1.2)
            let a = CGPoint(x: 24, y: rows[1]), b = CGPoint(x: w - 24, y: rows[1])
            dots(&ctx, a, b, n: 12, taken: f, takenColor: gold, takenOpacity: 0.45)
            runner(&ctx, lerp(a, b, f), me)

        case .capture:
            let a = CGPoint(x: 30, y: h * 0.5), b = CGPoint(x: w - 30, y: h * 0.5)
            line(&ctx, a, b, street, 12)
            let f = min(1, phase(t, 3.6) * 1.35)
            let done = f >= 0.8
            if done {
                dots(&ctx, a, b, n: 14, taken: 2, takenColor: gold)
            } else {
                dots(&ctx, a, b, n: 14, taken: f, takenColor: gold, takenOpacity: 0.45)
                runner(&ctx, lerp(a, b, f), me)
            }
            let label = done ? "YOURS" : "\(Int(f * 100))%"
            ctx.draw(Text(label).font(.system(size: 26, weight: .black, design: .rounded)).foregroundStyle(done ? gold : .white),
                     at: CGPoint(x: w / 2, y: h * 0.25))

        case .rivals:
            let y1 = h * 0.32, y2 = h * 0.68
            let fade = RulesConfig.bundled.decay.isEnabled ? 0.35 + 0.65 * (0.5 + 0.5 * cos(t * 1.4)) : 1
            line(&ctx, CGPoint(x: 30, y: y1), CGPoint(x: w - 30, y: y1), street, 10)
            dots(&ctx, CGPoint(x: 30, y: y1), CGPoint(x: w - 30, y: y1), n: 12, taken: 2, takenColor: gold, takenOpacity: fade)
            let a = CGPoint(x: 30, y: y2), b = CGPoint(x: w - 30, y: y2)
            let f = phase(t, 3.0)
            line(&ctx, a, b, street, 10)
            dots(&ctx, a, b, n: 12, color: gold, taken: f, takenColor: bot)
            runner(&ctx, lerp(a, b, f), bot)
            ctx.draw(Text("Jess M").font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundStyle(bot),
                     at: CGPoint(x: lerp(a, b, f).x, y: y2 + 28))
            ctx.draw(Text(RulesConfig.bundled.decay.isEnabled ? "fading…" : "yours until someone runs it").font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundStyle(gold.opacity(fade)),
                     at: CGPoint(x: w / 2, y: y1 - 22))

        case .power:
            let a = CGPoint(x: 24, y: h * 0.78), b = CGPoint(x: w - 24, y: h * 0.78)
            line(&ctx, a, b, pink.opacity(0.45), 22, blur: 7)
            line(&ctx, a, b, street, 8)
            dots(&ctx, a, b, n: 12, color: pink)
            let c = CGPoint(x: w / 2, y: h * 0.38)
            let pulse = 1 + 0.18 * sin(t * 4)
            let r = 34 * pulse
            var g = ctx; g.addFilter(.blur(radius: 14))
            g.fill(Path(ellipseIn: CGRect(x: c.x - r * 1.4, y: c.y - r * 1.4, width: r * 2.8, height: r * 2.8)), with: .color(pink.opacity(0.7)))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 18, y: c.y - 18, width: 36, height: 36)), with: .color(.white))
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 18, y: c.y - 18, width: 36, height: 36)), with: .color(pink), lineWidth: 6)
            ctx.draw(Text("2×").font(.system(size: 22, weight: .black, design: .rounded)).foregroundStyle(pink),
                     at: CGPoint(x: c.x + 62, y: c.y - 24))

        case .block:
            let r = CGRect(x: w * 0.22, y: h * 0.16, width: w * 0.56, height: h * 0.68)
            let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
            let f = phase(t, 4.5) * 5   // four sides, then a beat with the block filled
            for i in 0..<4 {
                let a = corners[i], b = corners[(i + 1) % 4]
                line(&ctx, a, b, street, 9)
                let side = min(1, max(0, f - Double(i)))
                if side > 0 { line(&ctx, a, lerp(a, b, side), me, 9) }
                if side < 1 { dots(&ctx, a, b, n: 6, from: side) }
            }
            if f >= 4 {
                ctx.fill(Path(r.insetBy(dx: 6, dy: 6)), with: .color(me.opacity(0.28)))
                ctx.draw(Text("+BLOCK").font(.system(size: 20, weight: .black, design: .rounded)).foregroundStyle(me), at: CGPoint(x: r.midX, y: r.midY))
            } else {
                let i = Int(f), side = f - Double(i)
                runner(&ctx, lerp(corners[i], corners[(i + 1) % 4], side), me)
            }

        case .health:
            let pulse = 1 + 0.08 * sin(t * 5)
            ctx.draw(Text(Image(systemName: "arrow.down.circle.fill")).font(.system(size: 64 * pulse)).foregroundStyle(Color(hex: "FF8A3D")),
                     at: CGPoint(x: w * 0.28, y: h * 0.5))
            let f = phase(t, 2.4)
            for i in 0..<3 {
                let x = w * 0.44 + CGFloat(i) * 18
                let on = f * 3 > Double(i)
                ctx.fill(Path(ellipseIn: CGRect(x: x - 4, y: h * 0.5 - 4, width: 8, height: 8)), with: .color(on ? pellet : pellet.opacity(0.2)))
            }
            let a = CGPoint(x: w * 0.66, y: h * 0.28), b = CGPoint(x: w * 0.66, y: h * 0.72)
            line(&ctx, a, b, street, 9)
            line(&ctx, CGPoint(x: w * 0.66, y: h * 0.5), CGPoint(x: w - 24, y: h * 0.5), street, 9)
            if f > 0.6 {
                line(&ctx, a, b, me, 9)
                line(&ctx, CGPoint(x: w * 0.66, y: h * 0.5), CGPoint(x: w - 24, y: h * 0.5), me, 9)
            } else {
                dots(&ctx, a, b, n: 5)
            }

        case .leaderboard:
            let entries: [(String, Double, Color)] = [("You", 1.0, me), ("Callum R", 0.72, bot), ("Sam", 0.5, Color(hex: "5CE1E6"))]
            let grow = min(1, phase(t, 4) * 2)
            for (i, e) in entries.enumerated() {
                let y = h * 0.24 + CGFloat(i) * h * 0.26
                let maxW = w - 150
                ctx.draw(Text("\(i + 1)").font(.system(size: 18, weight: .black, design: .rounded)).foregroundStyle(.white.opacity(0.6)),
                         at: CGPoint(x: 26, y: y))
                ctx.draw(Text(e.0).font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundStyle(.white),
                         at: CGPoint(x: 72, y: y))
                let bar = CGRect(x: 108, y: y - 8, width: maxW * e.1 * grow, height: 16)
                ctx.fill(Path(roundedRect: bar, cornerRadius: 8), with: .color(e.2))
                ctx.draw(Text("\(Int(1240 * e.1 * grow))").font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundStyle(pellet),
                         at: CGPoint(x: bar.maxX + 24, y: y))
            }
        }
    }
}
