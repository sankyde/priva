import CryptoExtras
import CryptoKit
import Foundation

/// Client side of RFC 9474 (RSABSSA-SHA384-PSS-Deterministic).
///
/// The token message is 46 bytes: "PRIVA-TOKEN-v1" ‖ 32 random bytes. Because it is already
/// high-entropy, deterministic preparation is safe (RFC 9474 §7.3).
nonisolated enum BlindToken {
    /// SHA-256 of the issuer's SubjectPublicKeyInfo. Pinned so the server cannot tag users
    /// with per-user keys: a signature from any other key fails local verification.
    static let pinnedKeyIDs = PrivaConfig.tokenKeyIDs
    static let prefix = Data("PRIVA-TOKEN-v1".utf8)

    typealias PublicKey = _RSA.BlindSigning.PublicKey<SHA384>

    enum Failure: Error { case keyNotPinned, badSignature }

    struct Pending {
        let token: Data
        let blinded: Data
        fileprivate let prepared: _RSA.BlindSigning.PreparedMessage
        fileprivate let inverse: _RSA.BlindSigning.BlindingInverse
        fileprivate let key: PublicKey
    }

    struct Redeemable: Codable, Sendable {
        let token: Data
        let signature: Data
    }

    static func issuerKey(spki: Data, pinned: Set<String> = pinnedKeyIDs) throws -> PublicKey {
        guard pinned.contains(KDF.sha256(spki).hex) else { throw Failure.keyNotPinned }
        return try PublicKey(derRepresentation: spki, parameters: .RSABSSA_SHA384_PSS_Deterministic)
    }

    /// Registration token ("PRIVA-TOKEN-v1" ‖ 32 random bytes).
    static func begin(spki: Data) throws -> Pending {
        try begin(spki: spki, pinned: pinnedKeyIDs, token: prefix + Bytes.random(32))
    }

    /// Any high-entropy `token` under another pinned issuer key (relay passes).
    static func begin(spki: Data, pinned: Set<String>, token: Data) throws -> Pending {
        let key = try issuerKey(spki: spki, pinned: pinned)
        let prepared = key.prepare(token)
        let blinding = try key.blind(prepared)
        return Pending(token: token, blinded: blinding.blindedMessage, prepared: prepared, inverse: blinding.inverse, key: key)
    }

    static func finish(_ p: Pending, blindSignature: Data) throws -> Redeemable {
        let sig = try p.key.finalize(_RSA.BlindSigning.BlindSignature(rawRepresentation: blindSignature),
                                     for: p.prepared, blindingInverse: p.inverse)
        guard p.key.isValidSignature(sig, for: p.prepared) else { throw Failure.badSignature }
        return Redeemable(token: p.token, signature: sig.rawRepresentation)
    }
}

nonisolated enum PasswordKDF {
    /// scrypt N=2¹⁶, r=8, p=1 (64 MiB, memory-hard). Combined with a Secure Enclave secret,
    /// so offline guessing is impossible without this physical device and the user's face.
    static let rounds = 1 << 16

    static func derive(_ password: String, salt: Data) throws -> Data {
        let key = try CryptoExtras.KDF.Scrypt.deriveKey(
            from: Data(password.precomposedStringWithCanonicalMapping.utf8), salt: salt,
            outputByteCount: 32, rounds: rounds, blockSize: 8, parallelism: 1, maxMemory: 160 * 1024 * 1024)
        return key.withUnsafeBytes { Data($0) }
    }
}
