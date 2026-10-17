import CryptoExtras
import CryptoKit
import Foundation

/// Every long-term key is derived from one 32-byte master seed (shown to the user as a
/// 24-word recovery phrase).
nonisolated struct IdentityKeys: Sendable {
    let seed: Data
    let signing: HybridSigningKey
    let kem: KEMPrivatePair
    let inboxSecret: Data

    static let seedSize = 32

    init(seed: Data) throws {
        guard seed.count == Self.seedSize else { throw CryptoFailure.malformed }
        self.seed = seed.detached
        do {
            let ed = try Curve25519.Signing.PrivateKey(rawRepresentation: Self.derive(seed, "ed25519", 32))
            let pq = try MLDSA65.PrivateKey(seedRepresentation: Self.derive(seed, "mldsa65", 32), publicKey: nil)
            let xw = try XWingMLKEM768X25519.PrivateKey(seedRepresentation: Self.derive(seed, "xwing", 32), publicKey: nil)
            let mk = try MLKEM1024.PrivateKey(seedRepresentation: Self.derive(seed, "mlkem1024", 64), publicKey: nil)
            signing = HybridSigningKey(ed: ed, pq: pq)
            kem = KEMPrivatePair(xwing: xw, mlkem: mk)
        } catch {
            throw CryptoFailure.keyGeneration
        }
        inboxSecret = Self.derive(seed, "inbox", 32)
    }

    private static func derive(_ seed: Data, _ label: String, _ n: Int) -> Data {
        KDF.derive(seed, salt: Data("priva.identity.v1".utf8), info: Data(label.utf8), count: n)
    }

    static func newSeed() -> Data { Bytes.random(seedSize) }

    /// Topic on which friends reach this identity. Derived from a secret only friends learn.
    var inboxTopic: String {
        "i-" + Base32.encode(KDF.derive(inboxSecret, info: "priva/inbox/v1", count: 20))
    }

    /// Wraps the vault key so a forgotten password can be reset with the recovery phrase.
    var recoveryWrapKey: Data { Self.derive(seed, "recovery/vault-wrap", 32) }

    /// Revocation secret: presenting it removes this identity's username from the directory
    /// (sign-back-in after a reinstall). The server stores only SHA-256 of it.
    var revokeSecret: Data { Self.derive(seed, "revoke/v1", 32) }
    var revokeHash: String { KDF.sha256(revokeSecret).hex }

    /// Shared with every friend: lets them receive a signed rename announcement if this
    /// identity ever moves to a new username (docs/IDENTITY_DESIGN.md §7).
    var announceKey: Data { Self.derive(seed, "announce/v1", 32) }

    func bundle(username: String, day: UInt32 = KeyBundle.today) throws -> KeyBundle {
        try KeyBundle.create(ucommit: try UsernameKey.deriveStrict(username).ucommit, identity: self, day: day)
    }
}

// MARK: - Usernames

nonisolated enum Username {
    static let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_")

    static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "@", with: "")
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: ".", with: "_")
    }

    static func isValid(_ s: String) -> Bool {
        (3...24).contains(s.count) && s.allSatisfy { allowed.contains($0) }
    }

    /// The username in a profile QR code or link (`priva://add/<name>`), or a bare username; nil otherwise.
    static func fromAddLink(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "priva://add/"
        let raw = t.lowercased().hasPrefix(prefix) ? String(t.dropFirst(prefix.count)) : t
        let name = normalize(raw.removingPercentEncoding ?? raw)
        return isValid(name) ? name : nil
    }

    /// 1,024 short BIP-39 words (3–5 letters): 10 bits each.
    static let words: [String] = Array(RecoveryPhrase.words.filter { (3...5).contains($0.count) }.prefix(1024))

    /// Random name: three words + four digits (≈ 43 bits), e.g. `cedar_lunar_pilot_5821`.
    /// `SystemRandomNumberGenerator` is the platform CSPRNG; `random(in:)` is exactly uniform.
    static func random() -> String {
        precondition(words.count == 1024)
        var rng = SystemRandomNumberGenerator()
        let w = (0..<3).map { _ in words[Int.random(in: 0..<1024, using: &rng)] }
        return w.joined(separator: "_") + "_" + String(format: "%04d", Int.random(in: 0..<10_000, using: &rng))
    }

    static let entropyBits: Double = 30 + log2(10_000)
}

