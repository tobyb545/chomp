import Foundation

/// One GPS fix.
public struct TracePoint: Codable, Hashable, Sendable {
    public var coordinate: Coordinate
    public var timestamp: Date
    /// Metres; negative means invalid.
    public var horizontalAccuracy: Double
    /// m/s as reported by the device; negative means unknown.
    public var speed: Double
    public var altitude: Double

    public init(coordinate: Coordinate, timestamp: Date, horizontalAccuracy: Double = 5, speed: Double = -1, altitude: Double = 0) {
        self.coordinate = coordinate
        self.timestamp = timestamp
        self.horizontalAccuracy = horizontalAccuracy
        self.speed = speed
        self.altitude = altitude
    }
}

/// A stretch of a segment that the runner covered between two timestamps.
public struct CoveragePiece: Codable, Hashable, Sendable {
    public let segment: Int
    public let from: Double
    public let to: Double
    public let start: Date
    public let end: Date
}

public struct MatchedPoint: Hashable, Sendable {
    public let traceIndex: Int
    public let segment: Int
    public let offset: Double
    public let snapped: Coordinate
    public let timestamp: Date
}

public struct MatchResult: Sendable {
    public var pieces: [CoveragePiece]
    public var path: [MatchedPoint]
    /// Points that survived filtering but had no street within range.
    public var unmatchedPoints: Int
    /// Number of independent stretches the trace broke into (gaps, off-network sections).
    public var chunks: Int
    public var usedPoints: Int

    public static let empty = MatchResult(pieces: [], path: [], unmatchedPoints: 0, chunks: 0, usedPoints: 0)

    public func coverage(segmentCount: Int? = nil) -> [Int: IntervalSet] {
        Self.coverage(of: pieces)
    }

    public static func coverage(of pieces: [CoveragePiece]) -> [Int: IntervalSet] {
        var out: [Int: IntervalSet] = [:]
        for p in pieces {
            out[p.segment, default: IntervalSet()].insert(min(p.from, p.to)...max(p.from, p.to))
        }
        return out
    }
}

/// Hidden-Markov-model map matcher (Newson & Krumm 2009) against Chomp's own
/// segment graph, so results are expressed directly as segment IDs + covered
/// stretches. The same algorithm runs server-side in the resolve-run Edge Function.
public struct MapMatcher: Sendable {
    public let area: Area
    public let rules: RulesConfig.Matching

    public init(area: Area, rules: RulesConfig.Matching) {
        self.area = area
        self.rules = rules
    }

    struct Candidate {
        let segment: Int
        let offset: Double
        let distance: Double
        let point: Vec2
    }

    /// Route between two candidates: total length plus the pieces it walks over.
    struct Route {
        let length: Double
        /// (segment, from, to) in travel order
        let parts: [(Int, Double, Double)]
    }

    public func match(_ trace: [TracePoint]) -> MatchResult {
        let proj = area.projection
        // 1. Filter & thin.
        var kept: [(Int, TracePoint, Vec2)] = []
        for (i, p) in trace.enumerated() {
            guard p.horizontalAccuracy >= 0, p.horizontalAccuracy <= rules.maxAccuracyMetres else { continue }
            let v = proj.project(p.coordinate)
            if let last = kept.last {
                let dt = p.timestamp.timeIntervalSince(last.1.timestamp)
                if dt <= 0 { continue }
                if v.distance(to: last.2) < rules.minPointSpacingMetres && dt < 10 { continue }
            }
            kept.append((i, p, v))
        }
        guard !kept.isEmpty else { return .empty }

        // 2. Split at gaps.
        var chunks: [[(Int, TracePoint, Vec2)]] = [[kept[0]]]
        for k in 1..<kept.count {
            let prev = kept[k - 1], cur = kept[k]
            let dt = cur.1.timestamp.timeIntervalSince(prev.1.timestamp)
            let dd = cur.2.distance(to: prev.2)
            if dt > rules.maxGapSeconds || dd > rules.maxGapMetres {
                chunks.append([cur])
            } else {
                chunks[chunks.count - 1].append(cur)
            }
        }

        var result = MatchResult(pieces: [], path: [], unmatchedPoints: 0, chunks: 0, usedPoints: kept.count)
        for chunk in chunks {
            matchChunk(chunk, into: &result)
        }
        return result
    }

    private func candidates(for v: Vec2) -> [Candidate] {
        var out: [Candidate] = []
        for s in area.index.segments(near: v, radius: rules.candidateRadiusMetres) {
            let pr = area.segments[s].polyline.project(v)
            if pr.distance <= rules.candidateRadiusMetres {
                out.append(Candidate(segment: s, offset: pr.offset, distance: pr.distance, point: pr.point))
            }
        }
        out.sort { $0.distance < $1.distance }
        return Array(out.prefix(rules.maxCandidatesPerPoint))
    }

