import LocalAuthentication
import SwiftUI

struct OnboardingFlow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var ob = model.onboarding
        NavigationStack(path: $ob.path) {
            WelcomeView()
                .navigationDestination(for: OnboardingModel.Step.self) { step in
                    switch step {
                    case .welcome: WelcomeView()
                    case .purchase: PurchaseView()
                    case .password: CreatePasswordView()
                    case .biometrics: BiometricsView()
                    case .phrase: RecoveryPhraseView()
                    case .creating: CreatingAccountView()
                    case .signBackIn: SignBackInView()
                    }
                }
        }
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var appeared = false
    @State private var restoring = false
    @State private var legal: LegalDocument?

    var body: some View {
        // Scrolls only when it doesn't fit (a 4.7" iPhone SE, large Dynamic Type) instead of truncating.
        GeometryReader { geo in
            ScrollView {
                content(compact: geo.size.height < 760).frame(minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .onAppear {
            withAnimation(Theme.gentle.delay(0.1)) { appeared = true }
            if model.offerRestore { model.offerRestore = false; restoring = true }
        }
        .onChange(of: model.offerRestore) { _, v in if v { model.offerRestore = false; restoring = true } }
        .sheet(isPresented: $restoring) { BackupRestoreView(mode: .onboarding) }
        .sheet(item: $legal) { LegalView(document: $0) }
    }

    private func compactFeature(_ text: String, _ icon: String, _ tint: Color) -> some View {
        Label { Text(text).foregroundStyle(Theme.textPrimary) } icon: { Image(systemName: icon).foregroundStyle(tint) }
    }

    /// `compact`: short screens (4.7" iPhone SE) get a smaller mark and one-line features, so every action
    /// stays above the fold.
    private func content(compact: Bool) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: compact ? 8 : 20)
            VStack(spacing: compact ? 10 : 16) {
                PrivaMark()
                    .frame(width: compact ? 84 : 132, height: compact ? 84 : 132)
                    .motionPulse(to: 1.045, duration: 2.2)
                    .shadow(color: Theme.violet.opacity(0.45), radius: 40)
                Text("Priva").font(.system(size: compact ? 38 : 46, weight: .bold, design: .rounded)).foregroundStyle(Theme.textPrimary)
                Text("Private by design.\nQuantum-safe by default.")
                    .font(.title3.weight(.medium))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(Theme.textSecondary)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 16)
            Spacer(minLength: compact ? 14 : 28)
            if compact {
                VStack(alignment: .leading, spacing: 10) {
                    compactFeature("Peer-to-peer: no server stores messages", "point.3.connected.trianglepath.dotted", Theme.violet)
                    compactFeature("Two layers of post-quantum encryption", "atom", Theme.cyan)
                    compactFeature("Purchase never linked to your username", "eye.slash.fill", Theme.mint)
                }
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, Theme.gutter)
                .opacity(appeared ? 1 : 0)
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    FeatureRow(icon: "point.3.connected.trianglepath.dotted", title: "Peer-to-peer",
                               detail: "Messages and calls go phone to phone. No server stores them.")
                    FeatureRow(icon: "atom", title: "Post-quantum encryption",
                               detail: "Two independent layers of quantum-safe encryption.", tint: Theme.cyan)
                    FeatureRow(icon: "eye.slash.fill", title: "Anonymous by design",
                               detail: "Your purchase is never linked to your username.", tint: Theme.mint)
                }
                .padding(.horizontal, Theme.gutter)
                .opacity(appeared ? 1 : 0)
            }
            Spacer(minLength: compact ? 14 : 28)
            // Restoring comes first-class, before any sign-up: a backup brings the whole account back.
            VStack(spacing: 12) {
                PrimaryButton(title: "Create new account") { model.onboarding.path.append(.purchase) }
                    .accessibilityIdentifier("welcome.new")
                SecondaryButton(title: "Restore from backup", systemImage: "arrow.counterclockwise.icloud") { restoring = true }
                    .accessibilityIdentifier("welcome.restore")
                Button("No backup? Use my recovery phrase") { model.onboarding.path.append(.signBackIn) }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(minHeight: 44)
                // Agreeing to the terms (zero tolerance for abuse) is part of App Review's rules for apps where
                // people message each other.
                Text("By continuing you agree to the [Terms](priva-legal:Terms) and [Privacy Policy](priva-legal:Privacy). Zero tolerance for abuse.")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .tint(Theme.textSecondary)
                    .environment(\.openURL, OpenURLAction { url in
                        legal = LegalDocument(rawValue: url.absoluteString.replacingOccurrences(of: "priva-legal:", with: ""))
                        return .handled
                    })
                    .accessibilityIdentifier("welcome.terms")
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 12)
        }
    }
}

