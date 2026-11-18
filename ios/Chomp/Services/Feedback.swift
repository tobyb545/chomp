import AVFoundation
import UIKit

/// Haptics + procedurally synthesised sounds. All sounds are generated in code
/// (original, no samples), and mix with the runner's own music.
@MainActor
final class Feedback {
    static let shared = Feedback()

    var soundOn = true
    var hapticsOn = true

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var started = false
    private var cache: [Cue: AVAudioPCMBuffer] = [:]

    enum Cue: Hashable { case pellet, steal, block, powerUp, frenzyEnd, start, finish }

    private init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.55
    }

    private func ensureStarted() {
        guard !started else { return }
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.ambient, options: [.mixWithOthers])
        try? s.setActive(true)
        do { try engine.start(); player.play(); started = true } catch { started = false }
    }

    func play(_ cue: Cue) {
        if hapticsOn { haptic(cue) }
        guard soundOn else { return }
        ensureStarted()
        guard started else { return }
        let buf = cache[cue] ?? render(cue)
        cache[cue] = buf
        player.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil)
    }

    private func haptic(_ cue: Cue) {
        switch cue {
        case .pellet:
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.8)
        case .steal:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .block, .powerUp:
            let g = UIImpactFeedbackGenerator(style: .heavy)
            g.impactOccurred()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120)); g.impactOccurred(intensity: 0.7)
                try? await Task.sleep(for: .milliseconds(120)); g.impactOccurred(intensity: 1)
            }
        case .frenzyEnd:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .start, .finish:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    /// Tone recipe: (start Hz, end Hz, seconds, waveform)
    private func render(_ cue: Cue) -> AVAudioPCMBuffer {
        let notes: [(Double, Double, Double, Wave)]
        switch cue {
        case .pellet: notes = [(880, 1320, 0.05, .triangle), (1320, 990, 0.06, .triangle)]
        case .steal: notes = [(523, 523, 0.07, .square), (659, 659, 0.07, .square), (784, 1046, 0.12, .square)]
        case .block: notes = [(392, 392, 0.08, .triangle), (523, 523, 0.08, .triangle), (659, 659, 0.08, .triangle), (1046, 1046, 0.2, .triangle)]
        case .powerUp: notes = [(220, 1760, 0.45, .square)]
        case .frenzyEnd: notes = [(880, 220, 0.35, .triangle)]
        case .start: notes = [(440, 440, 0.08, .sine), (880, 880, 0.12, .sine)]
        case .finish: notes = [(784, 784, 0.1, .sine), (659, 659, 0.1, .sine), (1046, 1046, 0.25, .sine)]
        }
        let sr = format.sampleRate
        let total = notes.reduce(0) { $0 + $1.2 }
        let frames = AVAudioFrameCount(total * sr)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        let out = buf.floatChannelData![0]
        var i = 0
        var phase = 0.0
        for (f0, f1, dur, wave) in notes {
            let n = Int(dur * sr)
            for k in 0..<n where i < Int(frames) {
                let t = Double(k) / Double(n)
                let f = f0 * pow(f1 / f0, t)
                phase += f / sr
                let env = min(1, t * 20) * pow(1 - t, 1.6)
                out[i] = Float(wave.sample(phase) * env * 0.35)
                i += 1
            }
        }
        return buf
    }

    enum Wave {
        case sine, square, triangle
        func sample(_ p: Double) -> Double {
            let x = p - floor(p)
            switch self {
            case .sine: return sin(2 * .pi * x)
            case .square: return x < 0.5 ? 0.6 : -0.6
            case .triangle: return 4 * abs(x - 0.5) - 1
            }
        }
    }
}
