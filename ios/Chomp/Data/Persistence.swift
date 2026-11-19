import Foundation
import ChompKit

/// Player profile + preferences. Small, so UserDefaults-backed JSON.
struct PlayerProfile: Codable, Hashable {
    var id: String = UUID().uuidString
    var name: String = ""
    var colorHex: String = PlayerPalette.swatches[0].hex
    var homeArea: String = "west-byfleet"
    var onboarded = false
    var privateMode = false
    var soundOn = true
    var hapticsOn = true
    var useMiles = false
    var trailStyle: TrailStyle = .solid
    var privacyZones: [PrivacyZone] = []
    var dismissedZoneSuggestions: [Coordinate] = []
    var blockedPlayers: [String] = []
    var mutedPlayers: [String] = []
    var debugPro = false
    /// The swipeable "how it works" cards have been shown.
    var seenIntro = false
    var mapLook: MapLook = .dusk
    /// Spoken updates during runs, and whether they include splits.
    var voiceOn = false
    var voiceSplits = true
    /// Push notifications when a rival takes your coins, and when bots raid.
    var pushLost = true
    var pushRaids = true
    /// Health workouts already offered for import (so declined runs aren't offered again).
    var healthOffered: [UUID] = []
    /// Losses before this have been shown in the "under attack" banner.
    var attacksSeenAt: Date?
    /// Badge id → when it was earned.
    var badgesEarned: [String: Date] = [:]
    /// Set once existing achievements have been awarded quietly (so updating doesn't flood unlocks).
    var badgesSeeded = false
    /// Sticky: has been in a club (for the Team player badge).
    var joinedClub = false
    /// Invite code typed in (or opened from a link) before signing in.
    var pendingInviteCode: String?

    /// How bright the map underneath the game is.
    enum MapLook: String, Codable, CaseIterable, Identifiable {
        case light, dusk, dark
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    enum TrailStyle: String, Codable, CaseIterable, Identifiable {
        case solid, dotted, comet
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var isPro: Bool { self != .solid }
    }

    init() {}

    /// Field by field, so a profile saved by an older build (missing newer
    /// fields) keeps everything it has instead of resetting.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ k: CodingKeys, _ into: inout T) { if let v = try? c.decode(T.self, forKey: k) { into = v } }
        get(.id, &id); get(.name, &name); get(.colorHex, &colorHex); get(.homeArea, &homeArea); get(.onboarded, &onboarded)
        get(.privateMode, &privateMode); get(.soundOn, &soundOn); get(.hapticsOn, &hapticsOn); get(.useMiles, &useMiles)
        get(.trailStyle, &trailStyle); get(.privacyZones, &privacyZones); get(.dismissedZoneSuggestions, &dismissedZoneSuggestions)
        get(.blockedPlayers, &blockedPlayers); get(.mutedPlayers, &mutedPlayers); get(.debugPro, &debugPro)
        get(.mapLook, &mapLook); get(.voiceOn, &voiceOn); get(.voiceSplits, &voiceSplits)
        get(.pushLost, &pushLost); get(.pushRaids, &pushRaids); get(.healthOffered, &healthOffered)
        attacksSeenAt = try? c.decodeIfPresent(Date.self, forKey: .attacksSeenAt)
        get(.badgesEarned, &badgesEarned); get(.badgesSeeded, &badgesSeeded); get(.joinedClub, &joinedClub)
        pendingInviteCode = try? c.decodeIfPresent(String.self, forKey: .pendingInviteCode)
        get(.seenIntro, &seenIntro)  // existing players see the cards once too
    }

    private static let key = "chomp.profile.v1"

    static func load() -> PlayerProfile {
        guard let d = UserDefaults.standard.data(forKey: key), let p = try? JSONDecoder().decode(PlayerProfile.self, from: d) else {
            return PlayerProfile()
        }
        return p
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key) }
    }
}

/// A finished run as stored on device. Raw trace kept locally only.
struct RunRecord: Codable, Identifiable, Hashable {
    var id: UUID
    var areaSlug: String
    var startedAt: Date
    var endedAt: Date
    var distance: Double
    var movingTime: TimeInterval
    var source: Source
    var outcome: RunOutcome
    var splits: [SplitRecord]
    var simulated: Bool
    /// Untrimmed first/last fix. Stays on this phone; only used to suggest privacy zones.
    var rawEndpoints: [Coordinate]? = nil
    /// Tokens earned (nil for runs saved before tokens existed).
    var tokens: Int? = nil

    /// fileImport: a GPX/TCX/FIT file. healthImport is no longer created (kept so old runs load).
    enum Source: String, Codable { case live, healthImport, stravaImport, fileImport }

    struct SplitRecord: Codable, Hashable { var distance: Double; var duration: TimeInterval }
}

/// File-backed stores in Application Support. JSON keeps it inspectable and the
/// whole state is only a few hundred KB even for a heavily-played town.
actor LocalStore {
    static let shared = LocalStore()

    private let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Chomp", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    func loadState(area: String) -> GameState? {
        guard let d = try? Data(contentsOf: url("state-\(area).json")) else { return nil }
        return try? JSONDecoder.chomp.decode(GameState.self, from: d)
    }

    func saveState(_ s: GameState) {
        if let d = try? JSONEncoder.chomp.encode(s) { try? d.write(to: url("state-\(s.areaSlug).json"), options: .atomic) }
    }

    func loadRuns() -> [RunRecord] {
        guard let d = try? Data(contentsOf: url("runs.json")) else { return [] }
        return (try? JSONDecoder.chomp.decode([RunRecord].self, from: d)) ?? []
    }

    func saveRuns(_ runs: [RunRecord]) {
        if let d = try? JSONEncoder.chomp.encode(runs) { try? d.write(to: url("runs.json"), options: .atomic) }
    }

    func saveTrace(_ trace: [TracePoint], run: UUID) {
        if let d = try? JSONEncoder.chomp.encode(trace) {
            try? d.write(to: url("trace-\(run.uuidString).json"), options: [.atomic, .completeFileProtection])
        }
    }

    func loadTrace(run: UUID) -> [TracePoint] {
        guard let d = try? Data(contentsOf: url("trace-\(run.uuidString).json")) else { return [] }
        return (try? JSONDecoder.chomp.decode([TracePoint].self, from: d)) ?? []
    }

    func deleteEverything() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

extension JSONEncoder {
    static var chomp: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }
}

extension JSONDecoder {
    static var chomp: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}
