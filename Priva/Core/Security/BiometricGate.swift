import CryptoKit
import Foundation
import LocalAuthentication

/// Produces a 32-byte secret that exists only after a successful Face ID / Touch ID match.
///
/// On hardware the secret is an ECDH result computed *inside the Secure Enclave* with a key
/// created with `.biometryCurrentSet`: it never leaves the chip, cannot be exported, and is
/// invalidated if anyone enrols a new face or finger. The Simulator has no Secure Enclave, so
/// there the secret lives in a Keychain item protected by the same biometry access control.
nonisolated enum BiometricGate {
    enum Failure: Error, Equatable { case unavailable, cancelled, failed, invalidated }

    static let seKeyAccount = "bio.se.key"
    static let partnerAccount = "bio.se.partner"
    /// The Secure Enclave key and its partner in one Keychain item: enrolling is a single write, so an app killed
    /// mid-way can't leave a key paired with the wrong partner. (The two separate items above are read for older vaults.)
    static let pairAccount = "bio.se.pair"
    static let fallbackAccount = "bio.kc.secret"

    private struct Pair: Codable { let se: Data; let partner: Data }

    enum Kind: String { case faceID = "Face ID", touchID = "Touch ID", opticID = "Optic ID", none = "Biometrics" }

    static var kind: Kind {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch ctx.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        case .opticID: return .opticID
        default: return .none
        }
    }

    static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    /// Why Face ID can't be used right now, saying what to do about it: a lockout only needs the iPhone's passcode,
    /// and nobody should reach for the recovery phrase over a setting.
    static func unavailableMessage() -> String {
        var err: NSError?
        _ = LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
        let name = kind == .none ? "Face ID" : kind.rawValue
        switch err.flatMap({ LAError.Code(rawValue: $0.code) }) {
        case .biometryLockout?:
            return "\(name) is locked after too many tries. Lock your iPhone and unlock it with your passcode, then try again here."
        case .biometryNotEnrolled?:
            return "\(name) isn't set up on this iPhone. Set it up in Settings › \(name) & Passcode: Priva needs it to unlock."
        case .passcodeNotSet?:
            return "This iPhone has no passcode, so \(name) is off. Set a passcode in Settings › \(name) & Passcode."
        case .biometryNotAvailable?:
            return "\(name) is turned off for Priva. Turn it on in Settings › Apps › Priva."
        default:
            return "\(name) is unavailable. Priva requires it to unlock."
        }
    }

    /// Face ID that a hooked `evaluatePolicy` can't fake: the evaluation must also unlock the Secure Enclave key
    /// (OWASP MASTG-TEST-0266: a bare yes/no can be flipped by runtime tools on a jailbroken phone). For gates that
    /// reveal or erase something without otherwise using the key.
    static func confirm(reason: String) async throws {
        let ctx = try await authenticate(reason: reason)
        _ = try secret(context: ctx)
    }

    /// Biometrics only: no passcode fallback, as required.
    static func authenticate(reason: String) async throws -> LAContext {
        let ctx = LAContext()
        ctx.localizedFallbackTitle = ""
        ctx.localizedCancelTitle = "Cancel"
        ctx.touchIDAuthenticationAllowableReuseDuration = 0
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) else {
            throw Failure.unavailable
        }
        do {
            let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
            guard ok else { throw Failure.failed }
            return ctx
        } catch let e as LAError where e.code == .userCancel || e.code == .appCancel || e.code == .systemCancel {
            throw Failure.cancelled
        } catch let e as LAError where [.biometryLockout, .biometryNotEnrolled, .biometryNotAvailable, .passcodeNotSet].contains(e.code) {
            throw Failure.unavailable          // locked out by this try, or turned off meanwhile: say what to do
        } catch is LAError {
            throw Failure.failed
        }
    }

    private static func accessControl() -> SecAccessControl? {
        #if targetEnvironment(simulator)
        let protection = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let flags: SecAccessControlCreateFlags = [.biometryCurrentSet]
        #else
        let protection = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        let flags: SecAccessControlCreateFlags = [.privateKeyUsage, .biometryCurrentSet]
        #endif
        return SecAccessControlCreateWithFlags(nil, protection, flags, nil)
    }

    /// Creates a fresh biometric-bound secret (replacing any previous one).
    static func enroll(context: LAContext) throws -> Data {
        guard let ac = accessControl() else { throw Failure.unavailable }
        #if targetEnvironment(simulator)
        let secret = Bytes.random(32)
        try Keychain.set(secret, account: fallbackAccount, accessControl: ac, context: context)
        return secret
        #else
        guard SecureEnclave.isAvailable else { throw Failure.unavailable }
        let se = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: ac, authenticationContext: context)
        let partner = P256.KeyAgreement.PrivateKey()
        try Keychain.setCodable(Pair(se: se.dataRepresentation, partner: partner.publicKey.rawRepresentation), account: pairAccount)
        Keychain.delete(seKeyAccount)
        Keychain.delete(partnerAccount)
        return try derive(se: se, partner: partner.publicKey)
        #endif
    }

    /// Returns the secret using an already-authenticated context (no second prompt).
    static func secret(context: LAContext) throws -> Data {
        #if targetEnvironment(simulator)
        do {
            guard let s = try Keychain.get(fallbackAccount, context: context) else { throw Failure.invalidated }
            return s
        } catch let e as Keychain.Failure {
            if case .status(let st) = e, st == errSecUserCanceled { throw Failure.cancelled }
            throw Failure.invalidated
        }
        #else
        let pair = Keychain.getCodable(Pair.self, account: pairAccount)
        guard let blob = try pair?.se ?? Keychain.get(seKeyAccount), let partnerRaw = try pair?.partner ?? Keychain.get(partnerAccount) else {
            throw Failure.invalidated
        }
        do {
            let se = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob, authenticationContext: context)
            return try derive(se: se, partner: try P256.KeyAgreement.PublicKey(rawRepresentation: partnerRaw))
        } catch {
            // A changed biometric set invalidates the key: the user must reset with the recovery phrase.
            throw Failure.invalidated
        }
        #endif
    }

    #if !targetEnvironment(simulator)
    private static func derive(se: SecureEnclave.P256.KeyAgreement.PrivateKey, partner: P256.KeyAgreement.PublicKey) throws -> Data {
        let shared = try se.sharedSecretFromKeyAgreement(with: partner)
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("priva/bio/v1".utf8),
                                                  sharedInfo: Data(), outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }
    #endif

    static func wipe() {
        Keychain.delete(pairAccount)
        Keychain.delete(seKeyAccount)
        Keychain.delete(partnerAccount)
        Keychain.delete(fallbackAccount)
    }
}
