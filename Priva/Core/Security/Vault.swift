import CryptoKit
import Foundation
import LocalAuthentication

/// The vault key (VK) encrypts everything Priva stores. Unwrapping it requires BOTH:
///   • the password  → scrypt(password, salt)
///   • a biometric match → Secure Enclave secret
///
///   KEK   = HKDF(scrypt(pw) ‖ bioSecret)
///   wrap₁ = AES-GCM(KEK, VK), daily unlock
///   wrap₂ = AES-GCM(HKDF(seed,"recovery"), VK), password reset with the recovery phrase
///   seed  = AES-GCM(VK, masterSeed)
nonisolated struct VaultMeta: Codable, Sendable {
    var version = 1
    var username: String
    var passwordSalt: Data
    var wrapPassword: Data
    var wrapRecovery: Data
    var sealedSeed: Data
    var bundleRaw: Data
    var registered: Bool
    var wipeAfterFailures: Bool = false
    var created: Date = .now
    /// Cached device-side derivations of the username (memory-hard to recompute).
    var ucommit: Data?
    var requestTopic: String?
}

nonisolated struct UnlockedVault: Sendable {
    let username: String
    let vaultKey: SymmetricKey
    let identity: IdentityKeys
    let bundle: KeyBundle
    let registered: Bool

    /// Random keys every closed engine shares, made once: a locked engine that UIKit still holds keeps these, not
    /// the account's.
    private static let wipedIdentity: IdentityKeys? = try? IdentityKeys(seed: IdentityKeys.newSeed())

    /// The same account without its secrets (public bundle and name only).
    func wiped() -> UnlockedVault {
        UnlockedVault(username: username, vaultKey: SymmetricKey(size: .bits256), identity: Self.wipedIdentity ?? identity,
                      bundle: bundle, registered: registered)
    }
}

