import CoreLocation
import SwiftUI

/// Quick steps: colour → name → location → account → first run.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step = 0
    @State private var colorHex = PlayerPalette.swatches[0].hex
    @State private var name = ""
    @State private var nameTaken = false
    @State private var checkingName = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        ZStack {
            Color(hex: "07070E").ignoresSafeArea()
            PelletField(colorHex: colorHex).ignoresSafeArea().opacity(0.6).accessibilityHidden(true)
            VStack(spacing: 24) {
                ProgressDots(step: step, count: 5, colorHex: colorHex)
                Spacer()
                Group {
                    switch step {
                    case 0: colourStep
                    case 1: nameStep
                    case 2: locationStep
                    case 3: accountStep
                    default: readyStep
                    }
                }
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                Spacer()
            }
            .padding(24)
            .animation(.spring(duration: 0.35), value: step)
        }
        .environment(\.colorScheme, .dark)
    }

    private var colourStep: some View {
        VStack(spacing: 22) {
            Text("CHOMP").font(.system(size: 54, weight: .black, design: .rounded)).foregroundStyle(Color(hex: colorHex))
                .shadow(color: Color(hex: colorHex).opacity(0.7), radius: 14)
                .accessibilityAddTraits(.isHeader)
            Text("Run a street to collect its coins and paint it your colour.\nPick yours.")
                .font(.title3.weight(.semibold)).multilineTextAlignment(.center).foregroundStyle(Theme.hudSecondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 14) {
                ForEach(PlayerPalette.swatches) { s in
                    Button { colorHex = s.hex; Feedback.shared.play(.pellet) } label: {
                        Circle().fill(Color(hex: s.hex))
                            .frame(height: 62)
                            .overlay(Circle().strokeBorder(.white, lineWidth: colorHex == s.hex ? 4 : 0))
                            .shadow(color: Color(hex: s.hex).opacity(0.7), radius: colorHex == s.hex ? 12 : 0)
                    }
                    .accessibilityLabel(s.name)
                    .accessibilityAddTraits(colorHex == s.hex ? .isSelected : [])
                }
            }
            next("That's me") { step = 1; nameFocused = true }
        }
    }

    private var nameStep: some View {
        VStack(spacing: 22) {
            Text("What should rivals call you?").font(Theme.display(.title)).multilineTextAlignment(.center).foregroundStyle(.white)
            TextField("Runner name", text: $name)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .focused($nameFocused)
                .padding(18)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 18))
                .onSubmit { if valid { confirmName() } }
                .onChange(of: name) { _, v in
                    if v.count > 20 { name = String(v.prefix(20)) }
                    nameTaken = false
                }
            if nameTaken {
                Text("Someone already uses that name. Try another.").font(.footnote.weight(.semibold)).foregroundStyle(Theme.danger)
            } else {
                Text("Shown on leaderboards. You can play fully private later.").font(.footnote).foregroundStyle(Theme.hudSecondary)
            }
            next(checkingName ? "Checking…" : "Next") { confirmName() }
                .disabled(!valid || checkingName).grayscale(valid ? 0 : 1).brightness(valid ? 0 : -0.3)
        }
    }

    private var valid: Bool { name.trimmingCharacters(in: .whitespaces).count >= 2 && !nameTaken }

    /// Names are unique online. If the check can't run (offline), carry on: sign-in checks again.
    private func confirmName() {
        checkingName = true
        Task {
            let ok = await model.backend.nameAvailable(name.trimmingCharacters(in: .whitespaces))
            checkingName = false
            if ok == false { nameTaken = true } else { step = 2 }
        }
    }

    private var locationStep: some View {
        VStack(spacing: 18) {
            Image(systemName: "location.circle.fill").font(.system(size: 64)).foregroundStyle(Color(hex: colorHex))
                .accessibilityHidden(true)
            Text("Location while you run").font(Theme.display(.title)).foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 10) {
                bullet("map.fill", "To load the streets around you. Chomp works anywhere in the world.")
                bullet("figure.run", "While a run is recording, to see which streets you cover.")
                bullet("eye.slash.fill", "Rivals never see where you are. They only see which streets you own.")
                bullet("house.fill", "Add privacy zones to hide where your runs start and end.")
            }
            next("Allow while using") {
                Task {
                    _ = await LocationPermission.shared.requestWhenInUse()
                    toAccount()
                    // Start on the streets now: a new area can take a minute to download.
                    await model.locateAndLoad()
                }
            }
            Button("Not now") { toAccount() }.foregroundStyle(Theme.hudSecondary)
        }
    }

    /// The account step, unless online play isn't set up in this build or the
    /// player is already signed in.
    private func toAccount() {
        // Sign-in syncs the profile, so it needs the name and colour now.
        model.profile.name = name.trimmingCharacters(in: .whitespaces)
        model.profile.colorHex = colorHex
        step = model.backend.isConfigured && !model.backend.isSignedIn ? 3 : 4
    }

    private var accountStep: some View {
        VStack(spacing: 18) {
            Text("Save your streets").font(Theme.display(.title)).foregroundStyle(.white)
            Text("Create an account to appear on leaderboards, steal rivals' streets and join clubs. Your runs stay safe if you change phone.")
                .font(.body.weight(.medium)).multilineTextAlignment(.center).foregroundStyle(Theme.hudSecondary)
            AccountSignInView(name: name.trimmingCharacters(in: .whitespaces), colorHex: colorHex, prominent: true,
                              onSignedIn: { step = 4 },
                              onNameTaken: { nameTaken = true; step = 1; nameFocused = true })
            Button("Not now") { step = 4 }
                .font(.body.weight(.semibold)).foregroundStyle(Theme.hudSecondary)
        }
    }

    private var readyStep: some View {
        VStack(spacing: 18) {
            Text("Ready, \(name.trimmingCharacters(in: .whitespaces))").font(Theme.display(.title)).foregroundStyle(.white)
            Text("Every street is covered in coins, and rivals are already out there. Go and grab some streets.")
                .font(.title3.weight(.semibold)).multilineTextAlignment(.center).foregroundStyle(Theme.hudSecondary)
            next("Try a practice run") { model.wantsPractice = true; finish() }
            Button("Skip, show me the map") { finish() }
                .font(.body.weight(.semibold)).foregroundStyle(Theme.hudSecondary)
        }
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).frame(width: 26).foregroundStyle(Color(hex: colorHex))
            Text(text).font(.body.weight(.medium)).foregroundStyle(Theme.hudText)
        }
        .accessibilityElement(children: .combine)
    }

    private func next(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title) }
            .buttonStyle(ChunkyButtonStyle(colorHex: colorHex, height: 64))
    }

    private func finish() {
        var p = model.profile
        p.name = name.trimmingCharacters(in: .whitespaces)
        p.colorHex = colorHex
        p.onboarded = true
        model.profile = p
        Task {
            await model.locateAndLoad()
            if await NotificationService.requestPermission() { await PushService.shared.refresh() }
        }
    }
}

private struct ProgressDots: View {
    let step: Int
    let count: Int
    let colorHex: String
    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { i in
                Capsule().fill(i <= step ? Color(hex: colorHex) : .white.opacity(0.2)).frame(width: i == step ? 26 : 10, height: 10)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(step + 1) of \(count)")
    }
}

/// Decorative drifting pellets behind onboarding.
private struct PelletField: View {
    let colorHex: String
    var body: some View {
        TimelineView(.animation) { t in
            Canvas { ctx, size in
                let time = t.date.timeIntervalSinceReferenceDate
                let spacing: CGFloat = 34
                let rows = Int(size.height / spacing) + 2
                for r in 0..<rows {
                    let y = CGFloat(r) * spacing
                    let shift = CGFloat((time * 18).truncatingRemainder(dividingBy: Double(spacing)))
                    var x: CGFloat = (r % 2 == 0 ? shift : -shift) - spacing
                    while x < size.width + spacing {
                        let rect = CGRect(x: x, y: y, width: 6, height: 6)
                        ctx.fill(Path(ellipseIn: rect), with: .color(r % 7 == 3 ? Color(hex: colorHex) : Color(hex: "FFF1C1").opacity(0.35)))
                        x += spacing
                    }
                }
            }
        }
    }
}
