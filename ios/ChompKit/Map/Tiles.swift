import CryptoKit
import Foundation

/// The world is split into slippy-map tiles at zoom 14 (about 1.5 km across in
/// the UK). Street data is built per tile, on demand, from OpenStreetMap, so the
/// game works anywhere instead of only inside bundled towns.
public struct TileKey: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public static let zoom = 14
    public let x: Int
    public let y: Int

    public init(x: Int, y: Int) { self.x = x; self.y = y }

    public init(containing c: Coordinate) {
        let n = Double(1 << Self.zoom)
        let latR = c.latitude * .pi / 180
        x = Int(((c.longitude + 180) / 360 * n).rounded(.down))
        y = Int(((1 - log(tan(latR) + 1 / cos(latR)) / .pi) / 2 * n).rounded(.down))
    }

    public init?(string: String) {
        let p = string.split(separator: "/").compactMap { Int($0) }
        guard p.count == 3, p[0] == Self.zoom else { return nil }
        x = p[1]; y = p[2]
    }

    /// "14/x/y"
    public var description: String { "\(Self.zoom)/\(x)/\(y)" }
    public var fileName: String { "\(Self.zoom)_\(x)_\(y)" }

    static func lon(_ x: Int) -> Double { Double(x) / Double(1 << zoom) * 360 - 180 }
    static func lat(_ y: Int) -> Double {
        let n = Double.pi * (1 - 2 * Double(y) / Double(1 << zoom))
        return atan(sinh(n)) * 180 / .pi
    }

    public var west: Double { Self.lon(x) }
    public var east: Double { Self.lon(x + 1) }
    public var north: Double { Self.lat(y) }
    public var south: Double { Self.lat(y + 1) }
    public var center: Coordinate { Coordinate(latitude: (north + south) / 2, longitude: (west + east) / 2) }

    public func contains(_ c: Coordinate) -> Bool { TileKey(containing: c) == self }

    /// This tile and the ring of tiles around it, `radius` deep, sorted.
    public func neighbourhood(radius: Int = 1) -> [TileKey] {
        var out: [TileKey] = []
        for dx in -radius...radius { for dy in -radius...radius { out.append(TileKey(x: x + dx, y: y + dy)) } }
        return out.sorted()
    }

    public static func < (a: TileKey, b: TileKey) -> Bool { a.description < b.description }

    /// Tiles needed to resolve a trace: every tile within `margin` of a point.
    /// Streets belong to the tile holding their midpoint, so a run near a tile
    /// edge can cover a street owned by the next tile. Only a street over 500 m
    /// long, run at its far end, can be missed. The server uses the same rule.
    public static func covering(_ coords: [Coordinate], margin: Double = 250) -> [TileKey] {
        var set = Set<TileKey>()
        for c in coords {
            for (dx, dy) in [(0.0, 0.0), (1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)] {
                let p = Coordinate(latitude: c.latitude + dy * margin / 110_540,
                                   longitude: c.longitude + dx * margin / (111_320 * cos(c.latitude * .pi / 180)))
                set.insert(TileKey(containing: p))
            }
        }
        return set.sorted()
    }
}

/// One tile of playable streets, as built by `StreetBuilder` (and by the server's
/// port of it in backend/supabase/functions/_shared/chomp/tiles.ts).
public struct TileFile: Codable, Sendable {
    public static let currentFormat = 1
    public let formatVersion: Int
    public let key: String
    public let generatedAt: String
    public let osmTimestamp: String
    public let segments: [AreaFile.SegmentRecord]
    public let blocks: [AreaFile.BlockRecord]
    public let pois: [AreaFile.POIRecord]
}

/// Minimal Overpass API JSON.
public struct OverpassResponse: Decodable, Sendable {
    public struct Element: Decodable, Sendable {
        public struct Center: Decodable, Sendable { public let lat: Double; public let lon: Double }
        public let type: String
        public let id: Int64
        public let lat: Double?
        public let lon: Double?
        public let nodes: [Int64]?
        public let tags: [String: String]?
        public let center: Center?
    }
    public struct Meta: Decodable, Sendable { public let timestamp_osm_base: String? }
    public let osm3s: Meta?
    public let elements: [Element]
    public init(osm3s: Meta?, elements: [Element]) { self.osm3s = osm3s; self.elements = elements }
}