/// The username never leaves the device in plaintext. The server stores and is queried with
/// `ucommit`; the friend-request topic comes from an independent branch of the same memory-hard
/// hash, so the server cannot compute any request topic (docs/IDENTITY_DESIGN.md §2.1).
nonisolated enum UsernameKey {
    struct Derived: Sendable { let ucommit: Data; let topicKey: Data }

    static let rounds = 1 << 16
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Derived] = [:]

    enum Failure: Error { case outOfMemory }

    static func derive(_ username: String) -> Derived {
        // scrypt can fail only when 64 MiB can't be had (memory pressure). Fail CLOSED: a random value matches no one
        // and isn't cached, never a shared fallback every username would collapse onto.
        (try? deriveStrict(username)) ?? Derived(ucommit: Bytes.random(32), topicKey: Bytes.random(32))
    }

    /// For this user's own name, which gets stored and registered: a random stand-in would mean never receiving a
    /// friend request, so it throws instead and the caller tries again later (audit STA-32).
    static func deriveStrict(_ username: String) throws -> Derived {
        let name = Username.normalize(username)
        lock.lock()
        if let d = cache[name] { lock.unlock(); return d }
        lock.unlock()
        for attempt in 0..<3 {
            if let s = stretch(name) {
                let d = Derived(ucommit: KDF.derive(s, info: "priva/ucommit", count: 32),
                                topicKey: KDF.derive(s, info: "priva/request-topic", count: 32))
                lock.lock()
                cache[name] = d
                lock.unlock()
                return d
            }
            if attempt < 2 { Thread.sleep(forTimeInterval: 0.05) }
        }
        throw Failure.outOfMemory
    }

    private static func stretch(_ name: String) -> Data? {
        #if DEBUG
        if debugFailStretch { return nil }
        #endif
        return (try? CryptoExtras.KDF.Scrypt.deriveKey(
            from: Data("priva-username-v1|\(name)".utf8), salt: Data("priva.directory.v1".utf8),
            outputByteCount: 64, rounds: rounds, blockSize: 8, parallelism: 1, maxMemory: 160 * 1024 * 1024))?
            .withUnsafeBytes { Data($0) }
    }

    #if DEBUG
    /// Tests only: make scrypt fail (as it would under memory pressure).
    nonisolated(unsafe) static var debugFailStretch = false
    #endif

    static func commitment(_ username: String) -> Data { derive(username).ucommit }

    static func requestTopic(_ username: String) -> String { topic(derive(username)) }

    static func requestTopicStrict(_ username: String) throws -> String { topic(try deriveStrict(username)) }

    private static func topic(_ d: Derived) -> String {
        "r-" + Base32.encode(KDF.derive(d.topicKey, info: "priva/req/v2", count: 20))
    }
}

// MARK: - Key bundle v2