// MARK: - Purchase verification

struct PurchaseView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ob = model.onboarding
        OnboardingScaffold(step: 0, total: 4, title: "Verifying purchase", subtitle: "Checked once, then forgotten.") {
            VStack(spacing: 18) {
                ZStack {
                    Circle().stroke(Theme.hairline, lineWidth: 6)
                    switch ob.purchase {
                    case .verified:
                        Circle().fill(Theme.mint.opacity(0.14))
                        Image(systemName: "checkmark").font(.system(size: 44, weight: .bold)).foregroundStyle(Theme.mint)
                            .transition(.scale.combined(with: .opacity))
                    case .failed:
                        Image(systemName: "exclamationmark").font(.system(size: 44, weight: .bold)).foregroundStyle(Theme.rose)
                    default:
                        Circle().trim(from: 0, to: 0.28).stroke(Theme.aurora, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                            .rotationEffect(.degrees(ob.purchase == .verifying ? 360 : 0))
                            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: ob.purchase)
                        Image(systemName: "bag.fill").font(.system(size: 34)).foregroundStyle(Theme.textSecondary)
                    }
                }
                .frame(width: 120, height: 120)
                .animation(Theme.bouncy, value: ob.purchase)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .sensoryFeedback(.success, trigger: ob.purchase == .verified)

                Text(statusText(ob.purchase)).font(.headline).foregroundStyle(Theme.textPrimary).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .contentTransition(.opacity)
            }
        } footer: {
            if case .failed = ob.purchase {
                PrimaryButton(title: "Try Again", systemImage: "arrow.clockwise") { Task { await ob.verifyPurchase() } }
            } else {
                PrimaryButton(title: "Continue", enabled: ob.purchase == .verified) { ob.path.append(.password) }
            }
        }
        .task { await ob.verifyPurchase() }
    }

    private func statusText(_ s: OnboardingModel.PurchaseState) -> String {
        switch s {
        case .idle, .verifying: return "Checking with the App Store…"
        case .verified: return "Purchase verified"
        case .failed(let m): return m
        }
    }

}

// MARK: - Password

struct CreatePasswordView: View {
    @Environment(AppModel.self) private var model
    @State private var confirm = ""
    @FocusState private var f1: Bool
    @FocusState private var f2: Bool

    var body: some View {
        @Bindable var ob = model.onboarding
        let a = PasswordPolicy.assess(ob.password)
        let matches = !confirm.isEmpty && confirm == ob.password
        OnboardingScaffold(step: 1, total: 4, title: "Create a password", subtitle: "Used with \(BiometricGate.kind.rawValue) to open Priva. It never leaves this iPhone.") {
            PasswordField(title: "Password", text: $ob.password, focused: $f1) { f2 = true }
            if !ob.password.isEmpty { StrengthMeter(assessment: a).transition(.opacity) }
            PasswordField(title: "Confirm password", text: $confirm, focused: $f2)
            if !confirm.isEmpty {
                Label(matches ? "Passwords match" : "Passwords don't match", systemImage: matches ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(matches ? Theme.mint : Theme.rose)
            }
            Text("Use 12 or more characters, or four random words.")
                .font(.footnote).foregroundStyle(Theme.textSecondary)
        } footer: {
            PrimaryButton(title: "Continue", enabled: a.acceptable && matches) { ob.path.append(.biometrics) }
        }
        .animation(Theme.snappy, value: ob.password.isEmpty)
        .onAppear {
            // Back on this step: both fields start empty, never a hidden password the field doesn't show.
            if confirm.isEmpty { ob.password = "" }
            #if DEBUG
            if let pw = DebugAutomation.testPassword, ob.password.isEmpty { ob.password = pw; confirm = pw }
            #endif
            f1 = true
        }
    }
}

// MARK: - Biometrics

struct BiometricsView: View {
    @Environment(AppModel.self) private var model
    @State private var error: String?
    @State private var busy = false
    @State private var scan = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let ob = model.onboarding
        let kind = BiometricGate.kind
        OnboardingScaffold(step: 2, total: 4, title: "Enable \(kind.rawValue)", subtitle: "Priva opens only with your \(kind == .touchID ? "fingerprint" : "face") and your password.") {
            ZStack {
                RoundedRectangle(cornerRadius: 40).fill(Theme.surface).frame(width: 170, height: 170)
                Image(systemName: kind == .touchID ? "touchid" : "faceid")
                    .font(.system(size: 86, weight: .light))
                    .foregroundStyle(Theme.aurora)
                    .symbolEffect(.bounce, value: scan)
                RoundedRectangle(cornerRadius: 3).fill(Theme.cyan.opacity(0.7)).frame(width: 130, height: 3)
                    .offset(y: scan ? 60 : -60)
                    .blur(radius: 1)
                    .opacity(reduceMotion ? 0 : 1)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 1.4).repeatForever(), value: scan)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .onAppear { scan = true }
            if let error { Text(error).font(.footnote.weight(.medium)).foregroundStyle(Theme.rose) }
        } footer: {
            PrimaryButton(title: "Enable \(kind.rawValue)", systemImage: kind == .touchID ? "touchid" : "faceid", loading: busy) {
                Task { await enable(ob) }
            }
        }
    }

    private func enable(_ ob: OnboardingModel) async {
        busy = true
        defer { busy = false }
        error = nil
        do {
            let ctx = try await BiometricGate.authenticate(reason: "Seal your Priva vault")
            try await ob.createVault(context: ctx)
            ob.path.append(.phrase)
        } catch BiometricGate.Failure.unavailable {
            error = BiometricGate.unavailableMessage()
        } catch BiometricGate.Failure.cancelled {
            error = nil
        } catch {
            self.error = "Couldn't create the vault. Please try again."
        }
    }
}