/// Turns OpenStreetMap highways into game segments: stretches of runnable street
/// between two junctions, each with a stable ID derived from its OSM nodes. Also
/// traces city blocks and picks landmark POIs. A straight port of
/// tools/ingest/ingest.py, so IDs match the ones the old town files used.
public enum StreetBuilder {
    public static let bufferMetres = 400.0
    static let roadClasses: Set<String> = [
        "trunk", "trunk_link", "primary", "primary_link", "secondary", "secondary_link",
        "tertiary", "tertiary_link", "unclassified", "residential", "living_street", "service",
    ]
    static let pathClasses: Set<String> = ["pedestrian", "footway", "path", "track", "cycleway", "steps", "bridleway"]
    static let excludedService: Set<String> = ["driveway", "parking_aisle", "drive-through", "emergency_access"]
    static let footOK: Set<String> = ["yes", "designated", "permissive"]
    static let sidewalkNear = 14.0, sidewalkBearing = 25.0, sidewalkShare = 0.75
    static let minDeadEnd = 10.0, blockMin = 1000.0, blockMax = 250_000.0

    // MARK: Fetching

    /// The area Overpass is asked for: the tile plus a buffer, so junctions and
    /// blocks at the tile's edge come out the same as they would from inside.
    public static func fetchBox(for tile: TileKey) -> (south: Double, west: Double, north: Double, east: Double) {
        let proj = LocalProjection(origin: tile.center)
        let dlat = bufferMetres / proj.ky, dlon = bufferMetres / proj.kx
        return (tile.south - dlat, tile.west - dlon, tile.north + dlat, tile.east + dlon)
    }

    static func f5(_ v: Double) -> String { String(format: "%.5f", v) }

    /// One Overpass query returns the highways (with a buffer) and landmarks for
    /// a group of tiles; `subset(_:for:)` then cuts out exactly what a query for
    /// a single tile would have returned, so batching never changes the result.
    public static func overpassQuery(for tiles: [TileKey]) -> String {
        let boxes = tiles.map(fetchBox(for:))
        let hb = "\(f5(boxes.map(\.south).min()!)),\(f5(boxes.map(\.west).min()!)),\(f5(boxes.map(\.north).max()!)),\(f5(boxes.map(\.east).max()!))"
        let tb = "\(f5(tiles.map(\.south).min()!)),\(f5(tiles.map(\.west).min()!)),\(f5(tiles.map(\.north).max()!)),\(f5(tiles.map(\.east).max()!))"
        let poi = [
            "nwr[\"leisure\"=\"park\"][\"name\"]", "nwr[\"railway\"=\"station\"][\"name\"]",
            "nwr[\"amenity\"=\"place_of_worship\"][\"name\"]", "nwr[\"amenity\"=\"library\"][\"name\"]",
            "nwr[\"leisure\"=\"playground\"][\"name\"]", "nwr[\"leisure\"=\"common\"][\"name\"]",
            "nwr[\"historic\"][\"name\"]", "nwr[\"amenity\"=\"community_centre\"][\"name\"]",
            "nwr[\"leisure\"=\"nature_reserve\"][\"name\"]",
        ].map { "\($0)(\(tb));" }.joined()
        return "[out:json][timeout:90];(way[\"highway\"](\(hb)););out body;>;out skel qt;(\(poi));out center tags;"
    }

    /// What Overpass returns for one tile: highways with any node inside the
    /// tile's fetch box (plus everything else, which the builder filters itself).
    public static func subset(_ osm: OverpassResponse, for tile: TileKey) -> OverpassResponse {
        let b = fetchBox(for: tile)
        var at: [Int64: (Double, Double)] = [:]
        for e in osm.elements where e.type == "node" { if let la = e.lat, let lo = e.lon { at[e.id] = (la, lo) } }
        let els = osm.elements.filter { e in
            guard e.type == "way", let ns = e.nodes else { return true }
            return ns.contains { n in at[n].map { $0.0 >= b.south && $0.0 <= b.north && $0.1 >= b.west && $0.1 <= b.east } ?? false }
        }
        return OverpassResponse(osm3s: osm.osm3s, elements: els)
    }

    // MARK: Filters

    static func kind(_ highway: String) -> String { roadClasses.contains(highway) ? "road" : "path" }

    static func isRunnable(_ t: [String: String]) -> Bool {
        guard let hw = t["highway"], roadClasses.contains(hw) || pathClasses.contains(hw) else { return false }
        if t["area"] == "yes" { return false }
        let foot = t["foot"]
        if foot == "no" || foot == "private" { return false }
        if let a = t["access"], a == "private" || a == "no", !(foot.map(footOK.contains) ?? false) { return false }
        if hw == "service", let s = t["service"], excludedService.contains(s) { return false }
        if t["indoor"] == "yes" { return false }
        // Pavements mapped as separate ways credit the road they run beside.
        if hw == "footway", let f = t["footway"], ["sidewalk", "crossing", "traffic_island"].contains(f) { return false }
        if hw == "path" || hw == "cycleway", t["footway"] == "sidewalk" { return false }
        return true
    }

