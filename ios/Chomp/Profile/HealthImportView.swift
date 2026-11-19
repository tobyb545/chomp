import SwiftUI
import ChompKit

/// Pick a run recorded by another app (Apple Watch Workout, Strava, Garmin...)
/// and add it to Chomp afterwards, as if it had been recorded here.
struct HealthImportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var runs: [HealthService.WorkoutSummary]?
    @State private var working: UUID?
    @State private var message: String?

    var body: some View {
        List {
            Section {
                Text("Forgot to start Chomp? Runs recorded by your watch or another app show up here. Runs from the last \(days) days capture streets. Older ones count as streets you've explored.")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
                if let message { Text(message).font(.subheadline.weight(.semibold)) }
            }
            Section("Runs in Apple Health") {
                if let runs {
                    if runs.isEmpty {
                        Text("No new runs in the last 60 days.").foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(runs) { r in row(r) }
                    if runs.contains(where: { !$0.hasRoute }) {
                        Text(routeHelp).font(.footnote).foregroundStyle(Theme.textSecondary)
                    }
                } else {
                    HStack { ProgressView(); Text("Reading Health…").foregroundStyle(Theme.textSecondary) }
                }
            }
        }
        .navigationTitle("Add from Health")
        .task { runs = await model.healthRunsToImport() }
    }

    /// Shown when some runs have no route in Health.
    private var routeHelp: String {
        let none = runs?.allSatisfy { !$0.hasRoute } ?? false
        return "Runs marked No route were saved to Health without GPS, which Garmin Connect and Strava often do."
            + (none ? " If your Apple Watch runs show No route too, open the Settings app → Health → Data Access & Devices → Chomp and turn on Workout Routes." : "")
    }

    private var days: Int { Int(model.rules.imports.captureWindowHours / 24) }

    private func row(_ r: HealthService.WorkoutSummary) -> some View {
        let counts = model.importCaptures(endedAt: r.end)
        return Button {
            guard r.hasRoute else { message = AppModel.noRouteMessage(source: r.source); return }
            Task {
                working = r.id
                message = await model.importHealthRun(r)
                // Gone from the list once it's one of your runs.
                if model.runs.contains(where: { abs($0.startedAt.timeIntervalSince(r.start)) < 120 }) {
                    runs?.removeAll { $0.id == r.id }
                }
                working = nil
                if model.presentedSummary != nil { dismiss() }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.start.formatted(.dateTime.weekday(.abbreviated).day().month().hour().minute())).font(.body.weight(.semibold))
                    Text([r.distance.map { formatDistance($0, miles: model.profile.useMiles) },
                          Duration.seconds(r.end.timeIntervalSince(r.start)).formatted(.time(pattern: .hourMinuteSecond)),
                          r.source].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if working == r.id {
                    ProgressView()
                } else if !r.hasRoute {
                    Chip(text: "No route", colorHex: "555566")
                } else {
                    Chip(text: counts ? "Captures" : "Explore only", colorHex: counts ? model.profile.colorHex : "8888AA")
                }
            }
        }
        .disabled(working != nil)
        .accessibilityHint(!r.hasRoute ? "This run has no GPS route in Health, so it can't be added."
                           : counts ? "Adds this run. Streets you ran turn your colour." : "Adds this run as exploration only.")
    }
}
