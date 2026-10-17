import CryptoKit
import Foundation

/// Errors are intentionally coarse: callers must not learn *why* authentication failed.
nonisolated enum CryptoFailure: Error, Equatable {
    case authentication
    case malformed
    case keyGeneration
}

// MARK: - KDF

nonisolated enum KDF {
    /// HKDF-SHA-512.
    static func derive(_ ikm: Data, salt: Data, info: Data, count: Int) -> Data {
        let key = HKDF<SHA512>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm), salt: salt, info: info, outputByteCount: count)
        return key.withUnsafeBytes { Data($0) }
    }

    static func derive(_ ikm: Data, salt: Data = Data(), info: String, count: Int) -> Data {
        derive(ikm, salt: salt, info: Data(info.utf8), count: count)
    }

    static func sha512(_ parts: Data...) -> Data {
        var h = SHA512()
        for p in parts { h.update(data: p) }
        return Data(h.finalize())
    }

    static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    static func hmac(_ key: Data, _ message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }
}

// MARK: - Dual AEAD (AES-256-GCM inside ChaCha20-Poly1305, independent keys)

nonisolated struct DualKey: Sendable {
    let aes: SymmetricKey
    let chacha: SymmetricKey

    /// 64 bytes of key material: first half AES-256, second half ChaCha20.
    init(_ material: Data) {
        precondition(material.count == 64, "DualKey needs 64 bytes")
        let m = material.detached
        aes = SymmetricKey(data: m.prefix(32))
        chacha = SymmetricKey(data: m.suffix(32))
    }

    static func derive(from ikm: Data, salt: Data = Data(), info: String) -> DualKey {
        DualKey(KDF.derive(ikm, salt: salt, info: info, count: 64))
    }
}

nonisolated enum DualAEAD {
    static let overhead = 32
    static let nonceSize = 12

    static func nonce(counter: UInt64) -> Data {
        var n = Data(count: 4)
        n.appendBE(counter)
        return n
    }

    static func seal(_ plaintext: Data, key: DualKey, nonce: Data, aad: Data) throws -> Data {
        let inner = try AES.GCM.seal(plaintext, using: key.aes, nonce: AES.GCM.Nonce(data: nonce), authenticating: aad)
        let outer = try ChaChaPoly.seal(inner.ciphertext + inner.tag, using: key.chacha,
                                        nonce: ChaChaPoly.Nonce(data: nonce), authenticating: aad)
        return Data(outer.ciphertext + outer.tag)
    }

    static func open(_ ciphertext: Data, key: DualKey, nonce: Data, aad: Data) throws -> Data {
        guard ciphertext.count >= overhead else { throw CryptoFailure.malformed }
        do {
            let c = ciphertext.detached
            let outerBox = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nonce),
                                                   ciphertext: c.dropLast(16), tag: c.suffix(16))
            let inner = try ChaChaPoly.open(outerBox, using: key.chacha, authenticating: aad)
            let innerBox = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce),
                                                 ciphertext: inner.dropLast(16), tag: inner.suffix(16))
            return try AES.GCM.open(innerBox, using: key.aes, authenticating: aad)
        } catch {
            throw CryptoFailure.authentication
        }
    }

    /// Random-nonce mode: output = nonce(12) ‖ ciphertext. Safe for < 2³² messages per key.
    static func sealRandom(_ plaintext: Data, key: DualKey, aad: Data) throws -> Data {
        let n = Bytes.random(nonceSize)
        return n + (try seal(plaintext, key: key, nonce: n, aad: aad))
    }

    static func openRandom(_ box: Data, key: DualKey, aad: Data) throws -> Data {
        guard box.count >= nonceSize + overhead else { throw CryptoFailure.malformed }
        let b = box.detached
        return try open(b.dropFirst(nonceSize).detached, key: key, nonce: b.prefix(nonceSize), aad: aad)
    }
}

// MARK: - Dual KEM key pairs

