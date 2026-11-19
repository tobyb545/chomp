import Foundation

public enum CaptureKind: String, Codable, Sendable {
    /// Ate the pellets on a neutral street.
    case captured
    /// Flipped a rival's (or bot's) street.
    case stolen
    /// Re-ran a street you already own; decay timer reset.
    case refreshed
    /// Covered enough, but rejected (speed, review, rate limit, import).
    case rejected
    /// Ran part of it, not enough to count.
    case partial
}

public struct CaptureRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: SegmentID { segmentID }
    public var segmentID: SegmentID
    public var streetName: String
    public var kind: CaptureKind
    public var coverage: Double
    public var points: Int
    public var multiplier: Double
    public var previousOwner: OwnerRef?
    public var at: Date
    public var reason: String?
    /// Coins taken on this street (nil in runs saved before coins).
    public var tokens: Int? = nil
    /// Indexes of the coins taken, for the replay and live map.
    public var coins: [Int]? = nil
}

public struct RunContext: Sendable {
    public var runID: UUID
    public var startedAt: Date
    public var endedAt: Date
    /// Old imported history: counts for personal exploration only, never ownership.
    public var isImport: Bool

    public init(runID: UUID, startedAt: Date, endedAt: Date, isImport: Bool = false) {
        self.runID = runID; self.startedAt = startedAt; self.endedAt = endedAt; self.isImport = isImport
    }
}

public struct RunOutcome: Codable, Hashable, Sendable {
    public var runID: UUID
    public var captures: [CaptureRecord]
    public var points: Int
    public var blockBonus: Int
    public var blocksCompleted: [BlockID]
    public var pelletsCollected: [String]
    public var frenzyWindows: [DateInterval]
    public var verdict: RunVerdict
    public var flags: [AntiCheatFlag]
    public var conqueredTown: Bool

    public var gained: [CaptureRecord] { captures.filter { $0.kind == .captured || $0.kind == .stolen } }
    public var stolen: [CaptureRecord] { captures.filter { $0.kind == .stolen } }
    public var refreshed: [CaptureRecord] { captures.filter { $0.kind == .refreshed } }
    public var rejected: [CaptureRecord] { captures.filter { $0.kind == .rejected } }
    public var totalPoints: Int { points + blockBonus }
    /// Coins collected (new and stolen). 0 for runs saved before coins.
    public var coins: Int { gained.reduce(0) { $0 + ($1.tokens ?? 0) } }
    /// Coins taken from rivals.
    public var coinsStolen: Int { stolen.reduce(0) { $0 + ($1.tokens ?? 0) } }
    /// Coins you already held and ran past again (kept fresh).
    public var coinsKept: Int { refreshed.reduce(0) { $0 + ($1.tokens ?? $1.coins?.count ?? 0) } }
}

/// "1 coin", "12 coins".
public func coinCount(_ n: Int) -> String { "\(n.formatted()) coin\(n == 1 ? "" : "s")" }

/// Pure game rules. Given state + a matched, anti-cheat-checked run, decides
/// every capture. The server's resolve-run function implements the same rules.
public struct GameEngine: Sendable {
    public let area: Area
    public let rules: RulesConfig

    public init(area: Area, rules: RulesConfig) {
        self.area = area
        self.rules = rules
    }

    // MARK: Run resolution

