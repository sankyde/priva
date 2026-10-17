import Compression
import CryptoExtras
import CryptoKit
import Foundation

/// Encrypted backup container (docs/BACKUP_DESIGN.md §4–5).
///
///   file  = "PRIVABK1" | u32 coreLen | core JSON | u32 wrapLen | wrapped CK | frames…
///   frame = u32 len | DualAEAD(k_frames, nonce = i, aad = H ‖ i ‖ final)(u8 type | u8 flags | payload)
///   H     = SHA-512("PRIVABK1" ‖ core JSON): binds every frame and the key wrap to this exact header
nonisolated enum BackupError: Error, Equatable {
    case notABackup, unsupportedVersion, corrupted, wrongKey, needsKeychainFactor, truncated, tooLarge
}

// MARK: - The 24-word Backup Key (factor F1)

nonisolated struct BackupKey: Sendable {
    let entropy: Data            // 256 bits

    static func generate() -> BackupKey { BackupKey(entropy: Bytes.random(32)) }

    init(entropy: Data) { self.entropy = entropy.detached }

    init(words: [String]) throws {
        do { entropy = try RecoveryPhrase.decode(words) } catch { throw BackupError.wrongKey }
    }

    init(text: String) throws {
        do { entropy = try RecoveryPhrase.decode(text) } catch { throw BackupError.wrongKey }
    }

    var words: [String] { RecoveryPhrase.encode(entropy) }

    /// Memory-hard stretch (defence in depth even at 256 bits), then deterministic hybrid PQ key pair.
    func keyPair() throws -> KEMPrivatePair {
        let k = try CryptoExtras.KDF.Scrypt.deriveKey(
            from: entropy, salt: Data("priva.backup.key.v1".utf8), outputByteCount: 64,
            rounds: 1 << 16, blockSize: 8, parallelism: 1, maxMemory: 160 * 1024 * 1024).withUnsafeBytes { Data($0) }
        do {
            let xw = try XWingMLKEM768X25519.PrivateKey(seedRepresentation: KDF.derive(k, info: "priva/backup/xwing", count: 32), publicKey: nil)
            let mk = try MLKEM1024.PrivateKey(seedRepresentation: KDF.derive(k, info: "priva/backup/mlkem1024", count: 64), publicKey: nil)
            return KEMPrivatePair(xwing: xw, mlkem: mk)
        } catch { throw CryptoFailure.keyGeneration }
    }

    /// Short, non-secret hint shown in lists so the user knows which key a backup needs.
    static func hint(for pk: KEMPublicPair) -> String {
        String(KDF.sha256(pk.xwingRaw + pk.mlkemRaw).hex.prefix(8)).uppercased()
    }
}

/// Factor F2: the Priva password, stretched with scrypt (N = 2¹⁷, r = 8 → 128 MiB).
nonisolated enum BackupPasswordKDF {
    static let defaultRounds = 1 << 17

    /// A file's header says how hard to stretch; anything above 2¹⁸ (256 MiB) is refused before any memory is
    /// reserved: a crafted backup must not be able to crash the app by asking for a gigabyte.
    static let maxRounds = 1 << 18

    static func derive(_ password: String, salt: Data, rounds: Int = defaultRounds) throws -> Data {
        guard (1 << 14...maxRounds).contains(rounds), rounds.nonzeroBitCount == 1 else { throw BackupError.corrupted }
        return try CryptoExtras.KDF.Scrypt.deriveKey(
            from: Data(password.precomposedStringWithCanonicalMapping.utf8), salt: salt, outputByteCount: 32,
            rounds: rounds, blockSize: 8, parallelism: 1, maxMemory: 300 * 1024 * 1024).withUnsafeBytes { Data($0) }
    }
}

// MARK: - Header

nonisolated struct BackupHeader: Codable, Sendable, Equatable {
    var version = 1
    let id: Data                 // 16 random bytes
    let created: Date
    let keyHint: String          // which Backup Key opens it (non-secret)
    let pwSalt: Data
    let pwRounds: Int
    let usesKeychain: Bool
    let ctX: Data                // X-Wing ciphertext
    let ctK: Data                // ML-KEM-1024 ciphertext
}

