import Foundation

public enum MotionActivity: String, Codable, Sendable {
    case stationary, walking, running, cycling, automotive, unknown
}

public struct MotionSample: Codable, Hashable, Sendable {
    public var start: Date
    public var end: Date
    public var activity: MotionActivity
    /// 0 low, 1 medium, 2 high (CMMotionActivityConfidence)
    public var confidence: Int
    public init(start: Date, end: Date, activity: MotionActivity, confidence: Int) {
        self.start = start; self.end = end; self.activity = activity; self.confidence = confidence
    }
}

public struct CadenceSample: Codable, Hashable, Sendable {
    public var timestamp: Date
    public var stepsPerMinute: Double
    public init(timestamp: Date, stepsPerMinute: Double) { self.timestamp = timestamp; self.stepsPerMinute = stepsPerMinute }
}

public struct HeartRateSample: Codable, Hashable, Sendable {
    public var timestamp: Date
    public var bpm: Double
    public init(timestamp: Date, bpm: Double) { self.timestamp = timestamp; self.bpm = bpm }
}

/// Non-GPS evidence collected during a run.
public struct RunSignals: Codable, Hashable, Sendable {
    public var motion: [MotionSample] = []
    public var cadence: [CadenceSample] = []
    public var heartRate: [HeartRateSample] = []
    public init(motion: [MotionSample] = [], cadence: [CadenceSample] = [], heartRate: [HeartRateSample] = []) {
        self.motion = motion; self.cadence = cadence; self.heartRate = heartRate
    }
}

public enum FlagSeverity: Int, Codable, Sendable, Comparable {
    case low = 0, medium = 1, high = 2
    public static func < (a: FlagSeverity, b: FlagSeverity) -> Bool { a.rawValue < b.rawValue }
}

public struct AntiCheatFlag: Codable, Hashable, Sendable {
    public var rule: String
    public var severity: FlagSeverity
    public var detail: String
}

public enum RunVerdict: String, Codable, Sendable {
    /// Everything outside `excluded` windows counts.
    case accepted
    /// Strong evidence of cheating: no ownership changes until a human reviews it.
    case underReview
}

public struct AntiCheatReport: Codable, Hashable, Sendable {
    public var verdict: RunVerdict
    public var flags: [AntiCheatFlag]
    /// Time windows whose coverage is discarded (too fast, vehicle, teleport).
    public var excluded: [DateInterval]

    public func isExcluded(_ piece: CoveragePiece) -> Bool {
        let mid = piece.start.addingTimeInterval(piece.end.timeIntervalSince(piece.start) / 2)
        return excluded.contains { $0.contains(mid) || $0.contains(piece.start) && $0.contains(piece.end) }
    }

    public static let clean = AntiCheatReport(verdict: .accepted, flags: [], excluded: [])
}

