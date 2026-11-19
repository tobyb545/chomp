import Foundation
import Testing
@testable import ChompKit

final class TestBundle {}

enum Fixtures {
    static let area: Area = {
        let url = Bundle(for: TestBundle.self).url(forResource: "west-byfleet", withExtension: "json")!
        return try! Area.load(from: url)
    }()
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
    @Test func loadsWestByfleet() {
        let a = Fixtures.area
        #expect(a.segments.count > 1500)
        #expect(a.totalLength > 100_000)
        #expect(!a.blocks.isEmpty)
        #expect(!a.landmarks.isEmpty)
        #expect(Set(a.segments.map(\.id)).count == a.segments.count, "segment IDs must be unique")
        #expect(a.contains(a.center))
    }

    @Test func blocksReferenceRealSegments() {
        for b in Fixtures.area.blocks {
            for s in b.segmentIDs { #expect(Fixtures.area.segment(s) != nil) }
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

    func resolve(_ trace: [TracePoint], state: inout GameState, signals: RunSignals = RunSignals(), isImport: Bool = false) -> RunOutcome {
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
        #expect(a.count == min(Fixtures.rules.powerPellets.perDay, Fixtures.area.landmarks.count))
        let bonus = DailySpawns.bonusStreets(area: Fixtures.area, date: Fixtures.t0, rules: Fixtures.rules)
        #expect(bonus.count == Fixtures.rules.bonusStreets.perDay)
        #expect(bonus[0].label().contains("×"))
    }

    @Test func completingABlockPaysABonus() throws {
        let area = Fixtures.area
        let block = try #require(area.blocks.first { $0.segmentIDs.count >= 3 })
        var state = GameState(areaSlug: "west-byfleet", playerID: "me")
        // Own all but one side already.
        let last = block.segmentIDs.last!
        for s in block.segmentIDs.dropLast() {
            state.ownership[s] = Ownership(owner: state.me, capturedAt: Fixtures.t0, lastVisitedAt: Fixtures.t0)
        }
        let seg = try #require(area.segment(last))
        let trace = RouteSimulator(area: area).trace(along: seg.coordinates, start: Fixtures.t0.addingTimeInterval(60), speed: 2.5, noise: 1, seed: 3)
        let out = resolve(trace, state: &state)
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

        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("shared/fixtures/parity.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]).write(to: url)
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
