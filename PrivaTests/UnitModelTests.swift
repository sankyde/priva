import CryptoKit
import XCTest
@testable import Priva

/// Fast, offline unit tests for models, parsers, storage and protocol invariants.
nonisolated final class UnitModelTests: XCTestCase {

    // MARK: search

    func testSearchFindsMessagesOnThisIPhoneAndStopsWhenAsked() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("search-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try Store(vaultKey: SymmetricKey(size: .bits256), directory: dir)
        func msg(_ text: String?, _ contact: String = "friend_0001", kind: Message.Kind = .text, ago: Double = 0,
                 file: String? = nil, expires: Date? = nil) -> Message {
            let att = file.map { Attachment(fileID: UUID().uuidString, kind: .file, name: $0, mime: "application/pdf", size: 1, key: Data(count: 32),
                                            header: Data(), sha256: Data(), thumbnail: nil, width: nil, height: nil, duration: nil, progress: 1) }
            return Message(id: UUID().uuidString, contact: contact, outgoing: false, kind: kind, text: text, attachment: att,
                           sentAt: Date().addingTimeInterval(-ago), status: .received, expiresAt: expires)
        }
        var all = (0..<5_000).map { msg("filler message \($0)", ago: Double($0) * 60) }
        all += [msg("Meet at the Café Lunar at 6", ago: 10), msg("cafe lunar again?", "g:abc", ago: 5),
                msg(nil, kind: .media, ago: 3, file: "lunar-plan.pdf"),
                msg("You're now connected. cafe lunar", kind: .system),
                msg("gone cafe lunar", expires: Date().addingTimeInterval(-1))]
        try store.importMessages(all)

        let t = Date()
        let hits = store.searchMessages("cafe LUNAR")
        let ms = Date().timeIntervalSince(t) * 1000
        XCTAssertEqual(hits.compactMap(\.text), ["cafe lunar again?", "Meet at the Café Lunar at 6"], "newest first, accents and case ignored")
        XCTAssertEqual(store.searchMessages("lunar").count, 3, "file names too; never system lines or expired messages")
        XCTAssertTrue(store.searchMessages("l").isEmpty, "one letter would match everything")
        XCTAssertEqual(store.searchMessages("filler", limit: 20).count, 20)
        var pages = 0
        XCTAssertTrue(store.searchMessages("nothing like this") { pages += 1; return pages > 2 }.isEmpty)
        XCTAssertEqual(pages, 3, "stops at the next page once cancelled")
        XCTAssertLessThan(ms, 1_500, "5,000 encrypted messages searched in well under 1.5 s (simulator)")
        print("METRIC search_5000_ms = \(Int(ms))")
    }

    // MARK: network privacy

    func testNetworkPrivacyRoutesFailClosedAndDecodesLegacySettings() throws {
        XCTAssertNil(NetworkPrivacy(mode: .direct).effectiveProxy)
        let tor = NetworkPrivacy(mode: .tor)
        if TorService.socksPort == 0 {
            XCTAssertEqual(tor.effectiveProxy?.port, 9, "Tor not up yet → closed port, never direct")
        }
        XCTAssertEqual(NetworkPrivacy(mode: .proxy, host: "", port: 9050).effectiveProxy?.port, 9, "invalid proxy fails closed")
        XCTAssertEqual(NetworkPrivacy(mode: .proxy, host: "10.0.0.2", port: 9150).effectiveProxy?.host, "10.0.0.2")
        XCTAssertNotEqual(NetworkPrivacy(mode: .direct).routeKey, NetworkPrivacy(mode: .proxy, host: "a", port: 1).routeKey)
        // Settings saved by the previous version ({onion, host, port}) keep working.
        let legacy = try JSONDecoder().decode(NetworkPrivacy.self, from: Data(#"{"onion":true,"host":"127.0.0.1","port":9150}"#.utf8))
        XCTAssertEqual(legacy.mode, .proxy)
        XCTAssertEqual(legacy.port, 9150)
        let off = try JSONDecoder().decode(NetworkPrivacy.self, from: Data(#"{"onion":false}"#.utf8))
        XCTAssertEqual(off.mode, .direct)
        let round = try JSONDecoder().decode(NetworkPrivacy.self, from: try JSONEncoder().encode(NetworkPrivacy(mode: .tor)))
        XCTAssertEqual(round.mode, .tor)
    }

    func testTorListenerParsing() {
        XCTAssertEqual(TorService.parsePort("\"127.0.0.1:53211\""), 53211)
        XCTAssertEqual(TorService.parsePort("\"[::1]:9050\" \"127.0.0.1:9150\""), 9150, "loopback IPv4 listener picked")
        XCTAssertNil(TorService.parsePort("\"0.0.0.0:9050\""), "never a non-loopback listener")
        XCTAssertNil(TorService.parsePort(""))
        XCTAssertNil(TorService.parsePort("\"127.0.0.1:0\""))
    }

    // MARK: usernames

    func testUsernameNormalisationAndValidity() {
        XCTAssertEqual(Username.normalize("  @Beach-Gate-Swear-3315 "), "beach_gate_swear_3315")
        XCTAssertEqual(Username.normalize("beach gate.swear 3315"), "beach_gate_swear_3315")
        XCTAssertTrue(Username.isValid("beach_gate_swear_3315"))
        XCTAssertFalse(Username.isValid("ab"))
        XCTAssertFalse(Username.isValid("drop table;"))
        XCTAssertFalse(Username.isValid(String(repeating: "a", count: 25)))
        let names = Set((0..<500).map { _ in Username.random() })
        XCTAssertEqual(names.count, 500, "no collisions in a small sample")
        XCTAssertTrue(names.allSatisfy(Username.isValid))
        XCTAssertGreaterThan(Username.entropyBits, 43)
    }

    // MARK: groups

    func testInviteSnapshotRevealsOnlyTheHost() throws {
        let host = try IdentityKeys(seed: IdentityKeys.newSeed())
        let hb = try host.bundle(username: "host_user_0001")
        func member(_ u: String, _ r: PrivaGroup.Role) -> PrivaGroup.Member {
            .init(username: u, role: r, joined: .now, bundleRaw: hb.raw, inbox: "i-\(u)")
        }
        var g = PrivaGroup(id: "g1", name: "Team", host: "host_user_0001", epoch: 3,
                           members: [member("host_user_0001", .host), member("bob_user_0002", .admin), member("carol_user_0003", .member)])
        g.charter = try SignedCharter.sign(Charter(groupID: "g1", epoch: 3, host: "host_user_0001", successors: g.successors, ts: 1), identity: host)
        let inv = GroupSnapshot.invite(for: g, hostName: "Host")
        XCTAssertEqual(inv.group.members.map(\.username), ["host_user_0001"])
        XCTAssertNil(inv.group.charter)
        XCTAssertEqual(inv.memberCount, 3)
        XCTAssertEqual(inv.group.rules, g.rules)
        XCTAssertEqual(g.successors, ["bob_user_0002", "carol_user_0003"], "admins first, then longest-standing members")
    }

    func testCharterSignaturesBindEveryField() throws {
        let host = try IdentityKeys(seed: IdentityKeys.newSeed())
        let other = try IdentityKeys(seed: IdentityKeys.newSeed())
        let hb = try host.bundle(username: "host_user_0001"), ob = try other.bundle(username: "other_user_0002")
        let c = Charter(groupID: "g1", epoch: 7, host: "host_user_0001", successors: ["a_user_0001", "b_user_0002"], ts: 42)
        let s = try SignedCharter.sign(c, identity: host)
        XCTAssertTrue(s.verify(with: hb))
        XCTAssertFalse(s.verify(with: ob), "wrong signer")
        for tampered in [
            Charter(groupID: "g2", epoch: 7, host: c.host, successors: c.successors, ts: 42),
            Charter(groupID: "g1", epoch: 8, host: c.host, successors: c.successors, ts: 42),
            Charter(groupID: "g1", epoch: 7, host: "mallory_0003", successors: c.successors, ts: 42),
            Charter(groupID: "g1", epoch: 7, host: c.host, successors: ["mallory_0003"], ts: 42),
        ] {
            XCTAssertFalse(SignedCharter(charter: tampered, signature: s.signature).verify(with: hb))
        }
    }

    func testGroupPacketRoutingMetadata() {
        let e = Wire.Envelope(id: UUID().uuidString, sentAt: .now, kind: .text, text: "x", attachment: nil, replyTo: nil, expiresIn: nil)
        let durable: [GroupPacket] = [.join(groupID: "g", accept: true, name: nil), .admin(groupID: "g", action: .leave),
                                      .removed(groupID: "g", reason: ""), .deleted(groupID: "g", id: "m"), .sync(groupID: "g", since: 0)]
        let ephemeral: [GroupPacket] = [.post(groupID: "g", envelope: e), .ack(groupID: "g", ids: []),
                                        .callInvite(groupID: "g", callID: "c", video: true), .callEnd(groupID: "g", callID: "c")]
        XCTAssertTrue(durable.allSatisfy(\.isDurable))
        XCTAssertFalse(ephemeral.contains(where: \.isDurable), "calls and posts are never queued as control packets")
        XCTAssertTrue((durable + ephemeral).allSatisfy { $0.groupID == "g" })
    }

    // MARK: storage

    func testStoreUnreadCountsAndKeyValueRemoval() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("unit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try Store(vaultKey: SymmetricKey(size: .bits256), directory: dir)
        func msg(_ out: Bool, read: Bool, kind: Message.Kind = .text) -> Message {
            var m = Message(id: UUID().uuidString, contact: "friend_user_0001", outgoing: out, kind: kind, text: "t", attachment: nil,
                            sentAt: .now, status: out ? .delivered : .received)
            if read { m.readAt = .now }
            return m
        }
        for m in [msg(false, read: false), msg(false, read: false), msg(false, read: true), msg(true, read: false), msg(false, read: false, kind: .system)] {
            try store.save(m)
        }
        XCTAssertEqual(try store.unreadCount(for: "friend_user_0001"), 2, "incoming, unread, non-system only")
        var first = try XCTUnwrap(try store.messages(with: "friend_user_0001").first { !$0.outgoing && $0.readAt == nil && $0.kind == .text })
        first.readAt = .now
        try store.save(first)
        XCTAssertEqual(try store.unreadCount(for: "friend_user_0001"), 1)
        XCTAssertEqual(try store.unreadCount(for: "someone_else_0002"), 0)
        try store.set(["a", "b"], for: "k")
        XCTAssertEqual(store.get([String].self, for: "k"), ["a", "b"])
        store.removeValue(for: "k")
        XCTAssertNil(store.get([String].self, for: "k"))
        // At rest: neither contents nor the contact's name appear in the database file.
        let db = try Data(contentsOf: dir.appendingPathComponent("priva.db"))
        XCTAssertNil(db.range(of: Data("friend_user_0001".utf8)))
    }

    // MARK: robustness

    /// Mutated protocol messages must decode or throw, never trap.
    func testProtocolDecodersSurviveMutationFuzzing() throws {
        let e = Wire.Envelope(id: UUID().uuidString, sentAt: .now, kind: .text, text: "hello", attachment: nil, replyTo: nil, expiresIn: 60)
        let samples: [Data] = try [
            JSONEncoder().encode(Wire.message(e)),
            JSONEncoder().encode(Wire.group(.post(groupID: "g", envelope: e))),
            JSONEncoder().encode(Wire.group(.callRoster(groupID: "g", callID: "c", participants: ["a_b_c_0001"]))),
            JSONEncoder().encode(Wire.fileWant(fileID: UUID().uuidString, missing: [0, 1, 2])),
            JSONEncoder().encode(PrivaSettings()),
            JSONEncoder().encode(NetworkPrivacy(mode: .tor)),
        ]
        var rng = SystemRandomNumberGenerator()
        var decoded = 0
        for sample in samples {
            for _ in 0..<400 {
                var d = sample
                for _ in 0..<Int.random(in: 1...6, using: &rng) {
                    let i = Int.random(in: 0..<d.count, using: &rng)
                    switch Int.random(in: 0..<3, using: &rng) {
                    case 0: d[i] = UInt8.random(in: 0...255, using: &rng)
                    case 1: d.remove(at: i)
                    default: d.insert(UInt8.random(in: 32...126, using: &rng), at: i)
                    }
                    if d.isEmpty { d = Data("{".utf8) }
                }
                if (try? JSONDecoder().decode(Wire.self, from: d)) != nil { decoded += 1 }
                _ = try? JSONDecoder().decode(PrivaSettings.self, from: d)
                _ = try? JSONDecoder().decode(NetworkPrivacy.self, from: d)
            }
        }
        XCTAssertGreaterThanOrEqual(decoded, 0)   // reaching here without a trap is the assertion
    }

    func testPrivaSettingsTolerateMissingAndUnknownKeys() throws {
        let s = try JSONDecoder().decode(PrivaSettings.self, from: Data(#"{"readReceipts":true,"somethingNew":42}"#.utf8))
        XCTAssertTrue(s.readReceipts)
        XCTAssertTrue(s.typingIndicators, "missing keys keep their defaults")
        XCTAssertEqual(s.videoQuality, 720)
    }

    /// Audit TST-08: this used to sit outside any test class and never ran.
    func testKeywordFilterResistsInvisibleCharactersAndMasksPhrases() {
        var r = PrivaGroup.Rules()
        r.keywords = ["spoiler", "secret plan"]
        r.filterAction = .block
        XCTAssertTrue(KeywordFilter.apply("big spo\u{200B}iler here", rules: r).blocked, "zero-width space doesn't split the word")
        XCTAssertTrue(KeywordFilter.apply("SPO\u{2060}ILER", rules: r).blocked, "word joiner")
        XCTAssertTrue(KeywordFilter.apply("a spo\u{00AD}iler", rules: r).blocked, "soft hyphen")
        XCTAssertTrue(KeywordFilter.apply("\u{FF53}\u{FF50}\u{FF4F}\u{FF49}\u{FF4C}\u{FF45}\u{FF52}", rules: r).blocked, "full-width letters")
        XCTAssertTrue(KeywordFilter.apply("the Sécret  plan", rules: r).blocked, "accents and case folded")
        XCTAssertFalse(KeywordFilter.apply("spoilers are fine", rules: r).blocked, "whole words only")
        r.filterAction = .mask
        let m = KeywordFilter.apply("our secret plan: no spoiler", rules: r)
        XCTAssertFalse(m.blocked)
        XCTAssertTrue(m.hit)
        XCTAssertFalse(m.text.localizedCaseInsensitiveContains("secret plan"))
        XCTAssertFalse(m.text.localizedCaseInsensitiveContains("spoiler"))
        XCTAssertEqual(KeywordFilter.apply("nothing to see", rules: r).text, "nothing to see")
    }
}
