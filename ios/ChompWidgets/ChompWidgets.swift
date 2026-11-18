import ActivityKit
import SwiftUI
import WidgetKit

@main
struct ChompWidgetBundle: WidgetBundle {
    var body: some Widget {
        StreetsHeldWidget()
        UnderAttackWidget()
        PowerPelletsWidget()
        RunLiveActivity()
    }
}

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry { SnapshotEntry(date: .now, snapshot: .placeholder) }
    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: .now, snapshot: context.isPreview ? .placeholder : (WidgetSnapshot.load() ?? .placeholder)))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let entry = SnapshotEntry(date: .now, snapshot: WidgetSnapshot.load() ?? .placeholder)
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(30 * 60))))
    }
}

private let ink = Color(hex: "07070E")
private let pellet = Color(hex: "FFF1C1")
private let power = Color(hex: "FF2BD6")
private let muted = Color(hex: "A3A3C2")

// MARK: Streets held

struct StreetsHeldWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "StreetsHeld", provider: SnapshotProvider()) { e in
            StreetsHeldView(s: e.snapshot).containerBackground(ink, for: .widget).widgetURL(URL(string: "chomp://map"))
        }
        .configurationDisplayName("Streets held")
        .description("Your territory in your home town.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

struct StreetsHeldView: View {
    @Environment(\.widgetFamily) private var family
    let s: WidgetSnapshot

    var body: some View {
        let c = Color(hex: s.playerColorHex)
        switch family {
        case .accessoryCircular:
            Gauge(value: min(1, s.townPercent)) { Text("\(s.streetsHeld)") } currentValueLabel: { Text("\(s.streetsHeld)") }
                .gaugeStyle(.accessoryCircularCapacity)
                .accessibilityLabel("\(s.streetsHeld) streets held")
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Text("CHOMP").font(.caption2.weight(.black))
                Text("\(s.streetsHeld) streets").font(.headline)
                Text("\(Int(s.townPercent * 100))% of \(s.townName)").font(.caption)
            }
        default:
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CHOMP").font(.system(size: 11, weight: .black, design: .rounded)).tracking(2).foregroundStyle(c)
                    Text("\(s.streetsHeld)").font(.system(size: 44, weight: .black, design: .rounded)).foregroundStyle(.white)
                        .minimumScaleFactor(0.5).contentTransition(.numericText())
                    Text("streets held").font(.caption.weight(.semibold)).foregroundStyle(muted)
                    Spacer(minLength: 0)
                    Text("\(String(format: "%.1f", s.kmHeld)) km · \(Int(s.townPercent * 100))%").font(.caption2.weight(.bold)).foregroundStyle(pellet)
                }
                if family == .systemMedium {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(s.townName).font(.headline).foregroundStyle(.white)
                        Label("\(s.blocksHeld) blocks", systemImage: "square.grid.3x3.fill").foregroundStyle(c)
                        Label("\(s.fadingSoon) fading", systemImage: "hourglass").foregroundStyle(muted)
                        if let b = s.bonusLabels.first { Label(b, systemImage: "star.fill").foregroundStyle(power).lineLimit(1) }
                    }
                    .font(.caption.weight(.semibold))
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: Under attack

struct UnderAttackWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "UnderAttack", provider: SnapshotProvider()) { e in
            UnderAttackView(s: e.snapshot).containerBackground(ink, for: .widget)
        }
        .configurationDisplayName("Under attack")
        .description("Streets rivals have eaten and streets about to fade.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct UnderAttackView: View {
    let s: WidgetSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("UNDER ATTACK", systemImage: "exclamationmark.triangle.fill").font(.caption.weight(.black)).foregroundStyle(Color(hex: "FF3355"))
            if s.underAttack.isEmpty {
                Text("All quiet. Your streets are safe… for now.").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
            }
            ForEach(s.underAttack.prefix(3), id: \.self) { a in
                VStack(alignment: .leading, spacing: 0) {
                    Text(a.street).font(.subheadline.weight(.bold)).foregroundStyle(.white).lineLimit(1)
                    Text("eaten by \(a.by)").font(.caption2).foregroundStyle(muted)
                }
            }
            Spacer(minLength: 0)
            if s.fadingSoon > 0 { Text("\(s.fadingSoon) streets fading").font(.caption2.weight(.bold)).foregroundStyle(pellet) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(URL(string: "chomp://map"))
    }
}

// MARK: Power pellets

struct PowerPelletsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PowerPellets", provider: SnapshotProvider()) { e in
            PowerPelletsView(s: e.snapshot).containerBackground(ink, for: .widget)
        }
        .configurationDisplayName("Today's power pellets")
        .description("Where today's frenzy landmarks are.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct PowerPelletsView: View {
    let s: WidgetSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("POWER PELLETS", systemImage: "bolt.circle.fill").font(.caption.weight(.black)).foregroundStyle(power)
            ForEach(s.pellets, id: \.self) { p in
                HStack(spacing: 6) {
                    Image(systemName: p.collected ? "checkmark.circle.fill" : "circle.fill").font(.caption2)
                        .foregroundStyle(p.collected ? muted : power)
                    Text(p.name).font(.caption.weight(.bold)).foregroundStyle(p.collected ? muted : .white).lineLimit(1)
                        .strikethrough(p.collected)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(p.name)\(p.collected ? ", collected" : "")")
            }
            Spacer(minLength: 0)
            Text("10 min frenzy · 2× points").font(.caption2).foregroundStyle(muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(URL(string: "chomp://map"))
    }
}

// MARK: Live Activity

struct RunLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ChompRunAttributes.self) { ctx in
            LockScreenRunView(attrs: ctx.attributes, state: ctx.state)
                .activityBackgroundTint(ink)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { ctx in
            let c = Color(hex: ctx.attributes.playerColorHex)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading) {
                        Text("\(ctx.state.streetsCaptured)").font(.title.weight(.black)).foregroundStyle(c)
                        Text("streets").font(.caption2).foregroundStyle(muted)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing) {
                        Text("\(ctx.state.pelletsEaten)").font(.title.weight(.black)).foregroundStyle(pellet)
                        Text("pellets").font(.caption2).foregroundStyle(muted)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(ctx.attributes.startedAt, style: .timer).font(.title3.weight(.heavy)).monospacedDigit()
                        .multilineTextAlignment(.center)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let f = ctx.state.frenzyEndsAt, f > .now {
                        HStack { Image(systemName: "bolt.fill"); Text("FRENZY"); Spacer(); Text(timerInterval: Date.now...f, countsDown: true).monospacedDigit() }
                            .font(.headline.weight(.black)).foregroundStyle(power)
                    } else {
                        Text(String(format: "%.2f km", ctx.state.distanceMetres / 1000)).font(.headline).foregroundStyle(.white)
                    }
                }
            } compactLeading: {
                Image(systemName: ctx.state.frenzyEndsAt.map { $0 > .now } == true ? "bolt.fill" : "circle.grid.cross.fill").foregroundStyle(c)
            } compactTrailing: {
                Text("\(ctx.state.streetsCaptured)").font(.headline.weight(.black)).foregroundStyle(c)
            } minimal: {
                Text("\(ctx.state.streetsCaptured)").font(.caption.weight(.black)).foregroundStyle(c)
            }
        }
    }
}

