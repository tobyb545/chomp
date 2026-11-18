import Foundation

public enum OwnerKind: String, Codable, Sendable, Hashable {
    case player
    /// Simulated rival, always labelled as a bot in the UI.
    case ghost
}

public struct OwnerRef: Codable, Hashable, Sendable {
    public var kind: OwnerKind
    public var id: String
    public init(kind: OwnerKind, id: String) { self.kind = kind; self.id = id }
    public static func player(_ id: String) -> OwnerRef { OwnerRef(kind: .player, id: id) }
    public static func ghost(_ id: String) -> OwnerRef { OwnerRef(kind: .ghost, id: id) }
}

public struct Ownership: Codable, Hashable, Sendable {
    public var owner: OwnerRef
    public var capturedAt: Date
    public var lastVisitedAt: Date

    public init(owner: OwnerRef, capturedAt: Date, lastVisitedAt: Date) {
        self.owner = owner
        self.capturedAt = capturedAt
        self.lastVisitedAt = lastVisitedAt
    }

    /// 1 when freshly run, fading linearly to 0 at the decay horizon.
    public func strength(at now: Date, decay: TimeInterval) -> Double {
        max(0, min(1, 1 - now.timeIntervalSince(lastVisitedAt) / decay))
    }
}

public struct PersonalCoverage: Codable, Hashable, Sendable {
    public var firstRunAt: Date
    public var lastRunAt: Date
    public var timesRun: Int
    /// Imported history (HealthKit/Strava) only counts here, never for ownership.
    public var importedOnly: Bool
}

public enum GameEventKind: String, Codable, Sendable {
    case captured, stolen, lost, refreshed, decayed, blockCompleted, powerPellet, frenzy, bonusStreet, ghostRaid, townConquered, runRejected
}

public struct GameEvent: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var date: Date
    public var kind: GameEventKind
    public var actor: OwnerRef?
    public var segmentIDs: [SegmentID]
    public var points: Int
    public var message: String

    public init(id: UUID = UUID(), date: Date, kind: GameEventKind, actor: OwnerRef?, segmentIDs: [SegmentID] = [], points: Int = 0, message: String) {
        self.id = id
        self.date = date
        self.kind = kind
        self.actor = actor
        self.segmentIDs = segmentIDs
        self.points = points
        self.message = message
    }
}

public struct GhostProfile: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var colorHex: String
    /// 0...1 – how strongly the bot targets the player's streets.
    public var aggression: Double
    public var segmentsPerDay: Int
    public var cursorNode: Int64
}

/// Everything about one area's game, as one Codable value. In offline/solo mode
/// this is the source of truth; online, the server's copy wins.
public struct GameState: Codable, Sendable {
    public var areaSlug: String
    public var playerID: String
    public var ownership: [SegmentID: Ownership] = [:]
    public var coverage: [SegmentID: PersonalCoverage] = [:]
    public var points: Int = 0
    public var events: [GameEvent] = []
    public var blockAwards: [BlockID: Date] = [:]
    public var ghosts: [GhostProfile] = []
    public var lastGhostTick: Date?
    /// A bot tick already announced via a scheduled notification; it must happen at exactly this time.
    public var scheduledGhostTick: Date?
    public var lastDecaySweep: Date?
    public var capturesByDay: [String: Int] = [:]
    public var badges: [String] = []
    /// Power pellet ID → when this player collected it.
    public var collectedPellets: [String: Date] = [:]

    public init(areaSlug: String, playerID: String) {
        self.areaSlug = areaSlug
        self.playerID = playerID
    }

    public var me: OwnerRef { .player(playerID) }

    public mutating func log(_ e: GameEvent) {
        events.insert(e, at: 0)
        if events.count > 500 { events.removeLast(events.count - 500) }
    }
}

public struct TownProgress: Sendable, Hashable {
    public var heldSegments: Int
    public var heldMetres: Double
    public var heldFraction: Double
    public var exploredFraction: Double
    public var blocksHeld: Int
    public var totalSegments: Int
}

public struct Standing: Sendable, Hashable, Identifiable {
    public var id: String { owner.id }
    public var owner: OwnerRef
    public var name: String
    public var colorHex: String
    public var streets: Int
    public var metres: Double
    public var blocks: Int
}