// MARK: - Recovery phrase

/// The new account's 24 words: shown once here, kept by writing them down or downloading an encrypted file.
struct RecoveryPhraseView: View {
    @Environment(AppModel.self) private var model
    @State private var screenshotWarning = false

    var body: some View {
        let ob = model.onboarding
        OnboardingScaffold(step: 3, total: 4, title: "Recovery phrase", subtitle: "Write these 24 words down, or save them as a file.") {
            WordGrid(words: ob.phrase)
                .accessibilityIdentifier("phrase.words")
            Label("Anyone with these words can become you. Never share them.", systemImage: "exclamationmark.shield.fill")
                .font(.footnote).foregroundStyle(Theme.textSecondary)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.amber.opacity(0.1), in: .rect(cornerRadius: 14))
            if screenshotWarning {
                Label("Screenshot taken. Delete it from Photos.", systemImage: "camera.metering.unknown")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.rose)
            }
        } footer: {
            KeepKeyButtons(kind: .recovery, secret: ob.seed, password: ob.password) {
                OnboardingModel.phraseConfirmed = true
                model.onboarding.path.append(.creating)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            withAnimation { screenshotWarning = true }
        }
    }
}

// MARK: - Creating / registering

struct CreatingAccountView: View {
    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        let ob = model.onboarding
        let done = ob.create == .done
        ScrollView {
            VStack(spacing: 24) {
                ZStack {
                    Circle().fill(Theme.violet.opacity(0.18)).frame(width: 170, height: 170).blur(radius: 30)
                    PrivaMark().frame(width: 104, height: 104)
                }
                .scaleEffect(done ? 1.06 : 1)
                .animation(Theme.bouncy, value: done)
                .padding(.top, 24)
                VStack(spacing: 8) {
                    Text(done ? (ob.restored != nil ? "Welcome back" : "You're all set")
                              : (ob.restored != nil ? "Finishing your restore" : "Setting up Priva")).font(.screenTitle)
                    Text(done ? (ob.restored.map { "Your account is back with a new username. @\($0.oldUsername) is being retired." }
                                    ?? "Share your username so friends can add you.")
                              : (ob.restored != nil ? "New keys and a new username for this iPhone…" : "Creating your keys and username…"))
                        .font(.body).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                }
                if done, let v = ob.vault {
                    UsernameCard(username: v.username, copied: $copied)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
                if done {
                    // Once finished, the three steps collapse into one line so the username card fits on screen.
                    if let r = ob.restored {
                        RestoredSummaryCard(summary: r).transition(.opacity)
                    } else if ob.isReturning {
                        Label("Your friends have been invited to follow you", systemImage: "checkmark.seal.fill")
                            .font(.footnote.weight(.semibold)).foregroundStyle(Theme.mint)
                            .transition(.opacity)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        row(0, ob.restored != nil ? "Chats, friends and groups restored" : "Creating your keys", "")
                        row(1, ob.restored != nil ? "Claiming a new random username" : "Claiming a random username", "")
                        row(2, ob.isReturning ? "Telling your friends where you are" : "Removing the purchase record", "")
                    }
                    .padding(20)
                    .background(Theme.surface, in: .rect(cornerRadius: Theme.radius))
                    .transition(.opacity)
                }
                if done {
                    WarningNote(text: "For high security, use Priva with a VPN.",
                                systemImage: "network.badge.shield.half.filled")
                        .accessibilityIdentifier("onboarding.vpn")
                        .transition(.opacity)
                }
                if case .failed(let m) = ob.create {
                    Text(m).font(.footnote.weight(.medium)).foregroundStyle(Theme.rose).multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, Theme.gutter)
        }
        .safeAreaInset(edge: .bottom) {
            Group {
                switch ob.create {
                case .done: PrimaryButton(title: "Open Priva", systemImage: "arrow.right") { open(ob) }
                case .failed: PrimaryButton(title: "Try Again", systemImage: "arrow.clockwise") { Task { await ob.register() } }
                default: PrimaryButton(title: "Working…", loading: true) {}
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 12)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .animation(Theme.snappy, value: ob.create)
        .sensoryFeedback(.success, trigger: done)
        .task { if ob.create == .idle { await ob.register() } }
    }

    private func open(_ ob: OnboardingModel) {
        guard let v = ob.vault else { return }
        let tour = ob.shouldShowTour
        defer { if tour { model.showTour = true } }
        let registered = UnlockedVault(username: v.username, vaultKey: v.vaultKey, identity: v.identity, bundle: v.bundle, registered: true)
        if model.phase == .finishingSetup, let engine = model.engine, engine.vault.username == v.username {
            if let m = ob.pendingMigration { engine.saveMigration(m); ob.pendingMigration = nil }
            model.finishRegistration()
        } else {
            model.didUnlock(registered)
        }
        ob.reset()
    }

    private func row(_ i: Int, _ title: String, _ detail: String) -> some View {
        let state: Int = {
            switch model.onboarding.create {
            case .done: return 3
            case .working(let n): return n
            default: return 0
            }
        }()
        return HStack(spacing: 14) {
            ZStack {
                Circle().fill(state > i ? Theme.mint : Theme.surface2).frame(width: 28, height: 28)
                if state > i { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.black) }
                else if state == i { ProgressView().controlSize(.small) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(state >= i ? Theme.textPrimary : Theme.textTertiary)
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(Theme.textSecondary) }
            }
        }
        .animation(Theme.snappy, value: state)
    }
}

/// Shows a username with copy + QR, used after registration and in Settings.
struct UsernameCard: View {
    let username: String
    @Binding var copied: Bool

    var body: some View {
        VStack(spacing: 14) {
            Text("Your username").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            Text("@\(username)")
                .accessibilityIdentifier("username.card")
                .font(.system(.title3, design: .monospaced).weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            QRCodeView(text: "priva://add/\(username)").frame(width: 150, height: 150)
            HStack(spacing: 10) {
                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    SecurePasteboard.copy(username)
                    withAnimation(Theme.snappy) { copied = true }
                }
                .buttonStyle(.glass)
                ShareLink(item: "Add me on Priva: @\(username)") { Label("Share", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.glass)
            }
            Text("Friends can type this name or scan the code.")
                .font(.caption).foregroundStyle(Theme.textTertiary).multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Theme.surface, in: .rect(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Theme.aurora.opacity(0.6), lineWidth: 1))
    }
}

// MARK: - Sign back in with the recovery phrase

/// For a returning user whose old vault didn't survive (or who prefers the phrase): proves the old
/// identity, so friends can be invited to the new username and the old one removed.
struct SignBackInView: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var oldName = ""
    @State private var error: String?
    @State private var busy = false
    @State private var importing = false

    var body: some View {
        OnboardingScaffold(step: nil, title: "Sign back in", subtitle: "You'll get a new username. Enter your recovery phrase so your friends can follow you.") {
            PhraseInput(text: $text)
            OpenKeyFileButton(kind: .recovery) { importing = true }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text("@").foregroundStyle(Theme.textTertiary)
                    TextField("previous username (optional)", text: $oldName).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                .font(.body.weight(.medium))
                .padding(.horizontal, 16).frame(height: 52)
                .background(Theme.surface, in: .rect(cornerRadius: 14))
                Text("Your old username is removed right away, or after 3 weeks if you don't enter it.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
            if let error { Text(error).font(.footnote.weight(.medium)).foregroundStyle(Theme.rose) }
        } footer: {
            PrimaryButton(title: "Continue", loading: busy, enabled: PhraseInput.words(text).count == 24) { Task { await verify() } }
            Button("Skip, start without friends") { model.onboarding.path = [.purchase] }
                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textSecondary).frame(minHeight: 44)
        }
        .keyFileImporter(isPresented: $importing, kind: .recovery) { seed in
            error = nil
            text = RecoveryPhrase.encode(seed).joined(separator: " ")
        }
    }

    private func verify() async {
        busy = true
        defer { busy = false }
        error = nil
        do {
            let seed = try RecoveryPhrase.decode(text)
            let identity = try IdentityKeys(seed: seed)
            var name: String?
            let typed = Username.normalize(oldName)
            if !typed.isEmpty {
                let entry = try await PrivaAPI.shared.lookup(typed)
                if let b = entry.bundle, b.verifying.ed.rawRepresentation == identity.signing.verifying.ed.rawRepresentation {
                    name = typed
                } else if entry.status == .removed {
                    name = nil
                } else {
                    error = "That username doesn't belong to this phrase."
                    return
                }
            }
            let ob = model.onboarding
            ob.previous = .init(username: name, identity: identity)
            ob.path = [.purchase]
        } catch RecoveryPhrase.Failure.checksum {
            error = "One or more words are wrong (checksum mismatch)."
        } catch RecoveryPhrase.Failure.unknownWord(let w) {
            error = "“\(w)” isn't a recovery word."
        } catch {
            self.error = "Couldn't verify right now. Check your connection."
        }
    }
}

/// Recovery phrase entry with live word validation and autocomplete.
struct PhraseInput: View {
    @Binding var text: String
    static func words(_ t: String) -> [String] { t.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init) }

    var body: some View {
        let words = Self.words(text)
        let current = text.last?.isWhitespace == false ? (words.last ?? "") : ""
        VStack(alignment: .leading, spacing: 10) {
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .frame(minHeight: 150)
                .padding(10)
                .background(Theme.surface, in: .rect(cornerRadius: 16))
            HStack {
                Text("\(words.count)/24 words").font(.caption.monospacedDigit()).foregroundStyle(words.count == 24 ? Theme.mint : Theme.textSecondary)
                if let bad = words.first(where: { RecoveryPhrase.words.firstIndex(of: $0) == nil && $0 != current }) {
                    Text("· “\(bad)” isn't valid").font(.caption).foregroundStyle(Theme.rose)
                }
            }
            if !current.isEmpty, !(words.count == 24 && RecoveryPhrase.words.contains(current)) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(RecoveryPhrase.suggestions(for: current), id: \.self) { s in
                            Button(s) {
                                var w = words
                                w[w.count - 1] = s
                                text = w.joined(separator: " ") + " "
                            }
                            .buttonStyle(.glass)
                            .font(.system(.subheadline, design: .monospaced))
                        }
                    }
                }
            }
        }
    }
}

/// After a restore: what came back, and what happens to the old username.
struct RestoredSummaryCard: View {
    let summary: OnboardingModel.RestoreSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("^[\(summary.friends) friend](inflect: true) · ^[\(summary.groups) group](inflect: true) · ^[\(summary.messages) message](inflect: true) restored",
                  systemImage: "checkmark.seal.fill")
                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.mint)
            Label("Friends and groups move to your new username automatically.",
                  systemImage: "arrow.triangle.2.circlepath")
                .font(.footnote).foregroundStyle(Theme.textSecondary)
            Label("@\(summary.oldUsername) is removed from the directory within a few hours.", systemImage: "person.crop.circle.badge.xmark")
                .font(.footnote).foregroundStyle(Theme.textSecondary)
            Label("Your recovery phrase changed. Save the new one in Settings › Security.",
                  systemImage: "list.number")
                .font(.footnote).foregroundStyle(Theme.textSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: .rect(cornerRadius: Theme.radius))
    }
}
