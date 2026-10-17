import CryptoKit
import XCTest
@testable import Priva

/// Backups as users (and attackers) experience them: the settings behind backups, the 90-day group media rule, and attacker journeys
/// (docs/BACKUP_DESIGN.md §8).
nonisolated final class BackupJourneyTests: PrivaTestCase {
    private static let password = "test-\(UUID().uuidString)"

    override func setUp() async throws {
        await MainActor.run { BackupLocations.deleteAll() }
    }
    override func tearDown() async throws {
        await MainActor.run { BackupLocations.deleteAll() }
    }

    @MainActor private func localEngine() throws -> Node {
        let id = try IdentityKeys(seed: IdentityKeys.newSeed())
        let name = Username.random()
        let v = UnlockedVault(username: name, vaultKey: SymmetricKey(size: .bits256), identity: id,
                              bundle: try id.bundle(username: name), registered: true)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("local-\(UUID().uuidString)", isDirectory: true)
        let n = Node(engine: PrivaEngine(vault: v, store: try Store(vaultKey: v.vaultKey, directory: dir)), dir: dir)
        addTeardownBlock { @MainActor in try? FileManager.default.removeItem(at: n.dir) }
        return n
    }

    @MainActor private func latestBackup(for c: BackupCenter) throws -> BackupFile {
        let hint = try XCTUnwrap(c.config?.hint)
        return try XCTUnwrap(BackupLocations.list().first { $0.header.keyHint == hint }, "backup file on this iPhone")
    }

    // The lost-phone journey (restore on a new iPhone, new username, friends + groups follow) is in
    // RestoreJourneyTests.

    // MARK: - iCloud going away: off, signed out, full, out of Priva's hands

    /// What `BackupLocations.debugICloud` answers: iCloud Drive's folder, nil while it's off or signed out.
    nonisolated(unsafe) private static var icloudFolder: URL?

    private static func backups(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix("." + BackupLocations.fileExtension) }
    }

    /// iCloud backups chosen, then iCloud goes: turned off or signed out, then full. Each backup still lands on this
    /// iPhone and counts as done (it used to fail the whole backup when the iCloud copy failed, so the daily backup
    /// failed every day), and the backup screen says where it is. Once iCloud has room again, the next backup
    /// reaches it and the note goes.
    @MainActor func testBackupsSurviveICloudGoingAwayAndReachItWhenItsBack() async throws {
        let icloud = FileManager.default.temporaryDirectory.appendingPathComponent("icloud-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: icloud, withIntermediateDirectories: true)
        Self.icloudFolder = nil
        BackupLocations.debugICloud = { BackupJourneyTests.icloudFolder }
        defer {
            BackupLocations.debugICloud = nil
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: icloud.path)
            try? FileManager.default.removeItem(at: icloud)
        }
        let n = try localEngine()
        let c = n.engine.backup
        _ = try await c.setUp(password: Self.password, icloud: true)

        // iCloud Drive off, or signed out of iCloud.
        await c.backUpNow()
        XCTAssertEqual(c.phase, .idle, "the backup didn't fail")
        let first = try XCTUnwrap(c.config?.lastBackup)
        _ = try latestBackup(for: c)
        XCTAssertEqual(c.config?.icloudIssue?.contains("iCloud Drive is off"), true, "the screen says it's only on this iPhone")

        // iCloud is back, but full: it refuses the copy.
        Self.icloudFolder = icloud
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: icloud.path)
        try await Task.sleep(for: .milliseconds(20))
        await c.backUpNow()
        XCTAssertEqual(c.phase, .idle, "a full iCloud doesn't fail the backup")
        XCTAssertGreaterThan(try XCTUnwrap(c.config?.lastBackup), first, "it counts as done: no daily retry and error")
        XCTAssertEqual(c.config?.icloudIssue?.contains("couldn't be copied"), true)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: icloud.path)) ?? [], [], "no half-copied file in iCloud")

        // Room again.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: icloud.path)
        await c.backUpNow()
        XCTAssertEqual(c.phase, .idle)
        XCTAssertNil(c.config?.icloudIssue, "the note goes once a backup reaches iCloud")
        XCTAssertEqual(Self.backups(in: icloud).count, 1, "the backup is in iCloud")
    }

    // MARK: - Settings: turning backups on/off, key checks, password change, schedule

    @MainActor func testBackupSettingsLifecycle() async throws {
        let n = try localEngine()
        let c = n.engine.backup
        XCTAssertFalse(c.isOn)
        try n.engine.store.importMessages([Message(id: UUID().uuidString, contact: "someone_0001", outgoing: true, kind: .text,
                                               text: "hello", attachment: nil, sentAt: .now, status: .delivered)])

        let key = try await c.setUp(password: Self.password, icloud: false)
        XCTAssertTrue(c.isOn)
        let matches = await c.matches(key)
        let wrong = await c.matches(BackupKey.generate())
        XCTAssertTrue(matches, "Check my Backup Key: right key")
        XCTAssertFalse(wrong, "Check my Backup Key: wrong key")

        // Toggles persist across a relaunch (a fresh center reading the same store).
        c.setAutomatic(false)
        c.setICloud(true)
        let reloaded = BackupCenter()
        reloaded.engine = n.engine
        reloaded.load()
        XCTAssertEqual(reloaded.config?.automatic, false)
        XCTAssertEqual(reloaded.config?.icloud, true)
        c.setICloud(false)

        // Daily schedule: only when on, and at most once a day.
        c.setAutomatic(true)
        c.backUpIfDue()
        try await waitUntil("scheduled backup ran") { c.config?.lastBackup != nil && !c.isWorking }
        let first = try latestBackup(for: c)
        c.backUpIfDue()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(c.isWorking, "not due again within 24 h")

        // Changing the password: new backups need the new one; the older backup still opens with the old one.
        let newPassword = "test-\(UUID().uuidString)"
        await c.passwordChanged(to: newPassword)
        await c.backUpNow()
        let newer = try latestBackup(for: c)
        XCTAssertNotEqual(newer.header.id, first.header.id)
        await assertStageFails(newer.url, key, Self.password, .wrongKey)
        let s1 = try await BackupRestore.stage(newer.url, key: key, password: newPassword)
        BackupRestore.discard(s1)
        let s0 = try await BackupRestore.stage(first.url, key: key, password: Self.password)
        BackupRestore.discard(s0)

        // Only the newest two are kept on the phone.
        await c.backUpNow()
        await c.backUpNow()
        XCTAssertEqual(BackupLocations.list().filter { $0.location == .device && $0.header.keyHint == c.config?.hint }.count, BackupLocations.keep)

        // Turning off with delete removes the files and the config.
        c.turnOff(deleteFiles: true)
        XCTAssertFalse(c.isOn)
        try await waitUntil("files deleted") { BackupLocations.list().isEmpty }
    }

    @MainActor private func assertStageFails(_ url: URL, _ key: BackupKey, _ pw: String, _ expected: BackupError,
                                             file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let s = try await BackupRestore.stage(url, key: key, password: pw)
            BackupRestore.discard(s)
            XCTFail("restore should fail with \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? BackupError, expected, file: file, line: line)
        }
    }

    @MainActor func testRestoreStagingLeavesNothingBehindOnFailure() async throws {
        let n = try localEngine()
        let key = try await n.engine.backup.setUp(password: Self.password, icloud: false)
        await n.engine.backup.backUpNow()
        let file = try latestBackup(for: n.engine.backup)
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        func stagingDirs() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []).filter { $0.hasPrefix("Restore-") }
        }
        let before = stagingDirs()
        await assertStageFails(file.url, key, "not the password", .wrongKey)
        await assertStageFails(file.url, BackupKey.generate(), Self.password, .wrongKey)
        // A backup cut short mid-file (e.g. an interrupted iCloud upload).
        let cut = FileManager.default.temporaryDirectory.appendingPathComponent("cut.privabackup")
        let d = try Data(contentsOf: file.url)
        try d.prefix(d.count - 5000).write(to: cut)
        do { _ = try await BackupRestore.stage(cut, key: key, password: Self.password); XCTFail("truncated restore") } catch {}
        XCTAssertEqual(stagingDirs(), before, "failed restores clean up their staging folder")
        // Abandoned staging folders from a crash are removed at launch.
        try FileManager.default.createDirectory(at: base.appendingPathComponent("Restore-crashed"), withIntermediateDirectories: true)
        BackupRestore.removeAbandoned()
        XCTAssertTrue(stagingDirs().isEmpty)
    }

    // MARK: - Group media: 90 days, then gone (and not in backups)

    @MainActor func testGroupMediaOlderThan90DaysIsDeletedAndLeftOutOfBackups() async throws {
        let n = try localEngine()
        let g = try n.engine.groups.create(name: "Old photos", members: [])
        func media(_ days: Double, contact: String) throws -> Message {
            let id = UUID().uuidString
            try Bytes.random(4096).write(to: n.engine.store.mediaURL(id))
            let a = Attachment(fileID: id, kind: .image, name: "p.jpg", mime: "image/jpeg", size: 4096, key: Bytes.random(32),
                               header: Data(), sha256: Data(), thumbnail: Data([1, 2, 3]), progress: 1)
            let m = Message(id: UUID().uuidString, contact: contact, outgoing: false, kind: .media, text: nil, attachment: a,
                            sentAt: Date().addingTimeInterval(-days * 86_400), status: .received)
            try n.engine.store.save(m)
            return m
        }
        let old = try media(91, contact: g.threadKey)
        let recent = try media(89, contact: g.threadKey)
        let oldDirect = try media(400, contact: "friend_0001")

        n.engine.pruneGroupMedia()

        let after = try n.engine.store.messages(with: g.threadKey)
        let o = try XCTUnwrap(after.first { $0.id == old.id }?.attachment)
        XCTAssertEqual(o.expired, true, "the message stays, marked as removed")
        XCTAssertTrue(o.key.isEmpty, "its key is wiped")
        XCTAssertNil(o.thumbnail, "its thumbnail is wiped")
        XCTAssertFalse(FileManager.default.fileExists(atPath: n.engine.store.mediaURL(old.attachment!.fileID).path))
        XCTAssertFalse(MediaSaver.canSave(o, outgoing: false), "nothing left to save")
        let r = try XCTUnwrap(after.first { $0.id == recent.id }?.attachment)
        XCTAssertNotEqual(r.expired, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: n.engine.store.mediaURL(recent.attachment!.fileID).path))
        XCTAssertTrue(MediaSaver.canSave(r, outgoing: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: n.engine.store.mediaURL(oldDirect.attachment!.fileID).path),
                      "1:1 media is never auto-deleted")

        // Pruning is idempotent, and a backup with media carries only the live files: the recent group photo and the
        // old 1:1 one, not the pruned one (audit TST-10: text-only backups made the old check vacuous).
        // (Counted by opening the backup: files are padded to 64 KiB steps, so their size says nothing here.)
        n.engine.pruneGroupMedia()
        let key = try await n.engine.backup.setUp(password: Self.password, icloud: false)
        n.engine.backup.setIncludeMedia(true)
        await n.engine.backup.backUpNow()
        await n.engine.backup.refreshList()
        let newest = try XCTUnwrap(n.engine.backup.files.max { $0.header.created < $1.header.created })
        let staged = try await BackupRestore.unlock(newest.url, key: key, password: Self.password)
        defer { BackupRestore.discard(staged) }
        XCTAssertEqual(staged.media, 2, "the recent group photo and the old 1:1 one, not the pruned one")
    }

    // MARK: - Attacker journeys (docs/BACKUP_DESIGN.md §8)

    private func sampleBackup(keychain: Data? = Bytes.random(32)) throws -> (URL, BackupKey, Data?, BackupWriteKeys, BackupManifest, Store) {
        let key = BackupKey.generate()
        let salt = Bytes.random(16)
        let keys = BackupWriteKeys(publicKey: try key.keyPair().publicPair, passwordKey: try BackupPasswordKDF.derive(Self.password, salt: salt),
                                   passwordSalt: salt, passwordRounds: BackupPasswordKDF.defaultRounds, keychainSecret: keychain)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("atk-\(UUID().uuidString)", isDirectory: true)
        let store = try Store(vaultKey: SymmetricKey(size: .bits256), directory: dir)
        try store.importMessages([Message(id: UUID().uuidString, contact: "friend_0001", outgoing: true, kind: .text,
                                          text: "the secret plans", attachment: nil, sentAt: .now, status: .delivered)])
        let id = try IdentityKeys(seed: IdentityKeys.newSeed())
        let manifest = BackupManifest(username: "victim_0001", seed: id.seed, bundleRaw: try id.bundle(username: "victim_0001").raw,
                                      registered: true, created: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded()),
                                      displayName: nil, messageCount: 1, contactCount: 0, groupCount: 0, mediaCount: 0)
        let url = dir.appendingPathComponent("victim.privabackup")
        _ = try BackupExporter.write(to: url, keys: keys, store: store, manifest: manifest)
        return (url, key, keychain, keys, manifest, store)
    }

    private func open(_ url: URL, _ key: BackupKey, _ pw: String, _ kc: Data?) throws -> BackupImporter.Result {
        let r = try BackupReader(url: url, backupKey: key, password: pw, keychainSecret: kc)
        let dst = try Store(vaultKey: SymmetricKey(size: .bits256),
                            directory: FileManager.default.temporaryDirectory.appendingPathComponent("atk-dst-\(UUID().uuidString)"))
        return try BackupImporter.importAll(r, into: dst)
    }

    /// Attacker 1: has the file (stolen iCloud account / subpoena of iCloud data) but nothing else.
    func testAttackerWithOnlyTheFileLearnsNothing() throws {
        let (url, _, kc, _, _, _) = try sampleBackup()
        let raw = try Data(contentsOf: url)
        XCTAssertNil(raw.range(of: Data("secret plans".utf8)), "no plaintext in the file")
        XCTAssertNil(raw.range(of: Data("victim_0001".utf8)), "not even the username")
        let h = try BackupReader.peek(url)
        XCTAssertEqual(h.keyHint.count, 8, "the header reveals only a short key hint, the date and KDF cost")
        for _ in 0..<3 {
            XCTAssertThrowsError(try open(url, BackupKey.generate(), "password123", kc)) { XCTAssertEqual($0 as? BackupError, .wrongKey) }
        }
        // Cost of ONE guess even with the right password and Apple account: 256-bit key space × scrypt(2¹⁶).
        let t = Date()
        _ = try? open(url, BackupKey.generate(), Self.password, kc)
        PrivaTestCase.metric("backup_attack_cost_per_key_guess", Date().timeIntervalSince(t) * 1000, "ms")
    }

    /// Attacker 2: found the 24 words (photo of the paper) but doesn't know the password.
    func testAttackerWithTheBackupKeyButNotThePasswordFails() throws {
        let (url, key, kc, _, _, _) = try sampleBackup()
        for guess in ["", "password", String(Self.password.dropLast()), Self.password.uppercased()] {
            XCTAssertThrowsError(try open(url, key, guess, kc)) { XCTAssertEqual($0 as? BackupError, .wrongKey) }
        }
        let t = Date()
        _ = try? open(url, key, "guess", kc)
        PrivaTestCase.metric("backup_attack_cost_per_password_guess", Date().timeIntervalSince(t) * 1000, "ms")
    }

    /// Attacker 3: has the 24 words AND the password, but not the victim's Apple Account (iCloud Keychain).
    func testAttackerWithKeyAndPasswordButAnotherAppleAccountFails() throws {
        let (url, key, _, _, _, _) = try sampleBackup()
        XCTAssertThrowsError(try open(url, key, Self.password, nil)) { XCTAssertEqual($0 as? BackupError, .needsKeychainFactor) }
        XCTAssertThrowsError(try open(url, key, Self.password, Bytes.random(32))) { XCTAssertEqual($0 as? BackupError, .wrongKey) }
    }

    /// Attacker 4: edits the header to lower the password KDF cost (to make guessing cheaper). The header is
    /// bound into the key derivation, so the edited file no longer opens for anyone.
    func testLoweringThePasswordCostInTheHeaderIsDetected() throws {
        let (url, key, kc, _, _, _) = try sampleBackup()
        var d = try Data(contentsOf: url)
        let coreLen = d[8..<12].reduce(0) { ($0 << 8) | Int($1) }
        let core = String(decoding: d[12..<12 + coreLen], as: UTF8.self)
        let cheap = core.replacingOccurrences(of: "\"pwRounds\":\(BackupPasswordKDF.defaultRounds)", with: "\"pwRounds\":\(1 << 14)")
        XCTAssertNotEqual(cheap, core)
        var nd = d.prefix(8)
        nd.appendBE(UInt32(cheap.utf8.count)); nd.append(Data(cheap.utf8)); nd.append(d[(12 + coreLen)...])
        d = nd
        let tampered = url.deletingLastPathComponent().appendingPathComponent("cheap.privabackup")
        try d.write(to: tampered)
        XCTAssertThrowsError(try open(tampered, key, Self.password, kc)) { XCTAssertEqual($0 as? BackupError, .wrongKey) }
    }

    /// Attacker 5: plants a forged backup (knows the victim's public backup key, e.g. from a seized phone's
    /// database, but not the password) hoping the victim restores it. It can't be opened by the victim.
    func testForgedBackupWithoutThePasswordCannotBePlanted() throws {
        let (_, key, kc, real, manifest, store) = try sampleBackup()
        let salt = Bytes.random(16)
        let forgedKeys = BackupWriteKeys(publicKey: real.publicKey, passwordKey: try BackupPasswordKDF.derive("attacker guess", salt: salt),
                                         passwordSalt: salt, passwordRounds: BackupPasswordKDF.defaultRounds, keychainSecret: kc)
        let forged = FileManager.default.temporaryDirectory.appendingPathComponent("forged-\(UUID().uuidString).privabackup")
        _ = try BackupExporter.write(to: forged, keys: forgedKeys, store: store, manifest: manifest)
        XCTAssertThrowsError(try open(forged, key, Self.password, kc)) { XCTAssertEqual($0 as? BackupError, .wrongKey) }
    }

    /// Typos and near-misses in the 24 words are caught before any decryption is attempted.
    func testNearMissBackupKeysAreRejected() throws {
        let key = BackupKey.generate()
        var words = key.words
        XCTAssertNoThrow(try BackupKey(words: words))
        XCTAssertNoThrow(try BackupKey(text: "  " + words.joined(separator: "  ").uppercased() + "\n"), "spacing and case are forgiven")
        words[5] = words[5] == "abandon" ? "ability" : "abandon"
        XCTAssertThrowsError(try BackupKey(words: words), "one wrong word → checksum")
        XCTAssertThrowsError(try BackupKey(words: Array(key.words.prefix(23))), "23 words")
        XCTAssertThrowsError(try BackupKey(text: key.words.joined(separator: " ") + " zoo"), "25 words")
        var swapped = key.words
        swapped.swapAt(0, 23)
        if swapped != key.words, let k = try? BackupKey(words: swapped) {
            XCTAssertNotEqual(k.entropy, key.entropy, "a swapped phrase that passes the checksum is simply a different key")
        }
        XCTAssertThrowsError(try BackupKey(text: RecoveryPhrase.encode(Bytes.random(32)).dropLast().joined(separator: " ") + " notaword"))
    }

    /// Rollback: an attacker with iCloud access can't forge, but CAN swap in an older genuine backup. The
    /// restore list shows each backup's date and the summary its contents, so the user sees it.
    func testOlderGenuineBackupIsDistinguishableByDate() throws {
        let (url, key, kc, keys, manifest, store) = try sampleBackup()
        let older = url.deletingLastPathComponent().appendingPathComponent("older.privabackup")
        var m2 = manifest
        m2 = BackupManifest(username: m2.username, seed: m2.seed, bundleRaw: m2.bundleRaw, registered: true,
                            created: m2.created.addingTimeInterval(-30 * 86_400), displayName: nil,
                            messageCount: 0, contactCount: 0, groupCount: 0, mediaCount: 0)
        _ = try BackupExporter.write(to: older, keys: keys, store: store, manifest: m2)
        let a = try open(url, key, Self.password, kc), b = try open(older, key, Self.password, kc)
        XCTAssertGreaterThan(a.manifest.created, b.manifest.created)
    }

    /// Garbage, empty, and hostile length fields fail fast without big allocations.
    func testMalformedFilesAreRefusedCheaply() throws {
        let dir = FileManager.default.temporaryDirectory
        let cases: [(String, Data)] = [
            ("empty", Data()),
            ("random", Bytes.random(4096)),
            ("magic only", Data("PRIVABK1".utf8)),
            ("huge core length", Data("PRIVABK1".utf8) + Data([0xFF, 0xFF, 0xFF, 0xFF]) + Bytes.random(64)),
        ]
        for (name, data) in cases {
            let u = dir.appendingPathComponent("bad-\(UUID().uuidString).privabackup")
            try data.write(to: u)
            XCTAssertThrowsError(try BackupReader.peek(u), name)
        }
        // A future format version is refused rather than misread.
        let (url, _, _, _, _, _) = try sampleBackup()
        let d = try Data(contentsOf: url)
        let coreLen = d[8..<12].reduce(0) { ($0 << 8) | Int($1) }
        let core = String(decoding: d[12..<12 + coreLen], as: UTF8.self).replacingOccurrences(of: "\"version\":1", with: "\"version\":2")
        var nd = d.prefix(8)
        nd.appendBE(UInt32(core.utf8.count)); nd.append(Data(core.utf8)); nd.append(d[(12 + coreLen)...])
        let v2 = dir.appendingPathComponent("v2-\(UUID().uuidString).privabackup")
        try nd.write(to: v2)
        XCTAssertThrowsError(try BackupReader.peek(v2)) { XCTAssertEqual($0 as? BackupError, .unsupportedVersion) }
    }
}