nonisolated struct KEMPublicPair: Sendable {
    let xwing: XWingMLKEM768X25519.PublicKey
    let mlkem: MLKEM1024.PublicKey

    static let xwingSize = 1216
    static let mlkemSize = 1568
    static let xwingCiphertextSize = 1120
    static let mlkemCiphertextSize = 1568

    init(xwing: XWingMLKEM768X25519.PublicKey, mlkem: MLKEM1024.PublicKey) {
        self.xwing = xwing
        self.mlkem = mlkem
    }

    init(xwingRaw: Data, mlkemRaw: Data) throws {
        guard xwingRaw.count == Self.xwingSize, mlkemRaw.count == Self.mlkemSize else { throw CryptoFailure.malformed }
        do {
            xwing = try XWingMLKEM768X25519.PublicKey(rawRepresentation: xwingRaw)
            mlkem = try MLKEM1024.PublicKey(rawRepresentation: mlkemRaw)
        } catch { throw CryptoFailure.malformed }
    }

    var xwingRaw: Data { xwing.rawRepresentation }
    var mlkemRaw: Data { mlkem.rawRepresentation }
}

nonisolated struct KEMPrivatePair: Sendable {
    let xwing: XWingMLKEM768X25519.PrivateKey
    let mlkem: MLKEM1024.PrivateKey

    static func generate() throws -> KEMPrivatePair {
        do {
            return KEMPrivatePair(xwing: try XWingMLKEM768X25519.PrivateKey.generate(),
                                  mlkem: try MLKEM1024.PrivateKey.generate())
        } catch { throw CryptoFailure.keyGeneration }
    }

    var publicPair: KEMPublicPair { KEMPublicPair(xwing: xwing.publicKey, mlkem: mlkem.publicKey) }
}

/// Encapsulation to both KEMs; returns ciphertexts and the concatenated shared secrets.
nonisolated enum DualKEM {
    static func encapsulate(to pk: KEMPublicPair) throws -> (ctX: Data, ctK: Data, secret: Data) {
        do {
            let a = try pk.xwing.encapsulate()
            let b = try pk.mlkem.encapsulate()
            let s = a.sharedSecret.withUnsafeBytes { Data($0) } + b.sharedSecret.withUnsafeBytes { Data($0) }
            return (a.encapsulated, b.encapsulated, s)
        } catch { throw CryptoFailure.keyGeneration }
    }

    static func decapsulate(ctX: Data, ctK: Data, with sk: KEMPrivatePair) throws -> Data {
        guard ctX.count == KEMPublicPair.xwingCiphertextSize, ctK.count == KEMPublicPair.mlkemCiphertextSize else {
            throw CryptoFailure.malformed
        }
        do {
            let a = try sk.xwing.decapsulate(ctX)
            let b = try sk.mlkem.decapsulate(ctK)
            return a.withUnsafeBytes { Data($0) } + b.withUnsafeBytes { Data($0) }
        } catch { throw CryptoFailure.authentication }
    }
}

// MARK: - DualSeal: one-shot public-key encryption to a (X-Wing, ML-KEM-1024) pair

