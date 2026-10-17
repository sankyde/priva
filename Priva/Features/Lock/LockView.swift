import LocalAuthentication
import SwiftUI

struct LockView: View {
    @Environment(AppModel.self) private var model
    enum Stage: Equatable { case biometric, password, unlocking }
    @State private var stage: Stage = .biometric
    @State private var password = ""
    @State private var context: SendableBox<LAContext>?
    @State private var error: String?
    @State private var shakes = 0
    @State private var showReset = false
    @State private var now = Date()
    @State private var authenticating = false
    /// When this Face ID approval was given. It doesn't last: on an iPhone it stopped unlocking the Secure Enclave
    /// key ≈ 15–18 min later (FID-08, through the waits after wrong passwords), so an old one is renewed first.
    @State private var verifiedAt: Date?
    @FocusState private var focused: Bool

    static let approvalLifetime: TimeInterval = 300

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 18) {
                PrivaMark()
                    .frame(width: 96, height: 96)
                    .shadow(color: Theme.violet.opacity(0.4), radius: 30)
                Text("Priva is locked").font(.screenTitle).foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                if let name = Vault.meta?.username {
                    Text("@\(name)").font(.headline).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer().frame(height: 40)
            Group {
                switch stage {
                case .biometric:
                    VStack(spacing: 14) {
                        Button { Task { await authenticate() } } label: {
                            Image(systemName: BiometricGate.kind == .touchID ? "touchid" : "faceid")
                                .font(.system(size: 54, weight: .light))
                                .foregroundStyle(Theme.aurora)
                                .frame(width: 104, height: 104)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 30))
                        .accessibilityLabel("Unlock with \(BiometricGate.kind.rawValue)")
                        Text(BiometricGate.kind.rawValue).font(.footnote.weight(.medium)).foregroundStyle(Theme.textSecondary)
                    }
                    .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .leading).combined(with: .opacity)))
                case .password, .unlocking:
                    VStack(spacing: 14) {
                        Label("\(BiometricGate.kind.rawValue) verified", systemImage: "checkmark.seal.fill")
                            .font(.footnote.weight(.semibold)).foregroundStyle(Theme.mint)
                            .accessibilityIdentifier("lock.verified")
                        PasswordField(title: "Password", text: $password, focused: $focused) { Task { await unlock() } }
                            .shake(shakes)
                            #if DEBUG
                            .onAppear { if let pw = DebugAutomation.testPassword, password.isEmpty { password = pw } }
                            #endif
                        PrimaryButton(title: "Unlock", systemImage: "lock.open.fill", loading: stage == .unlocking, enabled: !password.isEmpty && lockout == nil) {
                            Task { await unlock() }
                        }
                    }
                    .padding(.horizontal, Theme.gutter)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                }
            }
            .animation(Theme.snappy, value: stage)
            VStack(spacing: 6) {
                if let lockout {
                    Text("Too many attempts. Try again in \(Self.wait(lockout.timeIntervalSince(now)))")
                        .font(.footnote.weight(.semibold)).foregroundStyle(Theme.amber)
                } else if let error {
                    Text(error).font(.footnote.weight(.semibold)).foregroundStyle(Theme.rose).multilineTextAlignment(.center)
                        .accessibilityIdentifier("lock.error")
                }
            }
            .frame(minHeight: 44)
            .padding(.horizontal)
            Spacer()
            Button("Forgot password?") { showReset = true }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(minHeight: 44)
                .padding(.bottom, 8)
        }
        .background(Theme.background.ignoresSafeArea())
        .task { await authenticate() }
        .onReceive(timer) { now = $0 }
        .onChange(of: model.lockEpoch) {
            // Back from the background: Face ID again. An unlock already running is left to finish.
            guard stage != .unlocking else { return }
            context?.value.invalidate()
            context = nil
            verifiedAt = nil
            password = ""
            error = nil
            stage = .biometric
            if !showReset { Task { await authenticate() } }
        }
        .sheet(isPresented: $showReset) { RecoveryResetView() }
        .sensoryFeedback(.error, trigger: shakes)
    }

    /// With "Erase after 10 tries" on, it warns from the 5th wrong password how many are left.
    static func wrongPassword() -> String {
        let n = Vault.failedAttempts
        if Vault.meta?.wipeAfterFailures == true, n >= 5 {
            let left = max(0, 10 - n)
            return "Wrong password. \(left) \(left == 1 ? "try" : "tries") left before Priva erases this iPhone."
        }
        return n >= 3 ? "Wrong password · \(n) failed attempts" : "Wrong password"
    }

    /// "45 s", "15 min", "1 h".
    static func wait(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        if s < 60 { return "\(max(1, s)) s" }
        if s < 3600 { return "\((s + 59) / 60) min" }
        return "1 h"
    }

    private var lockout: Date? {
        _ = now
        return Vault.lockoutUntil()
    }

    private func authenticate() async {
        // One Face ID prompt at a time, however often the button is tapped.
        guard stage == .biometric, !authenticating else { return }
        authenticating = true
        defer { authenticating = false }
        error = nil
        do {
            let ctx = try await BiometricGate.authenticate(reason: "Unlock Priva")
            context = SendableBox(ctx)
            verifiedAt = .now
            withAnimation(Theme.snappy) { stage = .password }
            try? await Task.sleep(for: .milliseconds(250))
            focused = true
        } catch BiometricGate.Failure.unavailable {
            error = BiometricGate.unavailableMessage()
        } catch BiometricGate.Failure.cancelled {
        } catch {
            self.error = "\(BiometricGate.kind.rawValue) didn't match."
        }
    }

    /// Face ID again, keeping what was typed. True when the new approval is in hand.
    private func renewFaceID() async -> Bool {
        context?.value.invalidate()
        context = nil
        verifiedAt = nil
        withAnimation(Theme.snappy) { stage = .biometric }
        await authenticate()
        return stage == .password && context != nil
    }

    private func unlock() async {
        guard context != nil, !password.isEmpty, stage == .password else { return }
        if let t = verifiedAt, Date().timeIntervalSince(t) > Self.approvalLifetime {
            guard await renewFaceID() else { return }
        }
        guard let context else { return }
        stage = .unlocking
        let pw = password
        let result: Result<UnlockedVault, Error> = await Task.detached(priority: .userInitiated) {
            Result { try Vault.unlock(password: pw, context: context.value) }
        }.value
        switch result {
        case .success(let v):
            password = ""
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            // An unfinished sign-up may show the recovery phrase again, whose "save as file" needs the password.
            if !v.registered { model.onboarding.password = pw }
            if !model.didUnlock(v) { stage = .password; error = AppModel.storeOpenFailed }
        case .failure(let e):
            stage = .password
            password = ""
            withAnimation(.linear(duration: 0.4)) { shakes += 1 }
            switch e as? Vault.Failure {
            case .wrongPassword?:
                error = Self.wrongPassword()
            case .lockedOut?: error = nil
            case .wiped?: model.wipe()
            case .biometric(.invalidated)? where verifiedAt.map({ Date().timeIntervalSince($0) > 60 }) ?? true:
                // An approval that lapsed, not a changed Face ID: ask again and try the same password (once: the
                // new approval is fresh, so a second refusal means Face ID really changed).
                password = pw
                if await renewFaceID() { await unlock() }
                return
            case .biometric(.invalidated)?:
                error = "\(BiometricGate.kind.rawValue) changed. Reset with your recovery phrase."
                stage = .biometric
            default: error = "Couldn't unlock."
            }
            focused = true
        }
    }
}

