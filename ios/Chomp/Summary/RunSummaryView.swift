import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import ChompKit

struct RunSummaryView: View {
    @State private var paywall = false
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let record: RunRecord

    @State private var trace: [TracePoint] = []
    @State private var revealed = 0
    @State private var replaying = false
    @State private var shareImage: Image?
    @State private var storyImage: Image?
    @State private var gifURL: URL?
    @State private var exporting = false

    private var outcome: RunOutcome { record.outcome }
    private var ordered: [CaptureRecord] { outcome.gained.sorted { $0.at < $1.at } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    replayMap
                    headline
                    statsGrid
                    goalsCard
                    if outcome.verdict == .underReview || !outcome.rejected.isEmpty { fairPlayCard }
                    if !outcome.pelletsCollected.isEmpty || outcome.blockBonus > 0 { specialsCard }
                    streetsCard
                    if !record.splits.isEmpty { splitsCard }
                    shareRow
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle(record.startedAt.formatted(date: .abbreviated, time: .shortened))
            .sheet(isPresented: $paywall) { PaywallView() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                trace = await LocalStore.shared.loadTrace(run: record.id)
                shareImage = renderPoster()
                storyImage = renderStory()
                await replay()
            }
        }
    }

    private var replayMap: some View {
        var snap = MapSnapshot()
        snap.version = revealed + (replaying ? 10_000 : 0)
        snap.playerColorHex = model.profile.colorHex
        // Coins taken on this run light up street by street; before that they show
        // whoever held them. Runs saved before coins colour whole streets.
        for (n, c) in ordered.enumerated() {
            let look: MapSnapshot.SegmentLook = n < revealed
                ? .init(state: "mine", colorHex: model.profile.colorHex, strength: 1)
                : c.previousOwner.map { .init(state: "rival", colorHex: model.ownerColor($0), strength: 1) }
                    ?? .init(state: "neutral", colorHex: "FFFFFF", strength: 0)
            if let coins = c.coins {
                for i in coins { snap.coinLooks[Coins.id(c.segmentID, i)] = look }
            } else {
                snap.looks[c.segmentID] = look
            }
        }
        snap.trail = trace.map(\.coordinate)
        snap.eaten = ordered.prefix(revealed).suffix(2).flatMap { c in c.coins.map { $0.map { Coins.id(c.segmentID, $0) } } ?? [c.segmentID] }
        let fitCoords = trace.isEmpty
            ? ordered.compactMap { model.area.segment($0.segmentID)?.midpoint }
            : stride(from: 0, to: trace.count, by: max(1, trace.count / 60)).map { trace[$0].coordinate }
        return GameMapView(area: model.area, snapshot: snap, camera: .fit(fitCoords), showsUserLocation: false)
            .frame(height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                Button { Task { await replay() } } label: {
                    Label("Replay", systemImage: "play.fill").font(.caption.bold())
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Theme.hud, in: Capsule()).foregroundStyle(.white)
                }
                .padding(10)
                .disabled(replaying)
            }
            .accessibilityElement()
            .accessibilityLabel("Replay map. \(outcome.gained.count) streets eaten on this run.")
    }

    private func replay() async {
        guard !ordered.isEmpty else { return }
        replaying = true
        revealed = 0
        let step = max(0.05, min(0.35, 4.0 / Double(ordered.count)))
        for i in 1...ordered.count {
            try? await Task.sleep(for: .seconds(step))
            revealed = i
            if i % 2 == 0 || ordered.count < 12 { Feedback.shared.play(ordered[i - 1].kind == .stolen ? .steal : .pellet) }
        }
        replaying = false
    }

    private var headline: some View {
        VStack(spacing: 4) {
            Text("+\(outcome.totalPoints)").font(Theme.display(.largeTitle)).foregroundStyle(Theme.readableTint(model.profile.colorHex))
            Text("points").font(.headline).foregroundStyle(Theme.textSecondary)
            if outcome.conqueredTown {
                Label("You conquered a whole map square!", systemImage: "crown.fill")
                    .font(.headline).foregroundStyle(Color(hex: "FFD600")).padding(.top, 6)
            }
            if record.simulated, !AppModel.marketing { Chip(text: "Simulated run", colorHex: "8B5CFF").padding(.top, 4) }
        }
        .accessibilityElement(children: .combine)
    }

    private var statsGrid: some View {
        let lost = model.state.events.filter { $0.kind == .ghostRaid && $0.date > record.startedAt.addingTimeInterval(-7 * 86_400) && $0.date < record.startedAt }
            .reduce(0) { $0 + $1.segmentIDs.count }
        return Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                tile(formatDistance(record.distance, miles: model.profile.useMiles), "Distance")
                tile(RunMath.formatDuration(record.movingTime), "Time")
                tile(RunMath.formatPace(record.distance > 0 ? record.movingTime / (record.distance / 1000) : 0), "Avg pace")
            }
            GridRow {
                tile("\(outcome.gained.count - outcome.stolen.count)", "New streets")
                tile("\(outcome.stolen.count)", "Won back")
                tile("\(lost)", "Lost this week")
            }
            GridRow {
                tile("\(record.tokens ?? model.tokens(of: outcome, in: model.area))", "Coins collected")
                tile("\(model.state.tokens(of: model.state.me).formatted())", "All-time coins")
                tile(model.streak.current > 0 ? "\(model.streak.current) day\(model.streak.current == 1 ? "" : "s")" : "–", "Run streak")
            }
        }
    }

    /// This week's goals, so the run's contribution shows.
    private var goalsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("THIS WEEK").font(.caption.weight(.heavy)).foregroundStyle(Theme.textSecondary).tracking(1.5)
            ForEach(model.weeklyGoals) { g in GoalRow(goal: g, colorHex: model.profile.colorHex, dark: false) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    private func tile(_ v: String, _ l: String) -> some View {
        VStack(spacing: 2) {
            Text(v).font(Theme.number(.title3)).foregroundStyle(Theme.textPrimary).minimumScaleFactor(0.6).lineLimit(1)
            Text(l).font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private var fairPlayCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(outcome.verdict == .underReview ? "Run sent for review" : "Some streets didn't count", systemImage: "exclamationmark.shield.fill")
                .font(.headline).foregroundStyle(Theme.danger)
            if outcome.verdict == .underReview {
                Text("This run looked more like cycling or driving than running, so it won't change any street ownership. If that's wrong, nothing is lost: your next run counts as normal.")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
            }
            ForEach(Array(Set(outcome.rejected.compactMap(\.reason))).sorted(), id: \.self) { r in
                Text("• \(r)").font(.subheadline).foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16).background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))
    }

    private var specialsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(outcome.pelletsCollected, id: \.self) { id in
                let name = model.pellets.first { $0.id == id }?.landmark.name ?? "a landmark"
                Label("Power-up at \(name): 10 min frenzy", systemImage: "bolt.circle.fill").foregroundStyle(Theme.power)
            }
            if outcome.blockBonus > 0 {
                Label("\(outcome.blocksCompleted.count) block\(outcome.blocksCompleted.count == 1 ? "" : "s") filled: +\(outcome.blockBonus)", systemImage: "square.grid.3x3.fill")
                    .foregroundStyle(Theme.readableTint(model.profile.colorHex))
            }
        }
        .font(.subheadline.weight(.semibold))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16).background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))
    }

    private var streetsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Streets").font(.headline)
            if outcome.gained.isEmpty && outcome.refreshed.isEmpty {
                Text("No coins this time. Run along a street to collect the coins you pass.")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
            }
            ForEach(ordered.prefix(40)) { c in
                HStack {
                    Circle().fill(Color(hex: model.profile.colorHex)).frame(width: 10, height: 10)
                    VStack(alignment: .leading) {
                        Text(c.streetName).font(.subheadline.weight(.semibold))
                        let coins = c.tokens.map { "\($0) coin\($0 == 1 ? "" : "s")" }
                        if let prev = c.previousOwner {
                            Text([coins, "taken from \(model.ownerName(prev))"].compactMap { $0 }.joined(separator: ", "))
                                .font(.caption).foregroundStyle(Theme.textSecondary)
                        } else if let coins {
                            Text(coins).font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Spacer()
                    if c.multiplier > 1 { Chip(text: "\(Int(c.multiplier))×", colorHex: "FF2BD6") }
                    Text("+\(c.points)").font(Theme.number(.subheadline))
                }
                .accessibilityElement(children: .combine)
            }
            if ordered.count > 40 { Text("and \(ordered.count - 40) more").font(.caption).foregroundStyle(Theme.textSecondary) }
            if !outcome.refreshed.isEmpty {
                Text("\(outcome.refreshed.count) street\(outcome.refreshed.count == 1 ? "" : "s") you already held")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16).background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))
    }

    private var splitsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Splits").font(.headline)
            ForEach(Array(record.splits.enumerated()), id: \.offset) { i, s in
                HStack {
                    Text(s.distance >= 999 ? "km \(i + 1)" : formatDistance(s.distance, miles: false)).font(.subheadline)
                    Spacer()
                    Text(RunMath.formatPace(s.duration / max(s.distance / 1000, 0.01))).font(Theme.number(.subheadline))
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16).background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))
    }

    private var shareRow: some View {
        VStack(spacing: 10) {
            if let img = storyImage {
                ShareLink(item: img, preview: SharePreview("My Chomp run", image: img)) {
                    Label("Share to your Story", systemImage: "rectangle.portrait.on.rectangle.portrait")
                }
                .buttonStyle(ChunkyButtonStyle(colorHex: model.profile.colorHex, height: 56))
            }
            if let img = shareImage {
                ShareLink(item: img, preview: SharePreview("My streets in \(model.placeName)", image: img)) {
                    Label("Share my territory", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(ChunkyButtonStyle(colorHex: "2A2A4A", height: 50))
            }
            if let gifURL {
                ShareLink(item: gifURL) { Label("Share replay GIF", systemImage: "film") }
                    .buttonStyle(ChunkyButtonStyle(colorHex: "2A2A4A", height: 50))
            } else {
                Button {
                    if model.pro.isPro { Task { exporting = true; gifURL = await exportGIF(); exporting = false } }
                    else { paywall = true }
                } label: {
                    Label(exporting ? "Rendering…" : "Export replay (Pro)", systemImage: "film.stack")
                }
                .buttonStyle(ChunkyButtonStyle(colorHex: "2A2A4A", height: 50))
                .disabled(exporting)
            }
        }
    }

    // MARK: Share rendering

    @MainActor
    private func renderPoster(reveal: Int? = nil) -> Image? {
        let poster = TerritoryPoster(area: model.area, state: model.state, me: model.state.me, colorHex: model.profile.colorHex,
                                     highlight: Set(ordered.prefix(reveal ?? ordered.count).map(\.segmentID)),
                                     title: model.placeName, subtitle: "\(model.progress.heldSegments) streets held · +\(outcome.totalPoints) pts",
                                     ownerColor: model.ownerColor)
        let r = ImageRenderer(content: poster.frame(width: 1080 / 3, height: 1350 / 3))
        r.scale = 3
        return r.uiImage.map { Image(uiImage: $0) }
    }

    /// 9:16 card for Instagram/TikTok Stories: this run's streets up close, coins and stats.
    @MainActor
    private func renderStory() -> Image? {
        let coins = record.tokens ?? model.tokens(of: outcome, in: model.area)
        let miles = model.profile.useMiles
        let unit = miles ? 1609.344 : 1000.0
        let pace = record.distance > 0 ? record.movingTime / (record.distance / unit) : 0
        let hour = Calendar.current.component(.hour, from: record.startedAt)
        let when = hour < 5 ? "Night run" : hour < 12 ? "Morning run" : hour < 17 ? "Afternoon run" : hour < 21 ? "Evening run" : "Night run"
        let card = StoryCard(
            map: StoryMap(area: model.area, state: model.state, me: model.state.me, colorHex: model.profile.colorHex,
                          run: Set(ordered.map(\.segmentID)), zones: model.profile.privacyZones, ownerColor: model.ownerColor),
            title: "\(when) · \(model.placeName)",
            date: record.startedAt.formatted(.dateTime.day().month(.wide).year()),
            coins: coins,
            stats: [("Distance", formatDistance(record.distance, miles: miles)),
                    ("Pace", RunMath.formatPace(pace) + (miles ? " /mi" : " /km")),
                    ("Time", RunMath.formatDuration(record.movingTime))],
            extras: [("Streets", "\(outcome.gained.count)"),
                     outcome.stolen.isEmpty ? ("Streak", model.streak.current > 0 ? "\(model.streak.current) days" : "1 day")
                                            : ("Stolen", "\(outcome.stolen.count)"),
                     ("Points", "+\(outcome.totalPoints.formatted())")],
            colorHex: model.profile.colorHex)
        let r = ImageRenderer(content: card.frame(width: 360, height: 640))
        r.scale = 3
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-dumpStory"), let png = r.uiImage?.pngData() {
            try? png.write(to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("story.png"))
        }
        #endif
        return r.uiImage.map { Image(uiImage: $0) }
    }

    @MainActor
    private func exportGIF() async -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chomp-replay-\(record.id.uuidString.prefix(6)).gif")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 32, nil) else { return nil }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frames = 30
        for f in 0...frames {
            let reveal = Int(Double(ordered.count) * Double(f) / Double(frames))
            let poster = TerritoryPoster(area: model.area, state: model.state, me: model.state.me, colorHex: model.profile.colorHex,
                                         highlight: Set(ordered.prefix(reveal).map(\.segmentID)), title: model.placeName,
                                         subtitle: "+\(outcome.totalPoints) pts", ownerColor: model.ownerColor)
            let r = ImageRenderer(content: poster.frame(width: 300, height: 375))
            r.scale = 2
            guard let cg = r.cgImage else { continue }
            let delay = f == frames ? 1.5 : 0.08
            CGImageDestinationAddImage(dest, cg, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
            await Task.yield()
        }
        return CGImageDestinationFinalize(dest) ? url : nil
    }
}