/// What the writer needs, never the Backup Key itself.
nonisolated struct BackupWriteKeys: Sendable {
    let publicKey: KEMPublicPair
    let passwordKey: Data        // K₂
    let passwordSalt: Data
    let passwordRounds: Int
    let keychainSecret: Data?    // S
}

nonisolated enum BackupFrameType: UInt8, Sendable {
    case manifest = 1, records = 2, mediaStart = 3, mediaBytes = 4, mediaEnd = 5, padding = 6, end = 0xFF
}

nonisolated enum BackupFormat {
    static let magic = Data("PRIVABK1".utf8)
    static let maxFrame = 4 * 1024 * 1024
    static let maxDecompressed = 64 * 1024 * 1024
    static let padUnit: Int64 = 64 * 1024

    static func headerHash(_ core: Data) -> Data { KDF.sha512(magic, core) }

    static func wrapKey(secret: Data, passwordKey: Data, keychain: Data?, id: Data, hash: Data) -> DualKey {
        DualKey.derive(from: secret + passwordKey + (keychain ?? Data()),
                       salt: Data("PRIVA-BACKUP-v1".utf8) + id, info: "wrap|" + hash.hex)
    }

    static func frameKey(_ ck: Data) -> DualKey { DualKey.derive(from: ck, info: "priva/backup/frames/v1") }

    static func frameAAD(_ hash: Data, index: UInt64, final: Bool) -> Data {
        var d = hash
        d.appendBE(index)
        d.append(final ? 1 : 0)
        return d
    }

    // Bounded LZFSE (a decompression bomb can't exhaust memory).
    static func compress(_ d: Data) -> Data? {
        guard !d.isEmpty else { return nil }
        let cap = d.count + 64
        var out = Data(count: cap)
        let n = out.withUnsafeMutableBytes { dst in
            d.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, cap,
                                          src.bindMemory(to: UInt8.self).baseAddress!, d.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard n > 0, n < d.count else { return nil }
        return out.prefix(n)
    }

    static func decompress(_ d: Data, expected: Int) throws -> Data {
        guard expected > 0, expected <= maxDecompressed else { throw BackupError.tooLarge }
        // One spare byte: output that doesn't end exactly at the declared size is rejected either way.
        var out = Data(count: expected + 1)
        let n = out.withUnsafeMutableBytes { dst in
            d.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, expected + 1,
                                          src.bindMemory(to: UInt8.self).baseAddress!, d.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard n == expected else { throw BackupError.corrupted }
        return out.prefix(expected)
    }
}

// MARK: - Writer

/// Streams a backup to disk. Content key and frame key exist only in memory.
nonisolated final class BackupWriter {
    let header: BackupHeader
    private let handle: FileHandle
    private let hash: Data
    private let key: DualKey
    private var index: UInt64 = 0
    private(set) var bytesWritten: Int64 = 0
    private(set) var plainBytes: Int64 = 0
    private var finished = false

    init(url: URL, keys: BackupWriteKeys, created: Date = .now) throws {
        let (ctX, ctK, ss) = try DualKEM.encapsulate(to: keys.publicKey)
        header = BackupHeader(id: Bytes.random(16), created: created, keyHint: BackupKey.hint(for: keys.publicKey),
                              pwSalt: keys.passwordSalt, pwRounds: keys.passwordRounds,
                              usesKeychain: keys.keychainSecret != nil, ctX: ctX, ctK: ctK)
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        enc.dateEncodingStrategy = .secondsSince1970
        let core = try enc.encode(header)
        hash = BackupFormat.headerHash(core)
        let ck = Bytes.random(32)
        let wk = BackupFormat.wrapKey(secret: ss, passwordKey: keys.passwordKey, keychain: keys.keychainSecret, id: header.id, hash: hash)
        let wrapped = try DualAEAD.sealRandom(ck, key: wk, aad: hash)
        key = BackupFormat.frameKey(ck)

        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete])
        handle = try FileHandle(forWritingTo: url)
        var head = BackupFormat.magic
        head.appendBE(UInt32(core.count)); head.append(core)
        head.appendBE(UInt32(wrapped.count)); head.append(wrapped)
        try handle.write(contentsOf: head)
        bytesWritten = Int64(head.count)
    }

    deinit { try? handle.close() }

    func write(_ type: BackupFrameType, _ payload: Data, compress: Bool = true) throws {
        precondition(!finished)
        try emit(type, payload, compress: compress, final: false)
    }

    func writeJSON<T: Encodable>(_ type: BackupFrameType, _ value: T, compress: Bool = true) throws {
        try write(type, try Self.encode(value), compress: compress)
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        enc.outputFormatting = [.sortedKeys]        // deterministic bytes: a frame's size depends only on its content
        return try enc.encode(value)
    }

    /// Room for a frame's type byte, length and seals under the reader's limit.
    static let recordsBudget = BackupFormat.maxFrame - 64 * 1024

    /// The reader refuses frames over `BackupFormat.maxFrame`, so records that don't fit one frame are split across
    /// several (the reader merges them). A single record too big for any frame fails the backup, instead of writing
    /// one that could never be restored (found 2026-10-15: years of calls, settings or group queues outgrew it).
    func writeRecords<T>(_ items: [T], compress: Bool, _ make: ([T]) -> BackupRecords) throws {
        guard !items.isEmpty else { return }
        let data = try Self.encode(make(items))
        if data.count <= Self.recordsBudget { try write(.records, data, compress: compress); return }
        guard items.count > 1 else { throw BackupError.tooLarge }
        let mid = items.count / 2
        try writeRecords(Array(items[..<mid]), compress: compress, make)
        try writeRecords(Array(items[mid...]), compress: compress, make)
    }

    #if DEBUG
    /// Tests only: every frame's type, whether it was compressed, its plaintext and its sealed size.
    nonisolated(unsafe) static var debugOnFrame: ((BackupFrameType, Bool, Data, Int) -> Void)?
    #endif

    /// Pads to a multiple of 64 KiB (the size reveals little) and seals with the authenticated end frame.
    func finish() throws {
        guard !finished else { return }
        let overhead: Int64 = 4 + 2 + Int64(DualAEAD.overhead)
        let afterEnd = bytesWritten + 2 * overhead
        let target = (afterEnd + BackupFormat.padUnit - 1) / BackupFormat.padUnit * BackupFormat.padUnit
        try emit(.padding, Data(count: Int(max(0, target - afterEnd))), compress: false, final: false)
        try emit(.end, Data(), compress: false, final: true)
        finished = true
        try handle.synchronize()
        try handle.close()
    }

    private func emit(_ type: BackupFrameType, _ payload: Data, compress: Bool, final: Bool) throws {
        var body = Data([type.rawValue])
        if compress, let z = BackupFormat.compress(payload) {
            body.append(1)
            body.appendBE(UInt32(payload.count))
            body.append(z)
        } else {
            body.append(0)
            body.append(payload)
        }
        let sealed = try DualAEAD.seal(body, key: key, nonce: DualAEAD.nonce(counter: index),
                                       aad: BackupFormat.frameAAD(hash, index: index, final: final))
        var out = Data()
        out.appendBE(UInt32(sealed.count))
        out.append(sealed)
        #if DEBUG
        Self.debugOnFrame?(type, body[body.startIndex + 1] == 1, payload, sealed.count)
        #endif
        try handle.write(contentsOf: out)
        bytesWritten += Int64(out.count)
        plainBytes += Int64(payload.count)
        index += 1
    }
}

