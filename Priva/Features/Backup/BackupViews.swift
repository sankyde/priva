import LocalAuthentication
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Settings › Backup

struct BackupSettingsView: View {
    @Environment(PrivaEngine.self) private var engine
    @State private var settingUp = false
    @State private var restoring = false
    @State private var confirmOff = false
    @State private var askICloud = false
    @State private var checkingKey = false
    @State private var latest: URL?

    private var center: BackupCenter { engine.backup }
    /// Newest first; the copy on this iPhone rather than iCloud's (which may still be uploading).
    private func rankLocal(_ f: BackupFile) -> (Double, Int) { (-f.header.created.timeIntervalSince1970, f.location == .device ? 0 : 1) }

    var body: some View {
        List {
            if let c = center.config {
                Section {
                    statusCard(c)
                        .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
                }
                .listRowBackground(Theme.surface)
                Section {
                    Toggle(isOn: Binding(get: { c.icloud }, set: { on in if on { askICloud = true } else { center.setICloud(false) } })) {
                        SettingsRow(title: "iCloud", systemImage: "icloud.fill", color: .blue)
                    }
                    Toggle(isOn: Binding(get: { c.automatic }, set: { center.setAutomatic($0) })) {
                        SettingsRow(title: "Back up daily", systemImage: "clock.arrow.circlepath", color: Theme.mint)
                    }
                    Toggle(isOn: Binding(get: { c.includeMedia == true }, set: { center.setIncludeMedia($0) })) {
                        SettingsRow(title: "Include photos & files", systemImage: "photo.on.rectangle", color: .pink)
                    }
                } footer: {
                    if c.icloud && !center.icloudAvailable {
                        Text("iCloud Drive is off, so backups stay on this iPhone. Turn it on in the Settings app.")
                            .foregroundStyle(Theme.amber)
                    } else if c.icloud, let issue = c.icloudIssue {
                        Text(issue).foregroundStyle(Theme.amber)
                    } else {
                        Text((c.includeMedia == true ? "Messages, photos and files: much bigger. " : "Messages only: photos and files aren't backed up. ")
                             + (c.icloud ? "Stored in iCloud Drive." : "Kept on this iPhone only."))
                    }
                }
                .listRowBackground(Theme.surface)
                Section {
                    Button { checkingKey = true } label: { SettingsRow(title: "Check my Backup Key", systemImage: "checkmark.shield.fill", color: .indigo) }
                    if let latest {
                        // For a new iPhone without the same iCloud: AirDrop it, or save it to Files or a drive.
                        ShareLink(item: latest) { SettingsRow(title: "Save a copy…", systemImage: "square.and.arrow.up", color: .teal) }
                    }
                    Button { restoring = true } label: { SettingsRow(title: "Restore from a backup", systemImage: "arrow.counterclockwise", color: .orange) }
                } footer: {
                    if latest != nil { Text("A copy opens only with your Backup Key, password and iCloud Keychain.") }
                }
                .listRowBackground(Theme.surface)
                Section {
                    Button("Turn off backups", role: .destructive) { confirmOff = true }
                        .confirmationDialog("Turn off backups?", isPresented: $confirmOff, titleVisibility: .visible) {
                            Button("Turn off and delete backups", role: .destructive) { center.turnOff(deleteFiles: true) }
                            Button("Turn off, keep existing backups") { center.turnOff(deleteFiles: false) }
                        }
                }
                .listRowBackground(Theme.surface)
            } else {
                Section {
                    VStack(spacing: 16) {
                        HeroGlyph(systemImage: "lock.icloud.fill")
                        Text("Encrypted backup").font(.title2.weight(.bold))
                        Text("Lose your iPhone, keep your chats. Only you can open a backup.")
                            .font(.subheadline).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                        PrimaryButton(title: "Turn on backups", systemImage: "arrow.up.circle.fill") { settingUp = true }
                            .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .listRowBackground(Color.clear)
                }
                Section {
                    FeatureRow(icon: "key.horizontal.fill", title: "Your own Backup Key",
                               detail: "24 words only you have. Nobody else can open your backup: not Apple, not Priva.")
                    FeatureRow(icon: "atom", title: "Post-quantum encryption",
                               detail: "Two independent layers, sealed on this iPhone before anything is stored.", tint: Theme.cyan)
                    FeatureRow(icon: "faceid", title: "Opens only with you",
                               detail: "Restoring needs your Backup Key, your password and Face ID.", tint: Theme.mint)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                Section {
                    Button { restoring = true } label: { SettingsRow(title: "Restore from a backup", systemImage: "arrow.counterclockwise", color: .orange) }
                }
                .listRowBackground(Theme.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Backup")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $settingUp) { BackupSetupView().environment(engine) }
        .sheet(isPresented: $restoring) { BackupRestoreView(mode: .settings).environment(engine) }
        .sheet(isPresented: $checkingKey) { BackupKeyCheckView().environment(engine) }
        .alert("Store backups in iCloud?", isPresented: $askICloud) {
            Button("Not now", role: .cancel) {}
            Button("Allow") { center.setICloud(true); Task { await center.backUpNow() } }
        } message: {
            Text("Backups are encrypted on this iPhone before they're uploaded. Apple can't open them.")
        }
        .task(id: center.config?.lastBackup) {
            await center.refreshList()
            let hint = center.config?.hint
            latest = center.files.filter { $0.header.keyHint == hint }.sorted { rankLocal($0) < rankLocal($1) }.first?.url
        }
    }

    @ViewBuilder private func statusCard(_ c: BackupConfig) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                IconTile(systemImage: "checkmark.icloud.fill", color: Theme.mint, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Backups are on").font(.headline)
                    Text(lastText(c)).font(.subheadline).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }
            switch center.phase {
            case .working(let p):
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: p).tint(Theme.violet)
                    Text("Encrypting… \(Int(p * 100))%").font(.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                }
            case .failed(let m):
                Label(m, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(Theme.rose)
                backUpButton
            case .idle:
                backUpButton
            }
            HStack(spacing: 6) {
                Image(systemName: "key.horizontal")
                Text("Backup Key \(Text(c.hint).monospaced())")
                if c.usesKeychain { Text("· iCloud Keychain") }
            }
            .font(.caption)
            .foregroundStyle(Theme.textTertiary)
        }
    }

    private var backUpButton: some View {
        PrimaryButton(title: "Back up now", systemImage: "arrow.up.circle.fill") { Task { await center.backUpNow() } }
    }

    private func lastText(_ c: BackupConfig) -> String {
        guard let last = c.lastBackup else { return "No backup yet" }
        let size = c.lastSize.map { " · " + Format.bytes(UInt64($0)) } ?? ""
        return "Last backup " + last.formatted(.relative(presentation: .named)) + size
    }
}

// MARK: - Setup

struct BackupSetupView: View {
    @Environment(PrivaEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    enum Step: Hashable { case location, password, reveal, done }
    @State private var step: Step = .location
    @State private var icloud = true
    @State private var password = ""
    @State private var key: BackupKey?
    @State private var pending: BackupConfig?
    @State private var busy = false
    @State private var error: String?
    @State private var screenshot = false
    /// Held only while the key is on screen: the optional key file is sealed with it.
    @State private var filePassword = ""
    @FocusState private var pwFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .location: locationStep
                case .password: passwordStep
                case .reveal: revealStep
                case .done: doneStep
                }
            }
            .animation(Theme.snappy, value: step)
            .background(Theme.background.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if step != .done {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", systemImage: "xmark") { cancel() } }
                }
            }
        }
        .hiddenWhileCaptured()
        .interactiveDismissDisabled(step == .reveal)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            if step == .reveal { screenshot = true }
        }
    }

    private func cancel() {
        key = nil
        pending = nil
        filePassword = ""
        dismiss()
    }

    private func activate() {
        guard let pending else { return }
        error = nil
        key = nil
        filePassword = ""
        engine.backup.activate(pending)
        self.pending = nil
        step = .done
        Task { await engine.backup.backUpNow() }
    }

    private var locationStep: some View {
        OnboardingScaffold(title: "Where to keep backups", subtitle: "Backups are encrypted on this iPhone before they're stored anywhere.") {
            VStack(spacing: 12) {
                choice(true, "iCloud", "Survives losing or replacing your iPhone.", "icloud.fill")
                choice(false, "This iPhone only", "Lost if this iPhone is lost or erased.", "iphone")
            }
        } footer: {
            PrimaryButton(title: "Continue") { step = .password }
        }
    }

    private func choice(_ value: Bool, _ title: String, _ detail: String, _ icon: String) -> some View {
        Button { icloud = value } label: {
            HStack(spacing: 14) {
                IconTile(systemImage: icon, color: value ? .blue : Theme.textSecondary, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundStyle(Theme.textPrimary)
                    Text(detail).font(.subheadline).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Image(systemName: icloud == value ? "checkmark.circle.fill" : "circle")
                    .font(.title2).foregroundStyle(icloud == value ? Theme.violet : Theme.textTertiary)
            }
            .padding(16)
            .background(Theme.surface, in: .rect(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(icloud == value ? Theme.violet : Theme.hairline, lineWidth: icloud == value ? 1.5 : 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(icloud == value ? .isSelected : [])
    }

    private var passwordStep: some View {
        OnboardingScaffold(title: "Confirm it's you", subtitle: "Your password becomes part of the backup's lock. You'll need it to restore.") {
            PasswordField(title: "Priva password", text: $password, focused: $pwFocused) { Task { await confirmPassword() } }
            if let error { Text(error).font(.footnote.weight(.medium)).foregroundStyle(Theme.rose) }
        } footer: {
            PrimaryButton(title: "Continue with \(BiometricGate.kind.rawValue)", loading: busy, enabled: !password.isEmpty) {
                Task { await confirmPassword() }
            }
        }
        .onAppear {
            pwFocused = true
            #if DEBUG
            if let pw = DebugAutomation.testPassword, password.isEmpty { password = pw }
            #endif
        }
    }

    private func confirmPassword() async {
        busy = true
        defer { busy = false }
        error = nil
        do {
            let ctx = SendableBox(try await BiometricGate.authenticate(reason: "Turn on encrypted backups"))
            let pw = password
            _ = try await Task.detached(priority: .userInitiated) { try Vault.unlock(password: pw, context: ctx.value) }.value
            (key, pending) = try await engine.backup.prepare(password: pw, icloud: icloud)
            filePassword = pw
            #if DEBUG
            if DebugAutomation.testPassword != nil { DebugAutomation.backupKey = key?.words.joined(separator: " ") }
            #endif
            password = ""
            step = .reveal
        } catch BiometricGate.Failure.cancelled {
        } catch Vault.Failure.wrongPassword {
            error = "That isn't your Priva password."
        } catch {
            self.error = "Couldn't set up backups. Try again."
        }
    }

    private var revealStep: some View {
        OnboardingScaffold(title: "Your Backup Key", subtitle: "Shown only once. Write it down or save it as a file.") {
            WordGrid(words: key?.words ?? [])
                .accessibilityIdentifier("backup.words")
            Label("Without it, nobody can open your backups, not even you.", systemImage: "exclamationmark.shield.fill")
                .font(.footnote).foregroundStyle(Theme.textSecondary)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.amber.opacity(0.1), in: .rect(cornerRadius: 14))
            if screenshot {
                Label("Screenshot taken. Delete it from Photos.", systemImage: "camera.metering.unknown")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.rose)
            }
        } footer: {
            if let key {
                KeepKeyButtons(kind: .backup, secret: key.entropy, password: filePassword, fallbackID: engine.purchaseIDs.first) {
                    activate()
                }
            }
        }
    }

    private var doneStep: some View {
        VStack(spacing: 18) {
            Spacer()
            HeroGlyph(systemImage: "checkmark.shield.fill", color: Theme.mint)
            Text("Backups are on").font(.title.weight(.bold))
            Text("Your first backup is being encrypted now. Priva backs up once a day while it's open.")
                .font(.body).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center).padding(.horizontal, 32)
            Spacer()
            PrimaryButton(title: "Done") { dismiss() }.padding(.horizontal, Theme.gutter).padding(.bottom, 12)
        }
        .sensoryFeedback(.success, trigger: step)
    }
}

// MARK: - Check the Backup Key (without restoring)

struct BackupKeyCheckView: View {
    @Environment(PrivaEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var result: Bool?
    @State private var busy = false
    @State private var importing = false

    var body: some View {
        NavigationStack {
            OnboardingScaffold(title: "Check your Backup Key", subtitle: "Type the 24 words or open the key file to check it still works.") {
                PhraseInput(text: $text)
                OpenKeyFileButton(kind: .backup) { importing = true }
                if let result {
                    Label(result ? "That's your Backup Key." : "That key doesn't match your backups.",
                          systemImage: result ? "checkmark.seal.fill" : "xmark.octagon.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(result ? Theme.mint : Theme.rose)
                }
            } footer: {
                PrimaryButton(title: "Check", loading: busy, enabled: PhraseInput.words(text).count == 24) {
                    Task {
                        busy = true
                        defer { busy = false }
                        guard let k = try? BackupKey(text: text) else { result = false; return }
                        result = await engine.backup.matches(k)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", systemImage: "xmark") { dismiss() } } }
            .keyFileImporter(isPresented: $importing, kind: .backup, savedIDs: engine.purchaseIDs) { entropy in
                result = nil
                text = BackupKey(entropy: entropy).words.joined(separator: " ")
            }
        }
    }
}

// MARK: - Restore

struct BackupRestoreView: View {
    enum Mode { case settings, onboarding }
    let mode: Mode
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    enum Step: Equatable { case search, key(BackupFile), confirm }
    @State private var step: Step = .search
    @State private var files: [BackupFile] = []
    @State private var searching = true
    @State private var status = "Searching…"
    @State private var picking = false
    @State private var phrase = ""
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false
    @State private var staged: BackupRestore.Staged?
    @State private var chosen: BackupFile?
    @State private var throttle: TimeInterval = 0
    @State private var importingKey = false
    @FocusState private var pwFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .search: searchStep
                case .key(let f): keyStep(f)
                case .confirm: confirmStep
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(step == .search ? "Find your backup" : "Restore")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // On the key step Back takes the leading spot, so Cancel moves to the trailing one (one button each side).
                ToolbarItem(placement: isKeyStep ? .primaryAction : .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") {
                        if let staged { BackupRestore.discard(staged) }
                        dismiss()
                    }
                }
                if case .key = step {
                    ToolbarItem(placement: .navigation) {
                        Button("Back", systemImage: "chevron.left") { error = nil; step = .search }
                    }
                }
            }
        }
        .hiddenWhileCaptured()
        .interactiveDismissDisabled(busy || staged != nil)
        .task { await search() }
    }

    private var isKeyStep: Bool { if case .key = step { return true } else { return false } }

    // MARK: search

    /// Automatic search of iCloud Drive and this iPhone. Nothing is ever picked for the user: with several
    /// backups (or one), they choose; anything else can be found with Browse Files.
    private func search() async {
        searching = true
        error = nil
        let found = await BackupLocations.search { s in Task { @MainActor in status = s } }
        withAnimation(Theme.snappy) {
            files = found
            searching = false
        }
    }

    private var searchStep: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    HeroGlyph(systemImage: searching ? "magnifyingglass" : (files.isEmpty ? "questionmark.folder.fill" : "tray.full.fill"),
                              color: files.isEmpty && !searching ? Theme.textSecondary : Theme.violet)
                    Text(searching ? status : files.isEmpty ? "No backups found" : files.count == 1 ? "1 backup found" : "\(files.count) backups found")
                        .font(.headline)
                        .accessibilityIdentifier("restore.status")
                    Text(searching ? "Looking in iCloud Drive and on this iPhone."
                         : files.isEmpty ? "Nothing in iCloud Drive or on this iPhone. Elsewhere? Browse for it."
                         : "Choose the one to restore. The newest is usually the one you want.")
                        .font(.subheadline).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                    if searching { ProgressView().padding(.top, 4) }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }
            if !searching {
                let newest = files.first?.header.id
                ForEach([BackupFile.Location.icloud, .device, .received], id: \.self) { loc in
                    let here = files.filter { $0.location == loc }
                    if !here.isEmpty {
                        Section(Self.label(loc)) { ForEach(here) { row($0, newest: $0.header.id == newest) } }
                            .listRowBackground(Theme.surface)
                    }
                }
            }
            Section {
                Button { picking = true } label: { SettingsRow(title: "Browse Files…", systemImage: "folder.fill", color: .blue) }
                    .accessibilityIdentifier("restore.browse")
                if !searching {
                    Button { Task { await search() } } label: { SettingsRow(title: "Search again", systemImage: "arrow.clockwise", color: .gray) }
                }
            } footer: {
                if let error { Text(error).foregroundStyle(Theme.rose) }
                else { Text("Finding a backup doesn't open it. That takes its Backup Key and your password.") }
            }
            .listRowBackground(Theme.surface)
        }
        .scrollContentBackground(.hidden)
        // On this step only: SwiftUI presents one file importer per hierarchy, and the key step has its own.
        .fileImporter(isPresented: $picking, allowedContentTypes: [UTType(exportedAs: "com.sanketdesai.priva.backup"), .data]) { result in
            guard case .success(let url) = result else { return }
            choosePicked(url)
        }
    }

    static func label(_ l: BackupFile.Location) -> String {
        switch l {
        case .icloud: "iCloud Drive"
        case .device: "On this iPhone"
        case .received: "Received files"
        case .picked: "Chosen file"
        }
    }

    private func row(_ f: BackupFile, newest: Bool) -> some View {
        Button { error = nil; chosen = f; step = .key(f) } label: {
            HStack(spacing: 14) {
                IconTile(systemImage: f.location == .icloud ? "icloud.fill" : f.location == .device ? "iphone" : "tray.and.arrow.down.fill",
                         color: f.location == .icloud ? .blue : .gray, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(f.header.created.formatted(date: .abbreviated, time: .shortened)).font(.headline).foregroundStyle(Theme.textPrimary)
                        if newest {
                            Text("Newest").font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Theme.mint.opacity(0.18), in: .capsule).foregroundStyle(Theme.mint)
                        }
                    }
                    Text("\(f.header.created.formatted(.relative(presentation: .named))) · \(Format.bytes(UInt64(f.size))) · key \(f.header.keyHint)")
                        .font(.caption.monospaced()).foregroundStyle(Theme.textSecondary).lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.textTertiary)
            }
        }
        .accessibilityIdentifier("restore.file")
    }

    private func choosePicked(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        // Copy into our sandbox so the file stays readable after the picker's access ends. Only a well-formed
        // header gets further; the file is never trusted beyond that until it decrypts and authenticates.
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".privabackup")
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { throw BackupError.notABackup }
            try FileManager.default.copyItem(at: url, to: local)
            let h = try BackupReader.peek(local)
            let size = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? NSNumber)?.int64Value ?? 0
            let f = BackupFile(url: local, location: .picked, header: h, size: size)
            chosen = f
            error = nil
            step = .key(f)
        } catch {
            try? FileManager.default.removeItem(at: local)
            self.error = "That file isn't a Priva backup."
        }
    }

    // MARK: key

    private func keyStep(_ f: BackupFile) -> some View {
        OnboardingScaffold(title: "Unlock the backup",
                           subtitle: "From \(f.header.created.formatted(date: .abbreviated, time: .shortened)). Use its Backup Key or key file, and the password you had then.") {
            #if DEBUG
            Color.clear.frame(height: 0).onAppear {
                if phrase.isEmpty, let k = DebugAutomation.backupKey { phrase = k }
                if password.isEmpty, let pw = DebugAutomation.testPassword { password = pw }
            }
            #endif
            PhraseInput(text: $phrase)
            OpenKeyFileButton(kind: .backup) { importingKey = true }
            PasswordField(title: "Priva password", text: $password, focused: $pwFocused) { Task { await unlock(f) } }
            if throttle > 0 {
                Label("Too many wrong tries. Try again in \(Self.duration(throttle)).", systemImage: "hourglass")
                    .font(.footnote.weight(.medium)).foregroundStyle(Theme.amber)
            } else if let error {
                Label(error, systemImage: "exclamationmark.octagon.fill").font(.footnote.weight(.medium)).foregroundStyle(Theme.rose)
            }
        } footer: {
            PrimaryButton(title: "Unlock backup", systemImage: "lock.open.fill", loading: busy,
                          enabled: PhraseInput.words(phrase).count == 24 && !password.isEmpty && throttle <= 0) { Task { await unlock(f) } }
        }
        // The key file and the backup were sealed with the same password: one entry fills both.
        .keyFileImporter(isPresented: $importingKey, kind: .backup, password: $password, savedIDs: model.engine?.purchaseIDs ?? []) { entropy in
            error = nil
            phrase = BackupKey(entropy: entropy).words.joined(separator: " ")
        }
        .task(id: f.id) {
            // Counts down while a wait is in force (kept in the Keychain across reinstalls).
            while !Task.isCancelled {
                throttle = RestoreThrottle.wait()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    static func duration(_ s: TimeInterval) -> String {
        s >= 60 ? "\(Int((s / 60).rounded(.up))) min" : "\(Int(s.rounded(.up))) s"
    }

    private func unlock(_ f: BackupFile) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        error = nil
        guard let key = try? BackupKey(text: phrase) else { error = "Those 24 words aren't a valid Backup Key."; return }
        do {
            staged = try await BackupRestore.unlock(f.url, key: key, password: password)
            phrase = ""
            step = .confirm
        } catch let t as BackupRestore.Throttled {
            throttle = t.seconds
        } catch BackupError.wrongKey {
            throttle = RestoreThrottle.wait()
            error = "The Backup Key or password doesn't match this backup."
        } catch BackupError.needsKeychainFactor {
            error = "Turn on iCloud Keychain with the Apple Account that made this backup, then try again."
        } catch {
            self.error = "This backup is damaged or was modified, so it can't be opened."
        }
    }

    // MARK: confirm

    private var confirmStep: some View {
        let m = staged?.manifest
        // Dates inside the backup are authenticated; a newer file with the same key suggests picking that one.
        let newer = m.flatMap { m in files.filter { $0.header.keyHint == chosen?.header.keyHint && $0.header.created > m.created.addingTimeInterval(60) }.first }
        let days = m.map { Int(-$0.created.timeIntervalSinceNow / 86_400) } ?? 0
        return OnboardingScaffold(title: "Restore this account?",
                                  subtitle: mode == .settings ? "Everything on this iPhone is replaced by the backup." : "No sign-up needed: your chats, groups and friends come back.") {
            if let m, let s = staged {
                VStack(spacing: 0) {
                    summaryRow("person.crop.circle.fill", "Account", "@\(m.username)")
                    Divider().padding(.leading, 52)
                    summaryRow("calendar", "Backed up", m.created.formatted(date: .abbreviated, time: .shortened))
                    Divider().padding(.leading, 52)
                    summaryRow("bubble.left.and.bubble.right.fill", "Messages", "\(s.messages)")
                    Divider().padding(.leading, 52)
                    summaryRow("person.2.fill", "Friends · groups", "\(m.contactCount) · \(m.groupCount)")
                    Divider().padding(.leading, 52)
                    summaryRow("photo.fill", "Photos & files", m.includesMedia == false ? "Not included" : "\(s.media)")
                }
                .background(Theme.surface, in: .rect(cornerRadius: 18, style: .continuous))
                Label("You'll get a new username; friends and groups follow once your old iPhone confirms, or within 12 hours. Same password.",
                      systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
                if let newer {
                    Label("A newer backup exists (\(newer.header.created.formatted(date: .abbreviated, time: .shortened))). Go back to use it.",
                          systemImage: "exclamationmark.triangle.fill").font(.footnote.weight(.medium)).foregroundStyle(Theme.amber)
                } else if days >= 7 {
                    Label("\(days) days old: newer messages won't come back.",
                          systemImage: "clock.badge.exclamationmark").font(.footnote.weight(.medium)).foregroundStyle(Theme.amber)
                }
            }
            if let error { Text(error).font(.footnote.weight(.medium)).foregroundStyle(Theme.rose) }
        } footer: {
            VStack(spacing: 10) {
                PrimaryButton(title: "Restore with \(BiometricGate.kind.rawValue)", systemImage: BiometricGate.kind == .touchID ? "touchid" : "faceid", loading: busy) {
                    Task { await commit() }
                }
                .accessibilityIdentifier("restore.commit")
                if newer != nil {
                    Button("Choose another backup") {
                        if let staged { BackupRestore.discard(staged) }
                        staged = nil
                        step = .search
                    }
                    .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                }
            }
        }
    }

    private func summaryRow(_ icon: String, _ title: String, _ value: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.body).foregroundStyle(Theme.violet).frame(width: 24)
            Text(title).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value).font(.body.weight(.semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 14).frame(minHeight: 50)
    }

    private func commit() async {
        guard let s = staged else { return }
        busy = true
        defer { busy = false }
        error = nil
        // The restored account gets a new username, which needs this Apple Account's purchase: check it first.
        do {
            _ = try await PurchaseService.obtainToken()
        } catch PurchaseService.Failure.notPurchased {
            error = "Restoring needs Priva bought with the Apple Account on this iPhone."; return
        } catch PurchaseService.Failure.limitReached {
            error = "This purchase has made too many usernames recently. Try again next month."; return
        } catch {
            self.error = "Couldn't reach the verification service. Check your connection and try again."; return
        }
        do {
            let ctx = try await BiometricGate.authenticate(reason: "Restore your Priva backup")
            let pw = password
            staged = nil
            password = ""
            dismiss()
            do {
                try await model.restore(s, password: pw, context: ctx)
            } catch {
                BackupRestore.discard(s)
                model.restoreError = "Nothing on this iPhone was changed. Try the restore again."
            }
        } catch BiometricGate.Failure.cancelled {
        } catch {
            self.error = "\(BiometricGate.kind.rawValue) didn't work. Try again."
        }
    }
}
