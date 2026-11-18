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

    enum TrailStyle: String, Codable, CaseIterable, Identifiable {
        case solid, dotted, comet
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var isPro: Bool { self != .solid }
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

    enum Source: String, Codable { case live, healthImport, stravaImport }

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
