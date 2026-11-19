import Foundation
import ChompKit
import Supabase

enum LeaderboardScope: String, CaseIterable, Identifiable {
    /// Everyone holding streets within roughly 25 km (the same zoom-10 map square).
    case nearby, global, friends, club
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum LeaderboardMetric: String, CaseIterable, Identifiable {
    case streets, km, blocks
    var id: String { rawValue }
    var label: String {
        switch self { case .streets: "Streets"; case .km: "km held"; case .blocks: "Blocks" }
    }
}

struct LeaderboardEntry: Identifiable, Hashable {
    var id: String
    var rank: Int
    var name: String
    var colorHex: String
    var isBot: Bool
    var isMe: Bool
    var streets: Int
    var metres: Double
    var blocks: Int

    func value(_ m: LeaderboardMetric) -> Double {
        switch m { case .streets: Double(streets); case .km: metres / 1000; case .blocks: Double(blocks) }
    }
}

struct RivalInfo: Hashable, Codable {
    var name: String
    var colorHex: String
}

struct Club: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var colorHex: String
    var members: Int
    var inviteCode: String?
}

struct Friend: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var colorHex: String
    var streets: Int
}

/// Run sent to the server for authoritative resolution. The trace has already
/// been privacy-trimmed on device.
struct RunUpload: Codable {
    var runId: UUID
    var startedAt: Date
    var endedAt: Date
    var source: String
    var polyline: String
    var timestamps: [Double]
    var accuracies: [Double]
    var speeds: [Double]
    var signals: RunSignals
    var clientVersion: String
}

struct ServerOwnershipRow: Codable {
    var segment_id: String
    var owner_kind: String
    var owner_id: String
    var owner_name: String
    var owner_color: String
    var captured_at: Date
    var last_visited_at: Date
}

/// Online play. Everything that changes ownership goes through the resolve-run
/// Edge Function; the client never writes ownership itself.
final class SupabaseBackend: @unchecked Sendable {
    static let shared = SupabaseBackend()

    let client: SupabaseClient?
    private let lock = NSLock()
    private var _userID: String?
    private(set) var userID: String? {
        get { lock.withLock { _userID } }
        set { lock.withLock { _userID = newValue } }
    }

