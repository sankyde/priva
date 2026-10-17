import CryptoKit
import Foundation

/// Priva File Encryption v1 ("PFE1"): random-access, streaming AES-256-GCM.
///
///   header(24) = "PFE1" | ver(1) | rsv(3) | chunkSize(u32) | plainSize(u64) | nonceSalt(4)
///   chunk i    = AES-GCM(key, nonce = salt ‖ i(u64), aad = header ‖ i ‖ isLast) → ct ‖ tag(16)
///
/// The AAD binds each chunk to its position, the file header and the final-chunk flag, so
/// chunks cannot be reordered, dropped, duplicated or the file truncated undetected.
nonisolated struct FileCipherHeader: Sendable, Equatable {
    static let size = 24
    static let defaultChunk = 128 * 1024  // + framing stays well under the 256 KiB SCTP message cap

    let chunkSize: Int
    let plainSize: UInt64
    let nonceSalt: Data

    var chunkCount: Int { plainSize == 0 ? 1 : Int((plainSize + UInt64(chunkSize) - 1) / UInt64(chunkSize)) }
    var encryptedSize: UInt64 { UInt64(Self.size) + plainSize + UInt64(chunkCount * 16) }

    func plainLength(ofChunk i: Int) -> Int {
        if i < chunkCount - 1 { return chunkSize }
        return Int(plainSize) - (chunkCount - 1) * chunkSize
    }

    func encryptedOffset(ofChunk i: Int) -> UInt64 { UInt64(Self.size) + UInt64(i) * UInt64(chunkSize + 16) }
    func encryptedLength(ofChunk i: Int) -> Int { plainLength(ofChunk: i) + 16 }

    var encoded: Data {
        var d = Data("PFE1".utf8)
        d.append(contentsOf: [1, 0, 0, 0])
        d.appendBE(UInt32(chunkSize))
        d.appendBE(plainSize)
        d.append(nonceSalt)
        return d
    }

    init(chunkSize: Int, plainSize: UInt64, nonceSalt: Data) {
        self.chunkSize = chunkSize
        self.plainSize = plainSize
        self.nonceSalt = nonceSalt
    }

    init(_ data: Data) throws {
        var r = ByteReader(data)
        guard try r.read(4) == Data("PFE1".utf8), try r.readByte() == 1 else { throw CryptoFailure.malformed }
        _ = try r.read(3)
        chunkSize = Int(try r.readBE(UInt32.self))
        plainSize = try r.readBE(UInt64.self)
        nonceSalt = try r.read(4)
        guard (4096...(4 << 20)).contains(chunkSize), plainSize <= 1 << 40 else { throw CryptoFailure.malformed }
    }
}