    public func resolve(run: RunContext, trace: [TracePoint], match: MatchResult, report: AntiCheatReport,
                        state: inout GameState) -> RunOutcome {
        let me = state.me
        let threshold = rules.capture.coverageThreshold
        let pieces = match.pieces.filter { !report.isExcluded($0) }
        let excludedPieces = match.pieces.filter { report.isExcluded($0) }

        // Power pellets collected → frenzy windows.
        var pellets: [String] = []
        var frenzy: [DateInterval] = []
        if !run.isImport && report.verdict == .accepted {
            var day = DailySpawns.townCalendar.startOfDay(for: run.startedAt)
            var spawns: [PowerPellet] = []
            while day <= run.endedAt {
                spawns += DailySpawns.powerPellets(area: area, date: day, rules: rules)
                day = DailySpawns.townCalendar.date(byAdding: .day, value: 1, to: day)!
            }
            for pellet in spawns where state.collectedPellets[pellet.id] == nil {
                if let hit = trace.first(where: {
                    $0.timestamp >= pellet.activeFrom && $0.timestamp < pellet.activeUntil &&
                        $0.horizontalAccuracy <= rules.matching.maxAccuracyMetres &&
                        $0.coordinate.distance(to: pellet.landmark.coordinate) <= rules.frenzy.collectRadiusMetres
                }) {
                    pellets.append(pellet.id)
                    state.collectedPellets[pellet.id] = hit.timestamp
                    frenzy.append(DateInterval(start: hit.timestamp, duration: rules.frenzy.durationSeconds))
                    state.log(GameEvent(date: hit.timestamp, kind: .powerPellet, actor: me,
                                        message: "Power pellet at \(pellet.landmark.name)! Frenzy for \(Int(rules.frenzy.durationSeconds / 60)) minutes."))
                }
            }
            frenzy = AntiCheat.merge(frenzy)
        }
        func inFrenzy(_ d: Date) -> Bool { frenzy.contains { $0.contains(d) } }

        let bonuses = DailySpawns.bonusStreets(area: area, date: run.startedAt, rules: rules)
            + (DailySpawns.townCalendar.isDate(run.startedAt, inSameDayAs: run.endedAt) ? [] :
                DailySpawns.bonusStreets(area: area, date: run.endedAt, rules: rules))
        func bonusMultiplier(_ seg: SegmentID, _ d: Date) -> Double {
            bonuses.filter { $0.segmentIDs.contains(seg) && $0.isActive(at: d) }.map(\.multiplier).max() ?? 1
        }

        // Coverage per segment, and when each threshold was crossed.
        struct Progress { var set = IntervalSet(); var crossed: Date?; var frenzyCrossed: Date?; var last: Date = .distantPast; var pieces: [CoveragePiece] = [] }
        var segProgress: [Int: Progress] = [:]
        for p in pieces.sorted(by: { $0.end < $1.end }) {
            var pr = segProgress[p.segment] ?? Progress()
            pr.set.insert(p.from...p.to)
            pr.pieces.append(p)
            pr.last = max(pr.last, p.end)
            let len = area.segments[p.segment].length
            let ratio = len > 0 ? pr.set.coveredLength / len : 0
            if pr.crossed == nil, ratio >= threshold { pr.crossed = p.end }
            if pr.frenzyCrossed == nil, ratio >= rules.capture.frenzyRivalCoverageThreshold, inFrenzy(p.end) {
                pr.frenzyCrossed = p.end
            }
            segProgress[p.segment] = pr
        }

        let dayKey = DailySpawns.dayKey(run.endedAt, calendar: DailySpawns.townCalendar)
        var capturesToday = state.capturesByDay[dayKey, default: 0]
        var capturesThisRun = 0
        var records: [CaptureRecord] = []
        var points = 0
        let completeBefore = Set(completedBlocks(for: me, state: state, now: run.startedAt))

        // Coins the run passed on each street, and when (earliest piece that reached it).
        struct Hit { let index: Int; let at: Date }
        let reach = rules.coinReach
        var segHits: [Int: [Hit]] = [:]
        for (segIndex, pr) in segProgress {
            let seg = area.segments[segIndex]
            let n = rules.coinCount(seg)
            var hits: [Hit] = []
            for i in 0..<n {
                let o = Coins.offset(i, of: n, length: seg.length)
                if let p = pr.pieces.first(where: { min($0.from, $0.to) - reach <= o && o <= max($0.from, $0.to) + reach }) {
                    hits.append(Hit(index: i, at: p.end))
                }
            }
            segHits[segIndex] = hits.sorted { ($0.at, $0.index) < ($1.at, $1.index) }
        }
        let ordered = segProgress.sorted { a, b in
            ((segHits[a.key]?.first?.at ?? a.value.last), a.key) < ((segHits[b.key]?.first?.at ?? b.value.last), b.key)
        }
        for (segIndex, pr) in ordered {
            let seg = area.segments[segIndex]
            let ratio = min(1, seg.length > 0 ? pr.set.coveredLength / seg.length : 0)
            let hits = segHits[segIndex] ?? []
            let ids = rules.coinIDs(seg)
            func liveOwner(_ i: Int, _ t: Date) -> Ownership? {
                state.ownership[ids[i]].flatMap { $0.strength(at: t, decay: rules.decayInterval) > 0 ? $0 : nil }
            }
            let previous = hits.compactMap { h in liveOwner(h.index, h.at).flatMap { $0.owner != me ? $0.owner : nil } }.first
            let firstAt = hits.first?.at ?? pr.last

            // Exploration still means running most of a street.
            if let crossed = pr.crossed {
                var cov = state.coverage[seg.id] ?? PersonalCoverage(firstRunAt: crossed, lastRunAt: crossed, timesRun: 0, importedOnly: run.isImport)
                cov.firstRunAt = min(cov.firstRunAt, crossed)
                cov.lastRunAt = max(cov.lastRunAt, crossed)
                cov.timesRun += 1
                cov.importedOnly = cov.importedOnly && run.isImport
                state.coverage[seg.id] = cov
            }

            func record(_ kind: CaptureKind, at: Date, pts: Int = 0, mult: Double = 1, reason: String? = nil, taken: [Int]? = nil) {
                records.append(CaptureRecord(segmentID: seg.id, streetName: seg.displayName, kind: kind, coverage: ratio,
                                             points: pts, multiplier: mult, previousOwner: previous, at: at, reason: reason,
                                             tokens: taken?.count, coins: taken))
            }

            guard !hits.isEmpty else { record(.partial, at: pr.last); continue }
            if run.isImport { record(.rejected, at: firstAt, reason: "Imported runs count for exploration only"); continue }
            if report.verdict == .underReview { record(.rejected, at: firstAt, reason: "Run is under review"); continue }
            let wouldGain = hits.contains { liveOwner($0.index, $0.at)?.owner != me }
            if wouldGain, capturesThisRun >= rules.antiCheat.maxCapturesPerRun || capturesToday >= rules.antiCheat.maxCapturesPerDay {
                record(.rejected, at: firstAt, reason: "Daily capture limit reached")
                continue
            }

            let spacing = seg.length / Double(ids.count)
            var taken: [Int] = []
            var takenAt: Date?
            var stole = false, refreshed = false, blocked = false
            var pts = 0.0, maxMult = 1.0
            for h in hits {
                let current = liveOwner(h.index, h.at)
                if let c = current, c.owner == me {
                    state.ownership[ids[h.index]]?.lastVisitedAt = max(c.lastVisitedAt, h.at)
                    refreshed = true
                    continue
                }
                // Later capture wins: a run added after the fact can't take back
                // coins someone else ran more recently.
                if let c = current, c.capturedAt > h.at { blocked = true; continue }
                let mult = (inFrenzy(h.at) ? rules.frenzy.multiplier : 1) * bonusMultiplier(seg.id, h.at)
                maxMult = max(maxMult, mult)
                pts += spacing * rules.capture.pointsPerMetre * mult
                if current != nil { stole = true }
                state.ownership[ids[h.index]] = Ownership(owner: me, capturedAt: h.at, lastVisitedAt: h.at)
                taken.append(h.index)
                takenAt = takenAt ?? h.at
            }
            if !taken.isEmpty {
                let p = max(rules.capture.minimumPointsPerSegment, Int(pts.rounded()))
                state.addTokens(taken.count, to: me)
                capturesThisRun += 1
                capturesToday += 1
                points += p
                record(stole ? .stolen : .captured, at: takenAt!, pts: p, mult: maxMult, taken: taken)
            } else if refreshed {
                record(.refreshed, at: firstAt)
            } else if blocked {
                record(.rejected, at: firstAt, reason: "Someone ran it more recently")
            } else {
                record(.partial, at: firstAt)
            }
        }
        for p in excludedPieces where segProgress[p.segment] == nil && !records.contains(where: { $0.segmentID == area.segments[p.segment].id }) {
            let seg = area.segments[p.segment]
            let ratio = min(1, (MatchResult.coverage(of: excludedPieces.filter { $0.segment == p.segment })[p.segment]?.coveredLength ?? 0) / max(seg.length, 1))
            if ratio >= threshold {
                records.append(CaptureRecord(segmentID: seg.id, streetName: seg.displayName, kind: .rejected, coverage: ratio, points: 0,
                                             multiplier: 1, previousOwner: state.ownership[seg.id]?.owner, at: p.end,
                                             reason: "Too fast to be running"))
            }
        }
        state.capturesByDay[dayKey] = capturesToday

        // Blocks.
        var blockBonus = 0
        var newBlocks: [BlockID] = []
        let completeAfter = completedBlocks(for: me, state: state, now: run.endedAt)
        for b in completeAfter where !completeBefore.contains(b) {
            guard let block = area.blockByID[b] else { continue }
            if let last = state.blockAwards[b], run.endedAt.timeIntervalSince(last) < rules.blocks.reawardCooldownHours * 3600 { continue }
            let bonus = rules.blocks.bonusBasePoints + Int(block.areaM2 / 100 * rules.blocks.bonusPointsPerHundredSquareMetres)
            blockBonus += bonus
            newBlocks.append(b)
            state.blockAwards[b] = run.endedAt
        }
        state.points += points + blockBonus

        // Events.
        let gained = records.filter { $0.kind == .captured }
        if !gained.isEmpty {
            state.log(GameEvent(date: run.endedAt, kind: .captured, actor: me, segmentIDs: gained.map(\.segmentID),
                                points: gained.reduce(0) { $0 + $1.points },
                                message: "You collected \(coinCount(gained.reduce(0) { $0 + ($1.tokens ?? 0) }))"))
        }
        let stolen = records.filter { $0.kind == .stolen }
        for (owner, recs) in Dictionary(grouping: stolen, by: { $0.previousOwner }) {
            let who = owner.map { ownerName($0, state: state) } ?? "a rival"
            state.log(GameEvent(date: run.endedAt, kind: .stolen, actor: me, segmentIDs: recs.map(\.segmentID),
                                points: recs.reduce(0) { $0 + $1.points },
                                message: "You stole \(coinCount(recs.reduce(0) { $0 + ($1.tokens ?? 0) })) from \(who)"))
        }
        if !newBlocks.isEmpty {
            state.log(GameEvent(date: run.endedAt, kind: .blockCompleted, actor: me, points: blockBonus,
                                message: "Block\(newBlocks.count == 1 ? "" : "s") filled: +\(blockBonus) bonus"))
        }
        let rejected = records.filter { $0.kind == .rejected && $0.reason != "Imported runs count for exploration only" }
        if !rejected.isEmpty {
            state.log(GameEvent(date: run.endedAt, kind: .runRejected, actor: me, segmentIDs: rejected.map(\.segmentID),
                                message: "Some of this run didn't count: \(rejected[0].reason ?? "")"))
        }

        // Conquering: hold (practically) every street in a map tile.
        var conquered = false
        let touchedTiles = Set(records.filter { $0.kind == .captured || $0.kind == .stolen }.compactMap { area.segmentIndex($0.segmentID).map { area.segmentTile[$0] } })
        for tile in touchedTiles.sorted() where rules.blocks.isEnabled {
            let badge = "conquered:\(tile)"
            if !state.badges.contains(badge), tileHeldFraction(tile, owner: me, state: state, now: run.endedAt) >= 0.999 {
                state.badges.append(badge)
                conquered = true
                state.log(GameEvent(date: run.endedAt, kind: .townConquered, actor: me, message: "You conquered a whole map square!"))
            }
        }
        return RunOutcome(runID: run.runID, captures: records, points: points, blockBonus: blockBonus, blocksCompleted: newBlocks,
                          pelletsCollected: pellets, frenzyWindows: frenzy, verdict: report.verdict, flags: report.flags,
                          conqueredTown: conquered)
    }