    var isConfigured: Bool { client != nil }
    /// Public bucket of server-built street tiles (see backend _shared/world.ts).
    let publicTilesURL: URL?
    var isSignedIn: Bool { userID != nil }

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let url = (info["SupabaseURL"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        let key = (info["SupabaseAnonKey"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let url, let key, url.host != nil {
            client = SupabaseClient(supabaseURL: url, supabaseKey: key)
            publicTilesURL = url.appendingPathComponent("storage/v1/object/public/tiles")
        } else {
            client = nil
            publicTilesURL = nil
        }
    }

    func restoreSession() async {
        guard let client else { return }
        userID = try? await client.auth.session.user.id.uuidString.lowercased()
    }

    func signInWithApple(idToken: String, nonce: String, displayName: String, colorHex: String) async throws {
        guard let client else { throw BackendError.notConfigured }
        let session = try await client.auth.signInWithIdToken(credentials: .init(provider: .apple, idToken: idToken, nonce: nonce))
        userID = session.user.id.uuidString.lowercased()
        struct Upsert: Encodable { let id: String; let display_name: String; let color_hex: String }
        try await client.from("profiles").upsert(Upsert(id: session.user.id.uuidString, display_name: displayName, color_hex: colorHex)).execute()
    }

    func signOut() async {
        try? await client?.auth.signOut()
        userID = nil
    }

    func updateProfile(name: String, colorHex: String, isPrivate: Bool) async throws {
        guard let client, let userID else { return }
        struct Patch: Encodable { let display_name: String; let color_hex: String; let is_private: Bool }
        try await client.from("profiles").update(Patch(display_name: name, color_hex: colorHex, is_private: isPrivate)).eq("id", value: userID).execute()
    }

    struct ResolveResponse: Decodable {
        let status: String
        let outcome: RunOutcome?
    }

    func submit(_ upload: RunUpload) async throws -> ResolveResponse {
        guard let client else { throw BackendError.notConfigured }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try await client.functions.invoke(
            "resolve-run",
            options: FunctionInvokeOptions(body: try encoder.encode(upload)),
            decoder: decoder)
    }

    func ownership(tiles: [String]) async throws -> [ServerOwnershipRow] {
        guard let client else { throw BackendError.notConfigured }
        return try await client.from("segment_ownership_public").select().in("tile", values: tiles).execute().value
    }

    /// Live ownership changes for the tiles on screen (Supabase Realtime).
    func ownershipChanges(tiles: [String]) -> AsyncStream<ServerOwnershipRow> {
        AsyncStream { continuation in
            guard let client else { continuation.finish(); return }
            let task = Task {
                let channel = client.channel("ownership:\(tiles.first ?? "")")
                let list = tiles.map { "\"\($0)\"" }.joined(separator: ",")
                let changes = channel.postgresChange(AnyAction.self, schema: "public", table: "segment_ownership_feed", filter: "tile=in.(\(list))")
                await channel.subscribe()
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                for await change in changes {
                    if case .insert(let a) = change, let row = try? a.decodeRecord(as: ServerOwnershipRow.self, decoder: decoder) {
                        continuation.yield(row)
                    } else if case .update(let a) = change, let row = try? a.decodeRecord(as: ServerOwnershipRow.self, decoder: decoder) {
                        continuation.yield(row)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    struct LeaderRow: Decodable {
        let user_id: String
        let display_name: String
        let color_hex: String
        let streets_held: Int
        let metres_held: Double
        let blocks_held: Int
    }

    func leaderboard(scope: LeaderboardScope, tile: String) async throws -> [LeaderboardEntry] {
        guard let client else { throw BackendError.notConfigured }
        struct Params: Encodable { let p_scope: String; let p_tile: String }
        let rows: [LeaderRow] = try await client.rpc("leaderboard", params: Params(p_scope: scope.rawValue, p_tile: tile)).execute().value
        return rows.enumerated().map { i, r in
            LeaderboardEntry(id: r.user_id, rank: i + 1, name: r.display_name, colorHex: r.color_hex, isBot: false,
                             isMe: r.user_id == userID, streets: r.streets_held, metres: r.metres_held, blocks: r.blocks_held)
        }
    }

    func clubs() async throws -> [Club] {
        guard let client else { throw BackendError.notConfigured }
        struct Row: Decodable { let id: String; let name: String; let color_hex: String; let member_count: Int; let invite_code: String? }
        let rows: [Row] = try await client.rpc("my_clubs").execute().value
        return rows.map { Club(id: $0.id, name: $0.name, colorHex: $0.color_hex, members: $0.member_count, inviteCode: $0.invite_code) }
    }

    func createClub(name: String, colorHex: String) async throws {
        guard let client else { throw BackendError.notConfigured }
        struct P: Encodable { let p_name: String; let p_color: String }
        try await client.rpc("create_club", params: P(p_name: name, p_color: colorHex)).execute()
    }

    func joinClub(code: String) async throws {
        guard let client else { throw BackendError.notConfigured }
        struct P: Encodable { let p_code: String }
        try await client.rpc("join_club", params: P(p_code: code)).execute()
    }

    func friends() async throws -> [Friend] {
        guard let client else { throw BackendError.notConfigured }
        struct Row: Decodable { let id: String; let display_name: String; let color_hex: String; let streets_held: Int }
        let rows: [Row] = try await client.rpc("my_friends").execute().value
        return rows.map { Friend(id: $0.id, name: $0.display_name, colorHex: $0.color_hex, streets: $0.streets_held) }
    }

    func addFriend(handle: String) async throws {
        guard let client else { throw BackendError.notConfigured }
        struct P: Encodable { let p_handle: String }
        try await client.rpc("request_friend", params: P(p_handle: handle)).execute()
    }

    func report(player: String, reason: String, notes: String) async throws {
        guard let client, let userID else { throw BackendError.notSignedIn }
        struct Row: Encodable { let reporter_id: String; let reported_user_id: String; let reason: String; let notes: String }
        try await client.from("reports").insert(Row(reporter_id: userID, reported_user_id: player, reason: reason, notes: notes)).execute()
    }

    func block(player: String, mute: Bool) async throws {
        guard let client, let userID else { throw BackendError.notSignedIn }
        struct Row: Encodable { let user_id: String; let target_id: String; let kind: String }
        try await client.from("user_relations").upsert(Row(user_id: userID, target_id: player, kind: mute ? "mute" : "block")).execute()
    }

    struct StravaImportResult: Decodable { let imported: Int; let streets: Int; let more: Bool }

    func importStrava(code: String?) async throws -> StravaImportResult {
        guard let client else { throw BackendError.notConfigured }
        struct Body: Encodable { let code: String? }
        return try await client.functions.invoke("strava-import", options: FunctionInvokeOptions(body: Body(code: code)))
    }

    struct CoverageRow: Decodable { let segment_id: String; let first_at: Date; let last_at: Date; let times_run: Int; let source: String }

    /// Streets this player has explored according to the server (live runs + imports).
    func personalCoverage() async throws -> [CoverageRow] {
        guard let client else { throw BackendError.notConfigured }
        return try await client.from("personal_coverage").select("segment_id, first_at, last_at, times_run, source").execute().value
    }

    func deleteAccount() async throws {
        guard let client else { throw BackendError.notConfigured }
        try await client.rpc("delete_own_account").execute()
        await signOut()
    }
}

enum BackendError: LocalizedError {
    case notConfigured, notSignedIn
    var errorDescription: String? {
        switch self {
        case .notConfigured: "Online play isn't set up in this build yet. Solo play and bots work fully offline."
        case .notSignedIn: "Sign in with Apple to play online."
        }
    }
}
