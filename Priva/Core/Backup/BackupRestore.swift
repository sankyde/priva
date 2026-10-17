import CryptoKit
import Foundation
import LocalAuthentication

/// Restoring a backup: decrypt + import into a staging folder (nothing on the phone changes), then, after
/// Face ID, build a new vault around the restored identity and swap the staged data into place.
nonisolated enum BackupRestore {
    struct Staged: Sendable {
        let manifest: BackupManifest
        let directory: URL
        let vaultKey: Data
        let messages: Int
        let media: Int
    }

    /// Needs all factors: the file, the 24-word Backup Key, the password it was made with, and (if the backup
    /// uses it) this Apple Account's iCloud Keychain secret. Any wrong factor → `.wrongKey`.
    static func stage(_ file: URL, key: BackupKey, password: String) async throws -> Staged {
        try await Task.detached(priority: .userInitiated) {
            let accessing = file.startAccessingSecurityScopedResource()
            defer { if accessing { file.stopAccessingSecurityScopedResource() } }
            let reader = try BackupReader(url: file, backupKey: key, password: password, keychainSecret: BackupKeychainFactor.read())
            let vk = SymmetricKey(size: .bits256)
            let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let dir = base.appendingPathComponent("Restore-" + UUID().uuidString, isDirectory: true)
            do {
                let r: BackupImporter.Result = try {
                    let store = try Store(vaultKey: vk, directory: dir)
                    let r = try BackupImporter.importAll(reader, into: store)
                    try prepareForNewIdentity(store, manifest: r.manifest)
                    try store.set(true, for: "restore.reconnect")
                    return r
                }()
                return Staged(manifest: r.manifest, directory: dir, vaultKey: vk.withUnsafeBytes { Data($0) },
                              messages: r.messages, media: r.media)
            } catch {
                try? FileManager.default.removeItem(at: dir)
                throw error
            }
        }.value
    }

    static func discard(_ s: Staged) { try? FileManager.default.removeItem(at: s.directory) }

    struct Throttled: Error { let seconds: TimeInterval }

    /// What the app calls: `stage`, behind the attempt limit. Only a wrong key/password counts as a failure.
    static func unlock(_ file: URL, key: BackupKey, password: String) async throws -> Staged {
        let wait = RestoreThrottle.wait()
        guard wait <= 0 else { throw Throttled(seconds: wait) }
        do {
            let s = try await stage(file, key: key, password: password)
            RestoreThrottle.reset()
            return s
        } catch BackupError.wrongKey {
            RestoreThrottle.recordFailure()
            throw BackupError.wrongKey
        }
    }

    /// The restored account will live under a new username and new keys. Keep the old ones only long enough to
    /// prove the move to friends (`RestoredFrom`); drop what was addressed to, or signed by, the old username.
    static func prepareForNewIdentity(_ store: Store, manifest m: BackupManifest) throws {
        let pending = try store.outgoingRequests().filter { $0.state == .pending && $0.migratesContact == nil && $0.rekey != true }
        let reissue = pending.map { RestoredFrom.Reissue(username: $0.username, bundleRaw: $0.bundleRaw, note: $0.note) }
        try store.set(RestoredFrom(username: m.username, seed: m.seed, bundleRaw: m.bundleRaw, reissue: reissue), for: "restore.previous")
        for r in try store.outgoingRequests() { try store.deleteRequest(outgoing: r.id) }
        for r in try store.incomingRequests() { try store.deleteRequest(incoming: r.id) }
        for c in try store.controlItems() { try store.deleteControl(c.id) }
        // Duties of the old account: announcements pointed friends at the old username (which is going away);
        // removals of even older usernames still hold and stay.
        if var mig = store.get(MigrationState.self, for: "migration") {
            mig.announcements = []
            try store.set(mig, for: "migration")
        }
        store.removeValue(for: "account.moved")
        store.removeValue(for: "group-links")
    }

    /// Staging folders left behind by an interrupted restore (they're encrypted, but not worth keeping). Runs after
    /// `recoverInterruptedCommit`, so a folder a cut-off restore still needs is never deleted.
    static func removeAbandoned() {
        let fm = FileManager.default
        guard Keychain.getCodable(CommitJournal.self, account: journalAccount) == nil,
              let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false),
              let items = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return }
        for item in items where item.lastPathComponent.hasPrefix("Restore-") { try? fm.removeItem(at: item) }
    }

    /// What a commit in progress is doing, written (synchronously, to the Keychain) before anything moves.
    struct CommitJournal: Codable, Equatable {
        let newUsername: String
        let old: String          // the previous account's store, moved aside
        let staged: String       // where the restored store came from
    }
    static let journalAccount = "restore.journal"

    /// At launch: a restore cut off part-way (app killed, phone off) is finished, or undone back to the previous
    /// account exactly, never left as a vault that can't open its own store.
    static func recoverInterruptedCommit() {
        guard let j = Keychain.getCodable(CommitJournal.self, account: journalAccount), let dst = try? Store.directory() else { return }
        resolve(j, store: dst, vaultUsername: Vault.meta?.username)
        Keychain.delete(journalAccount)
    }

    /// `store` is the live store folder; the journal's folders sit beside it.
    static func resolve(_ j: CommitJournal, store dst: URL, vaultUsername: String?) {
        let fm = FileManager.default
        let base = dst.deletingLastPathComponent()
        let old = base.appendingPathComponent(j.old, isDirectory: true)
        if vaultUsername == j.newUsername {
            // The new vault was written: the restore happened. Only the previous store is left to remove.
            try? fm.removeItem(at: old)
        } else if fm.fileExists(atPath: old.path) {
            // The vault is still the previous account's: put its store back; the restored copy is dropped.
            try? fm.removeItem(at: dst)
            try? fm.moveItem(at: old, to: dst)
        }
        try? fm.removeItem(at: base.appendingPathComponent(j.staged, isDirectory: true))
    }

    /// `context` must come from a fresh Face ID evaluation. Replaces whatever account is on this iPhone.
    /// The restored account gets NEW keys and a NEW username (registered next, see `OnboardingModel.register`):
    /// the server can't link it to the old one, and a copy of the same backup restored elsewhere can't pass
    /// itself off as this iPhone. Friends follow via the move proof (`PrivaEngine.reconnectAfterRestore`).
    static func commit(_ s: Staged, password: String, context: LAContext,
                       newUsername: String = Username.random(), newSeed: Data = IdentityKeys.newSeed()) throws -> UnlockedVault {
        let m = s.manifest
        // Swap whole directories first (renames on one volume): a failure at any step puts the old store back
        // untouched, and the old vault stays paired with it.
        let fm = FileManager.default
        let dst = try Store.directory()
        let old = dst.deletingLastPathComponent().appendingPathComponent("Restore-old-" + UUID().uuidString, isDirectory: true)
        // The phone's current Face ID secret is reused (this context is a fresh evaluation): the new vault record is
        // then the single write that switches accounts. A first restore on a new phone enrolls one.
        let bio = Vault.exists ? try? BiometricGate.secret(context: context) : nil
        try Keychain.setCodable(CommitJournal(newUsername: newUsername, old: old.lastPathComponent, staged: s.directory.lastPathComponent),
                                account: journalAccount)
        try fm.moveItem(at: dst, to: old)
        do { try fm.moveItem(at: s.directory, to: dst) } catch { try? fm.moveItem(at: old, to: dst); Keychain.delete(journalAccount); throw error }
        let v: UnlockedVault
        do {
            v = try Vault.create(username: newUsername, password: password, seed: newSeed, context: context,
                                 vaultKey: SymmetricKey(data: s.vaultKey), registered: false, biometricSecret: bio)
        } catch {
            try? fm.moveItem(at: dst, to: s.directory)
            try? fm.moveItem(at: old, to: dst)
            Keychain.delete(journalAccount)
            throw error
        }
        Keychain.delete(journalAccount)
        _ = try? Store.directory()          // re-applies protection class + backup exclusion
        try? fm.removeItem(at: old)
        if m.wipeAfterFailures == true { try? Vault.setWipeAfterFailures(true) }
        // Until the move is done, this iPhone can still remove the old username (even if the restore is interrupted).
        if m.registered, let ident = try? IdentityKeys(seed: m.seed), let bundle = try? KeyBundle.parse(m.bundleRaw) {
            Vault.storeRevocation(.init(username: m.username, ucommit: bundle.ucommit, secret: ident.revokeSecret))
        }
        return v
    }
}

