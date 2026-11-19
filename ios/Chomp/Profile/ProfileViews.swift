import AuthenticationServices
import CryptoKit
import SwiftUI
import ChompKit

struct ProfileView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Circle().fill(Color(hex: model.profile.colorHex)).frame(width: 54, height: 54)
                            .overlay(Text(String(model.displayName.prefix(1))).font(Theme.display(.title2)).foregroundStyle(Color.onAccent(model.profile.colorHex)))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading) {
                            Text(model.displayName).font(Theme.display(.title2))
                            Text("\(model.state.points) points · \(model.runs.filter { $0.source == .live }.count) runs").foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                Section("Stats") { StatsSection() }
                Section("Badges") { BadgesSection() }
                Section("Runs") {
                    NavigationLink { HealthImportView() } label: {
                        Label("Add a run from Apple Health", systemImage: "heart.text.square.fill")
                    }
                    if model.runs.isEmpty { Text("No runs yet").foregroundStyle(Theme.textSecondary) }
                    ForEach(model.runs.prefix(50)) { r in
                        Button { model.presentedSummary = r } label: { RunRow(record: r) }.buttonStyle(.plain)
                    }
                }
                Section {
                    NavigationLink { InviteView() } label: {
                        Label("Invite a friend, get a free month of Pro", systemImage: "gift.fill")
                    }
                    NavigationLink { IntroCardsView(replay: true) } label: { Label("How Chomp works", systemImage: "questionmark.circle.fill") }
                    NavigationLink { ClubsView() } label: { Label("Clubs & friends", systemImage: "person.3.fill") }
                    NavigationLink { SettingsView() } label: { Label("Settings", systemImage: "gearshape.fill") }
                    if !model.pro.isPro {
                        Button { model.showPaywall = true } label: { Label("Get Chomp Pro", systemImage: "sparkles") }
                    }
                }
            }
            .navigationTitle("Profile")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct RunRow: View {
    @Environment(AppModel.self) private var model
    let record: RunRecord
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.body.weight(.semibold))
                Text("\(formatDistance(record.distance, miles: model.profile.useMiles)) · \(record.outcome.gained.count) streets"
                     + (record.source == .healthImport ? " · imported" : "") + (record.simulated ? " · simulated" : ""))
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Text("+\(record.outcome.totalPoints)").font(Theme.number(.subheadline))
        }
        .accessibilityElement(children: .combine)
    }
}

struct StatsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let p = model.progress
        let live = model.runs.filter { $0.source == .live && !$0.simulated }
        let totalKm = live.reduce(0) { $0 + $1.distance } / 1000
        Group {
            LabeledContent("Tokens captured", value: model.state.tokens(of: model.state.me).formatted())
            LabeledContent("Streets held", value: "\(model.streetsHeldEverywhere)")
            LabeledContent("Held around \(model.placeName)", value: p.heldFraction.percentString)
            LabeledContent("Explored around \(model.placeName)", value: p.exploredFraction.percentString)
            LabeledContent("Blocks held", value: "\(p.blocksHeld)")
            if model.pro.isPro {
                LabeledContent("Distance run", value: String(format: "%.1f km", totalKm))
                LabeledContent("Streets stolen back", value: "\(model.runs.reduce(0) { $0 + $1.outcome.stolen.count })")
                LabeledContent("Power pellets", value: "\(model.state.collectedPellets.count)")
                LabeledContent("Most-run street", value: mostRun ?? "–")
                Toggle("Heatmap on the map", isOn: Bindable(model).heatmapOn)
            } else {
                Button { model.showPaywall = true } label: {
                    Label("Detailed stats and heatmaps with Pro", systemImage: "chart.xyaxis.line")
                }
            }
        }
    }

    private var mostRun: String? {
        let byName = Dictionary(grouping: model.state.coverage) { model.area.segment($0.key)?.name ?? "" }
            .filter { !$0.key.isEmpty }
            .mapValues { $0.reduce(0) { $0 + $1.value.timesRun } }
        return byName.max { $0.value < $1.value }.map { "\($0.key) (\($0.value)×)" }
    }
}

