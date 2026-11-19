import AppIntents
import Foundation

struct StartRunIntent: AppIntent {
    static let title: LocalizedStringResource = "Start a Chomp run"
    static let description = IntentDescription("Starts recording a run so you can collect coins.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.requestStart()
        return .result()
    }
}

struct FinishRunIntent: AppIntent {
    static let title: LocalizedStringResource = "Finish my Chomp run"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.requestStop()
        return .result()
    }
}

struct StreetsHeldIntent: AppIntent {
    static let title: LocalizedStringResource = "How many coins do I have?"

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let s = WidgetSnapshot.load() else { return .result(dialog: "Go for a run first!") }
        let attack = s.underAttack.first.map { " \($0.by) has been taking your coins on \($0.street)." } ?? ""
        return .result(dialog: "You've collected \(s.coinsHeld) coins, and you hold \(Int(s.townPercent * 100)) percent of the coins around \(s.townName).\(attack)")
    }
}

struct ChompShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartRunIntent(), phrases: ["Start a run in \(.applicationName)", "Go chomping with \(.applicationName)"],
                    shortTitle: "Start run", systemImageName: "figure.run")
        AppShortcut(intent: FinishRunIntent(), phrases: ["Finish my \(.applicationName) run"],
                    shortTitle: "Finish run", systemImageName: "stop.circle")
        AppShortcut(intent: StreetsHeldIntent(), phrases: ["How many coins do I have in \(.applicationName)"],
                    shortTitle: "My coins", systemImageName: "circle.grid.cross.fill")
    }
}
