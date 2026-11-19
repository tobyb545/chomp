import Foundation
import ChompKit

/// Street data for anywhere in the world, one map tile at a time. Tiles come
/// prebuilt from Cloudflare R2 where we have them (Great Britain), otherwise
/// they're built on device from OpenStreetMap via the free Overpass API. Either
/// way they're kept in Application Support, so places you've been work offline.
actor WorldStore {
    static let shared = WorldStore()

    enum WorldError: LocalizedError {
        case offline, busy, bad(String)
        var errorDescription: String? {
            switch self {
            case .offline: "Couldn't download the map here. Check your connection and try again."
            case .busy: "The free map server is busy. Chomp will try again in a moment."
            case .bad(let s): "Couldn't read the map data (\(s))."
            }
        }
    }

    /// Public Overpass instances, tried in order. All are free; their fair-use
    /// policies are fine for a phone fetching a few tiles at a time.
    private let endpoints = [
        URL(string: "https://overpass-api.de/api/interpreter")!,
        URL(string: "https://overpass.kumi.systems/api/interpreter")!,
        URL(string: "https://maps.mail.ru/osm/tools/overpass/api/interpreter")!,
    ]
    /// OSM changes slowly; refresh a tile after a month (keeping the old copy if offline).
    private let maxAge: TimeInterval = 30 * 86_400

    private var memory: [TileKey: TileFile] = [:]
    /// Downloads under way, shared by every caller that wants the same tiles. A
    /// caller that moves on (the map was panned) doesn't cancel them, so the
    /// tiles still arrive and are saved.
    private var inFlight: [TileKey: Task<[TileKey: TileFile], Error>] = [:]
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        // Overpass sends nothing until the whole answer is ready, which often takes
        // 40-60 s, so a shorter idle timeout gives up on requests that would have worked.
        c.timeoutIntervalForRequest = 100
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

    /// Returns the tiles, downloading the missing ones (one Overpass request per
    /// 3x3 group, much faster than one each). Falls back to stale copies offline.
    func tiles(_ keys: [TileKey]) async throws -> [TileKey: TileFile] {
        var out: [TileKey: TileFile] = [:]
        var missing: [TileKey] = []
        for k in keys {
            if isFresh(k), let t = cached([k]).first { out[k] = t } else { missing.append(k) }
        }
        // Prebuilt tiles first (Cloudflare R2), then the server's cache, then Overpass.
        let toCheck = missing.filter { inFlight[$0] == nil }
        if !toCheck.isEmpty, let shared = await fromSharedCache(toCheck) {
            for (k, t) in shared { remember(t, k); out[k] = t }
            missing.removeAll { shared[$0] != nil }
        }
        let start = missing.filter { inFlight[$0] == nil }
        // Ask the server to build these too, so the next player here gets them from the cache.
        if !start.isEmpty { SupabaseBackend.shared.warmTiles(start) }
        for group in stride(from: 0, to: start.count, by: 9).map({ Array(start[$0..<min($0 + 9, start.count)]) }) {
            let task = Task { () throws -> [TileKey: TileFile] in
                defer { for k in group where inFlight[k] != nil { inFlight[k] = nil } }
                let built = try await download(group)
                for (k, t) in built { remember(t, k) }
                return built
            }
            for k in group { inFlight[k] = task }
        }
        var lastError: Error?
        for task in Set(missing.compactMap { inFlight[$0] }) {
            do {
                let built = try await task.value
                for k in missing { if let t = built[k] { out[k] = t } }
            } catch {
                lastError = error
            }
        }
        try Task.checkCancellation()
        // Anything still missing: an old copy beats nothing.
        for k in missing where out[k] == nil {
            if let t = cached([k]).first { out[k] = t }
        }
        if let lastError, out.isEmpty { throw lastError }
        return out
    }

    private func remember(_ t: TileFile, _ k: TileKey) {
        memory[k] = t
        if let d = try? JSONEncoder().encode(t) { try? d.write(to: url(k), options: .atomic) }
    }

    /// Where prebuilt tiles live: built monthly from an OpenStreetMap extract by
    /// tools/tiles (see .github/workflows/tiles.yml) and served from Cloudflare R2.
    static let prebuiltTilesURL: URL? = {
        guard let s = Bundle.main.infoDictionary?["ChompTilesURL"] as? String, s.hasPrefix("https://"),
              let u = URL(string: s) else { return nil }
        return u.appendingPathComponent("v\(TileFile.currentFormat)")
    }()

    /// Tiles built elsewhere with the same builder, so interchangeable with our
    /// own: the prebuilt set first, then the server's public `tiles` bucket.
    private func fromSharedCache(_ keys: [TileKey]) async -> [TileKey: TileFile]? {
        var out: [TileKey: TileFile] = [:]
        for base in [Self.prebuiltTilesURL, SupabaseBackend.shared.publicTilesURL].compactMap({ $0 }) {
            let left = keys.filter { out[$0] == nil }
            if left.isEmpty { break }
            out.merge(await fetchTiles(left, from: base)) { a, _ in a }
        }
        return out.isEmpty ? nil : out
    }

    private func fetchTiles(_ keys: [TileKey], from base: URL) async -> [TileKey: TileFile] {
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
        return out
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
