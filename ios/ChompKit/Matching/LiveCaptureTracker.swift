import Foundation

/// Live, provisional coin collection during a run: matches the recent window of
/// the trace and reports coins as the runner passes them. The authoritative
/// decision is made when the run is resolved (on device or server), using the
/// same coin positions and reach.
public struct LiveCaptureTracker: Sendable {
    public struct Update: Sendable {
        /// Streets where at least one coin was just collected.
        public var newlyEaten: [SegmentID]
        /// Coins just collected, by street.
        public var newCoins: [SegmentID: [Int]]
    }

    public let matcher: MapMatcher
    public let metresPerToken: Double
    public let reach: Double
    private var pieces: [CoveragePiece] = []
    private var processed = 0
    /// Every coin passed so far (whoever owned it).
    public private(set) var eaten: Set<CoinID> = []
    /// Coins in the order they were passed.
    public private(set) var eatenOrder: [CoinID] = []

    public init(matcher: MapMatcher, metresPerToken: Double, reach: Double) {
        self.matcher = matcher
        self.metresPerToken = metresPerToken
        self.reach = reach
    }

    public var allPieces: [CoveragePiece] { pieces }

    public mutating func ingest(trace: [TracePoint]) -> Update {
        guard trace.count >= 2 else { return Update(newlyEaten: [], newCoins: [:]) }
        let overlap = 20
        let from = max(0, processed - overlap)
        let window = Array(trace[from...])
        processed = trace.count
        let r = matcher.match(window)
        pieces.append(contentsOf: r.pieces)
        return collect(r.pieces)
    }

    private mutating func collect(_ new: [CoveragePiece]) -> Update {
        var coins: [SegmentID: [Int]] = [:]
        var order: [SegmentID] = []
        for p in new {
            let s = matcher.area.segments[p.segment]
            let n = Coins.count(length: s.length, metresPerToken: metresPerToken)
            let lo = min(p.from, p.to) - reach, hi = max(p.from, p.to) + reach
            // Walk the coins in the direction the runner went.
            let indexes = p.to >= p.from ? Array(0..<n) : Array((0..<n).reversed())
            for i in indexes {
                let o = Coins.offset(i, of: n, length: s.length)
                guard o >= lo, o <= hi else { continue }
                let id = Coins.id(s.id, i)
                guard eaten.insert(id).inserted else { continue }
                eatenOrder.append(id)
                if coins[s.id] == nil { order.append(s.id) }
                coins[s.id, default: []].append(i)
            }
        }
        return Update(newlyEaten: order, newCoins: coins)
    }

    /// Same tracker on a new (bigger) map: coins already passed stay passed
    /// and aren't reported again.
    public mutating func rebase(matcher: MapMatcher, trace: [TracePoint]) {
        let keep = eaten, order = eatenOrder
        self = LiveCaptureTracker(matcher: matcher, metresPerToken: metresPerToken, reach: reach)
        eaten = keep
        eatenOrder = order
        guard trace.count >= 2 else { return }
        let r = matcher.match(trace)
        pieces = r.pieces
        processed = trace.count
        _ = collect(r.pieces)
    }
}