    // MARK: Decay

    /// Neutralises faded coins. Returns how many of the player's streets lost coins.
    @discardableResult
    public func sweepDecay(state: inout GameState, now: Date) -> Int {
        var faded = Set<SegmentID>()
        var coins = 0
        for (id, o) in state.ownership where o.strength(at: now, decay: rules.decayInterval) <= 0 {
            state.ownership[id] = nil
            if o.owner == state.me { faded.insert(Coins.segment(of: id)); coins += 1 }
        }
        state.lastDecaySweep = now
        if !faded.isEmpty {
            state.log(GameEvent(date: now, kind: .decayed, actor: nil, segmentIDs: faded.sorted(),
                                message: "\(coinCount(coins)) of yours faded back to silver"))
        }
        return faded.count
    }

    // MARK: Queries

    public func isLive(_ o: Ownership?, now: Date) -> Bool {
        guard let o else { return false }
        return o.strength(at: now, decay: rules.decayInterval) > 0
    }

    /// Blocks where `owner` holds every coin on every side.
    public func completedBlocks(for owner: OwnerRef, state: GameState, now: Date) -> [BlockID] {
        guard rules.blocks.isEnabled else { return [] }
        return area.blocks.filter { b in
            b.segmentIDs.allSatisfy { id in
                guard let s = area.segment(id) else { return false }
                let c = coinsHeld(s, by: owner, state: state, now: now)
                return c.held == c.total
            }
        }.map(\.id)
    }

