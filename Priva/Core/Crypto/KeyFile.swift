import Foundation

/// A downloadable copy of a 24-word key, the recovery phrase or the Backup Key, for people who'd rather keep a file
/// than paper. It opens only with the Priva password, and only in Priva on the Apple Account that bought it: the App
/// Store's appTransactionID is part of the key. The app reads that ID from StoreKit when it seals or opens a file and
/// never sends it anywhere for this.
///
///   file = "PRIVAKEY" | u32 coreLen | core JSON | DualAEAD(k, aad = H)(32-byte key)
///   H    = SHA-512("PRIVAKEY" ‖ core JSON)
///   k    = DualKey(scrypt(password, salt) ‖ SHA-256(appTransactionID), "PRIVA-KEYFILE-v1", kind ‖ H)
///
/// The password is stretched like a backup's (scrypt, 128 MiB), so a stolen file is as hard to guess as a backup.
nonisolated enum KeyFile {
    enum Kind: String, Codable, Sendable { case recovery, backup }
    enum Failure: Error, Equatable { case notAKeyFile, wrongKind(Kind), wrongPasswordOrAccount }

    struct Header: Codable, Sendable, Equatable {
        var version = 1
        let kind: Kind
        let created: Date
        let salt: Data
        let rounds: Int
    }

    static let magic = Data("PRIVAKEY".utf8)
    static let maxSize = 16 * 1024
    private static let boxSize = DualAEAD.nonceSize + 32 + DualAEAD.overhead

    static func fileName(_ kind: Kind) -> String { kind == .recovery ? "Priva Recovery Key" : "Priva Backup Key" }

    static func seal(_ secret: Data, kind: Kind, password: String, purchaseID: String,
                     rounds: Int = BackupPasswordKDF.defaultRounds, created: Date = .now) throws -> Data {
        precondition(secret.count == 32)
        let header = Header(kind: kind, created: created, salt: Bytes.random(32), rounds: rounds)
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        enc.dateEncodingStrategy = .secondsSince1970
        let core = try enc.encode(header)
        let hash = KDF.sha512(magic, core)
        var out = magic
        out.appendBE(UInt32(core.count))
        out.append(core)
        let pw = try stretch(password, header)
        out.append(try DualAEAD.sealRandom(secret, key: key(header, hash: hash, stretched: pw, purchaseID: purchaseID), aad: hash))
        return out
    }

    /// The public header (which key it holds): no password needed.
    static func peek(_ file: Data) throws -> Header { try parse(file).header }

    /// The 32-byte key. Any wrong factor, password, Apple Account, a changed byte, is the same error.
    static func open(_ file: Data, expecting kind: Kind, password: String, purchaseID: String) throws -> Data {
        try open(file, expecting: kind, password: password, purchaseIDs: [purchaseID])
    }

    /// Tries each purchase ID (this Apple Account's, ones saved in the vault, one the user typed) after a single
    /// password stretch: the stretch is the slow part, an extra ID costs microseconds.
    static func open(_ file: Data, expecting kind: Kind, password: String, purchaseIDs: [String]) throws -> Data {
        let (header, hash, box) = try parse(file)
        guard header.kind == kind else { throw Failure.wrongKind(header.kind) }
        let pw = try stretch(password, header)
        for id in purchaseIDs {
            let k = key(header, hash: hash, stretched: pw, purchaseID: id)
            if let secret = try? DualAEAD.openRandom(box, key: k, aad: hash), secret.count == 32 { return secret }
        }
        throw Failure.wrongPasswordOrAccount
    }

    private static func stretch(_ password: String, _ header: Header) throws -> Data {
        // The header's rounds are bounded before any memory is reserved (a crafted file can't ask for a gigabyte).
        do { return try BackupPasswordKDF.derive(password, salt: header.salt, rounds: header.rounds) } catch { throw Failure.notAKeyFile }
    }

    private static func key(_ header: Header, hash: Data, stretched pw: Data, purchaseID: String) -> DualKey {
        let account = KDF.sha256(Data("priva/keyfile/purchase|\(normalized(purchaseID))".utf8))
        return DualKey.derive(from: pw + account, salt: Data("PRIVA-KEYFILE-v1".utf8), info: "\(header.kind.rawValue)|" + hash.hex)
    }

    /// A typed-in ID may carry spaces or a line break from copying.
    static func normalized(_ purchaseID: String) -> String { purchaseID.filter { !$0.isWhitespace } }

    private static func parse(_ file: Data) throws -> (header: Header, hash: Data, box: Data) {
        let f = file.detached
        let start = magic.count + 4
        guard f.count <= maxSize, f.count > start, f.prefix(magic.count) == magic else { throw Failure.notAKeyFile }
        let len = Int(f[magic.count..<start].reduce(0) { ($0 << 8) | UInt32($1) })
        guard len > 0, len < 4096, f.count == start + len + boxSize else { throw Failure.notAKeyFile }
        let core = f.subdata(in: start..<(start + len))
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        guard let header = try? dec.decode(Header.self, from: core), header.version == 1, header.salt.count >= 16 else {
            throw Failure.notAKeyFile
        }
        return (header, KDF.sha512(magic, core), f.subdata(in: (start + len)..<f.count))
    }
}
