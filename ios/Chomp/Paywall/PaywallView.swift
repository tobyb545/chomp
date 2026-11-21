import RevenueCat
import SwiftUI

struct PaywallView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // In the content rather than the toolbar, so it can never sit on top of the title.
                    HStack {
                        Button("Not now") { dismiss() }.font(.body.weight(.semibold))
                        Spacer()
                    }
                    Text("CHOMP PRO").font(Theme.display(.largeTitle)).foregroundStyle(Theme.readableTint(model.profile.colorHex))
                        .accessibilityAddTraits(.isHeader)
                    Text("More ways to show off. Never more power: Pro can't help you collect, steal or defend a single coin.")
                        .multilineTextAlignment(.center).font(.headline).foregroundStyle(Theme.textSecondary)
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(ProStore.Feature.allCases) { f in
                            Label(f.title, systemImage: f.symbol).font(.body.weight(.semibold))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))

                    if !model.pro.isConfigured {
                        Text("Purchases aren't configured in this build yet.")
                            .font(.footnote).foregroundStyle(Theme.textSecondary)
                    } else if model.pro.pricesUnavailable {
                        VStack(spacing: 8) {
                            Text("Prices couldn't load from the App Store. Check your connection and try again.")
                                .font(.footnote).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                            Button("Try again") { Task { await model.pro.refresh() } }.font(.footnote.weight(.semibold))
                            #if DEBUG
                            if let d = model.pro.pricesErrorDetail {
                                Text(d).font(.caption2).foregroundStyle(Theme.danger).multilineTextAlignment(.leading)
                            }
                            #endif
                        }
                    } else if model.pro.packages.isEmpty {
                        Text("Loading prices…").font(.footnote).foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(model.pro.packages, id: \.identifier) { pkg in
                        Button { Task { await model.pro.purchase(pkg); if model.pro.isPro { dismiss() } } } label: {
                            VStack(spacing: 2) {
                                Text(pkg.packageType == .annual ? "Yearly" : pkg.packageType == .monthly ? "Monthly" : pkg.storeProduct.localizedTitle)
                                Text(pkg.localizedPriceString).font(.subheadline.weight(.semibold))
                            }
                        }
                        .buttonStyle(ChunkyButtonStyle(colorHex: pkg.packageType == .annual ? model.profile.colorHex : "2A2A4A", height: 64))
                    }
                    Button {
                        dismiss()
                        model.showInvite = true
                    } label: { Label("Or invite a friend for a free month", systemImage: "gift.fill") }
                        .font(.subheadline.weight(.semibold))
                    Button("Restore purchases") { Task { await model.pro.restore() } }.font(.footnote)
                    if let e = model.pro.lastError { Text(e).font(.footnote).foregroundStyle(Theme.danger) }
                    Text("Chomp Pro renews automatically unless cancelled at least 24 hours before the end of the current period. Manage or cancel it in Settings › your name › Subscriptions.")
                        .font(.caption).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                    // Required for subscriptions (App Review 3.1.2): Apple's standard EULA, plus our own
                    // terms and privacy policy on the website.
                    ViewThatFits {
                        HStack(spacing: 16) { legalLinks }
                        VStack(spacing: 8) { legalLinks }
                    }
                    .font(.caption.weight(.semibold))
                }
                .padding(20)
            }
            .background(Theme.background)
            .toolbar(.hidden, for: .navigationBar)
            .task { await model.pro.refresh() }
        }
    }

    @ViewBuilder private var legalLinks: some View {
        Link("Terms of Use (EULA)", destination: ProStore.appleEULA)
        if let web = AppModel.webURL, let terms = URL(string: web + "/terms/") { Link("Chomp terms", destination: terms) }
        if let web = AppModel.webURL, let privacy = URL(string: web + "/privacy/") { Link("Privacy policy", destination: privacy) }
    }
}
