import Foundation

/// Simulated rivals for when nobody else plays nearby. They "run" a few streets a
/// day near the player's territory, so there's always something to win back.
/// They have ordinary runner names and aren't labelled in the UI. Online, the
/// server's bots take over and step back once real runners are active nearby.
public struct GhostSimulator: Sendable {
    public let engine: GameEngine
    public init(engine: GameEngine) { self.engine = engine }

    /// Internal ids only (never shown).
    static let names = ["Dusk", "Rook", "Moth", "Fennel", "Pike", "Wren"]
    /// Display names: the kind of names runners actually pick.
    public static let displayNames = [
        "Jess M", "Callum R", "Sophie T", "Dan Hughes", "Ellie B", "Tom W", "Hannah K", "Josh P",
        "Amira S", "Liam O", "Grace H", "Ryan C", "Megan D", "Sam L", "Chloe F", "Isla A",
        "Zara N", "Matt G", "Katie J", "Owen E", "runner_dan", "miles_with_meg", "Lou runs", "ellie.runs",
        "tomtom_5k", "jo_on_the_go", "Kieran", "Ffion", "Rachel", "Ash", "Becky R", "Will T",
        "Niamh", "Harvey", "Ruby P", "Jay", "Arjun", "Leo", "Maisie", "Ollie K"
    ]

    /// `count` distinct display names for `seed`, skipping any in `taken` (case-insensitive).
    public static func pickNames(seed: String, count: Int, taken: Set<String> = []) -> [String] {
        var rng = SeededRandom(string: "names|\(seed)")
        var pool = displayNames.filter { !taken.contains($0.lowercased()) }
        var out: [String] = []
        while out.count < count, !pool.isEmpty { out.append(pool.remove(at: rng.int(pool.count))) }
        return out
    }
    static let colours = ["7C8CFF", "FF6FA1", "5CE1E6", "FFB15C", "B58CFF", "9CFF7A"]

    /// Creates bots the first time an area is played. Bot colours avoid the player's.
    public func ensureGhosts(state: inout GameState, playerColorHex: String, now: Date) {
        // Older saves named bots "Bot …": give them ordinary names.
        if state.ghosts.contains(where: { $0.name.hasPrefix("Bot ") }) {
            let fresh = Self.pickNames(seed: "\(engine.area.slug)|\(state.playerID)", count: state.ghosts.count)
            for i in state.ghosts.indices where i < fresh.count { state.ghosts[i].name = fresh[i] }
        }
        guard state.ghosts.isEmpty, !engine.area.segments.isEmpty else { return }
        let display = Self.pickNames(seed: "\(engine.area.slug)|\(state.playerID)", count: Self.names.count)
        var rng = SeededRandom(string: "ghosts|\(engine.area.slug)|\(state.playerID)")
        let colours = Self.colours.filter { $0.caseInsensitiveCompare(playerColorHex) != .orderedSame }
        let rules = engine.rules.ghosts
        let nodes = engine.area.graph.adjacency.keys.sorted()
        for i in 0..<min(rules.perArea, Self.names.count) {
            let span = max(1, rules.segmentsPerDayMax - rules.segmentsPerDayMin + 1)
            state.ghosts.append(GhostProfile(
                id: "bot-\(Self.names[i].lowercased())",
                name: display[i % display.count],
                colorHex: colours[i % colours.count],
                aggression: 0.3 + rng.unit() * 0.5,
                segmentsPerDay: rules.segmentsPerDayMin + rng.int(span),
                cursorNode: nodes[rng.int(nodes.count)]))
        }
        // Give each bot a small starting patch so the town isn't empty on day one.
        let seeded = state.ghosts.indices.flatMap { g in
            walk(ghost: g, steps: state.ghosts[g].segmentsPerDay * 3, from: now.addingTimeInterval(-86_400 * 3), to: now,
                 state: &state, rng: &rng)
        }
        _ = seeded
        state.lastGhostTick = now
    }

