import AuthenticationServices
import SwiftUI

/// Sign in (or create an account) with Apple or with a one-time code sent by
/// email. Used at the end of onboarding and in Settings.
struct AccountSignInView: View {
    @Environment(AppModel.self) private var model
    /// Runner name and colour for a new profile.
    let name: String
    let colorHex: String
    /// Onboarding's dark, full-width look; Settings uses the system look.
    var prominent = false
    var onSignedIn: () -> Void = {}
    /// Someone else has this runner name. nil shows the error here instead.
    var onNameTaken: (() -> Void)? = nil

    @State private var nonce = ""
    @State private var email = ""
    @State private var code = ""
    @State private var codeSentTo: String?
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focus: Field?
    private enum Field { case email, code }

    var body: some View {
        VStack(spacing: 14) {
            SignInWithAppleButton(.continue) { req in
                nonce = Nonce.random()
                req.requestedScopes = [.email]
                req.nonce = Nonce.sha256(nonce)
            } onCompletion: { result in
                switch result {
                case .success(let auth):
                    guard let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                          let data = cred.identityToken, let token = String(data: data, encoding: .utf8) else {
                        error = "Apple didn't send a sign-in token. Try again."
                        return
                    }
                    run { try await model.backend.signInWithApple(idToken: token, nonce: nonce, displayName: name, colorHex: colorHex) }
                case .failure(let e):
                    if (e as? ASAuthorizationError)?.code != .canceled { error = e.localizedDescription }
                }
            }
            .signInWithAppleButtonStyle(prominent ? .white : .black)
            .frame(height: prominent ? 56 : 48)
            .clipShape(RoundedRectangle(cornerRadius: prominent ? 16 : 10))
            .disabled(busy)

            HStack {
                line
                Text("or").font(.footnote.weight(.semibold)).foregroundStyle(secondary)
                line
            }

            if let sentTo = codeSentTo {
                Text("We emailed a code to \(sentTo).").font(.subheadline).foregroundStyle(secondary)
                    .multilineTextAlignment(.center)
                field("Code from the email", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($focus, equals: .code)
                    .onChange(of: code) { _, v in code = String(v.filter(\.isNumber).prefix(8)) }
                action(busy ? "Signing in…" : "Sign in", enabled: code.count >= 6 && !busy) { verify() }
                Button("Use a different email") { codeSentTo = nil; code = ""; error = nil; focus = .email }
                    .font(.footnote.weight(.semibold)).foregroundStyle(secondary)
                    .buttonStyle(.borderless)
            } else {
                field("Email address", text: $email)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.send)
                    .focused($focus, equals: .email)
                    .onSubmit { if emailValid { sendCode() } }
                action(busy ? "Sending…" : "Continue with email", enabled: emailValid && !busy) { sendCode() }
            }

            if let error {
                Text(error).font(.footnote.weight(.semibold)).foregroundStyle(Theme.danger).multilineTextAlignment(.center)
            }
        }
    }

    private var secondary: Color { prominent ? Theme.hudSecondary : Theme.textSecondary }
    private var line: some View { Rectangle().fill(secondary.opacity(0.4)).frame(height: 1) }

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    private var emailValid: Bool {
        let e = trimmedEmail
        guard let at = e.firstIndex(of: "@") else { return false }
        return e.distance(from: e.startIndex, to: at) > 0 && e[at...].contains(".") && !e.contains(" ")
    }

    @ViewBuilder private func field(_ title: String, text: Binding<String>) -> some View {
        if prominent {
            TextField(title, text: text)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(16)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 16))
        } else {
            TextField(title, text: text)
        }
    }

    @ViewBuilder private func action(_ title: String, enabled: Bool, _ perform: @escaping () -> Void) -> some View {
        if prominent {
            Button(action: perform) { Text(title) }
                .buttonStyle(ChunkyButtonStyle(colorHex: colorHex, height: 56))
                .disabled(!enabled).grayscale(enabled ? 0 : 1).brightness(enabled ? 0 : -0.3)
        } else {
            Button(title, action: perform).disabled(!enabled).buttonStyle(.borderless)
        }
    }

    private func sendCode() {
        let e = trimmedEmail
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                try await model.backend.sendEmailCode(to: e)
                codeSentTo = e
                focus = .code
            } catch {
                self.error = "Couldn't send the code: \(error.localizedDescription)"
            }
        }
    }

    private func verify() {
        let e = codeSentTo ?? trimmedEmail, c = code
        run { try await model.backend.verifyEmailCode(email: e, code: c, displayName: name, colorHex: colorHex) }
    }

    /// Signs in, then brings the account up to date (Pro, streets, profile).
    private func run(_ signIn: @escaping () async throws -> Void) {
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                try await signIn()
                await model.didSignIn()
                onSignedIn()
            } catch BackendError.nameTaken {
                if let onNameTaken { onNameTaken() } else { error = BackendError.nameTaken.localizedDescription }
            } catch {
                self.error = Self.friendly(error)
            }
        }
    }

    static func friendly(_ error: Error) -> String {
        let text = error.localizedDescription
        if text.localizedCaseInsensitiveContains("expired") || text.localizedCaseInsensitiveContains("invalid") {
            return "That code didn't work. Check it, or ask for a new one."
        }
        return text
    }
}
