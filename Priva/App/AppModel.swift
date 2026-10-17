import LocalAuthentication
import MachO
import Observation
import SwiftUI
import UIKit

@Observable
final class AppModel {
    enum Phase: Equatable { case onboarding, welcomeBack, locked, finishingSetup, unlocked, restoring }

    var phase: Phase
    var engine: PrivaEngine?
    let onboarding = OnboardingModel()
    var privacyCover = false { didSet { updateCoverWindow() } }
    var screenCaptured = false { didSet { updateCoverWindow() } }
    /// A window above everything, sheets, full-screen covers, alerts, so neither the app-switcher snapshot nor a
    /// screen recording can catch a presented screen (a view inside the app can't cover what's presented above it).
    @ObservationIgnored private var coverWindow: UIWindow?
    var integrity = IntegrityCheck.run()
    @ObservationIgnored private var backgroundedAt: Date?
    @ObservationIgnored private var captureObserver: NSObjectProtocol?
    @ObservationIgnored private var memoryObserver: NSObjectProtocol?

    init() {
        // A restore cut off by a crash or a dead battery is finished or undone before anything reads the vault.
        BackupRestore.recoverInterruptedCommit()
        // iOS usually (not guaranteed) keeps Keychain items after an app is deleted. A fresh install
        // never silently reuses them: a surviving vault means a returning user → "Welcome back".
        if !UserDefaults.standard.bool(forKey: "priva.installed") {
            UserDefaults.standard.set(true, forKey: "priva.installed")
            if Vault.exists && Vault.meta?.registered == true {
                phase = .welcomeBack
            } else {
                Self.clearLeftovers(keepingRevocation: true)
                phase = .onboarding
            }
        } else {
            phase = Vault.exists ? .locked : .onboarding
        }
        MediaPrep.purgeTemp()
        // Off the main thread: finding the iCloud folder can block for seconds on a first launch (audit STA-22).
        Task.detached(priority: .utility) { BackupLocations.removeLeftovers() }
        BackupRestore.removeAbandoned()
        screenCaptured = Self.captured(Self.screen)        // a recording that was already running when Priva opened
        // Onion mode starts Tor before anything else touches the network (onboarding and unlock
        // talk to the directory too); requests fail closed until the circuit is up.
        if NetworkPrivacy.current.mode == .tor { TorService.shared.start() }
        captureObserver = NotificationCenter.default.addObserver(forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main) { [weak self] n in
            let captured = Self.captured(n.object as? UIScreen)
            MainActor.assumeIsolated { self?.screenCaptured = captured }
        }
        memoryObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine?.trimMemory() }
        }
        #if DEBUG
        DebugAutomation.apply(to: self)
        #endif
    }

    /// Screen recording, mirroring or AirPlay. Development builds can be told to ignore it (`-PrivaIgnoreCapture YES`)
    /// so the on-device journeys can drive Priva while the phone is mirrored to a Mac; release builds always honor it.
    /// Priva's screen (one window scene). Nil only before the scene connects; `.active` checks again.
    static var screen: UIScreen? { UIApplication.shared.connectedScenes.lazy.compactMap { ($0 as? UIWindowScene)?.screen }.first }

    nonisolated static func captured(_ screen: UIScreen?) -> Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "PrivaIgnoreCapture") { return false }
        #endif
        return MainActor.assumeIsolated { screen?.isCaptured ?? false }
    }

    /// Removes stale Keychain items but keeps the tiny revocation record (lets this iPhone remove
    /// its previous username) and, in development builds, the simulated purchase.
    static func clearLeftovers(keepingRevocation: Bool) {
        let record = Vault.revocationRecord
        let token = PurchaseService.storedToken
        let devNonce = PurchaseService.developmentNonce
        let tourSeen = WelcomeTour.seen
        let throttle: Data? = try? Keychain.get(RestoreThrottle.account)
        Keychain.deleteAll()
        BiometricGate.wipe()
        if tourSeen { WelcomeTour.markSeen() }          // a reinstall isn't a first download
        if let throttle { try? Keychain.set(throttle, account: RestoreThrottle.account) }   // nor a fresh set of guesses
        if keepingRevocation, let record { Vault.storeRevocation(record) }
        if let token { try? Keychain.setCodable(token, account: "purchase.token") }
        if let devNonce { PurchaseService.developmentNonce = devNonce }
    }

    /// Returning user chose to sign back in with the vault that survived the reinstall.
    func signBackIn(previous vault: UnlockedVault) {
        onboarding.reset()
        onboarding.previous = .init(username: vault.username, identity: vault.identity)
        Keychain.delete("vault.meta")
        BiometricGate.wipe()
        onboarding.path = [.purchase]
        phase = .onboarding
    }

    /// Returning user chose not to notify anyone: remove the old name (if we can) and start over.
    func startFresh() {
        onboarding.reset()
        Self.clearLeftovers(keepingRevocation: true)
        phase = .onboarding
    }

    /// False when this iPhone's data couldn't be opened (full storage, a failed migration): the caller says so and
    /// lets the user try again, instead of spinning (audit STA-15).
    @discardableResult
    func didUnlock(_ vault: UnlockedVault) -> Bool {
        do {
            let store = try Store(vaultKey: vault.vaultKey)
            let e = PrivaEngine(vault: vault, store: store)
            engine?.close()
            engine = e
            // A restore interrupted before its new username was registered: pick up the old keys again so the
            // move can still be announced.
            if !vault.registered, onboarding.previous == nil, let prev = store.get(RestoredFrom.self, for: "restore.previous"),
               prev.username != vault.username, let id = try? IdentityKeys(seed: prev.seed) {
                onboarding.previous = .init(username: prev.username, identity: id)
                onboarding.restored = onboarding.restored ?? .init(oldUsername: prev.username, friends: e.friends.count,
                                                                   groups: store.get([String].self, for: "groups")?.count ?? 0, messages: 0)
                onboarding.abandoned = onboarding.abandoned ?? store.get(Vault.RevocationRecord.self, for: "restore.abandoned")
            }
            if let m = onboarding.pendingMigration {
                e.saveMigration(m)
                onboarding.pendingMigration = nil
            }
            if vault.registered {
                phase = .unlocked
                e.start()
            } else if onboarding.restored == nil, !OnboardingModel.phraseConfirmed {
                // Sign-up was interrupted before the recovery phrase was checked or saved: show it again first,
                // rather than finishing an account whose phrase nobody has.
                onboarding.resumeRegistration(vault: vault)
                onboarding.seed = vault.identity.seed
                onboarding.path = [.phrase]
                phase = .onboarding
            } else {
                onboarding.resumeRegistration(vault: vault)
                phase = .finishingSetup
            }
            return true
        } catch {
            phase = .locked
            return false
        }
    }

    static let storeOpenFailed = "Couldn't open your data. Free up some storage and try again."

    /// Replaces whatever is on this iPhone with a staged backup. `context` is a fresh Face ID evaluation.
    /// No sign-up: the backup's password becomes this iPhone's password, and the account continues under a new
    /// username (registered right after; friends follow automatically).
    func restore(_ staged: BackupRestore.Staged, password: String, context: LAContext) async throws {
        // The new username needs this Apple Account's purchase (an anonymous token): check before anything changes.
        // Relay passes with it, not seconds after the new username is registered (audit SEC-02).
        _ = try await PurchaseService.obtainToken()
        await RelayPass.prefetch()
        engine?.close()          // not just stop: UIKit can hold on to the object, so it's emptied too
        engine = nil
        MediaVault.shared.purge()
        phase = .restoring
        let ctx = SendableBox(context)
        // The account this iPhone had until now (if any) is being replaced: its username is removed too.
        let replaced = Vault.revocationRecord
        do {
            let v = try await Task.detached(priority: .userInitiated) {
                try BackupRestore.commit(staged, password: password, context: ctx.value)
            }.value
            let m = staged.manifest
            onboarding.reset()
            onboarding.previous = .init(username: m.username, identity: try IdentityKeys(seed: m.seed))
            onboarding.restored = .init(oldUsername: m.username, friends: m.contactCount, groups: m.groupCount, messages: staged.messages)
            if let r = replaced, r.username != m.username { onboarding.abandoned = r }
            UserDefaults.standard.set(true, forKey: "priva.installed")
            didUnlock(v)
            if let r = onboarding.abandoned { try? engine?.store.set(r, for: "restore.abandoned") }
            // A restore makes a new identity: the old phrase no longer works. Chats asks until the new one is saved.
            engine?.markPhraseUnsaved()
        } catch {
            phase = Vault.exists ? .locked : .onboarding
            throw error
        }
    }

    /// First run only (see `WelcomeTour`); also opened from Settings.
    var showTour = false
    /// Shown after the restore sheet closed (e.g. the new username couldn't be registered).
    var restoreError: String?
    /// A backup file opened in Priva (AirDrop, Files, Mail) while no account is set up: open the restore search.
    var offerRestore = false
    /// Bumped when Priva comes back from the background while locked: a Face ID approval given before leaving
    /// the app must not still be waiting for the password when someone else picks the phone up.
    var lockEpoch = 0

    /// iOS already copied the file into Documents/Inbox, where "Search for backup" finds it.
    /// A friend's username from a scanned profile code (`priva://add/<name>`): Find opens with it once unlocked.
    var pendingAdd: String?

    func received(_ url: URL) {
        if url.scheme?.lowercased() == "priva" {
            pendingAdd = Username.fromAddLink(url.absoluteString)
            return
        }
        guard url.pathExtension == BackupLocations.fileExtension else { return }
        if phase == .onboarding { offerRestore = true }
    }

    func finishRegistration() {
        guard let engine else { return }
        phase = .unlocked
        engine.start()
    }

    func lock() {
        engine?.close()          // not just stop: UIKit can hold on to the object, so it's emptied too
        engine = nil
        MediaPrep.purgeTemp()
        MediaVault.shared.purge()
        phase = Vault.exists ? .locked : .onboarding
    }

    func wipe() {
        engine?.close()          // not just stop: UIKit can hold on to the object, so it's emptied too
        engine = nil
        Vault.wipeEverything()
        UserDefaults.standard.set(true, forKey: "priva.installed")
        onboarding.reset()
        phase = .onboarding
    }

    private func updateCoverWindow() {
        let show = privacyCover || screenCaptured
        guard show else { coverWindow?.isHidden = true; coverWindow = nil; return }
        let wanted = screenCaptured ? "capture" : "privacy"
        if let w = coverWindow, w.accessibilityIdentifier == wanted { return }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let w = coverWindow ?? UIWindow(windowScene: scene)
        w.windowLevel = .alert + 1
        w.accessibilityIdentifier = wanted
        let host = UIHostingController(rootView: AnyView(screenCaptured ? AnyView(CaptureCoverView()) : AnyView(PrivacyCover())))
        host.view.backgroundColor = .clear
        w.rootViewController = host
        w.isHidden = false
        coverWindow = w
    }

    func scenePhaseChanged(_ p: ScenePhase) {
        // Any call keeps Priva unlocked in the background (audio background mode): a group call too (audit STA-03,
        // locking ended it, for everyone when hosting).
        let inCall = (engine?.calls.isInCall ?? false) || (engine?.groupCalls.isInCall ?? false)
        switch p {
        case .active:
            privacyCover = false
            screenCaptured = Self.captured(Self.screen)
            if let t = backgroundedAt, phase == .unlocked, !inCall {
                let limit = TimeInterval(engine?.settings.autoLockSeconds ?? 0)
                if Date().timeIntervalSince(t) >= limit { lock() }
            }
            // Only after the background, not .inactive: the Face ID sheet itself makes the app inactive.
            if backgroundedAt != nil, phase == .locked || phase == .welcomeBack { lockEpoch += 1 }
            backgroundedAt = nil
        case .inactive:
            privacyCover = true             // always: the app-switcher snapshot never shows content
        case .background:
            privacyCover = true
            backgroundedAt = .now
            if phase == .unlocked, !inCall, (engine?.settings.autoLockSeconds ?? 0) == 0 { lock() }
            // Not locking yet (auto-lock later): still drop decoded photos and other chats' messages. A suspended
            // app holding them is first in line for iOS to kill, and plaintext needn't wait in memory.
            if phase == .unlocked, !inCall { engine?.trimMemory() }
            if phase == .finishingSetup || phase == .locked { MediaPrep.purgeTemp() }
        @unknown default: break
        }
    }
}

