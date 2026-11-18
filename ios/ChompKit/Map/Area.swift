import Foundation

/// The JSON produced by tools/ingest/ingest.py.
public struct AreaFile: Codable, Sendable {
    public struct SegmentRecord: Codable, Sendable {
        public let id: String
        public let name: String
        public let kind: String
        public let highway: String
        public let length: Double
        public let a: Int64
        public let b: Int64
        public let coords: [[Double]]
    }
    public struct BlockRecord: Codable, Sendable {
        public let id: String
        public let segments: [String]
        public let areaM2: Double
        public let ring: [[Double]]
    }
    public struct POIRecord: Codable, Sendable {
        public let id: String
        public let name: String
        public let kind: String
        public let lon: Double
        public let lat: Double
    }

    public let formatVersion: Int
    public let slug: String
    public let name: String
    public let longName: String
    public let county: String
    public let country: String
    public let generatedAt: String
    public let osmTimestamp: String
    public let attribution: String
    public let center: [Double]
    public let bbox: [Double]
    public let boundary: [[[[Double]]]]
    public let totalLengthMetres: Double
    public let segments: [SegmentRecord]
    public let blocks: [BlockRecord]
    public let pois: [POIRecord]
    public let lineage: [String: String]
}

public typealias SegmentID = String
public typealias BlockID = String

public struct Segment: Sendable, Identifiable {
    public let id: SegmentID
    public let index: Int
    public let name: String
    public let isPath: Bool
    public let highway: String
    public let length: Double
    public let startNode: Int64
    public let endNode: Int64
    public let coordinates: [Coordinate]
    public let polyline: Polyline

    public var displayName: String {
        if !name.isEmpty { return name }
        switch highway {
        case "footway", "path", "pedestrian", "steps": return "Footpath"
        case "cycleway": return "Cycle path"
        case "track", "bridleway": return "Track"
        case "service": return "Service road"
        default: return "Unnamed street"
        }
    }

    public var midpoint: Coordinate {
        coordinates[coordinates.count / 2]
    }
}

public struct Block: Sendable, Identifiable {
    public let id: BlockID
    public let segmentIDs: [SegmentID]
    public let areaM2: Double
    public let ring: [Coordinate]
}

public struct Landmark: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let kind: String
    public let coordinate: Coordinate
}

/// A playable town: segments, graph, blocks and landmarks, all immutable.
public final class Area: Sendable {
    public let slug: String
    public let name: String
    public let longName: String
    public let county: String
    public let country: String
    public let attribution: String
    public let center: Coordinate
    /// west, south, east, north
    public let bbox: [Double]
    public let boundary: [[[Coordinate]]]
    public let projection: LocalProjection
    public let segments: [Segment]
    public let blocks: [Block]
    public let landmarks: [Landmark]
    public let lineage: [SegmentID: SegmentID]
    public let totalLength: Double
    public let graph: SegmentGraph
    public let index: SpatialIndex
    private let indexByID: [SegmentID: Int]
    public let blocksBySegment: [SegmentID: [BlockID]]
    public let blockByID: [BlockID: Block]

    public init(file: AreaFile) {
        slug = file.slug
        name = file.name
        longName = file.longName
        county = file.county
        country = file.country
        attribution = file.attribution
        center = Coordinate(latitude: file.center[1], longitude: file.center[0])
        bbox = file.bbox
        boundary = file.boundary.map { poly in poly.map { ring in ring.map { Coordinate(latitude: $0[1], longitude: $0[0]) } } }
        let proj = LocalProjection(origin: center)
        projection = proj
        var segs: [Segment] = []
        segs.reserveCapacity(file.segments.count)
        for (i, s) in file.segments.enumerated() {
            let coords = s.coords.map { Coordinate(latitude: $0[1], longitude: $0[0]) }
            segs.append(Segment(
                id: s.id, index: i, name: s.name, isPath: s.kind == "path", highway: s.highway,
                length: s.length, startNode: s.a, endNode: s.b, coordinates: coords,
                polyline: Polyline(coords.map(proj.project))))
        }
        segments = segs
        indexByID = Dictionary(uniqueKeysWithValues: segs.map { ($0.id, $0.index) })
        blocks = file.blocks.map { b in
            Block(id: b.id, segmentIDs: b.segments, areaM2: b.areaM2,
                  ring: b.ring.map { Coordinate(latitude: $0[1], longitude: $0[0]) })
        }
        var bySeg: [SegmentID: [BlockID]] = [:]
        for b in blocks { for s in b.segmentIDs { bySeg[s, default: []].append(b.id) } }
        blocksBySegment = bySeg
        blockByID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        landmarks = file.pois.map { Landmark(id: $0.id, name: $0.name, kind: $0.kind,
                                             coordinate: Coordinate(latitude: $0.lat, longitude: $0.lon)) }
        lineage = file.lineage
        totalLength = segs.reduce(0) { $0 + $1.length }
        graph = SegmentGraph(segments: segs)
        index = SpatialIndex(segments: segs, cell: 60)
    }

