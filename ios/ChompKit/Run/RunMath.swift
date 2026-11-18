import Foundation

public struct PrivacyZone: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// Deliberately not the exact spot: the stored centre is jittered on creation.
    public var center: Coordinate
    public var radius: Double

    public init(id: UUID = UUID(), name: String, center: Coordinate, radius: Double) {
        self.id = id; self.name = name; self.center = center; self.radius = radius
    }

    public func contains(_ c: Coordinate) -> Bool { center.distance(to: c) <= radius }

    /// A zone around `exact`, with its centre moved a random distance so the zone
    /// edge doesn't reveal where home is.
    public static func fuzzed(name: String, around exact: Coordinate, radius: Double, jitter: Double) -> PrivacyZone {
        var g = SystemRandomNumberGenerator()
        let d = Double.random(in: 0...jitter, using: &g)
        let b = Double.random(in: 0..<360, using: &g)
        return PrivacyZone(name: name, center: exact.offset(metres: d, bearingDegrees: b), radius: radius + jitter)
    }
}

public enum PrivacyTrimmer {
    /// Drops points from the start until the runner first leaves every zone, and
    /// from the end after they last enter one. Mid-run passes through a zone are kept
    /// (they don't reveal an endpoint).
    public static func trim(_ trace: [TracePoint], zones: [PrivacyZone]) -> [TracePoint] {
        guard !zones.isEmpty, !trace.isEmpty else { return trace }
        func inside(_ p: TracePoint) -> Bool { zones.contains { $0.contains(p.coordinate) } }
        guard let first = trace.firstIndex(where: { !inside($0) }),
              let last = trace.lastIndex(where: { !inside($0) }) else { return [] }
        return Array(trace[first...last])
    }

    /// Suggests zones where runs keep starting/ending (likely home or work).
    public static func suggestions(endpoints: [Coordinate], existing: [PrivacyZone], radius: Double, minimumVisits: Int = 3) -> [Coordinate] {
        var clusters: [(center: Coordinate, count: Int)] = []
        for p in endpoints where !existing.contains(where: { $0.contains(p) }) {
            if let i = clusters.firstIndex(where: { $0.center.distance(to: p) < radius }) {
                let c = clusters[i]
                let n = Double(c.count)
                clusters[i] = (Coordinate(latitude: (c.center.latitude * n + p.latitude) / (n + 1),
                                          longitude: (c.center.longitude * n + p.longitude) / (n + 1)), c.count + 1)
            } else {
                clusters.append((p, 1))
            }
        }
        return clusters.filter { $0.count >= minimumVisits }.sorted { $0.count > $1.count }.map(\.center)
    }
}

public struct Split: Hashable, Sendable, Identifiable {
    public var id: Int { index }
    public let index: Int
    public let distance: Double
    public let duration: TimeInterval
    public var paceSecondsPerKm: Double { distance > 0 ? duration / (distance / 1000) : 0 }
}

public enum RunMath {
    public static func distance(_ trace: [TracePoint], maxAccuracy: Double = 40) -> Double {
        let pts = trace.filter { $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= maxAccuracy }
        guard pts.count > 1 else { return 0 }
        var d = 0.0
        for i in 1..<pts.count {
            let step = pts[i].coordinate.distance(to: pts[i - 1].coordinate)
            let dt = pts[i].timestamp.timeIntervalSince(pts[i - 1].timestamp)
            // Ignore jumps that are clearly GPS glitches.
            if dt > 0, step / dt < 15 { d += step }
        }
        return d
    }

    public static func splits(_ trace: [TracePoint], every: Double = 1000, maxAccuracy: Double = 40) -> [Split] {
        let pts = trace.filter { $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= maxAccuracy }
        guard pts.count > 1 else { return [] }
        var out: [Split] = []
        var acc = 0.0
        var splitStart = pts[0].timestamp
        for i in 1..<pts.count {
            let step = pts[i].coordinate.distance(to: pts[i - 1].coordinate)
            let dt = pts[i].timestamp.timeIntervalSince(pts[i - 1].timestamp)
            guard dt > 0, step / dt < 15 else { continue }
            acc += step
            if acc >= every {
                // Interpolate the moment the split boundary was crossed.
                let over = acc - every
                let frac = step > 0 ? 1 - over / step : 1
                let t = pts[i - 1].timestamp.addingTimeInterval(dt * frac)
                out.append(Split(index: out.count + 1, distance: every, duration: t.timeIntervalSince(splitStart)))
                splitStart = t
                acc = over
            }
        }
        if acc > 50, let last = pts.last {
            out.append(Split(index: out.count + 1, distance: acc, duration: last.timestamp.timeIntervalSince(splitStart)))
        }
        return out
    }

