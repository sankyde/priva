import CryptoKit
import XCTest
@testable import Priva

/// Encrypted backups (docs/BACKUP_DESIGN.md): round trip, every factor, tampering, size, limits.
nonisolated final class BackupTests: XCTestCase {
    private var tmp: URL!

    override func setUp() {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bk-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    struct Fixture {
        let key: BackupKey
        let password: String
        let keychain: Data
        let keys: BackupWriteKeys
        let store: Store
        let manifest: BackupManifest
        let mediaID: String
        let mediaBytes: Data
    }

    private func fixture(messages: Int = 50, mediaMB: Int = 1, keychain: Bool = true) throws -> Fixture {
        let key = BackupKey.generate()
        let password = "test-\(UUID().uuidString)"
        let salt = Bytes.random(16)
        let secret = Bytes.random(32)
        let keys = BackupWriteKeys(publicKey: try key.keyPair().publicPair,
                                   passwordKey: try BackupPasswordKDF.derive(password, salt: salt),
                                   passwordSalt: salt, passwordRounds: BackupPasswordKDF.defaultRounds,
                                   keychainSecret: keychain ? secret : nil)
        let store = try Store(vaultKey: SymmetricKey(size: .bits256), directory: tmp.appendingPathComponent("src"))
        let id = try IdentityKeys(seed: IdentityKeys.newSeed())
        let friend = try IdentityKeys(seed: IdentityKeys.newSeed())
        try store.upsert(Contact(username: "friend_user_0001", bundleRaw: try friend.bundle(username: "friend_user_0001").raw,
                                 pair: PairSecrets(current: Bytes.random(64), previous: nil, epoch: 3), inboxTopic: "i-abc"))
        var ms: [Message] = []
        for i in 0..<messages {
            ms.append(Message(id: UUID().uuidString, contact: "friend_user_0001", outgoing: i % 2 == 0, kind: .text,
                              text: "message \(i), the quick brown fox jumps over the lazy dog", attachment: nil,
                              sentAt: Date().addingTimeInterval(Double(i)), status: .delivered))
        }
        let mediaID = UUID().uuidString
        let bytes = Bytes.random(mediaMB << 20)
        try bytes.write(to: store.mediaURL(mediaID))
        let att = Attachment(fileID: mediaID, kind: .file, name: "report.pdf", mime: "application/pdf", size: UInt64(bytes.count),
                             key: Bytes.random(32), header: Data(), sha256: KDF.sha256(bytes), progress: 1)
        ms.append(Message(id: UUID().uuidString, contact: "friend_user_0001", outgoing: true, kind: .media, text: nil,
                          attachment: att, sentAt: .now, status: .delivered))
        try store.importMessages(ms)
        try store.set(["grp1"], for: "groups")
        let manifest = BackupManifest(username: "owner_user_0001", seed: id.seed, bundleRaw: try id.bundle(username: "owner_user_0001").raw,
                                      registered: true, created: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded()), displayName: "Owner", messageCount: ms.count,
                                      contactCount: 1, groupCount: 0, mediaCount: 1)
        return Fixture(key: key, password: password, keychain: secret, keys: keys, store: store, manifest: manifest,
                       mediaID: mediaID, mediaBytes: bytes)
    }

    private func write(_ f: Fixture, name: String = "b.privabackup", media: Bool? = nil) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        var manifest = f.manifest
        manifest.includesMedia = media
        _ = try BackupExporter.write(to: url, keys: f.keys, store: f.store, manifest: manifest)
        return url
    }

    private func restore(_ url: URL, _ f: Fixture, key: BackupKey? = nil, password: String? = nil, keychain: Data?? = nil) throws -> (Store, BackupImporter.Result) {
        let r = try BackupReader(url: url, backupKey: key ?? f.key, password: password ?? f.password,
                                 keychainSecret: keychain ?? f.keychain)
        let dst = try Store(vaultKey: SymmetricKey(size: .bits256), directory: tmp.appendingPathComponent("dst-\(UUID().uuidString)"))
        return (dst, try BackupImporter.importAll(r, into: dst))
    }

    // MARK: - round trip

    func testRoundTripRestoresEverythingUnderANewVaultKey() throws {
        let f = try fixture()
        let url = try write(f)
        let (dst, result) = try restore(url, f)
        XCTAssertEqual(result.manifest, f.manifest)
        XCTAssertEqual(result.media, 1)
        XCTAssertEqual(try dst.contacts().map(\.username), ["friend_user_0001"])
        XCTAssertEqual(try dst.contacts().first?.pair.epoch, 3)
        let msgs = try dst.messages(with: "friend_user_0001", limit: 1000)
        XCTAssertEqual(msgs.count, 51)
        XCTAssertEqual(Set(msgs.compactMap(\.text)), Set(try f.store.messages(with: "friend_user_0001", limit: 1000).compactMap(\.text)))
        XCTAssertEqual(try Data(contentsOf: dst.mediaURL(f.mediaID)), f.mediaBytes, "media bit-exact")
        XCTAssertEqual(dst.get([String].self, for: "groups"), ["grp1"])
        // No plaintext anywhere in the file.
        let raw = try Data(contentsOf: url)
        XCTAssertNil(raw.range(of: Data("quick brown fox".utf8)))
        XCTAssertNil(raw.range(of: Data("friend_user_0001".utf8)))
        XCTAssertNil(raw.range(of: Data("owner_user_0001".utf8)))
        XCTAssertNil(raw.range(of: f.manifest.seed))
    }

    /// Years of use: more calls, settings and group queues than one 4 MB frame holds. Backups used to write them
    /// into a single frame the reader then refused as "corrupted": a backup that wrote fine but could never be
    /// restored (found by XD-21, 2026-10-15). They're split across frames now, and everything comes back.
    func testABackupBiggerThanOneFrameStillRestores() throws {
        let f = try fixture(messages: 10, mediaMB: 0)
        let calls = 30_000
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<calls {
            try f.store.save(CallRecord(id: UUID().uuidString, contact: "friend_user_0001", outgoing: i % 2 == 0, video: i % 3 == 0,
                                        startedAt: start.addingTimeInterval(Double(i) * 60), duration: Double(i % 600), outcome: .answered))
        }
        XCTAssertGreaterThan(try BackupWriter.encode(try f.store.calls(limit: 100_000)).count, BackupFormat.maxFrame, "more than one frame's worth")
        let url = try write(f)
        let (dst, result) = try restore(url, f)
        XCTAssertEqual(result.manifest, f.manifest)
        XCTAssertEqual(try dst.calls(limit: 100_000).count, calls, "every call came back")
        XCTAssertEqual(try dst.contacts().map(\.username), ["friend_user_0001"])
        XCTAssertEqual(dst.get([String].self, for: "groups"), ["grp1"])
    }

    /// One record too big for any frame fails the backup out loud, instead of writing a file that can't be restored.
    func testOneRecordTooBigForAnyFrameFailsTheBackup() throws {
        let f = try fixture(messages: 1, mediaMB: 0)
        try f.store.set(String(repeating: "x", count: BackupFormat.maxFrame), for: "huge")
        XCTAssertThrowsError(try write(f)) { XCTAssertEqual($0 as? BackupError, .tooLarge) }
    }

    /// Priva quitting in the middle of a backup: the half-written temp file and an unfinished copy are never listed
    /// as backups, the finished ones are untouched, and the leftovers are cleared at the next launch.
    func testAnInterruptedBackupLeavesNothingThatLooksLikeABackup() throws {
        let f = try fixture(mediaMB: 0)
        let done = try write(f, name: "done.privabackup")
        let dir = tmp.appendingPathComponent("location-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: done, to: dir.appendingPathComponent("done.privabackup"))
        // A copy cut off halfway: its header is intact, the rest isn't.
        let data = try Data(contentsOf: done)
        try data.prefix(data.count / 2).write(to: dir.appendingPathComponent("newer.privabackup.partial"))
        let listed = BackupLocations.files(in: dir, location: .device)
        XCTAssertEqual(listed.map { $0.url.lastPathComponent }, ["done.privabackup"], "only the finished backup is offered")
        // The temp file a killed backup leaves in tmp, and the stale partial, go at the next launch.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".privabackup")
        try data.prefix(100).write(to: temp)
        BackupLocations.removeLeftovers()
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
        XCTAssertNotNil(try BackupReader.peek(dir.appendingPathComponent("done.privabackup")), "the finished backup is untouched")
    }

    /// The default: messages only. The 4 MB photo stays out (the file is a fraction of the size); after a restore the
    /// message is there, marked "not in backup", with no file behind it.
    func testTextOnlyBackupsLeaveMediaOut() throws {
        let f = try fixture(mediaMB: 4)
        let textOnly = try write(f, name: "t.privabackup", media: false)
        let withMedia = try write(f, name: "m.privabackup", media: true)
        let small = try FileManager.default.attributesOfItem(atPath: textOnly.path)[.size] as! Int64
        let big = try FileManager.default.attributesOfItem(atPath: withMedia.path)[.size] as! Int64
        XCTAssertLessThan(small, 512 * 1024, "text only: well under the photo's size")
        XCTAssertGreaterThan(big, 4 << 20, "with media: the photo is in")
        let (dst, result) = try restore(textOnly, f)
        XCTAssertEqual(result.media, 0)
        XCTAssertEqual(result.manifest.includesMedia, false)
        let restored = try dst.messages(with: "friend_user_0001", limit: 1000).compactMap(\.attachment)
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.notBackedUp, true)
        XCTAssertEqual(restored.first?.isComplete, false, "not offered as a file that isn't there")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst.mediaURL(f.mediaID).path))
    }

    /// With "Include photos & files" on, media comes back byte for byte and isn't marked missing.
    func testMediaBackupsWhenChosen() throws {
        let f = try fixture(mediaMB: 4)
        let url = try write(f, media: true)
        let (dst, result) = try restore(url, f)
        XCTAssertEqual(result.media, 1)
        XCTAssertEqual(try Data(contentsOf: dst.mediaURL(f.mediaID)), f.mediaBytes)
        XCTAssertNil(try dst.messages(with: "friend_user_0001", limit: 1000).compactMap(\.attachment).first?.notBackedUp)
    }

    /// The Backup Key saved as a file instead of on paper: the key that comes back opens the backup.
    func testABackupKeyFileOpensTheBackup() throws {
        let f = try fixture(messages: 5)
        let url = try write(f)
        let file = try KeyFile.seal(f.key.entropy, kind: .backup, password: f.password, purchaseID: "2000000123456789", rounds: 1 << 14)
        let key = BackupKey(entropy: try KeyFile.open(file, expecting: .backup, password: f.password, purchaseID: "2000000123456789"))
        XCTAssertEqual(key.words, f.key.words)
        let (_, result) = try restore(url, f, key: key)
        XCTAssertEqual(result.manifest.username, "owner_user_0001")
    }

    /// The purchase IDs kept in the vault travel inside the encrypted backup (never on a server).
    func testSavedPurchaseIDsComeBackWithARestore() throws {
        let f = try fixture(messages: 3)
        try f.store.set(["2000000123456789", "2000000000000001"], for: "purchase.ids")
        let url = try write(f)
        XCTAssertNil(try Data(contentsOf: url).range(of: Data("2000000123456789".utf8)), "not readable in the file")
        let (dst, _) = try restore(url, f)
        XCTAssertEqual(dst.get([String].self, for: "purchase.ids"), ["2000000123456789", "2000000000000001"])
    }

    func testBackupKeyIs24WordsAndRoundTrips() throws {
        let k = BackupKey.generate()
        XCTAssertEqual(k.words.count, 24)
        XCTAssertEqual(try BackupKey(words: k.words).entropy, k.entropy)
        XCTAssertEqual(try BackupKey(text: k.words.joined(separator: "  ").uppercased()).entropy, k.entropy)
        var bad = k.words
        bad.swapAt(0, 1)
        XCTAssertThrowsError(try BackupKey(words: bad), "checksum catches a swapped word (almost always)") { _ in }
        XCTAssertThrowsError(try BackupKey(words: Array(k.words.prefix(23))))
        XCTAssertEqual(BackupKey.hint(for: try k.keyPair().publicPair).count, 8)
        XCTAssertEqual(try k.keyPair().publicPair.xwingRaw, try BackupKey(words: k.words).keyPair().publicPair.xwingRaw, "deterministic key pair")
    }

    // MARK: - every factor is required

    func testEachFactorIsRequired() throws {
        let f = try fixture(messages: 5)
        let url = try write(f)
        XCTAssertThrowsError(try restore(url, f, key: BackupKey.generate())) { XCTAssertEqual($0 as? BackupError, .wrongKey) }
        XCTAssertThrowsError(try restore(url, f, password: f.password + "r")) { XCTAssertEqual($0 as? BackupError, .wrongKey) }
        XCTAssertThrowsError(try restore(url, f, keychain: .some(nil))) { XCTAssertEqual($0 as? BackupError, .needsKeychainFactor) }
        XCTAssertThrowsError(try restore(url, f, keychain: .some(Bytes.random(32)))) { XCTAssertEqual($0 as? BackupError, .wrongKey) }
        XCTAssertNoThrow(try restore(url, f))
    }

    func testBackupWithoutKeychainFactorOpensWithPhraseAndPassword() throws {
        let f = try fixture(messages: 3, mediaMB: 0, keychain: false)
        let url = try write(f)
        XCTAssertEqual(try BackupReader.peek(url).usesKeychain, false)
        XCTAssertNoThrow(try restore(url, f, keychain: .some(nil)))
    }

    // MARK: - tampering

    private func frameOffsets(_ d: Data) -> [(start: Int, end: Int)] {
        func u32(_ i: Int) -> Int { d[i..<i+4].reduce(0) { ($0 << 8) | Int($1) } }
        var p = 8
        p += 4 + u32(p)       // core
        p += 4 + u32(p)       // wrapped
        var out: [(Int, Int)] = []
        while p < d.count { let len = u32(p); out.append((p, p + 4 + len)); p += 4 + len }
        return out
    }

    private func expectRejected(_ data: Data, _ f: Fixture, _ what: String) {
        let url = tmp.appendingPathComponent("t-\(UUID().uuidString).privabackup")
        try? data.write(to: url)
        XCTAssertThrowsError(try restore(url, f), what)
    }

    func testTamperingAnywhereIsRejected() throws {
        let f = try fixture(messages: 200, mediaMB: 1)
        let url = try write(f)
        let good = try Data(contentsOf: url)
        let frames = frameOffsets(good)
        XCTAssertGreaterThan(frames.count, 4)

        var d = good; d[20] ^= 1
        expectRejected(d, f, "header byte flipped")
        let wrapAt = 8 + 4 + good[8..<12].reduce(0) { ($0 << 8) | Int($1) } + 10
        d = good; d[wrapAt] ^= 1
        expectRejected(d, f, "wrapped key flipped")
        d = good; d[frames[1].start + 20] ^= 1
        expectRejected(d, f, "frame byte flipped")
        expectRejected(good.prefix(frames.last!.start), f, "end frame cut off (truncation)")
        expectRejected(good.prefix(frames[2].start), f, "cut mid-backup")
        d = good; d.removeSubrange(frames[1].start..<frames[1].end)
        expectRejected(d, f, "middle frame dropped")
        d = good
        let a = good[frames[1].start..<frames[1].end], b = good[frames[2].start..<frames[2].end]
        d.replaceSubrange(frames[1].start..<frames[2].end, with: b + a)
        expectRejected(d, f, "frames reordered")
        d = good; d.insert(contentsOf: a, at: frames[2].start)
        expectRejected(d, f, "frame duplicated")
        expectRejected(good + Data([0, 0, 0, 1, 0]), f, "bytes after the end frame")

        // Splice a frame from another backup made with the SAME keys: bound to its own header → rejected.
        let url2 = try write(f, name: "other.privabackup")
        let other = try Data(contentsOf: url2)
        let of = frameOffsets(other)
        d = good; d.replaceSubrange(frames[1].start..<frames[1].end, with: other[of[1].start..<of[1].end])
        expectRejected(d, f, "frame spliced from another backup")

        // Flip the "uses iCloud Keychain" flag in the header: the key derivation no longer matches.
        let coreLen = good[8..<12].reduce(0) { ($0 << 8) | Int($1) }
        let core = String(decoding: good[12..<12+coreLen], as: UTF8.self)
        if core.contains("\"usesKeychain\":true") {
            let swapped = core.replacingOccurrences(of: "\"usesKeychain\":true", with: "\"usesKeychain\":false")
            var nd = good.prefix(8)
            nd.appendBE(UInt32(swapped.utf8.count)); nd.append(Data(swapped.utf8)); nd.append(good[(12+coreLen)...])
            expectRejected(nd, f, "keychain flag stripped")
        }
        XCTAssertNoThrow(try restore(url, f), "the untouched file still restores")
    }

    // MARK: - size, compression, limits

    func testCompressionAndSizePadding() throws {
        let f = try fixture(messages: 5000, mediaMB: 0)
        let url = try write(f)
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber).int64Value
        XCTAssertEqual(size % BackupFormat.padUnit, 0, "padded to a multiple of 64 KiB")
        var raw = 0
        try f.store.exportMessages { raw += (try? JSONEncoder().encode($0).count) ?? 0 }
        PrivaTestCase.metric("backup_5000_messages_json", Double(raw) / 1024, "KiB")
        PrivaTestCase.metric("backup_5000_messages_file", Double(size) / 1024, "KiB")
        XCTAssertLessThan(Double(size), Double(raw) * 0.6, "records are compressed")
    }

    func testDecompressionIsBounded() {
        XCTAssertThrowsError(try BackupFormat.decompress(Data(repeating: 1, count: 100), expected: 200 << 20)) {
            XCTAssertEqual($0 as? BackupError, .tooLarge)
        }
        let z = BackupFormat.compress(Data(repeating: 7, count: 100_000))!
        XCTAssertThrowsError(try BackupFormat.decompress(z, expected: 50_000), "lies about its size") { _ in }
        XCTAssertEqual(try BackupFormat.decompress(z, expected: 100_000), Data(repeating: 7, count: 100_000))
        XCTAssertThrowsError(try BackupPasswordKDF.derive("x", salt: Bytes.random(16), rounds: 1 << 30), "absurd KDF cost refused (DoS)")
        XCTAssertThrowsError(try BackupPasswordKDF.derive("x", salt: Bytes.random(16), rounds: 3000), "non power of two refused")
    }

    func testImporterRejectsPathTraversalMediaIDs() throws {
        let f = try fixture(messages: 1, mediaMB: 0)
        let url = tmp.appendingPathComponent("evil.privabackup")
        let w = try BackupWriter(url: url, keys: f.keys)
        try w.writeJSON(.manifest, f.manifest)
        try w.writeJSON(.mediaStart, BackupMediaStart(fileID: "../../Priva/priva.db", size: 4))
        try w.write(.mediaBytes, Data([1, 2, 3, 4]), compress: false)
        try w.write(.mediaEnd, Data(), compress: false)
        try w.finish()
        XCTAssertThrowsError(try restore(url, f)) { XCTAssertEqual($0 as? BackupError, .corrupted) }
    }

    func testStressLargeBackupStreamsInFlatMemory() throws {
        let f = try fixture(messages: 20_000, mediaMB: 64)
        let before = PrivaTestCase.residentMB()
        let t0 = Date()
        let url = try write(f)
        let tWrite = Date().timeIntervalSince(t0)
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber).int64Value
        let t1 = Date()
        let (dst, r) = try restore(url, f)
        let tRead = Date().timeIntervalSince(t1)
        PrivaTestCase.metric("backup_stress_write_20k_msgs_64MB", tWrite * 1000, "ms")
        PrivaTestCase.metric("backup_stress_restore", tRead * 1000, "ms")
        PrivaTestCase.metric("backup_stress_file", Double(size) / 1_048_576, "MB")
        PrivaTestCase.metric("backup_stress_memory_growth", PrivaTestCase.residentMB() - before, "MB")
        XCTAssertEqual(r.messages, 20_001)
        XCTAssertEqual(try Data(contentsOf: dst.mediaURL(f.mediaID)), f.mediaBytes)
        XCTAssertLessThan(PrivaTestCase.residentMB() - before, 400, "streams instead of loading everything")
    }
}