/// Public key bundle (v2). Byte layout is shared with supabase/functions/_shared/bundle.ts.
///
///   "PRVB" | 2 | ucommit(32) | ed25519(32) | mldsa65(1952) | xwing(1216) | mlkem1024(1568) | day(u32 BE)
///   | sig_ed25519(64) | sig_mldsa65(3309)
nonisolated struct KeyBundle: Sendable, Hashable {
    let ucommit: Data
    let verifying: HybridVerifyingKey
    let kem: KEMPublicPair
    let day: UInt32
    let raw: Data

    static let size = 4 + 1 + 32 + 32 + 1952 + 1216 + 1568 + 4 + HybridSigningKey.signatureSize
    static var today: UInt32 { UInt32(Date().timeIntervalSince1970 / 86_400) }
    private static let sigContext = Data("PRIVA-BUNDLE-v2\0".utf8)

    static func create(ucommit: Data, identity: IdentityKeys, day: UInt32) throws -> KeyBundle {
        guard ucommit.count == 32 else { throw CryptoFailure.malformed }
        var d = Data("PRVB".utf8)
        d.append(2)
        d.append(ucommit)
        d.append(identity.signing.verifying.ed.rawRepresentation)
        d.append(identity.signing.verifying.pq.rawRepresentation)
        d.append(identity.kem.publicPair.xwingRaw)
        d.append(identity.kem.publicPair.mlkemRaw)
        d.appendBE(day)
        let sig = try identity.signing.sign(sigContext + d)
        return KeyBundle(ucommit: ucommit.detached, verifying: identity.signing.verifying, kem: identity.kem.publicPair,
                         day: day, raw: d + sig)
    }

    /// Parses AND verifies both self-signatures. Throws on any deviation. Bundles that already verified are
    /// remembered by their exact bytes (contacts' keys are read constantly; ML-DSA verification isn't free).
    static func parse(_ raw: Data) throws -> KeyBundle {
        guard raw.count == size else { throw CryptoFailure.malformed }
        let digest = KDF.sha256(raw)
        verifiedLock.lock()
        let hit = verified[digest]
        verifiedLock.unlock()
        if let hit { return hit }
        let b = try parseAndVerify(raw)
        verifiedLock.lock()
        if verified.count >= 1024 { verified.removeAll() }
        verified[digest] = b
        verifiedLock.unlock()
        return b
    }

    private static let verifiedLock = NSLock()
    nonisolated(unsafe) private static var verified: [Data: KeyBundle] = [:]

    private static func parseAndVerify(_ raw: Data) throws -> KeyBundle {
        var r = ByteReader(raw)
        guard try r.read(4) == Data("PRVB".utf8), try r.readByte() == 2 else { throw CryptoFailure.malformed }
        let ucommit = try r.read(32)
        let verifying = try HybridVerifyingKey(edRaw: try r.read(32), pqRaw: try r.read(1952))
        let kem = try KEMPublicPair(xwingRaw: try r.read(1216), mlkemRaw: try r.read(1568))
        let day = try r.readBE(UInt32.self)
        let signedLength = r.offset
        let sig = try r.read(HybridSigningKey.signatureSize)
        guard r.isAtEnd else { throw CryptoFailure.malformed }
        guard verifying.verify(sig, for: sigContext + raw.detached.prefix(signedLength)) else { throw CryptoFailure.authentication }
        return KeyBundle(ucommit: ucommit, verifying: verifying, kem: kem, day: day, raw: raw.detached)
    }

    /// True if this bundle is bound to `username` (memory-hard; cached per name).
    func belongs(to username: String) -> Bool { Bytes.equal(ucommit, UsernameKey.commitment(username)) }

    /// Canonical public key material (signatures excluded; Ed25519 signatures are randomized).
    var keyMaterial: Data {
        var d = Data()
        d.appendField(ucommit)
        d.appendField(verifying.ed.rawRepresentation)
        d.appendField(verifying.pq.rawRepresentation)
        d.appendField(kem.xwingRaw)
        d.appendField(kem.mlkemRaw)
        return d
    }

    var fingerprint: Data { KDF.sha512(Data("PRIVA-FP-v2".utf8), keyMaterial) }

    static func == (a: KeyBundle, b: KeyBundle) -> Bool { Bytes.equal(a.keyMaterial, b.keyMaterial) }
    func hash(into h: inout Hasher) { h.combine(keyMaterial) }
}

// MARK: - Rename announcements (docs/IDENTITY_DESIGN.md §7)

