import Foundation

/// A loop through the street graph, planned before a run.
public struct PlannedRoute: Sendable, Hashable {
    /// Segment indexes in the order they're run (a street can appear twice).
    public var segments: [Int]
    public var coordinates: [Coordinate]
    public var distance: Double
    /// Distinct wanted streets on the loop, and the tokens on them.
    public var targets: Int
    public var tokens: Int
}

/// Plans a loop of roughly the asked-for distance that starts and ends at the
/// same junction and passes as many wanted streets as it can. Wanted-ness is
/// up to the caller (neutral streets to capture, fading streets to defend,
/// streets never run...). Tries several randomised walks and keeps the best.
public struct RoutePlanner: Sendable {
    public let area: Area
    public init(area: Area) { self.area = area }

    /// - Parameters:
    ///   - value: how much each segment (by index) is wanted, 0...1+.
    ///   - tokens: tokens on a segment, for the summary.
    public func plan(from start: Coordinate, distance target: Double, seed: UInt64, attempts: Int = 24,
                     value: (Int) -> Double, tokens: (Int) -> Int) -> PlannedRoute? {
        guard !area.segments.isEmpty, target > 200 else { return nil }
        let proj = area.projection
        let p = proj.project(start)
        let near = area.index.segments(near: p, radius: 600)
        guard let first = near.min(by: { area.segments[$0].polyline.project(p).distance < area.segments[$1].polyline.project(p).distance })
        else { return nil }
        let fs = area.segments[first]
        let startNode = fs.polyline.project(p).offset < fs.length / 2 ? fs.startNode : fs.endNode

        var nodePos: [Int64: Vec2] = [:]
        for s in area.segments {
            nodePos[s.startNode] = s.polyline.points.first
            nodePos[s.endNode] = s.polyline.points.last
        }
        guard let home = nodePos[startNode] else { return nil }
        func dist(_ a: Vec2, _ b: Vec2) -> Double { let dx = a.x - b.x, dy = a.y - b.y; return (dx * dx + dy * dy).squareRoot() }

        var rng = SeededRandom(seed: seed)
        var best: (route: [Int], score: Double)?
        for _ in 0..<max(1, attempts) {
            var node = startNode
            var walked = 0.0
            var route: [Int] = []
            var used: [Int: Int] = [:]
            var lastSeg = -1
            for _ in 0..<4000 {
                let here = nodePos[node] ?? home
                let homeGap = dist(here, home)
                if walked > target * 0.3, walked + homeGap * 1.3 >= target { break }
                let opts = area.graph.neighbours(of: node)
                if opts.isEmpty { break }
                let heading = walked > target * 0.5
                var pick = opts[0], bestScore = -Double.infinity
                for e in opts {
                    let s = area.segments[e.segment]
                    let times = used[e.segment, default: 0]
                    var score = (times == 0 ? value(e.segment) * 2 : 0) + 0.15
                    score /= Double(1 + times * 2)
                    if e.segment == lastSeg && opts.count > 1 { score -= 1.5 }  // no instant U-turns
                    if heading, s.length > 0 {
                        let gain = homeGap - dist(nodePos[e.other] ?? here, home)
                        score += 0.9 * gain / s.length
                    }
                    score += rng.unit() * 0.35
                    if score > bestScore { bestScore = score; pick = e }
                }
                route.append(pick.segment)
                used[pick.segment, default: 0] += 1
                walked += area.segments[pick.segment].length
                lastSeg = pick.segment
                node = pick.other
            }
            // Shortest way back to the start.
            if node != startNode {
                let tree = area.graph.shortestPaths(from: [(node: node, cost: 0)], segments: area.segments, limit: max(target, 3000))
                var back: [Int] = []
                var n = startNode
                var guardSteps = 0
                while n != node, let (prevNode, seg) = tree.prev[n], guardSteps < 5000 {
                    back.append(seg)
                    n = prevNode
                    guardSteps += 1
                }
                guard n == node else { continue }  // start unreachable from here
                route.append(contentsOf: back.reversed())
            }
            guard !route.isEmpty else { continue }
            let total = route.reduce(0) { $0 + area.segments[$1].length }
            let distinct = Set(route)
            let gained = distinct.reduce(0.0) { $0 + value($1) * area.segments[$1].length }
            let score = gained / max(total, 1) - 1.5 * abs(total - target) / target
            if best == nil || score > best!.score { best = (route, score) }
        }
        guard let chosen = best?.route else { return nil }

        // Coordinates in running order.
        var coords: [Coordinate] = []
        var node = startNode
        for idx in chosen {
            let s = area.segments[idx]
            let forward = s.startNode == node
            let pts = forward ? s.coordinates : s.coordinates.reversed()
            coords.append(contentsOf: coords.isEmpty ? pts : Array(pts.dropFirst()))
            node = forward ? s.endNode : s.startNode
        }
        let wanted = Set(chosen).filter { value($0) > 0 }
        return PlannedRoute(segments: chosen, coordinates: coords,
                            distance: chosen.reduce(0) { $0 + area.segments[$1].length },
                            targets: wanted.count, tokens: wanted.reduce(0) { $0 + tokens($1) })
    }
}
