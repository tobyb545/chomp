import SwiftUI
import ChompKit

/// Home screen: the map around you with a big start button. Pan anywhere and
/// the streets there load too.
struct MapScreen: View {
    @Environment(AppModel.self) private var model
    @State private var follow = true
    @State private var sheet: Sheet?
    @State private var startConfirm = false
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
                .accessibilityHint("Use the Streets button for a list of streets and who owns them.")

            VStack(spacing: 10) {
                if model.run.isActive {
                    RunHUDView(follow: $follow)
                } else {
                    TownHeader(onGoals: { sheet = .goals })
                    WorldStatusBanner()
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
        .confirmationDialog("Start a run", isPresented: $startConfirm) {
            Button("Run for real") { start(simulated: false) }
            Button("Simulated run (demo)") { start(simulated: true) }
        } message: {
            Text("Simulated runs replay a believable route through the streets on screen at 8× speed. Handy for trying the game in the simulator.")
        }
        .onAppear { seenEvents = UserDefaults.standard.integer(forKey: "seenEvents") }
        .onChange(of: seenEvents) { _, v in UserDefaults.standard.set(v, forKey: "seenEvents") }
    }

    private var mapAccessibilityLabel: String {
        let p = model.progress
        return "Map of \(model.placeName). You hold \(p.heldSegments) streets here, \(p.heldFraction.percentString) of the streets nearby. "
            + "\(model.uncollectedPellets.count) power pellets on the map today."
    }

    private var sideButtons: some View {
        HStack(alignment: .bottom) {
            VStack(spacing: 10) {
                RoundIconButton(symbol: "trophy.fill", label: "Leaderboards") { sheet = .leaderboard }
                RoundIconButton(symbol: "bell.fill", label: "Activity", badge: max(0, model.state.events.count - seenEvents)) { sheet = .activity }
                RoundIconButton(symbol: "list.bullet", label: "Streets") { sheet = .streets }
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
            Text("Route · \(formatDistance(r.distance, miles: model.profile.useMiles)) · \(r.targets) streets · \(r.tokens) tokens")
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
        .contextMenu {
            Button("Simulated run (demo)", systemImage: "wand.and.stars") { start(simulated: true) }
        }
        .accessibilityHint("Starts recording. Streets you run turn your colour.")
    }

    private func start(simulated: Bool) {
        follow = true
        guard !model.area.segments.isEmpty else {
            model.toast = "Streets are still loading. Give it a moment."
            return
        }
        Task {
            if !simulated {
                let status = await LocationPermission.shared.requestWhenInUse()
                guard status == .authorizedWhenInUse || status == .authorizedAlways else {
                    model.toast = "Chomp needs location access to see which streets you run. Turn it on in Settings."
                    return
                }
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
                    .accessibilityLabel("\(p.heldFraction.percentString) of the streets around \(model.placeName) held")

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(model.placeName).font(Theme.display(.title3)).foregroundStyle(Theme.hudText).lineLimit(1)
                            if model.isConquered { Chip(text: "Conquered", colorHex: "FFD600") }
                        }
                        Text("\(p.heldSegments) streets · \(formatDistance(p.heldMetres, miles: model.profile.useMiles)) · \(model.state.tokens(of: model.state.me).formatted()) tokens")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.hudSecondary)
                        Text("Explored \(p.exploredFraction.percentString)").font(.caption).foregroundStyle(Theme.hudSecondary)
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
                        .accessibilityLabel("Power pellet at \(p.landmark.name). Show on map.")
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
                        .accessibilityLabel("Bonus street. \(b.label(calendar: DailySpawns.townCalendar))")
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
            banner(symbol: nil, text: model.area.segments.isEmpty ? "Loading the streets around you…" : "Loading more streets… (\(n))")
        case .needsLocation:
            banner(symbol: "location.slash", text: "Allow location, or pan the map to any town, to load its streets.") {
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
