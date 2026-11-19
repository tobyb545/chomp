import Foundation
import Observation
import ChompKit

/// A run in progress: records GPS + motion, eats pellets live (provisionally),
/// drives the Live Activity, watch and haptics, then hands off for resolution.
@MainActor
@Observable
final class RunSession {
    enum Phase { case idle, running, paused, finishing }

    weak var model: AppModel?

    private(set) var phase: Phase = .idle
    private(set) var startedAt: Date?
    private(set) var trace: [TracePoint] = []
    private(set) var trail: [Coordinate] = []
    private(set) var distance: Double = 0
    private(set) var pelletsEaten = 0
    /// Coins taken from rivals this run.
    private(set) var coinsStolen = 0
    private(set) var pointsProvisional = 0
    private(set) var frenzyEndsAt: Date?
    private(set) var lastEatenName: String?
    private(set) var collectedThisRun: Set<String> = []
    private(set) var tracker: LiveCaptureTracker?
    private(set) var simulated = false
    /// A guided practice run: simulated, and thrown away at the end (nothing is captured).
    private(set) var practice = false
    private(set) var pausedDuration: TimeInterval = 0
    private var pausedAt: Date?
    private var runID = UUID()
    private var locationTask: Task<Void, Never>?
    private var motion = MotionRecorder()
    private var fixesSinceMatch = 0
    private var frenzyTimer: Task<Void, Never>?
    private var nextSplitAt: Double = 1000
    private var lastSplitTime: TimeInterval = 0
    private var splitIndex = 0