/// Forgot-password flow: 24-word phrase + new password + fresh biometric enrolment.
struct RecoveryResetView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var phrase = ""
    @State private var pw = ""
    @State private var confirm = ""
    @State private var error: String?
    @State private var busy = false
    @State private var importing = false
    @FocusState private var f1: Bool
    @FocusState private var f2: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Enter your recovery phrase, then choose a new password.")
                        .foregroundStyle(Theme.textSecondary)
                    PhraseInput(text: $phrase)
                    // Opening a key file takes the password it was saved with: this helps when Face ID changed,
                    // not when the password is forgotten.
                    OpenKeyFileButton(kind: .recovery) { importing = true }
                    Text("The file needs the password you saved it with.").font(.caption).foregroundStyle(Theme.textTertiary)
                    PasswordField(title: "New password", text: $pw, focused: $f1) { f2 = true }
                    if !pw.isEmpty { StrengthMeter(assessment: PasswordPolicy.assess(pw)) }
                    PasswordField(title: "Confirm new password", text: $confirm, focused: $f2)
                    if let error { Text(error).font(.footnote.weight(.semibold)).foregroundStyle(Theme.rose) }
                    PrimaryButton(title: "Reset password", loading: busy,
                                  enabled: PhraseInput.words(phrase).count == 24 && PasswordPolicy.assess(pw).acceptable && pw == confirm) {
                        Task { await reset() }
                    }
                }
                .padding(Theme.gutter)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Reset password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", systemImage: "xmark") { dismiss() } } }
            .keyFileImporter(isPresented: $importing, kind: .recovery) { seed in
                error = nil
                phrase = RecoveryPhrase.encode(seed).joined(separator: " ")
            }
        }
    }

    private func reset() async {
        busy = true
        defer { busy = false }
        error = nil
        do {
            let seed = try RecoveryPhrase.decode(phrase)
            let ctx = SendableBox(try await BiometricGate.authenticate(reason: "Confirm your new Priva password"))
            let newPassword = pw
            let v = try await Task.detached(priority: .userInitiated) {
                try Vault.resetPassword(seed: seed, newPassword: newPassword, context: ctx.value)
            }.value
            guard model.didUnlock(v) else { error = AppModel.storeOpenFailed; return }
            dismiss()
        } catch Vault.Failure.wrongPhrase {
            error = "That recovery phrase doesn't match this account."
        } catch is RecoveryPhrase.Failure {
            error = "Check the words: the phrase isn't valid."
        } catch BiometricGate.Failure.cancelled {
        } catch {
            self.error = "Couldn't reset the password."
        }
    }
}

