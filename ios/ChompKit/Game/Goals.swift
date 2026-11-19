import Foundation

/// What a finished run contributed, for goals and streaks.
public struct RunFacts: Sendable, Hashable {
    public var date: Date
    public var distance: Double
    public var streets: Int
    public var stolen: Int
    public var tokens: Int
    public var pellets: Int
    public var blocks: Int
    public init(date: Date, distance: Double, streets: Int, stolen: Int, tokens: Int, pellets: Int, blocks: Int) {
        self.date = date; self.distance = distance; self.streets = streets; self.stolen = stolen
        self.tokens = tokens; self.pellets = pellets; self.blocks = blocks
    }
}

public struct WeeklyGoal: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable { case streets, tokens, days, distance, steal, pellets, blocks }
    public var id: String { kind.rawValue }
    public var kind: Kind
    public var target: Int
    public var progress: Int
    public var done: Bool { progress >= target }
    public var fraction: Double { min(1, Double(progress) / Double(max(target, 1))) }

    public var title: String {
        switch kind {
        case .streets: "Capture \(target) streets"
        case .tokens: "Eat \(target.formatted()) tokens"
        case .days: "Run on \(target) different days"
        case .distance: "Run \(target) km"
        case .steal: "Take \(target) streets from rivals"
        case .pellets: target == 1 ? "Grab a power pellet" : "Grab \(target) power pellets"
        case .blocks: target == 1 ? "Win a block" : "Win \(target) blocks"
        }
    }
    public var symbol: String {
        switch kind {
        case .streets: "road.lanes"
        case .tokens: "circle.grid.cross.fill"
        case .days: "calendar"
        case .distance: "figure.run"
        case .steal: "arrow.uturn.backward.circle.fill"
        case .pellets: "bolt.circle.fill"
        case .blocks: "square.grid.3x3.fill"
        }
    }
}

/// Weekly goals (Monday to Sunday, UK time, the same three for everyone each
/// week) and the daily run streak. Pure: computed from run history.
public enum Goals {
    public static let calendar: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        return c
    }()

    public static func weekStart(_ d: Date) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: d)!.start
    }

    public static func weekKey(_ d: Date) -> String {
        let c = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: d)
        return "\(c.yearForWeekOfYear!)-W\(c.weekOfYear!)"
    }

    private static let options: [WeeklyGoal.Kind: [Int]] = [
        .streets: [12, 20, 30], .tokens: [300, 600, 1000], .days: [3, 4, 5], .distance: [10, 15, 20],
        .steal: [3, 5, 8], .pellets: [1, 2], .blocks: [1, 2],
    ]

    /// This week's three goals with progress from `runs`.
    public static func weekly(runs: [RunFacts], now: Date) -> [WeeklyGoal] {
        var rng = SeededRandom(string: "goals|\(weekKey(now))")
        var kinds = WeeklyGoal.Kind.allCases
        var picked: [WeeklyGoal] = []
        for _ in 0..<3 {
            let k = kinds.remove(at: rng.int(kinds.count))
            let targets = options[k]!
            picked.append(WeeklyGoal(kind: k, target: targets[rng.int(targets.count)], progress: 0))
        }
        let start = weekStart(now)
        let week = runs.filter { $0.date >= start && $0.date <= now }
        for i in picked.indices {
            picked[i].progress = switch picked[i].kind {
            case .streets: week.reduce(0) { $0 + $1.streets }
            case .tokens: week.reduce(0) { $0 + $1.tokens }
            case .days: Set(week.map { calendar.startOfDay(for: $0.date) }).count
            case .distance: Int(week.reduce(0) { $0 + $1.distance } / 1000)
            case .steal: week.reduce(0) { $0 + $1.stolen }
            case .pellets: week.reduce(0) { $0 + $1.pellets }
            case .blocks: week.reduce(0) { $0 + $1.blocks }
            }
        }
        return picked
    }

    public struct Streak: Sendable, Hashable {
        /// Days in a row with a run, counting today if you've run, else up to yesterday.
        public var current: Int
        public var best: Int
        public var ranToday: Bool
        /// The streak ends at midnight unless you run today.
        public var atRisk: Bool { current > 0 && !ranToday }
    }

    public static func streak(runs: [RunFacts], now: Date) -> Streak {
        let days = Set(runs.map { calendar.startOfDay(for: $0.date) })
        let today = calendar.startOfDay(for: now)
        let ranToday = days.contains(today)
        var current = 0
        var d = ranToday ? today : calendar.date(byAdding: .day, value: -1, to: today)!
        while days.contains(d) {
            current += 1
            d = calendar.date(byAdding: .day, value: -1, to: d)!
        }
        var best = 0, run = 0
        var prev: Date?
        for day in days.sorted() {
            if let p = prev, calendar.date(byAdding: .day, value: 1, to: p) == day { run += 1 } else { run = 1 }
            best = max(best, run)
            prev = day
        }
        return Streak(current: current, best: max(best, current), ranToday: ranToday)
    }
}