    private func route(from a: Candidate, to b: Candidate, limit: Double,
                       cache: inout [Int: (dist: [Int64: Double], prev: [Int64: (Int64, Int)])], cacheKey: Int) -> Route? {
        let segs = area.segments
        if a.segment == b.segment {
            // Same street: straight along it (also covers short back-and-forths).
            return Route(length: abs(b.offset - a.offset), parts: [(a.segment, a.offset, b.offset)])
        }
        let sa = segs[a.segment], sb = segs[b.segment]
        let tree: (dist: [Int64: Double], prev: [Int64: (Int64, Int)])
        if let t = cache[cacheKey] {
            tree = t
        } else {
            tree = area.graph.shortestPaths(
                from: [(sa.startNode, a.offset), (sa.endNode, sa.length - a.offset)],
                segments: segs, limit: limit)
            cache[cacheKey] = tree
        }
        let viaStart = tree.dist[sb.startNode].map { $0 + b.offset } ?? .infinity
        let viaEnd = tree.dist[sb.endNode].map { $0 + (sb.length - b.offset) } ?? .infinity
        let total = min(viaStart, viaEnd)
        guard total.isFinite, total <= limit else { return nil }
        let entryNode = viaStart <= viaEnd ? sb.startNode : sb.endNode

        // Walk predecessors back to one of a's endpoints.
        var middle: [(Int, Double, Double)] = []
        var node = entryNode
        var guardCount = 0
        while let (p, seg) = tree.prev[node], guardCount < 512 {
            let s = segs[seg]
            // travelling p -> node along seg
            if s.startNode == p { middle.append((seg, 0, s.length)) } else { middle.append((seg, s.length, 0)) }
            node = p
            guardCount += 1
        }
        middle.reverse()
        let exitViaStart = sa.startNode == sa.endNode ? a.offset <= sa.length - a.offset : node == sa.startNode
        let firstPart: (Int, Double, Double) = exitViaStart ? (a.segment, a.offset, 0) : (a.segment, a.offset, sa.length)
        let lastPart: (Int, Double, Double) = entryNode == sb.startNode ? (b.segment, 0, b.offset) : (b.segment, sb.length, b.offset)
        return Route(length: total, parts: [firstPart] + middle + [lastPart])
    }

    private func matchChunk(_ chunk: [(Int, TracePoint, Vec2)], into result: inout MatchResult) {
        let sigma = rules.gpsSigmaMetres
        let beta = rules.transitionBeta

        // Viterbi state for the current run of connected points.
        var layers: [(point: (Int, TracePoint, Vec2), cands: [Candidate], score: [Double], back: [Int], routes: [Route?])] = []

        func flush() {
            guard let last = layers.last, !last.cands.isEmpty else { layers.removeAll(); return }
            result.chunks += 1
            // Backtrack.
            var idx = last.score.indices.max(by: { last.score[$0] < last.score[$1] })!
            var chosen: [(layer: Int, cand: Int)] = []
            for l in stride(from: layers.count - 1, through: 0, by: -1) {
                chosen.append((l, idx))
                idx = layers[l].back[idx]
            }
            chosen.reverse()
            let proj = area.projection
            for (n, c) in chosen.enumerated() {
                let layer = layers[c.layer]
                let cand = layer.cands[c.cand]
                result.path.append(MatchedPoint(traceIndex: layer.point.0, segment: cand.segment, offset: cand.offset,
                                                snapped: proj.unproject(cand.point), timestamp: layer.point.1.timestamp))
                guard n > 0 else { continue }
                let prevLayer = layers[chosen[n - 1].layer]
                let t0 = prevLayer.point.1.timestamp, t1 = layer.point.1.timestamp
                guard let r = layer.routes[c.cand] else { continue }
                // Spread time across the route parts proportionally to their length.
                var acc = 0.0
                let total = max(r.length, 0.0001)
                let span = t1.timeIntervalSince(t0)
                for part in r.parts {
                    let len = abs(part.2 - part.1)
                    let s = t0.addingTimeInterval(span * acc / total)
                    acc += len
                    let e = t0.addingTimeInterval(span * min(1, acc / total))
                    if len > 0 || r.parts.count == 1 {
                        result.pieces.append(CoveragePiece(segment: part.0, from: min(part.1, part.2), to: max(part.1, part.2), start: s, end: e))
                    }
                }
            }
            layers.removeAll()
        }

        for item in chunk {
            let cands = candidates(for: item.2)
            if cands.isEmpty {
                result.unmatchedPoints += 1
                flush()
                continue
            }
            let emission = cands.map { -0.5 * pow($0.distance / sigma, 2) }
            guard let prev = layers.last else {
                layers.append((item, cands, emission, Array(repeating: -1, count: cands.count), Array(repeating: nil, count: cands.count)))
                continue
            }
            let gc = item.2.distance(to: prev.point.2)
            let limit = gc * 2 + 60
            var cache: [Int: (dist: [Int64: Double], prev: [Int64: (Int64, Int)])] = [:]
            var score = Array(repeating: -Double.infinity, count: cands.count)
            var back = Array(repeating: -1, count: cands.count)
            var routes: [Route?] = Array(repeating: nil, count: cands.count)
            for (j, cj) in cands.enumerated() {
                for (i, ci) in prev.cands.enumerated() where prev.score[i].isFinite {
                    guard let r = route(from: ci, to: cj, limit: limit, cache: &cache, cacheKey: i) else { continue }
                    let s = prev.score[i] + emission[j] - abs(r.length - gc) / beta
                    if s > score[j] {
                        score[j] = s
                        back[j] = i
                        routes[j] = r
                    }
                }
            }
            if score.allSatisfy({ !$0.isFinite }) {
                // HMM break: no plausible transition. Close the current run and restart here.
                flush()
                layers.append((item, cands, emission, Array(repeating: -1, count: cands.count), Array(repeating: nil, count: cands.count)))
                continue
            }
            // Normalise to avoid drift.
            let m = score.filter(\.isFinite).max() ?? 0
            layers.append((item, cands, score.map { $0 - m }, back, routes))
        }
        flush()
    }
}
