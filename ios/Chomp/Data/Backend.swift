import Foundation
import ChompKit
import Supabase

enum LeaderboardScope: String, CaseIterable, Identifiable {
    /// Everyone holding streets within roughly 25 km (the same zoom-10 map square).
    case nearby, global, friends, club
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct LeaderboardEntry: Identifiable, Hashable {
    var id: String
    var rank: Int
    var name: String
    var colorHex: String
    var isBot: Bool
    var isMe: Bool
    /// Tokens captured (the dots on every street you've taken), all time.
    var tokens: Int
}

struct InviteInfo: Hashable {
    var code: String
    /// Friends who signed up with your code.
    var joined: Int
    /// Of those, how many have finished a run, earning you a month.
    var rewarded: Int
    /// Joined but haven't run yet.
    var pending: Int
    /// The code you yourself joined with, if any.
    var redeemedCode: String?
}

enum InviteCode {
    /// Codes are 6 letters/digits without look-alikes (no 0/O, 1/I/L).
    static let alphabet = Set("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    static func normalise(_ s: String) -> String { s.uppercased().filter { !$0.isWhitespace && $0 != "-" } }
    static func isValid(_ s: String) -> Bool { s.count == 6 && s.allSatisfy { alphabet.contains($0) } }
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

/// Your club: its tally (coins members collected while in it), rank and members.
struct MyClub: Hashable, Decodable {
    struct Member: Identifiable, Hashable, Decodable {
        var id: String
        var name: String
        var color_hex: String
        var role: String
        var tokens: Int
    }
    var id: String
    var name: String
    var color_hex: String
    var invite_code: String
    var role: String
    var tokens: Int
    var rank: Int
    var clubs: Int
    var members: [Member]
    var isOwner: Bool { role == "owner" }
}

enum ClubScope: String, CaseIterable, Identifiable {
    case nearby, global
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct ClubStanding: Identifiable, Hashable, Decodable {
    var club_id: String
    var name: String
    var color_hex: String
    var members: Int
    var tokens: Int
    var is_mine: Bool
    var id: String { club_id }
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

    /// Asks the server to build street tiles into the shared cache. Fire and forget:
    /// the app downloads its own copy meanwhile.
    func warmTiles(_ keys: [TileKey]) {
        guard let client else { return }
        struct Body: Encodable { let tiles: [String] }
        for group in stride(from: 0, to: keys.count, by: 9).map({ Array(keys[$0..<min($0 + 9, keys.count)]) }) {
            Task.detached(priority: .utility) {
                try? await client.functions.invoke("warm-tiles", options: FunctionInvokeOptions(body: Body(tiles: group.map(\.description))))
            }
        }
    }

    func restoreSession() async {
        guard let client else { return }
        userID = try? await client.auth.session.user.id.uuidString.lowercased()
    }

    func signInWithApple(idToken: String, nonce: String, displayName: String, colorHex: String) async throws {
        guard let client else { throw BackendError.notConfigured }
        let session = try await client.auth.signInWithIdToken(credentials: .init(provider: .apple, idToken: idToken, nonce: nonce))
        struct Upsert: Encodable { let id: String; let display_name: String; let color_hex: String }
        do {
            try await client.from("profiles").upsert(Upsert(id: session.user.id.uuidString, display_name: displayName, color_hex: colorHex)).execute()
        } catch {
            // No profile means no online play: don't leave a half-signed-in session behind.
            try? await client.auth.signOut()
            throw Self.isNameTaken(error) ? BackendError.nameTaken : error
        }
        userID = session.user.id.uuidString.lowercased()
    }

    /// Runner names are unique (ignoring case). nil when it can't be checked (offline, not set up).
    func nameAvailable(_ name: String) async -> Bool? {
        guard let client else { return nil }
        struct Params: Encodable { let p_name: String }
        return try? await client.rpc("name_available", params: Params(p_name: name)).execute().value
    }

    static func isNameTaken(_ error: Error) -> Bool {
        (error as? PostgrestError)?.code == "23505"
    }

    func signOut() async {
        try? await client?.auth.signOut()
        userID = nil
    }

    func registerPushToken(_ token: String, environment: String, kinds: [String]) async throws {
        guard let client else { throw BackendError.notConfigured }
        guard userID != nil else { throw BackendError.notSignedIn }
        struct Params: Encodable { let p_token: String; let p_environment: String; let p_kinds: [String] }
        try await client.rpc("register_push_token", params: Params(p_token: token, p_environment: environment, p_kinds: kinds)).execute()
    }

    func unregisterPushToken(_ token: String) async throws {
        guard let client, userID != nil else { return }
        struct Params: Encodable { let p_token: String }
        try await client.rpc("unregister_push_token", params: Params(p_token: token)).execute()
    }

    func updateProfile(name: String, colorHex: String, isPrivate: Bool) async throws {
        guard let client, let userID else { return }
        struct Patch: Encodable { let display_name: String; let color_hex: String; let is_private: Bool }
        do {
            try await client.from("profiles").update(Patch(display_name: name, color_hex: colorHex, is_private: isPrivate)).eq("id", value: userID).execute()
        } catch { throw Self.isNameTaken(error) ? BackendError.nameTaken : error }
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
        // The API returns at most 1,000 rows per request; busy areas hold more coins than that.
        let page = 1000
        var all: [ServerOwnershipRow] = []
        while true {
            let rows: [ServerOwnershipRow] = try await client.from("segment_ownership_public").select().in("tile", values: tiles)
                .order("segment_id").range(from: all.count, to: all.count + page - 1).execute().value
            all += rows
            if rows.count < page || all.count >= 50_000 { return all }
        }
    }

    /// Live ownership changes for the tiles on screen (Supabase Realtime).
    func ownershipChanges(tiles: [String]) -> AsyncStream<ServerOwnershipRow> {
        AsyncStream { continuation in
            guard let client else { continuation.finish(); return }
            let task = Task {
                let channel = client.channel("ownership:\(tiles.first ?? "")")
                let changes = channel.postgresChange(AnyAction.self, schema: "public", table: "segment_ownership_feed",
                                                     filter: .in("tile", values: tiles))
                do { try await channel.subscribeWithError() } catch { continuation.finish(); return }
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
        let tokens: Int
    }

    func leaderboard(scope: LeaderboardScope, tile: String) async throws -> [LeaderboardEntry] {
        guard let client else { throw BackendError.notConfigured }
        struct Params: Encodable { let p_scope: String; let p_tile: String }
        let rows: [LeaderRow] = try await client.rpc("leaderboard", params: Params(p_scope: scope.rawValue, p_tile: tile)).execute().value
        return rows.enumerated().map { i, r in
            LeaderboardEntry(id: r.user_id, rank: i + 1, name: r.display_name, colorHex: r.color_hex, isBot: r.user_id.hasPrefix("bot-"),
                             isMe: r.user_id == userID, tokens: r.tokens)
        }
    }

    // MARK: Invites (a free month of Pro for you and your friend)

    func myInvite() async throws -> InviteInfo {
        guard let client else { throw BackendError.notConfigured }
        guard userID != nil else { throw BackendError.notSignedIn }
        struct Row: Decodable { let code: String; let joined: Int; let rewarded: Int; let pending: Int; let redeemed_code: String? }
        let r: Row = try await client.rpc("my_invite").execute().value
        return InviteInfo(code: r.code, joined: r.joined, rewarded: r.rewarded, pending: r.pending, redeemedCode: r.redeemed_code)
    }

    /// Returns when the free Pro month granted to you ends.
    @discardableResult
    func redeemInvite(code: String) async throws -> Date {
        guard let client else { throw BackendError.notConfigured }
        guard userID != nil else { throw BackendError.notSignedIn }
        struct Params: Encodable { let p_code: String }
        let until: Date = try await client.rpc("redeem_invite", params: Params(p_code: code)).execute().value
        return until
    }

    /// End of the free Pro earned through invites, if any.
    func invitePremiumUntil() async throws -> Date? {
        guard let client, let userID else { return nil }
        struct Row: Decodable { let expires_at: Date? }
        let rows: [Row] = try await client.from("entitlements").select("expires_at")
            .eq("user_id", value: userID).eq("entitlement", value: "pro_invite").execute().value
        return rows.first?.expires_at
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

    func myClub() async throws -> MyClub? {
        guard let client, userID != nil else { return nil }
        let c: MyClub? = try await client.rpc("my_club").execute().value
        return c
    }

    func clubLeaderboard(scope: ClubScope, tile: String) async throws -> [ClubStanding] {
        guard let client else { throw BackendError.notConfigured }
        guard userID != nil else { throw BackendError.notSignedIn }
        struct P: Encodable { let p_scope: String; let p_tile: String }
        return try await client.rpc("club_leaderboard", params: P(p_scope: scope.rawValue, p_tile: tile)).execute().value
    }

    func leaveClub() async throws {
        guard let client else { throw BackendError.notConfigured }
        try await client.rpc("leave_club").execute()
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
        // Run traces live in Storage, which the database can't delete: remove them first.
        if let userID {
            let traces = client.storage.from("traces")
            for _ in 0..<50 {
                let files = try await traces.list(path: userID, options: SearchOptions(limit: 1000))
                guard !files.isEmpty else { break }
                _ = try await traces.remove(paths: files.map { "\(userID)/\($0.name)" })
            }
        }
        try await client.rpc("delete_own_account").execute()
        await signOut()
    }
}

enum BackendError: LocalizedError {
    case notConfigured, notSignedIn, nameTaken
    var errorDescription: String? {
        switch self {
        case .nameTaken: "Someone already uses that runner name. Pick another one."
        case .notConfigured: "Online play isn't set up in this build yet. Solo play works fully offline."
        case .notSignedIn: "Sign in with Apple to play online."
        }
    }
}