/// Onboarding / registration state machine (identity v2: docs/IDENTITY_DESIGN.md).
@Observable
final class OnboardingModel {
    enum Step: Hashable { case welcome, purchase, password, biometrics, phrase, creating, signBackIn }
    enum PurchaseState: Equatable { case idle, verifying, verified, failed(String) }
    enum CreateState: Equatable { case idle, working(Int), done, failed(String) }

    /// The identity a returning user is moving away from (from a surviving vault or the phrase).
    struct PreviousIdentity {
        let username: String?
        let identity: IdentityKeys
    }

    struct RestoreSummary: Equatable {
        let oldUsername: String
        let friends: Int
        let groups: Int
        let messages: Int
    }

    var path: [Step] = []
    var purchase: PurchaseState = .idle
    /// Set while finishing a restore (the new username is registered on the "creating" screen).
    var restored: RestoreSummary?
    /// A different account this iPhone had before the restore replaced it: its username is removed as well.
    @ObservationIgnored var abandoned: Vault.RevocationRecord?
    /// Random, generated on this device; registered before it is ever shown (IDENTITY_DESIGN §2).
    private(set) var username = Username.random()
    var password = ""
    var create: CreateState = .idle
    var previous: PreviousIdentity?
    @ObservationIgnored var seed = IdentityKeys.newSeed()
    @ObservationIgnored var vault: UnlockedVault?
    @ObservationIgnored var pendingMigration: MigrationState?

