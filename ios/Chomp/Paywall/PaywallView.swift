import RevenueCat
import SwiftUI

struct PaywallView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Text("CHOMP PRO").font(Theme.display(.largeTitle)).foregroundStyle(Color(hex: model.profile.colorHex))
                        .accessibilityAddTraits(.isHeader)
                    Text("More ways to show off. Never more power: Pro can't help you capture or defend a single street.")
                        .multilineTextAlignment(.center).font(.headline).foregroundStyle(Theme.textSecondary)
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(ProStore.Feature.allCases) { f in
                            Label(f.title, systemImage: f.symbol).font(.body.weight(.semibold))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))

                    if model.pro.packages.isEmpty {
                        Text(model.pro.isConfigured ? "Loading prices…" : "Purchases aren't configured in this build yet.")
                            .font(.footnote).foregroundStyle(Theme.textSecondary)
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
                    Text("Subscriptions renew automatically until cancelled in Settings › Apple ID › Subscriptions.")
                        .font(.caption).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                }
                .padding(20)
            }
            .background(Theme.background)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Not now") { dismiss() } } }
            .task { await model.pro.refresh() }
        }
    }
}
