import SwiftUI
import WatchConnectivity
import WatchKit

@main
struct ChompWatchApp: App {
    @State private var model = WatchModel()
    var body: some Scene {
        WindowGroup { WatchRunView().environment(model) }
    }
}

/// Mirrors the phone's run; start/stop commands go back to the phone, which
/// does the recording (GPS + matching live on the phone in this milestone).
@MainActor
@Observable
final class WatchModel: NSObject, WCSessionDelegate {
    var running = false
    var startedAt: Date?
    /// While running: coins stolen this run. Otherwise: all-time coins.
    var streets = 0
    var pellets = 0
    var distance = 0.0
    var frenzyEndsAt: Date?
    var colorHex = "C6FF00"
    var lastCapture: String?
    var reachable = false

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func send(_ cmd: String) {
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessage([WatchMessage.command: cmd], replyHandler: nil, errorHandler: nil)
        WKInterfaceDevice.current().play(.start)
    }

    private func apply(_ d: [String: Any]) {
        if let r = d[WatchMessage.running] as? Bool { running = r }
        if let s = d[WatchMessage.startedAt] as? TimeInterval { startedAt = Date(timeIntervalSince1970: s) } else if !running { startedAt = nil }
        if let v = d[WatchMessage.streets] as? Int { streets = v }
        if let v = d[WatchMessage.pellets] as? Int { pellets = v }
        if let v = d[WatchMessage.distance] as? Double { distance = v }
        if let v = d[WatchMessage.colorHex] as? String { colorHex = v }
        if let f = d[WatchMessage.frenzyEndsAt] as? TimeInterval {
            let new = f > 0 ? Date(timeIntervalSince1970: f) : nil
            if new != nil, new != frenzyEndsAt { WKInterfaceDevice.current().play(.notification) }
            frenzyEndsAt = new
        }
        if let name = d[WatchMessage.capture] as? String {
            lastCapture = name
            WKInterfaceDevice.current().play(.success)
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let ctx = session.receivedApplicationContext
        let reach = session.isReachable
        Task { @MainActor in self.reachable = reach; self.apply(ctx) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reach = session.isReachable
        Task { @MainActor in self.reachable = reach }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let box = MessageBox(message)
        Task { @MainActor in self.apply(box.value) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let box = MessageBox(applicationContext)
        Task { @MainActor in self.apply(box.value) }
    }
}

/// WatchConnectivity dictionaries are property-list values; safe to hop actors.
struct MessageBox: @unchecked Sendable {
    let value: [String: Any]
    init(_ v: [String: Any]) { value = v }
}

struct WatchRunView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        let c = Color(hex: model.colorHex)
        ScrollView {
            VStack(spacing: 8) {
                if model.running, let s = model.startedAt {
                    Text(s, style: .timer).font(.system(size: 34, weight: .black, design: .rounded)).monospacedDigit()
                } else {
                    Text("CHOMP").font(.system(size: 26, weight: .black, design: .rounded)).foregroundStyle(c)
                }
                HStack {
                    if model.running {
                        stat("\(model.pellets)", "coins", Color(hex: "FFF1C1"))
                        stat("\(model.streets)", "stolen", c)
                    } else {
                        stat("\(model.streets)", "coins", Color(hex: "FFF1C1"))
                    }
                }
                if let f = model.frenzyEndsAt, f > .now {
                    HStack { Image(systemName: "bolt.fill"); Text(timerInterval: Date.now...f, countsDown: true).monospacedDigit() }
                        .font(.headline.weight(.black)).foregroundStyle(Color(hex: "FF2BD6"))
                        .accessibilityLabel("Frenzy active")
                }
                if let last = model.lastCapture, model.running {
                    Text("Ate \(last)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Button(model.running ? "Finish" : "Start run") { model.send(model.running ? "stop" : "start") }
                    .buttonStyle(.borderedProminent)
                    .tint(model.running ? Color(hex: "FF3355") : c)
                    .disabled(!model.reachable)
                if !model.reachable {
                    Text("Open Chomp on your iPhone").font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
        }
    }

    private func stat(_ v: String, _ l: String, _ c: Color) -> some View {
        VStack(spacing: 0) {
            Text(v).font(.title2.weight(.black)).foregroundStyle(c)
            Text(l).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
