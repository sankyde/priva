import CryptoKit
import LocalAuthentication
import SwiftUI

// MARK: - Settings (top level)

struct SettingsView: View {
    @Environment(PrivaEngine.self) private var engine
    @Environment(AppModel.self) private var model
    @AppStorage(Appearance.storageKey) private var appearance = Appearance.system.rawValue
    @State private var onion = NetworkPrivacy.current.onion
    @State private var touring = false
    @State private var legal: LegalDocument?

    /// Backups off, or not run for days: one line, under the Backup row.
    private var backupWarning: String? {
        guard let c = engine.backup.config else { return "Backups are off. Lose this iPhone and your chats are gone." }
        let last = c.lastBackup ?? c.created
        guard c.automatic, last.timeIntervalSinceNow < -3 * 86_400 else { return nil }
        return "No backup for \(Int(-last.timeIntervalSinceNow / 86_400)) days. Open Backup to run one."
    }

    var body: some View {
        List {
            Section {
                NavigationLink { ProfileView() } label: { profileCard }
            }
            .listRowBackground(Theme.surface)

            Section {
                NavigationLink { BackupSettingsView() } label: {
                    SettingsRow(title: "Backup", systemImage: "lock.icloud.fill", color: .blue,
                                value: engine.backup.isOn ? "On" : "Off",
                                valueColor: engine.backup.isOn ? Theme.mint : Theme.amber)
                }
                NavigationLink { PrivacySettingsView() } label: {
                    SettingsRow(title: "Privacy", systemImage: "hand.raised.fill", color: Theme.violet)
                }
                NavigationLink { SecuritySettingsView() } label: {
                    SettingsRow(title: "Security & account", systemImage: "lock.shield.fill", color: Theme.mint,
                                value: model.integrity.ok ? nil : "Check", valueColor: Theme.rose)
                }
            } footer: {
                if let warning = backupWarning { WarningNote(text: warning).padding(.top, 4) }
            }
            .listRowBackground(Theme.surface)

            Section {
                NavigationLink { NetworkSettingsView() } label: {
                    SettingsRow(title: "Network", systemImage: "network", color: .indigo,
                                value: onion ? "Tor" : nil)
                }
                NavigationLink { AppearanceView() } label: {
                    SettingsRow(title: "Appearance", systemImage: "circle.lefthalf.filled", color: .gray,
                                value: (Appearance(rawValue: appearance) ?? .system).label)
                }
                NavigationLink { StorageView() } label: {
                    SettingsRow(title: "Storage", systemImage: "internaldrive.fill", color: .orange)
                }
            }
            .listRowBackground(Theme.surface)

            Section {
                NavigationLink { HowItWorksView() } label: {
                    SettingsRow(title: "How Priva protects you", systemImage: "shield.lefthalf.filled", color: Theme.cyan)
                }
                Button { touring = true } label: {
                    SettingsRow(title: "Welcome tour", systemImage: "sparkles", color: .pink)
                }
                .accessibilityIdentifier("settings.tour")
                Button { legal = .terms } label: { SettingsRow(title: "Terms of Use", systemImage: "doc.text.fill", color: .gray) }
                Button { legal = .privacy } label: { SettingsRow(title: "Privacy Policy", systemImage: "hand.raised.square.fill", color: .gray) }
                if let email = Support.email, let url = URL(string: "mailto:\(email)?subject=Priva%20support") {
                    Link(destination: url) { SettingsRow(title: "Contact support", systemImage: "envelope.fill", color: .blue) }
                }
                #if DEBUG
                NavigationLink { DiagnosticsView() } label: {
                    SettingsRow(title: "Diagnostics", systemImage: "gauge.with.dots.needle.67percent", color: .gray)
                }
                #endif
            } footer: {
                Text("Priva \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                    .frame(maxWidth: .infinity).padding(.top, 8)
            }
            .listRowBackground(Theme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Settings")
        .onAppear { onion = NetworkPrivacy.current.onion }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Lock", systemImage: "lock.fill") { model.lock() }
            }
        }
        .sheet(isPresented: $touring, onDismiss: { onion = NetworkPrivacy.current.onion }) {
            WelcomeTourView(replay: true).environment(model).environment(engine)
        }
        .sheet(item: $legal) { LegalView(document: $0) }
    }

    private var profileCard: some View {
        HStack(spacing: 14) {
            Avatar(name: engine.me, size: 58, online: engine.realtimeStatus == .connected)
            VStack(alignment: .leading, spacing: 3) {
                Text(engine.settings.displayName.isEmpty ? "Add your name" : engine.settings.displayName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(engine.settings.displayName.isEmpty ? Theme.textSecondary : Theme.textPrimary)
                Text("@\(engine.me)").font(.subheadline.monospaced()).foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Profile

struct ProfileView: View {
    @Environment(PrivaEngine.self) private var engine
    @State private var copied = false

    var body: some View {
        @Bindable var e = engine
        List {
            Section {
                VStack(spacing: 10) {
                    Avatar(name: engine.me, size: 96, online: engine.realtimeStatus == .connected)
                    Text(engine.settings.displayName.isEmpty ? "@\(engine.me)" : engine.settings.displayName)
                        .font(.title2.weight(.bold)).lineLimit(1).minimumScaleFactor(0.6)
                    Label(statusText, systemImage: statusIcon)
                        .font(.caption.weight(.semibold)).foregroundStyle(statusColor)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(statusColor.opacity(0.12), in: .capsule)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            Section {
                TextField("Your name", text: $e.settings.displayName)
                    .textContentType(.nickname)
                    .onChange(of: engine.settings.displayName) { _, v in if v.count > 40 { e.settings.displayName = String(v.prefix(40)) } }
            } header: { Text("Name") } footer: {
                Text("Optional. Shared only with your friends, inside encrypted messages.")
            }
            .listRowBackground(Theme.surface)
            Section {
                UsernameCard(username: engine.me, copied: $copied)
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            } header: { Text("Your username") } footer: {
                Text("People can add you only by typing this exactly. There's no search.")
            }
            .listRowBackground(Theme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var statusText: String {
        switch engine.ownDirectoryState {
        case .uninstalled?: return "Not findable by new people"
        case .removed?: return "Removed from the directory"
        default: return "Findable by exact username"
        }
    }
    private var healthy: Bool { engine.ownDirectoryState == .active || engine.ownDirectoryState == nil }
    private var statusIcon: String { healthy ? "checkmark.circle.fill" : "exclamationmark.circle.fill" }
    private var statusColor: Color { healthy ? Theme.mint : Theme.amber }
}

// MARK: - Privacy

struct PrivacySettingsView: View {
    @Environment(PrivaEngine.self) private var engine

    var body: some View {
        @Bindable var e = engine
        List {
            Section {
                Toggle(isOn: $e.settings.readReceipts) { SettingsRow(title: "Read receipts", systemImage: "checkmark.circle.fill", color: .blue) }
                Toggle(isOn: $e.settings.typingIndicators) { SettingsRow(title: "Typing indicator", systemImage: "ellipsis.bubble.fill", color: Theme.cyan) }
                Toggle(isOn: $e.settings.announcePresence) { SettingsRow(title: "Show when I'm online", systemImage: "circle.fill", color: Theme.mint) }
            } footer: {
                Text("These go only to your friends, directly and encrypted. Turning one off stops sending it.")
            }
            .listRowBackground(Theme.surface)
            Section {
                LabeledContent { Image(systemName: "checkmark").foregroundStyle(Theme.mint) } label: {
                    SettingsRow(title: "Hidden in app switcher", systemImage: "eye.slash.fill", color: .gray)
                }
                LabeledContent { Image(systemName: "checkmark").foregroundStyle(Theme.mint) } label: {
                    SettingsRow(title: "Only Apple's keyboard", systemImage: "keyboard.fill", color: .gray)
                }
            } header: { Text("Always on") }
            .listRowBackground(Theme.surface)
            Section {
                NavigationLink { BlockedListView() } label: {
                    SettingsRow(title: "Blocked", systemImage: "hand.raised.fill", color: Theme.rose,
                                value: engine.blocked.isEmpty ? nil : "\(engine.blocked.count)")
                }
            }
            .listRowBackground(Theme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Security & account

/// "Erase after 10 tries": turning it on asks first, and the switch shows what was actually saved.
struct EraseAfterFailuresToggle: View {
    @State private var on = false
    @State private var confirming = false

    var body: some View {
        Toggle(isOn: Binding(get: { on }, set: { v in if v { confirming = true } else { save(false) } })) {
            SettingsRow(title: "Erase after 10 tries", systemImage: "trash.slash.fill", color: Theme.rose)
        }
        // Read when shown: NavigationLink builds this view early, so an initial @State value would be stale.
        .onAppear { on = Vault.meta?.wipeAfterFailures ?? false }
        .confirmationDialog("Erase after 10 wrong passwords?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Turn on", role: .destructive) { save(true) }
        } message: {
            Text("Priva on this iPhone is erased after 10 wrong passwords in a row. The lock screen warns from the 5th.")
        }
    }

    private func save(_ v: Bool) {
        do { try Vault.setWipeAfterFailures(v) } catch { UINotificationFeedbackGenerator().notificationOccurred(.error) }
        on = Vault.meta?.wipeAfterFailures ?? false
    }
}

struct SecuritySettingsView: View {
    @Environment(PrivaEngine.self) private var engine
    @Environment(AppModel.self) private var model
    @State private var confirmLeave = false
    @State private var confirmDelete = false
    @State private var working = false
    /// Leaving or deleting asks for the password too, not only Face ID (audit SEC-18): either can't be undone.
    @State private var askingPassword: Bool?          // the pending choice: true = delete, false = leave
    @State private var typed = ""

    var body: some View {
        @Bindable var e = engine
        List {
            if !model.integrity.ok {
                Section {
                    Label("This iPhone looks modified (jailbreak or debugger). Your keys may be at risk.", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline).foregroundStyle(Theme.rose)
                }
                .listRowBackground(Theme.rose.opacity(0.1))
            }
            Section {
                Picker(selection: $e.settings.autoLockSeconds) {
                    Text("Immediately").tag(0)
                    Text("After 1 minute").tag(60)
                    Text("After 5 minutes").tag(300)
                } label: { SettingsRow(title: "Auto-lock", systemImage: "lock.rotation", color: Theme.violet) }
                EraseAfterFailuresToggle()
            } footer: {
                Text("10 wrong passwords in a row erase Priva on this iPhone.")
            }
            .listRowBackground(Theme.surface)
            Section {
                NavigationLink { ChangePasswordView() } label: { SettingsRow(title: "Change password", systemImage: "key.fill", color: .orange) }
                NavigationLink { RecoveryPhraseRevealView() } label: { SettingsRow(title: "Recovery phrase", systemImage: "list.number", color: .indigo) }
                NavigationLink { PurchaseIDView() } label: { SettingsRow(title: "Purchase ID", systemImage: "bag.fill", color: .teal) }
            }
            .listRowBackground(Theme.surface)
            Section {
                Button(role: .destructive) { confirmLeave = true } label: { Text("Leave Priva on this iPhone") }
                Button(role: .destructive) { confirmDelete = true } label: { Text("Delete account") }
            } header: { Text("Account") } footer: {
                Text("Both erase Priva and your backups here. Leave: friends see you left. Delete: your account is removed for good.")
            }
            .listRowBackground(Theme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Security & account")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(working)
        .overlay { if working { ProgressView().controlSize(.large) } }
        .confirmationDialog("Leave Priva on this iPhone?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave", role: .destructive) { askPassword(delete: false) }
        } message: { Text("@\(engine.me) disappears right away. Coming back means a new username.") }
        .confirmationDialog("Delete your account?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete account", role: .destructive) { askPassword(delete: true) }
        } message: { Text("@\(engine.me), your messages and backups are erased for good.") }
        .alert("Enter your Priva password", isPresented: Binding(get: { askingPassword != nil }, set: { if !$0 { askingPassword = nil } })) {
            SecureField("Password", text: $typed).textContentType(.oneTimeCode)
            Button("Cancel", role: .cancel) { typed = "" }
            Button(askingPassword == true ? "Delete account" : "Leave", role: .destructive) {
                let pw = typed, delete = askingPassword == true
                typed = ""
                Task { await leave(delete: delete, password: pw) }
            }
        }
    }

    private func askPassword(delete: Bool) {
        #if DEBUG
        if let pw = DebugAutomation.testPassword { typed = pw }
        #endif
        askingPassword = delete
    }

    private func leave(delete: Bool, password: String) async {
        do {
            let ctx = SendableBox(try await BiometricGate.authenticate(reason: delete ? "Delete your Priva account" : "Leave Priva on this iPhone"))
            _ = try await Task.detached(priority: .userInitiated) { try Vault.unlock(password: password, context: ctx.value) }.value
        } catch BiometricGate.Failure.cancelled {
            return
        } catch Vault.Failure.wrongPassword {
            engine.toast = .init(title: "Wrong password", body: "Nothing was erased.", contact: nil)
            return
        } catch {
            engine.toast = .init(title: "Couldn't check", body: "Nothing was erased. Try again.", contact: nil)
            return
        }
        working = true
        defer { working = false }
        let commit = engine.myBundle.ucommit, identity = engine.identity
        do {
            if delete { try await PrivaAPI.shared.revoke(ucommit: commit, secret: identity.revokeSecret) }
            else { try await PrivaAPI.shared.retire(ucommit: commit, identity: identity) }
        } catch {
            engine.toast = .init(title: "Couldn't reach Priva", body: "Try again when you're online.", contact: nil)
            return
        }
        engine.backup.turnOff(deleteFiles: false)
        await Task.detached { BackupLocations.deleteAll(); BackupKeychainFactor.delete() }.value
        let record = delete ? nil : Vault.revocationRecord
        model.wipe()
        if let record { Vault.storeRevocation(record) }
    }
}

struct ChangePasswordView: View {
    @Environment(PrivaEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var pw = ""
    @State private var confirm = ""
    @State private var error: String?
    @State private var busy = false
    @FocusState private var f0: Bool
    @FocusState private var f1: Bool
    @FocusState private var f2: Bool

    var body: some View {
        OnboardingScaffold(title: "Change password",
                           subtitle: engine.backup.isOn ? "New backups will need the new password. Older backups still open with the old one."
                                                        : "You'll use it with \(BiometricGate.kind.rawValue) to unlock Priva.") {
            PasswordField(title: "Current password", text: $current, focused: $f0) { f1 = true }
            PasswordField(title: "New password", text: $pw, focused: $f1) { f2 = true }
            if !pw.isEmpty { StrengthMeter(assessment: PasswordPolicy.assess(pw)) }
            PasswordField(title: "Confirm new password", text: $confirm, focused: $f2) { Task { await change() } }
            if !confirm.isEmpty && pw != confirm {
                Text("Passwords don't match.").font(.footnote.weight(.medium)).foregroundStyle(Theme.rose)
            }
            if let error { Text(error).font(.footnote.weight(.medium)).foregroundStyle(Theme.rose) }
        } footer: {
            PrimaryButton(title: "Change password", loading: busy, enabled: !current.isEmpty && PasswordPolicy.assess(pw).acceptable && pw == confirm) {
                Task { await change() }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { f0 = true }
    }

    private func change() async {
        guard !current.isEmpty, PasswordPolicy.assess(pw).acceptable, pw == confirm, !busy else { return }
        busy = true
        defer { busy = false }
        error = nil
        do {
            let ctx = SendableBox(try await BiometricGate.authenticate(reason: "Confirm your new Priva password"))
            let vault = engine.vault, newPassword = pw, currentPassword = current
            try await Task.detached(priority: .userInitiated) {
                try Vault.changePassword(vault: vault, currentPassword: currentPassword, newPassword: newPassword, context: ctx.value)
            }.value
            await engine.backup.passwordChanged(to: newPassword)
            current = ""
            pw = ""
            confirm = ""
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            engine.toast = .init(title: "Password changed", body: "Use your new password next time you unlock.", contact: nil)
            dismiss()
        } catch BiometricGate.Failure.cancelled {
        } catch Vault.Failure.wrongPassword {
            self.error = "That isn't your current password."
            current = ""
            f0 = true
        } catch Vault.Failure.lockedOut(let until) {
            self.error = "Too many wrong passwords. Try again \(until.formatted(.relative(presentation: .named)))."
        } catch {
            self.error = "Couldn't change the password."
        }
    }
}

struct RecoveryPhraseRevealView: View {
    @Environment(PrivaEngine.self) private var engine
    @Environment(\.scenePhase) private var scenePhase
    @State private var unlocked = false
    @State private var asking = false
    @State private var typed = ""
    @State private var sealing = false
    @State private var keyFile: KeyFileDocument?
    @State private var note: (text: String, ok: Bool)?
    @State private var askingToShow = false
    @State private var showError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if unlocked {
                    WordGrid(words: RecoveryPhrase.encode(engine.identity.seed))
                    SaveKeyFileButton(kind: .recovery, busy: sealing) {
                        note = nil
                        #if DEBUG
                        if let pw = DebugAutomation.testPassword { typed = pw }
                        #endif
                        asking = true
                    }
                    if let note {
                        Label(note.text, systemImage: note.ok ? "checkmark.circle.fill" : "exclamationmark.octagon.fill")
                            .font(.footnote.weight(.medium)).foregroundStyle(note.ok ? Theme.mint : Theme.rose)
                    }
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.shield.fill").foregroundStyle(Theme.amber)
                        Text("Anyone with these words can become you. Never share them.")
                            .font(.footnote).foregroundStyle(Theme.textSecondary)
                    }
                    .padding(14)
                    .background(Theme.amber.opacity(0.1), in: .rect(cornerRadius: 14))
                } else {
                    VStack(spacing: 16) {
                        HeroGlyph(systemImage: "list.number")
                        Text("Your recovery phrase").font(.title2.weight(.bold))
                        Text("24 words that move your identity to a new iPhone. It's different from your Backup Key.")
                            .font(.subheadline).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                        // Password and Face ID: an unlocked iPhone in someone else's hands isn't enough to read the
                        // words that can become you (audit SEC-04).
                        PrimaryButton(title: "Show", systemImage: "eye.fill") {
                            showError = nil
                            #if DEBUG
                            if let pw = DebugAutomation.testPassword { typed = pw }
                            #endif
                            askingToShow = true
                        }
                        .padding(.top, 6)
                        Text("Needs your password and \(BiometricGate.kind.rawValue).").font(.caption).foregroundStyle(Theme.textTertiary)
                        if let showError {
                            Text(showError).font(.footnote.weight(.semibold)).foregroundStyle(Theme.rose).multilineTextAlignment(.center)
                        }
                    }
                    .padding(.top, 40)
                }
            }
            .padding(Theme.gutter)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Recovery phrase")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { unlocked = false; note = nil }
        // Leaving the app hides the words again (auto-lock may be minutes away).
        .onChange(of: scenePhase) { _, p in if p == .background { unlocked = false } }
        .alert("Enter your Priva password", isPresented: $askingToShow) {
            SecureField("Password", text: $typed)
                .textContentType(.oneTimeCode)
            Button("Cancel", role: .cancel) { typed = "" }
            Button("Show") { let pw = typed; typed = ""; Task { await reveal(pw) } }
        }
        .alert("Enter your Priva password", isPresented: $asking) {
            SecureField("Password", text: $typed)
                .textContentType(.oneTimeCode)
            Button("Cancel", role: .cancel) { typed = "" }
            Button("Continue") { let pw = typed; typed = ""; Task { await seal(pw) } }
        } message: {
            Text("The file opens only with this password. If you change it, save a new file.")
        }
        .keyFileExporter($keyFile, kind: .recovery, onSaved: { note = ("Saved. Keep it where only you can reach it.", true) },
                         onFailed: { note = ("Couldn't save the file. Try again.", false) })
    }

    /// The same check as the lock screen (and the same wrong-password counter).
    private func reveal(_ pw: String) async {
        do {
            let ctx = SendableBox(try await BiometricGate.authenticate(reason: "Show your recovery phrase"))
            _ = try await Task.detached(priority: .userInitiated) { try Vault.unlock(password: pw, context: ctx.value) }.value
            withAnimation(Theme.snappy) { unlocked = true }
            engine.phraseSaved()
        } catch BiometricGate.Failure.cancelled {
        } catch Vault.Failure.wrongPassword {
            showError = LockView.wrongPassword()
        } catch Vault.Failure.lockedOut(let until) {
            showError = "Too many wrong passwords. Try again in \(LockView.wait(until.timeIntervalSinceNow))."
        } catch {
            showError = "Couldn't check. Try again."
        }
    }

    /// Checks the password against the vault first (same counter as the lock screen), so the file can't be sealed
    /// with a typo.
    private func seal(_ pw: String) async {
        sealing = true
        defer { sealing = false }
        do {
            let ctx = SendableBox(try await BiometricGate.authenticate(reason: "Save your recovery phrase as a file"))
            _ = try await Task.detached(priority: .userInitiated) { try Vault.unlock(password: pw, context: ctx.value) }.value
            keyFile = try await KeyFile.document(engine.identity.seed, kind: .recovery, password: pw, fallbackID: engine.purchaseIDs.first)
        } catch BiometricGate.Failure.cancelled {
        } catch Vault.Failure.wrongPassword {
            note = ("That isn't your Priva password.", false)
        } catch Vault.Failure.lockedOut(let until) {
            note = ("Too many wrong passwords. Try again \(until.formatted(.relative(presentation: .named))).", false)
        } catch {
            note = (KeyFile.message(for: error), false)
        }
    }
}

/// The App Store purchase ID: part of every key file's lock. Shown (after Face ID) so it can be kept for a move to a
/// different Apple Account; it lives only on this iPhone and inside encrypted backups, never on a server.
struct PurchaseIDView: View {
    @Environment(PrivaEngine.self) private var engine
    @Environment(\.scenePhase) private var scenePhase
    @State private var unlocked = false
    @State private var ids: [String] = []
    @State private var copied: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if unlocked {
                    if ids.isEmpty {
                        Label("Priva couldn't reach the App Store yet. Open this again when you're online.", systemImage: "wifi.exclamationmark")
                            .font(.subheadline).foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(Array(ids.enumerated()), id: \.offset) { i, id in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(i == 0 ? "Latest" : "Earlier, from a backup or another Apple Account")
                                .font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                            Text(id)
                                .font(.system(.body, design: .monospaced).weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .accessibilityIdentifier("purchase.id.\(i)")
                            Button(copied == id ? "Copied" : "Copy", systemImage: copied == id ? "checkmark" : "doc.on.doc") {
                                SecurePasteboard.copy(id)
                                withAnimation(Theme.snappy) { copied = id }
                            }
                            .buttonStyle(.glass)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surface, in: .rect(cornerRadius: Theme.radius))
                    }
                    Text("Key files need this ID and your password. Keep a copy in case you change Apple Account.")
                        .font(.footnote).foregroundStyle(Theme.textSecondary)
                } else {
                    VStack(spacing: 16) {
                        HeroGlyph(systemImage: "bag.fill")
                        Text("Your purchase ID").font(.title2.weight(.bold))
                        Text("The App Store's ID for the Apple Account that bought Priva. Your key files need it.")
                            .font(.subheadline).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                        PrimaryButton(title: "Show with \(BiometricGate.kind.rawValue)", systemImage: "faceid") {
                            Task {
                                guard (try? await BiometricGate.confirm(reason: "Show your purchase ID")) != nil else { return }
                                await engine.rememberPurchase()
                                ids = engine.purchaseIDs
                                withAnimation(Theme.snappy) { unlocked = true }
                            }
                        }
                        .accessibilityIdentifier("purchase.show")
                        .padding(.top, 6)
                    }
                    .padding(.top, 40)
                }
            }
            .padding(Theme.gutter)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Purchase ID")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { unlocked = false; copied = nil; ids = [] }
        .onChange(of: scenePhase) { _, p in if p == .background { unlocked = false; ids = [] } }
    }
}

// MARK: - Network (onion routing, relay, calls)

struct NetworkSettingsView: View {
    @Environment(PrivaEngine.self) private var engine
    @State private var cfg = NetworkPrivacy.current
    @State private var portText = String(NetworkPrivacy.current.port)
    @State private var testing = false
    @State private var result: String?
    private var tor: TorService { TorService.shared }

    var body: some View {
        @Bindable var e = engine
        List {
            Section {
                Toggle(isOn: Binding(get: { cfg.onion }, set: { cfg.mode = $0 ? .tor : .direct })) {
                    SettingsRow(title: "Onion routing", systemImage: "circle.hexagongrid.fill", color: .indigo)
                }
                if cfg.mode == .tor { LabeledContent("Status") { status } }
                if cfg.onion && ManagedRelay.servers.isEmpty && engine.settings.turnURL.isEmpty {
                    // Tor mode is relay-only: without a relay, chats and calls wait rather than show friends our IP.
                    WarningNote(text: "No relay is available, so chats and calls wait instead of showing friends your IP.")
                }
                if cfg.onion {
                    Toggle("Use my own SOCKS5 proxy", isOn: Binding(get: { cfg.mode == .proxy }, set: { cfg.mode = $0 ? .proxy : .tor }))
                    if cfg.mode == .proxy {
                        TextField("Host", text: $cfg.host).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        TextField("Port", text: $portText).keyboardType(.numberPad)
                            .onChange(of: portText) { _, v in cfg.port = Int(v.filter(\.isNumber)) ?? 0 }
                    }
                    Button(testing ? "Testing…" : "Test connection") { Task { await test() } }.disabled(testing)
                    if let result { Text(result).font(.footnote).foregroundStyle(Theme.textSecondary) }
                }
            } footer: {
                Text("Hides your IP with Tor. Slower, and offline if Tor is down. Chats and calls use Priva's relay.")
            }
            .listRowBackground(Theme.surface)

            Section {
                Picker(selection: $e.settings.videoQuality) {
                    Text("Data saver").tag(540)
                    Text("Balanced").tag(720)
                    Text("Best").tag(1080)
                } label: { SettingsRow(title: "Video quality", systemImage: "video.fill", color: Theme.mint) }
                NavigationLink { RelaySettingsView() } label: {
                    SettingsRow(title: "Relay server", systemImage: "server.rack", color: .gray,
                                value: engine.settings.turnURL.isEmpty && ManagedRelay.servers.isEmpty ? "None"
                                    : (engine.settings.relayCalls || cfg.onion ? "On" : "If needed"))
                }
            } header: { Text("Calls") } footer: {
                Text("Direct calls show your IP address to the other person. A relay hides it.")
            }
            .listRowBackground(Theme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Network")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            cfg = NetworkPrivacy.current
            portText = String(cfg.port)
        }
        .animation(Theme.snappy, value: cfg)
        .onChange(of: cfg) { _, v in if v.mode != .proxy || v.isValidProxy { engine.setNetworkPrivacy(v) } }
    }

    @ViewBuilder private var status: some View {
        switch tor.state {
        case .off: Text("Off").foregroundStyle(Theme.textSecondary)
        case .starting(let p): HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Connecting \(p)%") }.foregroundStyle(Theme.textSecondary)
        case .ready: HStack(spacing: 6) { Image(systemName: "checkmark.circle.fill"); Text("Connected") }.foregroundStyle(Theme.mint)
        case .failed(let m): Text(m).foregroundStyle(Theme.rose)
        }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        let t0 = Date()
        do {
            _ = try await PrivaAPI.shared.issuerPublicKey()
            result = String(format: "Reached Priva in %.1f s.", Date().timeIntervalSince(t0))
        } catch {
            result = cfg.mode == .tor && !tor.isReady ? "Tor is still connecting." : "Couldn't reach Priva on this route."
        }
    }
}

struct RelaySettingsView: View {
    @Environment(PrivaEngine.self) private var engine
    var body: some View {
        @Bindable var e = engine
        List {
            Section {
                TextField("turn:relay.example.com:3478", text: $e.settings.turnURL).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("Username", text: $e.settings.turnUsername).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Credential", text: $e.settings.turnCredential)
            } header: { Text("Your own TURN server") } footer: {
                Text(ManagedRelay.servers.isEmpty ? "Your own relay. It only ever sees encrypted traffic."
                     : "Optional. Any relay only sees encrypted traffic.")
            }
            .listRowBackground(Theme.surface)
            Section {
                Toggle("Relay all calls", isOn: $e.settings.relayCalls)
                    .disabled(engine.settings.turnURL.isEmpty && ManagedRelay.servers.isEmpty)
            } footer: {
                Text(NetworkPrivacy.current.onion ? "Always on while onion routing is on."
                     : "On: never a direct connection; without a relay, Priva waits. Off: the relay only if direct fails.")
            }
            .listRowBackground(Theme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Relay server")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Appearance

struct AppearanceView: View {
    @AppStorage(Appearance.storageKey) private var appearance = Appearance.system.rawValue

    var body: some View {
        ScrollView {
            HStack(spacing: 14) {
                ForEach(Appearance.allCases) { a in
                    let selected = appearance == a.rawValue
                    Button { withAnimation(Theme.snappy) { appearance = a.rawValue } } label: {
                        VStack(spacing: 10) {
                            preview(a)
                                .frame(height: 170)
                                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(selected ? Theme.violet : Theme.hairline, lineWidth: selected ? 3 : 1))
                            Text(a.label).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                                .lineLimit(1).minimumScaleFactor(0.5)        // never "Ligh t" at large sizes
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .font(.title3).foregroundStyle(selected ? Theme.violet : Theme.textTertiary)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(a.label)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(Theme.gutter)
            .sensoryFeedback(.selection, trigger: appearance)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// A tiny chat mock-up rendered in the given scheme ("Automatic" shows half and half).
    @ViewBuilder private func preview(_ a: Appearance) -> some View {
        Group {
            switch a {
            case .system:
                HStack(spacing: 0) {
                    mock.environment(\.colorScheme, .light)
                    mock.environment(\.colorScheme, .dark)
                }
            case .light: mock.environment(\.colorScheme, .light)
            case .dark: mock.environment(\.colorScheme, .dark)
            }
        }
        .clipShape(.rect(cornerRadius: 18, style: .continuous))
    }

    private var mock: some View {
        VStack(alignment: .leading, spacing: 7) {
            Capsule().fill(Theme.incomingBubble).frame(width: 46, height: 14)
            Capsule().fill(Theme.aurora).frame(width: 38, height: 14).frame(maxWidth: .infinity, alignment: .trailing)
            Capsule().fill(Theme.incomingBubble).frame(width: 30, height: 14)
            Spacer()
            Capsule().fill(Theme.surface).frame(height: 16)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}

// MARK: - Storage

struct StorageView: View {
    @Environment(PrivaEngine.self) private var engine
    @State private var media: UInt64?
    @State private var messages: Int?
    @State private var backups: Int64?

    var body: some View {
        List {
            Section {
                LabeledContent("Messages") { value(messages.map { "\($0)" }) }
                LabeledContent("Photos, videos & files") { value(media.map { Format.bytes($0) }) }
                LabeledContent("Backups on this iPhone") { value(backups.map { Format.bytes(UInt64($0)) }) }
            } footer: {
                Text("Everything here is encrypted on this iPhone.")
            }
            .listRowBackground(Theme.surface)
            Section {
                HStack(alignment: .top, spacing: 14) {
                    IconTile(systemImage: "clock.badge.xmark.fill", color: .orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Group media is kept for 90 days").foregroundStyle(Theme.textPrimary)
                        Text("After that it's deleted from this iPhone. Save anything you want to keep to Photos.")
                            .font(.footnote).foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(Theme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let store = engine.store
            let r = await Task.detached(priority: .utility) {
                (store.storageBytes(), store.messageCount(),
                 BackupLocations.list().filter { $0.location == .device }.reduce(Int64(0)) { $0 + $1.size })
            }.value
            withAnimation(Theme.snappy) { (media, messages, backups) = r }
        }
    }

    @ViewBuilder private func value(_ s: String?) -> some View {
        if let s { Text(s).foregroundStyle(Theme.textSecondary).monospacedDigit() } else { ProgressView().controlSize(.small) }
    }
}

// MARK: - How it works

struct HowItWorksView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                FeatureRow(icon: "bag.fill", title: "Anonymous purchase", detail: "Your purchase becomes a blind-signed token that can't be linked to your username.")
                FeatureRow(icon: "dice.fill", title: "Random username", detail: "Created on your iPhone. The server keeps only a one-way hash of it.", tint: Theme.cyan)
                FeatureRow(icon: "atom", title: "Post-quantum encryption", detail: "Two layers of quantum-safe encryption.", tint: Theme.mint)
                FeatureRow(icon: "point.3.connected.trianglepath.dotted", title: "Peer-to-peer", detail: "Messages, files and calls go phone to phone. Servers never see their content.")
                FeatureRow(icon: "person.3.fill", title: "Groups without a server", detail: "The group's host relays encrypted traffic. Priva's servers never see a group.", tint: Theme.cyan)
                FeatureRow(icon: "faceid", title: "Two-factor lock", detail: "Your data opens only with your password and your face.", tint: Theme.mint)
                FeatureRow(icon: "lock.icloud.fill", title: "Sealed backups", detail: "Encrypted with your Backup Key and password. Apple and Priva can't open them.")
                FeatureRow(icon: "circle.hexagongrid.fill", title: "Onion routing", detail: "Optional Tor hides your IP address from Priva's servers.", tint: Theme.cyan)
                FeatureRow(icon: "arrow.triangle.2.circlepath", title: "Keys that move forward", detail: "Keys change after every conversation.", tint: Theme.mint)
            }
            .padding(Theme.gutter)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("How Priva protects you")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Diagnostics (development builds)

#if DEBUG
struct DiagnosticsView: View {
    @Environment(PrivaEngine.self) private var engine
    @State private var results: [(String, String)] = []
    @State private var running = false

    var body: some View {
        List {
            // What's in memory right now: the device journeys read these.
            Section("Memory") {
                LabeledContent("Footprint", value: String(format: "%.0f MB", LiveObjects.footprintMB))
                    .accessibilityIdentifier("diag.memory")
                LabeledContent("Decoded photos", value: "\(MediaVault.shared.debugDecoded)")
                    .accessibilityIdentifier("diag.decoded")
                // One line for the journeys to parse: "CallCenter=1 PeerLink=2 PrivaEngine=1 …".
                LabeledContent("Live objects", value: LiveObjects.snapshot.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
                    .font(.caption.monospaced())
                    .accessibilityIdentifier("diag.live")
            }
            Section("Connection") {
                LabeledContent("Rendezvous", value: engine.realtimeStatus == .connected ? "Connected (TLS 1.3)" : "Connecting")
                LabeledContent("Last PQ handshake", value: engine.diagnostics.lastHandshakeMs.map { String(format: "%.0f ms", $0) } ?? "-")
                LabeledContent("Encrypted round-trip", value: engine.diagnostics.lastRoundTripMs.map { String(format: "%.1f ms", $0) } ?? "-")
                LabeledContent("Signals sent / received", value: "\(engine.diagnostics.signalsSent) / \(engine.diagnostics.signalsReceived)")
                LabeledContent("Rejected envelopes", value: "\(engine.diagnostics.rejectedEnvelopes)")
                LabeledContent("Relay passes", value: "\(RelayPass.stored.count)")
                LabeledContent("Relay answers", value: PrivaAPI.debugBroadcastStats.filter { !$0.key.hasPrefix("bytes:") }
                    .sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
                    .font(.footnote.monospacedDigit())
            }
            Section("On-device crypto benchmark") {
                ForEach(results, id: \.0) { r in LabeledContent(r.0, value: r.1).font(.subheadline.monospacedDigit()) }
                Button(running ? "Running…" : "Run benchmark", systemImage: "speedometer") { Task { await bench() } }.disabled(running)
            }
        }
        .navigationTitle("Diagnostics")
    }

    private func bench() async {
        running = true
        defer { running = false }
        results = await Task.detached(priority: .userInitiated) { () -> [(String, String)] in
            func time(_ n: Int, _ body: () throws -> Void) -> Double {
                let t = DispatchTime.now().uptimeNanoseconds
                for _ in 0..<n { try? body() }
                return Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6 / Double(n)
            }
            var out: [(String, String)] = []
            let bob = try! KEMPrivatePair.generate()
            out.append(("DualSeal (X-Wing + ML-KEM-1024)", String(format: "%.2f ms", time(50) { _ = try DualSeal.seal(Data(count: 256), to: bob.publicPair, aad: Data()) })))
            let root = Bytes.random(64)
            out.append(("Full session handshake", String(format: "%.2f ms", time(30) {
                let i = try Handshake.Initiator(me: "a", peer: "b", root: root)
                let r = try Handshake.Responder(me: "b", peer: "a", root: root, hello: i.hello)
                let (f, _) = try i.finish(with: r.ack)
                _ = try r.complete(with: f)
            })))
            let id = try! IdentityKeys(seed: IdentityKeys.newSeed())
            out.append(("Hybrid signature (Ed25519 + ML-DSA-65)", String(format: "%.2f ms", time(50) { _ = try id.signing.sign(Data(count: 64)) })))
            let key = DualKey(Bytes.random(64)), block = Bytes.random(1 << 20)
            let ms = time(32) { _ = try DualAEAD.seal(block, key: key, nonce: Data(count: 12), aad: Data()) }
            out.append(("Dual AEAD throughput", String(format: "%.0f MB/s", 1000 / ms)))
            let fkey = SymmetricKey(size: .bits256)
            let header = FileCipherHeader(chunkSize: FileCipherHeader.defaultChunk, plainSize: 1 << 20, nonceSalt: Bytes.random(4))
            let chunk = Bytes.random(FileCipherHeader.defaultChunk)
            let fms = time(64) { _ = try FileCipher.sealChunk(chunk, index: 0, header: header, key: fkey) }
            out.append(("File encryption throughput", String(format: "%.0f MB/s", Double(FileCipherHeader.defaultChunk) / 1_048_576 * 1000 / fms)))
            out.append(("Username commitment (scrypt 64 MiB)", String(format: "%.0f ms", time(1) { _ = UsernameKey.derive(Username.random()) })))
            out.append(("Password KDF (scrypt 64 MiB)", String(format: "%.0f ms", time(1) { _ = try PasswordKDF.derive("benchmark", salt: Bytes.random(16)) })))
            out.append(("Backup Key → PQ key pair (scrypt 64 MiB)", String(format: "%.0f ms", time(1) { _ = try BackupKey.generate().keyPair() })))
            return out
        }.value
    }
}
#endif
