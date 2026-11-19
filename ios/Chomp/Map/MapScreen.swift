import SwiftUI
import ChompKit

/// Home screen: the map around you with a big start button. Pan anywhere and
/// the streets there load too.
struct MapScreen: View {
    @Environment(AppModel.self) private var model
    @State private var follow = true
    @State private var sheet: Sheet?
    @State private var startConfirm = false
    @State private var locationProblem: LocationPermission.Problem?
    @State private var seenEvents = 0

    enum Sheet: String, Identifiable { case leaderboard, activity, profile, streets, goals, route; var id: String { rawValue } }

    var body: some View {
        let snapshot = model.mapSnapshot()
        ZStack {
            GameMapView(area: model.area, snapshot: snapshot,
                        camera: model.run.isActive && follow ? .follow : .free,
                        focus: model.focusRequest,
                        onUserPan: { follow = false },
                        onRegionChange: { c, zoom in model.mapSettled(at: c, zoom: zoom) })
                .ignoresSafeArea()
                .accessibilityElement()
                .accessibilityLabel(mapAccessibilityLabel)
                .accessibilityHint("Use the Coins nearby button for a list of where the coins are and who holds them.")

            VStack(spacing: 10) {
                if model.run.isActive {
                    RunHUDView(follow: $follow)
                        .overlay(alignment: .bottom) { if model.run.practice { PracticeCoach().padding(.bottom, 170) } }
                } else {
                    TownHeader(onGoals: { sheet = .goals })
                    WorldStatusBanner()
                    if let report = model.attackReport { AttackBanner(report: report) }
                    if model.locationApproximate { PreciseLocationBanner() }
                    Spacer()
                    sideButtons
                    if let r = model.plannedRoute { plannedRouteBar(r) }
                    startButton
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .background(Color(hex: "07070E"))
        .sheet(item: $sheet) { s in
            switch s {
            case .leaderboard: LeaderboardView()
            case .activity: ActivityFeedView().onAppear { seenEvents = model.state.events.count }
            case .profile: ProfileView()
            case .streets: StreetListView()
            case .goals: GoalsSheet()
            case .route: RoutePlannerSheet()
            }
        }
        .alert(locationProblem == .off ? "Location is off for Chomp" : "Precise Location is off",
               isPresented: Binding(get: { locationProblem != nil }, set: { if !$0 { locationProblem = nil } })) {
            Button("Open Settings") {
                locationProblem = nil
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            if locationProblem == .approximate {
                Button("Run anyway") { locationProblem = nil; Task { model.run.start(simulated: false) } }
            }
            Button("Cancel", role: .cancel) { locationProblem = nil }
        } message: {
            Text(locationProblem == .off
                 ? "Chomp needs your location during a run to see which coins you pass. In Settings, tap Location and choose While Using the App."
                 : "With approximate location, Chomp can't tell which coins you pass, so you won't collect any. In Settings, tap Location and turn on Precise Location.")
        }
        .confirmationDialog("Start a run", isPresented: $startConfirm) {
            Button("Run for real") { start(simulated: false) }
            Button("Simulated run (demo)") { start(simulated: true) }
        } message: {
            Text("Simulated runs replay a believable route through the map on screen at 8× speed. Handy for trying the game in the simulator.")
        }
        .onAppear { seenEvents = UserDefaults.standard.integer(forKey: "seenEvents") }
        // Practice run requested (onboarding or Profile): start it once streets are loaded.
        .task(id: "\(model.wantsPractice)-\(model.area.segments.count)-\(sheet == nil)") {
            guard model.wantsPractice, !model.area.segments.isEmpty, model.run.phase == .idle, sheet == nil else { return }
            model.wantsPractice = false
            try? await Task.sleep(for: .milliseconds(600))
            model.run.startPractice()
        }
        .onChange(of: seenEvents) { _, v in UserDefaults.standard.set(v, forKey: "seenEvents") }
    }

    private var mapAccessibilityLabel: String {
        let p = model.progress
        return "Map of \(model.placeName). You hold \(coinCount(p.coinsHeld)) here, \(p.heldFraction.percentString) of the coins nearby. "
            + "\(model.uncollectedPellets.count) power-ups on the map today."
    }

    private var sideButtons: some View {
        HStack(alignment: .bottom) {
            VStack(spacing: 10) {
                RoundIconButton(symbol: "trophy.fill", label: "Leaderboards") { sheet = .leaderboard }
                RoundIconButton(symbol: "bell.fill", label: "Activity", badge: max(0, model.state.events.count - seenEvents)) { sheet = .activity }
                RoundIconButton(symbol: "list.bullet", label: "Coins nearby") { sheet = .streets }
                RoundIconButton(symbol: "point.topleft.down.to.point.bottomright.curvepath.fill",
                                label: model.plannedRoute == nil ? "Plan a route" : "Planned route") { sheet = .route }
            }
            Spacer()
            VStack(spacing: 10) {
                if model.pro.isPro {
                    RoundIconButton(symbol: model.heatmapOn ? "flame.fill" : "flame", label: model.heatmapOn ? "Hide heatmap" : "Show heatmap") {
                        model.heatmapOn.toggle()
                    }
                }
                RoundIconButton(symbol: "location.fill", label: "Centre on me") {
                    Task {
                        _ = await LocationPermission.shared.requestWhenInUse()
                        await model.locateAndLoad()
                    }
                }
                RoundIconButton(symbol: "person.crop.circle.fill", label: "Profile and settings") { sheet = .profile }
            }
        }
    }

    private func plannedRouteBar(_ r: PlannedRoute) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill").foregroundStyle(Color(hex: "38E8FF"))
            Text("Route · \(formatDistance(r.distance, miles: model.profile.useMiles)) · \(coinCount(r.tokens))")
                .font(.footnote.weight(.bold)).foregroundStyle(Theme.hudText).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            Button { model.plannedRoute = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.hudSecondary) }
                .accessibilityLabel("Clear planned route")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color(hex: "11111F").opacity(0.92), in: Capsule())
        .accessibilityElement(children: .contain)
    }

    private var startButton: some View {
        Button {
            #if targetEnvironment(simulator)
            startConfirm = true
            #else
            start(simulated: false)
            #endif
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "play.fill")
                Text("START RUN")
            }
        }
        .buttonStyle(ChunkyButtonStyle(colorHex: model.profile.colorHex, height: 76))
        #if DEBUG
        .contextMenu {
            Button("Simulated run (demo)", systemImage: "wand.and.stars") { start(simulated: true) }
        }
        #endif
        .accessibilityHint("Starts recording. Coins you run past become yours.")
    }

    private func start(simulated: Bool) {
        follow = true
        guard !model.area.segments.isEmpty else {
            model.toast = "The coins are still loading. Give it a moment."
            return
        }
        Task {
            if !simulated {
                let status = await LocationPermission.shared.requestWhenInUse()
                guard status == .authorizedWhenInUse || status == .authorizedAlways else {
                    locationProblem = .off
                    return
                }
                if let p = LocationPermission.shared.problem { locationProblem = p; return }
                _ = await HealthService.shared.requestAuthorization()
            }
            model.run.start(simulated: simulated)
        }
    }
}

