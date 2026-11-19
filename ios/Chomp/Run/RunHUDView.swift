import SwiftUI
import ChompKit

struct RunHUDView: View {
    @Environment(AppModel.self) private var model
    @Binding var follow: Bool
    @State private var holdProgress: CGFloat = 0
    @State private var confirmDiscard = false

    var body: some View {
        let run = model.run
        VStack(spacing: 10) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HUDPanel {
                    VStack(spacing: 12) {
                        HStack {
                            if run.practice { Chip(text: "Practice", colorHex: "38E8FF") }
                            else if run.simulated, !AppModel.marketing { Chip(text: "Simulated", colorHex: "8B5CFF") }
                            if run.phase == .paused { Chip(text: "Paused", colorHex: "FFD600") }
                            Spacer()
                            Text(RunMath.formatDuration(run.elapsed))
                                .font(Theme.number(.largeTitle)).foregroundStyle(Theme.hudText)
                                .accessibilityLabel("Time \(RunMath.formatDuration(run.elapsed))")
                            Spacer()
                            if run.simulated || run.phase == .paused { Color.clear.frame(width: 60, height: 1) }
                        }
                        HStack {
                            StatTile(value: formatDistance(run.distance, miles: model.profile.useMiles), label: "Distance")
                            StatTile(value: RunMath.formatPace(run.paceSecondsPerKm), label: "Pace /km")
                            StatTile(value: "\(run.streetsCaptured)", label: "Streets", tint: Color(hex: model.profile.colorHex))
                            StatTile(value: "\(run.pelletsEaten)", label: "Tokens", tint: Theme.pellet)
                        }
                        if run.isFrenzy, let end = run.frenzyEndsAt {
                            HStack {
                                Image(systemName: "bolt.fill")
                                Text("FRENZY 2×")
                                Spacer()
                                Text(timerInterval: Date.now...end, countsDown: true).monospacedDigit()
                            }
                            .font(Theme.display(.headline))
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(Theme.power, in: RoundedRectangle(cornerRadius: 14))
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Frenzy active. Rival streets flip instantly.")
                        }
                        if let last = run.lastEatenName {
                            Text("Ate \(last)\(run.streetsStolen > 0 ? " · \(run.streetsStolen) stolen back" : "")")
                                .font(.footnote.weight(.semibold)).foregroundStyle(Theme.hudSecondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(.top, 4)

            Spacer()

            HStack(spacing: 10) {
                if !follow {
                    RoundIconButton(symbol: "location.north.line.fill", label: "Follow me") { follow = true }
                }
                Spacer()
                RoundIconButton(symbol: model.profile.voiceOn ? "speaker.wave.2.fill" : "speaker.slash.fill",
                                label: model.profile.voiceOn ? "Turn off spoken updates" : "Turn on spoken updates") {
                    model.profile.voiceOn.toggle()
                    RunVoice.shared.enabled = model.profile.voiceOn
                    RunVoice.shared.say("Spoken updates on.")
                }
                RoundIconButton(symbol: "xmark", label: "Discard run") { confirmDiscard = true }
            }

            HStack(spacing: 12) {
                Button {
                    run.phase == .paused ? run.resume() : run.pause()
                } label: {
                    Image(systemName: run.phase == .paused ? "play.fill" : "pause.fill")
                        .font(.title.weight(.black))
                        .frame(width: 76, height: 76)
                }
                .buttonStyle(ChunkyButtonStyle(colorHex: "2A2A4A", height: 76))
                .frame(width: 92)
                .accessibilityLabel(run.phase == .paused ? "Resume" : "Pause")

                finishButton
            }
        }
        .confirmationDialog("Discard this run?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { model.run.discard() }
        } message: {
            Text("Nothing from this run will be saved or counted.")
        }
    }

    /// Press and hold to finish, so a bump in the pocket can't end the run.
    private var finishButton: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 29, style: .continuous).fill(Theme.danger)
            RoundedRectangle(cornerRadius: 29, style: .continuous).fill(.white.opacity(0.3))
                .frame(maxWidth: .infinity, alignment: .leading)
                .scaleEffect(x: holdProgress, y: 1, anchor: .leading)
            Text(model.run.phase == .finishing ? "SAVING…" : "HOLD TO FINISH")
                .font(Theme.display(.title3)).foregroundStyle(.white)
                .frame(maxWidth: .infinity)
        }
        .frame(height: 76)
        .clipShape(RoundedRectangle(cornerRadius: 29, style: .continuous))
        .onLongPressGesture(minimumDuration: 0.9, maximumDistance: 40) {
            holdProgress = 0
            Task { await model.run.finish() }
        } onPressingChanged: { pressing in
            withAnimation(pressing ? .linear(duration: 0.9) : .easeOut(duration: 0.2)) { holdProgress = pressing ? 1 : 0 }
        }
        .accessibilityElement()
        .accessibilityLabel("Finish run")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { Task { await model.run.finish() } }
    }
}
