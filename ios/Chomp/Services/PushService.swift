import UIKit
import UserNotifications

/// Remote push (APNs): registers the device and hands its token to the backend,
/// which sends "coins lost", bot-raid and invite messages from notification_outbox.
final class ChompAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in PushService.shared.didRegister(token: hex) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Simulators without push support land here; local notifications still work.
    }

    // Show pushes as banners even while the app is open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}

@MainActor
final class PushService {
    static let shared = PushService()

    private(set) var token: String?
    weak var model: AppModel?

    /// Which pushes this device wants, from the player's settings.
    static func kinds(for profile: PlayerProfile) -> [String] {
        var k: [String] = ["invite"]
        if profile.pushLost { k.append("lost") }
        if profile.pushRaids { k.append("raid") }
        return k
    }

    nonisolated static func authorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { done in
            UNUserNotificationCenter.current().getNotificationSettings { done.resume(returning: $0.authorizationStatus) }
        }
    }

    static var environment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }

    /// Ask APNs for a token if the player has allowed notifications. Cheap to call on every launch.
    func refresh() async {
        let status = await Self.authorizationStatus()
        guard status == .authorized || status == .provisional else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    func didRegister(token: String) {
        self.token = token
        Task { await sync() }
    }

    /// Uploads the token and the player's choices when signed in and something changed.
    func sync() async {
        guard let model, let token, model.backend.isSignedIn, !model.profile.privateMode else { return }
        let kinds = Self.kinds(for: model.profile)
        let key = [token, model.backend.userID ?? "", Self.environment, kinds.joined(separator: ",")].joined(separator: "|")
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: "push.synced") != key else { return }
        do {
            try await model.backend.registerPushToken(token, environment: Self.environment, kinds: kinds)
            defaults.set(key, forKey: "push.synced")
        } catch {
            // Try again next launch or sync.
        }
    }

    /// Signing out (or going private) stops pushes to this device.
    func unregister() async {
        guard let model, let token else { return }
        try? await model.backend.unregisterPushToken(token)
        UserDefaults.standard.removeObject(forKey: "push.synced")
    }
}
