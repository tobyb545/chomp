import Foundation

/// What badges are judged on. Built by the app from run history and game state.
public struct BadgeStats: Sendable, Hashable {
    public var tokens = 0
    public var runs = 0
    public var bestStreak = 0
    public var stolen = 0
    /// Metres, all runs.
    public var distance: Double = 0
    /// Share of the streets around you that you hold (0...1).
    public var heldFraction: Double = 0
    public var powerUps = 0
    public var inClub = false
    public var earlyBird = false
    public var nightOwl = false
    public init() {}
}

public enum BadgeTier: String, Sendable, CaseIterable { case bronze, silver, gold, special }

public struct Badge: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    /// How to earn it, e.g. "Collect 1,000 coins".
    public let detail: String
    public let symbol: String
    public let tier: BadgeTier
    public let current: Double
    public let target: Double
    /// Show "340 / 1,000" progress (false for one-off badges).
    public let counted: Bool
    /// Divides current/target for display (e.g. metres → km).
    public let unit: Double

    public var earned: Bool { current >= target }
    public var progress: Double { target > 0 ? min(1, current / target) : 1 }
}

public enum Badges {
    /// Every badge, in display order, with progress towards it.
    public static func all(_ s: BadgeStats) -> [Badge] {
        func count(_ id: String, _ title: String, _ detail: String, _ symbol: String, _ tier: BadgeTier,
                   _ current: Double, _ target: Double, unit: Double = 1) -> Badge {
            Badge(id: id, title: title, detail: detail, symbol: symbol, tier: tier, current: current, target: target,
                  counted: target > 1, unit: unit)
        }
        func once(_ id: String, _ title: String, _ detail: String, _ symbol: String, _ tier: BadgeTier, _ done: Bool) -> Badge {
            Badge(id: id, title: title, detail: detail, symbol: symbol, tier: tier, current: done ? 1 : 0, target: 1, counted: false, unit: 1)
        }
        let coins = Double(s.tokens), runs = Double(s.runs), streak = Double(s.bestStreak), stolen = Double(s.stolen)
        return [
            count("coins-1", "First bite", "Collect your first coin", "circle.grid.cross.fill", .bronze, coins, 1),
            count("coins-1k", "Coin collector", "Collect 1,000 coins", "dollarsign.circle.fill", .silver, coins, 1_000),
            count("coins-10k", "Treasure hunter", "Collect 10,000 coins", "crown.fill", .gold, coins, 10_000),
            count("runs-1", "Off the mark", "Finish your first run", "figure.run", .bronze, runs, 1),
            count("runs-10", "Regular", "Finish 10 runs", "figure.run.circle.fill", .silver, runs, 10),
            count("runs-50", "Street legend", "Finish 50 runs", "star.circle.fill", .gold, runs, 50),
            count("streak-3", "Hat-trick", "Run 3 days in a row", "flame.fill", .bronze, streak, 3),
            count("streak-7", "Week warrior", "Run 7 days in a row", "flame.circle.fill", .silver, streak, 7),
            count("streak-30", "Unstoppable", "Run 30 days in a row", "bolt.heart.fill", .gold, streak, 30),
            count("steal-1", "Sticky fingers", "Steal a street from a rival", "hand.raised.fill", .bronze, stolen, 1),
            count("steal-25", "Master thief", "Steal 25 streets from rivals", "theatermasks.fill", .gold, stolen, 25),
            count("dist-10", "First 10K", "Run 10 km in total", "shoeprints.fill", .bronze, s.distance, 10_000, unit: 1000),
            count("dist-100", "Century", "Run 100 km in total", "medal.fill", .silver, s.distance, 100_000, unit: 1000),
            count("dist-500", "Long haul", "Run 500 km in total", "trophy.fill", .gold, s.distance, 500_000, unit: 1000),
            count("map-10", "Local hero", "Hold 10% of the streets around you", "map.fill", .silver, s.heldFraction * 100, 10),
            count("map-25", "Kingpin", "Hold 25% of the streets around you", "flag.fill", .gold, s.heldFraction * 100, 25),
            once("power", "Frenzy", "Reach a power-up landmark", "bolt.circle.fill", .special, s.powerUps > 0),
            once("club", "Team player", "Join or start a club", "person.3.fill", .special, s.inClub),
            once("early", "Early bird", "Start a run before 7am", "sunrise.fill", .special, s.earlyBird),
            once("night", "Night owl", "Start a run after 9pm", "moon.stars.fill", .special, s.nightOwl),
        ]
    }

    /// Badges earned now that aren't in `already`.
    public static func newlyEarned(_ s: BadgeStats, already: Set<String>) -> [Badge] {
        all(s).filter { $0.earned && !already.contains($0.id) }
    }
}
