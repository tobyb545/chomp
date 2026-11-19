import SwiftUI
import ChompKit

struct LeaderboardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var scope: LeaderboardScope = .nearby
    @State private var metric: LeaderboardMetric = .streets
    @State private var entries: [LeaderboardEntry] = []
    @State private var error: String?
    @State private var selected: LeaderboardEntry?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Scope", selection: $scope) { ForEach(LeaderboardScope.allCases) { Text($0.label).tag($0) } }
                        .pickerStyle(.segmented)
                    Picker("Rank by", selection: $metric) { ForEach(LeaderboardMetric.allCases) { Text($0.label).tag($0) } }
                        .pickerStyle(.segmented)
                }
                .listRowBackground(Color.clear)

                if let error {
                    Section { Text(error).foregroundStyle(Theme.textSecondary) }
                }
                let sorted = entries.sorted { $0.value(metric) > $1.value(metric) }
                if let boss = sorted.first, scope == .nearby, boss.value(metric) > 0 {
                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: "crown.fill").font(.title).foregroundStyle(Color(hex: "FFD600"))
                            VStack(alignment: .leading) {
                                Text("Local boss this week").font(.caption.weight(.heavy)).textCase(.uppercase).foregroundStyle(Theme.textSecondary)
                                Text(boss.name).font(Theme.display(.title3))
                            }
                            if boss.isBot { Chip(text: "Bot", colorHex: "8888AA") }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                Section(model.placeName) {
                    ForEach(Array(sorted.enumerated()), id: \.element.id) { i, e in
                        Button { if !e.isMe && !e.isBot { selected = e } } label: { row(rank: i + 1, e) }
                            .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Leaderboards")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: scope) { await load() }
            .sheet(item: $selected) { e in PlayerSheet(playerID: e.id, name: e.name, colorHex: e.colorHex) }
        }
    }

    private func row(rank: Int, _ e: LeaderboardEntry) -> some View {
        HStack(spacing: 12) {
            Text("\(rank)").font(Theme.number(.headline)).frame(width: 28).foregroundStyle(Theme.textSecondary)
            Circle().fill(Color(hex: e.colorHex)).frame(width: 14, height: 14)
            Text(e.name).font(.body.weight(e.isMe ? .heavy : .semibold))
            if e.isBot { Chip(text: "Bot", colorHex: "8888AA") }
            if e.isMe { Chip(text: "You", colorHex: e.colorHex) }
            Spacer()
            Text(metric == .km ? String(format: "%.1f", e.value(metric)) : "\(Int(e.value(metric)))").font(Theme.number(.headline))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Rank \(rank), \(e.name)\(e.isBot ? ", bot" : ""), \(Int(e.value(metric))) \(metric.label)")
    }

    private func load() async {
        error = nil
        do { entries = try await model.leaderboard(scope: scope) } catch {
            entries = []
            self.error = scope == .nearby ? error.localizedDescription
                : "\(scope.label) leaderboards need online play. Nearby rankings (you vs the bots) work offline."
        }
    }
}


struct ActivityFeedView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if model.state.events.isEmpty {
                    ContentUnavailableView("Nothing yet", systemImage: "bell", description: Text("Captures, raids and fades show up here."))
                }
                ForEach(model.state.events.filter { e in !(e.actor.map { model.profile.mutedPlayers.contains($0.id) } ?? false) }) { e in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: icon(e.kind)).font(.title3).foregroundStyle(color(e)).frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(e.message).font(.body.weight(.semibold))
                            Text(e.date.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        if e.points > 0 { Text("+\(e.points)").font(Theme.number(.subheadline)).foregroundStyle(Theme.textSecondary) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let id = e.segmentIDs.first, let s = model.area.segment(id) { model.focusRequest = s.midpoint; dismiss() }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityHint(e.segmentIDs.isEmpty ? "" : "Shows the street on the map")
                }
            }
            .navigationTitle("Activity")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func icon(_ k: GameEventKind) -> String {
        switch k {
        case .captured: "circle.grid.cross.fill"
        case .stolen: "arrow.uturn.backward.circle.fill"
        case .lost, .ghostRaid: "exclamationmark.triangle.fill"
        case .refreshed: "arrow.clockwise.circle.fill"
        case .decayed: "hourglass.bottomhalf.filled"
        case .blockCompleted: "square.grid.3x3.fill"
        case .powerPellet, .frenzy: "bolt.circle.fill"
        case .bonusStreet: "star.circle.fill"
        case .townConquered: "crown.fill"
        case .runRejected: "exclamationmark.shield.fill"
        }
    }

    private func color(_ e: GameEvent) -> Color {
        switch e.kind {
        case .ghostRaid, .lost, .runRejected: Theme.danger
        case .decayed: Theme.textSecondary
        case .powerPellet, .frenzy: Theme.power
        case .townConquered: Color(hex: "FFD600")
        default: Color(hex: model.profile.colorHex)
        }
    }
}

