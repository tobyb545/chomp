import Foundation
import Testing
@testable import ChompKit

final class TestBundle {}

enum Fixtures {
    /// Real OpenStreetMap data for 3x3 tiles around West Byfleet (shared/fixtures/osm-west-byfleet.json).
    static let osm: OverpassResponse = {
        let url = Bundle(for: TestBundle.self).url(forResource: "osm-west-byfleet", withExtension: "json")!
        return try! JSONDecoder().decode(OverpassResponse.self, from: Data(contentsOf: url))
    }()
    static let centerTile = TileKey(x: 8168, y: 5460)
    static let builtAt = Date(timeIntervalSince1970: 1_790_000_000)

    static let tiles: [TileFile] = centerTile.neighbourhood().map {
        StreetBuilder.buildTile($0, osm: StreetBuilder.subset(osm, for: $0), generatedAt: builtAt)
    }
    static let area = Area(tiles: tiles, name: "West Byfleet")
    static let rules = RulesConfig.bundled
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000) // fixed, mid-2026

    static func run(seed: UInt64, distance: Double = 2500, speed: Double = 3.0, start: Date = t0) -> (route: [Coordinate], trace: [TracePoint]) {
        let sim = RouteSimulator(area: area)
        let route = sim.route(from: area.center, distance: distance, seed: seed)
        return (route, sim.trace(along: route, start: start, speed: speed, seed: seed &+ 1))
    }

    /// Segment indices the simulated route fully walked.
    static func walkedSegments(_ route: [Coordinate]) -> Set<Int> {
        let proj = area.projection
        var out = Set<Int>()
        for s in area.segments where s.length > 15 {
            let pts = [s.polyline.point(at: s.length * 0.25), s.polyline.point(at: s.length * 0.5), s.polyline.point(at: s.length * 0.75)]
            let line = Polyline(route.map(proj.project))
            if pts.allSatisfy({ line.project($0).distance < 1.0 }) { out.insert(s.index) }
        }
        return out
    }
}

@Suite("Geometry")
struct GeometryTests {
    @Test func intervalUnionMerges() {
        var s = IntervalSet()
        s.insert(0...10)
        s.insert(20...30)
        s.insert(5...22)
        #expect(s.intervals.count == 1)
        #expect(s.coveredLength == 30)
    }

    @Test func polylineCodecRoundTrips() {
        let coords = [Coordinate(latitude: 51.3392, longitude: -0.5063), Coordinate(latitude: 51.3401, longitude: -0.5071),
                      Coordinate(latitude: 51.3388, longitude: -0.5102)]
        let back = PolylineCodec.decode(PolylineCodec.encode(coords))
        #expect(back.count == 3)
        for (a, b) in zip(coords, back) { #expect(a.distance(to: b) < 1.5) }
    }

    @Test func projectionIsAccurate() {
        let a = Coordinate(latitude: 51.34, longitude: -0.51)
        let b = a.offset(metres: 1000, bearingDegrees: 60)
        let p = LocalProjection(origin: a)
        #expect(abs(p.project(b).distance(to: p.project(a)) - a.distance(to: b)) < 5)
    }
}

@Suite("Area data")
struct AreaTests {
    @Test func buildsWestByfleetFromOpenStreetMap() {
        let a = Fixtures.area
        #expect(a.tiles.count == 9)
        #expect(a.segments.count > 800)
        #expect(a.totalLength > 60_000)
        #expect(!a.blocks.isEmpty)
        #expect(!a.landmarks.isEmpty)
        #expect(Set(a.segments.map(\.id)).count == a.segments.count, "segment IDs must be unique")
        #expect(a.contains(a.center))
        #expect(a.segments.contains { $0.name == "Old Woking Road" })
    }

    @Test func eachStreetBelongsToExactlyOneTile() {
        var seen: [String: String] = [:]
        for t in Fixtures.tiles {
            for s in t.segments {
                #expect(seen[s.id] == nil, "\(s.id) in \(t.key) and \(seen[s.id] ?? "")")
                seen[s.id] = t.key
            }
        }
    }

    @Test func streetsJoinUpAcrossTileEdges() {
        let a = Fixtures.area
        var tilesAtNode: [Int64: Set<TileKey>] = [:]
        for s in a.segments {
            tilesAtNode[s.startNode, default: []].insert(a.segmentTile[s.index])
            tilesAtNode[s.endNode, default: []].insert(a.segmentTile[s.index])
        }
        #expect(tilesAtNode.values.filter { $0.count > 1 }.count > 20)
    }

    @Test func tileMathRoundTrips() {
        let c = Coordinate(latitude: 51.3392, longitude: -0.5063)
        let t = TileKey(containing: c)
        #expect(t == Fixtures.centerTile)
        #expect(t.contains(c) && t.contains(t.center))
        #expect(TileKey(string: t.description) == t)
        #expect(t.west < c.longitude && c.longitude < t.east && t.south < c.latitude && c.latitude < t.north)
    }