    // MARK: Geometry (mirrors ingest.py exactly)

    static func dist(_ a: Vec2, _ b: Vec2) -> Double { hypot(a.x - b.x, a.y - b.y) }

    static func polylineLength(_ p: [Vec2]) -> Double {
        var s = 0.0
        for i in 0..<max(0, p.count - 1) { s += dist(p[i], p[i + 1]) }
        return s
    }

    static func pointSegmentDistance(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let l2 = dx * dx + dy * dy
        if l2 == 0 { return dist(p, a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2))
        return dist(p, Vec2(a.x + t * dx, a.y + t * dy))
    }

    static func bearing(_ a: Vec2, _ b: Vec2) -> Double {
        let d = atan2(b.x - a.x, b.y - a.y) * 180 / .pi
        let m = d.truncatingRemainder(dividingBy: 360)
        return m < 0 ? m + 360 : m
    }

    static func bearingDiff(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 180)
        return min(d, 180 - d)
    }

    static func sampleAlong(_ pts: [Vec2], step: Double) -> [(Vec2, Double)] {
        var out: [(Vec2, Double)] = []
        var carry = 0.0
        for i in 0..<max(0, pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            let seg = dist(a, b)
            if seg == 0 { continue }
            let brg = bearing(a, b)
            var t = carry
            while t <= seg {
                let f = t / seg
                out.append((Vec2(a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f), brg))
                t += step
            }
            carry = t - seg
        }
        if pts.count >= 2 { out.append((pts[pts.count - 1], bearing(pts[pts.count - 2], pts[pts.count - 1]))) }
        return out
    }

    static func ringArea(_ ring: [Vec2]) -> Double {
        var a = 0.0
        for i in 0..<max(0, ring.count - 1) { a += ring[i].x * ring[i + 1].y - ring[i + 1].x * ring[i].y }
        return a / 2
    }

    static func midpoint(_ xy: [Vec2]) -> Vec2 {
        let half = polylineLength(xy) / 2
        var acc = 0.0
        for i in 0..<max(0, xy.count - 1) {
            let d = dist(xy[i], xy[i + 1])
            if acc + d >= half, d > 0 {
                let f = (half - acc) / d
                return Vec2(xy[i].x + (xy[i + 1].x - xy[i].x) * f, xy[i].y + (xy[i + 1].y - xy[i].y) * f)
            }
            acc += d
        }
        return xy[0]
    }

    static func r6(_ v: Double) -> Double { (v * 1e6).rounded() / 1e6 }
    static func r1(_ v: Double) -> Double { (v * 10).rounded() / 10 }

    static func sha11(_ s: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(s.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(11))
    }

    struct Grid {
        let cell: Double
        var cells: [Int64: [(Vec2, Vec2)]] = [:]
        init(cell: Double) { self.cell = cell }
        static func key(_ x: Int, _ y: Int) -> Int64 { (Int64(x) << 32) ^ Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: y))) }
        mutating func insert(_ pts: [Vec2]) {
            for i in 0..<max(0, pts.count - 1) {
                let a = pts[i], b = pts[i + 1]
                for gx in Int(floor(min(a.x, b.x) / cell))...Int(floor(max(a.x, b.x) / cell)) {
                    for gy in Int(floor(min(a.y, b.y) / cell))...Int(floor(max(a.y, b.y) / cell)) {
                        cells[Self.key(gx, gy), default: []].append((a, b))
                    }
                }
            }
        }
        func near(_ p: Vec2, _ r: Double) -> [(Vec2, Vec2)] {
            var out: [(Vec2, Vec2)] = []
            for gx in Int(floor((p.x - r) / cell))...Int(floor((p.x + r) / cell)) {
                for gy in Int(floor((p.y - r) / cell))...Int(floor((p.y + r) / cell)) {
                    if let c = cells[Self.key(gx, gy)] { out.append(contentsOf: c) }
                }
            }
            return out
        }
    }

    struct Edge: Hashable, Comparable {
        let a: Int64, b: Int64
        static func < (l: Edge, r: Edge) -> Bool { (l.a, l.b) < (r.a, r.b) }
    }

    struct BuiltSegment {
        let id: String
        let nodes: [Int64]
        let ll: [Coordinate]
        let xy: [Vec2]
        let length: Double
        let name: String
        let highway: String
        let kind: String
    }

    // MARK: Build

    /// Builds a tile from an Overpass response for `overpassQuery(for: tile)`.
    public static func buildTile(_ tile: TileKey, osm: OverpassResponse, generatedAt: Date = .now) -> TileFile {
        let proj = LocalProjection(origin: tile.center)
        let segments = buildSegments(osm: osm, projection: proj)
        let box = fetchBox(for: tile)
        let inTile = segments.filter { tile.contains(proj.unproject(midpoint($0.xy))) }
        let blocks = traceBlocks(segments).filter { b in
            b.ring.allSatisfy { $0.latitude > box.south && $0.latitude < box.north && $0.longitude > box.west && $0.longitude < box.east }
                && tile.contains(b.centroid)
        }
        let iso = ISO8601DateFormatter()
        return TileFile(
            formatVersion: TileFile.currentFormat, key: tile.description,
            generatedAt: iso.string(from: generatedAt), osmTimestamp: osm.osm3s?.timestamp_osm_base ?? "",
            segments: inTile.map(record),
            blocks: blocks.map { AreaFile.BlockRecord(id: $0.id, segments: $0.segments, areaM2: $0.areaM2,
                                                      ring: $0.ring.map { [r6($0.longitude), r6($0.latitude)] }) },
            pois: pois(osm: osm, tile: tile))
    }

    static func record(_ s: BuiltSegment) -> AreaFile.SegmentRecord {
        AreaFile.SegmentRecord(id: s.id, name: s.name, kind: s.kind, highway: s.highway, length: r1(s.length),
                               a: s.nodes[0], b: s.nodes[s.nodes.count - 1],
                               coords: s.ll.map { [r6($0.longitude), r6($0.latitude)] })
    }

    static func buildSegments(osm: OverpassResponse, projection proj: LocalProjection) -> [BuiltSegment] {
        var nodes: [Int64: Coordinate] = [:]
        var ways: [OverpassResponse.Element] = []
        var seenWay = Set<Int64>()
        for el in osm.elements {
            if el.type == "node", let lat = el.lat, let lon = el.lon {
                nodes[el.id] = Coordinate(latitude: lat, longitude: lon)
            } else if el.type == "way", el.nodes != nil, el.tags?["highway"] != nil, !seenWay.contains(el.id) {
                seenWay.insert(el.id)
                ways.append(el)
            }
        }
        let kept = ways.filter { w in isRunnable(w.tags ?? [:]) && w.nodes!.allSatisfy { nodes[$0] != nil } }

        // Untagged parallel pavements: a footway/path hugging a road along most of its length.
        var roads = Grid(cell: 40)
        for w in kept where kind(w.tags!["highway"]!) == "road" { roads.insert(w.nodes!.map { proj.project(nodes[$0]!) }) }
        var finalWays: [OverpassResponse.Element] = []
        for w in kept {
            let t = w.tags!
            if ["footway", "path", "cycleway"].contains(t["highway"]!), t["name"] == nil {
                let samples = sampleAlong(w.nodes!.map { proj.project(nodes[$0]!) }, step: 8)
                if samples.count >= 3 {
                    var hugging = 0
                    for (p, brg) in samples {
                        for (a, b) in roads.near(p, sidewalkNear)
                        where pointSegmentDistance(p, a, b) <= sidewalkNear && bearingDiff(brg, bearing(a, b)) <= sidewalkBearing {
                            hugging += 1
                            break
                        }
                    }
                    if Double(hugging) / Double(samples.count) >= sidewalkShare { continue }
                }
            }
            finalWays.append(w)
        }

        // Junction graph.
        var adj: [Int64: Set<Int64>] = [:]
        var edgeWay: [Edge: Int64] = [:]
        var wayByID: [Int64: OverpassResponse.Element] = [:]
        for w in finalWays {
            wayByID[w.id] = w
            let ns = w.nodes!
            for i in 0..<max(0, ns.count - 1) {
                let a = ns[i], b = ns[i + 1]
                if a == b { continue }
                adj[a, default: []].insert(b)
                adj[b, default: []].insert(a)
                edgeWay[Edge(a: a, b: b)] = w.id
                edgeWay[Edge(a: b, b: a)] = w.id
            }
        }
        func wkey(_ wid: Int64) -> String {
            let t = wayByID[wid]!.tags!
            return "\(t["name"] ?? "")\u{1}\(kind(t["highway"]!))"
        }
        var split = Set<Int64>()
        for (nid, nbrs) in adj {
            if nbrs.count != 2 { split.insert(nid); continue }
            let pair = Array(nbrs)
            if wkey(edgeWay[Edge(a: nid, b: pair[0])]!) != wkey(edgeWay[Edge(a: nid, b: pair[1])]!) { split.insert(nid) }
        }

        var visited = Set<Edge>()
        func walk(_ start: Int64, _ next: Int64) -> [Int64] {
            var chain = [start, next]
            visited.insert(Edge(a: start, b: next)); visited.insert(Edge(a: next, b: start))
            var prev = start, cur = next
            while !split.contains(cur) {
                guard let nx = adj[cur]!.first(where: { $0 != prev }) else { break }
                if visited.contains(Edge(a: cur, b: nx)) { break }
                visited.insert(Edge(a: cur, b: nx)); visited.insert(Edge(a: nx, b: cur))
                chain.append(nx)
                prev = cur; cur = nx
                if cur == start { break }
            }
            return chain
        }
        var chains: [[Int64]] = []
        for nid in split.sorted() {
            for nb in adj[nid]!.sorted() where !visited.contains(Edge(a: nid, b: nb)) { chains.append(walk(nid, nb)) }
        }
        for e in edgeWay.keys.sorted() where !visited.contains(e) {  // isolated loops with no junction
            split.insert(e.a)
            chains.append(walk(e.a, e.b))
        }

        var out: [BuiltSegment] = []
        var used = Set<String>()
        for raw in chains {
            let n = raw.count
            let fwd = (raw[0], raw[1], raw[n - 2], raw[n - 1]), rev = (raw[n - 1], raw[n - 2], raw[1], raw[0])
            let ch = fwd <= rev ? raw : raw.reversed()
            let ll = ch.map { nodes[$0]! }
            let xy = ll.map(proj.project)
            let length = polylineLength(xy)
            if length < 0.5 { continue }
            let tags = wayByID[edgeWay[Edge(a: ch[0], b: ch[1])]!]!.tags!
            let key = "\(ch[0])-\(ch[1])-\(ch[n - 2])-\(ch[n - 1])"
            var sid = "s" + sha11(key)
            while used.contains(sid) { sid = "s" + sha11(key + sid) }
            used.insert(sid)
            out.append(BuiltSegment(id: sid, nodes: ch, ll: ll, xy: xy, length: length,
                                    name: tags["name"] ?? tags["ref"] ?? "", highway: tags["highway"]!, kind: kind(tags["highway"]!)))
        }
        // Drop tiny dead-end stubs (the last few metres of a footway into a hedge).
        return out.filter { s in
            !(s.length < minDeadEnd && (adj[s.nodes[0]]!.count == 1 || adj[s.nodes[s.nodes.count - 1]]!.count == 1))
        }
    }

    struct BuiltBlock {
        let id: String
        let segments: [String]
        let areaM2: Double
        let ring: [Coordinate]
        var centroid: Coordinate {
            let pts = ring.dropLast()
            return Coordinate(latitude: pts.map(\.latitude).reduce(0, +) / Double(pts.count),
                              longitude: pts.map(\.longitude).reduce(0, +) / Double(pts.count))
        }
    }

    static func direction(_ xy: [Vec2], fromStart: Bool) -> Double {
        let pts = fromStart ? xy : xy.reversed()
        let origin = pts[0]
        var acc = 0.0
        var target = pts[1]
        for k in 1..<pts.count {
            acc += dist(pts[k - 1], pts[k])
            target = pts[k]
            if acc >= 6 { break }
        }
        return atan2(target.y - origin.y, target.x - origin.x)
    }

    /// Faces of the (approximately planar) segment graph via half-edge traversal.
    static func traceBlocks(_ segs: [BuiltSegment]) -> [BuiltBlock] {
        struct Half: Comparable {
            let angle: Double, seg: Int, fwd: Bool
            static func < (l: Half, r: Half) -> Bool {
                (l.angle, l.seg, l.fwd ? 1 : 0) < (r.angle, r.seg, r.fwd ? 1 : 0)
            }
        }
        struct HK: Hashable { let seg: Int; let fwd: Bool }
        var outEdges: [Int64: [Half]] = [:]
        var order: [Int64] = []
        func add(_ n: Int64, _ h: Half) {
            if outEdges[n] == nil { order.append(n) }
            outEdges[n, default: []].append(h)
        }
        for (i, s) in segs.enumerated() {
            let a = s.nodes[0], b = s.nodes[s.nodes.count - 1]
            if a == b { continue }
            add(a, Half(angle: direction(s.xy, fromStart: true), seg: i, fwd: true))
            add(b, Half(angle: direction(s.xy, fromStart: false), seg: i, fwd: false))
        }
        for k in order { outEdges[k]!.sort() }
        func head(_ i: Int, _ f: Bool) -> Int64 { f ? segs[i].nodes[segs[i].nodes.count - 1] : segs[i].nodes[0] }

        var visited = Set<HK>()
        var blocks: [BuiltBlock] = []
        for node in order {
            for start in outEdges[node]! {
                if visited.contains(HK(seg: start.seg, fwd: start.fwd)) { continue }
                var face: [HK] = []
                var cur = HK(seg: start.seg, fwd: start.fwd)
                var guardCount = 0
                while !visited.contains(cur), guardCount < 5000 {
                    visited.insert(cur)
                    face.append(cur)
                    let lst = outEdges[head(cur.seg, cur.fwd)]!
                    let idx = lst.firstIndex { $0.seg == cur.seg && $0.fwd == !cur.fwd }!
                    let nx = lst[(idx - 1 + lst.count) % lst.count]
                    cur = HK(seg: nx.seg, fwd: nx.fwd)
                    guardCount += 1
                }
                if face.isEmpty || cur != HK(seg: start.seg, fwd: start.fwd) { continue }
                var ring: [Vec2] = []
                var llRing: [Coordinate] = []
                for h in face {
                    let pts = h.fwd ? segs[h.seg].xy : segs[h.seg].xy.reversed()
                    let ll = h.fwd ? segs[h.seg].ll : segs[h.seg].ll.reversed()
                    ring.append(contentsOf: ring.isEmpty ? pts[...] : pts.dropFirst())
                    llRing.append(contentsOf: llRing.isEmpty ? ll[...] : ll.dropFirst())
                }
                if ring.count < 4 { continue }
                let area = ringArea(ring + [ring[0]])
                if area <= 0 || area < blockMin || area > blockMax { continue }
                var counts: [Int: Int] = [:]
                for h in face { counts[h.seg, default: 0] += 1 }
                let bounding = Set(counts.filter { $0.value == 1 }.map { segs[$0.key].id }).sorted()
                if bounding.count < 2 { continue }
                llRing.append(llRing[0])
                blocks.append(BuiltBlock(id: "b" + sha11(bounding.joined(separator: "-")), segments: bounding,
                                         areaM2: area.rounded(), ring: llRing))
            }
        }
        var uniq: [String: BuiltBlock] = [:]
        for b in blocks where uniq[b.id] == nil { uniq[b.id] = b }
        return uniq.values.sorted { $0.id < $1.id }
    }

    static func pois(osm: OverpassResponse, tile: TileKey) -> [AreaFile.POIRecord] {
        var out: [AreaFile.POIRecord] = []
        var seen = Set<String>()
        var seenID = Set<String>()
        for el in osm.elements {
            guard let tags = el.tags, let rawName = tags["name"] else { continue }
            let lat: Double, lon: Double
            if el.type == "node", let a = el.lat, let o = el.lon { lat = a; lon = o }
            else if let c = el.center { lat = c.lat; lon = c.lon }
            else { continue }
            let kind: String
            if tags["railway"] == "station" { kind = "station" }
            else if tags["amenity"] == "place_of_worship" { kind = "worship" }
            else if ["park", "common", "nature_reserve"].contains(tags["leisure"] ?? "") { kind = "park" }
            else if tags["leisure"] == "playground" { kind = "playground" }
            else if tags["amenity"] == "library" { kind = "library" }
            else if tags["amenity"] == "community_centre" { kind = "community" }
            else if tags["historic"] != nil { kind = "historic" }
            else { continue }
            let c = Coordinate(latitude: lat, longitude: lon)
            guard tile.contains(c) else { continue }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = "\(el.type.prefix(1))\(el.id)"
            let dedupe = "\(name.lowercased())|\(kind)"
            if name.isEmpty || seen.contains(dedupe) || seenID.contains(id) { continue }
            seen.insert(dedupe); seenID.insert(id)
            out.append(AreaFile.POIRecord(id: id, name: name, kind: kind, lon: r6(lon), lat: r6(lat)))
        }
        return out.sorted { $0.id < $1.id }
    }
}
