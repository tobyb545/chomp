import SwiftUI
import ChompKit

@main
struct ChompApp: App {
    @UIApplicationDelegateAdaptor(ChompAppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task {
                    IntentRouter.shared.model = model
                    PushService.shared.model = model
                    await model.bootstrap()
                    model.checkForAttacks()
                    model.locationApproximate = LocationPermission.shared.problem == .approximate
                    await PushService.shared.refresh()
                    IntentRouter.shared.flush()
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active: model.onForeground(); IntentRouter.shared.flush()
                    case .background: model.onBackground()
                    default: break
                    }
                }
                .onOpenURL { url in
                    // A run file shared to Chomp, or opened from Files.
                    if url.isFileURL {
                        Task { model.toast = await model.importRunFile(url) }
                        return
                    }
                    // chomp://run/start (from widgets / shortcuts)
                    if url.host == "run", url.path == "/start" { IntentRouter.shared.requestStart() }
                    // Invite and club links: chomp://invite/<code>, chomp://club/<code>,
                    // or the website's /invite/?c=<code> and /club/?c=<code> (universal links).
                    if let link = AppModel.parseLink(url) {
                        if link.kind == "invite" { model.openInvite(code: link.code) } else { model.openClubInvite(code: link.code) }
                    }
                }
        }
    }
}

/// Bridges App Intents / URLs into the running app.
@MainActor
final class IntentRouter {
    static let shared = IntentRouter()
    weak var model: AppModel?
    private var pendingStart = false
    private var pendingStop = false

    func requestStart() { pendingStart = true; flush() }
    func requestStop() { pendingStop = true; flush() }

    func flush() {
        guard let model, model.profile.onboarded else { return }
        if pendingStart, model.run.phase == .idle {
            pendingStart = false
            model.run.start(simulated: false)
        }
        if pendingStop {
            pendingStop = false
            Task { await model.run.finish() }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if !model.profile.seenIntro {
                IntroCardsView()
            } else if model.profile.onboarded {
                MapScreen()
            } else {
                OnboardingView()
            }
        }
        .sheet(item: $model.presentedSummary) { record in
            RunSummaryView(record: record)
        }
        .sheet(isPresented: $model.showPaywall) {
            PaywallView()
        }
        .sheet(item: $model.practiceResult) { r in PracticeResultView(result: r) }
        // Badge unlocks wait until the run summary (and any other prompt) is closed.
        .sheet(item: Binding(get: { model.presentedSummary == nil && model.practiceResult == nil ? model.pendingBadges.first : nil },
                             set: { if $0 == nil, !model.pendingBadges.isEmpty { model.pendingBadges.removeFirst() } })) { b in
            BadgeDetailView(badge: b, earnedAt: model.profile.badgesEarned[b.id], celebrate: true)
        }
        .sheet(isPresented: $model.showClubs) {
            NavigationStack {
                ClubsView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { model.showClubs = false } } }
            }
        }
        .sheet(isPresented: $model.showInvite) {
            NavigationStack {
                InviteView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { model.showInvite = false } } }
            }
        }
        .overlay(alignment: .top) { ToastView() }
        .tint(Theme.readableTint(model.profile.colorHex))
    }
}

struct ToastView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let t = model.toast {
            Text(t)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.hudText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Theme.hud, in: Capsule())
                .overlay(Capsule().strokeBorder(Color(hex: model.profile.colorHex).opacity(0.6)))
                .padding(.top, 8)
                .padding(.horizontal, 24)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: t) {
                    UIAccessibility.post(notification: .announcement, argument: t)
                    try? await Task.sleep(for: .seconds(3.5))
                    withAnimation { model.toast = nil }
                }
                .onTapGesture { withAnimation { model.toast = nil } }
        }
    }
}