    @Test func blocksReferenceRealSegments() {
        // Blocks in the middle tile only use streets from it and its loaded neighbours.
        let mid = Fixtures.tiles.first { $0.key == Fixtures.centerTile.description }!
        #expect(!mid.blocks.isEmpty)
        for b in mid.blocks {
            for s in b.segments { #expect(Fixtures.area.segment(s) != nil) }
        }
    }
}

@Suite("Map matching")
struct MatchingTests {
    @Test(arguments: [1, 2, 3, 4] as [UInt64])
    func simulatedRunCapturesTheStreetsItRan(seed: UInt64) {
        let (route, trace) = Fixtures.run(seed: seed)
        let matcher = MapMatcher(area: Fixtures.area, rules: Fixtures.rules.matching)
        let result = matcher.match(trace)
        let cov = result.coverage()
        let walked = Fixtures.walkedSegments(route)
        #expect(!walked.isEmpty)
        let captured = walked.filter { i in (cov[i]?.coveredLength ?? 0) / Fixtures.area.segments[i].length >= 0.8 }
        // GPS noise at junctions can shave the odd short street, but the vast majority must count.
        #expect(Double(captured.count) / Double(walked.count) >= 0.9, "captured \(captured.count)/\(walked.count)")
        // And we must not hand out streets the runner never touched.
        let falsePositives = cov.filter { i, set in !walked.contains(i) && set.coveredLength / Fixtures.area.segments[i].length >= 0.8 && Fixtures.area.segments[i].length > 30 }
        #expect(falsePositives.count <= max(2, walked.count / 10), "false positives: \(falsePositives.count)")
    }

    @Test func gapsBreakTheTrace() {
        var (_, trace) = Fixtures.run(seed: 9)
        let mid = trace.count / 2
        for i in mid..<trace.count { trace[i].timestamp.addTimeInterval(600) }
        let r = MapMatcher(area: Fixtures.area, rules: Fixtures.rules.matching).match(trace)
        #expect(r.chunks >= 2)
    }

    @Test func liveTrackerAgreesWithFullMatch() {
        let (_, trace) = Fixtures.run(seed: 5, distance: 1500)
        let matcher = MapMatcher(area: Fixtures.area, rules: Fixtures.rules.matching)
        var live = LiveCaptureTracker(matcher: matcher, threshold: 0.8)
        var i = 30
        while i <= trace.count {
            _ = live.ingest(trace: Array(trace[0..<i]), isRival: { _ in false }, frenzy: false, frenzyThreshold: 0.4)
            i += 30
        }
        _ = live.ingest(trace: trace, isRival: { _ in false }, frenzy: false, frenzyThreshold: 0.4)
        let full = matcher.match(trace).coverage()
        let fullEaten = Set(full.filter { $0.value.coveredLength / Fixtures.area.segments[$0.key].length >= 0.8 }.map { Fixtures.area.segments[$0.key].id })
        let overlap = live.eaten.intersection(fullEaten).count
        #expect(Double(overlap) >= Double(fullEaten.count) * 0.85)
    }
}

@Suite("Game rules")
struct GameTests {
    let engine = GameEngine(area: Fixtures.area, rules: Fixtures.rules)
    /// Capture areas are switched off in rules.json for now; these tests keep them working for later.
    static let areasOn: GameEngine = { var r = Fixtures.rules; r.blocks.enabled = true; return GameEngine(area: Fixtures.area, rules: r) }()

    func resolve(_ trace: [TracePoint], state: inout GameState, signals: RunSignals = RunSignals(), isImport: Bool = false,
                 engine: GameEngine? = nil) -> RunOutcome {
        let engine = engine ?? self.engine
        let match = MapMatcher(area: Fixtures.area, rules: Fixtures.rules.matching).match(trace)
        let report = AntiCheat.evaluate(trace: trace, signals: signals, rules: Fixtures.rules.antiCheat, matching: Fixtures.rules.matching)
        return engine.resolve(run: RunContext(runID: UUID(), startedAt: trace.first!.timestamp, endedAt: trace.last!.timestamp, isImport: isImport),
                              trace: trace, match: match, report: report, state: &state)
    }

    @Test func firstRunEatsPelletsAndScores() {
        var state = GameState(areaSlug: "west-byfleet", playerID: "me")
        let (_, trace) = Fixtures.run(seed: 11)
        let out = resolve(trace, state: &state)
        #expect(out.verdict == .accepted)
        #expect(out.gained.count > 5)
        #expect(out.points > 0)
        #expect(state.points == out.totalPoints)
        let p = engine.progress(for: state.me, state: state, now: trace.last!.timestamp)
        #expect(p.heldSegments == out.gained.count)
        #expect(p.heldFraction > 0)
    }

