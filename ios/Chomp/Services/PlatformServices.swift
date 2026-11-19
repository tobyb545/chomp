import ActivityKit
import CoreLocation
import Foundation
import UserNotifications
import WatchConnectivity
import WidgetKit
import ChompKit

// MARK: Live Activity

@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()
    private var activity: Activity<ChompRunAttributes>?

    func start(startedAt: Date, colorHex: String, town: String) {
        endAll()  // never two on the lock screen
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attrs = ChompRunAttributes(startedAt: startedAt, playerColorHex: colorHex, townName: town)
        let state = ChompRunAttributes.ContentState(pelletsEaten: 0, coinsStolen: 0, distanceMetres: 0, frenzyEndsAt: nil, isPaused: false)
        activity = try? Activity.request(attributes: attrs, content: .init(state: state, staleDate: nil))
    }

    func update(_ state: ChompRunAttributes.ContentState) {
        guard let id = activity?.id else { return }
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(120))
        Task.detached { await Self.update(id: id, content) }
    }

    /// The run is over: take it off the lock screen straight away.
    func end(_ state: ChompRunAttributes.ContentState) {
        activity = nil
        endAll(state)
    }

    /// Ends every Chomp activity, including any left behind if the app was
    /// closed mid-run. Called at launch when no run is going.
    func endAll(_ state: ChompRunAttributes.ContentState? = nil) {
        let keep = activity?.id
        let content = state.map { ActivityContent(state: $0, staleDate: nil) }
        Task.detached { await Self.end(except: keep, content) }
    }

    // Activities aren't Sendable, so they're looked up by ID off the main actor
    // rather than handed across (Xcode 26's compiler rejects that).
    private nonisolated static func update(id: String, _ content: ActivityContent<ChompRunAttributes.ContentState>) async {
        guard let a = Activity<ChompRunAttributes>.activities.first(where: { $0.id == id }) else { return }
        await a.update(content)
    }

    private nonisolated static func end(except keep: String?, _ content: ActivityContent<ChompRunAttributes.ContentState>?) async {
        for a in Activity<ChompRunAttributes>.activities where a.id != keep {
            await a.end(content, dismissalPolicy: .immediate)
        }
    }
}

// MARK: Notifications

@MainActor
enum NotificationService {
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Schedules the next local raid message for exactly when it will happen.
    static func scheduleRaid(message: String, at date: Date) {
        let c = UNMutableNotificationContent()
        c.title = "Coins lost"
        c.body = message
        c.sound = .default
        c.threadIdentifier = "raids"
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let req = UNNotificationRequest(identifier: "bot-raid", content: c,
                                        trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
        UNUserNotificationCenter.current().add(req)
    }

    static func cancelRaid() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["bot-raid"])
    }

    static func fadeWarning(count: Int, at date: Date) {
        guard count > 0 else { return }
        let c = UNMutableNotificationContent()
        c.title = "Coins fading"
        c.body = "\(coinCount(count)) of yours fade back to silver soon. A quick run keeps them yours."
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "fade-warning", content: c,
                                                                      trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
    }
}

// MARK: Widgets

enum WidgetBridge {
    static func publish(_ snapshot: WidgetSnapshot) {
        snapshot.save()
        WidgetCenter.shared.reloadAllTimelines()
    }
}

// MARK: Watch

/// Phone side of WatchConnectivity: mirrors run state to the watch and accepts
/// start/stop commands from it.
final class WatchBridge: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchBridge()
    var onCommand: (@MainActor (String) -> Void)?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func send(_ payload: [String: Any]) {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        guard s.activationState == .activated, s.isPaired, s.isWatchAppInstalled else { return }
        if s.isReachable {
            s.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        } else {
            try? s.updateApplicationContext(payload)
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let cmd = message[WatchMessage.command] as? String else { return }
        Task { @MainActor in self.onCommand?(cmd) }
    }
}

/// Friendly name for where the player is ("West Byfleet", "Hackney"), from
/// Apple's reverse geocoder. Only a tile centre is sent, never a run.
enum PlaceNamer {
    @MainActor private static var cache: [String: String] = [:]

    @MainActor
    static func name(for c: Coordinate) async -> String? {
        let key = String(format: "%.3f,%.3f", c.latitude, c.longitude)
        if let hit = cache[key] { return hit }
        let marks = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: c.latitude, longitude: c.longitude))
        guard let m = marks?.first, let name = m.subLocality ?? m.locality ?? m.subAdministrativeArea ?? m.name else { return nil }
        cache[key] = name
        return name
    }
}