/// Place name, completion ring and today's specials.
struct TownHeader: View {
    @Environment(AppModel.self) private var model
    var onGoals: () -> Void = {}

    var body: some View {
        let p = model.progress
        HUDPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    ZStack {
                        ProgressRing(fraction: p.heldFraction, colorHex: model.profile.colorHex)
                        Text(p.heldFraction.percentString).font(Theme.number(.caption)).foregroundStyle(Theme.hudText)
                            .minimumScaleFactor(0.5).padding(6)
                    }
                    .frame(width: 58, height: 58)
                    .accessibilityElement()
                    .accessibilityLabel("You hold \(p.heldFraction.percentString) of the coins around \(model.placeName)")

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(model.placeName).font(Theme.display(.title3)).foregroundStyle(Theme.hudText).lineLimit(1)
                            if model.isConquered { Chip(text: "Conquered", colorHex: "FFD600") }
                        }
                        Text("\(p.coinsHeld.formatted()) coins held")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.hudSecondary)
                        Text("\(model.state.tokens(of: model.state.me).formatted()) collected in total").font(.caption).foregroundStyle(Theme.hudSecondary)
                        StreakChip(action: onGoals).fixedSize().padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("\(model.state.points)").font(Theme.number(.title3)).foregroundStyle(Theme.pellet)
                        Text("PTS").font(.caption2.weight(.heavy)).foregroundStyle(Theme.hudSecondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(model.state.points) points")
                }
                specials
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder private var specials: some View {
        // Nearest few only: every map square has its own.
        let here = model.savedFocus ?? model.area.center
        let pellets = Array(model.uncollectedPellets.sorted { $0.landmark.coordinate.distance(to: here) < $1.landmark.coordinate.distance(to: here) }.prefix(4))
        let bonus = Array(model.activeBonus.sorted {
            (model.area.segment($0.segmentIDs[0])?.midpoint.distance(to: here) ?? 0) < (model.area.segment($1.segmentIDs[0])?.midpoint.distance(to: here) ?? 0)
        }.prefix(3))
        if !pellets.isEmpty || !bonus.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(pellets) { p in
                        Button { model.focusRequest = p.landmark.coordinate } label: {
                            Label(p.landmark.name, systemImage: "bolt.circle.fill")
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Theme.power.opacity(0.22), in: Capsule())
                                .foregroundStyle(Theme.hudText)
                        }
                        .accessibilityLabel("Power-up at \(p.landmark.name). Show on map.")
                    }
                    ForEach(bonus) { b in
                        Button {
                            if let s = b.segmentIDs.first.flatMap(model.area.segment) { model.focusRequest = s.midpoint }
                        } label: {
                            Label(b.label(calendar: DailySpawns.townCalendar), systemImage: b.isActive(at: .now) ? "star.circle.fill" : "clock")
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Theme.pellet.opacity(0.16), in: Capsule())
                                .foregroundStyle(Theme.hudText)
                        }
                        .accessibilityLabel("Bonus coins. \(b.label(calendar: DailySpawns.townCalendar))")
                    }
                }
            }
        }
    }
}