    @Test func rerunningRefreshesWithoutPoints() {
        var state = GameState(areaSlug: "west-byfleet", playerID: "me")
        let (route, trace) = Fixtures.run(seed: 12)
        _ = resolve(trace, state: &state)
        let later = RouteSimulator(area: Fixtures.area).trace(along: route, start: Fixtures.t0.addingTimeInterval(86_400 * 5), seed: 99)
        let out = resolve(later, state: &state)
        #expect(out.gained.count <= 2)
        #expect(out.refreshed.count > 5)
    }

    @Test func runningARivalStreetFlipsIt() {
        var state = GameState(areaSlug: "west-byfleet", playerID: "me")
        let (_, trace) = Fixtures.run(seed: 13)
        let first = MapMatcher(area: Fixtures.area, rules: Fixtures.rules.matching).match(trace).coverage()
        for (i, _) in first { state.ownership[Fixtures.area.segments[i].id] = Ownership(owner: .ghost("bot-rook"), capturedAt: Fixtures.t0.addingTimeInterval(-3600), lastVisitedAt: Fixtures.t0.addingTimeInterval(-3600)) }
        state.ghosts = [GhostProfile(id: "bot-rook", name: "Bot Rook", colorHex: "FF6FA1", aggression: 0.5, segmentsPerDay: 5, cursorNode: 0)]
        let out = resolve(trace, state: &state)
        #expect(out.stolen.count > 5)
        #expect(out.stolen.allSatisfy { $0.previousOwner == .ghost("bot-rook") })
    }

    @Test func streetsDecayAfterTheConfiguredDays() {
        var state = GameState(areaSlug: "west-byfleet", playerID: "me")
        let (_, trace) = Fixtures.run(seed: 14)
        let out = resolve(trace, state: &state)
        #expect(!out.gained.isEmpty)
        let faded = engine.sweepDecay(state: &state, now: Fixtures.t0.addingTimeInterval(Fixtures.rules.decayInterval + 3600))
        #expect(faded == out.gained.count)
        #expect(state.ownership.isEmpty)
        // Personal exploration survives decay.
        #expect(!state.coverage.isEmpty)
    }

    @Test func importedRunsNeverTakeOwnership() {
        var state = GameState(areaSlug: "west-byfleet", playerID: "me")
        let (_, trace) = Fixtures.run(seed: 15)
        let out = resolve(trace, state: &state, isImport: true)
        #expect(out.gained.isEmpty)
        #expect(state.ownership.isEmpty)
        #expect(!state.coverage.isEmpty)
    }

    @Test func cyclingSpeedIsRejected() {
        var state = GameState(areaSlug: "west-byfleet", playerID: "me")
        let (_, trace) = Fixtures.run(seed: 16, distance: 4000, speed: 9.5) // ~34 km/h
        let out = resolve(trace, state: &state)
        #expect(out.gained.count <= 1)
        #expect(out.flags.contains { $0.rule == "speed" })
    }

    @Test func drivingMotionSendsRunToReview() {
        var state = GameState(areaSlug: "west-byfleet", playerID: "me")
        let (_, trace) = Fixtures.run(seed: 17)
        let signals = RunSignals(motion: [MotionSample(start: trace.first!.timestamp, end: trace.last!.timestamp, activity: .automotive, confidence: 2)])
        let out = resolve(trace, state: &state, signals: signals)
        #expect(out.verdict == .underReview)
        #expect(state.ownership.isEmpty)
    }

    @Test func powerPelletStartsFrenzyAndDoublesPoints() {
        let area = Fixtures.area
        let pellet = DailySpawns.powerPellets(area: area, date: Fixtures.t0, rules: Fixtures.rules)[0]
        let sim = RouteSimulator(area: area)
        let route = sim.route(from: pellet.landmark.coordinate, distance: 2000, seed: 21)
        // Start the run right on the landmark.
        let trace = [TracePoint(coordinate: pellet.landmark.coordinate, timestamp: Fixtures.t0, horizontalAccuracy: 5)]
            + sim.trace(along: route, start: Fixtures.t0.addingTimeInterval(5), seed: 22)
        var state = GameState(areaSlug: "west-byfleet", playerID: "me")
        let out = resolve(trace, state: &state)
        #expect(out.pelletsCollected == [pellet.id])
        #expect(out.gained.contains { $0.multiplier >= 2 })
    }

