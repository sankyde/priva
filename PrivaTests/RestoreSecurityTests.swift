import CryptoKit
import XCTest
@testable import Priva

/// The restore, move and first-run machinery taken apart (no network): move proofs, group roster swaps
/// dressed up as restores, what a restored store keeps, the backup search, the attempt limit and the tour flag.
nonisolated final class RestoreSecurityTests: XCTestCase {
    private static let password = "test-\(UUID().uuidString)"
    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("restore-sec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        await MainActor.run { RestoreThrottle.reset() }
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
        await MainActor.run {
            RestoreThrottle.reset()
            if let inbox = BackupLocations.receivedDirectory() { try? FileManager.default.removeItem(at: inbox) }
            BackupLocations.deleteAll()
        }
    }

    private func identity(_ name: String) throws -> (IdentityKeys, KeyBundle) {
        let id = try IdentityKeys(seed: IdentityKeys.newSeed())
        return (id, try id.bundle(username: name))
    }

    // MARK: - Move proofs

    func testAMoveProofBindsOldAndNewNamesTheNewKeysTheRecipientAndTheTime() throws {
        let (old, oldB) = try identity("alice_old_0001")
        let (_, newB) = try identity("alice_new_0002")
        let (_, otherB) = try identity("mallory_0003")
        let ts = Signal.now
        let sig = try MoveProof.sign(old: old, oldUsername: "alice_old_0001", newUsername: "alice_new_0002", newBundle: newB, to: "bob_0004", ts: ts)
        func ok(old o: String = "alice_old_0001", new n: String = "alice_new_0002", bundle: KeyBundle? = nil, to: String = "bob_0004",
                ts t: Int64? = nil, pinned: KeyBundle? = nil, now: Date = .now) -> Bool {
            MoveProof.verify(sig, pinned: pinned ?? oldB, old: o, new: n, newBundle: bundle ?? newB, to: to, ts: t ?? ts, now: now)
        }
        XCTAssertTrue(ok())
        XCTAssertFalse(ok(new: "mallory_0003"), "can't be redirected to another username")
        XCTAssertFalse(ok(bundle: otherB), "…or to other keys")
        XCTAssertFalse(ok(to: "carol_0005"), "a proof for Bob can't be replayed to Carol")
        XCTAssertFalse(ok(old: "someone_else_0006"), "names the account it moves")
        XCTAssertFalse(ok(ts: ts + 1), "the time is signed")
        XCTAssertFalse(ok(pinned: otherB), "only the old keys can sign it")
        XCTAssertFalse(ok(now: Date().addingTimeInterval(31 * 86_400)), "expires after 30 days")
        XCTAssertFalse(ok(now: Date().addingTimeInterval(-3600)), "…and can't come from the future")
        let selfMove = try MoveProof.sign(old: old, oldUsername: "alice_old_0001", newUsername: "alice_old_0001", newBundle: oldB, to: "bob_0004", ts: ts)
        XCTAssertFalse(MoveProof.verify(selfMove, pinned: oldB, old: "alice_old_0001", new: "alice_old_0001", newBundle: oldB, to: "bob_0004", ts: ts),
                       "a move must change the username and keys")
    }

    // MARK: - Group hosts can't pass off a swap as a restore

    private func member(_ name: String, _ b: KeyBundle, role: PrivaGroup.Role = .member) -> PrivaGroup.Member {
        .init(username: name, role: role, name: nil, joined: .now, bundleRaw: b.raw, inbox: "i-\(name)")
    }

    @MainActor func testOnlyAMoveSignedByTheMembersOldKeysIsShownAsARestore() throws {
        let (_, hostB) = try identity("host_user_0001")
        let (alice, aliceB) = try identity("alice_user_0002")
        let (_, newB) = try identity("alice_next_0003")
        let (mallory, malloryB) = try identity("mallory_0004")
        let before = PrivaGroup(id: "g1", name: "G", host: "host_user_0001", epoch: 3,
                                members: [member("host_user_0001", hostB, role: .host), member("alice_user_0002", aliceB)])
        let ts = Signal.now

        // Genuine: Alice's old keys signed the move (the proof addressed to the host), forwarded in the roster.
        var genuine = before
        genuine.members[1] = member("alice_next_0003", newB)
        genuine.moves = [.init(old: "alice_user_0002", new: "alice_next_0003", to: "host_user_0001", ts: ts,
                               sig: try MoveProof.sign(old: alice, oldUsername: "alice_user_0002", newUsername: "alice_next_0003", newBundle: newB, to: "host_user_0001", ts: ts))]
        XCTAssertEqual(GroupHub.verifiedMoves(from: before, to: genuine, host: "host_user_0001").map(\.new), ["alice_next_0003"])
        XCTAssertTrue(GroupHub.verifiedMoves(from: before, to: genuine, host: "someone_else_0009").isEmpty, "only from the host it was addressed to")

        // Malicious host swaps Alice for Mallory and labels it a restore, signing with Mallory's keys.
        var swap = before
        swap.members[1] = member("mallory_0004", malloryB)
        swap.moves = [.init(old: "alice_user_0002", new: "mallory_0004", to: "host_user_0001", ts: ts,
                            sig: try MoveProof.sign(old: mallory, oldUsername: "alice_user_0002", newUsername: "mallory_0004", newBundle: malloryB, to: "host_user_0001", ts: ts))]
        XCTAssertTrue(GroupHub.verifiedMoves(from: before, to: swap, host: "host_user_0001").isEmpty, "shown as Alice leaving + Mallory joining")

        // Replaying Alice's genuine proof onto Mallory's keys doesn't work either.
        var replay = before
        replay.members[1] = member("alice_next_0003", malloryB)
        replay.moves = genuine.moves
        XCTAssertTrue(GroupHub.verifiedMoves(from: before, to: replay, host: "host_user_0001").isEmpty)

        // A "move" that keeps the old member in the roster (a ghost added next to them) is not a move.
        var ghost = before
        ghost.members.append(member("alice_next_0003", newB))
        ghost.moves = genuine.moves
        XCTAssertTrue(GroupHub.verifiedMoves(from: before, to: ghost, host: "host_user_0001").isEmpty)
    }

    func testInvitesDontCarryMoveHistory() throws {
        let (_, hostB) = try identity("host_user_0001")
        var g = PrivaGroup(id: "g1", name: "G", host: "host_user_0001", epoch: 1, members: [member("host_user_0001", hostB, role: .host)])
        g.moves = [.init(old: "a_user_0001", new: "b_user_0002", to: "host_user_0001", ts: 1, sig: Data([1]))]
        XCTAssertNil(GroupSnapshot.invite(for: g, hostName: nil).group.moves, "someone who declines learns nothing about members")
    }

    // MARK: - What a restored store keeps (and drops)

    @MainActor func testARestoredStoreKeepsTheOldKeysOnlyToProveTheMoveAndDropsWhatTheOldNameSigned() throws {
        let store = try Store(vaultKey: SymmetricKey(size: .bits256), directory: tmp.appendingPathComponent("staged"))
        let (old, oldB) = try identity("owner_user_0001")
        let (_, friendB) = try identity("friend_user_0002")
        let pending = OutgoingRequest(id: "r1", username: "friend_user_0002", bundleRaw: friendB.raw, envelope: Data([1]),
                                      exporter: Data([2]), transcript: Data([3]), note: "hi", createdAt: .now)
        try store.save(pending)
        try store.save(IncomingRequest(id: "i1", username: "stranger_0003", bundleRaw: friendB.raw, inboxTopic: "i-x",
                                       exporter: Data(), transcript: Data(), note: nil, receivedAt: .now))
        try store.save(ControlItem(id: "c1", kind: .acceptance, contact: "stranger_0003", topic: "i-x", envelope: Data([9]), createdAt: .now))
        var mig = MigrationState()
        mig.announcements = [.init(topic: "m-x", envelope: Data([1]), until: .distantFuture, formerAnnounceKey: Data(), oldUsername: "older")]
        mig.revocations = [.init(username: "older_0009", ucommit: Data([7]), secret: Data([8]), notBefore: .now)]
        try store.set(mig, for: "migration")
        try store.set(AccountMovedNotice(newUsername: "x", at: .now), for: "account.moved")

        let manifest = BackupManifest(username: "owner_user_0001", seed: old.seed, bundleRaw: oldB.raw, registered: true, created: .now,
                                      displayName: nil, messageCount: 0, contactCount: 1, groupCount: 0, mediaCount: 0)
        try BackupRestore.prepareForNewIdentity(store, manifest: manifest)

        let prev = try XCTUnwrap(store.get(RestoredFrom.self, for: "restore.previous"))
        XCTAssertEqual(prev.username, "owner_user_0001")
        XCTAssertEqual(prev.seed, old.seed)
        XCTAssertEqual(prev.reissue.map(\.username), ["friend_user_0002"], "pending requests are sent again from the new name")
        XCTAssertTrue(try store.outgoingRequests().isEmpty, "nothing signed by the old username is sent again")
        XCTAssertTrue(try store.incomingRequests().isEmpty, "requests to the old username can't be answered by the new one")
        XCTAssertTrue(try store.controlItems().isEmpty)
        let kept = try XCTUnwrap(store.get(MigrationState.self, for: "migration"))
        XCTAssertTrue(kept.announcements.isEmpty, "old announcements pointed at a name that's going away")
        XCTAssertEqual(kept.revocations.count, 1, "removing even older usernames still happens")
        XCTAssertNil(store.get(AccountMovedNotice.self, for: "account.moved"))
    }

    /// Every username this iPhone leaves behind is removed from the directory: the backup's old one, and the
    /// account the restore replaced (restoring from Settings, or over a vault that survived a reinstall).
    @MainActor func testRestoringOverAnotherAccountRemovesThatUsernameToo() async throws {
        let (old, _) = try identity("backup_owner_0001")
        let (fresh, freshB) = try identity("fresh_name_0002")
        let v = UnlockedVault(username: "fresh_name_0002", vaultKey: SymmetricKey(size: .bits256), identity: fresh, bundle: freshB, registered: true)
        let replaced = Vault.RevocationRecord(username: "replaced_acct_0003", ucommit: Data(repeating: 3, count: 32), secret: Bytes.random(32))
        let m = await OnboardingModel.migration(from: .init(username: "backup_owner_0001", identity: old), to: v,
                                                record: nil, abandoned: replaced)
        XCTAssertEqual(Set(m.revocations.map(\.username)), ["backup_owner_0001", "replaced_acct_0003"])
        XCTAssertFalse(m.revocations.contains { $0.ucommit == freshB.ucommit }, "never the new username")
        XCTAssertTrue(m.revocations.allSatisfy { $0.notBefore > Date().addingTimeInterval(500) || OnboardingModel.debugRemovalDelay != nil },
                      "removed later, not next to the registration")
        XCTAssertEqual(m.announcements.count, 2, "friends' announce topic + the old iPhone's inbox")
        XCTAssertTrue(m.announcements.contains { $0.topic == old.inboxTopic })
    }

    // MARK: - Search for backup

    private func writeBackup(to url: URL, key: BackupKey, created: Date, username: String = "owner_user_0001") throws {
        let salt = Bytes.random(16)
        let keys = BackupWriteKeys(publicKey: try key.keyPair().publicPair, passwordKey: try BackupPasswordKDF.derive(Self.password, salt: salt),
                                   passwordSalt: salt, passwordRounds: BackupPasswordKDF.defaultRounds, keychainSecret: nil)
        let store = try Store(vaultKey: SymmetricKey(size: .bits256), directory: tmp.appendingPathComponent("src-\(UUID().uuidString)"))
        let id = try IdentityKeys(seed: IdentityKeys.newSeed())
        let m = BackupManifest(username: username, seed: id.seed, bundleRaw: try id.bundle(username: username).raw, registered: true,
                               created: Date(timeIntervalSince1970: created.timeIntervalSince1970.rounded()), displayName: nil, messageCount: 0, contactCount: 0, groupCount: 0, mediaCount: 0)
        _ = try BackupExporter.write(to: url, keys: keys, store: store, manifest: m, created: created)
    }

    @MainActor func testSearchFindsEveryBackupNewestFirstAndNeverPicksOne() async throws {
        let key = BackupKey.generate(), other = BackupKey.generate()
        let dev = try BackupLocations.deviceDirectory()
        try writeBackup(to: dev.appendingPathComponent("a.privabackup"), key: key, created: Date().addingTimeInterval(-86_400 * 40))
        try writeBackup(to: dev.appendingPathComponent("b.privabackup"), key: other, created: Date().addingTimeInterval(-86_400))
        let inbox = try XCTUnwrap(BackupLocations.receivedDirectory())
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try writeBackup(to: inbox.appendingPathComponent("from-airdrop.privabackup"), key: key, created: Date().addingTimeInterval(-3600))
        // The same backup twice (e.g. on this iPhone and received again): listed once.
        try FileManager.default.copyItem(at: dev.appendingPathComponent("a.privabackup"), to: inbox.appendingPathComponent("a-copy.privabackup"))
        // Junk named like a backup, and a link pointing at something that isn't one.
        try Data("not a backup at all".utf8).write(to: inbox.appendingPathComponent("junk.privabackup"))
        try FileManager.default.createSymbolicLink(at: inbox.appendingPathComponent("link.privabackup"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))

        let found = await BackupLocations.search(wait: 0)
        XCTAssertEqual(found.count, 3, "three distinct genuine backups")
        XCTAssertEqual(found.map(\.header.created), found.map(\.header.created).sorted(by: >), "newest first")
        XCTAssertEqual(found.first?.location, .received)
        XCTAssertEqual(Set(found.map(\.header.keyHint)), [BackupKey.hint(for: try key.keyPair().publicPair), BackupKey.hint(for: try other.keyPair().publicPair)])
        XCTAssertEqual(found.filter { $0.header.id == (try? BackupReader.peek(dev.appendingPathComponent("a.privabackup")))?.id }.first?.location, .device,
                       "a duplicate prefers the copy already on this iPhone")
    }

    func testICloudPlaceholdersAreRecognised() throws {
        for name in [".b.privabackup.icloud", "b.privabackup", ".other.pdf.icloud", ".x.privabackup"] {
            try Data().write(to: tmp.appendingPathComponent(name))
        }
        XCTAssertEqual(BackupLocations.icloudPlaceholders(in: tmp).map(\.lastPathComponent), [".b.privabackup.icloud"])
    }

    // MARK: - A tampered listing can't mislead the restore

    @MainActor func testAForgedDateInTheFileHeaderIsCaughtWhenOpening() async throws {
        let key = BackupKey.generate()
        let url = tmp.appendingPathComponent("v.privabackup")
        try writeBackup(to: url, key: key, created: Date().addingTimeInterval(-86_400 * 90))
        // An attacker edits the (unencrypted) header so an old backup looks like today's.
        var raw = try Data(contentsOf: url)
        let h = try BackupReader.peek(url)
        let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys; enc.dateEncodingStrategy = .secondsSince1970
        let oldCore = try enc.encode(h)
        let fake = BackupHeader(id: h.id, created: .now, keyHint: h.keyHint, pwSalt: h.pwSalt, pwRounds: h.pwRounds,
                                usesKeychain: h.usesKeychain, ctX: h.ctX, ctK: h.ctK)
        let newCore = try enc.encode(fake)
        let r = try XCTUnwrap(raw.range(of: oldCore))
        raw.replaceSubrange(r, with: newCore)
        raw.replaceSubrange(8..<12, with: withUnsafeBytes(of: UInt32(newCore.count).bigEndian) { Data($0) })
        try raw.write(to: url)
        XCTAssertGreaterThan(try BackupReader.peek(url).created, Date().addingTimeInterval(-60), "the listing shows the forged date…")
        do {
            _ = try await BackupRestore.unlock(url, key: key, password: Self.password)
            XCTFail("a forged header must not open")
        } catch {
            XCTAssertEqual(error as? BackupError, .wrongKey, "…but the header is authenticated, so the file won't open")
        }
    }

    // MARK: - Attempt limit

    @MainActor func testWrongKeyAttemptsSlowDownAndSurviveAReinstall() async throws {
        let key = BackupKey.generate()
        let url = tmp.appendingPathComponent("t.privabackup")
        try writeBackup(to: url, key: key, created: .now)
        XCTAssertEqual(RestoreThrottle.delay(after: 2), 0)
        XCTAssertEqual(RestoreThrottle.delay(after: 3), 30)
        XCTAssertEqual(RestoreThrottle.delay(after: 9), 3600)
        for _ in 0..<3 {
            do { _ = try await BackupRestore.unlock(url, key: key, password: "wrong guess"); XCTFail() } catch { XCTAssertEqual(error as? BackupError, .wrongKey) }
        }
        XCTAssertEqual(RestoreThrottle.failures, 3)
        // Even the RIGHT key and password wait now: the limit doesn't reveal whether a guess was right.
        do {
            _ = try await BackupRestore.unlock(url, key: key, password: Self.password)
            XCTFail("should be throttled")
        } catch let t as BackupRestore.Throttled {
            XCTAssertGreaterThan(t.seconds, 20)
        }
        // Deleting and reinstalling Priva (which clears its Keychain leftovers) keeps the count.
        AppModel.clearLeftovers(keepingRevocation: true)
        XCTAssertGreaterThan(RestoreThrottle.wait(), 20)
        // After the wait, the right key works and the count resets.
        RestoreThrottle.reset()
        let s = try await BackupRestore.unlock(url, key: key, password: Self.password)
        XCTAssertEqual(RestoreThrottle.failures, 0)
        BackupRestore.discard(s)
    }

    // MARK: - Welcome tour: first install only

    @MainActor func testTheWelcomeTourShowsOnceForANewAccountAndNeverAfterARestore() throws {
        WelcomeTour.debugForget()
        let ob = OnboardingModel()
        XCTAssertTrue(ob.shouldShowTour, "a brand-new account on a first install")
        ob.restored = .init(oldUsername: "x_user_0001", friends: 1, groups: 0, messages: 3)
        XCTAssertFalse(ob.shouldShowTour, "not after restoring a backup")
        ob.restored = nil
        ob.previous = .init(username: "x_user_0001", identity: try IdentityKeys(seed: IdentityKeys.newSeed()))
        XCTAssertFalse(ob.shouldShowTour, "not after signing back in with the recovery phrase")
        ob.previous = nil

        WelcomeTour.markSeen()
        XCTAssertFalse(OnboardingModel().shouldShowTour, "never again once seen")
        // Deleting and reinstalling Priva: UserDefaults go, the Keychain flag survives the leftovers cleanup.
        UserDefaults.standard.removeObject(forKey: "priva.tour.seen")
        AppModel.clearLeftovers(keepingRevocation: true)
        XCTAssertTrue(WelcomeTour.seen, "a reinstall isn't a first download")
        WelcomeTour.debugForget()
    }

    /// A restore cut off at each point of the folder swap (app killed, battery dead): the next launch leaves exactly
    /// one whole account, the previous one, or the restored one once its vault exists, and never deletes the
    /// previous account's data while the restore could still be undone.
    @MainActor func testAnInterruptedRestoreCommitIsFinishedOrUndone() throws {
        let fm = FileManager.default
        func world() throws -> (base: URL, dst: URL, j: BackupRestore.CommitJournal) {
            let base = fm.temporaryDirectory.appendingPathComponent("commit-\(UUID().uuidString)", isDirectory: true)
            let dst = base.appendingPathComponent("Priva", isDirectory: true)
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
            try Data("previous".utf8).write(to: dst.appendingPathComponent("marker"))
            let staged = base.appendingPathComponent("Restore-staged", isDirectory: true)
            try fm.createDirectory(at: staged, withIntermediateDirectories: true)
            try Data("restored".utf8).write(to: staged.appendingPathComponent("marker"))
            return (base, dst, .init(newUsername: "new_name_word_0001", old: "Restore-old-x", staged: "Restore-staged"))
        }
        func marker(_ dst: URL) -> String? { (try? Data(contentsOf: dst.appendingPathComponent("marker"))).map { String(decoding: $0, as: UTF8.self) } }

        // 1. Killed before anything moved: the previous account, untouched.
        var w = try world()
        BackupRestore.resolve(w.j, store: w.dst, vaultUsername: "old_name_word_0001")
        XCTAssertEqual(marker(w.dst), "previous")
        XCTAssertFalse(fm.fileExists(atPath: w.base.appendingPathComponent("Restore-staged").path))

        // 2. Killed after the previous store was moved aside: it's put back.
        w = try world()
        try fm.moveItem(at: w.dst, to: w.base.appendingPathComponent(w.j.old))
        BackupRestore.resolve(w.j, store: w.dst, vaultUsername: "old_name_word_0001")
        XCTAssertEqual(marker(w.dst), "previous")

        // 3. Killed after the restored store moved in, before its vault was written: undone.
        w = try world()
        try fm.moveItem(at: w.dst, to: w.base.appendingPathComponent(w.j.old))
        try fm.moveItem(at: w.base.appendingPathComponent("Restore-staged"), to: w.dst)
        BackupRestore.resolve(w.j, store: w.dst, vaultUsername: "old_name_word_0001")
        XCTAssertEqual(marker(w.dst), "previous", "the vault is still the previous account's, so is the store")

        // 4. Killed after the new vault was written: the restore stands; the previous store is cleaned up.
        w = try world()
        try fm.moveItem(at: w.dst, to: w.base.appendingPathComponent(w.j.old))
        try fm.moveItem(at: w.base.appendingPathComponent("Restore-staged"), to: w.dst)
        BackupRestore.resolve(w.j, store: w.dst, vaultUsername: w.j.newUsername)
        XCTAssertEqual(marker(w.dst), "restored")
        XCTAssertFalse(fm.fileExists(atPath: w.base.appendingPathComponent(w.j.old).path))
    }
}
