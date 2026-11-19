import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import ChompKit

struct RunSummaryView: View {
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
            Text("+\(outcome.totalPoints)").font(Theme.display(.largeTitle)).foregroundStyle(Color(hex: model.profile.colorHex))
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
                tile("\(record.tokens ?? model.tokens(of: outcome, in: model.area))", "Tokens eaten")
                tile("\(model.state.tokens(of: model.state.me).formatted())", "All-time tokens")
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
                    .foregroundStyle(Color(hex: model.profile.colorHex))
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
                    else { model.showPaywall = true }
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

    /// 9:16 card for Instagram/TikTok Stories: the coins headline, this run's streets and a "Get Chomp" footer.
    @MainActor
    private func renderStory() -> Image? {
        let coins = record.tokens ?? model.tokens(of: outcome, in: model.area)
        let card = StoryCard(
            poster: TerritoryPoster(area: model.area, state: model.state, me: model.state.me, colorHex: model.profile.colorHex,
                                    highlight: Set(ordered.map(\.segmentID)), title: model.placeName,
                                    subtitle: "\(model.progress.heldSegments) streets held", ownerColor: model.ownerColor),
            coins: coins, stolen: outcome.stolen.count,
            stats: [(formatDistance(record.distance, miles: model.profile.useMiles), "Distance"),
                    (RunMath.formatDuration(record.movingTime), "Time"),
                    ("\(outcome.gained.count)", outcome.gained.count == 1 ? "Street" : "Streets")],
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

/// Instagram Story card (1080x1920 when rendered at 3x).
struct StoryCard: View {
    let poster: TerritoryPoster
    let coins: Int
    let stolen: Int
    let stats: [(String, String)]
    let colorHex: String

    private let lime = Color(hex: "D4FF3A")

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: "4F7BFF"), Color(hex: "8640EC")], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [.white.opacity(0.25), .clear], center: UnitPoint(x: 0.2, y: 0.08), startRadius: 0, endRadius: 330)
            VStack(spacing: 14) {
                Spacer(minLength: 46)
                VStack(spacing: 0) {
                    Text("I just grabbed").font(.system(size: 30, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                    HStack(spacing: 8) {
                        Image(uiImage: CoinIcon.render(colorHex: "FFC83D")).resizable().frame(width: 34, height: 34)
                        Text("\(coins) coin\(coins == 1 ? "" : "s")").font(.system(size: 44, weight: .black, design: .rounded)).foregroundStyle(lime)
                    }
                    if stolen > 0 {
                        Text("and stole \(stolen) street\(stolen == 1 ? "" : "s") from rivals")
                            .font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.9)).padding(.top, 4)
                    }
                }
                .shadow(color: Color(hex: "1A0F55").opacity(0.35), radius: 6, y: 3)
                poster
                    .frame(height: 330)
                    .clipShape(RoundedRectangle(cornerRadius: 26))
                    .overlay(RoundedRectangle(cornerRadius: 26).stroke(.white.opacity(0.15), lineWidth: 1))
                    .shadow(color: Color(hex: "140A40").opacity(0.5), radius: 16, y: 10)
                    .padding(.horizontal, 22)
                HStack(spacing: 8) {
                    ForEach(Array(stats.enumerated()), id: \.offset) { _, s in
                        VStack(spacing: 2) {
                            Text(s.0).font(.system(size: 18, weight: .black, design: .rounded)).foregroundStyle(.white)
                            Text(s.1).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.75))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
                    }
                }
                .padding(.horizontal, 22)
                Spacer(minLength: 8)
                VStack(spacing: 6) {
                    Text("Every street is covered in coins.").font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.9))
                    Text("Get Chomp on the App Store")
                        .font(.system(size: 16, weight: .heavy, design: .rounded)).foregroundStyle(Color(hex: "16123A"))
                        .padding(.horizontal, 22).padding(.vertical, 11)
                        .background(lime, in: Capsule())
                }
                .padding(.bottom, 52)
            }
        }
    }
}