    var phrase: [String] { RecoveryPhrase.encode(seed) }

    /// The new recovery phrase was checked, or saved as a key file. Until then an interrupted sign-up shows it again
    /// instead of finishing without it. A Keychain flag in Priva's own service: wiped with everything else.
    static var phraseConfirmed: Bool {
        get { (try? Keychain.get(phraseAccount)) != nil }
        set { if newValue { try? Keychain.set(Data([1]), account: phraseAccount) } else { Keychain.delete(phraseAccount) } }
    }
    private static let phraseAccount = "onboarding.phrase.ok"
    var isReturning: Bool { previous != nil }
    /// The welcome tour is for a brand-new account on a first install, never after a restore or sign-back-in.
    var shouldShowTour: Bool { previous == nil && restored == nil && !WelcomeTour.seen }

    func reset() {
        path = []
        purchase = .idle
        username = Username.random()
        password = ""
        create = .idle
        previous = nil
        restored = nil
        abandoned = nil
        seed = IdentityKeys.newSeed()
        vault = nil
        pendingMigration = nil
    }

    func verifyPurchase() async {
        guard purchase != .verifying, purchase != .verified else { return }
        purchase = .verifying
        let started = Date()
        do {
            _ = try await PurchaseService.obtainToken()
            // The month's relay passes now too, while the purchase is being proved anyway: fetched right after the
            // username is registered (as before), the same purchase proof would arrive seconds after the
            // registration, from the same address, and tie the two together (audit SEC-02). Best effort: if it
            // fails, the passes come at the first refill instead.
            await RelayPass.prefetch()
            let elapsed = Date().timeIntervalSince(started)
            if elapsed < 1.2 { try? await Task.sleep(for: .seconds(1.2 - elapsed)) }
            purchase = .verified
        } catch PurchaseService.Failure.notPurchased {
            purchase = .failed("We couldn't find a purchase of Priva for this Apple Account.")
        } catch PurchaseService.Failure.limitReached {
            purchase = .failed("This purchase has created too many usernames recently. Please try again next month.")
        } catch {
            purchase = .failed("Couldn't reach the verification service. Check your connection and try again.")
        }
    }

