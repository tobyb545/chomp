import SwiftUI
import ChompKit

/// Invite a friend: when they join with your code, they get a month of Pro
/// straight away, and you get a month once they've finished their first run.
struct InviteView: View {
    @Environment(AppModel.self) private var model
    @State private var info: InviteInfo?
    @State private var loading = false
    @State private var error: String?
    @State private var entry = ""
    @State private var redeemMessage: String?
    @State private var redeeming = false

    private var accent: String { model.profile.colorHex }

    var body: some View {
        List {
            Section {
                VStack(spacing: 14) {
                    Image(systemName: "gift.fill").font(.system(size: 46)).foregroundStyle(Color(hex: accent))
                        .accessibilityHidden(true)
                    Text("Give a month, get a month").font(Theme.display(.title2)).multilineTextAlignment(.center)
                    Text("Your friend gets a month of Chomp Pro free when they join with your code. You get a free month when they finish their first run.")
                        .font(.subheadline).multilineTextAlignment(.center).foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section("Your code") { yourCode }

            if info?.redeemedCode == nil {
                Section {
                    TextField("Friend's code", text: $entry)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(Theme.number(.title3))
                        .onChange(of: entry) { _, v in
                            let n = InviteCode.normalise(v)
                            if n != v || n.count > 6 { entry = String(n.prefix(6)) }
                        }
                    Button(redeeming ? "Checking…" : "Use code") { Task { await redeem() } }
                        .disabled(!InviteCode.isValid(entry) || redeeming)
                    if let redeemMessage { Text(redeemMessage).font(.footnote.weight(.semibold)) }
                } header: { Text("Got a code from a friend?") } footer: {
                    Text("Works on new accounts within 30 days of joining, once per person.")
                }
            } else if let used = info?.redeemedCode {
                Section { Label("You joined with code \(used)", systemImage: "checkmark.seal.fill") }
            }

            if let until = model.pro.invitePro, until > .now {
                Section { Label("Free Pro until \(until.formatted(date: .abbreviated, time: .omitted))", systemImage: "sparkles") }
            }
        }
        .navigationTitle("Invite friends")
        .task { await load() }
        .refreshable { await load() }
        .onAppear { if let p = model.profile.pendingInviteCode, entry.isEmpty { entry = p } }
    }

    @ViewBuilder private var yourCode: some View {
        if !model.backend.isConfigured {
            Text("Invites need online play, which isn't connected in this build yet.").foregroundStyle(Theme.textSecondary)
        } else if !model.backend.isSignedIn {
            Text("Sign in with Apple (Profile → Settings → Online play) to get your invite code.").foregroundStyle(Theme.textSecondary)
        } else if let info {
            VStack(spacing: 16) {
                Text(info.code)
                    .font(.system(size: 44, weight: .black, design: .rounded)).tracking(6)
                    .foregroundStyle(Color(hex: accent))
                    .textSelection(.enabled)
                    .accessibilityLabel("Your code: \(info.code.map(String.init).joined(separator: " "))")
                ShareLink(item: shareText(info.code)) {
                    Label("Share invite", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                .buttonStyle(ChunkyButtonStyle(colorHex: accent, height: 54))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .listRowBackground(Color.clear)
            LabeledContent("Friends joined", value: "\(info.joined)")
            LabeledContent("Months earned", value: "\(info.rewarded)")
            if info.pending > 0 {
                Text("\(info.pending) friend\(info.pending == 1 ? " hasn't" : "s haven't") finished a run yet. Your month arrives when they do.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }
        } else if loading {
            HStack { ProgressView(); Text("Getting your code…").foregroundStyle(Theme.textSecondary) }
        } else if let error {
            Text(error).foregroundStyle(Theme.textSecondary)
        }
    }

    private func shareText(_ code: String) -> String {
        "Come and play Chomp with me: run your streets to eat the tokens and claim them before anyone else. "
            + "Join with my code \(code) and you get a month of Chomp Pro free. chomp://invite/\(code)"
    }

    private func load() async {
        guard model.backend.isSignedIn else { return }
        loading = true
        defer { loading = false }
        do {
            info = try await model.backend.myInvite()
            error = nil
        } catch { self.error = error.localizedDescription }
        await model.refreshInvitePro()
    }

    private func redeem() async {
        let code = InviteCode.normalise(entry)
        guard model.backend.isSignedIn else {
            // Kept until they sign in, then redeemed automatically.
            model.profile.pendingInviteCode = code
            redeemMessage = "Saved. It's applied as soon as you sign in to play online."
            return
        }
        redeeming = true
        defer { redeeming = false }
        do {
            let until = try await model.backend.redeemInvite(code: code)
            model.pro.invitePro = until
            model.profile.pendingInviteCode = nil
            redeemMessage = "Done! Pro is yours until \(until.formatted(date: .abbreviated, time: .omitted))."
            entry = ""
            info = try? await model.backend.myInvite()
        } catch {
            redeemMessage = Self.friendly(error)
        }
    }

    /// Database errors carry a readable message after "chomp: ".
    static func friendly(_ e: Error) -> String {
        let s = String(describing: e)
        if let r = s.range(of: "chomp: ") {
            return String(s[r.upperBound...].prefix { $0 != "\"" && $0 != "\n" && $0 != ")" })
        }
        return e.localizedDescription
    }
}