    @Test func dailySpawnsAreDeterministic() {
        let a = DailySpawns.powerPellets(area: Fixtures.area, date: Fixtures.t0, rules: Fixtures.rules).map(\.id)
        let b = DailySpawns.powerPellets(area: Fixtures.area, date: Fixtures.t0.addingTimeInterval(60), rules: Fixtures.rules).map(\.id)
        #expect(a == b)
        let withLandmarks = Fixtures.area.tiles.filter { !(Fixtures.area.landmarksByTile[$0] ?? []).isEmpty }.count
        #expect(a.count == withLandmarks * Fixtures.rules.powerPellets.perDay)
        let bonus = DailySpawns.bonusStreets(area: Fixtures.area, date: Fixtures.t0, rules: Fixtures.rules)
        #expect(bonus.count >= Fixtures.area.tiles.count - 2)
        #expect(bonus[0].label().contains("×"))
    }

    @Test func spawnsDependOnlyOnTheirOwnTile() {
        // A tile's pellets must not change when neighbouring tiles load or unload.
        let one = Area(tiles: Fixtures.tiles.filter { $0.key == Fixtures.centerTile.description })
        let mine = Set(DailySpawns.powerPellets(area: one, date: Fixtures.t0, rules: Fixtures.rules).map(\.id))
        let all = Set(DailySpawns.powerPellets(area: Fixtures.area, date: Fixtures.t0, rules: Fixtures.rules).map(\.id))
        #expect(mine.isSubset(of: all))
        let b1 = DailySpawns.bonusStreets(area: one, date: Fixtures.t0, rules: Fixtures.rules).map(\.id)
        let b9 = DailySpawns.bonusStreets(area: Fixtures.area, date: Fixtures.t0, rules: Fixtures.rules).map(\.id)
        #expect(Set(b1).isSubset(of: Set(b9)))
    }

    @Test func holdingAWholeTileConquersIt() throws {
        let area = Fixtures.area
        let tile = try #require(area.tiles.min { (area.segmentsByTile[$0]?.count ?? 0) < (area.segmentsByTile[$1]?.count ?? 0) })
        let segs = area.segments(in: tile)
        let last = try #require(segs.filter { $0.length > 40 && !$0.isPath }.max { $0.length < $1.length })
        var state = GameState(areaSlug: "world", playerID: "me")
        for s in segs where s.id != last.id {
            state.ownership[s.id] = Ownership(owner: state.me, capturedAt: Fixtures.t0, lastVisitedAt: Fixtures.t0)
        }
        let trace = RouteSimulator(area: area).trace(along: last.coordinates, start: Fixtures.t0.addingTimeInterval(60), speed: 2.5, noise: 1, seed: 5)
        var off = state
        let outOff = resolve(trace, state: &off)
        #expect(!outOff.conqueredTown && !off.badges.contains("conquered:\(tile)"), "capture areas are off by default")
        let out = resolve(trace, state: &state, engine: Self.areasOn)
        #expect(out.conqueredTown)
        #expect(state.badges.contains("conquered:\(tile)"))
    }

    @Test func laterCaptureWins() throws {
        let area = Fixtures.area
        let seg = try #require(area.segments.first { $0.length > 120 && !$0.isPath })
        var state = GameState(areaSlug: "world", playerID: "me")
        // A bot ran it an hour after our (imported) run.
        state.ownership[seg.id] = Ownership(owner: .ghost("bot-rook"), capturedAt: Fixtures.t0.addingTimeInterval(3600),
                                            lastVisitedAt: Fixtures.t0.addingTimeInterval(3600))
        let trace = RouteSimulator(area: area).trace(along: seg.coordinates, start: Fixtures.t0, speed: 2.5, noise: 1, seed: 6)
        let out = resolve(trace, state: &state)
        #expect(out.captures.first { $0.segmentID == seg.id }?.kind == .rejected)
        #expect(state.ownership[seg.id]?.owner == .ghost("bot-rook"))
    }