    public static func formatPace(_ secondsPerKm: Double) -> String {
        guard secondsPerKm.isFinite, secondsPerKm > 0 else { return "–:––" }
        let s = Int(secondsPerKm.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    public static func formatDuration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Google encoded polyline (precision 5), used for compact uploads.
public enum PolylineCodec {
    public static func encode(_ coords: [Coordinate]) -> String {
        var out = ""
        var pLat = 0, pLon = 0
        for c in coords {
            let lat = Int((c.latitude * 1e5).rounded()), lon = Int((c.longitude * 1e5).rounded())
            encodeValue(lat - pLat, into: &out)
            encodeValue(lon - pLon, into: &out)
            pLat = lat; pLon = lon
        }
        return out
    }

    private static func encodeValue(_ v: Int, into out: inout String) {
        var x = v < 0 ? ~(v << 1) : (v << 1)
        while x >= 0x20 {
            out.unicodeScalars.append(UnicodeScalar(UInt8((0x20 | (x & 0x1f)) + 63)))
            x >>= 5
        }
        out.unicodeScalars.append(UnicodeScalar(UInt8(x + 63)))
    }

    public static func decode(_ s: String) -> [Coordinate] {
        var coords: [Coordinate] = []
        let bytes = Array(s.utf8)
        var i = 0, lat = 0, lon = 0
        func next() -> Int {
            var result = 0, shift = 0, b = 0
            repeat {
                b = Int(bytes[i]) - 63; i += 1
                result |= (b & 0x1f) << shift
                shift += 5
            } while b >= 0x20 && i < bytes.count
            return (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
        }
        while i < bytes.count {
            lat += next()
            guard i < bytes.count else { break }
            lon += next()
            coords.append(Coordinate(latitude: Double(lat) / 1e5, longitude: Double(lon) / 1e5))
        }
        return coords
    }
}

/// Generates believable runs along real streets: for the simulator, demos and tests.
public struct RouteSimulator: Sendable {
    public let area: Area
    public init(area: Area) { self.area = area }

    /// A walk through the street graph preferring streets not yet used, `distance` metres long.
    public func route(from start: Coordinate, distance: Double, seed: UInt64) -> [Coordinate] {
        var rng = SeededRandom(seed: seed)
        let proj = area.projection
        let p = proj.project(start)
        let near = area.index.segments(near: p, radius: 400)
        let startSeg = near.min { area.segments[$0].polyline.project(p).distance < area.segments[$1].polyline.project(p).distance }
            ?? rng.int(area.segments.count)
        var node = area.segments[startSeg].startNode
        var used = Set<Int>()
        var coords: [Coordinate] = []
        var total = 0.0
        while total < distance {
            let opts = area.graph.neighbours(of: node)
            guard !opts.isEmpty else { break }
            let fresh = opts.filter { !used.contains($0.segment) }
            let pick = (fresh.isEmpty ? opts : fresh)[rng.int((fresh.isEmpty ? opts : fresh).count)]
            used.insert(pick.segment)
            let s = area.segments[pick.segment]
            let pts = s.startNode == node ? s.coordinates : s.coordinates.reversed()
            coords.append(contentsOf: coords.isEmpty ? pts : Array(pts.dropFirst()))
            total += s.length
            node = pick.other
        }
        return coords
    }

    /// Samples a route at 1 Hz with realistic pace wobble and GPS noise.
    public func trace(along route: [Coordinate], start: Date, speed: Double = 3.0, noise: Double = 3.5, seed: UInt64) -> [TracePoint] {
        guard route.count > 1 else { return [] }
        var rng = SeededRandom(seed: seed)
        let proj = area.projection
        let line = Polyline(route.map(proj.project))
        var out: [TracePoint] = []
        var offset = 0.0
        var t = start
        var v = speed
        while offset <= line.length {
            let truth = proj.unproject(line.point(at: offset))
            let n = noise * (rng.unit() + rng.unit() + rng.unit() - 1.5)
            let pos = truth.offset(metres: abs(n), bearingDegrees: rng.unit() * 360)
            out.append(TracePoint(coordinate: pos, timestamp: t, horizontalAccuracy: 4 + rng.unit() * 6, speed: v))
            v = max(speed * 0.75, min(speed * 1.25, v + (rng.unit() - 0.5) * 0.3))
            offset += v
            t = t.addingTimeInterval(1)
        }
        return out
    }
}
