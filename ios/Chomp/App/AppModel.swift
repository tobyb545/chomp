import Foundation
import Observation
import SwiftUI
import ChompKit
import UserNotifications

/// What the map draws. Rebuilt whenever ownership or the run changes.
struct MapSnapshot {
    struct SegmentLook { var state: String; var colorHex: String; var strength: Double }
    struct GhostMarker: Identifiable { var id: String; var name: String; var colorHex: String; var coordinate: Coordinate; var isBot: Bool }
    var version = 0
    /// Whole-street looks (used by the run replay) and per-coin looks (owned coins).
    var looks: [SegmentID: SegmentLook] = [:]
    var coinLooks: [CoinID: SegmentLook] = [:]
    var bonus: Set<SegmentID> = []
    var pellets: [PowerPellet] = []
    var ghosts: [GhostMarker] = []
    var heat: [SegmentID: Int]? = nil
    var trail: [Coordinate] = []
    var runner: Coordinate?
    var eaten: [SegmentID] = []
    var playerColorHex = "C6FF00"
    var conquered = false
    var look: PlayerProfile.MapLook = .dusk
    var route: [Coordinate] = []
    var metresPerToken = 10.0
}

@MainActor
@Observable
final class AppModel {
    enum WorldStatus: Equatable { case idle, needsLocation, loading(Int), failed(String) }

    // Street data: the map tiles around wherever the player is (or is looking).
    let rules = RulesConfig.bundled
    private(set) var area: Area
    private(set) var engine: GameEngine
    private(set) var matcher: MapMatcher
    private(set) var placeName = "Nearby"
    private(set) var worldStatus: WorldStatus = .idle
    private var focusTile: TileKey?
    private var loadedTiles: [TileKey: TileFile] = [:]
    private var worldTask: Task<Void, Never>?
    private var geocodedTile: TileKey?

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
    /// A loop planned before a run, drawn on the map until the run ends.
    var plannedRoute: PlannedRoute? { didSet { bumpMap() } }
    /// Centre of the map when it last settled (where a route starts if we don't know where you are).
    private(set) var lastMapCentre: Coordinate?
    var presentedSummary: RunRecord?
    var showPaywall = false
    var showInvite = false
    /// Set when a practice run ends, to show what would have happened.
    var practiceResult: PracticeResult?
    struct PracticeResult: Identifiable { let id = UUID(); let coins: Int; let streets: Int }
    /// Onboarding asked for a practice run once the map is ready.
    var wantsPractice = false
    /// New runs found in Apple Health on launch, waiting for the player to say yes or no.
    var healthPrompt: HealthPrompt?
    private var lastHealthCheck: Date?
    var focusRequest: Coordinate?
    var toast: String?

    let run = RunSession()
    let pro = ProStore()
    let backend = SupabaseBackend.shared
    private var realtimeTask: Task<Void, Never>?
    private var realtimeTiles: [TileKey] = []

    static let worldSlug = "world"
    private static let focusKey = "chomp.world.focus"

    init() {
        let profile = PlayerProfile.load()
        self.profile = profile
        let empty = Area(tiles: [])
        area = empty
        engine = GameEngine(area: empty, rules: rules)
        matcher = MapMatcher(area: empty, rules: rules.matching)
        state = GameState(areaSlug: Self.worldSlug, playerID: profile.id)
        run.model = self
        applyPreferences()
    }

    /// Where the map was last centred, so the app opens there (and offline).
    var savedFocus: Coordinate? {
        get {
            guard let a = UserDefaults.standard.array(forKey: Self.focusKey) as? [Double], a.count == 2 else { return nil }
            return Coordinate(latitude: a[0], longitude: a[1])
        }
        set {
            if let c = newValue { UserDefaults.standard.set([c.latitude, c.longitude], forKey: Self.focusKey) }
        }
    }

    // MARK: World

    /// Loads the 3x3 tiles around `c` (about 4.5 km across). Called when the app
    /// opens, when the player pans the map, and as a run moves along.
    func focusWorld(on c: Coordinate, force: Bool = false) {
        let center = TileKey(containing: c)
        if !force, center == focusTile, !isFailed { return }
        focusTile = center
        savedFocus = c
        let wanted = center.neighbourhood()
        worldTask?.cancel()
        worldTask = Task { [weak self] in await self?.load(wanted, around: center) }
        Task { await geocode(center) }
    }

