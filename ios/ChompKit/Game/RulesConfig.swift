import Foundation

/// Mirror of shared/rules.json. The same file is read by the server, so the
/// client's provisional results agree with the authoritative ones.
public struct RulesConfig: Codable, Sendable, Hashable {
    public struct Capture: Codable, Sendable, Hashable {
        public var coverageThreshold: Double
        public var frenzyRivalCoverageThreshold: Double
        public var pointsPerMetre: Double
        public var minimumPointsPerSegment: Int
        /// A coin is taken when the matched run passes within this many metres of it.
        public var coinReachMetres: Double?
    }
    public struct Decay: Codable, Sendable, Hashable {
        /// Off: streets stay yours until someone else runs them.
        public var enabled: Bool?
        public var days: Double
        public var isEnabled: Bool { enabled ?? true }
    }
    public struct Frenzy: Codable, Sendable, Hashable {
        public var durationSeconds: Double
        public var multiplier: Double
        public var collectRadiusMetres: Double
    }
    public struct Count: Codable, Sendable, Hashable { public var perDay: Int }
    public struct Blocks: Codable, Sendable, Hashable {
        /// Capture areas: filling a block (bonus) and conquering a map square.
        /// Off for now; streets and their tokens are the whole game.
        public var enabled: Bool?
        public var isEnabled: Bool { enabled ?? true }
        public var bonusBasePoints: Int
        public var bonusPointsPerHundredSquareMetres: Double
        public var reawardCooldownHours: Double
    }
    public struct Matching: Codable, Sendable, Hashable {
        public var candidateRadiusMetres: Double
        public var gpsSigmaMetres: Double
        public var transitionBeta: Double
        public var maxCandidatesPerPoint: Int
        public var minPointSpacingMetres: Double
        public var maxGapSeconds: Double
        public var maxGapMetres: Double
        public var maxAccuracyMetres: Double
    }
    public struct AntiCheat: Codable, Sendable, Hashable {
        public var maxSustainedSpeedKmh: Double
        public var sustainedWindowSeconds: Double
        public var teleportSpeedKmh: Double
        public var maxAccelerationMps2: Double
        public var straightLineWindowSeconds: Double
        public var maxAutomotiveFraction: Double
        public var maxCyclingFraction: Double
        public var minRunningCadenceSpm: Double
        public var runningSpeedForCadenceCheckMps: Double
        public var lowHeartRateBpm: Double
        public var maxCapturesPerRun: Int
        public var maxCapturesPerDay: Int
    }
    public struct Ghosts: Codable, Sendable, Hashable {
        public var perArea: Int
        public var segmentsPerDayMin: Int
        public var segmentsPerDayMax: Int
        public var maxTickHours: Double
    }
    /// The dots drawn along every street. Capturing a street eats its tokens,
    /// and leaderboards rank by tokens captured.
    public struct Tokens: Codable, Sendable, Hashable {
        public var metresPerToken: Double
    }
    public struct Imports: Codable, Sendable, Hashable {
        /// Runs added after the fact (Health import, late upload) still capture
        /// streets if they ended within this many hours. Older ones only count
        /// as exploration.
        public var captureWindowHours: Double
    }
    public struct Privacy: Codable, Sendable, Hashable {
        public var defaultZoneRadiusMetres: Double
        public var zoneJitterMetres: Double
    }

    public var version: Int
    public var capture: Capture
    public var decay: Decay
    public var frenzy: Frenzy
    public var powerPellets: Count
    public var bonusStreets: Count
    public var blocks: Blocks
    public var matching: Matching
    public var antiCheat: AntiCheat
    public var ghosts: Ghosts
    public var imports: Imports
    public var tokens: Tokens

    /// Tokens on a street of this length: one per `metresPerToken`, at least one.
    public func tokens(forLength metres: Double) -> Int {
        max(1, Int((metres / tokens.metresPerToken).rounded()))
    }
    public var privacy: Privacy

    /// Infinite when decay is off, so strength stays at 1 forever.
    public var decayInterval: TimeInterval { decay.isEnabled ? decay.days * 86_400 : .infinity }

    /// Rules bundled with ChompKit (a copy of shared/rules.json).
    public static let bundled: RulesConfig = {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: "rules", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let rules = try? JSONDecoder().decode(RulesConfig.self, from: data) else {
            fatalError("ChompKit is missing rules.json")
        }
        return rules
    }()
}

final class BundleToken {}

public extension Bundle {
    /// ChompKit's own resource bundle.
    static var chompKit: Bundle { Bundle(for: BundleToken.self) }
}
