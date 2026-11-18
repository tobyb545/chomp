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
}

public struct RunContext: Sendable {
    public var runID: UUID
    public var startedAt: Date
    public var endedAt: Date
    /// Imported history: counts for personal exploration only, never ownership.
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
}

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
        struct Progress { var set = IntervalSet(); var crossed: Date?; var frenzyCrossed: Date?; var last: Date = .distantPast }
        var segProgress: [Int: Progress] = [:]
        for p in pieces.sorted(by: { $0.end < $1.end }) {
            var pr = segProgress[p.segment] ?? Progress()
            pr.set.insert(p.from...p.to)
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

        let ordered = segProgress.sorted { ($0.value.crossed ?? $0.value.frenzyCrossed ?? $0.value.last) < ($1.value.crossed ?? $1.value.frenzyCrossed ?? $1.value.last) }
        for (segIndex, pr) in ordered {
            let seg = area.segments[segIndex]
            let ratio = min(1, seg.length > 0 ? pr.set.coveredLength / seg.length : 0)
            let current = state.ownership[seg.id]
            let currentLive = current.flatMap { $0.strength(at: pr.last, decay: rules.decayInterval) > 0 ? $0 : nil }
            let at = pr.crossed ?? pr.frenzyCrossed ?? pr.last

            if pr.crossed != nil {
                var cov = state.coverage[seg.id] ?? PersonalCoverage(firstRunAt: at, lastRunAt: at, timesRun: 0, importedOnly: run.isImport)
                cov.firstRunAt = min(cov.firstRunAt, at)
                cov.lastRunAt = max(cov.lastRunAt, at)
                cov.timesRun += 1
                cov.importedOnly = cov.importedOnly && run.isImport
                state.coverage[seg.id] = cov
            }

            func record(_ kind: CaptureKind, pts: Int = 0, mult: Double = 1, reason: String? = nil) {
                records.append(CaptureRecord(segmentID: seg.id, streetName: seg.displayName, kind: kind, coverage: ratio,
                                             points: pts, multiplier: mult, previousOwner: currentLive?.owner, at: at, reason: reason))
            }

            let isMine = currentLive?.owner == me
            let isRival = currentLive != nil && !isMine
            let qualifies = pr.crossed != nil || (isRival && pr.frenzyCrossed != nil)
            guard qualifies else { record(.partial); continue }

            if run.isImport { record(.rejected, reason: "Imported runs count for exploration only"); continue }
            if report.verdict == .underReview { record(.rejected, reason: "Run is under review"); continue }

            if isMine {
                state.ownership[seg.id]?.lastVisitedAt = max(current!.lastVisitedAt, at)
                record(.refreshed)
                continue
            }
            guard capturesThisRun < rules.antiCheat.maxCapturesPerRun, capturesToday < rules.antiCheat.maxCapturesPerDay else {
                record(.rejected, reason: "Daily capture limit reached")
                continue
            }
            let mult = (inFrenzy(at) ? rules.frenzy.multiplier : 1) * bonusMultiplier(seg.id, at)
            let pts = max(rules.capture.minimumPointsPerSegment, Int((seg.length * rules.capture.pointsPerMetre * mult).rounded()))
            state.ownership[seg.id] = Ownership(owner: me, capturedAt: at, lastVisitedAt: at)
            capturesThisRun += 1
            capturesToday += 1
            points += pts
            record(isRival ? .stolen : .captured, pts: pts, mult: mult)
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
                                message: "You ate \(gained.count) new street\(gained.count == 1 ? "" : "s")"))
        }
        let stolen = records.filter { $0.kind == .stolen }
        for (owner, recs) in Dictionary(grouping: stolen, by: { $0.previousOwner }) {
            let who = owner.map { ownerName($0, state: state) } ?? "a rival"
            state.log(GameEvent(date: run.endedAt, kind: .stolen, actor: me, segmentIDs: recs.map(\.segmentID),
                                points: recs.reduce(0) { $0 + $1.points },
                                message: "You won back \(recs.count) street\(recs.count == 1 ? "" : "s") from \(who)"))
        }
        if !newBlocks.isEmpty {
            state.log(GameEvent(date: run.endedAt, kind: .blockCompleted, actor: me, points: blockBonus,
                                message: "Block\(newBlocks.count == 1 ? "" : "s") filled: +\(blockBonus) bonus"))
        }
        let rejected = records.filter { $0.kind == .rejected && $0.reason != "Imported runs count for exploration only" }
        if !rejected.isEmpty {
            state.log(GameEvent(date: run.endedAt, kind: .runRejected, actor: me, segmentIDs: rejected.map(\.segmentID),
                                message: "\(rejected.count) street\(rejected.count == 1 ? "" : "s") not counted: \(rejected[0].reason ?? "")"))
        }

        var conquered = false
        let badge = "conquered:\(area.slug)"
        if !state.badges.contains(badge), self.progress(for: me, state: state, now: run.endedAt).heldFraction >= 0.999 {
            state.badges.append(badge)
            conquered = true
            state.log(GameEvent(date: run.endedAt, kind: .townConquered, actor: me, message: "You conquered \(area.name)!"))
        }

        return RunOutcome(runID: run.runID, captures: records, points: points, blockBonus: blockBonus, blocksCompleted: newBlocks,
                          pelletsCollected: pellets, frenzyWindows: frenzy, verdict: report.verdict, flags: report.flags,
                          conqueredTown: conquered)
    }

    // MARK: Decay

    /// Neutralises faded streets. Returns how many of the player's streets faded.
    @discardableResult
    public func sweepDecay(state: inout GameState, now: Date) -> Int {
        var faded: [SegmentID] = []
        for (id, o) in state.ownership where o.strength(at: now, decay: rules.decayInterval) <= 0 {
            state.ownership[id] = nil
            if o.owner == state.me { faded.append(id) }
        }
        state.lastDecaySweep = now
        if !faded.isEmpty {
            state.log(GameEvent(date: now, kind: .decayed, actor: nil, segmentIDs: faded,
                                message: "\(faded.count) of your street\(faded.count == 1 ? "" : "s") faded back to neutral"))
        }
        return faded.count
    }

    // MARK: Queries

    public func isLive(_ o: Ownership?, now: Date) -> Bool {
        guard let o else { return false }
        return o.strength(at: now, decay: rules.decayInterval) > 0
    }

    public func completedBlocks(for owner: OwnerRef, state: GameState, now: Date) -> [BlockID] {
        area.blocks.filter { b in
            b.segmentIDs.allSatisfy { id in
                guard let o = state.ownership[id] else { return false }
                return o.owner == owner && o.strength(at: now, decay: rules.decayInterval) > 0
            }
        }.map(\.id)
    }

    public func progress(for owner: OwnerRef, state: GameState, now: Date) -> TownProgress {
        var held = 0
        var metres = 0.0
        for s in area.segments {
            if let o = state.ownership[s.id], o.owner == owner, o.strength(at: now, decay: rules.decayInterval) > 0 {
                held += 1
                metres += s.length
            }
        }
        let explored = owner == state.me
            ? state.coverage.keys.reduce(0.0) { $0 + (area.segment($1)?.length ?? 0) }
            : metres
        return TownProgress(heldSegments: held, heldMetres: metres,
                            heldFraction: area.totalLength > 0 ? metres / area.totalLength : 0,
                            exploredFraction: area.totalLength > 0 ? explored / area.totalLength : 0,
                            blocksHeld: completedBlocks(for: owner, state: state, now: now).count,
                            totalSegments: area.segments.count)
    }

    public func standings(state: GameState, playerName: String, playerColorHex: String, now: Date) -> [Standing] {
        var by: [OwnerRef: (Int, Double)] = [:]
        for s in area.segments {
            if let o = state.ownership[s.id], o.strength(at: now, decay: rules.decayInterval) > 0 {
                by[o.owner, default: (0, 0)].0 += 1
                by[o.owner, default: (0, 0)].1 += s.length
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
                            blocks: completedBlocks(for: o, state: state, now: now).count)
        }.sorted { ($0.streets, $0.metres) > ($1.streets, $1.metres) }
    }

    func ownerName(_ o: OwnerRef, state: GameState) -> String {
        if o.kind == .ghost, let g = state.ghosts.first(where: { $0.id == o.id }) { return g.name }
        return o == state.me ? "you" : "a rival"
    }
}