    /// Creates the vault (password + Face ID). Called right after a successful biometric evaluation.
    func createVault(context: LAContext) async throws {
        let name = username, pw = password, s = seed
        let ctx = SendableBox(context)
        // scrypt (password) + scrypt (username commitment) + Secure Enclave work run off the main thread.
        let v = try await Task.detached(priority: .userInitiated) {
            try Vault.create(username: name, password: pw, seed: s, context: ctx.value)
        }.value
        vault = v
        Self.phraseConfirmed = false
        // Kept until registration starts: the recovery phrase step can seal it into a key file.
    }

    func resumeRegistration(vault: UnlockedVault) {
        self.vault = vault
        username = vault.username
        create = .idle
    }

    /// Registers the random username with the anonymous token, then prepares the migration work
    /// (friend announcement + removal of the previous username) and erases the purchase trail.
    func register() async {
        guard var v = vault else { create = .failed("Missing vault"); return }
        password = ""
        create = .working(0)
        try? await Task.sleep(for: .milliseconds(350))
        create = .working(1)
        do {
            var token = try await PurchaseService.obtainToken()
            // Random delay: registration is not issued in lock-step with the purchase check.
            try? await Task.sleep(for: .milliseconds(Int.random(in: 400...1500)))
            var attempt = 0
            var freshToken = false
            while true {
                do {
                    try await PrivaAPI.shared.register(ucommit: v.bundle.ucommit, bundle: v.bundle, token: token,
                                                       revokeHash: v.identity.revokeHash)
                    break
                } catch APIError.http(409, let code) where code == "username_taken" && attempt < 4 {
                    // Taken by this phone itself? A launch killed after the server accepted the name but before the
                    // phone recorded it: the entry carries our own keys, so the registration is simply done.
                    if let entry = try? await PrivaAPI.shared.lookup(v.username), let b = entry.bundle,
                       b.verifying.ed.rawRepresentation == v.identity.signing.verifying.ed.rawRepresentation { break }
                    // Astronomically unlikely with 43 bits, but handled: draw another random name.
                    attempt += 1
                    let fresh = Username.random()
                    let identity = v.identity
                    let bundle = try await Task.detached { try Vault.changeUnregisteredUsername(to: fresh, identity: identity) }.value
                    v = UnlockedVault(username: fresh, vaultKey: v.vaultKey, identity: identity, bundle: bundle, registered: false)
                    vault = v
                    username = fresh
                } catch APIError.http(409, let code) where code == "token_spent" && !freshToken {
                    // The token went with an earlier, interrupted try: one fresh token (the same purchase check).
                    freshToken = true
                    PurchaseService.purge()
                    token = try await PurchaseService.obtainToken()
                }
            }
            // Saved before the vault says "registered": if iOS kills Priva on the next screen, the friend notices and
            // the old username's removal still happen after the next unlock (audit STA-14).
            let migration = await buildMigration(newVault: v)
            if let store = try? Store(vaultKey: v.vaultKey) { try? store.set(migration, for: "migration") }
            try Vault.markRegistered(bundle: v.bundle)
            create = .working(2)
            pendingMigration = migration
            // This device can later remove THIS username after a reinstall, even without the password.
            Vault.storeRevocation(.init(username: v.username, ucommit: v.bundle.ucommit, secret: v.identity.revokeSecret))
            PurchaseService.purge()
            try? await Task.sleep(for: .milliseconds(400))
            create = .done
        } catch PurchaseService.Failure.limitReached {
            create = .failed("This purchase has created too many usernames recently. Try again next month.")
        } catch {
            create = .failed("Registration failed. Check your connection and try again.")
        }
    }