    @Test func completingABlockPaysABonus() throws {
        let area = Fixtures.area
        let block = try #require(area.blocks.first { $0.segmentIDs.count >= 3 && $0.segmentIDs.allSatisfy { area.segment($0) != nil } })
        var state = GameState(areaSlug: "west-byfleet", playerID: "me")
        // Own all but the longest side already.
        let last = block.segmentIDs.max { area.segment($0)!.length < area.segment($1)!.length }!
        for s in block.segmentIDs where s != last {
            state.ownership[s] = Ownership(owner: state.me, capturedAt: Fixtures.t0, lastVisitedAt: Fixtures.t0)
        }
        let seg = try #require(area.segment(last))
        let trace = RouteSimulator(area: area).trace(along: seg.coordinates, start: Fixtures.t0.addingTimeInterval(60), speed: 2.5, noise: 1, seed: 3)
        var off = state
        let outOff = resolve(trace, state: &off)
        #expect(outOff.blockBonus == 0 && outOff.blocksCompleted.isEmpty, "capture areas are off by default")
        #expect(engine.completedBlocks(for: off.me, state: off, now: trace.last!.timestamp).isEmpty)
        #expect(!outOff.gained.isEmpty, "the street itself still counts")
        let out = resolve(trace, state: &state, engine: Self.areasOn)
        #expect(out.blocksCompleted.contains(block.id))
        #expect(out.blockBonus >= Fixtures.rules.blocks.bonusBasePoints)
    }
}

@Suite("Bots")
struct GhostTests {
    @Test func botsStartWithTerritoryAndRaidOverTime() {
        let engine = GameEngine(area: Fixtures.area, rules: Fixtures.rules)
        let sim = GhostSimulator(engine: engine)
        var state = GameState(areaSlug: "west-byfleet", playerID: "me")
        sim.ensureGhosts(state: &state, playerColorHex: "C6FF00", now: Fixtures.t0)
        #expect(state.ghosts.count == Fixtures.rules.ghosts.perArea)
        #expect(state.ghosts.allSatisfy { $0.name.hasPrefix("Bot ") })
        let botHeld = state.ownership.values.filter { $0.owner.kind == .ghost }.count
        #expect(botHeld > 0)
        // Give the player some streets, then let a few days pass.
        for s in Fixtures.area.segments.prefix(300) where state.ownership[s.id] == nil {
            state.ownership[s.id] = Ownership(owner: state.me, capturedAt: Fixtures.t0, lastVisitedAt: Fixtures.t0)
        }
        sim.tick(state: &state, now: Fixtures.t0.addingTimeInterval(86_400 * 2))
        let afterHeld = state.ownership.values.filter { $0.owner.kind == .ghost }.count
        #expect(afterHeld > botHeld)
    }
}

@Suite("Privacy")
struct PrivacyTests {
    @Test func trimsRunsThatStartAndEndAtHome() {
        let (_, trace) = Fixtures.run(seed: 30)
        let home = PrivacyZone(name: "Home", center: trace.first!.coordinate, radius: 200)
        let work = PrivacyZone(name: "Work", center: trace.last!.coordinate, radius: 200)
        let trimmed = PrivacyTrimmer.trim(trace, zones: [home, work])
        #expect(trimmed.count < trace.count)
        #expect(!home.contains(trimmed.first!.coordinate))
        #expect(!work.contains(trimmed.last!.coordinate))
    }

    @Test func suggestsFrequentEndpoints() {
        let home = Coordinate(latitude: 51.34, longitude: -0.505)
        let pts = (0..<4).map { home.offset(metres: Double($0) * 20, bearingDegrees: 45) } + [Coordinate(latitude: 51.33, longitude: -0.52)]
        let s = PrivacyTrimmer.suggestions(endpoints: pts, existing: [], radius: 250)
        #expect(s.count == 1)
        #expect(s[0].distance(to: home) < 60)
    }
}

@Suite("Splits")
struct SplitTests {
    @Test func splitsAddUpToTheDistance() {
        let (_, trace) = Fixtures.run(seed: 40, distance: 3200)
        let splits = RunMath.splits(trace)
        let total = RunMath.distance(trace)
        #expect(splits.count >= 3)
        #expect(abs(splits.reduce(0) { $0 + $1.distance } - total) < 60)
    }
}

/// Writes shared/fixtures/parity.json: what ChompKit decides for fixed inputs.
/// backend/supabase/tests/parity.test.ts checks the server's TypeScript port
/// reaches the same answers, so client-side provisional results match the server.
@Suite("Server parity fixture")
struct ParityFixture {
    /// iCloud-synced folders can refuse an in-place overwrite (EDEADLK), so replace the file instead.
    func write(_ data: Data, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        try data.write(to: url)
    }

