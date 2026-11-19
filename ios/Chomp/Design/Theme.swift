import SwiftUI
import UIKit

/// Design tokens. Surfaces adapt to light/dark; the map itself is always dark.
enum Theme {
    static func dynamic(light: String, dark: String) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(Color(hex: dark)) : UIColor(Color(hex: light)) })
    }

    static let background = dynamic(light: "F4F3FA", dark: "07070E")
    static let surface = dynamic(light: "FFFFFF", dark: "14142A")
    static let surfaceRaised = dynamic(light: "ECEBF6", dark: "1D1D38")
    static let textPrimary = dynamic(light: "0E0E1C", dark: "F4F3FF")
    static let textSecondary = dynamic(light: "5B5B78", dark: "A3A3C2")
    static let hairline = dynamic(light: "DDDCEA", dark: "2A2A4A")
    static let pellet = Color(hex: "FFF1C1")
    static let power = Color(hex: "FF2BD6")
    static let danger = Color(hex: "FF3355")
    static let success = Color(hex: "2BE38B")

    /// HUD panels floating over the (always dark) map.
    static let hud = Color(hex: "0C0C1A").opacity(0.86)
    static let hudText = Color(hex: "F4F3FF")
    static let hudSecondary = Color(hex: "A3A3C2")

    static func display(_ style: Font.TextStyle = .largeTitle) -> Font {
        .system(style, design: .rounded).weight(.black)
    }

    static func number(_ style: Font.TextStyle = .title2) -> Font {
        .system(style, design: .rounded).weight(.heavy).monospacedDigit()
    }
}

/// Readable text on any player colour.
extension Color {
    static func onAccent(_ hex: String) -> Color {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r = Double((v >> 16) & 0xff) / 255, g = Double((v >> 8) & 0xff) / 255, b = Double(v & 0xff) / 255
        return (0.299 * r + 0.587 * g + 0.114 * b) > 0.55 ? Color(hex: "0A0A14") : .white
    }
}

struct HUDPanel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(14)
            .background(Theme.hud, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.08)))
            .environment(\.colorScheme, .dark)
    }
}

struct StatTile: View {
    let value: String
    let label: String
    var tint: Color = Theme.hudText

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(Theme.number(.title3)).foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption2.weight(.semibold)).textCase(.uppercase).foregroundStyle(Theme.hudSecondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// The big arcade-style button.
struct ChunkyButtonStyle: ButtonStyle {
    var colorHex: String
    var height: CGFloat = 72

    func makeBody(configuration: Configuration) -> some View {
        let c = Color(hex: colorHex)
        configuration.label
            .font(Theme.display(.title2))
            .foregroundStyle(Color.onAccent(colorHex))
            .frame(maxWidth: .infinity, minHeight: height)
            .background(
                RoundedRectangle(cornerRadius: height / 2.6, style: .continuous)
                    .fill(c)
                    .shadow(color: c.opacity(0.6), radius: configuration.isPressed ? 6 : 18)
            )
            .overlay(
                RoundedRectangle(cornerRadius: height / 2.6, style: .continuous)
                    .strokeBorder(.white.opacity(0.35), lineWidth: 2)
            )
            .offset(y: configuration.isPressed ? 3 : 0)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

struct RoundIconButton: View {
    let symbol: String
    let label: String
    var badge: Int = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.hudText)
                .frame(width: 52, height: 52)
                .background(Theme.hud, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.1)))
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text("\(min(badge, 99))").font(.caption2.bold()).foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Theme.danger, in: Capsule())
                            .offset(x: 4, y: -4)
                    }
                }
        }
        .accessibilityLabel(label)
        .accessibilityValue(badge > 0 ? "\(badge) new" : "")
    }
}

struct Chip: View {
    let text: String
    var colorHex: String = "FFF1C1"
    var body: some View {
        Text(text)
            .font(.caption2.weight(.heavy))
            .textCase(.uppercase)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(Color.onAccent(colorHex))
            .background(Color(hex: colorHex), in: Capsule())
    }
}

struct ProgressRing: View {
    let fraction: Double
    let colorHex: String
    var lineWidth: CGFloat = 7

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.12), lineWidth: lineWidth)
            Circle().trim(from: 0, to: max(0.005, min(1, fraction)))
                .stroke(Color(hex: colorHex), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: Color(hex: colorHex).opacity(0.7), radius: 4)
        }
    }
}

extension Double {
    var percentString: String {
        let p = self * 100
        return p < 10 && p > 0 ? String(format: "%.1f%%", p) : "\(Int(p.rounded()))%"
    }
}

func formatDistance(_ metres: Double, miles: Bool) -> String {
    if miles { return String(format: "%.2f mi", metres / 1609.344) }
    return metres < 1000 ? "\(Int(metres)) m" : String(format: "%.2f km", metres / 1000)
}
