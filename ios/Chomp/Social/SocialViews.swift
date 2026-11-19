import SwiftUI
import ChompKit

struct LeaderboardView: View {
    enum Board: String, CaseIterable, Identifiable {
        case runners, clubs
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var board: Board = .runners
    @State private var scope: LeaderboardScope = AppModel.marketing ? .global : .nearby
    @State private var clubScope: ClubScope = .nearby
    @State private var entries: [LeaderboardEntry] = []
    @State private var clubs: [ClubStanding] = []
    @State private var error: String?
    @State private var selected: LeaderboardEntry?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Board", selection: $board) { ForEach(Board.allCases) { Text($0.label).tag($0) } }
                        .pickerStyle(.segmented)
                    if board == .runners {
                        Picker("Scope", selection: $scope) { ForEach(LeaderboardScope.allCases) { Text($0.label).tag($0) } }
                            .pickerStyle(.segmented)
                        Text("Ranked by coins collected: every coin you run past counts.")
                            .font(.footnote).foregroundStyle(Theme.textSecondary)
                    } else {
                        Picker("Area", selection: $clubScope) { ForEach(ClubScope.allCases) { Text($0.label).tag($0) } }
                            .pickerStyle(.segmented)
                        Text(clubScope == .nearby
                             ? "Clubs ranked by the coins their members collected around here (about 25 km)."
                             : "Clubs ranked by every coin their members have collected.")
                            .font(.footnote).foregroundStyle(Theme.textSecondary)
                    }
                }
                .listRowBackground(Color.clear)

