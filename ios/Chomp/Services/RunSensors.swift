import CoreLocation
import CoreMotion
import Foundation
import HealthKit
import ChompKit

// MARK: Location

protocol LocationSource: Sendable {
    /// Fixes until the task is cancelled.
    func stream() -> AsyncStream<TracePoint>
}

/// Real GPS via the iOS 17+ async location API. Uses the `.fitness` activity
/// profile and a CLBackgroundActivitySession so recording continues with
/// "While Using" permission while a run (and its Live Activity) is in progress.
struct LiveLocationSource: LocationSource {
    func stream() -> AsyncStream<TracePoint> {
        AsyncStream { continuation in
            let task = Task {
                let background = CLBackgroundActivitySession()
                let service = CLServiceSession(authorization: .whenInUse)
                defer { background.invalidate(); service.invalidate() }
                do {
                    for try await update in CLLocationUpdate.liveUpdates(.fitness) {
                        if Task.isCancelled { break }
                        guard let l = update.location else { continue }
                        continuation.yield(TracePoint(
                            coordinate: Coordinate(latitude: l.coordinate.latitude, longitude: l.coordinate.longitude),
                            timestamp: l.timestamp, horizontalAccuracy: l.horizontalAccuracy,
                            speed: l.speed, altitude: l.altitude))
                    }
                } catch {}
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Plays a believable run along real streets. Used in the simulator and for demos.
struct SimulatedLocationSource: LocationSource {
    let points: [TracePoint]
    /// 1 = real time; 10 = ten seconds of running per real second.
    let speedUp: Double

    func stream() -> AsyncStream<TracePoint> {
        AsyncStream { continuation in
            let task = Task {
                let wallStart = Date()
                guard let t0 = points.first?.timestamp else { continuation.finish(); return }
                for p in points {
                    let due = p.timestamp.timeIntervalSince(t0) / speedUp
                    let wait = due - Date().timeIntervalSince(wallStart)
                    if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                    if Task.isCancelled { break }
                    var q = p
                    // Present simulated fixes as if they were happening now.
                    q.timestamp = wallStart.addingTimeInterval(p.timestamp.timeIntervalSince(t0))
                    continuation.yield(q)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@MainActor
final class LocationPermission: NSObject, CLLocationManagerDelegate {
    static let shared = LocationPermission()
    private let manager = CLLocationManager()
    private var waiters: [CheckedContinuation<CLAuthorizationStatus, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
    }

    var status: CLAuthorizationStatus { manager.authorizationStatus }

    /// Checked without creating a prompt.
    nonisolated static var isAuthorized: Bool {
        let s = CLLocationManager().authorizationStatus
        return s == .authorizedWhenInUse || s == .authorizedAlways
    }

    func requestWhenInUse() async -> CLAuthorizationStatus {
        guard manager.authorizationStatus == .notDetermined else { return manager.authorizationStatus }
        return await withCheckedContinuation { c in
            waiters.append(c)
            manager.requestWhenInUseAuthorization()
        }
    }

    var lastKnown: Coordinate? {
        manager.location.map { Coordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        Task { @MainActor in
            guard s != .notDetermined else { return }
            let w = self.waiters
            self.waiters.removeAll()
            w.forEach { $0.resume(returning: s) }
        }
    }
}

// MARK: Motion

/// Activity type + cadence, for anti-cheat. Thread-safe sample buffer.
final class MotionRecorder: @unchecked Sendable {
    private let activity = CMMotionActivityManager()
    private let pedometer = CMPedometer()
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var motion: [MotionSample] = []
    private var cadence: [CadenceSample] = []
    private var steps = 0

    static var isAvailable: Bool { CMMotionActivityManager.isActivityAvailable() }

    func start(at date: Date) {
        queue.maxConcurrentOperationCount = 1
        if CMMotionActivityManager.isActivityAvailable() {
            activity.startActivityUpdates(to: queue) { [weak self] a in
                guard let self, let a else { return }
                let kind: MotionActivity = a.automotive ? .automotive : a.cycling ? .cycling : a.running ? .running
                    : a.walking ? .walking : a.stationary ? .stationary : .unknown
                self.lock.lock(); defer { self.lock.unlock() }
                if let last = self.motion.last { self.motion[self.motion.count - 1].end = max(last.start, a.startDate) }
                self.motion.append(MotionSample(start: a.startDate, end: a.startDate, activity: kind, confidence: a.confidence.rawValue))
            }
        }
        if CMPedometer.isCadenceAvailable() || CMPedometer.isStepCountingAvailable() {
            pedometer.startUpdates(from: date) { [weak self] data, _ in
                guard let self, let data else { return }
                self.lock.lock(); defer { self.lock.unlock() }
                self.steps = data.numberOfSteps.intValue
                if let c = data.currentCadence?.doubleValue {
                    self.cadence.append(CadenceSample(timestamp: data.endDate, stepsPerMinute: c * 60))
                }
            }
        }
    }

    func stop(at date: Date) -> RunSignals {
        activity.stopActivityUpdates()
        pedometer.stopUpdates()
        lock.lock(); defer { lock.unlock() }
        if !motion.isEmpty { motion[motion.count - 1].end = date }
        return RunSignals(motion: motion, cadence: cadence, heartRate: [])
    }
}

// MARK: HealthKit

@MainActor
final class HealthService {
    static let shared = HealthService()
    private let store = HKHealthStore()
    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private var share: Set<HKSampleType> {
        [HKObjectType.workoutType(), HKSeriesType.workoutRoute(), HKQuantityType(.distanceWalkingRunning)]
    }
    private var read: Set<HKObjectType> {
        [HKObjectType.workoutType(), HKSeriesType.workoutRoute(), HKQuantityType(.heartRate)]
    }

    func requestAuthorization() async -> Bool {
        guard isAvailable else { return false }
        do {
            try await store.requestAuthorization(toShare: share, read: read)
            return true
        } catch { return false }
    }

    /// Saves the run as an outdoor running workout with its route.
    func saveWorkout(start: Date, end: Date, distance: Double, trace: [TracePoint]) async throws {
        guard isAvailable else { return }
        let config = HKWorkoutConfiguration()
        config.activityType = .running
        config.locationType = .outdoor
        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())
        try await builder.beginCollection(at: start)
        let sample = HKQuantitySample(type: HKQuantityType(.distanceWalkingRunning),
                                      quantity: HKQuantity(unit: .meter(), doubleValue: distance), start: start, end: end)
        try await builder.addSamples([sample])
        try await builder.endCollection(at: end)
        guard let workout = try await builder.finishWorkout() else { return }
        let route = HKWorkoutRouteBuilder(healthStore: store, device: .local())
        let locations = trace.map {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude),
                       altitude: $0.altitude, horizontalAccuracy: $0.horizontalAccuracy, verticalAccuracy: -1,
                       course: -1, speed: $0.speed, timestamp: $0.timestamp)
        }
        if !locations.isEmpty {
            try await route.insertRouteData(locations)
            try await route.finishRoute(with: workout, metadata: nil)
        }
    }

    /// Heart rate recorded (e.g. by an Apple Watch) during the run, for anti-cheat.
    func heartRate(from start: Date, to end: Date) async -> [HeartRateSample] {
        guard isAvailable else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let descriptor = HKSampleQueryDescriptor(predicates: [.quantitySample(type: HKQuantityType(.heartRate), predicate: predicate)],
                                                 sortDescriptors: [SortDescriptor(\.startDate)])
        let unit = HKUnit.count().unitDivided(by: .minute())
        let samples = (try? await descriptor.result(for: store)) ?? []
        return samples.map { HeartRateSample(timestamp: $0.startDate, bpm: $0.quantity.doubleValue(for: unit)) }
    }

    struct ImportedRun: Sendable {
        let start: Date
        let end: Date
        let trace: [TracePoint]
    }

    /// Past running workouts with routes, for seeding personal exploration.
    func pastRuns(since: Date, limit: Int = 200) async -> [ImportedRun] {
        guard isAvailable else { return [] }
        let predicate = HKQuery.predicateForWorkouts(with: .running)
        let dates = HKQuery.predicateForSamples(withStart: since, end: .now)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(NSCompoundPredicate(andPredicateWithSubpredicates: [predicate, dates]))],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)], limit: limit)
        let workouts = (try? await descriptor.result(for: store)) ?? []
        var out: [ImportedRun] = []
        for w in workouts {
            let routes = await routes(for: w)
            var trace: [TracePoint] = []
            for r in routes { trace += await locations(for: r) }
            if trace.count > 10 { out.append(ImportedRun(start: w.startDate, end: w.endDate, trace: trace)) }
        }
        return out
    }

    private func routes(for workout: HKWorkout) async -> [HKWorkoutRoute] {
        let d = HKSampleQueryDescriptor(predicates: [.workoutRoute(HKQuery.predicateForObjects(from: workout))], sortDescriptors: [])
        return (try? await d.result(for: store)) ?? []
    }

    private func locations(for route: HKWorkoutRoute) async -> [TracePoint] {
        await withCheckedContinuation { (c: CheckedContinuation<[TracePoint], Never>) in
            final class Box: @unchecked Sendable { var pts: [TracePoint] = []; var done = false }
            let box = Box()
            let q = HKWorkoutRouteQuery(route: route) { _, locs, finished, error in
                for l in locs ?? [] {
                    box.pts.append(TracePoint(coordinate: Coordinate(latitude: l.coordinate.latitude, longitude: l.coordinate.longitude),
                                              timestamp: l.timestamp, horizontalAccuracy: l.horizontalAccuracy, speed: l.speed, altitude: l.altitude))
                }
                if (finished || error != nil) && !box.done { box.done = true; c.resume(returning: box.pts) }
            }
            store.execute(q)
        }
    }
}
