import Foundation
import SwiftUI
#if canImport(ActivityKit) && os(iOS)
import ActivityKit
#endif

/// Shared between the app, widgets and watch.
enum AppGroup {
    static let id = "group.com.tobyb545.chomp"
    static var defaults: UserDefaults { UserDefaults(suiteName: id) ?? .standard }
    static var containerURL: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
}

/// What widgets show. Written by the app whenever the game state changes.
struct WidgetSnapshot: Codable, Hashable {
    struct Pellet: Codable, Hashable {
        var name: String
        var kind: String
        var collected: Bool
    }
    struct Attack: Codable, Hashable {
        var street: String
        var by: String
    }
    var townName: String
    var playerColorHex: String
    var streetsHeld: Int
    var kmHeld: Double
    var townPercent: Double
    var blocksHeld: Int
    var underAttack: [Attack]
    var fadingSoon: Int
    var pellets: [Pellet]
    var bonusLabels: [String]
    var updatedAt: Date

    static let placeholder = WidgetSnapshot(
        townName: "West Byfleet", playerColorHex: "C6FF00", streetsHeld: 42, kmHeld: 6.3, townPercent: 0.041, blocksHeld: 2,
        underAttack: [Attack(street: "Old Woking Road", by: "Bot Rook"), Attack(street: "Station Approach", by: "Bot Moth")],
        fadingSoon: 5,
        pellets: [Pellet(name: "West Byfleet", kind: "station", collected: false),
                  Pellet(name: "All Saints Church", kind: "worship", collected: true),
                  Pellet(name: "Woodham Lodge Open Space", kind: "park", collected: false)],
        bonusLabels: ["Station Road: 3× until 8am"], updatedAt: .now)

    private static var url: URL { AppGroup.containerURL.appendingPathComponent("widget-snapshot.json") }

    static func load() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: Self.url, options: .atomic) }
    }
}

#if canImport(ActivityKit) && os(iOS)
struct ChompRunAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var pelletsEaten: Int
        var streetsCaptured: Int
        var streetsStolen: Int
        var distanceMetres: Double
        var frenzyEndsAt: Date?
        var isPaused: Bool
    }
    var startedAt: Date
    var playerColorHex: String
    var townName: String
}
#endif

/// Phone ⇄ watch messages (WatchConnectivity dictionaries).
enum WatchMessage {
    static let command = "cmd"          // "start" | "stop"
    static let running = "running"      // Bool
    static let startedAt = "startedAt"  // TimeInterval since 1970
    static let streets = "streets"      // Int
    static let pellets = "pellets"      // Int
    static let distance = "distance"    // Double metres
    static let frenzyEndsAt = "frenzyEndsAt" // TimeInterval, 0 = none
    static let capture = "capture"      // String street name (haptic ping)
    static let colorHex = "color"
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(.sRGB, red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}

/// Neon player colours. Original palette; names are our own.
enum PlayerPalette {
    struct Swatch: Identifiable, Hashable { var id: String { hex }; let name: String; let hex: String }
    static let swatches: [Swatch] = [
        .init(name: "Volt", hex: "C6FF00"),
        .init(name: "Ice", hex: "00E5FF"),
        .init(name: "Flare", hex: "FF2BD6"),
        .init(name: "Ember", hex: "FF8A00"),
        .init(name: "Laser", hex: "FF3355"),
        .init(name: "Ultra", hex: "8B5CFF"),
        .init(name: "Mint", hex: "2BFFA8"),
        .init(name: "Sun", hex: "FFD600"),
    ]
    static func name(for hex: String) -> String {
        swatches.first { $0.hex.caseInsensitiveCompare(hex) == .orderedSame }?.name ?? "Custom"
    }
}