/// Shown after a reinstall when this iPhone still holds the previous vault (identity v2 §6).
struct WelcomeBackView: View {
    @Environment(AppModel.self) private var model
    @State private var stage = 0
    @State private var password = ""
    @State private var context: SendableBox<LAContext>?
    @State private var busy = false
    @State private var error: String?
    @State private var confirmFresh = false
    @State private var restoring = false
    @State private var verifiedAt: Date?
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                PrivaMark().frame(width: 92, height: 92).shadow(color: Theme.violet.opacity(0.4), radius: 30).padding(.top, 36)
                Text("Welcome back").font(.screenTitle)
                Text("Restore a backup to keep your chats, or sign back in with a new username.")
                    .font(.body).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                if stage == 0 {
                    SecondaryButton(title: "Restore a backup", systemImage: "arrow.counterclockwise.icloud") { restoring = true }
                }
                if stage == 0 {
                    PrimaryButton(title: "Unlock with \(BiometricGate.kind.rawValue)", systemImage: BiometricGate.kind == .touchID ? "touchid" : "faceid") {
                        Task { await authenticate() }
                    }
                } else {
                    PasswordField(title: "Password of your previous account", text: $password, focused: $focused) { Task { await unlock() } }
                    PrimaryButton(title: "Sign back in", systemImage: "arrow.right", loading: busy, enabled: !password.isEmpty) { Task { await unlock() } }
                }
                if let error { Text(error).font(.footnote.weight(.semibold)).foregroundStyle(Theme.rose).multilineTextAlignment(.center) }
                Button("Use my recovery phrase instead") {
                    model.onboarding.reset()
                    model.onboarding.path = [.signBackIn]
                    model.phase = .onboarding
                }
                .font(.subheadline.weight(.semibold))
                Button("Start fresh without notifying anyone", role: .destructive) { confirmFresh = true }
                    .font(.subheadline)
                    .padding(.bottom, 20)
            }
            .padding(.horizontal, Theme.gutter)
        }
        .background(Theme.background.ignoresSafeArea())
        .animation(Theme.snappy, value: stage)
        .onChange(of: model.lockEpoch) {
            guard !busy else { return }
            context?.value.invalidate()
            context = nil
            password = ""
            stage = 0
        }
        .sheet(isPresented: $restoring) { BackupRestoreView(mode: .onboarding) }
        .confirmationDialog("Start fresh?", isPresented: $confirmFresh, titleVisibility: .visible) {
            Button("Start fresh", role: .destructive) { model.startFresh() }
        } message: {
            Text("Your old username will be removed. Friends won't get your new one.")
        }
    }

    private func authenticate() async {
        error = nil
        do {
            context = SendableBox(try await BiometricGate.authenticate(reason: "Unlock your previous Priva identity"))
            verifiedAt = .now
            stage = 1
            try? await Task.sleep(for: .milliseconds(200))
            focused = true
        } catch BiometricGate.Failure.unavailable {
            error = BiometricGate.unavailableMessage()
        } catch BiometricGate.Failure.cancelled {
        } catch {
            self.error = "\(BiometricGate.kind.rawValue) didn't match. You can use your recovery phrase instead."
        }
    }

    private func unlock() async {
        guard context != nil, !password.isEmpty else { return }
        // An old Face ID approval no longer opens the key (see LockView.approvalLifetime): renew it first.
        if let t = verifiedAt, Date().timeIntervalSince(t) > LockView.approvalLifetime {
            await authenticate()
            guard verifiedAt.map({ Date().timeIntervalSince($0) < 60 }) ?? false else { return }
        }
        guard let context else { return }
        busy = true
        defer { busy = false }
        let pw = password
        let result: Result<UnlockedVault, Error> = await Task.detached(priority: .userInitiated) {
            Result { try Vault.unlock(password: pw, context: context.value) }
        }.value
        switch result {
        case .success(let v):
            password = ""
            model.signBackIn(previous: v)
        case .failure(let e):
            password = ""
            // Each failure as it is (audit STA-16): an erase or a lockout isn't a wrong password.
            switch e as? Vault.Failure {
            case .biometric(.invalidated)?: error = "\(BiometricGate.kind.rawValue) changed. Use your recovery phrase instead."
            case .lockedOut(let until)?: error = "Too many attempts. Try again in \(LockView.wait(until.timeIntervalSinceNow))."
            case .wiped?, .notSetUp?: model.wipe()
            case .wrongPassword?: error = LockView.wrongPassword()
            default: error = "Couldn't unlock. Try again."
            }
        }
    }
}