/// Wrong Backup Key / password attempts on this iPhone slow down (30 s after 3, up to an hour). Kept in the
/// Keychain so deleting and reinstalling Priva doesn't reset it. It can't stop an offline attacker, but one of
/// those would also need the 24-word key and the iCloud Keychain secret; this is for someone holding the phone.
nonisolated enum RestoreThrottle {
    private struct State: Codable { var failures: Int; var last: Date }
    static let account = "restore.failures"

    private static var state: State? { Keychain.getCodable(State.self, account: account) }

    static func delay(after failures: Int) -> TimeInterval {
        switch failures {
        case ..<3: 0
        case 3: 30
        case 4: 60
        case 5: 300
        case 6: 900
        default: 3600
        }
    }

    /// Seconds until the next attempt is allowed (0 = now).
    static func wait(now: Date = .now) -> TimeInterval {
        guard let s = state else { return 0 }
        return max(0, s.last.addingTimeInterval(delay(after: s.failures)).timeIntervalSince(now))
    }

    static func recordFailure() {
        var s = state ?? State(failures: 0, last: .now)
        s.failures += 1
        s.last = .now
        try? Keychain.setCodable(s, account: account)
    }

    static func reset() { Keychain.delete(account) }

    #if DEBUG
    static var failures: Int { state?.failures ?? 0 }
    #endif
}