    private func buildMigration(newVault v: UnlockedVault) async -> MigrationState {
        await Self.migration(from: previous, to: v, record: Vault.revocationRecord, abandoned: abandoned)
    }

    /// What a returning user owes the world after registering a new username: a signed announcement for
    /// friends (and for the old iPhone, if it still runs Priva), and, later, removal of the previous username.
    static func migration(from prev: PreviousIdentity?, to v: UnlockedVault, record: Vault.RevocationRecord?,
                          abandoned: Vault.RevocationRecord? = nil) async -> MigrationState {
        var m = MigrationState()
        if let prev {
            let old = prev.identity, oldName = prev.username ?? ""
            let newName = v.username, bundle = v.bundle
            if let env = try? Announcement.make(old: old, oldUsername: oldName, newUsername: newName, newBundle: bundle,
                                                displayName: nil, generation: Int(Date().timeIntervalSince1970)) {
                m.announcements.append(.init(topic: Announcement.topic(announceKey: old.announceKey), envelope: env,
                                             until: Date().addingTimeInterval(30 * 86_400),
                                             formerAnnounceKey: old.announceKey, oldUsername: oldName, created: .now))
                // The old iPhone learns its account now lives elsewhere (only these keys can say so).
                m.announcements.append(.init(topic: old.inboxTopic, envelope: env, until: Date().addingTimeInterval(7 * 86_400),
                                             formerAnnounceKey: old.announceKey, oldUsername: oldName, created: .now))
            }
            if let oldName = prev.username {
                let commit = await Task.detached { UsernameKey.commitment(oldName) }.value
                m.revocations.append(.init(username: oldName, ucommit: commit, secret: old.revokeSecret, notBefore: removalTime()))
            }
        }
        // No old keys, but this iPhone still remembers how to remove its previous username(s).
        for r in [record, abandoned].compactMap({ $0 }) where r.ucommit != v.bundle.ucommit && !m.revocations.contains(where: { $0.ucommit == r.ucommit }) {
            m.revocations.append(.init(username: r.username, ucommit: r.ucommit, secret: r.secret, notBefore: removalTime()))
        }
        return m
    }

