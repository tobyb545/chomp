import ActivityKit
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
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attrs = ChompRunAttributes(startedAt: startedAt, playerColorHex: colorHex, townName: town)
        let state = ChompRunAttributes.ContentState(pelletsEaten: 0, streetsCaptured: 0, streetsStolen: 0, distanceMetres: 0, frenzyEndsAt: nil, isPaused: false)
        activity = try? Activity.request(attributes: attrs, content: .init(state: state, staleDate: nil))
    }

    func update(_ state: ChompRunAttributes.ContentState) {
        guard let activity else { return }
        Task { await activity.update(.init(state: state, staleDate: Date().addingTimeInterval(120))) }
    }

    func end(_ state: ChompRunAttributes.ContentState) {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(60 * 15))) }
    }
}

// MARK: Notifications

@MainActor
enum NotificationService {
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Schedules the bots' next raid message for exactly when it will happen.
    static func scheduleRaid(message: String, at date: Date) {
        let c = UNMutableNotificationContent()
        c.title = "Your streets are under attack"
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
        c.title = "Streets fading"
        c.body = "\(count) of your streets fade back to neutral soon. A quick run keeps them yours."
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