struct BadgesSection: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let p = model.progress
        let badges: [(String, String, Bool)] = [
            ("First bite", "circle.grid.cross.fill", p.heldSegments > 0 || !model.state.coverage.isEmpty),
            ("10% of the map around you", "10.circle.fill", p.heldFraction >= 0.1),
            ("Block party", "square.grid.3x3.fill", !model.state.blockAwards.isEmpty),
            ("Frenzy", "bolt.circle.fill", !model.state.collectedPellets.isEmpty),
            ("Conquered a map square", "crown.fill", model.state.badges.contains { $0.hasPrefix("conquered:") }),
        ]
        ForEach(badges, id: \.0) { b in
            Label(b.0, systemImage: b.1)
                .foregroundStyle(b.2 ? Color(hex: model.profile.colorHex) : Theme.textSecondary.opacity(0.5))
                .accessibilityLabel("\(b.0), \(b.2 ? "earned" : "not yet earned")")
        }
        if model.isConquered {
            Text("Conquered map style unlocked.").font(.footnote).foregroundStyle(Theme.textSecondary)
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuth
    @State private var importing = false
    @State private var importResult: String?
    @State private var confirmReset = false
    @State private var customColour = Color.white
    @State private var nonce = ""
    @State private var accountError: String?

    var body: some View {
        @Bindable var model = model
        Form {
            Section("You") {
                TextField("Runner name", text: $model.profile.name)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(PlayerPalette.swatches) { s in
                            Button { model.profile.colorHex = s.hex; model.bumpMap() } label: {
                                Circle().fill(Color(hex: s.hex)).frame(width: 36, height: 36)
                                    .overlay(Circle().strokeBorder(Theme.textPrimary, lineWidth: model.profile.colorHex == s.hex ? 3 : 0))
                            }
                            .accessibilityLabel(s.name)
                            .accessibilityAddTraits(model.profile.colorHex == s.hex ? .isSelected : [])
                        }
                    }.padding(.vertical, 4)
                }
                if model.pro.isPro {
                    ColorPicker("Custom colour", selection: $customColour, supportsOpacity: false)
                        .onChange(of: customColour) { _, c in
                            let ui = UIColor(c)
                            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
                            ui.getRed(&r, green: &g, blue: &b, alpha: nil)
                            model.profile.colorHex = String(format: "%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
                            model.bumpMap()
                        }
                    Picker("Run trail", selection: $model.profile.trailStyle) {
                        ForEach(PlayerProfile.TrailStyle.allCases) { Text($0.label).tag($0) }
                    }
                } else {
                    Button("Custom colours & trails (Pro)") { model.showPaywall = true }
                }
            }

            Section {
                Toggle("Play privately", isOn: $model.profile.privateMode)
                NavigationLink("Privacy zones (\(model.profile.privacyZones.count))") { PrivacyZonesView() }
            } header: { Text("Privacy") } footer: {
                Text("Private mode keeps every run on this phone: solo play with bots only, nothing uploaded. Privacy zones hide where your runs start and end, even from you on shared images.")
            }

            Section {
                Picker("Map", selection: $model.profile.mapLook) {
                    ForEach(PlayerProfile.MapLook.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: model.profile.mapLook) { _, _ in model.bumpMap() }
            } header: { Text("Map brightness") } footer: {
                Text("Light is easiest to read in sunshine. Dark is the original arcade look.")
            }

            Section("Feel") {
                Toggle("Chomp sounds", isOn: $model.profile.soundOn)
                Toggle("Haptics", isOn: $model.profile.hapticsOn)
                Toggle("Use miles", isOn: $model.profile.useMiles)
            }

            Section {
                NavigationLink("Add a run from Apple Health") { HealthImportView() }
                Button(importing ? "Importing…" : "Import a year of Health runs (exploration)") {
                    Task {
                        importing = true
                        let n = await model.importHealthHistory()
                        importResult = n == 0 ? "No new runs with routes found." : "Imported \(n) run\(n == 1 ? "" : "s")."
                        importing = false
                    }
                }.disabled(importing)
                Button(importing ? "Importing…" : "Import from Strava (Pro)") {
                    guard model.pro.isPro else { model.showPaywall = true; return }
                    Task {
                        importing = true
                        importResult = await StravaImport.run(model: model, webAuth: webAuth)
                        importing = false
                    }
                }.disabled(importing)
                if let importResult { Text(importResult).font(.footnote).foregroundStyle(Theme.textSecondary) }
            } header: { Text("History") } footer: {
                Text("A single run added from Health within 7 days of running it captures streets like any other run, unless someone has run them since. A year of history and Strava imports only count towards streets you've explored, so they can't steal anyone's streets.")
            }

            Section {
                if !model.backend.isConfigured {
                    Text("Online play isn't connected in this build. Everything else works offline.").foregroundStyle(Theme.textSecondary)
                } else if model.backend.isSignedIn {
                    LabeledContent("Signed in", value: "Apple")
                    Button("Sign out") { Task { await model.backend.signOut() } }
                    Button("Delete online account", role: .destructive) { Task { try? await model.backend.deleteAccount() } }
                } else {
                    SignInWithAppleButton(.signIn) { req in
                        nonce = Nonce.random()
                        req.requestedScopes = [.fullName]
                        req.nonce = Nonce.sha256(nonce)
                    } onCompletion: { result in
                        guard case .success(let auth) = result, let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                              let tokenData = cred.identityToken, let token = String(data: tokenData, encoding: .utf8) else { return }
                        Task {
                            do {
                                try await model.backend.signInWithApple(idToken: token, nonce: nonce, displayName: model.displayName, colorHex: model.profile.colorHex)
                                if let id = model.backend.userID { await model.pro.identify(userID: id) }
                                await model.syncOnline()
                            } catch { accountError = error.localizedDescription }
                        }
                    }
                    .frame(height: 48)
                }
                if let accountError { Text(accountError).font(.footnote).foregroundStyle(Theme.danger) }
            } header: { Text("Online play") }

            Section("Chomp Pro") {
                if model.pro.isPro { Label("Pro is active", systemImage: "checkmark.seal.fill") }
                else { Button("See Pro") { model.showPaywall = true } }
                Button("Restore purchases") { Task { await model.pro.restore() } }
                #if DEBUG
                Toggle("Debug: pretend Pro", isOn: $model.profile.debugPro)
                #endif
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                Text(Area.osmAttribution + ", via the Overpass API.").font(.footnote).foregroundStyle(Theme.textSecondary)
                Text("Map tiles: OpenFreeMap, © OpenMapTiles, © OpenStreetMap contributors.").font(.footnote).foregroundStyle(Theme.textSecondary)
                Button("Reset all data on this phone", role: .destructive) { confirmReset = true }
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Reset everything?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { Task { await model.resetAllData() } }
        } message: { Text("Deletes your streets, runs and settings from this phone.") }
        .onAppear { customColour = Color(hex: model.profile.colorHex) }
    }
}

struct PrivacyZonesView: View {
    @Environment(AppModel.self) private var model
    @State private var name = "Home"
    @State private var radius = 250.0

    private var suggestions: [Coordinate] { model.zoneSuggestions }

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                ForEach(model.profile.privacyZones) { z in
                    VStack(alignment: .leading) {
                        Text(z.name).font(.body.weight(.semibold))
                        Text("\(Int(z.radius)) m radius").font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                .onDelete { model.profile.privacyZones.remove(atOffsets: $0) }
            } header: { Text("Zones") } footer: {
                Text("Runs that start or end inside a zone are trimmed on this phone before anything is saved or uploaded. Zone centres are deliberately shifted a little so their edge can't pinpoint your door. Streets inside a zone can only be captured by running through it, not by starting or finishing there.")
            }
            if !suggestions.isEmpty {
                Section("Suggested") {
                    ForEach(suggestions, id: \.self) { c in
                        HStack {
                            Text("Your runs often start or end here")
                            Spacer()
                            Button("Hide") { add(name: "Suggested zone", at: c) }
                            Button("Ignore") { model.profile.dismissedZoneSuggestions.append(c) }.foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
            Section("Add a zone at my current location") {
                TextField("Name", text: $name)
                Stepper("Radius \(Int(radius)) m", value: $radius, in: 150...800, step: 50)
                Button("Add zone here") {
                    guard let here = LocationPermission.shared.lastKnown else { return }
                    add(name: name, at: here)
                }
                .disabled(LocationPermission.shared.lastKnown == nil)
            }
        }
        .navigationTitle("Privacy zones")
    }

    private func add(name: String, at c: Coordinate) {
        model.profile.privacyZones.append(.fuzzed(name: name, around: c, radius: radius, jitter: model.rules.privacy.zoneJitterMetres))
    }
}

extension AppModel {
    /// Places runs keep starting/ending that aren't already hidden (likely home or work).
    var zoneSuggestions: [Coordinate] {
        let endpoints = runs.filter { $0.source == .live && !$0.simulated }.flatMap { $0.rawEndpoints ?? [] }
        return PrivacyTrimmer.suggestions(endpoints: endpoints, existing: profile.privacyZones,
                                          radius: rules.privacy.defaultZoneRadiusMetres)
            .filter { s in !profile.dismissedZoneSuggestions.contains { $0.distance(to: s) < rules.privacy.defaultZoneRadiusMetres } }
    }
}

enum StravaImport {
    /// Strava OAuth in the app; the code goes to the strava-import Edge Function,
    /// which holds the client secret, imports runs and returns a summary.
    @MainActor
    static func run(model: AppModel, webAuth: WebAuthenticationSession) async -> String {
        let backend = model.backend
        guard backend.isConfigured else { return BackendError.notConfigured.localizedDescription }
        guard backend.isSignedIn else { return BackendError.notSignedIn.localizedDescription }
        let clientID = (Bundle.main.infoDictionary?["StravaClientID"] as? String) ?? ""
        guard !clientID.isEmpty else { return "Strava isn't set up in this build (STRAVA_CLIENT_ID is empty)." }
        do {
            var code: String?
            if !UserDefaults.standard.bool(forKey: "stravaConnected") {
                var c = URLComponents(string: "https://www.strava.com/oauth/mobile/authorize")!
                c.queryItems = [.init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: "chomp://strava"),
                                .init(name: "response_type", value: "code"), .init(name: "approval_prompt", value: "auto"),
                                .init(name: "scope", value: "activity:read_all")]
                let callback = try await webAuth.authenticate(using: c.url!, callbackURLScheme: "chomp", preferredBrowserSession: .shared)
                code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "code" }?.value
                guard code != nil else { return "Strava didn't grant access." }
            }
            let r = try await backend.importStrava(code: code)
            UserDefaults.standard.set(true, forKey: "stravaConnected")
            await model.mergeServerCoverage()
            if r.imported == 0 { return "No new Strava runs to import." }
            return "Imported \(r.imported) Strava run\(r.imported == 1 ? "" : "s"), \(r.streets) streets explored." + (r.more ? " Tap again for more." : "")
        } catch let e as ASWebAuthenticationSessionError where e.code == .canceledLogin {
            return "Strava import cancelled."
        } catch {
            UserDefaults.standard.set(false, forKey: "stravaConnected")
            return "Strava import failed: \(error.localizedDescription)"
        }
    }
}

enum Nonce {
    static func random(length: Int = 32) -> String {
        let chars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var g = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in chars.randomElement(using: &g)! })
    }

    static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
