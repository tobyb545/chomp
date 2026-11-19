import Foundation
import ChompKit

/// Street data for anywhere in the world, one map tile at a time. Tiles are
/// built on device from OpenStreetMap (via the free Overpass API) and kept in
/// Application Support, so places you've been keep working offline.
actor WorldStore {
    static let shared = WorldStore()

    enum WorldError: LocalizedError {
        case offline, busy, bad(String)
        var errorDescription: String? {
            switch self {
            case .offline: "Couldn't download streets here. Check your connection and try again."
            case .busy: "The free map server is busy. Chomp will try again in a moment."
            case .bad(let s): "Couldn't read the street data (\(s))."
            }
        }
    }

    /// Public Overpass instances, tried in order. All are free; their fair-use
    /// policies are fine for a phone fetching a few tiles at a time.
    private let endpoints = [
        URL(string: "https://overpass-api.de/api/interpreter")!,
        URL(string: "https://overpass.private.coffee/api/interpreter")!,
        URL(string: "https://maps.mail.ru/osm/tools/overpass/api/interpreter")!,
    ]
    /// OSM changes slowly; refresh a tile after a month (keeping the old copy if offline).
    private let maxAge: TimeInterval = 30 * 86_400

    private var memory: [TileKey: TileFile] = [:]
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 35  // public mirrors stall sometimes; move on to the next
        c.httpAdditionalHeaders = ["User-Agent": "Chomp/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1") (iOS street game)"]
        return URLSession(configuration: c)
    }()

    private let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Chomp/tiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private func url(_ k: TileKey) -> URL { dir.appendingPathComponent("\(k.fileName).json") }

    /// Tiles already on this phone, without touching the network.
    func cached(_ keys: [TileKey]) -> [TileFile] {
        keys.compactMap { k in
            if let t = memory[k] { return t }
            guard let d = try? Data(contentsOf: url(k)), let t = try? JSONDecoder().decode(TileFile.self, from: d),
                  t.formatVersion == TileFile.currentFormat else { return nil }
            memory[k] = t
            return t
        }
    }

    func isFresh(_ k: TileKey) -> Bool {
        guard memory[k] != nil || FileManager.default.fileExists(atPath: url(k).path) else { return false }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url(k).path)
        let modified = attrs?[.modificationDate] as? Date ?? .distantPast
        return Date().timeIntervalSince(modified) < maxAge
    }

    /// Returns the tile, downloading and building it if needed.
    func tile(_ k: TileKey) async throws -> TileFile {
        guard let t = try await tiles([k])[k] else { throw WorldError.offline }
        return t
    }

    /// Returns the tiles, downloading all the missing ones in a single Overpass
    /// request (much faster than one each). Falls back to stale copies offline.
    func tiles(_ keys: [TileKey]) async throws -> [TileKey: TileFile] {
        var out: [TileKey: TileFile] = [:]
        var missing: [TileKey] = []
        for k in keys {
            if isFresh(k), let t = cached([k]).first { out[k] = t } else { missing.append(k) }
        }
        // Our own tile cache first (filled by the server), then Overpass.
        if !missing.isEmpty, let shared = await fromSharedCache(missing) {
            for (k, t) in shared { remember(t, k); out[k] = t }
            missing.removeAll { shared[$0] != nil }
        }
        // Overpass gets slow with huge boxes; 3x3 tiles (~5 km) per request is plenty.
        for group in stride(from: 0, to: missing.count, by: 9).map({ Array(missing[$0..<min($0 + 9, missing.count)]) }) {
            do {
                let built = try await download(group)
                for (k, t) in built { remember(t, k); out[k] = t }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let stale = cached(group)
                for t in stale { if let k = TileKey(string: t.key) { out[k] = t } }
                if stale.count < group.count, out.isEmpty { throw error }
            }
        }
        return out
    }

    private func remember(_ t: TileFile, _ k: TileKey) {
        memory[k] = t
        if let d = try? JSONEncoder().encode(t) { try? d.write(to: url(k), options: .atomic) }
    }

    /// Tiles the server already built, from the public `tiles` Storage bucket.
    /// Same format and same builder, so they're interchangeable with our own.
    private func fromSharedCache(_ keys: [TileKey]) async -> [TileKey: TileFile]? {
        guard let base = SupabaseBackend.shared.publicTilesURL else { return nil }
        var out: [TileKey: TileFile] = [:]
        await withTaskGroup(of: (TileKey, TileFile?).self) { g in
            for k in keys {
                g.addTask { [session] in
                    var req = URLRequest(url: base.appendingPathComponent("\(k.fileName).json"))
                    req.timeoutInterval = 10
                    guard let (d, r) = try? await session.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200,
                          let t = try? JSONDecoder().decode(TileFile.self, from: d), t.formatVersion == TileFile.currentFormat,
                          t.key == k.description else { return (k, nil) }
                    return (k, t)
                }
            }
            for await (k, t) in g { if let t { out[k] = t } }
        }
        return out.isEmpty ? nil : out
    }

    private func download(_ keys: [TileKey]) async throws -> [TileKey: TileFile] {
        let body = "data=" + (StreetBuilder.overpassQuery(for: keys)
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
        var lastError: Error = WorldError.offline
        for (attempt, endpoint) in endpoints.enumerated() {
            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(body.utf8)
            do {
                let (data, response) = try await session.data(for: req)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code == 429 || code == 504 || code == 503 {
                    lastError = WorldError.busy
                    try? await Task.sleep(for: .seconds(1 + attempt))
                    continue
                }
                guard code == 200 else { lastError = WorldError.bad("HTTP \(code)"); continue }
                let osm: OverpassResponse
                do { osm = try JSONDecoder().decode(OverpassResponse.self, from: data) } catch {
                    lastError = WorldError.bad("unexpected response")
                    continue
                }
                return await Task.detached(priority: .userInitiated) {
                    var built: [TileKey: TileFile] = [:]
                    for k in keys { built[k] = StreetBuilder.buildTile(k, osm: keys.count == 1 ? osm : StreetBuilder.subset(osm, for: k)) }
                    return built
                }.value
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = (error as? URLError)?.code == .notConnectedToInternet ? WorldError.offline : error
            }
        }
        throw lastError
    }

    func deleteAll() {
        memory = [:]
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}