    /// Advances the bots from the last tick to `now`. Returns the raids on the player.
    @discardableResult
    public func tick(state: inout GameState, now: Date) -> [GameEvent] {
        guard let last = state.lastGhostTick else { state.lastGhostTick = now; return [] }
        let elapsed = min(now.timeIntervalSince(last), engine.rules.ghosts.maxTickHours * 3600)
        guard elapsed >= 600 else { return [] }
        var rng = SeededRandom(string: "tick|\(state.playerID)|\(Int(last.timeIntervalSince1970))")
        var events: [GameEvent] = []
        let start = now.addingTimeInterval(-elapsed)
        for g in state.ghosts.indices {
            let expected = Double(state.ghosts[g].segmentsPerDay) * elapsed / 86_400
            var steps = Int(expected)
            if rng.unit() < expected - Double(steps) { steps += 1 }
            guard steps > 0 else { continue }
            let stolen = walk(ghost: g, steps: steps, from: start, to: now, state: &state, rng: &rng)
            if !stolen.isEmpty {
                let ghost = state.ghosts[g]
                let names = stolen.compactMap { engine.area.segment($0)?.name }.filter { !$0.isEmpty }
                let street = Dictionary(grouping: names, by: { $0 }).max { $0.value.count < $1.value.count }?.key
                let msg = "\(ghost.name) took \(stolen.count) of your street\(stolen.count == 1 ? "" : "s")" + (street.map { " on \($0)" } ?? "")
                let e = GameEvent(date: now, kind: .ghostRaid, actor: .ghost(ghost.id), segmentIDs: stolen, message: msg)
                state.log(e)
                events.append(e)
            }
        }
        state.lastGhostTick = now
        return events
    }

    /// Moves one bot `steps` streets. Returns the player's streets it took.
    private func walk(ghost g: Int, steps: Int, from start: Date, to end: Date,
                      state: inout GameState, rng: inout SeededRandom) -> [SegmentID] {
        let area = engine.area
        let me = state.me
        let ghostRef = OwnerRef.ghost(state.ghosts[g].id)
        let decay = engine.rules.decayInterval
        let rules = engine.rules
        let cap = Int(Double(area.segments.reduce(0) { $0 + rules.coinCount($1) }) * 0.06)  // in coins
        var held = state.ownership.values.filter { $0.owner == ghostRef && $0.strength(at: end, decay: decay) > 0 }.count
        var stolen: [SegmentID] = []
        var node = state.ghosts[g].cursorNode
        let aggression = state.ghosts[g].aggression
        let mine = Set(state.ownership.filter { $0.value.owner == me && $0.value.strength(at: end, decay: decay) > 0 }
            .map { Coins.segment(of: $0.key) }).sorted()

        for step in 0..<steps {
            // Occasionally jump to the edge of the player's territory for a raid.
            if !mine.isEmpty, rng.unit() < aggression * 0.12, let seg = area.segment(mine[rng.int(mine.count)]) {
                node = rng.unit() < 0.5 ? seg.startNode : seg.endNode
            }
            let options = area.graph.neighbours(of: node)
            guard !options.isEmpty else {
                let nodes = area.graph.adjacency.keys.sorted()
                node = nodes[rng.int(nodes.count)]
                continue
            }
            let weights: [Double] = options.map { e in
                let owners = engine.coinOwners(area.segments[e.segment], state: state, now: end).compactMap { $0 }
                if owners.isEmpty { return held >= cap ? 0.15 : 1.5 }
                if owners.contains(me) { return 1 + 4 * aggression }
                if owners.allSatisfy({ $0 == ghostRef }) { return 0.35 }
                return 0.6
            }
            let total = weights.reduce(0, +)
            var r = rng.unit() * total
            var pick = options[0]
            for (e, w) in zip(options, weights) {
                r -= w
                if r <= 0 { pick = e; break }
            }
            let seg = area.segments[pick.segment]
            let t = start.addingTimeInterval(end.timeIntervalSince(start) * Double(step + 1) / Double(steps))
            // A bot runs the whole street, so it takes every coin on it.
            var raided = false, gained = 0
            for id in rules.coinIDs(seg) {
                let prev = state.ownership[id]
                if prev?.owner == ghostRef {
                    state.ownership[id]?.lastVisitedAt = t
                    continue
                }
                if prev?.owner == me, prev!.strength(at: t, decay: decay) > 0 { raided = true }
                state.ownership[id] = Ownership(owner: ghostRef, capturedAt: t, lastVisitedAt: t)
                gained += 1
            }
            if raided { stolen.append(seg.id) }
            if gained > 0 {
                state.addTokens(gained, to: ghostRef)
                held += gained
            }
            node = pick.other
        }
        state.ghosts[g].cursorNode = node
        return stolen
    }
}