    public static func load(from url: URL) throws -> Area {
        let data = try Data(contentsOf: url)
        return Area(file: try JSONDecoder().decode(AreaFile.self, from: data))
    }

    public func segment(_ id: SegmentID) -> Segment? {
        indexByID[id].map { segments[$0] }
    }

    public func segmentIndex(_ id: SegmentID) -> Int? { indexByID[id] }

    public func contains(_ c: Coordinate) -> Bool {
        let p = projection.project(c)
        for poly in boundary {
            guard let outer = poly.first else { continue }
            if pointInRing(p, outer.map(projection.project)),
               !poly.dropFirst().contains(where: { pointInRing(p, $0.map(projection.project)) }) {
                return true
            }
        }
        return false
    }
}

/// Junction graph: nodes are OSM junction node IDs, edges are segments.
public struct SegmentGraph: Sendable {
    public struct Edge: Sendable { public let segment: Int; public let other: Int64 }
    public let adjacency: [Int64: [Edge]]

    init(segments: [Segment]) {
        var adj: [Int64: [Edge]] = [:]
        for s in segments {
            adj[s.startNode, default: []].append(Edge(segment: s.index, other: s.endNode))
            adj[s.endNode, default: []].append(Edge(segment: s.index, other: s.startNode))
        }
        adjacency = adj
    }

    public func neighbours(of node: Int64) -> [Edge] { adjacency[node] ?? [] }

    /// Bounded Dijkstra over junctions. Returns distance and predecessor (node, via segment).
    public func shortestPaths(from sources: [(node: Int64, cost: Double)], segments: [Segment], limit: Double)
        -> (dist: [Int64: Double], prev: [Int64: (Int64, Int)]) {
        var dist: [Int64: Double] = [:]
        var prev: [Int64: (Int64, Int)] = [:]
        var heap = MinHeap<(Double, Int64)>(by: { $0.0 < $1.0 })
        for s in sources where s.cost <= limit {
            if s.cost < dist[s.node, default: .infinity] {
                dist[s.node] = s.cost
                heap.push((s.cost, s.node))
            }
        }
        while let (d, n) = heap.pop() {
            if d > dist[n, default: .infinity] { continue }
            for e in neighbours(of: n) {
                let nd = d + segments[e.segment].length
                if nd <= limit, nd < dist[e.other, default: .infinity] {
                    dist[e.other] = nd
                    prev[e.other] = (n, e.segment)
                    heap.push((nd, e.other))
                }
            }
        }
        return (dist, prev)
    }
}

/// Uniform grid over segment pieces for "what streets are within 30 m of this GPS fix".
public struct SpatialIndex: Sendable {
    let cell: Double
    let cells: [Int64: [Int]]

    init(segments: [Segment], cell: Double) {
        self.cell = cell
        var cells: [Int64: Set<Int>] = [:]
        for s in segments {
            let pts = s.polyline.points
            for i in 0..<max(0, pts.count - 1) {
                let a = pts[i], b = pts[i + 1]
                for gx in Self.cellRange(min(a.x, b.x), max(a.x, b.x), cell) {
                    for gy in Self.cellRange(min(a.y, b.y), max(a.y, b.y), cell) {
                        cells[Self.key(gx, gy), default: []].insert(s.index)
                    }
                }
            }
        }
        self.cells = cells.mapValues { Array($0) }
    }

    static func cellRange(_ lo: Double, _ hi: Double, _ c: Double) -> ClosedRange<Int> {
        Int((lo / c).rounded(.down))...Int((hi / c).rounded(.down))
    }

    static func key(_ x: Int, _ y: Int) -> Int64 { (Int64(x) << 32) ^ Int64(UInt32(bitPattern: Int32(y))) }

    public func segments(near p: Vec2, radius: Double) -> Set<Int> {
        var out = Set<Int>()
        for gx in Self.cellRange(p.x - radius, p.x + radius, cell) {
            for gy in Self.cellRange(p.y - radius, p.y + radius, cell) {
                if let s = cells[Self.key(gx, gy)] { out.formUnion(s) }
            }
        }
        return out
    }
}

/// Small binary heap; avoids pulling in swift-collections.
public struct MinHeap<T> {
    private var items: [T] = []
    private let less: (T, T) -> Bool
    public init(by less: @escaping (T, T) -> Bool) { self.less = less }
    public var isEmpty: Bool { items.isEmpty }

    public mutating func push(_ x: T) {
        items.append(x)
        var i = items.count - 1
        while i > 0 {
            let p = (i - 1) / 2
            if less(items[i], items[p]) { items.swapAt(i, p); i = p } else { break }
        }
    }

    public mutating func pop() -> T? {
        guard !items.isEmpty else { return nil }
        items.swapAt(0, items.count - 1)
        let top = items.removeLast()
        var i = 0
        while true {
            let l = 2 * i + 1, r = l + 1
            var m = i
            if l < items.count, less(items[l], items[m]) { m = l }
            if r < items.count, less(items[r], items[m]) { m = r }
            if m == i { break }
            items.swapAt(i, m)
            i = m
        }
        return top
    }
}
