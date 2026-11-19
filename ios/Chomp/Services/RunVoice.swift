import AVFoundation
import ChompKit
import Foundation

/// Spoken updates during a run, for runners with headphones who don't look at
/// their phone: captures (batched), steals, frenzy, and a split every kilometre
/// or mile. Other audio is ducked while it speaks (the system handles that,
/// because the synthesizer uses its own audio session).
@MainActor
final class RunVoice {
    static let shared = RunVoice()

    private let synth = AVSpeechSynthesizer()
    private var pendingStreets: [String] = []
    private var pendingTokens = 0
    private var pendingStolen = 0
    private var flushTask: Task<Void, Never>?

    var enabled = false
    var splits = true

    private init() {
        synth.usesApplicationAudioSession = false
    }

    func say(_ text: String) {
        guard enabled else { return }
        let u = AVSpeechUtterance(string: text)
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        synth.speak(u)
    }

    /// Coins collected within a few seconds of each other become one sentence.
    func captured(street: String, tokens: Int, stolen: Int) {
        guard enabled else { return }
        pendingStreets.append(street)
        pendingTokens += tokens
        pendingStolen += stolen
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    private func flush() {
        defer { pendingStreets = []; pendingTokens = 0; pendingStolen = 0 }
        guard !pendingStreets.isEmpty else { return }
        var line = "\(coinCount(pendingTokens))"
        if Set(pendingStreets).count == 1, !pendingStreets[0].isEmpty { line += " on \(pendingStreets[0])" }
        line += "."
        if pendingStolen > 0 { line += pendingStolen == pendingTokens ? " All stolen from rivals." : " \(pendingStolen) stolen from rivals." }
        say(line)
    }

    func split(index: Int, miles: Bool, paceSecondsPerUnit: Double, coins: Int) {
        guard enabled, splits else { return }
        let unit = miles ? (index == 1 ? "mile" : "miles") : (index == 1 ? "kilometre" : "kilometres")
        var line = "\(index) \(unit)."
        if paceSecondsPerUnit > 0 {
            let m = Int(paceSecondsPerUnit) / 60, s = Int(paceSecondsPerUnit) % 60
            line += " Pace \(m) \(s == 0 ? "flat" : String(format: "%02d", s))."
        }
        if coins > 0 { line += " \(coinCount(coins)) so far." }
        say(line)
    }

    func stop() {
        flushTask?.cancel()
        flush()
    }

    func reset() {
        flushTask?.cancel()
        pendingStreets = []; pendingTokens = 0; pendingStolen = 0
        synth.stopSpeaking(at: .word)
    }
}