struct LockScreenRunView: View {
    let attrs: ChompRunAttributes
    let state: ChompRunAttributes.ContentState

    var body: some View {
        let c = Color(hex: attrs.playerColorHex)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("CHOMP · \(attrs.townName.uppercased())").font(.caption.weight(.black)).foregroundStyle(c)
                Spacer()
                if state.isPaused { Text("PAUSED").font(.caption.weight(.black)).foregroundStyle(pellet) }
                else { Text(attrs.startedAt, style: .timer).font(.headline.weight(.heavy)).monospacedDigit().foregroundStyle(.white) }
            }
            HStack {
                stat("\(state.streetsCaptured)", "streets", c)
                stat("\(state.pelletsEaten)", "pellets", pellet)
                stat("\(state.streetsStolen)", "won back", .white)
                stat(String(format: "%.2f", state.distanceMetres / 1000), "km", .white)
            }
            if let f = state.frenzyEndsAt, f > .now {
                HStack { Image(systemName: "bolt.fill"); Text("FRENZY 2×"); Spacer(); Text(timerInterval: Date.now...f, countsDown: true).monospacedDigit() }
                    .font(.subheadline.weight(.black)).foregroundStyle(.white)
                    .padding(8).background(power, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(16)
    }

    private func stat(_ v: String, _ l: String, _ c: Color) -> some View {
        VStack(spacing: 0) {
            Text(v).font(.title2.weight(.black)).foregroundStyle(c).monospacedDigit()
            Text(l).font(.caption2.weight(.semibold)).foregroundStyle(muted)
        }
        .frame(maxWidth: .infinity)
    }
}
