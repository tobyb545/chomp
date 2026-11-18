import Foundation

/// WGS84 coordinate. Plain value type so ChompKit stays free of CoreLocation/MapKit.
public struct Coordinate: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Great-circle distance in metres.
    public func distance(to other: Coordinate) -> Double {
        let r = 6_371_008.8
        let φ1 = latitude * .pi / 180, φ2 = other.latitude * .pi / 180
        let dφ = φ2 - φ1
        let dλ = (other.longitude - longitude) * .pi / 180
        let a = sin(dφ / 2) * sin(dφ / 2) + cos(φ1) * cos(φ2) * sin(dλ / 2) * sin(dλ / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }

    /// Point `metres` away along `bearingDegrees` (small-distance approximation).
    public func offset(metres: Double, bearingDegrees: Double) -> Coordinate {
        let b = bearingDegrees * .pi / 180
        let dLat = metres * cos(b) / 110_540
        let dLon = metres * sin(b) / (111_320 * cos(latitude * .pi / 180))
        return Coordinate(latitude: latitude + dLat, longitude: longitude + dLon)
    }
}

/// Planar point in metres in a local projection.
public struct Vec2: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }

    @inlinable public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    @inlinable public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    @inlinable public static func * (a: Vec2, k: Double) -> Vec2 { Vec2(a.x * k, a.y * k) }
    @inlinable public func dot(_ o: Vec2) -> Double { x * o.x + y * o.y }
    @inlinable public var length: Double { (x * x + y * y).squareRoot() }
    @inlinable public func distance(to o: Vec2) -> Double { (self - o).length }
}

/// Local equirectangular projection. Accurate to well under 1% across a town,
/// which is all the matcher needs, and far cheaper than haversine in hot loops.
public struct LocalProjection: Sendable, Hashable {
    public let origin: Coordinate
    public let kx: Double
    public let ky: Double

    public init(origin: Coordinate) {
        self.origin = origin
        self.kx = 111_320 * cos(origin.latitude * .pi / 180)
        self.ky = 110_540
    }

    @inlinable public func project(_ c: Coordinate) -> Vec2 {
        Vec2((c.longitude - origin.longitude) * kx, (c.latitude - origin.latitude) * ky)
    }

    @inlinable public func unproject(_ v: Vec2) -> Coordinate {
        Coordinate(latitude: origin.latitude + v.y / ky, longitude: origin.longitude + v.x / kx)
    }
}

/// A polyline in projected metres with cumulative lengths, for linear referencing.
public struct Polyline: Sendable {
    public let points: [Vec2]
    public let cumulative: [Double]
    public var length: Double { cumulative.last ?? 0 }

    public init(_ points: [Vec2]) {
        self.points = points
        var c: [Double] = [0]
        c.reserveCapacity(points.count)
        for i in 1..<max(points.count, 1) {
            c.append(c[i - 1] + points[i].distance(to: points[i - 1]))
        }
        self.cumulative = c
    }

    public struct Projection: Sendable {
        public let distance: Double
        /// Metres from the polyline start.
        public let offset: Double
        public let point: Vec2
    }

    /// Closest point on the polyline to `p`.
    public func project(_ p: Vec2) -> Projection {
        var best = Projection(distance: .infinity, offset: 0, point: points.first ?? p)
        guard points.count >= 2 else {
            if let f = points.first { return Projection(distance: f.distance(to: p), offset: 0, point: f) }
            return best
        }
        for i in 0..<(points.count - 1) {
            let a = points[i], b = points[i + 1]
            let ab = b - a
            let l2 = ab.dot(ab)
            let t = l2 == 0 ? 0 : max(0, min(1, (p - a).dot(ab) / l2))
            let q = a + ab * t
            let d = q.distance(to: p)
            if d < best.distance {
                best = Projection(distance: d, offset: cumulative[i] + t * (cumulative[i + 1] - cumulative[i]), point: q)
            }
        }
        return best
    }

    /// Point at `offset` metres along the line.
    public func point(at offset: Double) -> Vec2 {
        guard points.count >= 2 else { return points.first ?? Vec2(0, 0) }
        let o = max(0, min(length, offset))
        var lo = 0, hi = cumulative.count - 1
        while lo + 1 < hi {
            let mid = (lo + hi) / 2
            if cumulative[mid] <= o { lo = mid } else { hi = mid }
        }
        let seg = cumulative[hi] - cumulative[lo]
        let t = seg == 0 ? 0 : (o - cumulative[lo]) / seg
        return points[lo] + (points[hi] - points[lo]) * t
    }

    /// Sub-polyline between two offsets (in increasing order).
    public func slice(from a: Double, to b: Double) -> [Vec2] {
        let lo = max(0, min(a, b)), hi = min(length, max(a, b))
        var out = [point(at: lo)]
        for i in 0..<points.count where cumulative[i] > lo && cumulative[i] < hi {
            out.append(points[i])
        }
        out.append(point(at: hi))
        return out
    }
}

/// Union of closed intervals on [0, length], used for "how much of this street did I run".
public struct IntervalSet: Codable, Hashable, Sendable {
    public private(set) var intervals: [ClosedRange<Double>] = []

    public init() {}
    public init(_ ranges: [ClosedRange<Double>]) { ranges.forEach { insert($0) } }

    public mutating func insert(_ r: ClosedRange<Double>) {
        var lo = r.lowerBound, hi = r.upperBound
        var kept: [ClosedRange<Double>] = []
        kept.reserveCapacity(intervals.count + 1)
        for iv in intervals {
            if iv.upperBound < lo || iv.lowerBound > hi {
                kept.append(iv)
            } else {
                lo = min(lo, iv.lowerBound)
                hi = max(hi, iv.upperBound)
            }
        }
        kept.append(lo...hi)
        kept.sort { $0.lowerBound < $1.lowerBound }
        intervals = kept
    }

    public mutating func formUnion(_ other: IntervalSet) {
        other.intervals.forEach { insert($0) }
    }

    public var coveredLength: Double {
        intervals.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
    }

    public var isEmpty: Bool { intervals.isEmpty }
}

/// Signed area (m²) of a closed ring; positive when counter-clockwise.
public func signedArea(_ ring: [Vec2]) -> Double {
    guard ring.count >= 3 else { return 0 }
    var a = 0.0
    for i in 0..<ring.count {
        let p = ring[i], q = ring[(i + 1) % ring.count]
        a += p.x * q.y - q.x * p.y
    }
    return a / 2
}

public func pointInRing(_ p: Vec2, _ ring: [Vec2]) -> Bool {
    var inside = false
    var j = ring.count - 1
    for i in 0..<ring.count {
        let a = ring[i], b = ring[j]
        if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
            inside.toggle()
        }
        j = i
    }
    return inside
}