nonisolated enum DualSeal {
    static let version: UInt8 = 0x44
    static let headerSize = 1 + KEMPublicPair.xwingCiphertextSize + KEMPublicPair.mlkemCiphertextSize

    struct Result {
        let envelope: Data
        /// 32-byte secret both sides can use to derive further keys (e.g. pair root).
        let exporter: Data
        /// Transcript hash binding recipient keys and ciphertexts.
        let transcript: Data
    }

    private static func transcript(aad: Data, pk: KEMPublicPair, ctX: Data, ctK: Data) -> Data {
        var t = Data("PRIVA-DUALSEAL-v1".utf8)
        t.appendField(aad)
        t.appendField(pk.xwingRaw)
        t.appendField(pk.mlkemRaw)
        t.appendField(ctX)
        t.appendField(ctK)
        return KDF.sha512(t)
    }

    /// Two-step sealing: encapsulate first so the caller can sign the transcript, then seal.
    struct Sealer {
        let ctX: Data
        let ctK: Data
        let transcript: Data
        let exporter: Data
        private let key: DualKey

        init(to pk: KEMPublicPair, aad: Data) throws {
            let (x, k, ss) = try DualKEM.encapsulate(to: pk)
            ctX = x
            ctK = k
            transcript = DualSeal.transcript(aad: aad, pk: pk, ctX: x, ctK: k)
            let okm = KDF.derive(ss, salt: transcript, info: Data("priva/dualseal/keys".utf8), count: 96)
            key = DualKey(okm.prefix(64))
            exporter = okm.suffix(32).detached
        }

        func seal(_ plaintext: Data) throws -> Result {
            var env = Data([DualSeal.version])
            env.append(ctX)
            env.append(ctK)
            env.append(try DualAEAD.seal(plaintext, key: key, nonce: Data(count: 12), aad: transcript))
            return Result(envelope: env, exporter: exporter, transcript: transcript)
        }
    }

    static func seal(_ plaintext: Data, to pk: KEMPublicPair, aad: Data) throws -> Result {
        try Sealer(to: pk, aad: aad).seal(plaintext)
    }

    static func open(_ envelope: Data, with sk: KEMPrivatePair, aad: Data) throws -> (plaintext: Data, result: Result) {
        var r = ByteReader(envelope)
        guard (try? r.readByte()) == version else { throw CryptoFailure.malformed }
        let ctX = try r.read(KEMPublicPair.xwingCiphertextSize)
        let ctK = try r.read(KEMPublicPair.mlkemCiphertextSize)
        let body = r.readRest()
        let ss = try DualKEM.decapsulate(ctX: ctX, ctK: ctK, with: sk)
        let th = transcript(aad: aad, pk: sk.publicPair, ctX: ctX, ctK: ctK)
        let okm = KDF.derive(ss, salt: th, info: Data("priva/dualseal/keys".utf8), count: 96)
        let pt = try DualAEAD.open(body, key: DualKey(okm.prefix(64)), nonce: Data(count: 12), aad: th)
        return (pt, Result(envelope: envelope, exporter: okm.suffix(32).detached, transcript: th))
    }
}

// MARK: - Hybrid signatures (Ed25519 AND ML-DSA-65)

nonisolated struct HybridSigningKey: Sendable {
    let ed: Curve25519.Signing.PrivateKey
    let pq: MLDSA65.PrivateKey

    static let signatureSize = 64 + 3309

    func sign(_ message: Data) throws -> Data {
        do {
            return try ed.signature(for: message) + pq.signature(for: message)
        } catch { throw CryptoFailure.keyGeneration }
    }

    var verifying: HybridVerifyingKey { HybridVerifyingKey(ed: ed.publicKey, pq: pq.publicKey) }
}

nonisolated struct HybridVerifyingKey: Sendable {
    let ed: Curve25519.Signing.PublicKey
    let pq: MLDSA65.PublicKey

    static let edSize = 32
    static let pqSize = 1952

    init(ed: Curve25519.Signing.PublicKey, pq: MLDSA65.PublicKey) {
        self.ed = ed
        self.pq = pq
    }

    init(edRaw: Data, pqRaw: Data) throws {
        guard edRaw.count == Self.edSize, pqRaw.count == Self.pqSize else { throw CryptoFailure.malformed }
        do {
            ed = try Curve25519.Signing.PublicKey(rawRepresentation: edRaw)
            pq = try MLDSA65.PublicKey(rawRepresentation: pqRaw)
        } catch { throw CryptoFailure.malformed }
    }

    /// Both signatures must verify; evaluation is not short-circuited.
    func verify(_ signature: Data, for message: Data) -> Bool {
        guard signature.count == HybridSigningKey.signatureSize else { return false }
        let s = signature.detached
        let edOK = ed.isValidSignature(s.prefix(64), for: message)
        let pqOK = pq.isValidSignature(s.suffix(3309), for: message)
        return edOK && pqOK
    }
}