    /// Coins held out of all the coins on the map. (Streets count once you hold
    /// at least one coin on them; distance is weighted by the share of coins held.)
    public func progress(for owner: OwnerRef, state: GameState, now: Date) -> TownProgress {
        var held = 0
        var metres = 0.0
        var coins = 0, total = 0
        for s in area.segments {
            let c = coinsHeld(s, by: owner, state: state, now: now)
            coins += c.held; total += c.total
            guard c.held > 0 else { continue }
            held += 1
            metres += s.length * Double(c.held) / Double(c.total)
        }
        let explored = owner == state.me
            ? state.coverage.keys.reduce(0.0) { $0 + (area.segment($1)?.length ?? 0) }
            : metres
        return TownProgress(heldSegments: held, heldMetres: metres,
                            heldFraction: total > 0 ? Double(coins) / Double(total) : 0,
                            exploredFraction: area.totalLength > 0 ? explored / area.totalLength : 0,
                            blocksHeld: completedBlocks(for: owner, state: state, now: now).count,
                            totalSegments: area.segments.count, coinsHeld: coins, coinsTotal: total)
    }

    /// Share of a tile's street length the owner holds (by coins).
    public func tileHeldFraction(_ tile: TileKey, owner: OwnerRef, state: GameState, now: Date) -> Double {
        guard let total = area.lengthByTile[tile], total > 0 else { return 0 }
        var held = 0.0
        for s in area.segments(in: tile) {
            let c = coinsHeld(s, by: owner, state: state, now: now)
            held += s.length * Double(c.held) / Double(c.total)
        }
        return held / total
    }

