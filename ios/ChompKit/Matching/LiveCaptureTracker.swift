import Foundation

/// Incremental, provisional capture detection while running. Re-matches a
/// sliding window of recent fixes and unions coverage, so cost stays flat no
/// matter how long the run is. Final results always come from a full match.
public struct LiveCaptureTracker: Sendable {
    public struct Update: Sendable {
        /// Streets that just crossed the capture threshold (pellets eaten).
        public var newlyEaten: [SegmentID]
        /// Rival/bot streets among those.
        public var newlyStolen: [SegmentID]
        /// Coverage ratio of streets touched in this window.
        public var touched: [SegmentID: Double]
    }

    public let matcher: MapMatcher
    public let threshold: Double
    private var pieces: [CoveragePiece] = []
    private var coverage: [Int: IntervalSet] = [:]
    private var processed = 0
    public private(set) var eaten: Set<SegmentID> = []
    public private(set) var eatenOrder: [SegmentID] = []

    public init(matcher: MapMatcher, threshold: Double) {
        self.matcher = matcher
        self.threshold = threshold
    }

    public var allPieces: [CoveragePiece] { pieces }

    public mutating func ingest(trace: [TracePoint], isRival: (SegmentID) -> Bool, frenzy: Bool, frenzyThreshold: Double) -> Update {
        guard trace.count >= 2 else { return Update(newlyEaten: [], newlyStolen: [], touched: [:]) }
        let overlap = 20
        let from = max(0, processed - overlap)
        let window = Array(trace[from...])
        processed = trace.count
        let r = matcher.match(window)
        pieces.append(contentsOf: r.pieces)
        var touched: [SegmentID: Double] = [:]
        var newly: [SegmentID] = []
        var stolen: [SegmentID] = []
        for p in r.pieces {
            coverage[p.segment, default: IntervalSet()].insert(p.from...p.to)
        }
        for seg in Set(r.pieces.map(\.segment)) {
            let s = matcher.area.segments[seg]
            let ratio = min(1, (coverage[seg]?.coveredLength ?? 0) / max(s.length, 0.1))
            touched[s.id] = ratio
            let rival = isRival(s.id)
            let need = (frenzy && rival) ? min(threshold, frenzyThreshold) : threshold
            if ratio >= need, !eaten.contains(s.id) {
                eaten.insert(s.id)
                eatenOrder.append(s.id)
                newly.append(s.id)
                if rival { stolen.append(s.id) }
            }
        }
        return Update(newlyEaten: newly, newlyStolen: stolen, touched: touched)
    }

    public func ratio(for id: SegmentID) -> Double {
        guard let i = matcher.area.segmentIndex(id) else { return 0 }
        return min(1, (coverage[i]?.coveredLength ?? 0) / max(matcher.area.segments[i].length, 0.1))
    }
}