// MARK: - Reader

nonisolated final class BackupReader {
    let header: BackupHeader
    private let handle: FileHandle
    private let hash: Data
    private let key: DualKey
    private var index: UInt64 = 0
    private(set) var ended = false

    /// Reads only the public header (for listing backups): no keys needed.
    static func peek(_ url: URL) throws -> BackupHeader {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        return try readPrologue(h).header
    }

    private static func readPrologue(_ h: FileHandle) throws -> (header: BackupHeader, core: Data, wrapped: Data) {
        guard let magic = try h.read(upToCount: 8), magic == BackupFormat.magic else { throw BackupError.notABackup }
        let coreLen = try readU32(h)
        guard coreLen > 0, coreLen < 64 * 1024, let core = try h.read(upToCount: Int(coreLen)), core.count == coreLen else { throw BackupError.corrupted }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        guard let header = try? dec.decode(BackupHeader.self, from: core) else { throw BackupError.corrupted }
        guard header.version == 1 else { throw BackupError.unsupportedVersion }
        guard header.id.count == 16, header.pwSalt.count >= 16,
              header.ctX.count == KEMPublicPair.xwingCiphertextSize, header.ctK.count == KEMPublicPair.mlkemCiphertextSize else { throw BackupError.corrupted }
        let wrapLen = try readU32(h)
        guard wrapLen < 1024, let wrapped = try h.read(upToCount: Int(wrapLen)), wrapped.count == wrapLen else { throw BackupError.corrupted }
        return (header, core, wrapped)
    }

    private static func readU32(_ h: FileHandle) throws -> UInt32 {
        guard let b = try h.read(upToCount: 4), b.count == 4 else { throw BackupError.truncated }
        return b.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    /// Combines all factors. Throws `.wrongKey` for any wrong factor (no oracle telling which one).
    init(url: URL, backupKey: BackupKey, password: String, keychainSecret: Data?) throws {
        let pair = try backupKey.keyPair()
        handle = try FileHandle(forReadingFrom: url)
        let (header, core, wrapped) = try Self.readPrologue(handle)
        if header.usesKeychain && keychainSecret == nil { throw BackupError.needsKeychainFactor }
        self.header = header
        hash = BackupFormat.headerHash(core)
        let pwKey = try BackupPasswordKDF.derive(password, salt: header.pwSalt, rounds: header.pwRounds)
        let ss: Data
        do { ss = try DualKEM.decapsulate(ctX: header.ctX, ctK: header.ctK, with: pair) } catch { throw BackupError.wrongKey }
        let wk = BackupFormat.wrapKey(secret: ss, passwordKey: pwKey, keychain: header.usesKeychain ? keychainSecret : nil,
                                      id: header.id, hash: hash)
        guard let ck = try? DualAEAD.openRandom(wrapped, key: wk, aad: hash), ck.count == 32 else { throw BackupError.wrongKey }
        key = BackupFormat.frameKey(ck)
    }

    deinit { try? handle.close() }

    /// Next frame, in order; `nil` after the authenticated end frame. Any tampering throws.
    func next() throws -> (type: BackupFrameType, payload: Data)? {
        guard !ended else { return nil }
        guard let lenData = try handle.read(upToCount: 4), lenData.count == 4 else { throw BackupError.truncated }
        let len = Int(lenData.reduce(0) { ($0 << 8) | UInt32($1) })
        guard len >= DualAEAD.overhead + 2, len <= BackupFormat.maxFrame + 64 else { throw BackupError.corrupted }
        guard let sealed = try handle.read(upToCount: len), sealed.count == len else { throw BackupError.truncated }
        // The end frame is the only one sealed with final = 1: try non-final first, then final.
        let nonce = DualAEAD.nonce(counter: index)
        var final = false
        let body: Data
        if let b = try? DualAEAD.open(sealed, key: key, nonce: nonce, aad: BackupFormat.frameAAD(hash, index: index, final: false)) {
            body = b
        } else if let b = try? DualAEAD.open(sealed, key: key, nonce: nonce, aad: BackupFormat.frameAAD(hash, index: index, final: true)) {
            body = b
            final = true
        } else {
            throw BackupError.corrupted
        }
        index += 1
        guard body.count >= 2, let type = BackupFrameType(rawValue: body[body.startIndex]) else { throw BackupError.corrupted }
        let flags = body[body.startIndex + 1]
        var payload = body.dropFirst(2).detached
        if flags & 1 == 1 {
            guard payload.count > 4 else { throw BackupError.corrupted }
            let n = Int(payload.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) })
            payload = try BackupFormat.decompress(payload.dropFirst(4).detached, expected: n)
        }
        if final {
            guard type == .end else { throw BackupError.corrupted }
            // Nothing may follow the end frame.
            if let extra = try handle.read(upToCount: 1), !extra.isEmpty { throw BackupError.corrupted }
            ended = true
            return nil
        }
        guard type != .end else { throw BackupError.corrupted }
        return (type, payload)
    }

    func decodeJSON<T: Decodable>(_ t: T.Type, _ payload: Data) throws -> T {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        do { return try dec.decode(t, from: payload) } catch { throw BackupError.corrupted }
    }
}