/// Tells the player when streets are loading, or why they aren't there.
struct WorldStatusBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.worldStatus {
        case .idle:
            EmptyView()
        case .loading where AppModel.marketing && !model.area.segments.isEmpty:
            EmptyView()
        case .loading(let n):
            banner(symbol: nil, text: model.area.segments.isEmpty
                   ? "Loading the coins around you… The first time in a new area can take a minute."
                   : "Loading more of the map… (\(n))")
        case .needsLocation:
            banner(symbol: "location.slash", text: "Allow location, or pan the map to any town, to load its coins.") {
                Task {
                    _ = await LocationPermission.shared.requestWhenInUse()
                    await model.locateAndLoad()
                }
            }
        case .failed(let why):
            banner(symbol: "wifi.exclamationmark", text: why + " Tap to retry.") {
                if let f = model.savedFocus { model.focusWorld(on: f, force: true) }
            }
        }
    }

    private func banner(symbol: String?, text: String, action: (() -> Void)? = nil) -> some View {
        Button { action?() } label: {
            HStack(spacing: 10) {
                if let symbol { Image(systemName: symbol) } else { ProgressView().tint(Theme.hudText) }
                Text(text).font(.subheadline.weight(.semibold)).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.hudText)
            .padding(12)
            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .accessibilityElement(children: .combine)
    }
}

/// "Coins lost": what rivals took while you were away.
struct AttackBanner: View {
    @Environment(AppModel.self) private var model
    let report: AppModel.AttackReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger).font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Coins lost").font(.subheadline.weight(.heavy))
                    Text(report.message).font(.footnote.weight(.semibold)).foregroundStyle(Theme.hudText.opacity(0.8))
                }
                Spacer(minLength: 0)
                Button { model.dismissAttacks(showMe: false) } label: {
                    Image(systemName: "xmark").font(.footnote.weight(.bold)).padding(6)
                }
                .accessibilityLabel("Dismiss")
            }
            HStack(spacing: 8) {
                if report.focus != nil {
                    Button("Show me") { model.dismissAttacks(showMe: true) }
                        .buttonStyle(ChunkyButtonStyle(colorHex: "FF4D6D", height: 38))
                }
                Button("Win them back") {
                    model.dismissAttacks(showMe: report.focus != nil)
                    Task { model.plannedRoute = await model.planRoute(goal: .capture, distance: 4000, seed: UInt64.random(in: 1...999)) }
                }
                .buttonStyle(ChunkyButtonStyle(colorHex: model.profile.colorHex, height: 38))
            }
        }
        .foregroundStyle(Theme.hudText)
        .padding(12)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.danger.opacity(0.6), lineWidth: 1))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Tips shown during a practice run, timed to what's on screen.
struct PracticeCoach: View {
    @Environment(AppModel.self) private var model

    private func tip(_ t: TimeInterval) -> (String, String) {
        switch t {
        case ..<7: ("figure.run", "Practice run: we'll run this one for you at 8× speed. Nothing counts.")
        case ..<16: ("circle.grid.cross.fill", "The silver dots are coins. Run past them and they're yours.")
        case ..<25: ("paintbrush.fill", "Coins you collect turn gold. They're yours until someone runs past them.")
        case ..<35: ("arrow.uturn.backward.circle.fill", "Rivals can steal them back. Run past their coins to steal theirs.")
        default: ("flag.checkered", "That's it! Hold to finish, or let it end on its own.")
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let t = tip(model.run.elapsed)
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: t.0).font(.title3).foregroundStyle(Color(hex: "38E8FF")).frame(width: 28)
                Text(t.1).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.hudText).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(hex: "38E8FF").opacity(0.5), lineWidth: 1))
            .animation(.easeInOut, value: t.1)
            .accessibilityElement(children: .combine)
        }
    }
}

/// After a practice run: what a real one would have earned.
struct PracticeResultView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let result: AppModel.PracticeResult

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 52)).foregroundStyle(Color(hex: model.profile.colorHex))
            Text("You've got it").font(Theme.display(.title)).foregroundStyle(.white)
            Text(result.coins > 0
                 ? "On a real run that would have been \(coinCount(result.coins)). Now go and get them for real."
                 : "Run past coins to collect them. Now go and get them for real.")
                .font(.body.weight(.medium)).multilineTextAlignment(.center).foregroundStyle(Theme.hudSecondary)
            Button("Got it") { dismiss() }
                .buttonStyle(ChunkyButtonStyle(colorHex: model.profile.colorHex, height: 56))
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: "0C0C1A").ignoresSafeArea())
        .presentationDetents([.medium])
    }
}

/// Shown on the map while Precise Location is off: runs can't collect coins.
struct PreciseLocationBanner: View {
    var body: some View {
        Button {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "location.slash.fill").foregroundStyle(Color(hex: "FFD600"))
                Text("Precise Location is off, so runs can't collect coins. Tap to fix in Settings.")
                    .font(.subheadline.weight(.semibold)).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.hudText)
            .padding(12)
            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens Settings")
    }
}