                if let error {
                    Section { Text(error).foregroundStyle(Theme.textSecondary) }
                }
                if board == .runners { runnersSections } else { clubSections }
            }
            .navigationTitle("Leaderboards")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: "\(board)-\(scope)-\(clubScope)") { await load() }
            .sheet(item: $selected) { e in PlayerSheet(playerID: e.id, name: e.name, colorHex: e.colorHex) }
        }
    }

    @ViewBuilder private var runnersSections: some View {
        let sorted = entries.sorted { $0.tokens > $1.tokens }
        if let boss = sorted.first, scope == .nearby, boss.tokens > 0 {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "crown.fill").font(.title).foregroundStyle(Color(hex: "FFD600"))
                    VStack(alignment: .leading) {
                        Text("Top chomper nearby").font(.caption.weight(.heavy)).textCase(.uppercase).foregroundStyle(Theme.textSecondary)
                        Text(boss.name).font(Theme.display(.title3))
                    }
                    if boss.isBot { Chip(text: "Bot", colorHex: "8888AA") }
                }
                .accessibilityElement(children: .combine)
            }
        }
        Section(scope == .nearby ? model.placeName : scope.label) {
            ForEach(Array(sorted.enumerated()), id: \.element.id) { i, e in
                Button { if !e.isMe && !e.isBot { selected = e } } label: { row(rank: i + 1, e) }
                    .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private var clubSections: some View {
        if clubs.isEmpty, error == nil {
            Section {
                ContentUnavailableView("No club battles yet", systemImage: "person.3.fill",
                                       description: Text("Start or join a club from your profile. Every coin members collect counts for the club."))
            }
        }
        Section {
            ForEach(Array(clubs.enumerated()), id: \.element.id) { i, c in
                HStack(spacing: 12) {
                    Text("\(i + 1)").font(Theme.number(.headline)).frame(minWidth: 28).foregroundStyle(Theme.textSecondary)
                    RoundedRectangle(cornerRadius: 4).fill(Color(hex: c.color_hex)).frame(width: 14, height: 14).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.name).font(.body.weight(c.is_mine ? .heavy : .semibold))
                        Text("\(c.members) member\(c.members == 1 ? "" : "s")").font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    if c.is_mine { Chip(text: "Yours", colorHex: c.color_hex) }
                    Spacer()
                    HStack(spacing: 5) {
                        Text(c.tokens.formatted()).font(Theme.number(.headline))
                        Circle().fill(Color(hex: MapStyle.pelletColour)).frame(width: 8, height: 8).accessibilityHidden(true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Rank \(i + 1), \(c.name), \(c.members) members, \(c.tokens) coins\(c.is_mine ? ", your club" : "")")
            }
        }
    }

    private func row(rank: Int, _ e: LeaderboardEntry) -> some View {
        HStack(spacing: 12) {
            Text("\(rank)").font(Theme.number(.headline)).frame(minWidth: 28).foregroundStyle(Theme.textSecondary)
            Circle().fill(Color(hex: e.colorHex)).frame(width: 14, height: 14).accessibilityHidden(true)
            Text(e.name).font(.body.weight(e.isMe ? .heavy : .semibold))
            if e.isBot { Chip(text: "Bot", colorHex: "8888AA") }
            if e.isMe { Chip(text: "You", colorHex: e.colorHex) }
            Spacer()
            HStack(spacing: 5) {
                Text(e.tokens.formatted()).font(Theme.number(.headline))
                Circle().fill(Color(hex: MapStyle.pelletColour)).frame(width: 8, height: 8).accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Rank \(rank), \(e.name)\(e.isMe ? ", you" : "")\(e.isBot ? ", bot" : ""), \(e.tokens) coins")
    }

    /// Made-up rivals for App Store screenshots only (`-marketing`, debug builds).
    private static func marketingEntries(me: PlayerProfile) -> [LeaderboardEntry] {
        let rivals: [(String, String, Int)] = [
            ("Priya K 🇮🇳", "FF6FA1", 4_812), ("Marcus T 🇺🇸", "3BA8FF", 4_177), ("Sofia R 🇪🇸", "FFB020", 3_640),
            ("Jonah W 🇦🇺", "7B61FF", 2_955), ("Elena M 🇮🇹", "2ED3B7", 1_728), ("Theo B 🇫🇷", "FF7A45", 1_391),
            ("Hana S 🇯🇵", "A3E635", 1_206), ("Leo D 🇩🇪", "F472B6", 988), ("Grace O 🇳🇬", "38BDF8", 874),
            ("Sam P 🇨🇦", "FACC15", 731), ("Nina V 🇳🇱", "C084FC", 652), ("Oscar L 🇸🇪", "34D399", 540),
            ("Maya J 🇧🇷", "FB7185", 467),
        ]
        var list = rivals.enumerated().map { i, r in
            LeaderboardEntry(id: "m\(i)", rank: 0, name: r.0, colorHex: r.1, isBot: false, isMe: false, tokens: r.2)
        }
        list.append(LeaderboardEntry(id: "me", rank: 0, name: me.name + " 🇬🇧", colorHex: me.colorHex, isBot: false, isMe: true, tokens: 2_316))
        return list
    }

    private func load() async {
        error = nil
        switch board {
        case .runners:
            if AppModel.marketing { entries = Self.marketingEntries(me: model.profile); return }
            do { entries = try await model.leaderboard(scope: scope) } catch {
                entries = []
                self.error = scope == .nearby ? error.localizedDescription
                    : "\(scope.label) leaderboards need online play. Nearby rankings (you vs the bots) work offline."
            }
        case .clubs:
            do { clubs = try await model.clubLeaderboard(scope: clubScope) } catch {
                clubs = []
                self.error = "Club battles need online play. Sign in from Settings."
            }
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
    @State private var filter: Filter = .near
    @State private var query = ""

    enum Filter: String, CaseIterable, Identifiable {
        case near, mine, rivals, fading
        var id: String { rawValue }
        /// No "Fading" tab while streets don't fade.
        static var allCases: [Filter] { RulesConfig.bundled.decay.isEnabled ? [.near, .mine, .rivals, .fading] : [.near, .mine, .rivals] }
        var label: String { switch self { case .near: "To grab"; case .mine: "Mine"; case .rivals: "Rivals"; case .fading: "Fading" } }
        var empty: String {
            switch self {
            case .near: "Nothing to grab here. You hold every street nearby!"
            case .mine: "No streets yet. Run one end to end to make it yours."
            case .rivals: "No rivals' streets nearby."
            case .fading: "None of your streets are fading."
            }
        }
    }

    struct Row: Identifiable {
        let id: String; let name: String; let segments: [Segment]; let metres: Double
        let owner: OwnerRef?; let strength: Double; let tokens: Int; let away: Double; let nearest: Coordinate
    }

    private var rows: [Row] {
        let now = Date()
        let decay = model.rules.decayInterval
        let me = model.state.me
        let here = model.routeStart
        // Named streets group by name and owner; unnamed paths and service roads stay separate.
        let grouped = Dictionary(grouping: model.area.segments) { seg -> String in
            seg.name.isEmpty ? seg.id : "\(seg.name)|\(model.state.mainOwner(of: seg, rules: model.rules)?.id ?? "-")"
        }
        let out = grouped.compactMap { _, segs -> Row? in
            // Count coins: yours, rivals', unclaimed.
            var mine = 0, rival = 0, free = 0
            var weakest = 1.0
            var rivalOwner: OwnerRef?
            for seg in segs {
                for id in model.rules.coinIDs(seg) {
                    guard let o = model.state.ownership[id], o.strength(at: now, decay: decay) > 0 else { free += 1; continue }
                    if o.owner == me { mine += 1; weakest = min(weakest, o.strength(at: now, decay: decay)) }
                    else { rival += 1; rivalOwner = rivalOwner ?? o.owner }
                }
            }
            let tokens: Int
            switch filter {
            case .near: guard free + rival > 0 else { return nil }; tokens = free + rival
            case .mine: guard mine > 0 else { return nil }; tokens = mine
            case .rivals: guard rival > 0 else { return nil }; tokens = rival
            case .fading: guard mine > 0, weakest < 0.35 else { return nil }; tokens = mine
            }
            let owner: OwnerRef? = filter == .rivals ? rivalOwner
                : mine >= max(rival, 1) ? me : rival > 0 ? rivalOwner : nil
            let strength = owner == me ? weakest : (owner == nil ? 0 : 1)
            if !query.isEmpty, !segs[0].displayName.localizedCaseInsensitiveContains(query) { return nil }
            let closest = segs.min { $0.midpoint.distance(to: here) < $1.midpoint.distance(to: here) }!
            return Row(id: segs[0].id, name: segs[0].displayName, segments: segs, metres: segs.reduce(0) { $0 + $1.length },
                       owner: owner, strength: strength,
                       tokens: tokens,
                       away: closest.midpoint.distance(to: here), nearest: closest.midpoint)
        }
        switch filter {
        case .fading: return out.sorted { $0.strength < $1.strength }
        default: return out.sorted { $0.away < $1.away }
        }
    }

    var body: some View {
        let list = rows
        NavigationStack {
            List {
                Picker("Show", selection: $filter) { ForEach(Filter.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).listRowBackground(Color.clear)
                if list.isEmpty {
                    Text(query.isEmpty ? filter.empty : "No streets called \u{201C}\(query)\u{201D} here.")
                        .foregroundStyle(Theme.textSecondary)
                } else if filter == .near, query.isEmpty {
                    let tokens = list.prefix(20).reduce(0) { $0 + $1.tokens }
                    Text("The 20 closest hold \(tokens.formatted()) coins. Closest first.")
                        .font(.footnote).foregroundStyle(Theme.textSecondary)
                }
                ForEach(list.prefix(300)) { r in
                    Button {
                        model.focusRequest = r.nearest
                        dismiss()
                    } label: {
                        HStack {
                            Circle().fill(r.owner.map { $0 == model.state.me ? Color(hex: "F0A400") : Color(hex: MapStyle.rivalCoin(model.ownerColor($0))) } ?? .white)
                                .overlay(Circle().stroke(.black.opacity(0.25), lineWidth: 1))
                                .frame(width: 12, height: 12)
                            VStack(alignment: .leading) {
                                Text(r.name).font(.body.weight(.semibold))
                                Text("\(formatDistance(r.away, miles: model.profile.useMiles)) away · \(formatDistance(r.metres, miles: model.profile.useMiles))"
                                     + (r.owner.map { " · \(model.ownerName($0))" } ?? ""))
                                    .font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            if r.owner == model.state.me {
                                Text("\(Int(r.strength * 100))%").font(Theme.number(.caption)).foregroundStyle(r.strength < 0.35 ? Theme.danger : Theme.textSecondary)
                                    .accessibilityLabel("strength \(Int(r.strength * 100)) percent")
                            } else {
                                Label("\(r.tokens)", systemImage: "circle.fill").labelStyle(TokenCountStyle())
                                    .accessibilityLabel("\(r.tokens) coins")
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows it on the map")
                }
            }
            .searchable(text: $query, prompt: "Find a street")
            .navigationTitle("Streets near you")
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
    @State private var club: MyClub?
    @State private var loaded = false
    @State private var friends: [Friend] = []
    @State private var newName = ""
    @State private var code = ""
    @State private var handle = ""
    @State private var error: String?
    @State private var confirmLeave = false
    @State private var confirmSwitch = false
    @State private var confirmJoin = false
    @State private var showPaywall = false

    var body: some View {
        Form {
            if !model.backend.isSignedIn {
                Section {
                    Text("Clubs, friends and club battles need online play. Sign in from Settings.")
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            if let club {
                clubCard(club)
                Section {
                    ForEach(Array(club.members.sorted { $0.tokens > $1.tokens }.enumerated()), id: \.element.id) { i, m in
                        HStack(spacing: 10) {
                            Text("\(i + 1)").font(Theme.number(.subheadline)).foregroundStyle(Theme.textSecondary).frame(width: 22)
                            Circle().fill(Color(hex: m.color_hex)).frame(width: 12, height: 12)
                            Text(m.name).font(.body.weight(m.id == model.backend.userID ? .heavy : .regular))
                            if m.role == "owner" { Chip(text: "Captain", colorHex: club.color_hex) }
                            Spacer()
                            Text(m.tokens.formatted()).font(Theme.number(.subheadline))
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(i + 1). \(m.name)\(m.id == model.backend.userID ? ", you" : "")\(m.role == "owner" ? ", captain" : ""), \(m.tokens) coins")
                    }
                } header: { Text("Members") } footer: {
                    Text("Coins each member has collected for the club since joining.")
                }
                Section {
                    Button("Leave \(club.name)", role: .destructive) { confirmLeave = true }
                }
            } else if model.backend.isSignedIn, loaded {
                Section {
                    Text("Join a club and every coin you collect adds to its tally. Clubs battle on nearby and worldwide leaderboards.")
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Section {
                TextField("Invite code", text: $code).textInputAutocapitalization(.characters).autocorrectionDisabled()
                Button(club == nil ? "Join club" : "Switch to this club") {
                    if club == nil { Task { await run { try await model.backend.joinClub(code: code) } } } else { confirmSwitch = true }
                }
                .disabled(code.trimmingCharacters(in: .whitespaces).count < 4)
            } header: { Text(club == nil ? "Join a club" : "Join a different club") }

            if club == nil {
                Section {
                    TextField("Club name", text: $newName)
                    Button("Start club in my colour") {
                        guard model.pro.isPro else { showPaywall = true; return }
                        Task { await run { try await model.backend.createClub(name: newName, colorHex: model.profile.colorHex) } }
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).count < 3)
                } header: { Text("Start a club") } footer: {
                    Text("Starting a club is part of Chomp Pro. Anyone can join one for free.")
                }
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
        .task {
            await reload()
            // Opened from a club invite link: fill in the code and ask.
            if let c = model.pendingClubCode {
                model.pendingClubCode = nil
                code = c
                guard model.backend.isSignedIn, club?.invite_code != c else { return }
                if club == nil { confirmJoin = true } else { confirmSwitch = true }
            }
        }
        .refreshable { await reload() }
        .confirmationDialog("Join this club?", isPresented: $confirmJoin, titleVisibility: .visible) {
            Button("Join club \(code)") { Task { await run { try await model.backend.joinClub(code: code) } } }
        } message: {
            Text("Every coin you collect will count towards the club's tally.")
        }
        .confirmationDialog("Leave \(club?.name ?? "your club")?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave club", role: .destructive) { Task { await run { try await model.backend.leaveClub() } } }
        } message: {
            Text("Coins you've already collected stay in its tally.\(club?.isOwner == true ? " The longest-standing member becomes captain." : "")")
        }
        .confirmationDialog("Switch clubs?", isPresented: $confirmSwitch, titleVisibility: .visible) {
            Button("Leave \(club?.name ?? "my club") and join") { Task { await run { try await model.backend.joinClub(code: code) } } }
        } message: {
            Text("You can be in one club at a time. Coins you've collected stay with \(club?.name ?? "your current club").")
        }
        .sheet(isPresented: $showPaywall) { PaywallView() }
    }

    private func tally(_ c: MyClub) -> some View {
        VStack(alignment: .leading) {
            Text(c.tokens.formatted()).font(Theme.number(.title2))
            Text("club coins").font(.caption).foregroundStyle(Theme.textSecondary)
        }
    }

    private func rank(_ c: MyClub) -> some View {
        VStack(alignment: .leading) {
            Text("#\(c.rank)").font(Theme.number(.title2))
            Text("of \(c.clubs) clubs").font(.caption).foregroundStyle(Theme.textSecondary)
        }
    }

    private func clubCard(_ c: MyClub) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 10).fill(Color(hex: c.color_hex)).frame(width: 44, height: 44)
                        .overlay(Image(systemName: "person.3.fill").foregroundStyle(.black.opacity(0.6)))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.name).font(Theme.display(.title3))
                        Text("\(c.members.count) member\(c.members.count == 1 ? "" : "s")").font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack { tally(c); Spacer(); rank(c) }
                    VStack(alignment: .leading, spacing: 8) { tally(c); rank(c) }   // very large text
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(c.tokens) club coins. Ranked \(c.rank) of \(c.clubs) clubs.")
                HStack {
                    Text("Invite code").font(.caption).foregroundStyle(Theme.textSecondary)
                    Text(c.invite_code).font(.body.monospaced().weight(.bold)).textSelection(.enabled)
                        .speechSpellsOutCharacters()
                    Spacer()
                    ShareLink(item: "Join my Chomp club \(c.name): every coin we collect counts for the club. Code \(c.invite_code) or tap \(AppModel.clubLink(c.invite_code))") {
                        Label("Share", systemImage: "square.and.arrow.up").font(.caption.weight(.semibold))
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func reload() async {
        guard model.backend.isSignedIn else { loaded = true; return }
        club = try? await model.backend.myClub()
        if club != nil, !model.profile.joinedClub { model.profile.joinedClub = true; model.awardBadges() }
        friends = (try? await model.backend.friends()) ?? []
        loaded = true
    }

    private func run(_ op: () async throws -> Void) async {
        do { try await op(); error = nil; code = ""; newName = ""; await reload() } catch { self.error = error.localizedDescription }
    }
}

/// Token count readable on light and dark list backgrounds.
private struct TokenCountStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 6)).foregroundStyle(Color(hex: "E0A100"))
            configuration.title.font(Theme.number(.caption)).foregroundStyle(Theme.textPrimary)
        }
    }
}
