import SwiftUI
import ChompKit

extension BadgeTier {
    var colors: [Color] {
        switch self {
        case .bronze: [Color(hex: "F0A265"), Color(hex: "9A5524")]
        case .silver: [Color(hex: "D7DCE8"), Color(hex: "6B7391")]
        case .gold: [Color(hex: "FFE07A"), Color(hex: "C98A00")]
        case .special: [Color(hex: "FF5FE0"), Color(hex: "6D4BFF")]
        }
    }
    var label: String { rawValue.capitalized }
}

/// A round medal: tier-coloured when earned; grey with a progress ring when not.
struct BadgeMedal: View {
    let badge: Badge
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            if badge.earned {
                Circle().fill(LinearGradient(colors: badge.tier.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .shadow(color: badge.tier.colors[1].opacity(0.5), radius: size * 0.08, y: size * 0.04)
                Circle().inset(by: size * 0.09)
                    .fill(LinearGradient(colors: [badge.tier.colors[1], badge.tier.colors[1].opacity(0.75)], startPoint: .top, endPoint: .bottom))
                Circle().inset(by: size * 0.09).stroke(.white.opacity(0.35), lineWidth: size * 0.025)
                Image(systemName: badge.symbol).font(.system(size: size * 0.36, weight: .bold)).foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                // Gloss
                Circle().trim(from: 0.55, to: 0.95).stroke(.white.opacity(0.45), style: StrokeStyle(lineWidth: size * 0.03, lineCap: .round))
                    .rotationEffect(.degrees(0)).padding(size * 0.05)
            } else {
                Circle().fill(Theme.surfaceRaised)
                Circle().stroke(Theme.hairline, lineWidth: size * 0.06)
                Circle().trim(from: 0, to: badge.progress)
                    .stroke(badge.tier.colors[1], style: StrokeStyle(lineWidth: size * 0.06, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: badge.symbol).font(.system(size: size * 0.34, weight: .bold)).foregroundStyle(Theme.textSecondary.opacity(0.55))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension Badge {
    /// "340 / 1,000" (or "3.2 / 10 km").
    var progressText: String? {
        guard counted, !earned else { return nil }
        let unitSuffix = unit == 1000 ? " km" : id.hasPrefix("map-") ? "%" : ""
        func fmt(_ v: Double) -> String {
            let x = v / unit
            return unit == 1 && !id.hasPrefix("map-") ? Int(x).formatted() : x.formatted(.number.precision(.fractionLength(0...1)))
        }
        return "\(fmt(current)) / \(fmt(target))\(unitSuffix)"
    }
}

/// Profile grid of every badge.
struct BadgeGrid: View {
    @Environment(AppModel.self) private var model
    @State private var selected: Badge?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 14) {
            ForEach(model.badges) { b in
                Button { selected = b } label: {
                    VStack(spacing: 6) {
                        BadgeMedal(badge: b)
                        Text(b.title).font(.caption.weight(.semibold)).foregroundStyle(b.earned ? Theme.textPrimary : Theme.textSecondary)
                            .multilineTextAlignment(.center).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        if let p = b.progressText {
                            Text(p).font(.caption2.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(b.title), \(b.tier.label). \(b.earned ? "Earned" : "Not yet: \(b.detail)")\(b.progressText.map { ", \($0)" } ?? "")")
                .accessibilityAddTraits(.isButton)
            }
        }
        .padding(.vertical, 8)
        .sheet(item: $selected) { b in BadgeDetailView(badge: b, earnedAt: model.profile.badgesEarned[b.id], celebrate: false) }
        if model.isConquered {
            Text("Conquered map style unlocked.").font(.footnote).foregroundStyle(Theme.textSecondary)
        }
    }
}

/// One badge up close. `celebrate` is the unlock screen shown after a run.
struct BadgeDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let badge: Badge
    let earnedAt: Date?
    let celebrate: Bool
    @State private var shown = false
    @State private var shareImage: Image?

    var body: some View {
        VStack(spacing: 16) {
            if celebrate {
                Text("BADGE UNLOCKED").font(.caption.weight(.heavy)).tracking(2).foregroundStyle(badge.tier.colors[0])
            }
            BadgeMedal(badge: badge, size: 132)
                .scaleEffect(shown || !celebrate ? 1 : 0.4)
                .rotationEffect(.degrees(shown || !celebrate ? 0 : -25))
            Text(badge.title).font(Theme.display(.title)).foregroundStyle(.white)
            Text(badge.detail).font(.body.weight(.medium)).foregroundStyle(Theme.hudSecondary).multilineTextAlignment(.center)
            if badge.earned, let earnedAt {
                Text("\(badge.tier.label) · earned \(earnedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.hudSecondary)
            } else if let p = badge.progressText {
                ProgressView(value: badge.progress).tint(badge.tier.colors[1]).frame(maxWidth: 220)
                Text(p).font(.footnote.monospacedDigit()).foregroundStyle(Theme.hudSecondary)
            }
            if badge.earned, let img = shareImage {
                ShareLink(item: img, preview: SharePreview(badge.title, image: img)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(ChunkyButtonStyle(colorHex: model.profile.colorHex, height: 52))
            }
            Button(celebrate ? "Nice" : "Done") { dismiss() }
                .font(.body.weight(.semibold)).foregroundStyle(Theme.hudSecondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: "0C0C1A").ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.55)) { shown = true }
            if badge.earned { shareImage = renderShare() }
        }
    }

    @MainActor
    private func renderShare() -> Image? {
        let r = ImageRenderer(content: BadgeShareCard(badge: badge, name: model.profile.name).frame(width: 360, height: 640))
        r.scale = 3
        return r.uiImage.map { Image(uiImage: $0) }
    }
}

/// 9:16 share image for an earned badge (same look as the run Story card).
struct BadgeShareCard: View {
    let badge: Badge
    let name: String
    private let muted = Color(hex: "9A9DB8")

    var body: some View {
        ZStack {
            Color(hex: "0B0B14")
            RadialGradient(colors: [badge.tier.colors[1].opacity(0.45), .clear], center: UnitPoint(x: 0.5, y: 0.36), startRadius: 0, endRadius: 260)
            VStack(spacing: 0) {
                Spacer().frame(height: 110)
                Text("BADGE UNLOCKED").font(.system(size: 13, weight: .heavy).width(.condensed)).tracking(3).foregroundStyle(badge.tier.colors[0])
                BadgeMedal(badge: badge, size: 170).padding(.top, 26)
                Text(badge.title.uppercased()).font(.system(size: 40, weight: .heavy).width(.condensed)).foregroundStyle(.white).padding(.top, 28)
                Text(badge.detail).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(0.85)).padding(.top, 6)
                Text("\(badge.tier.label.uppercased()) · \(name.uppercased())").font(.system(size: 11, weight: .semibold)).tracking(1.4)
                    .foregroundStyle(muted).padding(.top, 14)
                Spacer()
                HStack(spacing: 7) {
                    Image(uiImage: CoinIcon.render(colorHex: "FFC83D")).resizable().frame(width: 18, height: 18)
                    Text("CHOMP").font(.system(size: 15, weight: .black).width(.condensed)).tracking(2).foregroundStyle(.white)
                    Spacer()
                    Text("The running game · App Store").font(.system(size: 11, weight: .semibold)).foregroundStyle(muted)
                }
                .padding(.horizontal, 26)
                .padding(.bottom, 86)
            }
        }
        .frame(width: 360, height: 640)
    }
}
