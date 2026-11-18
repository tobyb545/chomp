import SwiftUI
import ChompKit

/// Home screen: the town map with a big start button.
struct MapScreen: View {
    @Environment(AppModel.self) private var model
    @State private var follow = true
    @State private var sheet: Sheet?
    @State private var startConfirm = false
    @State private var seenEvents = 0

    enum Sheet: String, Identifiable { case leaderboard, activity, profile, streets; var id: String { rawValue } }

    var body: some View {
        let snapshot = model.mapSnapshot()
        ZStack {
            GameMapView(area: model.area, snapshot: snapshot,
                        camera: model.run.isActive && follow ? .follow : .free,
                        focus: model.focusRequest,
                        onUserPan: { follow = false })
                .ignoresSafeArea()
                .accessibilityElement()
                .accessibilityLabel(mapAccessibilityLabel)
                .accessibilityHint("Use the Streets button for a list of streets and who owns them.")

            VStack(spacing: 10) {
                if model.run.isActive {
                    RunHUDView(follow: $follow)
                } else {
                    TownHeader()
                    Spacer()
                    sideButtons
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
            }
        }
        .confirmationDialog("Start a run", isPresented: $startConfirm) {
            Button("Run for real") { start(simulated: false) }
            Button("Simulated run (demo)") { start(simulated: true) }
        } message: {
            Text("Simulated runs replay a believable route through \(model.area.name) at 8× speed. Handy for trying the game in the simulator.")
        }
        .onAppear { seenEvents = UserDefaults.standard.integer(forKey: "seenEvents") }
        .onChange(of: seenEvents) { _, v in UserDefaults.standard.set(v, forKey: "seenEvents") }
    }

    private var mapAccessibilityLabel: String {
        let p = model.progress
        return "Map of \(model.area.name). You hold \(p.heldSegments) streets, \(p.heldFraction.percentString) of the town. "
            + "\(model.uncollectedPellets.count) power pellets on the map today."
    }

    private var sideButtons: some View {
        HStack(alignment: .bottom) {
            VStack(spacing: 10) {
                RoundIconButton(symbol: "trophy.fill", label: "Leaderboards") { sheet = .leaderboard }
                RoundIconButton(symbol: "bell.fill", label: "Activity", badge: max(0, model.state.events.count - seenEvents)) { sheet = .activity }
                RoundIconButton(symbol: "list.bullet", label: "Streets") { sheet = .streets }
            }
            Spacer()
            VStack(spacing: 10) {
                if model.pro.isPro {
                    RoundIconButton(symbol: model.heatmapOn ? "flame.fill" : "flame", label: model.heatmapOn ? "Hide heatmap" : "Show heatmap") {
                        model.heatmapOn.toggle()
                    }
                }
                RoundIconButton(symbol: "location.fill", label: "Centre on me") {
                    model.focusRequest = LocationPermission.shared.lastKnown ?? model.area.center
                }
                RoundIconButton(symbol: "person.crop.circle.fill", label: "Profile and settings") { sheet = .profile }
            }
        }
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

/// Town name, completion ring and today's specials.
struct TownHeader: View {
    @Environment(AppModel.self) private var model

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
                    .accessibilityLabel("\(p.heldFraction.percentString) of \(model.area.name) held")

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(model.area.name).font(Theme.display(.title3)).foregroundStyle(Theme.hudText)
                            if model.isConquered { Chip(text: "Conquered", colorHex: "FFD600") }
                        }
                        Text("\(p.heldSegments) streets · \(formatDistance(p.heldMetres, miles: model.profile.useMiles)) · \(p.blocksHeld) blocks")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.hudSecondary)
                        Text("Explored \(p.exploredFraction.percentString)").font(.caption).foregroundStyle(Theme.hudSecondary)
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
        let pellets = model.uncollectedPellets
        let bonus = model.activeBonus
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