    /// Streets the owner holds at least one coin on, anywhere, loaded or not.
    public func heldEverywhere(by owner: OwnerRef, state: GameState, now: Date) -> Int {
        Set(state.ownership.filter { $0.value.owner == owner && $0.value.strength(at: now, decay: rules.decayInterval) > 0 }
            .map { Coins.segment(of: $0.key) }).count
    }

    public func standings(state: GameState, playerName: String, playerColorHex: String, now: Date) -> [Standing] {
        var by: [OwnerRef: (Int, Double)] = [:]
        for s in area.segments {
            let owners = coinOwners(s, state: state, now: now)
            for (o, n) in Dictionary(grouping: owners.compactMap { $0 }, by: { $0 }).mapValues(\.count) {
                by[o, default: (0, 0)].0 += 1
                by[o, default: (0, 0)].1 += s.length * Double(n) / Double(owners.count)
            }
        }
        var owners = Set(by.keys)
        owners.insert(state.me)
        state.ghosts.forEach { owners.insert(.ghost($0.id)) }
        return owners.map { o in
            let ghost = state.ghosts.first { $0.id == o.id && o.kind == .ghost }
            return Standing(owner: o,
                            name: o == state.me ? playerName : (ghost?.name ?? "Rival"),
                            colorHex: o == state.me ? playerColorHex : (ghost?.colorHex ?? "8888AA"),
                            streets: by[o]?.0 ?? 0, metres: by[o]?.1 ?? 0,
                            blocks: completedBlocks(for: o, state: state, now: now).count,
                            tokens: state.tokens(of: o))
        }.sorted { ($0.tokens, $0.streets) > ($1.tokens, $1.streets) }
    }

    func ownerName(_ o: OwnerRef, state: GameState) -> String {
        if o.kind == .ghost, let g = state.ghosts.first(where: { $0.id == o.id }) { return g.name }
        return o == state.me ? "you" : "a rival"
    }
}