    private var isLoading: Bool { if case .loading = worldStatus { return true } else { return false } }
    private var isFailed: Bool { if case .failed = worldStatus { return true } else { return false } }

    /// The map camera settled. Streets load once the player zooms in far enough
    /// to see them.
    func mapSettled(at c: Coordinate, zoom: Double) {
        guard zoom >= 12.5, !run.isActive else { return }
        lastMapCentre = c
        focusWorld(on: c)
    }

    /// While running, keep the tiles ahead loaded without dropping the ones behind.
    func runMoved(to c: Coordinate) {
        let around = TileKey(containing: c).neighbourhood()
        let missing = around.filter { loadedTiles[$0] == nil }
        guard !missing.isEmpty, worldTask == nil || !isLoading else { return }
        worldTask = Task { [weak self] in
            guard let self else { return }
            await self.load(Array(Set(self.area.tiles + around)).sorted(), around: TileKey(containing: c))
        }
    }

    private func load(_ wanted: [TileKey], around center: TileKey) async {
        // Show whatever is already on the phone straight away.
        let cached = await WorldStore.shared.cached(wanted)
        for t in cached { if let k = TileKey(string: t.key) { loadedTiles[k] = t } }
        var keep = Set(wanted)
        if run.isActive { keep.formUnion(area.tiles) }
        loadedTiles = loadedTiles.filter { keep.contains($0.key) }
        await install()

        let order = wanted.sorted { distance($0, center) < distance($1, center) }
        var stale: [TileKey] = []
        for k in order where !(await WorldStore.shared.isFresh(k)) { stale.append(k) }
        guard !stale.isEmpty else { worldStatus = .idle; worldTask = nil; return }
        var failure: String?
        worldStatus = .loading(stale.count)
        do {
            let got = try await WorldStore.shared.tiles(stale)
            if Task.isCancelled { return }
            for (k, t) in got { loadedTiles[k] = t }
            await install()
            if stale.contains(where: { loadedTiles[$0] == nil }) { failure = WorldStore.WorldError.offline.localizedDescription }
        } catch {
            if Task.isCancelled { return }
            failure = error.localizedDescription
        }
        worldStatus = failure.map { .failed($0) } ?? .idle
        worldTask = nil
    }

    private func distance(_ a: TileKey, _ b: TileKey) -> Int { abs(a.x - b.x) + abs(a.y - b.y) }

    /// Rebuilds the playable graph from the loaded tiles (off the main thread).
    private func install() async {
        let files = Array(loadedTiles.values)
        let name = placeName
        guard Set(files.map(\.key)) != Set(area.tiles.map(\.description)) else { return }
        let built = await Task.detached(priority: .userInitiated) { Area(tiles: files, name: name) }.value
        setArea(built)
    }

    private func setArea(_ a: Area) {
        area = a
        engine = GameEngine(area: a, rules: rules)
        matcher = MapMatcher(area: a, rules: rules.matching)
        refreshDay()
        run.areaDidChange()
        // State saved before tokens existed: credit the streets each owner holds now.
        if state.tokensCaptured == nil, !a.segments.isEmpty {
            state.tokensCaptured = [:]
            for s in a.segments { if let o = state.ownership[s.id] { state.addTokens(rules.tokens(forLength: s.length), to: o.owner) } }
        }
        // State saved before coins: each street's owner now holds all its coins.
        engine.migrateToCoins(state: &state)
        if state.ghosts.isEmpty, !a.segments.isEmpty { tickWorld() }
        bumpMap()
        Task { await subscribeRealtime() }
    }

    /// Street data for an arbitrary trace (a finished run or an import), which
    /// may be outside the tiles on screen. Downloads what's missing.
    func area(covering coords: [Coordinate]) async -> Area {
        let keys = TileKey.covering(coords)
        if Set(keys).isSubset(of: Set(area.tiles)) { return area }
        var files: [TileFile] = keys.compactMap { loadedTiles[$0] }
        let need = keys.filter { loadedTiles[$0] == nil }
        if !need.isEmpty, let got = try? await WorldStore.shared.tiles(need) { files += got.values }
        let name = placeName
        return await Task.detached(priority: .userInitiated) { Area(tiles: files, name: name) }.value
    }

    private func geocode(_ tile: TileKey) async {
        guard geocodedTile != tile else { return }
        geocodedTile = tile
        if let name = await PlaceNamer.name(for: tile.center), geocodedTile == tile { placeName = name; publishWidgets() }
    }

