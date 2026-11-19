import SwiftUI
import ChompKit

/// One weekly goal with a progress bar.
struct GoalRow: View {
    let goal: WeeklyGoal
    let colorHex: String
    var dark = true

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: goal.done ? "checkmark.circle.fill" : goal.symbol)
                .font(.body.weight(.bold))
                .foregroundStyle(goal.done ? Theme.success : Color(hex: colorHex))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(goal.title).font(.subheadline.weight(.semibold))
                        .foregroundStyle(dark ? Theme.hudText : Theme.textPrimary)
                        .strikethrough(goal.done)
                    Spacer()
                    Text("\(min(goal.progress, goal.target).formatted())/\(goal.target.formatted())")
                        .font(Theme.number(.caption)).foregroundStyle(dark ? Theme.hudSecondary : Theme.textSecondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill((dark ? Color.white : Theme.textSecondary).opacity(0.15))
                        Capsule().fill(goal.done ? Theme.success : Color(hex: colorHex))
                            .frame(width: max(6, geo.size.width * goal.fraction))
                    }
                }
                .frame(height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(goal.title). \(goal.done ? "Done" : "\(goal.progress) of \(goal.target)").")
    }
}

/// Streak and weekly goals, opened from the map header.
struct GoalsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let streak = model.streak
        let goals = model.weeklyGoals
        let resets = Goals.calendar.date(byAdding: .day, value: 7, to: Goals.weekStart(.now)) ?? .now
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 16) {
                        Image(systemName: "flame.fill").font(.system(size: 38))
                            .foregroundStyle(streak.current > 0 ? Theme.danger : Theme.textSecondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(streak.current == 1 ? "1 day" : "\(streak.current) days").font(Theme.number(.title))
                            Text(streak.atRisk ? "Run today to keep it going" : streak.ranToday ? "You've run today. Nice." : "Run today to start a streak")
                                .font(.subheadline).foregroundStyle(streak.atRisk ? Theme.danger : Theme.textSecondary)
                        }
                        Spacer()
                        VStack(spacing: 0) {
                            Text("\(streak.best)").font(Theme.number(.title3))
                            Text("BEST").font(.caption2.weight(.heavy)).foregroundStyle(Theme.textSecondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Best streak \(streak.best) days")
                    }
                    .padding(.vertical, 6)
                } header: { Text("Run streak") } footer: {
                    Text("Any run counts, live or imported from Apple Health. If your streak would end tonight, Chomp reminds you at 7pm.")
                }

                Section {
                    ForEach(goals) { g in GoalRow(goal: g, colorHex: model.profile.colorHex, dark: false).padding(.vertical, 4) }
                } header: { Text("This week's goals") } footer: {
                    Text("Everyone gets the same three goals. New ones \(resets.formatted(.relative(presentation: .named))). Progress counts runs since Monday.")
                }
            }
            .navigationTitle("Goals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Small flame + goals chip in the map header.
struct StreakChip: View {
    @Environment(AppModel.self) private var model
    var action: () -> Void

    var body: some View {
        let s = model.streak
        let goals = model.weeklyGoals
        Button(action: action) {
            HStack(spacing: 8) {
                Label("\(s.current)", systemImage: "flame.fill")
                    .foregroundStyle(s.atRisk ? Theme.danger : s.current > 0 ? Color(hex: "FF8A3D") : Theme.hudSecondary)
                Text("·").foregroundStyle(Theme.hudSecondary)
                Label("\(goals.filter(\.done).count)/\(goals.count)", systemImage: "target")
                    .foregroundStyle(Theme.hudText)
            }
            .font(.caption.weight(.heavy))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.white.opacity(0.08), in: Capsule())
        }
        .accessibilityLabel("Run streak \(s.current) days. \(goals.filter(\.done).count) of \(goals.count) weekly goals done.")
        .accessibilityHint("Shows your goals")
    }
}

/// Plans a loop from where you are through the streets worth running.
struct RoutePlannerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var goal: AppModel.RouteGoal = .capture
    @State private var distanceKm: Double = 5
    @State private var seed: UInt64 = 1
    @State private var planning = false
    @State private var result: PlannedRoute?
    @State private var failed = false

    private var miles: Bool { model.profile.useMiles }
    private var metres: Double { distanceKm * (miles ? 1609.344 : 1000) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Aim", selection: $goal) { ForEach(AppModel.RouteGoal.allCases) { Text($0.label).tag($0) } }
                        .pickerStyle(.segmented)
                    Text(goal.detail).font(.footnote).foregroundStyle(Theme.textSecondary)
                } header: { Text("What for") }

                Section {
                    VStack(alignment: .leading) {
                        Text(String(format: "%.1f %@", distanceKm, miles ? "mi" : "km")).font(Theme.number(.title2))
                        Slider(value: $distanceKm, in: 1...(miles ? 13 : 21), step: 0.5)
                            .accessibilityLabel("Distance")
                            .accessibilityValue(String(format: "%.1f %@", distanceKm, miles ? "miles" : "kilometres"))
                    }
                } header: { Text("How far") } footer: {
                    Text("A loop that starts and ends \(LocationPermission.shared.lastKnown.map { model.area.contains($0) } == true ? "where you are" : "in the middle of the map").")
                }

                Section {
                    Button {
                        Task { await plan(next: result != nil) }
                    } label: {
                        HStack {
                            Text(result == nil ? "Plan a route" : "Try another")
                            if planning { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(planning || model.area.segments.isEmpty)
                    if result != nil {
                        Button("Show it on the map") {
                            model.plannedRoute = result
                            if let first = result?.coordinates.first { model.focusRequest = first }
                            dismiss()
                        }
                        .font(.body.weight(.semibold))
                    }
                    if model.plannedRoute != nil {
                        Button("Clear the planned route", role: .destructive) {
                            model.plannedRoute = nil
                            dismiss()
                        }
                    }
                }
                if let r = result {
                    Section("Route") {
                        LabeledContent("Distance", value: formatDistance(r.distance, miles: miles))
                        LabeledContent("Streets to chomp", value: "\(r.targets)")
                        LabeledContent("Tokens on them", value: r.tokens.formatted())
                    }
                } else if failed {
                    Section {
                        Text("Couldn't find a loop here. Try a shorter distance, or move the map onto some streets.")
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

            }
            .navigationTitle("Plan a route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onChange(of: goal) { _, _ in result = nil }
            .onChange(of: distanceKm) { _, _ in result = nil }
        }
        .presentationDetents([.large])
    }

    private func plan(next: Bool) async {
        planning = true
        failed = false
        if next { seed &+= 1 }
        result = await model.planRoute(goal: goal, distance: metres, seed: seed)
        failed = result == nil
        planning = false
    }
}