/// Stylised territory image for sharing: no basemap, no start/end points.
struct TerritoryPoster: View {
    let area: Area
    let state: GameState
    let me: OwnerRef
    let colorHex: String
    let highlight: Set<SegmentID>
    let title: String
    let subtitle: String
    let ownerColor: (OwnerRef) -> String

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color(hex: "07070E")
            Canvas { ctx, size in
                let b = area.bbox
                let proj = area.projection
                let sw = proj.project(Coordinate(latitude: b[1], longitude: b[0]))
                let ne = proj.project(Coordinate(latitude: b[3], longitude: b[2]))
                let scale = min(size.width / (ne.x - sw.x), size.height / (ne.y - sw.y)) * 0.95
                let ox = (size.width - (ne.x - sw.x) * scale) / 2, oy = (size.height - (ne.y - sw.y) * scale) / 2
                func pt(_ v: Vec2) -> CGPoint { CGPoint(x: ox + (v.x - sw.x) * scale, y: size.height - (oy + (v.y - sw.y) * scale)) }
                for seg in area.segments {
                    var path = Path()
                    for (i, v) in seg.polyline.points.enumerated() { i == 0 ? path.move(to: pt(v)) : path.addLine(to: pt(v)) }
                    let owner = state.mainOwner(of: seg, rules: RulesConfig.bundled)
                    if highlight.contains(seg.id) {
                        ctx.stroke(path, with: .color(Color(hex: colorHex).opacity(0.5)), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        ctx.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    } else if let owner {
                        ctx.stroke(path, with: .color(Color(hex: ownerColor(owner)).opacity(owner == me ? 1 : 0.55)),
                                   style: StrokeStyle(lineWidth: owner == me ? 2.2 : 1.4, lineCap: .round))
                    } else {
                        ctx.stroke(path, with: .color(Color(hex: "2A2A4A")), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
                    }
                }
            }
            .padding(.bottom, 60)
            VStack(alignment: .leading, spacing: 2) {
                Text("CHOMP").font(.system(size: 13, weight: .black, design: .rounded)).foregroundStyle(Color(hex: colorHex)).tracking(3)
                Text(title).font(.system(size: 24, weight: .black, design: .rounded)).foregroundStyle(.white)
                Text(subtitle).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Color(hex: "A3A3C2"))
            }
            .padding(16)
        }
    }
}