    @Test func writeFixture() throws {
        let area = Fixtures.area, rules = Fixtures.rules
        var out: [String: Any] = [:]

        var rng = SeededRandom(string: "chomp")
        out["rng"] = (0..<5).map { _ in String(rng.next()) }

        let dates: [Double] = [Fixtures.t0.timeIntervalSince1970, 1_774_778_400 /* 2026-03-29 10:00Z, spring forward */,
                               1_792_918_800 /* 2026-10-25 09:00Z, clocks back */, 1_798_761_000 /* 2026-12-31 23:50Z, New Year's Eve */]
        out["spawns"] = dates.map { t -> [String: Any] in
            let d = Date(timeIntervalSince1970: t)
            return [
                "t": t,
                "pellets": DailySpawns.powerPellets(area: area, date: d, rules: rules).map {
                    ["id": $0.id, "from": $0.activeFrom.timeIntervalSince1970, "until": $0.activeUntil.timeIntervalSince1970]
                },
                "bonus": DailySpawns.bonusStreets(area: area, date: d, rules: rules).map {
                    ["street": $0.streetName, "mult": $0.multiplier, "starts": $0.startsAt.timeIntervalSince1970,
                     "ends": $0.endsAt.timeIntervalSince1970, "segments": $0.segmentIDs.count] as [String: Any]
                },
            ]
        }

        func encode(_ trace: [TracePoint]) -> [[Double]] {
            trace.map { [$0.coordinate.latitude, $0.coordinate.longitude, $0.timestamp.timeIntervalSince1970, $0.horizontalAccuracy, $0.speed] }
        }
        let matcher = MapMatcher(area: area, rules: rules.matching)
        var runs: [[String: Any]] = []
        for (seed, speed) in [(1, 3.0), (2, 3.2), (3, 2.8), (4, 7.5)] as [(UInt64, Double)] {
            let trace = Fixtures.run(seed: seed, distance: 3000, speed: speed).trace
            let match = matcher.match(trace)
            let report = AntiCheat.evaluate(trace: trace, signals: RunSignals(), rules: rules.antiCheat, matching: rules.matching)
            var state = GameState(areaSlug: area.slug, playerID: "p1")
            let engine = GameEngine(area: area, rules: rules)
            let outcome = engine.resolve(run: RunContext(runID: UUID(), startedAt: trace.first!.timestamp, endedAt: trace.last!.timestamp),
                                         trace: trace, match: match, report: report, state: &state)
            var coverage: [String: Double] = [:]
            for (seg, set) in match.coverage() { coverage[area.segments[seg].id] = set.coveredLength }
            runs.append([
                "seed": seed, "trace": encode(trace),
                "chunks": match.chunks, "used": match.usedPoints, "unmatched": match.unmatchedPoints, "coverage": coverage,
                "verdict": report.verdict.rawValue, "flags": report.flags.map(\.rule), "excluded": report.excluded.count,
                "captures": Dictionary(uniqueKeysWithValues: outcome.captures.map { ($0.segmentID, $0.kind.rawValue) }),
                "points": outcome.points, "blockBonus": outcome.blockBonus, "pellets": outcome.pelletsCollected,
            ])
        }
        out["runs"] = runs

        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("shared/fixtures")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try write(JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]), to: dir.appendingPathComponent("parity.json"))
        // The tiles themselves: the server's StreetBuilder port must produce exactly these.
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        try write(enc.encode(Fixtures.tiles), to: dir.appendingPathComponent("tiles-west-byfleet.json"))
    }
}

/// The app must be able to decode resolve-run's response. The JSON is written by
/// backend/tests/resolve.test.ts from the server's real code path.
@Suite("Server response")
struct ServerResponseDecoding {
    @Test func decodesResolveRunOutcome() throws {
        struct Response: Decodable { let status: String; let outcome: RunOutcome? }
        let url = try #require(Bundle(for: TestBundle.self).url(forResource: "server-response", withExtension: "json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let res = try decoder.decode(Response.self, from: Data(contentsOf: url))
        let o = try #require(res.outcome)
        #expect(res.status == "resolved")
        #expect(o.verdict == .accepted)
        #expect(!o.gained.isEmpty)
        #expect(o.frenzyWindows.first?.duration == 600)
        #expect(o.stolen.first?.previousOwner == .ghost("bot-dusk"))
        #expect(o.rejected.first?.reason == "Too fast to be running")
        #expect(o.flags.contains { $0.severity == .medium })
    }
}