/// Accessible alternative to the map: every street and who holds it.
struct StreetListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var filter: Filter = .mine
    @State private var query = ""

    enum Filter: String, CaseIterable, Identifiable { case mine, rivals, pellets, fading; var id: String { rawValue }
        var label: String { switch self { case .mine: "Mine"; case .rivals: "Rivals"; case .pellets: "Pellets"; case .fading: "Fading" } } }

    struct Row: Identifiable { let id: String; let name: String; let segments: [Segment]; let metres: Double; let owner: OwnerRef?; let strength: Double }

    private var rows: [Row] {
        let now = Date()
        let decay = model.rules.decayInterval
        let grouped = Dictionary(grouping: model.area.segments) { "\($0.displayName)|\(model.state.ownership[$0.id]?.owner.id ?? "-")" }
        return grouped.compactMap { _, segs -> Row? in
            let o = model.state.ownership[segs[0].id]
            let live = o.flatMap { $0.strength(at: now, decay: decay) > 0 ? $0 : nil }
            let strength = live?.strength(at: now, decay: decay) ?? 0
            switch filter {
            case .mine: guard live?.owner == model.state.me else { return nil }
            case .rivals: guard let l = live, l.owner != model.state.me else { return nil }
            case .pellets: guard live == nil || live?.owner != model.state.me else { return nil }
            case .fading: guard live?.owner == model.state.me, strength < 0.35 else { return nil }
            }
            if !query.isEmpty, !segs[0].displayName.localizedCaseInsensitiveContains(query) { return nil }
            return Row(id: segs[0].id, name: segs[0].displayName, segments: segs, metres: segs.reduce(0) { $0 + $1.length }, owner: live?.owner, strength: strength)
        }.sorted { $0.metres > $1.metres }
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("Show", selection: $filter) { ForEach(Filter.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).listRowBackground(Color.clear)
                ForEach(rows.prefix(300)) { r in
                    Button {
                        model.focusRequest = r.segments[0].midpoint
                        dismiss()
                    } label: {
                        HStack {
                            Circle().fill(r.owner.map { Color(hex: model.ownerColor($0)) } ?? Theme.pellet).frame(width: 12, height: 12)
                            VStack(alignment: .leading) {
                                Text(r.name).font(.body.weight(.semibold))
                                Text("\(r.segments.count) section\(r.segments.count == 1 ? "" : "s") · \(formatDistance(r.metres, miles: model.profile.useMiles))"
                                     + (r.owner.map { " · \(model.ownerName($0))" } ?? " · pellets"))
                                    .font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            if r.owner == model.state.me {
                                Text("\(Int(r.strength * 100))%").font(Theme.number(.caption)).foregroundStyle(Theme.textSecondary)
                                    .accessibilityLabel("strength \(Int(r.strength * 100)) percent")
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows it on the map")
                }
            }
            .searchable(text: $query, prompt: "Find a street")
            .navigationTitle("Streets")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// Rival player actions: report, block, mute.
struct PlayerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let playerID: String
    let name: String
    let colorHex: String
    @State private var reporting = false
    @State private var reason = "Cheating (cycling, driving or GPS spoofing)"
    @State private var notes = ""
    @State private var status: String?

    static let reasons = ["Cheating (cycling, driving or GPS spoofing)", "Offensive name", "Harassment", "Something else"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack { Circle().fill(Color(hex: colorHex)).frame(width: 18, height: 18); Text(name).font(Theme.display(.title3)) }
                }
                if reporting {
                    Section("Report") {
                        Picker("Reason", selection: $reason) { ForEach(Self.reasons, id: \.self) { Text($0) } }
                        TextField("Anything else? (optional)", text: $notes, axis: .vertical)
                        Button("Send report") { Task { await send() } }
                    }
                } else {
                    Section {
                        Button("Report \(name)", systemImage: "flag.fill") { reporting = true }
                        Button(model.profile.mutedPlayers.contains(playerID) ? "Unmute" : "Mute notifications", systemImage: "bell.slash.fill") { toggleMute() }
                        Button("Block \(name)", systemImage: "hand.raised.fill", role: .destructive) { block() }
                    } footer: {
                        Text("Blocking hides their streets and notifications from you. They aren't told.")
                    }
                }
                if let status { Section { Text(status) } }
            }
            .navigationTitle("Player")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func send() async {
        do {
            try await model.backend.report(player: playerID, reason: reason, notes: notes)
            status = "Thanks. A human will look at this. Reports are private."
            reporting = false
        } catch { status = error.localizedDescription }
    }

    private func toggleMute() {
        if let i = model.profile.mutedPlayers.firstIndex(of: playerID) { model.profile.mutedPlayers.remove(at: i) }
        else { model.profile.mutedPlayers.append(playerID); Task { try? await model.backend.block(player: playerID, mute: true) } }
    }

    private func block() {
        if !model.profile.blockedPlayers.contains(playerID) { model.profile.blockedPlayers.append(playerID) }
        Task { try? await model.backend.block(player: playerID, mute: false) }
        model.bumpMap()
        dismiss()
    }
}

struct ClubsView: View {
    @Environment(AppModel.self) private var model
    @State private var clubs: [Club] = []
    @State private var friends: [Friend] = []
    @State private var newName = ""
    @State private var code = ""
    @State private var handle = ""
    @State private var error: String?

    var body: some View {
        Form {
            if !model.backend.isSignedIn {
                Section {
                    Text("Clubs, friends and club-vs-club battles need online play. Sign in from Settings once the backend is connected.")
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Section("My clubs") {
                if clubs.isEmpty { Text("No clubs yet").foregroundStyle(Theme.textSecondary) }
                ForEach(clubs) { c in
                    HStack {
                        Circle().fill(Color(hex: c.colorHex)).frame(width: 14, height: 14)
                        Text(c.name).font(.body.weight(.semibold))
                        Spacer()
                        Text("\(c.members) members").font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    if let code = c.inviteCode { Text("Invite code: \(code)").font(.caption.monospaced()).textSelection(.enabled) }
                }
            }
            Section("Start a club") {
                TextField("Club name", text: $newName)
                Button("Create with my colour") {
                    Task { await run { try await model.backend.createClub(name: newName, colorHex: model.profile.colorHex) } }
                }.disabled(newName.count < 3)
            }
            Section("Join a club") {
                TextField("Invite code", text: $code).textInputAutocapitalization(.characters)
                Button("Join") { Task { await run { try await model.backend.joinClub(code: code) } } }.disabled(code.count < 4)
            }
            Section("Friends") {
                ForEach(friends) { f in
                    HStack { Circle().fill(Color(hex: f.colorHex)).frame(width: 12, height: 12); Text(f.name); Spacer(); Text("\(f.streets) streets").foregroundStyle(Theme.textSecondary) }
                }
                TextField("Add by runner name", text: $handle)
                Button("Send friend request") { Task { await run { try await model.backend.addFriend(handle: handle) } } }.disabled(handle.count < 2)
            }
            if let error { Section { Text(error).foregroundStyle(Theme.danger) } }
        }
        .navigationTitle("Clubs & friends")
        .task { await reload() }
    }

    private func reload() async {
        guard model.backend.isSignedIn else { return }
        clubs = (try? await model.backend.clubs()) ?? []
        friends = (try? await model.backend.friends()) ?? []
    }

    private func run(_ op: () async throws -> Void) async {
        do { try await op(); error = nil; await reload() } catch { self.error = error.localizedDescription }
    }
}
