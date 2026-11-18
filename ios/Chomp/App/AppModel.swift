import Foundation
import Observation
import SwiftUI
import ChompKit

/// What the map draws. Rebuilt whenever ownership or the run changes.
struct MapSnapshot {
    struct SegmentLook { var state: String; var colorHex: String; var strength: Double }
    struct GhostMarker: Identifiable { var id: String; var name: String; var colorHex: String; var coordinate: Coordinate; var isBot: Bool }
    var version = 0
    var looks: [SegmentID: SegmentLook] = [:]
    var bonus: Set<SegmentID> = []
    var pellets: [PowerPellet] = []
    var blocks: [(id: BlockID, colorHex: String)] = []
    var ghosts: [GhostMarker] = []
    var heat: [SegmentID: Int]? = nil
    var trail: [Coordinate] = []
    var runner: Coordinate?
    var eaten: [SegmentID] = []
    var playerColorHex = "C6FF00"
    var conquered = false
}

@MainActor
@Observable
final class AppModel {
    // Static game data
    let areas: [String: Area]
    let rules = RulesConfig.bundled
    private(set) var area: Area
    private(set) var engine: GameEngine
    private(set) var matcher: MapMatcher

    // Player
    var profile: PlayerProfile { didSet { profile.save(); applyPreferences() } }
    private(set) var state: GameState
    private(set) var runs: [RunRecord] = []
    var rivals: [String: RivalInfo] = [:]

    // Today
    private(set) var pellets: [PowerPellet] = []
    private(set) var bonusStreets: [BonusStreet] = []

    // UI
    private(set) var mapVersion = 0
    var heatmapOn = false { didSet { bumpMap() } }
    var presentedSummary: RunRecord?
    var showPaywall = false
    var focusRequest: Coordinate?
    var toast: String?

    let run = RunSession()
    let pro = ProStore()
    let backend = SupabaseBackend.shared
    private var realtimeTask: Task<Void, Never>?