@Suite("Routes, goals and tokens")
struct RoutesGoalsTokens {
    @Test func plannedRouteIsALoopNearTheTargetDistance() throws {
        let area = Fixtures.area
        let planner = RoutePlanner(area: area)
        let start = Coordinate(latitude: 51.3392, longitude: -0.5063)
        let wanted = Set(area.segments.filter { !$0.isPath }.map(\.index))
        let r = try #require(planner.plan(from: start, distance: 4000, seed: 7,
                                          value: { wanted.contains($0) ? 1 : 0 }, tokens: { _ in 1 }))
        #expect(r.distance > 2800 && r.distance < 5600, "distance \(r.distance)")
        let a = try #require(r.coordinates.first), b = try #require(r.coordinates.last)
        #expect(a.distance(to: b) < 1, "a loop ends where it starts")
        #expect(r.targets > 0)
        // Consecutive segments must share a junction.
        for (x, y) in zip(r.segments, r.segments.dropFirst()) {
            let a = area.segments[x], b = area.segments[y]
            #expect(!Set([a.startNode, a.endNode]).isDisjoint(with: [b.startNode, b.endNode]))
        }
    }

    @Test func streakCountsConsecutiveDays() {
        let cal = Goals.calendar
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 18))!
        func day(_ back: Int) -> RunFacts {
            RunFacts(date: cal.date(byAdding: .day, value: -back, to: now)!, distance: 3000, streets: 4, stolen: 1, tokens: 40, pellets: 0, blocks: 0)
        }
        let s = Goals.streak(runs: [day(1), day(2), day(3), day(6), day(7)], now: now)
        #expect(s.current == 3 && !s.ranToday && s.atRisk)
        #expect(s.best == 3)
        #expect(Goals.streak(runs: [day(0), day(1)], now: now).current == 2)
        #expect(Goals.streak(runs: [day(2)], now: now).current == 0)
    }

    @Test func weeklyGoalsAreStableAndCountThisWeekOnly() {
        let cal = Goals.calendar
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 18))!  // a Thursday
        let thisWeek = RunFacts(date: now.addingTimeInterval(-3600), distance: 5200, streets: 9, stolen: 2, tokens: 210, pellets: 1, blocks: 1)
        let lastWeek = RunFacts(date: now.addingTimeInterval(-8 * 86_400), distance: 9000, streets: 30, stolen: 9, tokens: 900, pellets: 2, blocks: 2)
        let g = Goals.weekly(runs: [thisWeek, lastWeek], now: now)
        #expect(g.count == 3 && Set(g.map(\.kind)).count == 3)
        #expect(g == Goals.weekly(runs: [thisWeek, lastWeek], now: now))
        for goal in g {
            switch goal.kind {
            case .streets: #expect(goal.progress == 9)
            case .tokens: #expect(goal.progress == 210)
            case .days: #expect(goal.progress == 1)
            case .distance: #expect(goal.progress == 5)
            case .steal: #expect(goal.progress == 2)
            case .pellets, .blocks: #expect(goal.progress == 1)
            }
        }
    }

    @Test func capturingAStreetEarnsItsTokens() {
        let engine = GameEngine(area: Fixtures.area, rules: Fixtures.rules)
        #expect(Fixtures.rules.tokens(forLength: 4) == 1)
        #expect(Fixtures.rules.tokens(forLength: 104) == 10)
        var state = GameState(areaSlug: "world", playerID: "p1")
        let seg = Fixtures.area.segments.first { !$0.isPath && $0.length > 120 }!
        let t = Fixtures.t0
        let pts = stride(from: 0.0, through: 1.0, by: 0.02).map { f -> TracePoint in
            let c = seg.polyline.point(at: seg.length * f)
            return TracePoint(coordinate: Fixtures.area.projection.unproject(c), timestamp: t.addingTimeInterval(f * seg.length / 3),
                              horizontalAccuracy: 5, speed: 3)
        }
        let match = MapMatcher(area: Fixtures.area, rules: Fixtures.rules.matching).match(pts)
        let report = AntiCheat.evaluate(trace: pts, signals: RunSignals(), rules: Fixtures.rules.antiCheat, matching: Fixtures.rules.matching)
        let out = engine.resolve(run: RunContext(runID: UUID(), startedAt: t, endedAt: pts.last!.timestamp, isImport: false),
                                 trace: pts, match: match, report: report, state: &state)
        let expected = out.gained.compactMap { Fixtures.area.segment($0.segmentID) }.reduce(0) { $0 + Fixtures.rules.tokens(forLength: $1.length) }
        #expect(expected > 0)
        #expect(state.tokens(of: state.me) == expected)
    }
}

