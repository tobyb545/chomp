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
                    await model.checkForNewHealthRuns()
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
                    // chomp://run/start (from widgets / shortcuts)
                    if url.host == "run", url.path == "/start" { IntentRouter.shared.requestStart() }
                    // chomp://invite/<code> (a friend's invite link)
                    if url.host == "invite", let code = url.pathComponents.dropFirst().first {
                        model.openInvite(code: code)
                    }
                    // chomp://club/<code> (a club's invite link)
                    if url.host == "club", let code = url.pathComponents.dropFirst().first {
                        model.openClubInvite(code: code)
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

    private var healthTitle: String {
        let n = model.healthPrompt?.runs.count ?? 0
        return n == 1 ? "New run in Apple Health" : "\(n) new runs in Apple Health"
    }

    private var healthMessage: String {
        guard let runs = model.healthPrompt?.runs else { return "" }
        let miles = model.profile.useMiles
        let lines = runs.prefix(3).map { r in
            [r.start.formatted(.dateTime.weekday(.wide).hour().minute()),
             r.distance.map { formatDistance($0, miles: miles) }, r.source].compactMap { $0 }.joined(separator: " · ")
        }
        let more = runs.count > 3 ? "\nand \(runs.count - 3) more" : ""
        return lines.joined(separator: "\n") + more + "\n\nImport \(runs.count == 1 ? "it" : "them") to collect the coins along the way?"
    }

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
        .alert(healthTitle, isPresented: Binding(get: { model.healthPrompt != nil }, set: { _ in })) {
            Button("Import") { Task { await model.answerHealthPrompt(importing: true) } }
            Button("Not now", role: .cancel) { Task { await model.answerHealthPrompt(importing: false) } }
        } message: {
            Text(healthMessage)
        }
        .overlay(alignment: .top) { ToastView() }
        .tint(Color(hex: model.profile.colorHex))
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