    init() {
        var loaded: [String: Area] = [:]
        let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: "areas") ?? []
        for url in urls { if let a = try? Area.load(from: url) { loaded[a.slug] = a } }
        if loaded.isEmpty, let url = Bundle.main.url(forResource: "west-byfleet", withExtension: "json"), let a = try? Area.load(from: url) {
            loaded[a.slug] = a
        }
        guard let fallback = loaded["west-byfleet"] ?? loaded.values.first else {
            fatalError("No playable areas bundled. Run tools/ingest/ingest.py first.")
        }
        areas = loaded
        let profile = PlayerProfile.load()
        self.profile = profile
        let area = loaded[profile.homeArea] ?? fallback
        self.area = area
        engine = GameEngine(area: area, rules: rules)
        matcher = MapMatcher(area: area, rules: rules.matching)
        state = GameState(areaSlug: area.slug, playerID: profile.id)
        run.model = self
        applyPreferences()
    }

    // MARK: Lifecycle

    func bootstrap() async {
        if let saved = await LocalStore.shared.loadState(area: area.slug) { state = saved }
        state.playerID = profile.id
        runs = await LocalStore.shared.loadRuns()
        await backend.restoreSession()
        if let id = backend.userID { await pro.identify(userID: id) } else { await pro.refresh() }
        WatchBridge.shared.onCommand = { [weak self] cmd in
            guard let self else { return }
            if cmd == "start", self.run.phase == .idle { self.run.start(simulated: false) }
            if cmd == "stop", self.run.phase == .running || self.run.phase == .paused { Task { await self.run.finish() } }
        }
        WatchBridge.shared.activate()
        refreshDay()
        #if DEBUG
        await seedDemoIfRequested()
        #endif
        tickWorld()
        await syncOnline()
    }

    #if DEBUG
    /// `-demo` launch argument: skips onboarding and plays a week of simulated
    /// runs instantly, so screenshots and UI checks have a lived-in town.
    private func seedDemoIfRequested() async {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-demo"), runs.isEmpty else {
            if args.contains("-autorun"), profile.onboarded { run.start(simulated: true) }
            return
        }
        var p = profile
        p.name = "Alex"
        p.onboarded = true
        profile = p
        let sim = RouteSimulator(area: area)
        let ghosts = GhostSimulator(engine: engine)
        let start = Date().addingTimeInterval(-6 * 86_400)
        ghosts.ensureGhosts(state: &state, playerColorHex: profile.colorHex, now: start)
        for day in 0..<6 {
            let t = start.addingTimeInterval(Double(day) * 86_400 + 7 * 3600)
            ghosts.tick(state: &state, now: t)
            let route = sim.route(from: area.center.offset(metres: Double(day % 3) * 250, bearingDegrees: Double(day) * 70),
                                  distance: 3500, seed: UInt64(100 + day))
            let trace = sim.trace(along: route, start: t, speed: 3.1, seed: UInt64(200 + day))
            await completeRun(id: UUID(), trace: trace, signals: RunSignals(), startedAt: t, endedAt: trace.last!.timestamp, simulated: true)
        }
        presentedSummary = nil
        if args.contains("-summary") { presentedSummary = runs.first }
        if args.contains("-autorun") { run.start(simulated: true) }
    }
    #endif

    func onForeground() {
        NotificationService.cancelRaid()
        refreshDay()
        tickWorld()
        Task { await syncOnline() }
    }

    func onBackground() {
        scheduleRaidNotification()
        persist()
    }

    private func applyPreferences() {
        Feedback.shared.soundOn = profile.soundOn
        Feedback.shared.hapticsOn = profile.hapticsOn
        pro.debugOverride = profile.debugPro
    }

    /// Advances bots and decay to now, without ever touching an in-progress run.
    func tickWorld(now: Date = .now) {
        guard run.phase == .idle else { return }
        let ghosts = GhostSimulator(engine: engine)
        if !profile.privateMode || state.ghosts.isEmpty {
            ghosts.ensureGhosts(state: &state, playerColorHex: profile.colorHex, now: now)
        }
        if let scheduled = state.scheduledGhostTick {
            if scheduled <= now { ghosts.tick(state: &state, now: scheduled) }
            state.scheduledGhostTick = nil
        }
        let raids = ghosts.tick(state: &state, now: now)
        engine.sweepDecay(state: &state, now: now)
        if let r = raids.first { toast = r.message }
        persist()
        bumpMap()
    }

    private func scheduleRaidNotification() {
        guard run.phase == .idle else { return }
        let at = Date().addingTimeInterval(6 * 3600)
        var copy = state
        let ghosts = GhostSimulator(engine: engine)
        let raids = ghosts.tick(state: &copy, now: at)
        guard let first = raids.first else { return }
        state.scheduledGhostTick = at
        NotificationService.scheduleRaid(message: first.message, at: at)
        let fading = state.ownership.values.filter {
            $0.owner == state.me && $0.strength(at: .now.addingTimeInterval(3 * 86_400), decay: rules.decayInterval) <= 0
        }.count
        NotificationService.fadeWarning(count: fading, at: Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: .now.addingTimeInterval(86_400)) ?? at)
    }

    func refreshDay() {
        pellets = DailySpawns.powerPellets(area: area, date: .now, rules: rules)
        bonusStreets = DailySpawns.bonusStreets(area: area, date: .now, rules: rules)
    }

    func persist() {
        let s = state
        Task { await LocalStore.shared.saveState(s) }
        publishWidgets()
        mirrorToWatch()
    }

    func bumpMap() { mapVersion &+= 1 }

    // MARK: Derived

    var progress: TownProgress { engine.progress(for: state.me, state: state, now: .now) }

    var standings: [Standing] {
        engine.standings(state: state, playerName: displayName, playerColorHex: profile.colorHex, now: .now)
    }

    var displayName: String { profile.name.isEmpty ? "You" : profile.name }

    var isConquered: Bool { state.badges.contains("conquered:\(area.slug)") }

    func ownerName(_ o: OwnerRef) -> String {
        if o == state.me { return displayName }
        if o.kind == .ghost { return state.ghosts.first { $0.id == o.id }?.name ?? "Bot" }
        return rivals[o.id]?.name ?? "Rival"
    }

    func ownerColor(_ o: OwnerRef) -> String {
        if o == state.me { return profile.colorHex }
        if o.kind == .ghost { return state.ghosts.first { $0.id == o.id }?.colorHex ?? "8888AA" }
        return rivals[o.id]?.colorHex ?? "8888AA"
    }

    var activeBonus: [BonusStreet] { bonusStreets.filter { $0.endsAt > .now } }
    var uncollectedPellets: [PowerPellet] { pellets.filter { state.collectedPellets[$0.id] == nil } }

    func mapSnapshot() -> MapSnapshot {
        var s = MapSnapshot()
        s.version = mapVersion
        s.playerColorHex = profile.colorHex
        s.conquered = isConquered
        let now = Date()
        let decay = rules.decayInterval
        let eatenLive = Set(run.tracker?.eaten ?? [])
        let blocked = Set(profile.blockedPlayers)
        for seg in area.segments {
            if eatenLive.contains(seg.id) {
                s.looks[seg.id] = .init(state: "mine", colorHex: profile.colorHex, strength: 1)
                continue
            }
            guard let o = state.ownership[seg.id], o.strength(at: now, decay: decay) > 0, !blocked.contains(o.owner.id) else {
                s.looks[seg.id] = .init(state: "neutral", colorHex: "FFF1C1", strength: 0)
                continue
            }
            let mine = o.owner == state.me
            s.looks[seg.id] = .init(state: mine ? "mine" : "rival", colorHex: ownerColor(o.owner), strength: o.strength(at: now, decay: decay))
        }
        s.bonus = Set(activeBonus.flatMap(\.segmentIDs))
        s.pellets = uncollectedPellets.filter { pellet in !run.collectedThisRun.contains(pellet.id) }
        for owner in Set(state.ownership.values.map(\.owner)) {
            for b in engine.completedBlocks(for: owner, state: state, now: now) {
                s.blocks.append((b, ownerColor(owner)))
            }
        }
        s.ghosts = ghostMarkers(now: now)
        if heatmapOn { s.heat = state.coverage.mapValues(\.timesRun) }
        s.trail = run.trail
        s.runner = run.trail.last
        s.eaten = run.tracker?.eatenOrder ?? []
        return s
    }

    /// Rivals are shown only by the rough centre of their territory (snapped to a
    /// ~300 m grid), never by live position.
    private func ghostMarkers(now: Date) -> [MapSnapshot.GhostMarker] {
        var byOwner: [OwnerRef: [Coordinate]] = [:]
        for (id, o) in state.ownership where o.owner != state.me && o.strength(at: now, decay: rules.decayInterval) > 0 {
            if let seg = area.segment(id) { byOwner[o.owner, default: []].append(seg.midpoint) }
        }
        return byOwner.compactMap { owner, pts in
            guard pts.count >= 3, !profile.blockedPlayers.contains(owner.id) else { return nil }
            let lat = pts.map(\.latitude).reduce(0, +) / Double(pts.count)
            let lon = pts.map(\.longitude).reduce(0, +) / Double(pts.count)
            let grid = 0.0027
            let snapped = Coordinate(latitude: (lat / grid).rounded() * grid, longitude: (lon / (grid * 1.6)).rounded() * grid * 1.6)
            return .init(id: "\(owner.kind.rawValue)-\(owner.id)", name: ownerName(owner), colorHex: ownerColor(owner),
                         coordinate: snapped, isBot: owner.kind == .ghost)
        }
    }

    // MARK: Runs

    /// Resolves a finished run: privacy trim → full match → anti-cheat → rules.
    func completeRun(id: UUID, trace raw: [TracePoint], signals: RunSignals, startedAt: Date, endedAt: Date, simulated: Bool) async {
        let trace = PrivacyTrimmer.trim(raw, zones: profile.privacyZones)
        let matcher = self.matcher
        let rules = self.rules
        let (match, report) = await Task.detached(priority: .userInitiated) {
            (matcher.match(trace), AntiCheat.evaluate(trace: trace, signals: signals, rules: rules.antiCheat, matching: rules.matching))
        }.value
        var s = state
        let outcome = engine.resolve(run: RunContext(runID: id, startedAt: startedAt, endedAt: endedAt), trace: trace,
                                     match: match, report: report, state: &s)
        state = s
        let distance = RunMath.distance(raw)
        let record = RunRecord(id: id, areaSlug: area.slug, startedAt: startedAt, endedAt: endedAt, distance: distance,
                               movingTime: endedAt.timeIntervalSince(startedAt), source: .live, outcome: outcome,
                               splits: RunMath.splits(raw).map { .init(distance: $0.distance, duration: $0.duration) },
                               simulated: simulated,
                               rawEndpoints: [raw.first?.coordinate, raw.last?.coordinate].compactMap { $0 })
        runs.insert(record, at: 0)
        let runsCopy = runs
        await LocalStore.shared.saveRuns(runsCopy)
        await LocalStore.shared.saveTrace(trace, run: id)
        persist()
        bumpMap()
        presentedSummary = record
        if outcome.conqueredTown { Feedback.shared.play(.block) }

        if !simulated {
            Task { try? await HealthService.shared.saveWorkout(start: startedAt, end: endedAt, distance: distance, trace: raw) }
        }
        if !simulated, backend.isSignedIn, !profile.privateMode {
            await upload(id: id, trace: trace, signals: signals, startedAt: startedAt, endedAt: endedAt)
        }
    }

    private func upload(id: UUID, trace: [TracePoint], signals: RunSignals, startedAt: Date, endedAt: Date) async {
        let upload = RunUpload(runId: id, areaSlug: area.slug, startedAt: startedAt, endedAt: endedAt, source: "live",
                               polyline: PolylineCodec.encode(trace.map(\.coordinate)),
                               timestamps: trace.map { $0.timestamp.timeIntervalSince1970 },
                               accuracies: trace.map(\.horizontalAccuracy), speeds: trace.map(\.speed), signals: signals,
                               clientVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")
        do {
            let res = try await backend.submit(upload)
            if let o = res.outcome, let i = runs.firstIndex(where: { $0.id == id }) {
                runs[i].outcome = o  // the server's answer wins
                await LocalStore.shared.saveRuns(runs)
            }
            await syncOnline()
        } catch {
            toast = "Couldn't reach the server. Your run is saved and will count locally."
        }
    }

    /// Pulls authoritative ownership from the server and listens for changes.
    func syncOnline() async {
        guard backend.isSignedIn, !profile.privateMode else { return }
        do {
            let rows = try await backend.ownership(area: area.slug)
            apply(rows: rows)
        } catch { return }
        guard realtimeTask == nil else { return }
        let slug = area.slug
        realtimeTask = Task { [weak self] in
            guard let stream = self?.backend.ownershipChanges(area: slug) else { return }
            for await row in stream { self?.apply(rows: [row]) }
        }
    }

    private func apply(rows: [ServerOwnershipRow]) {
        for r in rows {
            let owner = OwnerRef(kind: r.owner_kind == "ghost" ? .ghost : .player, id: r.owner_id == backend.userID ? profile.id : r.owner_id)
            if owner.kind == .player, owner.id != profile.id { rivals[owner.id] = RivalInfo(name: r.owner_name, colorHex: r.owner_color) }
            state.ownership[r.segment_id] = Ownership(owner: owner, capturedAt: r.captured_at, lastVisitedAt: r.last_visited_at)
        }
        persist()
        bumpMap()
    }

    /// Imports past HealthKit runs as personal exploration only.
    func importHealthHistory() async -> Int {
        guard await HealthService.shared.requestAuthorization() else { return 0 }
        let past = await HealthService.shared.pastRuns(since: .now.addingTimeInterval(-365 * 86_400))
        let matcher = self.matcher
        var imported = 0
        for r in past where !runs.contains(where: { abs($0.startedAt.timeIntervalSince(r.start)) < 60 }) {
            let trace = r.trace
            let match = await Task.detached { matcher.match(trace) }.value
            guard !match.pieces.isEmpty else { continue }
            var s = state
            let out = engine.resolve(run: RunContext(runID: UUID(), startedAt: r.start, endedAt: r.end, isImport: true),
                                     trace: trace, match: match, report: .clean, state: &s)
            state = s
            runs.append(RunRecord(id: out.runID, areaSlug: area.slug, startedAt: r.start, endedAt: r.end, distance: RunMath.distance(trace),
                                  movingTime: r.end.timeIntervalSince(r.start), source: .healthImport, outcome: out, splits: [], simulated: false))
            imported += 1
        }
        runs.sort { $0.startedAt > $1.startedAt }
        await LocalStore.shared.saveRuns(runs)
        persist()
        bumpMap()
        return imported
    }

    func leaderboard(scope: LeaderboardScope) async throws -> [LeaderboardEntry] {
        if backend.isSignedIn, !profile.privateMode {
            return try await backend.leaderboard(scope: scope, area: area.slug)
        }
        guard scope == .town else { throw BackendError.notSignedIn }
        return standings.enumerated().map { i, s in
            LeaderboardEntry(id: s.id, rank: i + 1, name: s.name, colorHex: s.colorHex, isBot: s.owner.kind == .ghost,
                             isMe: s.owner == state.me, streets: s.streets, metres: s.metres, blocks: s.blocks)
        }
    }

    func resetAllData() async {
        await LocalStore.shared.deleteEverything()
        state = GameState(areaSlug: area.slug, playerID: profile.id)
        runs = []
        var p = PlayerProfile()
        p.id = profile.id
        profile = p
        bumpMap()
    }

    // MARK: Widgets & watch

    func publishWidgets() {
        let p = progress
        let recentRaids = state.events.filter { $0.kind == .ghostRaid && $0.date > .now.addingTimeInterval(-48 * 3600) }
        let attacks = recentRaids.prefix(3).map { e in
            WidgetSnapshot.Attack(street: e.segmentIDs.compactMap { area.segment($0)?.name }.first { !$0.isEmpty } ?? "your streets",
                                  by: e.actor.map(ownerName) ?? "Bot")
        }
        let fading = state.ownership.values.filter {
            $0.owner == state.me && $0.strength(at: .now, decay: rules.decayInterval) < 0.2
        }.count
        WidgetBridge.publish(WidgetSnapshot(
            townName: area.name, playerColorHex: profile.colorHex, streetsHeld: p.heldSegments, kmHeld: p.heldMetres / 1000,
            townPercent: p.heldFraction, blocksHeld: p.blocksHeld, underAttack: Array(attacks), fadingSoon: fading,
            pellets: pellets.map { .init(name: $0.landmark.name, kind: $0.landmark.kind, collected: state.collectedPellets[$0.id] != nil) },
            bonusLabels: activeBonus.map { $0.label() }, updatedAt: .now))
    }

    func mirrorToWatch() {
        var payload: [String: Any] = [
            WatchMessage.running: run.phase == .running || run.phase == .paused,
            WatchMessage.streets: run.phase == .idle ? progress.heldSegments : run.streetsCaptured,
            WatchMessage.pellets: run.pelletsEaten,
            WatchMessage.distance: run.distance,
            WatchMessage.frenzyEndsAt: run.frenzyEndsAt?.timeIntervalSince1970 ?? 0,
            WatchMessage.colorHex: profile.colorHex,
        ]
        if let s = run.startedAt { payload[WatchMessage.startedAt] = s.timeIntervalSince1970 }
        WatchBridge.shared.send(payload)
    }
}