@Suite("Routes, goals and tokens: edge cases")
struct RoutesGoalsEdgeCases {
    let cal = Goals.calendar
    func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }
    func run(_ date: Date, streets: Int = 1) -> RunFacts {
        RunFacts(date: date, distance: 1000, streets: streets, stolen: 0, tokens: 10, pellets: 0, blocks: 0)
    }

    @Test func plannerRefusesNoStreetsNearbyAndTinyDistances() {
        let p = RoutePlanner(area: Fixtures.area)
        let farAway = Coordinate(latitude: 52.2, longitude: 0.12)  // Cambridge: no streets loaded there
        #expect(p.plan(from: farAway, distance: 4000, seed: 1, value: { _ in 1 }, tokens: { _ in 1 }) == nil)
        #expect(p.plan(from: Fixtures.area.center, distance: 150, seed: 1, value: { _ in 1 }, tokens: { _ in 1 }) == nil)
    }

    @Test func plannerStillMakesALoopWhenNothingIsWanted() throws {
        let p = RoutePlanner(area: Fixtures.area)
        let r = try #require(p.plan(from: Fixtures.area.center, distance: 3000, seed: 2, value: { _ in 0 }, tokens: { _ in 1 }))
        #expect(r.targets == 0 && r.tokens == 0)
        #expect(r.coordinates.first!.distance(to: r.coordinates.last!) < 1)
    }

    @Test func plannerIsDeterministicPerSeedAndVariesAcrossSeeds() throws {
        let p = RoutePlanner(area: Fixtures.area)
        let a = try #require(p.plan(from: Fixtures.area.center, distance: 5000, seed: 11, value: { _ in 1 }, tokens: { _ in 1 }))
        let b = try #require(p.plan(from: Fixtures.area.center, distance: 5000, seed: 11, value: { _ in 1 }, tokens: { _ in 1 }))
        #expect(a == b)
        let others = (12...16).compactMap { p.plan(from: Fixtures.area.center, distance: 5000, seed: UInt64($0), value: { _ in 1 }, tokens: { _ in 1 }) }
        #expect(others.contains { $0.segments != a.segments }, "\"Try another\" must give a different loop")
    }

    @Test(arguments: [2000.0, 5000.0, 10000.0])
    func plannerHitsTheDistanceAcrossSizes(target: Double) throws {
        let p = RoutePlanner(area: Fixtures.area)
        let r = try #require(p.plan(from: Fixtures.area.center, distance: target, seed: 5, value: { _ in 1 }, tokens: { _ in 1 }))
        #expect(abs(r.distance - target) / target < 0.4, "asked \(target), got \(r.distance)")
    }

    @Test func goalsWeekStartsMondayMidnightUKTime() {
        let monday = at(2026, 11, 16, 0, 0)
        #expect(Goals.weekStart(at(2026, 11, 19)) == monday)
        let sundayLate = run(at(2026, 11, 15, 23, 59), streets: 50)
        let mondayEarly = run(at(2026, 11, 16, 0, 1), streets: 3)
        let g = Goals.weekly(runs: [sundayLate, mondayEarly], now: at(2026, 11, 19))
        if let s = g.first(where: { $0.kind == .streets }) { #expect(s.progress == 3) }
        if let d = g.first(where: { $0.kind == .days }) { #expect(d.progress == 1) }
    }

    @Test func goalsChangeFromWeekToWeek() {
        let weeks = (0..<8).map { Goals.weekly(runs: [], now: at(2026, 11, 2).addingTimeInterval(Double($0) * 7 * 86_400)).map(\.title) }
        #expect(Set(weeks.map { $0.joined(separator: "|") }).count > 1)
        #expect(weeks.allSatisfy { $0.count == 3 })
    }

    @Test func futureRunsDontCount() {
        let now = at(2026, 11, 19)
        let g = Goals.weekly(runs: [run(now.addingTimeInterval(3600), streets: 99)], now: now)
        #expect(g.allSatisfy { $0.progress == 0 })
    }

    @Test func streakSurvivesTheClocksGoingBack() {
        // BST ended at 02:00 on 25 October 2026.
        let s = Goals.streak(runs: [run(at(2026, 10, 24, 7)), run(at(2026, 10, 25, 7)), run(at(2026, 10, 26, 7))], now: at(2026, 10, 26, 20))
        #expect(s.current == 3 && s.ranToday && !s.atRisk)
    }

    @Test func streakIgnoresSeveralRunsOnOneDayAndKeepsTheBest() {
        let now = at(2026, 11, 19, 20)
        let runs = [run(at(2026, 11, 19, 7)), run(at(2026, 11, 19, 18)),
                    run(at(2026, 11, 1)), run(at(2026, 11, 2)), run(at(2026, 11, 3)), run(at(2026, 11, 4))]
        let s = Goals.streak(runs: runs, now: now)
        #expect(s.current == 1 && s.best == 4)
        #expect(Goals.streak(runs: [], now: now) == Goals.Streak(current: 0, best: 0, ranToday: false))
    }

    @Test func tokensRoundToTheNearestTenMetresWithAMinimumOfOne() {
        let r = Fixtures.rules
        #expect(r.tokens(forLength: 0) == 1)
        #expect(r.tokens(forLength: 14.9) == 1)
        #expect(r.tokens(forLength: 15) == 2)
        #expect(r.tokens(forLength: 1000) == 100)
    }
}

@Suite("Route planner robustness")
struct RoutePlannerRobustness {
    @Test func plansFromAnywhereWithStreets() {
        let area = Fixtures.area
        let p = RoutePlanner(area: area)
        var rng = SeededRandom(seed: 99)
        var failures: [String] = []
        for _ in 0..<40 {
            let seg = area.segments[rng.int(area.segments.count)]
            // Somewhere near a street, not exactly on it.
            let start = Coordinate(latitude: seg.midpoint.latitude + (rng.unit() - 0.5) * 0.001,
                                   longitude: seg.midpoint.longitude + (rng.unit() - 0.5) * 0.0015)
            if p.plan(from: start, distance: 5000, seed: 1, attempts: 1, value: { _ in 1 }, tokens: { _ in 1 }) == nil {
                failures.append("\(seg.displayName) \(seg.isPath ? "path" : "road")")
            }
        }
        #expect(failures.isEmpty, "no loop from: \(failures)")
    }
}
