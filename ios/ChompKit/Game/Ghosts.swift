import Foundation

/// Simulated rivals for solo play. They "run" a few streets a day near the
/// player's territory, so there's always something to win back. Always shown
/// as bots in the UI.
public struct GhostSimulator: Sendable {
    public let engine: GameEngine
    public init(engine: GameEngine) { self.engine = engine }

    static let names = ["Dusk", "Rook", "Moth", "Fennel", "Pike", "Wren"]
    static let colours = ["7C8CFF", "FF6FA1", "5CE1E6", "FFB15C", "B58CFF", "9CFF7A"]

    /// Creates bots the first time an area is played. Bot colours avoid the player's.
    public func ensureGhosts(state: inout GameState, playerColorHex: String, now: Date) {
        guard state.ghosts.isEmpty, !engine.area.segments.isEmpty else { return }
        var rng = SeededRandom(string: "ghosts|\(engine.area.slug)|\(state.playerID)")
        let colours = Self.colours.filter { $0.caseInsensitiveCompare(playerColorHex) != .orderedSame }
        let rules = engine.rules.ghosts
        let nodes = engine.area.graph.adjacency.keys.sorted()
        for i in 0..<min(rules.perArea, Self.names.count) {
            let span = max(1, rules.segmentsPerDayMax - rules.segmentsPerDayMin + 1)
            state.ghosts.append(GhostProfile(
                id: "bot-\(Self.names[i].lowercased())",
                name: "Bot \(Self.names[i])",
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
                let msg = "\(ghost.name) ate \(stolen.count) of your street\(stolen.count == 1 ? "" : "s")" + (street.map { " on \($0)" } ?? "")
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
        let cap = Int(Double(area.segments.count) * 0.06)
        var held = state.ownership.values.filter { $0.owner == ghostRef && $0.strength(at: end, decay: decay) > 0 }.count
        var stolen: [SegmentID] = []
        var node = state.ghosts[g].cursorNode
        let aggression = state.ghosts[g].aggression
        let mine = state.ownership.filter { $0.value.owner == me && $0.value.strength(at: end, decay: decay) > 0 }.map(\.key).sorted()

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
                let s = area.segments[e.segment]
                guard let o = state.ownership[s.id], o.strength(at: end, decay: decay) > 0 else {
                    return held >= cap ? 0.15 : 1.5
                }
                if o.owner == me { return 1 + 4 * aggression }
                if o.owner == ghostRef { return 0.35 }
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
            let prev = state.ownership[seg.id]
            if prev?.owner == ghostRef {
                state.ownership[seg.id]?.lastVisitedAt = t
            } else {
                if prev?.owner == me, prev!.strength(at: t, decay: decay) > 0 { stolen.append(seg.id) }
                state.ownership[seg.id] = Ownership(owner: ghostRef, capturedAt: t, lastVisitedAt: t)
                held += 1
            }
            node = pick.other
        }
        state.ghosts[g].cursorNode = node
        return stolen
    }
}
