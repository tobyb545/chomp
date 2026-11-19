import Foundation

public typealias CoinID = String

/// Streets are lined with coins, one per token, evenly spaced. Coins are the
/// unit of ownership: you take every coin your run passes, not whole streets.
/// The server's chomp/coins.ts does exactly the same maths.
public enum Coins {
    public static func count(length: Double, metresPerToken: Double) -> Int {
        max(1, Int((length / metresPerToken).rounded()))
    }

    /// Distance along the street of coin `i` of `n`.
    public static func offset(_ i: Int, of n: Int, length: Double) -> Double {
        length * (Double(i) + 0.5) / Double(n)
    }

    public static func id(_ segment: SegmentID, _ i: Int) -> CoinID { "\(segment)#\(i)" }

    /// The street a coin is on. A plain street ID (state saved before coins) maps to itself.
    public static func segment(of key: String) -> SegmentID {
        guard let hash = key.lastIndex(of: "#") else { return key }
        return String(key[..<hash])
    }

    public static func index(of key: String) -> Int? {
        guard let hash = key.lastIndex(of: "#") else { return nil }
        return Int(key[key.index(after: hash)...])
    }

    public static func isCoin(_ key: String) -> Bool { key.contains("#") }
}

public extension RulesConfig {
    func coinCount(_ s: Segment) -> Int { Coins.count(length: s.length, metresPerToken: tokens.metresPerToken) }
    func coinIDs(_ s: Segment) -> [CoinID] { (0..<coinCount(s)).map { Coins.id(s.id, $0) } }
    /// How close (metres along the street) the matched run must pass a coin to take it.
    var coinReach: Double { capture.coinReachMetres ?? 5 }
}

public extension GameState {
    /// Whoever holds the most coins on a street (ignoring fading), or nil if none are held.
    func mainOwner(of s: Segment, rules: RulesConfig) -> OwnerRef? {
        if let o = ownership[s.id] { return o.owner }  // saved before coins
        var counts: [OwnerRef: Int] = [:]
        var best: (OwnerRef, Int)?
        for id in rules.coinIDs(s) {
            guard let o = ownership[id]?.owner else { continue }
            counts[o, default: 0] += 1
            if best == nil || counts[o]! > best!.1 { best = (o, counts[o]!) }
        }
        return best?.0
    }
}

public extension GameEngine {
    /// Live owner of each coin on a street (nil = unclaimed).
    func coinOwners(_ s: Segment, state: GameState, now: Date) -> [OwnerRef?] {
        rules.coinIDs(s).map { id in
            guard let o = state.ownership[id], o.strength(at: now, decay: rules.decayInterval) > 0 else { return nil }
            return o.owner
        }
    }

    /// How many of a street's coins `owner` holds, out of how many.
    func coinsHeld(_ s: Segment, by owner: OwnerRef, state: GameState, now: Date) -> (held: Int, total: Int) {
        let owners = coinOwners(s, state: state, now: now)
        return (owners.filter { $0 == owner }.count, owners.count)
    }

    /// State saved before coins existed keys ownership by street. Spread each
    /// street's owner over its coins (for the streets loaded now).
    func migrateToCoins(state: inout GameState) {
        for s in area.segments {
            guard let o = state.ownership[s.id] else { continue }
            state.ownership[s.id] = nil
            for id in rules.coinIDs(s) where state.ownership[id] == nil { state.ownership[id] = o }
        }
    }
}
