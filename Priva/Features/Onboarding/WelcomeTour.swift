import SwiftUI

/// The welcome tour: what Priva does, plus switches for the security features. Shown once, after creating a
/// brand-new account on a first install (never after a restore or signing back in), and any time from Settings.
enum WelcomeTour {
    static let account = "firstrun.tour"
    private static let defaultsKey = "priva.tour.seen"

    /// Kept in the Keychain as well, so deleting and reinstalling Priva doesn't bring the tour back. Erasing the
    /// account ("Delete account", erase after 10 tries) removes it with everything else.
    static var seen: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey) || ((try? Keychain.get(account)) ?? nil) != nil
    }

    static func markSeen() {
        UserDefaults.standard.set(true, forKey: defaultsKey)
        try? Keychain.set(Data([1]), account: account)
    }

    #if DEBUG
    static func debugForget() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        _ = Keychain.delete(account)
    }
    #endif
}

struct WelcomeTourView: View {
    /// Opened from Settings: nothing is marked, the last button just closes it.
    var replay = false
    @Environment(AppModel.self) private var model
    @Environment(PrivaEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0
    @State private var onion = NetworkPrivacy.current.onion
    @State private var settingUpBackup = false

    private let pages = 6

    var body: some View {
        @Bindable var e = engine
        VStack(spacing: 0) {
            HStack {
                Text("\(page + 1) of \(pages)").font(.footnote.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                    .accessibilityLabel("Page \(page + 1) of \(pages)")
                Spacer()
                if page < pages - 1 {
                    Button(replay ? "Close" : "Skip") { finish() }
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                        .accessibilityIdentifier("tour.skip")
                }
            }
            .padding(.horizontal, Theme.gutter).frame(height: 44)

            TabView(selection: $page) {
                card(0, "hand.wave.fill", Theme.violet, "Welcome to Priva",
                     "You're @\(engine.me). No phone number, no email, not linked to your purchase.")
                    .tag(0)
                card(1, "point.3.connected.trianglepath.dotted", Theme.cyan, "Phone to phone",
                     "Messages and calls go straight between phones. Servers only help them find each other.")
                    .tag(1)
                card(2, "atom", Theme.mint, "Quantum-safe",
                     "Encrypted twice, quantum-safe. Compare security codes in person to be sure.")
                    .tag(2)
                card(3, "person.3.fill", .orange, "Groups live on phones",
                     "Groups live on the host's iPhone, not a server. If the host leaves, someone takes over.")
                    .tag(3)
                securityPage($e).tag(4)
                backupPage.tag(5)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(Theme.snappy, value: page)

            HStack(spacing: 6) {
                ForEach(0..<pages, id: \.self) { i in
                    Capsule().fill(i == page ? Theme.violet : Theme.hairline).frame(width: i == page ? 18 : 6, height: 6)
                }
            }
            .animation(Theme.snappy, value: page)
            .padding(.bottom, 16)

            PrimaryButton(title: page == pages - 1 ? (replay ? "Done" : "Start using Priva") : "Next",
                          systemImage: page == pages - 1 ? "checkmark" : "arrow.right") {
                if page == pages - 1 { finish() } else { page += 1 }
            }
            .accessibilityIdentifier("tour.next")
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 12)
        }
        .background(Theme.background.ignoresSafeArea())
        .hiddenWhileCaptured()
        .interactiveDismissDisabled(!replay)
        .onAppear {
            onion = NetworkPrivacy.current.onion
        }
        .sheet(isPresented: $settingUpBackup) { BackupSetupView() }
    }

    private func card(_ i: Int, _ icon: String, _ color: Color, _ title: String, _ text: String) -> some View {
        // Centred when it fits; scrolls at the largest text sizes instead of cutting the words.
        ViewThatFits(in: .vertical) {
            cardContent(icon, color, title, text).frame(maxHeight: .infinity)
            ScrollView { cardContent(icon, color, title, text).padding(.vertical, 24) }
        }
        .padding(.horizontal, Theme.gutter + 8)
    }

    private func cardContent(_ icon: String, _ color: Color, _ title: String, _ text: String) -> some View {
        VStack(spacing: 22) {
            HeroGlyph(systemImage: icon, color: color)
            Text(title).font(.screenTitle).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Text(text).font(.body).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func securityPage(_ e: Bindable<PrivaEngine>) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                HeroGlyph(systemImage: "lock.shield.fill", color: Theme.violet)
                Text("Your security").font(.screenTitle)
                Text("Priva locks with \(BiometricGate.kind.rawValue) and your password. Pick the rest; change them anytime.")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                VStack(spacing: 0) {
                    HStack {
                        SettingsRow(title: "\(BiometricGate.kind.rawValue) + password", systemImage: BiometricGate.kind == .touchID ? "touchid" : "faceid", color: Theme.violet)
                        Spacer()
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.mint)
                    }
                    .padding(.horizontal, 14).frame(minHeight: 52)
                    Divider().padding(.leading, 56)
                    // Outside a List a Picker drops its label, so the row is built by hand.
                    HStack {
                        SettingsRow(title: "Auto-lock", systemImage: "lock.rotation", color: Theme.violet)
                        Spacer(minLength: 8)
                        Picker("Auto-lock", selection: e.settings.autoLockSeconds) {
                            Text("Immediately").tag(0)
                            Text("After 1 minute").tag(60)
                            Text("After 5 minutes").tag(300)
                        }
                        .labelsHidden()
                    }
                    .padding(.horizontal, 14).frame(minHeight: 52)
                    Divider().padding(.leading, 56)
                    EraseAfterFailuresToggle()
                        .accessibilityIdentifier("tour.erase")
                        .padding(.horizontal, 14).frame(minHeight: 52)
                    Divider().padding(.leading, 56)
                    Toggle(isOn: $onion) { SettingsRow(title: "Onion routing", systemImage: "circle.hexagongrid.fill", color: .indigo) }
                        .onChange(of: onion) { _, v in
                            var cfg = NetworkPrivacy.current
                            cfg.mode = v ? .tor : .direct
                            engine.setNetworkPrivacy(cfg)
                        }
                        .accessibilityIdentifier("tour.onion")
                        .padding(.horizontal, 14).frame(minHeight: 52)
                    Divider().padding(.leading, 56)
                    Toggle(isOn: e.settings.readReceipts) { SettingsRow(title: "Read receipts", systemImage: "checkmark.message.fill", color: Theme.cyan) }
                        .padding(.horizontal, 14).frame(minHeight: 52)
                    Divider().padding(.leading, 56)
                    Toggle(isOn: e.settings.announcePresence) { SettingsRow(title: "Show when I'm online", systemImage: "dot.radiowaves.left.and.right", color: Theme.mint) }
                        .padding(.horizontal, 14).frame(minHeight: 52)
                }
                .background(Theme.surface, in: .rect(cornerRadius: 18, style: .continuous))
                Text("Tor hides your IP address (slower). Erase wipes Priva after 10 wrong passwords.")
                    .font(.footnote).foregroundStyle(Theme.textTertiary).multilineTextAlignment(.center)
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 8)
        }
    }

    private var backupPage: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            HeroGlyph(systemImage: engine.backup.isOn ? "checkmark.icloud.fill" : "lock.icloud.fill", color: engine.backup.isOn ? Theme.mint : .blue)
            Text(engine.backup.isOn ? "Backups are on" : "Back up your account").font(.screenTitle)
            Text(engine.backup.isOn
                 ? "Lose this iPhone? Your chats come back with your Backup Key and password."
                 : "An encrypted, messages-only backup. It opens only with your Backup Key and password.")
                .font(.body).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if !engine.backup.isOn {
                SecondaryButton(title: "Set up backup", systemImage: "arrow.clockwise.icloud") { settingUpBackup = true }
                    .accessibilityIdentifier("tour.backup")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.gutter + 8)
    }

    private func finish() {
        if !replay { WelcomeTour.markSeen() }
        model.showTour = false
        dismiss()
    }
}
