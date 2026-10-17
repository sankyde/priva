import CryptoKit
import XCTest
@testable import Priva

/// Backups under heavy and hostile conditions: a big account restored byte for byte, a backup taken while messages
/// pour in, twenty backups back to back, and the Backup Key never written anywhere on the phone.
nonisolated final class BackupStressTests: PrivaTestCase {
    private static let password = "test-\(UUID().uuidString)"

    private func keys(_ key: BackupKey) throws -> BackupWriteKeys {
        let salt = Bytes.random(16)
        return BackupWriteKeys(publicKey: try key.keyPair().publicPair, passwordKey: try BackupPasswordKDF.derive(Self.password, salt: salt),
                               passwordSalt: salt, passwordRounds: BackupPasswordKDF.defaultRounds, keychainSecret: nil)
    }

    private func manifest(messages: Int) throws -> BackupManifest {
        let id = try IdentityKeys(seed: IdentityKeys.newSeed())
        return BackupManifest(username: "heavy_user_0001", seed: id.seed, bundleRaw: try id.bundle(username: "heavy_user_0001").raw,
                              registered: true, created: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded()),
                              displayName: "Heavy", messageCount: messages, contactCount: 0, groupCount: 0, mediaCount: 0)
    }

    private func digest(of store: Store) throws -> (count: Int, hash: String) {
        var rows: [String] = []
        try store.exportMessages { page in
            for m in page { rows.append("\(m.id)|\(m.contact)|\(m.text ?? "")|\(m.attachment?.fileID ?? "")|\(m.seq ?? -1)") }
        }
        rows.sort()
        return (rows.count, SHA256.hash(data: Data(rows.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined())
    }

    // MARK: - A big account, restored byte for byte

    func testHeavyAccountRestoresEveryMessageAndEveryByteOfMedia() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("heavy-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let store = try Store(vaultKey: .init(size: .bits256), directory: dir.appendingPathComponent("src"))
        let friends = 300, groups = 40, messages = 100_000, mediaFiles = 64, mediaMB = 2
        for i in 0..<friends {
            let id = try IdentityKeys(seed: IdentityKeys.newSeed())
            let name = String(format: "friend_user_%04d", i)
            try store.upsert(Contact(username: name, bundleRaw: try id.bundle(username: name).raw,
                                     pair: PairSecrets(current: Bytes.random(64), previous: nil, epoch: 1), inboxTopic: "i-\(i)"))
        }
        var mediaHashes: [String: Data] = [:]
        var batch: [Message] = []
        let t0 = Date()
        for i in 0..<messages {
            let isGroup = i % 5 == 0
            let thread = isGroup ? "g:group\(i % groups)" : String(format: "friend_user_%04d", i % friends)
            var att: Attachment?
            if i % (messages / mediaFiles) == 0, mediaHashes.count < mediaFiles {
                let fid = UUID().uuidString, bytes = Bytes.random(mediaMB << 20)
                try bytes.write(to: store.mediaURL(fid))
                mediaHashes[fid] = KDF.sha256(bytes)
                att = Attachment(fileID: fid, kind: .file, name: "file-\(i).bin", mime: "application/octet-stream", size: UInt64(bytes.count),
                                 key: Bytes.random(32), header: Data(), sha256: KDF.sha256(bytes), progress: 1)
            }
            batch.append(Message(id: "m\(i)", contact: thread, outgoing: i % 3 == 0, kind: att == nil ? .text : .media,
                                 text: att == nil ? "message \(i): \(String(repeating: "lorem ipsum ", count: i % 7))" : nil,
                                 attachment: att, sentAt: Date().addingTimeInterval(-Double(messages - i)), status: .delivered,
                                 seq: isGroup ? Int64(i) : nil, sender: isGroup ? "friend_user_0001" : nil))
            if batch.count == 5_000 { try store.importMessages(batch); batch.removeAll() }
        }
        try store.importMessages(batch)
        PrivaTestCase.metric("backup_heavy_fixture_build", Date().timeIntervalSince(t0), "s")
        let original = try digest(of: store)
        XCTAssertEqual(original.count, messages)

        let key = BackupKey.generate()
        let url = dir.appendingPathComponent("heavy.privabackup")
        let mem0 = Self.residentMB()
        let t1 = Date()
        _ = try BackupExporter.write(to: url, keys: try keys(key), store: store, manifest: try manifest(messages: messages))
        let tWrite = Date().timeIntervalSince(t1)
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber).int64Value
        PrivaTestCase.metric("backup_heavy_write_100k_msgs_128MB", tWrite, "s")
        PrivaTestCase.metric("backup_heavy_file", Double(size) / 1_048_576, "MB")
        PrivaTestCase.metric("backup_heavy_write_memory_growth", Self.residentMB() - mem0, "MB")

        let t2 = Date()
        let reader = try BackupReader(url: url, backupKey: key, password: Self.password, keychainSecret: nil)
        let restored = try Store(vaultKey: .init(size: .bits256), directory: dir.appendingPathComponent("dst"))
        let result = try BackupImporter.importAll(reader, into: restored)
        PrivaTestCase.metric("backup_heavy_restore", Date().timeIntervalSince(t2), "s")
        PrivaTestCase.metric("backup_heavy_restore_memory_growth", Self.residentMB() - mem0, "MB")

        XCTAssertEqual(result.messages, messages)
        XCTAssertEqual(result.media, mediaFiles)
        let back = try digest(of: restored)
        XCTAssertEqual(back.count, original.count)
        XCTAssertEqual(back.hash, original.hash, "every message, text, thread, order number, attachment, comes back identical")
        XCTAssertEqual(try restored.contacts().count, friends)
        for (fid, h) in mediaHashes {
            XCTAssertEqual(KDF.sha256(try Data(contentsOf: restored.mediaURL(fid))), h, "media \(fid) byte-identical")
        }
    }

    // MARK: - Backing up while messages keep arriving

    func testBackupWhileMessagesPourInIsConsistent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let store = try Store(vaultKey: .init(size: .bits256), directory: dir.appendingPathComponent("src"))
        let before = (0..<20_000).map { i in
            Message(id: "old\(i)", contact: "friend_user_\(i % 50)", outgoing: false, kind: .text, text: "before \(i)",
                    attachment: nil, sentAt: Date(timeIntervalSince1970: 1_000_000 + Double(i)), status: .received)
        }
        try store.importMessages(before)
        let key = BackupKey.generate()
        let url = dir.appendingPathComponent("live.privabackup")
        let writer = DispatchGroup()
        final class Box: @unchecked Sendable { var error: Error? }
        let box = Box()
        let k = try keys(key), man = try manifest(messages: 20_000)
        writer.enter()
        DispatchQueue.global().async {
            do { _ = try BackupExporter.write(to: url, keys: k, store: store, manifest: man) } catch { box.error = error }
            writer.leave()
        }
        // 5,000 new messages land while the backup is being written.
        for i in 0..<5_000 {
            try store.importMessages([Message(id: "new\(i)", contact: "friend_user_\(i % 50)", outgoing: false, kind: .text, text: "during \(i)",
                                              attachment: nil, sentAt: Date(), status: .received)])
        }
        writer.wait()
        XCTAssertNil(box.error)
        let reader = try BackupReader(url: url, backupKey: key, password: Self.password, keychainSecret: nil)
        let restored = try Store(vaultKey: .init(size: .bits256), directory: dir.appendingPathComponent("dst"))
        let r = try BackupImporter.importAll(reader, into: restored)
        var ids = Set<String>(), dupes = 0
        try restored.exportMessages { page in for m in page { if !ids.insert(m.id).inserted { dupes += 1 } } }
        PrivaTestCase.metric("backup_during_traffic_new_messages_captured", Double(ids.filter { $0.hasPrefix("new") }.count), "")
        XCTAssertEqual(dupes, 0, "no message appears twice")
        XCTAssertTrue((0..<20_000).allSatisfy { ids.contains("old\($0)") }, "everything that existed before the backup started is in it")
        XCTAssertEqual(r.messages, ids.count)
    }

    // MARK: - Twenty backups in a row, and the Backup Key is never stored

    @MainActor func testTwentyBackupsInARowAndTheKeyIsNeverStored() async throws {
        BackupLocations.deleteAll()
        addTeardownBlock { @MainActor in BackupLocations.deleteAll() }
        let id = try IdentityKeys(seed: IdentityKeys.newSeed())
        let name = Username.random()
        let v = UnlockedVault(username: name, vaultKey: .init(size: .bits256), identity: id, bundle: try id.bundle(username: name), registered: true)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("twenty-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let engine = PrivaEngine(vault: v, store: try Store(vaultKey: v.vaultKey, directory: dir))
        let key = try await engine.backup.setUp(password: Self.password, icloud: false)
        let t0 = Date()
        for round in 0..<20 {
            try engine.store.importMessages((0..<250).map { i in
                Message(id: "r\(round)-\(i)", contact: "friend_user_1", outgoing: true, kind: .text, text: "round \(round) #\(i)",
                        attachment: nil, sentAt: .now, status: .delivered)
            })
            await engine.backup.backUpNow()
            XCTAssertEqual(engine.backup.phase, .idle, "round \(round)")
        }
        PrivaTestCase.metric("backup_twenty_in_a_row", Date().timeIntervalSince(t0), "s")
        let files = BackupLocations.list().filter { $0.location == .device }
        XCTAssertEqual(files.count, BackupLocations.keep, "only the newest \(BackupLocations.keep) are kept")
        let newest = try XCTUnwrap(files.first)
        let staged = try await BackupRestore.stage(newest.url, key: key, password: Self.password)
        XCTAssertEqual(staged.messages, 20 * 250, "the newest backup holds everything")
        BackupRestore.discard(staged)

        // The Backup Key (its 24 words or its 32 bytes) exists nowhere on the phone: not in the store, the WAL,
        // media, preferences or the backups themselves.
        let needles = [key.entropy, Data(key.words.joined(separator: " ").utf8), Data(key.entropy.hex.utf8), Data(key.entropy.base64EncodedString().utf8)]
        var places = [dir, URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Preferences")]
        places.append(try BackupLocations.deviceDirectory())
        for place in places {
            for f in (FileManager.default.enumerator(at: place, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? [] where !f.hasDirectoryPath {
                guard let d = try? Data(contentsOf: f) else { continue }
                for n in needles { XCTAssertNil(d.range(of: n), "Backup Key material found in \(f.lastPathComponent)") }
            }
        }
    }
}