    /// Tries to centre the world on the player.
    func locateAndLoad() async {
        if let here = await LocationPermission.shared.currentLocation() {
            focusRequest = here
            focusWorld(on: here)
        } else if let saved = savedFocus {
            focusWorld(on: saved)
        } else {
            worldStatus = .needsLocation
        }
    }

    // MARK: Lifecycle

    func bootstrap() async {
        if let saved = await LocalStore.shared.loadState(area: Self.worldSlug) {
            state = saved
        } else if var legacy = await LocalStore.shared.loadState(area: "west-byfleet") {
            // Before the world map, everything lived in one town. Street IDs are
            // unchanged (same OSM-derived scheme), so progress carries over.
            legacy.areaSlug = Self.worldSlug
            state = legacy
        }
        state.playerID = profile.id
        if let saved = savedFocus { focusWorld(on: saved) }
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
        if profile.onboarded { await locateAndLoad() }
        tickWorld()
        await syncOnline()
    }

    /// `-marketing` (debug builds): hides "Simulated" badges for App Store screenshots.
    static let marketing: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-marketing")
        #else
        false
        #endif
    }()

    #if DEBUG
    /// `-demo` launch argument: skips onboarding and plays a week of simulated
    /// runs instantly, so screenshots and UI checks have a lived-in town.
    private func seedDemoIfRequested() async {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-demo") { profile.seenIntro = !args.contains("-intro") }
        if let i = args.firstIndex(of: "-mapLook"), i + 1 < args.count, let look = PlayerProfile.MapLook(rawValue: args[i + 1]) {
            profile.mapLook = look
        }
        if args.contains("-planRoute") {
            Task {
                for _ in 0..<60 where area.segments.isEmpty { try? await Task.sleep(for: .seconds(1)) }
                plannedRoute = await planRoute(goal: .capture, distance: 4000, seed: 3)
            }
        }
        guard args.contains("-demo"), runs.isEmpty else {
            if args.contains("-autorun"), profile.onboarded { run.start(simulated: true) }
            return
        }
        var p = profile
        p.name = "Alex"
        p.onboarded = true
        profile = p
        let demoCentre = Coordinate(latitude: 51.3392, longitude: -0.5063)  // West Byfleet
        focusRequest = demoCentre
        focusWorld(on: demoCentre, force: true)
        await worldTask?.value
        guard !area.segments.isEmpty else { return }
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
        checkForAttacks()
        Task { await checkForNewHealthRuns() }
        if case .failed = worldStatus, let f = savedFocus { focusWorld(on: f, force: true) }
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
        guard run.phase == .idle, !area.segments.isEmpty else { return }
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
        guard run.phase == .idle, profile.pushRaids else { return }
        let at = Date().addingTimeInterval(6 * 3600)
        var copy = state
        let ghosts = GhostSimulator(engine: engine)
        let raids = ghosts.tick(state: &copy, now: at)
        guard let first = raids.first else { return }
        state.scheduledGhostTick = at
        NotificationService.scheduleRaid(message: first.message, at: at)
        let fading = Set(state.ownership.filter {
            $0.value.owner == state.me && $0.value.strength(at: .now.addingTimeInterval(3 * 86_400), decay: rules.decayInterval) <= 0
        }.map { Coins.segment(of: $0.key) }).count
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

    /// The map square in the middle of the screen is fully held.
    var isConquered: Bool {
        rules.blocks.isEnabled && (focusTile.map { state.badges.contains("conquered:\($0)") } ?? false)
    }

    /// Streets held anywhere in the world, not just nearby.
    var streetsHeldEverywhere: Int { engine.heldEverywhere(by: state.me, state: state, now: .now) }

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
        s.look = profile.mapLook
        let now = Date()
        let decay = rules.decayInterval
        let blocked = Set(profile.blockedPlayers)
        var colours: [OwnerRef: String] = [:]
        for (id, o) in state.ownership where Coins.isCoin(id) && !blocked.contains(o.owner.id) {
            let strength = o.strength(at: now, decay: decay)
            guard strength > 0 else { continue }
            let mine = o.owner == state.me
            let colour = colours[o.owner] ?? ownerColor(o.owner)
            colours[o.owner] = colour
            s.coinLooks[id] = .init(state: mine ? "mine" : "rival", colorHex: colour, strength: strength)
        }
        // Coins collected on this run so far turn yours straight away.
        for (seg, idx) in run.coinsTaken {
            for i in idx { s.coinLooks[Coins.id(seg, i)] = .init(state: "mine", colorHex: profile.colorHex, strength: 1) }
        }
        s.bonus = Set(activeBonus.flatMap(\.segmentIDs))
        s.pellets = uncollectedPellets.filter { pellet in !run.collectedThisRun.contains(pellet.id) }
        s.metresPerToken = rules.tokens.metresPerToken
        s.ghosts = ghostMarkers(now: now)
        if heatmapOn { s.heat = state.coverage.mapValues(\.timesRun) }
        s.trail = run.trail
        s.runner = run.trail.last
        s.route = plannedRoute?.coordinates ?? []
        s.eaten = run.tracker?.eatenOrder ?? []
        return s
    }

    /// Rivals are shown only by the rough centre of their territory (snapped to a
    /// ~300 m grid), never by live position.
    private func ghostMarkers(now: Date) -> [MapSnapshot.GhostMarker] {
        var byOwner: [OwnerRef: [Coordinate]] = [:]
        for (id, o) in state.ownership where o.owner != state.me && o.strength(at: now, decay: rules.decayInterval) > 0 {
            if let seg = area.segment(Coins.segment(of: id)) { byOwner[o.owner, default: []].append(seg.midpoint) }
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
        guard let record = await resolve(id: id, raw: raw, signals: signals, startedAt: startedAt, endedAt: endedAt,
                                         source: .live, isImport: false, simulated: simulated) else { return }
        presentedSummary = record
        plannedRoute = nil
        if record.outcome.conqueredTown { Feedback.shared.play(.block) }
        if !simulated {
            Task { try? await HealthService.shared.saveWorkout(start: startedAt, end: endedAt, distance: record.distance, trace: raw) }
        }
        if let end = raw.last?.coordinate { focusWorld(on: end) }
    }

    /// Shared by live runs and imports. Returns nil if the trace couldn't be used.
    @discardableResult
    private func resolve(id: UUID, raw: [TracePoint], signals: RunSignals, startedAt: Date, endedAt: Date,
                         source: RunRecord.Source, isImport: Bool, simulated: Bool, upload: Bool = true) async -> RunRecord? {
        let trace = PrivacyTrimmer.trim(raw, zones: profile.privacyZones)
        let runArea = await area(covering: trace.map(\.coordinate))
        let matcher = runArea === area ? self.matcher : MapMatcher(area: runArea, rules: rules.matching)
        let rules = self.rules
        let (match, report) = await Task.detached(priority: .userInitiated) {
            (matcher.match(trace), AntiCheat.evaluate(trace: trace, signals: signals, rules: rules.antiCheat, matching: rules.matching))
        }.value
        guard source == .live || !match.pieces.isEmpty else { return nil }
        var s = state
        let runEngine = runArea === area ? engine : GameEngine(area: runArea, rules: rules)
        let outcome = runEngine.resolve(run: RunContext(runID: id, startedAt: startedAt, endedAt: endedAt, isImport: isImport),
                                        trace: trace, match: match, report: report, state: &s)
        state = s
        let goalsBefore = Set(weeklyGoals.filter(\.done).map(\.id))
        var record = RunRecord(id: id, areaSlug: Self.worldSlug, startedAt: startedAt, endedAt: endedAt, distance: RunMath.distance(raw),
                               movingTime: endedAt.timeIntervalSince(startedAt), source: source, outcome: outcome,
                               splits: RunMath.splits(raw).map { .init(distance: $0.distance, duration: $0.duration) },
                               simulated: simulated,
                               rawEndpoints: [raw.first?.coordinate, raw.last?.coordinate].compactMap { $0 })
        record.tokens = tokens(of: outcome, in: runArea)
        runs.insert(record, at: 0)
        runs.sort { $0.startedAt > $1.startedAt }
        await LocalStore.shared.saveRuns(runs)
        await LocalStore.shared.saveTrace(trace, run: id)
        persist()
        bumpMap()
        announceGoals(before: goalsBefore)
        scheduleStreakReminder()
        if upload, !simulated, backend.isSignedIn, !profile.privateMode {
            await self.upload(id: id, trace: trace, signals: signals, startedAt: startedAt, endedAt: endedAt, source: source)
        }
        return runs.first { $0.id == id } ?? record
    }

    private func upload(id: UUID, trace: [TracePoint], signals: RunSignals, startedAt: Date, endedAt: Date, source: RunRecord.Source) async {
        let upload = RunUpload(runId: id, startedAt: startedAt, endedAt: endedAt,
                               source: source == .live ? "live" : source == .healthImport ? "health_import" : "strava_import",
                               polyline: PolylineCodec.encode(trace.map(\.coordinate)),
                               timestamps: trace.map { $0.timestamp.timeIntervalSince1970 },
                               accuracies: trace.map(\.horizontalAccuracy), speeds: trace.map(\.speed), signals: signals,
                               clientVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")
        do {
            let res = try await backend.submit(upload)
            if let o = res.outcome, let i = runs.firstIndex(where: { $0.id == id }) {
                runs[i].outcome = o  // the server's answer wins
                if o.gained.allSatisfy({ area.segment($0.segmentID) != nil }) { runs[i].tokens = tokens(of: o, in: area) }
                await LocalStore.shared.saveRuns(runs)
            }
            await syncOnline()
        } catch {
            toast = "Couldn't reach the server. Your run is saved and will count locally."
        }
    }

    /// Pulls authoritative ownership for the tiles on screen and listens for changes.
    // MARK: Goals, streaks and route planning

    /// Tokens a run earned: the coins it collected (whole streets, for runs saved before coins).
    func tokens(of outcome: RunOutcome, in a: Area) -> Int {
        outcome.gained.reduce(0) { sum, c in
            sum + (c.tokens ?? a.segment(c.segmentID).map { rules.tokens(forLength: $0.length) } ?? 0)
        }
    }

    /// Runs that count for goals and streaks. Debug builds count simulated runs
    /// too, so the features can be tried in the simulator.
    var runFacts: [RunFacts] {
        runs.filter { r in
            #if DEBUG
            true
            #else
            !r.simulated
            #endif
        }.map { r in
            RunFacts(date: r.startedAt, distance: r.distance, streets: r.outcome.gained.count, stolen: r.outcome.stolen.count,
                     tokens: r.tokens ?? r.outcome.gained.count * 8, pellets: r.outcome.pelletsCollected.count,
                     blocks: r.outcome.blocksCompleted.count)
        }
    }

    var weeklyGoals: [WeeklyGoal] { Goals.weekly(runs: runFacts, now: .now) }
    var streak: Goals.Streak { Goals.streak(runs: runFacts, now: .now) }

    private func announceGoals(before: Set<String>) {
        let goals = weeklyGoals
        let fresh = goals.filter { $0.done && !before.contains($0.id) }
        guard let g = fresh.first else { return }
        Feedback.shared.play(.block)
        toast = goals.allSatisfy(\.done) ? "All three weekly goals done!" : "Goal done: \(g.title)"
    }

    /// 7pm reminder when a streak would end tonight; cleared once you've run today.
    func scheduleStreakReminder() {
        let s = streak
        let id = "streak-reminder"
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        guard s.current >= 2, !s.ranToday else { return }
        var at = Goals.calendar.date(bySettingHour: 19, minute: 0, second: 0, of: .now) ?? .now
        if at < .now { at = Date().addingTimeInterval(60) }
        guard Goals.calendar.isDate(at, inSameDayAs: .now) else { return }
        let c = UNMutableNotificationContent()
        c.title = "Keep your \(s.current)-day streak"
        c.body = "A short run today keeps it going. Even one street counts."
        c.sound = .default
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: at)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c,
            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
    }

    enum RouteGoal: String, CaseIterable, Identifiable {
        case capture, defend, explore
        var id: String { rawValue }
        /// "Save fading" only makes sense while streets fade.
        static var allCases: [RouteGoal] { RulesConfig.bundled.decay.isEnabled ? [.capture, .defend, .explore] : [.capture, .explore] }
        var label: String { switch self { case .capture: "Grab streets"; case .defend: "Save fading"; case .explore: "Explore" } }
        var detail: String {
            switch self {
            case .capture: "Neutral streets and rivals' streets to take."
            case .defend: "Your streets that are fading, before they turn neutral."
            case .explore: "Streets you've never run."
            }
        }
    }

    /// Where a planned loop starts: where you are, or the middle of the map.
    var routeStart: Coordinate {
        if let here = LocationPermission.shared.lastKnown, area.contains(here) { return here }
        // The map's camera starts somewhere generic before it flies to you, so only
        // trust a centre that's inside the streets we have.
        return [lastMapCentre, savedFocus].compactMap { $0 }.first { area.contains($0) } ?? area.center
    }

    func planRoute(goal: RouteGoal, distance: Double, seed: UInt64) async -> PlannedRoute? {
        let a = area, st = state, me = state.me, now = Date(), decay = rules.decayInterval, r = rules
        let start = routeStart
        let wanted: [Double] = a.segments.map { seg in
            let coins = r.coinIDs(seg).map { st.ownership[$0].flatMap { $0.strength(at: now, decay: decay) > 0 ? $0 : nil } }
            let n = Double(coins.count)
            switch goal {
            case .capture:
                // Value the coins you'd gain: unclaimed 1, a rival's 1.2, yours nothing.
                return coins.reduce(0.0) { $0 + ($1 == nil ? 1 : ($1!.owner == me ? 0 : 1.2)) } / n
            case .defend:
                let mine = coins.compactMap { $0 }.filter { $0.owner == me }
                guard let weakest = mine.map({ $0.strength(at: now, decay: decay) }).min() else { return 0 }
                return weakest < 0.6 ? 1.2 - weakest : 0
            case .explore: return st.coverage[seg.id] == nil ? 1 : 0
            }
        }
        let lengths = a.segments.map(\.length)
        return await Task.detached(priority: .userInitiated) {
            RoutePlanner(area: a).plan(from: start, distance: distance, seed: seed,
                                       value: { wanted[$0] }, tokens: { r.tokens(forLength: lengths[$0]) })
        }.value
    }

    // MARK: Invites

    /// A club invite link (chomp://club/<code>) waiting to be shown on the Clubs screen.
    var pendingClubCode: String?
    var showClubs = false

    func openClubInvite(code: String) {
        let c = code.uppercased().filter { $0.isLetter || $0.isNumber }
        guard (4...12).contains(c.count) else { return }
        pendingClubCode = c
        showClubs = true
    }

    /// The link a club shares. Custom scheme for now; swap for a universal link once there's a website.
    static func clubLink(_ code: String) -> String { "chomp://club/\(code)" }

    /// A friend's invite link was opened: remember the code until we can redeem it.
    func openInvite(code: String) {
        let c = InviteCode.normalise(code)
        guard InviteCode.isValid(c) else { return }
        profile.pendingInviteCode = c
        showInvite = true
        Task { await refreshInvitePro() }
    }

    /// Redeems a pending code once signed in, and picks up any free Pro months earned.
    func refreshInvitePro() async {
        guard backend.isSignedIn else { return }
        if let code = profile.pendingInviteCode {
            if (try? await backend.redeemInvite(code: code)) != nil { profile.pendingInviteCode = nil }
        }
        if let until = try? await backend.invitePremiumUntil() { pro.invitePro = until }
    }

    func syncOnline() async {
        await refreshInvitePro()
        await PushService.shared.sync()
        guard backend.isSignedIn, !profile.privateMode, !area.tiles.isEmpty else { return }
        do {
            let rows = try await backend.ownership(tiles: area.tiles.map(\.description))
            apply(rows: rows)
        } catch { return }
        await subscribeRealtime()
    }

    private func subscribeRealtime() async {
        guard backend.isSignedIn, !profile.privateMode, area.tiles != realtimeTiles, !area.tiles.isEmpty else { return }
        realtimeTiles = area.tiles
        realtimeTask?.cancel()
        let tiles = area.tiles.map(\.description)
        realtimeTask = Task { [weak self] in
            guard let stream = self?.backend.ownershipChanges(tiles: tiles) else { return }
            for await row in stream { self?.apply(rows: [row]) }
        }
    }

    private func apply(rows: [ServerOwnershipRow]) {
        for r in rows {
            let owner = OwnerRef(kind: r.owner_kind == "ghost" ? .ghost : .player, id: r.owner_id == backend.userID ? profile.id : r.owner_id)
            if owner.kind == .player, owner.id != profile.id { rivals[owner.id] = RivalInfo(name: r.owner_name, colorHex: r.owner_color) }
            let o = Ownership(owner: owner, capturedAt: r.captured_at, lastVisitedAt: r.last_visited_at)
            if Coins.isCoin(r.segment_id) {
                state.ownership[r.segment_id] = o
            } else if let seg = area.segment(r.segment_id) {
                // A server that still stores whole streets: the owner holds every coin.
                for id in rules.coinIDs(seg) { state.ownership[id] = o }
            }
        }
        persist()
        bumpMap()
    }

    /// Folds server-side exploration (e.g. Strava imports) into local coverage.
    func mergeServerCoverage() async {
        guard let rows = try? await backend.personalCoverage() else { return }
        for r in rows {
            var c = state.coverage[r.segment_id] ?? PersonalCoverage(firstRunAt: r.first_at, lastRunAt: r.last_at, timesRun: 0, importedOnly: r.source == "import")
            c.firstRunAt = min(c.firstRunAt, r.first_at)
            c.lastRunAt = max(c.lastRunAt, r.last_at)
            c.timesRun = max(c.timesRun, r.times_run)
            c.importedOnly = c.importedOnly && r.source == "import"
            state.coverage[r.segment_id] = c
        }
        persist()
        bumpMap()
    }

    // MARK: Apple Health

    /// Streets rivals or bots took while you were away.
    struct AttackReport: Equatable {
        let streets: Int
        let by: [String]
        let focus: Coordinate?
        var message: String {
            let who = by.count == 1 ? by[0] : by.count == 2 ? "\(by[0]) and \(by[1])" : "\(by[0]) and \(by.count - 1) others"
            return "\(who) took \(streets) of your street\(streets == 1 ? "" : "s") while you were away"
        }
    }
    var attackReport: AttackReport?

    /// Builds the banner from losses since it was last dismissed (none on a first launch).
    func checkForAttacks() {
        guard profile.onboarded, run.phase == .idle else { return }
        guard let since = profile.attacksSeenAt else { profile.attacksSeenAt = .now; return }
        let hits = state.events.filter { ($0.kind == .lost || $0.kind == .ghostRaid) && $0.date > since
            && !($0.actor.map { profile.mutedPlayers.contains($0.id) } ?? false) }
        let streets = Set(hits.flatMap(\.segmentIDs)).count
        guard streets > 0 else { attackReport = nil; return }
        var names: [String] = []
        for e in hits.sorted(by: { $0.date > $1.date }) {
            if let a = e.actor { let n = ownerName(a); if !names.contains(n) { names.append(n) } }
        }
        let focus = hits.max { $0.date < $1.date }?.segmentIDs.first.flatMap { area.segment($0)?.midpoint }
        attackReport = AttackReport(streets: streets, by: names.isEmpty ? ["Rivals"] : names, focus: focus)
    }

    #if DEBUG
    func replaceEventsForTesting(_ events: [GameEvent]) { state.events = events }
    #endif

    func dismissAttacks(showMe: Bool) {
        if showMe, let f = attackReport?.focus { focusRequest = f }
        attackReport = nil
        profile.attacksSeenAt = .now
    }

    struct HealthPrompt: Identifiable {
        let id = UUID()
        let runs: [HealthService.WorkoutSummary]
    }

    /// On launch: offers runs recorded by another app since you last opened Chomp,
    /// while they can still capture coins. Each run is only offered once.
    func checkForNewHealthRuns() async {
        guard profile.onboarded, profile.seenIntro, run.phase == .idle, healthPrompt == nil, presentedSummary == nil else { return }
        if let last = lastHealthCheck, Date().timeIntervalSince(last) < 600 { return }
        lastHealthCheck = .now
        guard await HealthService.shared.hasBeenAsked() else { return }
        let since = Date().addingTimeInterval(-rules.imports.captureWindowHours * 3600)
        let offered = Set(profile.healthOffered)
        let fresh = await HealthService.shared.recentRuns(since: since).filter { w in
            !offered.contains(w.id) && !runs.contains { abs($0.startedAt.timeIntervalSince(w.start)) < 120 }
        }
        guard !fresh.isEmpty else { return }
        healthPrompt = HealthPrompt(runs: fresh.sorted { $0.start < $1.start })
    }

    /// The player answered the prompt. Either way these runs aren't offered again.
    func answerHealthPrompt(importing: Bool) async {
        guard let prompt = healthPrompt else { return }
        healthPrompt = nil
        profile.healthOffered = Array((profile.healthOffered + prompt.runs.map(\.id)).suffix(300))
        guard importing else { return }
        var coins = 0, added = 0
        for w in prompt.runs {
            presentedSummary = nil
            _ = await importHealthRun(w)
            if let r = presentedSummary, abs(r.startedAt.timeIntervalSince(w.start)) < 120 {
                added += 1
                coins += tokens(of: r.outcome, in: area)
            }
        }
        toast = added == 0 ? "No streets Chomp knows about on \(prompt.runs.count == 1 ? "that run" : "those runs")"
            : "Added \(added) run\(added == 1 ? "" : "s"): \(coins) coin\(coins == 1 ? "" : "s") collected"
    }

    /// Runs in Health that Chomp hasn't seen yet (recorded by another app or watch).
    func healthRunsToImport() async -> [HealthService.WorkoutSummary] {
        guard await HealthService.shared.requestAuthorization() else { return [] }
        let since = Date().addingTimeInterval(-60 * 86_400)
        return await HealthService.shared.recentRuns(since: since).filter { w in
            !runs.contains { abs($0.startedAt.timeIntervalSince(w.start)) < 120 }
        }
    }

    /// Whether an imported run this old still captures streets.
    func importCaptures(endedAt: Date) -> Bool {
        Date().timeIntervalSince(endedAt) <= rules.imports.captureWindowHours * 3600
    }

    /// Adds one run from Health as if it had been recorded in Chomp. Recent runs
    /// capture streets (within the import window); older ones count as exploration.
    func importHealthRun(_ w: HealthService.WorkoutSummary) async -> String {
        let raw = await HealthService.shared.trace(for: w.id)
        guard raw.count > 10 else { return "That run has no GPS route in Health, so there are no streets to add." }
        var signals = RunSignals()
        signals.heartRate = await HealthService.shared.heartRate(from: w.start, to: w.end)
        let counts = importCaptures(endedAt: w.end)
        guard let record = await resolve(id: UUID(), raw: raw, signals: signals, startedAt: w.start, endedAt: w.end,
                                         source: .healthImport, isImport: !counts, simulated: false) else {
            return "None of that run was on streets Chomp knows about."
        }
        presentedSummary = record
        if let end = raw.last?.coordinate { focusRequest = end; focusWorld(on: end) }
        if !counts { return "Added for exploration. Runs older than \(Int(rules.imports.captureWindowHours / 24)) days can't capture streets." }
        let n = record.outcome.gained.count
        return n == 0 ? "Run added. No new streets this time." : "Run added: \(n) street\(n == 1 ? "" : "s") captured."
    }

    /// Imports past HealthKit runs as personal exploration only.
    func importHealthHistory() async -> Int {
        guard await HealthService.shared.requestAuthorization() else { return 0 }
        let past = await HealthService.shared.pastRuns(since: .now.addingTimeInterval(-365 * 86_400))
        var imported = 0
        for r in past where !runs.contains(where: { abs($0.startedAt.timeIntervalSince(r.start)) < 120 }) {
            if await resolve(id: UUID(), raw: r.trace, signals: RunSignals(), startedAt: r.start, endedAt: r.end,
                             source: .healthImport, isImport: true, simulated: false, upload: false) != nil {
                imported += 1
            }
        }
        return imported
    }

    func leaderboard(scope: LeaderboardScope) async throws -> [LeaderboardEntry] {
        if backend.isSignedIn, !profile.privateMode, let tile = focusTile {
            return try await backend.leaderboard(scope: scope, tile: tile.description)
        }
        guard scope == .nearby else { throw BackendError.notSignedIn }
        return standings.enumerated().map { i, s in
            LeaderboardEntry(id: s.id, rank: i + 1, name: s.name, colorHex: s.colorHex, isBot: s.owner.kind == .ghost,
                             isMe: s.owner == state.me, tokens: s.tokens)
        }
    }

    /// Clubs ranked by the coins their members collected (nearby region or worldwide).
    func clubLeaderboard(scope: ClubScope) async throws -> [ClubStanding] {
        guard backend.isSignedIn, !profile.privateMode else { throw BackendError.notSignedIn }
        let tile = (focusTile ?? TileKey(containing: area.center)).description
        return try await backend.clubLeaderboard(scope: scope, tile: tile)
    }

    func resetAllData() async {
        await LocalStore.shared.deleteEverything()
        await WorldStore.shared.deleteAll()
        state = GameState(areaSlug: Self.worldSlug, playerID: profile.id)
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
        let fading = Set(state.ownership.filter {
            $0.value.owner == state.me && $0.value.strength(at: .now, decay: rules.decayInterval) < 0.2
        }.map { Coins.segment(of: $0.key) }).count
        WidgetBridge.publish(WidgetSnapshot(
            townName: placeName, playerColorHex: profile.colorHex, streetsHeld: streetsHeldEverywhere, kmHeld: p.heldMetres / 1000,
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