public enum AntiCheat {
    public static func evaluate(trace: [TracePoint], signals: RunSignals, rules: RulesConfig.AntiCheat,
                                matching: RulesConfig.Matching) -> AntiCheatReport {
        var flags: [AntiCheatFlag] = []
        var excluded: [DateInterval] = []
        let pts = trace.filter { $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= matching.maxAccuracyMetres }
            .sorted { $0.timestamp < $1.timestamp }
        guard pts.count >= 2 else {
            return AntiCheatReport(verdict: .accepted, flags: [], excluded: [])
        }

        // Implied speeds between consecutive fixes.
        var legs: [(t0: Date, t1: Date, d: Double, v: Double)] = []
        for i in 1..<pts.count {
            let dt = pts[i].timestamp.timeIntervalSince(pts[i - 1].timestamp)
            guard dt > 0 else { continue }
            let d = pts[i].coordinate.distance(to: pts[i - 1].coordinate)
            legs.append((pts[i - 1].timestamp, pts[i].timestamp, d, d / dt))
        }

        // 1. Teleports.
        let teleport = rules.teleportSpeedKmh / 3.6
        let teleports = legs.filter { $0.v > teleport && $0.d > 50 }
        if !teleports.isEmpty {
            flags.append(.init(rule: "teleport", severity: teleports.count >= 3 ? .high : .medium,
                               detail: "\(teleports.count) jump(s), fastest \(Int(teleports.map(\.v).max()! * 3.6)) km/h"))
            excluded += teleports.map { DateInterval(start: $0.t0.addingTimeInterval(-15), end: $0.t1.addingTimeInterval(15)) }
        }

        // 2. Sustained speed over a rolling window.
        let maxV = rules.maxSustainedSpeedKmh / 3.6
        let window = rules.sustainedWindowSeconds
        var j = 0
        var dist = 0.0
        var fastTime = 0.0
        for i in 0..<legs.count {
            dist += legs[i].d
            while legs[i].t1.timeIntervalSince(legs[j].t0) > window, j < i {
                dist -= legs[j].d
                j += 1
            }
            let span = legs[i].t1.timeIntervalSince(legs[j].t0)
            if span >= window * 0.75, dist / span > maxV {
                excluded.append(DateInterval(start: legs[j].t0, end: legs[i].t1))
                fastTime += legs[i].t1.timeIntervalSince(legs[i].t0)
            }
        }
        if fastTime > 0 {
            flags.append(.init(rule: "speed", severity: fastTime > 300 ? .medium : .low,
                               detail: "\(Int(fastTime))s above \(Int(rules.maxSustainedSpeedKmh)) km/h"))
        }

        // 3. Impossible acceleration (needs 3 consecutive violations to ignore GPS jitter).
        var accelRun = 0, accelHits = 0
        for i in 1..<legs.count {
            let dt = legs[i].t1.timeIntervalSince(legs[i - 1].t1)
            guard dt > 0 else { continue }
            if abs(legs[i].v - legs[i - 1].v) / dt > rules.maxAccelerationMps2 {
                accelRun += 1
                if accelRun >= 3 { accelHits += 1 }
            } else { accelRun = 0 }
        }
        if accelHits > 0 {
            flags.append(.init(rule: "acceleration", severity: accelHits > 5 ? .high : .medium,
                               detail: "\(accelHits) bursts above \(rules.maxAccelerationMps2) m/s²"))
        }

        // 4. Synthetic traces: dead-straight, constant-speed, perfectly regular fixes.
        let straight = straightLineSeconds(pts, window: rules.straightLineWindowSeconds)
        if straight >= rules.straightLineWindowSeconds {
            flags.append(.init(rule: "straight_line", severity: straight > 3 * rules.straightLineWindowSeconds ? .high : .medium,
                               detail: "\(Int(straight))s of machine-straight constant-speed movement"))
        }
        let accs = Set(pts.map { ($0.horizontalAccuracy * 10).rounded() })
        let intervals = (1..<pts.count).map { pts[$0].timestamp.timeIntervalSince(pts[$0 - 1].timestamp) }
        let regular = intervals.count > 120 && intervals.allSatisfy { abs($0 - intervals[0]) < 0.001 }
        if pts.count > 120, accs.count == 1, regular {
            flags.append(.init(rule: "synthetic", severity: .high, detail: "identical accuracy and perfectly regular timestamps"))
        }

        // 5. Motion activity.
        let motion = signals.motion.filter { $0.confidence >= 1 }
        let totalMotion = motion.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        if totalMotion > 60 {
            func share(_ a: MotionActivity) -> Double {
                motion.filter { $0.activity == a }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) } / totalMotion
            }
            let auto = share(.automotive), cyc = share(.cycling)
            if auto > rules.maxAutomotiveFraction {
                flags.append(.init(rule: "automotive", severity: .high, detail: "\(Int(auto * 100))% of the run looked like driving"))
            }
            if cyc > rules.maxCyclingFraction {
                flags.append(.init(rule: "cycling", severity: .high, detail: "\(Int(cyc * 100))% of the run looked like cycling"))
            }
            excluded += motion.filter { ($0.activity == .automotive || $0.activity == .cycling) && $0.confidence == 2 }
                .map { DateInterval(start: $0.start, end: max($0.start, $0.end)) }
        }

        // 6. Cadence: running pace with no steps means wheels.
        let runPace = rules.runningSpeedForCadenceCheckMps
        let fastLegs = legs.filter { $0.v >= runPace && $0.v <= maxV }
        let fastSeconds = fastLegs.reduce(0) { $0 + $1.t1.timeIntervalSince($1.t0) }
        if fastSeconds > 120 {
            let cadences = fastLegs.compactMap { leg in nearest(signals.cadence, to: leg.t1, within: 30)?.stepsPerMinute }
            if cadences.count >= 5 {
                let med = cadences.sorted()[cadences.count / 2]
                if med < rules.minRunningCadenceSpm {
                    flags.append(.init(rule: "cadence", severity: .medium,
                                       detail: "median \(Int(med)) spm while moving at running pace"))
                }
            } else if signals.cadence.isEmpty && signals.motion.isEmpty {
                flags.append(.init(rule: "no_motion_data", severity: .low, detail: "no pedometer or motion data"))
            }
        }

        // 7. Heart rate (only a weak signal; many runners have no watch).
        if fastSeconds > 300, !signals.heartRate.isEmpty {
            let hrs = fastLegs.compactMap { nearest(signals.heartRate, to: $0.t1, within: 20)?.bpm }
            if hrs.count >= 10 {
                let avg = hrs.reduce(0, +) / Double(hrs.count)
                if avg < rules.lowHeartRateBpm {
                    flags.append(.init(rule: "heart_rate", severity: .low, detail: "average \(Int(avg)) bpm at running pace"))
                }
            }
        }

        let highs = flags.filter { $0.severity == .high }.count
        let mediums = flags.filter { $0.severity == .medium }.count
        let verdict: RunVerdict = (highs > 0 || mediums >= 3) ? .underReview : .accepted
        return AntiCheatReport(verdict: verdict, flags: flags, excluded: merge(excluded))
    }

    static func nearest<T>(_ samples: [T], to t: Date, within: TimeInterval) -> T? where T: TimeStamped {
        var best: T?
        var bestD = within
        for s in samples {
            let d = abs(s.time.timeIntervalSince(t))
            if d <= bestD { bestD = d; best = s }
        }
        return best
    }

    /// Longest stretch (seconds) where heading and speed are both machine-constant.
    static func straightLineSeconds(_ pts: [TracePoint], window: TimeInterval) -> Double {
        guard pts.count > 10 else { return 0 }
        var longest = 0.0
        var start = 0
        func heading(_ a: TracePoint, _ b: TracePoint) -> Double {
            atan2(b.coordinate.longitude - a.coordinate.longitude, b.coordinate.latitude - a.coordinate.latitude) * 180 / .pi
        }
        var refHeading = heading(pts[0], pts[1])
        var refSpeed = pts[1].coordinate.distance(to: pts[0].coordinate) / max(0.001, pts[1].timestamp.timeIntervalSince(pts[0].timestamp))
        for i in 2..<pts.count {
            let dt = max(0.001, pts[i].timestamp.timeIntervalSince(pts[i - 1].timestamp))
            let v = pts[i].coordinate.distance(to: pts[i - 1].coordinate) / dt
            var dh = abs(heading(pts[i - 1], pts[i]) - refHeading)
            if dh > 180 { dh = 360 - dh }
            let constant = v > 1 && dh < 0.5 && abs(v - refSpeed) / max(refSpeed, 0.1) < 0.02
            if !constant {
                longest = max(longest, pts[i - 1].timestamp.timeIntervalSince(pts[start].timestamp))
                start = i - 1
                refHeading = heading(pts[i - 1], pts[i])
                refSpeed = v
            }
        }
        return max(longest, pts[pts.count - 1].timestamp.timeIntervalSince(pts[start].timestamp))
    }

    static func merge(_ xs: [DateInterval]) -> [DateInterval] {
        let s = xs.sorted { $0.start < $1.start }
        var out: [DateInterval] = []
        for x in s {
            if let last = out.last, x.start <= last.end {
                out[out.count - 1] = DateInterval(start: last.start, end: max(last.end, x.end))
            } else {
                out.append(x)
            }
        }
        return out
    }
}

protocol TimeStamped { var time: Date { get } }
extension CadenceSample: TimeStamped { var time: Date { timestamp } }
extension HeartRateSample: TimeStamped { var time: Date { timestamp } }