nonisolated enum Vault {
    enum Failure: Error, Equatable {
        case notSetUp, wrongPassword, wrongPhrase, lockedOut(until: Date), wiped
        /// The password couldn't be checked at all (out of memory for the key derivation, damaged keys): not a guess.
        case unavailable
        case biometric(BiometricGate.Failure)
    }

    private static let metaAccount = "vault.meta"
    private static let failAccount = "vault.failures"
    private static let aad = Data("PRIVA-VAULT-v1".utf8)

    struct FailureState: Codable { var count: Int; var last: Date }

    /// Device-only record that lets THIS iPhone remove its username after a reinstall even if the
    /// password is forgotten (docs/IDENTITY_DESIGN.md §6). Holds no keys, only the revocation secret.
    struct RevocationRecord: Codable, Sendable { let username: String; let ucommit: Data; let secret: Data }
    private static let revokeAccount = "id.revoke"

    static var revocationRecord: RevocationRecord? { Keychain.getCodable(RevocationRecord.self, account: revokeAccount) }
    static func storeRevocation(_ r: RevocationRecord) { try? Keychain.setCodable(r, account: revokeAccount) }
    static func clearRevocation() { Keychain.delete(revokeAccount) }

    static var exists: Bool { (try? Keychain.get(metaAccount)) != nil }
    static var meta: VaultMeta? { Keychain.getCodable(VaultMeta.self, account: metaAccount) }

    private static func kek(password: String, salt: Data, bio: Data) throws -> SymmetricKey {
        let pw = try PasswordKDF.derive(password, salt: salt)
        return SymmetricKey(data: KDF.derive(pw + bio, salt: Data("priva/kek/v2".utf8), info: Data("vault".utf8), count: 32))
    }

    private static func seal(_ d: Data, _ k: SymmetricKey) throws -> Data {
        try AES.GCM.seal(d, using: k, authenticating: aad).combined!
    }

    private static func open(_ d: Data, _ k: SymmetricKey) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: d), using: k, authenticating: aad)
    }

    /// First-time setup. `context` must come from a successful biometric evaluation.
    /// `vaultKey` / `bundle` are passed when restoring a backup (the store was already written under that key,
    /// and the directory holds the original signed bundle).
    /// `biometricSecret`: an existing Face ID secret to reuse (a restore over an account on this iPhone), then the
    /// vault record is the only write, and an app killed half-way leaves the old vault fully usable.
    static func create(username: String, password: String, seed: Data, context: LAContext,
                       vaultKey: SymmetricKey? = nil, bundle restored: KeyBundle? = nil, registered: Bool = false,
                       biometricSecret: Data? = nil) throws -> UnlockedVault {
        let identity = try IdentityKeys(seed: seed)
        let bundle = try restored ?? identity.bundle(username: username)
        let vk = vaultKey ?? SymmetricKey(size: .bits256)
        let vkData = vk.withUnsafeBytes { Data($0) }
        let bio: Data
        if let biometricSecret { bio = biometricSecret } else {
            do { bio = try BiometricGate.enroll(context: context) } catch let e as BiometricGate.Failure { throw Failure.biometric(e) }
        }
        let salt = Bytes.random(16)
        let meta = VaultMeta(
            username: username, passwordSalt: salt,
            wrapPassword: try seal(vkData, try kek(password: password, salt: salt, bio: bio)),
            wrapRecovery: try seal(vkData, SymmetricKey(data: identity.recoveryWrapKey)),
            sealedSeed: try seal(seed, vk), bundleRaw: bundle.raw, registered: registered,
            ucommit: bundle.ucommit, requestTopic: try UsernameKey.requestTopicStrict(username))
        try Keychain.setCodable(meta, account: metaAccount)
        Keychain.delete(failAccount)
        return UnlockedVault(username: username, vaultKey: vk, identity: identity, bundle: bundle, registered: registered)
    }

    static func lockoutUntil() -> Date? {
        guard let f = Keychain.getCodable(FailureState.self, account: failAccount), f.count >= 5 else { return nil }
        let delay = min(3600.0, 30 * pow(2, Double(f.count - 5)))
        let until = f.last.addingTimeInterval(delay)
        return until > .now ? until : nil
    }

    static var failedAttempts: Int { Keychain.getCodable(FailureState.self, account: failAccount)?.count ?? 0 }

    #if DEBUG
    /// Tests: the wait after the last wrong password is over (the count stays).
    static func debugExpireLockout() {
        guard var f = Keychain.getCodable(FailureState.self, account: failAccount) else { return }
        f.last = .distantPast
        try? Keychain.setCodable(f, account: failAccount)
    }
    #endif

    static func unlock(password: String, context: LAContext) throws -> UnlockedVault {
        guard let meta else { throw Failure.notSetUp }
        if let until = lockoutUntil() { throw Failure.lockedOut(until: until) }
        let bio: Data
        do { bio = try BiometricGate.secret(context: context) } catch let e as BiometricGate.Failure { throw Failure.biometric(e) }
        // Only a key that doesn't open the vault counts as a wrong password (toward lockout and erase): a key
        // derivation that ran out of memory, or keys that won't parse, aren't guesses (audit STA-31).
        let kek: SymmetricKey
        do { kek = try Self.kek(password: password, salt: meta.passwordSalt, bio: bio) } catch { throw Failure.unavailable }
        if let vkData = try? open(meta.wrapPassword, kek) {
            do {
                let vk = SymmetricKey(data: vkData)
                let seed = try open(meta.sealedSeed, vk)
                let identity = try IdentityKeys(seed: seed)
                Keychain.delete(failAccount)
                return UnlockedVault(username: meta.username, vaultKey: vk, identity: identity,
                                     bundle: try KeyBundle.parse(meta.bundleRaw), registered: meta.registered)
            } catch { throw Failure.unavailable }
        } else {
            let count = failedAttempts + 1
            try? Keychain.setCodable(FailureState(count: count, last: .now), account: failAccount)
            if meta.wipeAfterFailures && count >= 10 {
                wipeEverything()
                throw Failure.wiped
            }
            throw Failure.wrongPassword
        }
    }

    static func markRegistered(bundle: KeyBundle) throws {
        guard var m = meta else { throw Failure.notSetUp }
        m.registered = true
        m.bundleRaw = bundle.raw
        try Keychain.setCodable(m, account: metaAccount)
    }

    /// Before registration a colliding random name is simply redrawn; keys stay the same.
    static func changeUnregisteredUsername(to name: String, identity: IdentityKeys) throws -> KeyBundle {
        guard var m = meta, !m.registered else { throw Failure.notSetUp }
        let bundle = try identity.bundle(username: name)
        m.username = name
        m.bundleRaw = bundle.raw
        m.ucommit = bundle.ucommit
        m.requestTopic = try UsernameKey.requestTopicStrict(name)
        try Keychain.setCodable(m, account: metaAccount)
        return bundle
    }

    static func setWipeAfterFailures(_ on: Bool) throws {
        guard var m = meta else { throw Failure.notSetUp }
        m.wipeAfterFailures = on
        try Keychain.setCodable(m, account: metaAccount)
    }

    /// Change password while unlocked: needs the current password and a fresh biometric context, so someone
    /// holding an unlocked iPhone (and able to pass Face ID, e.g. with the owner asleep) can't lock the owner out.
    /// Wrong guesses count toward the unlock lockout.
    static func changePassword(vault: UnlockedVault, currentPassword: String, newPassword: String, context: LAContext) throws {
        guard var m = meta else { throw Failure.notSetUp }
        if let until = lockoutUntil() { throw Failure.lockedOut(until: until) }
        let bio: Data
        do { bio = try BiometricGate.secret(context: context) } catch let e as BiometricGate.Failure { throw Failure.biometric(e) }
        let current = try? open(m.wrapPassword, try kek(password: currentPassword, salt: m.passwordSalt, bio: bio))
        guard let current, Bytes.equal(current, vault.vaultKey.withUnsafeBytes { Data($0) }) else {
            try? Keychain.setCodable(FailureState(count: failedAttempts + 1, last: .now), account: failAccount)
            throw Failure.wrongPassword
        }
        Keychain.delete(failAccount)
        let salt = Bytes.random(16)
        m.passwordSalt = salt
        m.wrapPassword = try seal(vault.vaultKey.withUnsafeBytes { Data($0) },
                                  try kek(password: newPassword, salt: salt, bio: bio))
        try Keychain.setCodable(m, account: metaAccount)
    }

    /// Forgot password: recovery phrase + a fresh biometric enrolment → new password.
    static func resetPassword(seed: Data, newPassword: String, context: LAContext) throws -> UnlockedVault {
        guard var m = meta else { throw Failure.notSetUp }
        let identity = try IdentityKeys(seed: seed)
        let vkData: Data
        do { vkData = try open(m.wrapRecovery, SymmetricKey(data: identity.recoveryWrapKey)) } catch { throw Failure.wrongPhrase }
        let vk = SymmetricKey(data: vkData)
        guard (try? open(m.sealedSeed, vk)) == seed else { throw Failure.wrongPhrase }
        let bio: Data
        do { bio = try BiometricGate.enroll(context: context) } catch let e as BiometricGate.Failure { throw Failure.biometric(e) }
        let salt = Bytes.random(16)
        m.passwordSalt = salt
        m.wrapPassword = try seal(vkData, try kek(password: newPassword, salt: salt, bio: bio))
        try Keychain.setCodable(m, account: metaAccount)
        Keychain.delete(failAccount)
        return UnlockedVault(username: m.username, vaultKey: vk, identity: identity,
                             bundle: try KeyBundle.parse(m.bundleRaw), registered: m.registered)
    }

    /// Panic / account deletion / erase after 10 tries: removes every key and every file. Irreversible.
    static func wipeEverything() {
        Keychain.deleteAll()
        BiometricGate.wipe()
        wipeFiles()
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "com.priva.app")
    }

    /// Every file Priva keeps on this iPhone: the encrypted store and media, backups kept on the phone, backup
    /// files received from elsewhere, restores in progress and temporary files. (Backups in iCloud Drive are the
    /// user's to delete: Settings › Backup › Turn off.)
    static func wipeFiles() {
        let fm = FileManager.default
        if let support = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
            for item in (try? fm.contentsOfDirectory(at: support, includingPropertiesForKeys: nil)) ?? []
            where ["Priva", "Backups"].contains(item.lastPathComponent) || item.lastPathComponent.hasPrefix("Restore-") {
                try? fm.removeItem(at: item)
            }
        }
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? fm.removeItem(at: docs.appendingPathComponent("Inbox", isDirectory: true))
        }
        for item in (try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: item)
        }
    }
}