nonisolated enum Announcement {
    struct Payload: Codable, Sendable {
        let old: String
        let new: String
        let bundle: Data
        let name: String?
        let generation: Int
        let ts: Int64
    }

    static func topic(announceKey: Data) -> String {
        "m-" + Base32.encode(KDF.derive(announceKey, info: "priva/announce/topic", count: 20))
    }

    private static func key(_ announceKey: Data) -> DualKey { DualKey(KDF.derive(announceKey, info: "priva/announce/key", count: 64)) }
    private static let aad = Data("PRIVA-RENAME-v1".utf8)

    /// Sealed with the announce key (friends only) and signed by the OLD identity.
    static func make(old: IdentityKeys, oldUsername: String, newUsername: String, newBundle: KeyBundle,
                     displayName: String?, generation: Int) throws -> Data {
        let payload = try JSONEncoder().encode(Payload(old: oldUsername, new: newUsername, bundle: newBundle.raw,
                                                        name: displayName, generation: generation, ts: Signal.now))
        let sig = try old.signing.sign(aad + KDF.sha512(payload))
        var framed = Data()
        framed.appendField(payload)
        framed.append(sig)
        return try DualAEAD.sealRandom(Padding.pad(framed), key: key(old.announceKey), aad: aad)
    }

    /// Opens and authenticates an announcement from a contact whose keys we pinned.
    static func open(_ envelope: Data, announceKey: Data, pinned: KeyBundle, oldUsername: String) throws -> Payload {
        let framed = try Padding.unpad(try DualAEAD.openRandom(envelope, key: key(announceKey), aad: aad))
        var r = ByteReader(framed)
        let payload = try r.readField(max: 64 * 1024)
        let sig = try r.read(HybridSigningKey.signatureSize)
        guard pinned.verifying.verify(sig, for: aad + KDF.sha512(payload)) else { throw CryptoFailure.authentication }
        let p = try JSONDecoder().decode(Payload.self, from: payload)
        // The topic + pinned-key signature identify the sender; `old` may be empty when the returning
        // user signed back in with only the recovery phrase.
        guard p.old.isEmpty || p.old == oldUsername, Username.isValid(p.new), p.new != oldUsername, (p.name ?? "").count <= 40 else {
            throw CryptoFailure.malformed
        }
        return p
    }

    /// Proof, carried in the friend request to the new name, that the sender knew the announce key.
    static func renameProof(announceKey: Data, friend: String, newUsername: String) -> Data {
        KDF.hmac(announceKey, Data("priva/rename-ack|\(friend)|\(newUsername)".utf8))
    }
}

// MARK: - Moving to a new username after restoring a backup

/// "The holder of @old's keys now lives at @new": signed by the OLD identity (whose keys every friend and group
/// member pinned), bound to the new username's exact keys, the recipient and the time. Carried in the friend
/// request the restored iPhone sends from its new username, and forwarded by group hosts so members can check it.
nonisolated enum MoveProof {
    /// How long a proof is accepted (the restored iPhone retries until friends come online).
    static let validity: TimeInterval = 30 * 86_400

    private static func message(old: String, new: String, newBundle: KeyBundle, to recipient: String, ts: Int64) -> Data {
        var d = Data("PRIVA-MOVED-v1".utf8)
        d.appendField(Data(old.utf8))
        d.appendField(Data(new.utf8))
        d.appendField(newBundle.keyMaterial)
        d.appendField(Data(recipient.utf8))
        d.appendBE(UInt64(bitPattern: ts))
        return KDF.sha512(d)
    }

    static func sign(old identity: IdentityKeys, oldUsername: String, newUsername: String, newBundle: KeyBundle,
                     to recipient: String, ts: Int64) throws -> Data {
        try identity.signing.sign(message(old: oldUsername, new: newUsername, newBundle: newBundle, to: recipient, ts: ts))
    }

    /// `pinned`: the keys we already hold for @old. Fails on any mismatch or a stale/future timestamp.
    static func verify(_ sig: Data, pinned: KeyBundle, old: String, new: String, newBundle: KeyBundle, to recipient: String,
                       ts: Int64, now: Date = Date(timeIntervalSince1970: Double(Signal.now) / 1000)) -> Bool {
        let age = now.timeIntervalSince1970 - Double(ts) / 1000
        guard age < validity, age > -600, old != new, Username.isValid(new), newBundle != pinned else { return false }
        return pinned.verifying.verify(sig, for: message(old: old, new: new, newBundle: newBundle, to: recipient, ts: ts))
    }
}