nonisolated enum FileCipher {
    static func nonce(_ h: FileCipherHeader, _ i: Int) throws -> AES.GCM.Nonce {
        var n = h.nonceSalt
        n.appendBE(UInt64(i))
        return try AES.GCM.Nonce(data: n)
    }

    static func aad(_ h: FileCipherHeader, _ i: Int) -> Data {
        var a = h.encoded
        a.appendBE(UInt64(i))
        a.append(i == h.chunkCount - 1 ? 1 : 0)
        return a
    }

    static func sealChunk(_ plain: Data, index: Int, header: FileCipherHeader, key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.seal(plain, using: key, nonce: nonce(header, index), authenticating: aad(header, index))
        return Data(box.ciphertext + box.tag)
    }

    static func openChunk(_ enc: Data, index: Int, header: FileCipherHeader, key: SymmetricKey) throws -> Data {
        guard enc.count == header.encryptedLength(ofChunk: index) else { throw CryptoFailure.malformed }
        let e = enc.detached
        do {
            let box = try AES.GCM.SealedBox(nonce: nonce(header, index), ciphertext: e.dropLast(16), tag: e.suffix(16))
            return try AES.GCM.open(box, using: key, authenticating: aad(header, index))
        } catch { throw CryptoFailure.authentication }
    }

    /// Streams `source` into an encrypted file. Returns the header and SHA-256 of the plaintext.
    static func encrypt(file source: URL, to destination: URL, key: SymmetricKey,
                        chunkSize: Int = FileCipherHeader.defaultChunk,
                        progress: ((Double) -> Void)? = nil) throws -> (FileCipherHeader, Data) {
        let size = (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.uint64Value ?? 0
        let header = FileCipherHeader(chunkSize: chunkSize, plainSize: size, nonceSalt: Bytes.random(4))
        FileManager.default.createFile(atPath: destination.path, contents: nil,
                                       attributes: [.protectionKey: FileProtectionType.complete])
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? input.close(); try? output.close() }
        try output.write(contentsOf: header.encoded)
        var hasher = SHA256()
        for i in 0..<header.chunkCount {
            try autoreleasepool {
                let plain = try input.read(upToCount: header.plainLength(ofChunk: i)) ?? Data()
                guard plain.count == header.plainLength(ofChunk: i) else { throw CryptoFailure.malformed }
                hasher.update(data: plain)
                try output.write(contentsOf: sealChunk(plain, index: i, header: header, key: key))
            }
            progress?(Double(i + 1) / Double(header.chunkCount))
        }
        return (header, Data(hasher.finalize()))
    }

    static func encrypt(data: Data, to destination: URL, key: SymmetricKey) throws -> FileCipherHeader {
        let header = FileCipherHeader(chunkSize: FileCipherHeader.defaultChunk, plainSize: UInt64(data.count), nonceSalt: Bytes.random(4))
        var out = header.encoded
        for i in 0..<header.chunkCount {
            let start = i * header.chunkSize
            let chunk = data.subdata(in: start..<(start + header.plainLength(ofChunk: i)))
            out.append(try sealChunk(chunk, index: i, header: header, key: key))
        }
        try out.write(to: destination, options: [.atomic, .completeFileProtection])
        return header
    }

    /// Random-access reader for an encrypted file (used for sending and for playback).
    final class Reader {
        let header: FileCipherHeader
        private let handle: FileHandle
        private let key: SymmetricKey?

        init(url: URL, key: SymmetricKey? = nil) throws {
            handle = try FileHandle(forReadingFrom: url)
            header = try FileCipherHeader(try handle.read(upToCount: FileCipherHeader.size) ?? Data())
            self.key = key
        }

        deinit { try? handle.close() }

        func encryptedChunk(_ i: Int) throws -> Data {
            try handle.seek(toOffset: header.encryptedOffset(ofChunk: i))
            guard let d = try handle.read(upToCount: header.encryptedLength(ofChunk: i)),
                  d.count == header.encryptedLength(ofChunk: i) else { throw CryptoFailure.malformed }
            return d
        }

        func plainChunk(_ i: Int) throws -> Data {
            guard let key else { throw CryptoFailure.malformed }
            return try FileCipher.openChunk(try encryptedChunk(i), index: i, header: header, key: key)
        }

        /// Decrypts an arbitrary plaintext byte range (AVAssetResourceLoader, thumbnails).
        func plainRange(offset: UInt64, length: Int) throws -> Data {
            guard length > 0, offset < header.plainSize else { return Data() }
            let end = min(header.plainSize, offset + UInt64(length))
            let first = Int(offset / UInt64(header.chunkSize)), last = Int((end - 1) / UInt64(header.chunkSize))
            var out = Data(capacity: Int(end - offset))
            for i in first...last {
                let chunk = try plainChunk(i)
                let chunkStart = UInt64(i) * UInt64(header.chunkSize)
                let lo = Int(max(offset, chunkStart) - chunkStart)
                let hi = Int(min(end, chunkStart + UInt64(chunk.count)) - chunkStart)
                out.append(chunk.subdata(in: lo..<hi))
            }
            return out
        }

        func decryptAll() throws -> Data {
            var out = Data(capacity: Int(header.plainSize))
            for i in 0..<header.chunkCount { out.append(try plainChunk(i)) }
            return out
        }
    }

    /// Receiver-side writer: verifies every chunk before accepting it; tracks which arrived. Thread-safe: chunks
    /// are written on a link's bulk thread while the main thread asks what's still missing.
    final class Writer: @unchecked Sendable {
        let header: FileCipherHeader
        let url: URL
        private let handle: FileHandle
        private let key: SymmetricKey
        private let lock = NSLock()
        private var have: IndexSet
        var received: IndexSet { lock.lock(); defer { lock.unlock() }; return have }

        init(url: URL, header: FileCipherHeader, key: SymmetricKey, resume: Bool) throws {
            self.header = header
            self.url = url
            self.key = key
            let fm = FileManager.default
            if !resume || !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete])
            }
            handle = try FileHandle(forUpdating: url)
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: header.encoded)
            have = IndexSet()
        }

        deinit { try? handle.close() }

        func markReceived(_ set: IndexSet) { lock.lock(); have = set; lock.unlock() }

        func write(chunk enc: Data, index i: Int) throws {
            guard (0..<header.chunkCount).contains(i) else { throw CryptoFailure.malformed }
            _ = try FileCipher.openChunk(enc, index: i, header: header, key: key)
            lock.lock()
            defer { lock.unlock() }
            try handle.seek(toOffset: header.encryptedOffset(ofChunk: i))
            try handle.write(contentsOf: enc)
            have.insert(i)
        }

        var isComplete: Bool { received.count == header.chunkCount }

        func finish() throws { lock.lock(); defer { lock.unlock() }; try handle.synchronize() }
    }
}