    /// Removal happens 10 minutes to 6 hours later so it is not adjacent to the new registration.
    static func removalTime() -> Date {
        #if DEBUG
        if let s = debugRemovalDelay { return Date().addingTimeInterval(s) }
        #endif
        return Date().addingTimeInterval(.random(in: 600...21_600))
    }
    #if DEBUG
    /// Tests only: remove the previous username after this many seconds instead of 10 min – 6 h.
    nonisolated(unsafe) static var debugRemovalDelay: TimeInterval?
    #endif
}

/// Lightweight tamper heuristics (defence in depth; a determined attacker with root wins anyway).
enum IntegrityCheck {
    struct Result: Equatable { var jailbroken = false; var debugger = false; var injected = false; var ok: Bool { !jailbroken && !debugger && !injected } }

    static func run() -> Result {
        var r = Result()
        #if !targetEnvironment(simulator)
        let paths = ["/Applications/Cydia.app", "/Applications/Sileo.app", "/bin/bash", "/usr/sbin/sshd", "/etc/apt",
                     "/private/var/lib/apt/", "/var/jb", "/usr/libexec/cydia"]
        r.jailbroken = paths.contains { FileManager.default.fileExists(atPath: $0) }
        let probe = "/private/priva-jb-probe"
        if (try? "x".write(toFile: probe, atomically: true, encoding: .utf8)) != nil {
            r.jailbroken = true
            try? FileManager.default.removeItem(atPath: probe)
        }
        var info = kinfo_proc()
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var size = MemoryLayout<kinfo_proc>.stride
        if sysctl(&mib, 4, &info, &size, nil, 0) == 0 { r.debugger = (info.kp_proc.p_flag & P_TRACED) != 0 }
        for i in 0..<_dyld_image_count() {
            let name = String(cString: _dyld_get_image_name(i)).lowercased()
            if ["frida", "cycript", "substrate", "substitute", "libhooker", "sslkillswitch"].contains(where: name.contains) { r.injected = true }
        }
        #endif
        return r
    }
}

/// Moves a non-Sendable, thread-safe object (e.g. an evaluated LAContext) into a detached task.
nonisolated struct SendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
