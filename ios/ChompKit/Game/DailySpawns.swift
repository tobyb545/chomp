import Foundation

/// Deterministic PRNG (SplitMix64). Same seed → same sequence on iOS and server,
/// so everyone in a town sees the same power pellets and bonus streets.
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public init(string: String) {
        // FNV-1a 64
        var h: UInt64 = 0xcbf29ce484222325
        for b in string.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        state = h
    }
    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    /// Uniform in [0, 1).
    public mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    public mutating func int(_ upper: Int) -> Int { upper <= 0 ? 0 : Int(next() % UInt64(upper)) }
}

public struct PowerPellet: Sendable, Hashable, Identifiable {
    public let id: String
    public let landmark: Landmark
    public let activeFrom: Date
    public let activeUntil: Date
}

public struct BonusStreet: Sendable, Hashable, Identifiable {
    public var id: String { "\(streetName)@\(Int(startsAt.timeIntervalSince1970))" }
    /// Every segment of the named street gets the multiplier.
    public let segmentIDs: [SegmentID]
    public let streetName: String
    public let multiplier: Double
    public let startsAt: Date
    public let endsAt: Date

    public func label(calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = calendar.component(.minute, from: endsAt) == 0 ? "ha" : "h:mma"
        f.amSymbol = "am"; f.pmSymbol = "pm"
        let mult = multiplier == multiplier.rounded() ? "\(Int(multiplier))" : String(format: "%.1f", multiplier)
        return "\(streetName): \(mult)× until \(f.string(from: endsAt))"
    }

    public func isActive(at d: Date) -> Bool { d >= startsAt && d < endsAt }
}

public enum DailySpawns {
    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// UK local day for the town, regardless of the device's time zone.
    public static var townCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London") ?? .current
        return c
    }

    public static func powerPellets(area: Area, date: Date, rules: RulesConfig, calendar: Calendar = townCalendar) -> [PowerPellet] {
        let key = dayKey(date, calendar: calendar)
        var rng = SeededRandom(string: "pellets|\(area.slug)|\(key)")
        var pool = area.landmarks.sorted { $0.id < $1.id }
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        var out: [PowerPellet] = []
        let n = min(rules.powerPellets.perDay, pool.count)
        for _ in 0..<n {
            let i = rng.int(pool.count)
            let lm = pool.remove(at: i)
            out.append(PowerPellet(id: "\(key)|\(lm.id)", landmark: lm, activeFrom: start, activeUntil: end))
        }
        return out
    }

    public static func bonusStreets(area: Area, date: Date, rules: RulesConfig, calendar: Calendar = townCalendar) -> [BonusStreet] {
        let key = dayKey(date, calendar: calendar)
        var rng = SeededRandom(string: "bonus|\(area.slug)|\(key)")
        // Prefer proper named streets of a satisfying length.
        let pool = area.segments.filter { !$0.name.isEmpty && $0.length >= 80 && !$0.isPath }.sorted { $0.id < $1.id }
        guard !pool.isEmpty else { return [] }
        let day = calendar.startOfDay(for: date)
        let windows: [(Int, Int, Double)] = [(6, 8, 3), (17, 20, 2), (12, 14, 2)]
        var out: [BonusStreet] = []
        var used = Set<String>()
        for w in windows.prefix(rules.bonusStreets.perDay) {
            var s = pool[rng.int(pool.count)]
            var tries = 0
            while used.contains(s.name), tries < 10 { s = pool[rng.int(pool.count)]; tries += 1 }
            used.insert(s.name)
            out.append(BonusStreet(
                segmentIDs: area.segments.filter { $0.name == s.name }.map(\.id), streetName: s.name, multiplier: w.2,
                startsAt: calendar.date(byAdding: .hour, value: w.0, to: day)!,
                endsAt: calendar.date(byAdding: .hour, value: w.1, to: day)!))
        }
        return out
    }
}