/// The streets of one run, zoomed in, for the Story card. Streets inside privacy
/// zones are drawn like any other street (never highlighted).
struct StoryMap: View {
    let area: Area
    let state: GameState
    let me: OwnerRef
    let colorHex: String
    let run: Set<SegmentID>
    let zones: [PrivacyZone]
    let ownerColor: (OwnerRef) -> String

    var body: some View {
        Canvas { ctx, size in
            let proj = area.projection
            let hidden = zones.map { (proj.project($0.center), $0.radius + 60) }
            func inZone(_ seg: Segment) -> Bool {
                seg.polyline.points.contains { p in hidden.contains { p.distance(to: $0.0) < $0.1 } }
            }
            let shown = area.segments.filter { run.contains($0.id) && !inZone($0) }
            // Frame the run (or the whole area if nothing is shown), at least ~700 m across.
            var pts = shown.flatMap(\.polyline.points)
            if pts.isEmpty { pts = area.segments.flatMap(\.polyline.points) }
            guard let first = pts.first else { return }
            var lo = first, hi = first
            for p in pts { lo = Vec2(min(lo.x, p.x), min(lo.y, p.y)); hi = Vec2(max(hi.x, p.x), max(hi.y, p.y)) }
            let c = Vec2((lo.x + hi.x) / 2, (lo.y + hi.y) / 2)
            let span = max(hi.x - lo.x, (hi.y - lo.y) * Double(size.width) / Double(size.height * 0.7), 700) * 1.35
            let scale = Double(size.width) / span
            func pt(_ v: Vec2) -> CGPoint {
                CGPoint(x: Double(size.width) / 2 + (v.x - c.x) * scale, y: Double(size.height) * 0.42 - (v.y - c.y) * scale)
            }
            func path(_ seg: Segment) -> Path {
                var p = Path()
                for (i, v) in seg.polyline.points.enumerated() { i == 0 ? p.move(to: pt(v)) : p.addLine(to: pt(v)) }
                return p
            }
            let mine = Color(hex: colorHex)
            let shownIDs = Set(shown.map(\.id))
            // Base streets, then territory, then the run on top.
            for seg in area.segments where !shownIDs.contains(seg.id) {
                let p = path(seg)
                if let owner = state.mainOwner(of: seg, rules: RulesConfig.bundled) {
                    ctx.stroke(p, with: .color(Color(hex: ownerColor(owner)).opacity(owner == me ? 0.75 : 0.55)),
                               style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                } else {
                    ctx.stroke(p, with: .color(Color(hex: "4B5175")), style: StrokeStyle(lineWidth: seg.isPath ? 1.2 : 2, lineCap: .round, lineJoin: .round))
                }
            }
            for seg in shown {
                let p = path(seg)
                ctx.stroke(p, with: .color(mine.opacity(0.22)), style: StrokeStyle(lineWidth: 12, lineCap: .round, lineJoin: .round))
                ctx.stroke(p, with: .color(mine), style: StrokeStyle(lineWidth: 5.5, lineCap: .round, lineJoin: .round))
            }
            for seg in shown {
                ctx.stroke(path(seg), with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            }
            // Coins along the run's streets, like the map.
            let gold = Color(hex: "FFC83D"), rim = Color(hex: "B07A00")
            for seg in shown {
                // One dot per ~30 m keeps the route readable.
                let n = max(1, Int((seg.length / 30).rounded()))
                for i in 0..<n {
                    let q = pt(seg.polyline.point(at: (Double(i) + 0.5) * seg.length / Double(n)))
                    let r: CGFloat = 2.2
                    ctx.fill(Path(ellipseIn: CGRect(x: q.x - r, y: q.y - r, width: 2 * r, height: 2 * r)), with: .color(rim))
                    ctx.fill(Path(ellipseIn: CGRect(x: q.x - r + 0.6, y: q.y - r + 0.6, width: 2 * r - 1.2, height: 2 * r - 1.2)), with: .color(gold))
                }
            }
        }
    }
}

/// Instagram Story card (1080x1920 when rendered at 3x), laid out like a training
/// app's share card: the map up top, condensed stats below.
struct StoryCard: View {
    let map: StoryMap
    let title: String
    let date: String
    let coins: Int
    let stats: [(String, String)]
    let extras: [(String, String)]
    let colorHex: String

    private let ink = Color(hex: "0B0B14")
    private let muted = Color(hex: "9A9DB8")

    private func label(_ s: String) -> some View {
        Text(s.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(1.2).foregroundStyle(muted)
    }
    private func value(_ s: String, size: CGFloat) -> some View {
        Text(s).font(.system(size: size, weight: .bold).width(.condensed)).foregroundStyle(.white).lineLimit(1).fixedSize()
    }

    var body: some View {
        ZStack(alignment: .top) {
            ink
            map.frame(width: 360, height: 420).clipped()
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [ink.opacity(0), ink.opacity(0.85), ink], startPoint: .top, endPoint: .bottom).frame(height: 150)
                }
                .overlay(alignment: .top) {
                    LinearGradient(colors: [ink.opacity(0.7), ink.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: 90)
                }
            VStack(alignment: .leading, spacing: 0) {
                Spacer().frame(height: 350)
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(0.92)).lineLimit(1)
                Text(date).font(.system(size: 12, weight: .medium)).foregroundStyle(muted).padding(.top, 2)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(coins.formatted()).font(.system(size: 64, weight: .heavy).width(.condensed)).foregroundStyle(Color(hex: "FFC83D"))
                    Text("COINS\nCOLLECTED").font(.system(size: 13, weight: .heavy).width(.condensed)).tracking(0.8)
                        .foregroundStyle(.white).lineSpacing(-2)
                }
                .padding(.top, 10)
                Rectangle().fill(.white.opacity(0.12)).frame(height: 1).padding(.vertical, 14)
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(stats.enumerated()), id: \.offset) { _, s in
                        VStack(alignment: .leading, spacing: 3) { label(s.0); value(s.1, size: 26) }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(extras.enumerated()), id: \.offset) { _, s in
                        VStack(alignment: .leading, spacing: 3) { label(s.0); value(s.1, size: 26) }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(0..<max(0, stats.count - extras.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                }
                .padding(.top, 14)
                Spacer()
                HStack(spacing: 7) {
                    Image(uiImage: CoinIcon.render(colorHex: "FFC83D")).resizable().frame(width: 18, height: 18)
                    Text("CHOMP").font(.system(size: 15, weight: .black).width(.condensed)).tracking(2).foregroundStyle(.white)
                    Spacer()
                    Text("Run your streets · App Store").font(.system(size: 11, weight: .semibold)).foregroundStyle(muted)
                }
                .padding(.bottom, 86)
            }
            .padding(.horizontal, 26)
        }
        .frame(width: 360, height: 640)
    }
}
