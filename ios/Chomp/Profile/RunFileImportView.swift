import SwiftUI
import UniformTypeIdentifiers

/// Add a run recorded by another app from a GPX, TCX or FIT file, with how-tos
/// for getting that file out of Garmin Connect, an Apple Watch and Strava.
struct RunFileImportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    @State private var busy = false
    @State private var result: String?
    @State private var open: Source? = nil

    enum Source: String, CaseIterable, Identifiable {
        case garmin = "Garmin Connect", watch = "Apple Watch", strava = "Strava"
        var id: String { rawValue }
        var icon: String {
            switch self { case .garmin: "applewatch.side.right"; case .watch: "applewatch"; case .strava: "figure.run" }
        }
    }

    static let types: [UTType] = ["gpx", "tcx", "fit"].compactMap { UTType(filenameExtension: $0) } + [.xml]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        picking = true
                    } label: {
                        Label(busy ? "Adding your run…" : "Choose a run file", systemImage: "doc.badge.plus")
                            .font(.headline)
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("chooseRunFile")
                    if let result {
                        Text(result).font(.subheadline).foregroundStyle(Theme.textSecondary)
                    }
                } footer: {
                    Text("Chomp reads GPX, TCX and FIT files. Runs from the last \(days) days collect coins like any other run. Older runs go into your history only.")
                }

                Section {
                    ForEach(Source.allCases) { s in
                        DisclosureGroup(isExpanded: Binding(get: { open == s }, set: { open = $0 ? s : nil })) {
                            steps(for: s)
                        } label: {
                            Label(s.rawValue, systemImage: s.icon)
                        }
                    }
                } header: {
                    Text("How to get your run file")
                } footer: {
                    Text("Shortcut: in most apps, Share a run file and pick Chomp. It opens here and is added straight away.")
                }
            }
            .navigationTitle("Import a run")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .fileImporter(isPresented: $picking, allowedContentTypes: Self.types, allowsMultipleSelection: true) { r in
                guard case .success(let urls) = r, !urls.isEmpty else { return }
                busy = true
                Task {
                    var lines: [String] = []
                    for url in urls { lines.append(await model.importRunFile(url)) }
                    result = lines.joined(separator: "\n\n")
                    busy = false
                }
            }
        }
    }

    private var days: Int { Int(model.rules.imports.captureWindowHours / 24) }

    @ViewBuilder private func steps(for s: Source) -> some View {
        switch s {
        case .garmin:
            Step(1, "In Safari, go to connect.garmin.com and sign in. The Garmin Connect app can't export files.")
            Step(2, "Open Activities, then tap the run you want.")
            Step(3, "Tap the gear icon at the top right, then Export to GPX. The file saves to Downloads.")
            Step(4, "Come back here, tap Choose a run file and pick it from Downloads.")
            Note("Export Original gives a .zip instead. Tap it in the Files app to unzip it, then choose the .fit file inside.")
        case .watch:
            Step(1, "Easiest: start your runs from Chomp on your watch, with your phone on you, and they collect coins as you go.")
            Step(2, "For a run you recorded in the Workout app: open the Health app, tap your picture at the top right, then Export All Health Data.")
            Step(3, "Save the export to Files, then tap it in Files to unzip it.")
            Step(4, "Here, tap Choose a run file and open apple_health_export, then workout-routes. Each run is a .gpx file named by its date.")
            Note("The export includes all your Health data and can take a few minutes. It stays on your phone: Chomp only reads the run file you pick.")
        case .strava:
            Step(1, "In Safari, go to strava.com and sign in. The Strava app can't export files.")
            Step(2, "Open the run. If you see the mobile site, tap the aA button and choose Request Desktop Website.")
            Step(3, "Tap the ••• menu on the left of the run, then Export GPX. The file saves to Downloads.")
            Step(4, "Come back here, tap Choose a run file and pick it from Downloads.")
            Note("Only your own runs can be exported.")
        }
    }

    private struct Step: View {
        let n: Int, text: String
        init(_ n: Int, _ text: String) { self.n = n; self.text = text }
        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(n)").font(.subheadline.weight(.bold)).monospacedDigit()
                    .frame(width: 22, height: 22).background(Theme.surfaceRaised, in: Circle())
                Text(text).font(.subheadline)
            }
            .padding(.vertical, 2)
        }
    }

    private struct Note: View {
        let text: String
        init(_ text: String) { self.text = text }
        var body: some View {
            Label(text, systemImage: "info.circle").font(.footnote).foregroundStyle(Theme.textSecondary)
        }
    }
}
