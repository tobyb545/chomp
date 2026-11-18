import Foundation

/// Mirror of shared/rules.json. The same file is read by the server, so the
/// client's provisional results agree with the authoritative ones.
public struct RulesConfig: Codable, Sendable, Hashable {
    public struct Capture: Codable, Sendable, Hashable {
        public var coverageThreshold: Double
        public var frenzyRivalCoverageThreshold: Double
        public var pointsPerMetre: Double
        public var minimumPointsPerSegment: Int
    }
    public struct Decay: Codable, Sendable, Hashable { public var days: Double }
    public struct Frenzy: Codable, Sendable, Hashable {
        public var durationSeconds: Double
        public var multiplier: Double
        public var collectRadiusMetres: Double
    }
    public struct Count: Codable, Sendable, Hashable { public var perDay: Int }
    public struct Blocks: Codable, Sendable, Hashable {
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
    public var privacy: Privacy

    public var decayInterval: TimeInterval { decay.days * 86_400 }

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