/// Validates password quality without sending it anywhere.
nonisolated enum PasswordPolicy {
    struct Assessment: Equatable { let score: Int; let label: String; let acceptable: Bool }

    static let common: Set<String> = ["password", "12345678", "123456789", "qwertyui", "iloveyou", "password1",
                                      "11111111", "00000000", "abcdefgh", "letmein1", "sunshine", "princess",
                                      "football", "baseball", "welcome1", "admin123", "priva123", "qwerty123"]

    static func assess(_ p: String) -> Assessment {
        guard p.count >= 8 else { return Assessment(score: 0, label: "Too short", acceptable: false) }
        if common.contains(p.lowercased()) { return Assessment(score: 0, label: "Too common", acceptable: false) }
        var classes = 0
        if p.contains(where: \.isLowercase) { classes += 1 }
        if p.contains(where: \.isUppercase) { classes += 1 }
        if p.contains(where: \.isNumber) { classes += 1 }
        if p.contains(where: { !$0.isLetter && !$0.isNumber }) { classes += 1 }
        let unique = Set(p).count
        var score = min(4, (p.count >= 12 ? 2 : 1) + (classes >= 3 ? 1 : 0) + (p.count >= 16 || classes == 4 ? 1 : 0))
        if unique < 5 { score = min(score, 1) }
        let labels = ["Weak", "Fair", "Good", "Strong", "Excellent"]
        return Assessment(score: score, label: labels[score], acceptable: score >= 2)
    }
}