    var isActive: Bool { phase != .idle }
    var isFrenzy: Bool { (frenzyEndsAt ?? .distantPast) > .now }

    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        let end = pausedAt ?? .now
        return end.timeIntervalSince(startedAt) - pausedDuration
    }

    var paceSecondsPerKm: Double {
        let recent = trace.suffix(60)
        guard let a = recent.first, let b = recent.last, b.timestamp > a.timestamp else { return 0 }
        let d = RunMath.distance(Array(recent))
        return d > 20 ? b.timestamp.timeIntervalSince(a.timestamp) / (d / 1000) : 0
    }

    func startPractice() {
        start(simulated: true)
        guard phase == .running else { return }
        practice = true
        LiveActivityController.shared.end(liveState)
        // Short and sweet: it finishes itself after 45 seconds.
        let id = runID
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            if let self, self.practice, self.runID == id, self.phase == .running || self.phase == .paused { await self.finish() }
        }
    }

    func start(simulated: Bool) {
        guard phase == .idle, let model else { return }
        reset()
        self.simulated = simulated
        runID = UUID()
        let now = Date()
        startedAt = now
        phase = .running
        tracker = LiveCaptureTracker(matcher: model.matcher, metresPerToken: model.rules.tokens.metresPerToken, reach: model.rules.coinReach)
        let source: LocationSource
        if simulated {
            let sim = RouteSimulator(area: model.area)
            let origin = LocationPermission.shared.lastKnown.flatMap { model.area.contains($0) ? $0 : nil } ?? model.savedFocus.flatMap { model.area.contains($0) ? $0 : nil } ?? randomStart(model.area)
            // Follow the planned loop if there is one, so route planning can be tried in the simulator.
            let route = model.plannedRoute?.coordinates ?? sim.route(from: origin, distance: 3200, seed: UInt64.random(in: 1...UInt64.max))
            source = SimulatedLocationSource(points: sim.trace(along: route, start: now, speed: 3.1, seed: UInt64.random(in: 1...UInt64.max)),
                                             speedUp: 8)
        } else {
            source = LiveLocationSource()
            motion.start(at: now)
        }
        Feedback.shared.play(.start)
        let voice = RunVoice.shared
        voice.reset()
        voice.enabled = model.profile.voiceOn
        voice.splits = model.profile.voiceSplits
        nextSplitAt = model.profile.useMiles ? 1609.344 : 1000
        if let r = model.plannedRoute {
            voice.say("Run started. Your route is \(formatDistance(r.distance, miles: model.profile.useMiles)) with \(coinCount(r.tokens)) to collect.")
        } else {
            voice.say("Run started.")
        }
        LiveActivityController.shared.start(startedAt: now, colorHex: model.profile.colorHex, town: model.placeName)
        locationTask = Task { [weak self] in
            for await fix in source.stream() {
                guard let self else { return }
                self.ingest(fix)
            }
            // A simulated route ran out: finish automatically.
            if let self, self.simulated, self.phase == .running { await self.finish() }
        }
        model.mirrorToWatch()
        model.bumpMap()
    }

    /// New tiles loaded mid-run: re-match what we have against the bigger map,
    /// keeping the streets already eaten so nothing is announced twice.
    func areaDidChange() {
        guard phase == .running || phase == .paused, let model, var t = tracker else { return }
        t.rebase(matcher: model.matcher, trace: trace)
        tracker = t
    }

    private func randomStart(_ area: Area) -> Coordinate {
        area.segments.filter { !$0.isPath && $0.name.count > 0 }.randomElement()?.midpoint ?? area.center
    }

    func pause() {
        guard phase == .running else { return }
        phase = .paused
        pausedAt = .now
        RunVoice.shared.say("Paused.")
        pushLiveActivity()
    }

    func resume() {
        guard phase == .paused, let p = pausedAt else { return }
        pausedDuration += Date().timeIntervalSince(p)
        pausedAt = nil
        phase = .running
        RunVoice.shared.say("Resumed.")
        pushLiveActivity()
    }

    func discard() {
        locationTask?.cancel()
        RunVoice.shared.reset()
        _ = motion.stop(at: .now)
        LiveActivityController.shared.end(liveState)
        reset()
        model?.bumpMap()
        model?.mirrorToWatch()
    }

    func finish() async {
        guard phase == .running || phase == .paused, let model, let startedAt else { return }
        phase = .finishing
        locationTask?.cancel()
        let end = trace.last?.timestamp ?? .now
        if practice {
            locationTask = nil
            LiveActivityController.shared.end(liveState)
            RunVoice.shared.stop()
            Feedback.shared.play(.finish)
            model.practiceResult = .init(coins: pelletsEaten)
            reset()
            model.bumpMap()
            return
        }
        var signals = simulated ? RunSignals() : motion.stop(at: end)
        if !simulated { signals.heartRate = await HealthService.shared.heartRate(from: startedAt, to: end) }
        LiveActivityController.shared.end(liveState)
        Feedback.shared.play(.finish)
        RunVoice.shared.stop()
        RunVoice.shared.say("Run finished. \(coinCount(pelletsEaten))" + (coinsStolen > 0 ? ", \(coinsStolen) stolen from rivals." : "."))
        let captured = trace
        let id = runID
        let wasSimulated = simulated
        if captured.count >= 2 {
            await model.completeRun(id: id, trace: captured, signals: signals, startedAt: startedAt, endedAt: end, simulated: wasSimulated)
        }
        reset()
        model.bumpMap()
        model.mirrorToWatch()
    }

    private func reset() {
        phase = .idle
        startedAt = nil
        trace = []
        trail = []
        distance = 0
        pelletsEaten = 0
        coinsStolen = 0
        pointsProvisional = 0
        frenzyEndsAt = nil
        lastEatenName = nil
        collectedThisRun = []
        practice = false
        coinsTaken = [:]
        tracker = nil
        pausedDuration = 0
        pausedAt = nil
        fixesSinceMatch = 0
        nextSplitAt = 1000
        lastSplitTime = 0
        splitIndex = 0
        frenzyTimer?.cancel()
        motion = MotionRecorder()
    }

    private func ingest(_ fix: TracePoint) {
        guard phase == .running, let model else { return }
        if let last = trace.last {
            let step = fix.coordinate.distance(to: last.coordinate)
            let dt = fix.timestamp.timeIntervalSince(last.timestamp)
            if dt > 0, step / dt < 12, fix.horizontalAccuracy <= model.rules.matching.maxAccuracyMetres { distance += step }
        }
        trace.append(fix)
        if distance >= nextSplitAt {
            splitIndex += 1
            let unit = model.profile.useMiles ? 1609.344 : 1000
            let now = elapsed
            RunVoice.shared.split(index: splitIndex, miles: model.profile.useMiles,
                                  paceSecondsPerUnit: (now - lastSplitTime) * (simulated ? 8 : 1), coins: pelletsEaten)
            lastSplitTime = now
            nextSplitAt += unit
        }
        if fix.horizontalAccuracy <= model.rules.matching.maxAccuracyMetres { trail.append(fix.coordinate) }

        // Power pellets.
        for pellet in model.uncollectedPellets where !collectedThisRun.contains(pellet.id) {
            if fix.coordinate.distance(to: pellet.landmark.coordinate) <= model.rules.frenzy.collectRadiusMetres {
                collectedThisRun.insert(pellet.id)
                let end = Date().addingTimeInterval(model.rules.frenzy.durationSeconds / (simulated ? 8 : 1))
                frenzyEndsAt = max(frenzyEndsAt ?? .distantPast, end)
                Feedback.shared.play(.powerUp)
                model.toast = "FRENZY! Double points at \(pellet.landmark.name)"
                RunVoice.shared.say("Frenzy! Double points for \(Int(model.rules.frenzy.durationSeconds / 60)) minutes. Rivals' coins are easier to steal.")
                scheduleFrenzyEnd()
            }
        }

        fixesSinceMatch += 1
        if fixesSinceMatch >= 5 { runLiveMatch() }
        if trace.count % 20 == 1 { model.runMoved(to: fix.coordinate) }
        if trace.count % 3 == 0 { model.bumpMap() }
        if trace.count % 10 == 0 { pushLiveActivity(); model.mirrorToWatch() }
    }

    /// Coins taken this run (not counting ones that were already yours), by street.
    private(set) var coinsTaken: [SegmentID: [Int]] = [:]

    private func runLiveMatch() {
        guard var t = tracker, let model else { return }
        fixesSinceMatch = 0
        let state = model.state
        let decay = model.rules.decayInterval
        let me = state.me
        let update = t.ingest(trace: trace)
        tracker = t
        guard !update.newlyEaten.isEmpty else { return }
        var anyNew = false, anyStolen = false
        for segID in update.newlyEaten {
            guard let seg = model.area.segment(segID), let idx = update.newCoins[segID] else { continue }
            var gained = 0, stolenHere = 0
            for i in idx {
                let o = state.ownership[Coins.id(segID, i)].flatMap { $0.strength(at: .now, decay: decay) > 0 ? $0 : nil }
                if o?.owner == me { continue }
                if o != nil { stolenHere += 1 }
                gained += 1
                coinsTaken[segID, default: []].append(i)
            }
            guard gained > 0 else { continue }
            anyNew = true
            if stolenHere > 0 { coinsStolen += stolenHere; anyStolen = true }
            pelletsEaten += gained
            RunVoice.shared.captured(street: seg.displayName, tokens: gained, stolen: stolenHere)
            let mult = (isFrenzy ? model.rules.frenzy.multiplier : 1)
                * (model.activeBonus.filter { $0.segmentIDs.contains(segID) && $0.isActive(at: .now) }.map(\.multiplier).max() ?? 1)
            pointsProvisional += Int(seg.length / Double(model.rules.coinCount(seg)) * Double(gained) * model.rules.capture.pointsPerMetre * mult)
            lastEatenName = seg.displayName
        }
        if anyStolen {
            Feedback.shared.play(.steal)
        } else if anyNew {
            Feedback.shared.play(.pellet)
        }
        if anyNew, let name = lastEatenName { WatchBridge.shared.send([WatchMessage.capture: name]) }
        pushLiveActivity()
        model.bumpMap()
    }

    private func scheduleFrenzyEnd() {
        frenzyTimer?.cancel()
        guard let end = frenzyEndsAt else { return }
        frenzyTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self, self.phase != .idle else { return }
            Feedback.shared.play(.frenzyEnd)
            self.model?.toast = "Frenzy over"
            RunVoice.shared.say("Frenzy over.")
            self.pushLiveActivity()
        }
        pushLiveActivity()
        model?.mirrorToWatch()
    }

    var liveState: ChompRunAttributes.ContentState {
        .init(pelletsEaten: pelletsEaten, coinsStolen: coinsStolen, distanceMetres: distance,
              frenzyEndsAt: isFrenzy ? frenzyEndsAt : nil, isPaused: phase == .paused)
    }

    private func pushLiveActivity() {
        LiveActivityController.shared.update(liveState)
    }
}
