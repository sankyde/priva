import CryptoKit
import XCTest
@testable import Priva

nonisolated final class CryptoTests: XCTestCase {

    // MARK: DualAEAD

    func testDualAEADRoundTripAndTamper() throws {
        let key = DualKey(Bytes.random(64))
        let nonce = Bytes.random(12)
        let pt = Data("the quick brown fox".utf8)
        let ct = try DualAEAD.seal(pt, key: key, nonce: nonce, aad: Data("aad".utf8))
        XCTAssertEqual(ct.count, pt.count + DualAEAD.overhead)
        XCTAssertEqual(try DualAEAD.open(ct, key: key, nonce: nonce, aad: Data("aad".utf8)), pt)

        for i in 0..<ct.count {
            var t = ct
            t[i] ^= 0x80
            XCTAssertThrowsError(try DualAEAD.open(t, key: key, nonce: nonce, aad: Data("aad".utf8)), "byte \(i)")
        }
        XCTAssertThrowsError(try DualAEAD.open(ct, key: key, nonce: nonce, aad: Data("AAD".utf8)))
        XCTAssertThrowsError(try DualAEAD.open(ct, key: key, nonce: Bytes.random(12), aad: Data("aad".utf8)))
        XCTAssertThrowsError(try DualAEAD.open(ct, key: DualKey(Bytes.random(64)), nonce: nonce, aad: Data("aad".utf8)))
    }

    func testDualAEADBothLayersIndependent() throws {
        // Knowing only one layer's key must not reveal plaintext.
        let material = Bytes.random(64)
        let key = DualKey(material)
        let pt = Data(repeating: 0x41, count: 64)
        let ct = try DualAEAD.seal(pt, key: key, nonce: Data(count: 12), aad: Data())
        var halfBroken = material
        halfBroken.replaceSubrange(0..<32, with: Bytes.random(32))
        XCTAssertThrowsError(try DualAEAD.open(ct, key: DualKey(halfBroken), nonce: Data(count: 12), aad: Data()))
        XCTAssertFalse(ct.range(of: pt.prefix(16)) != nil, "plaintext must not appear in ciphertext")
    }

    // MARK: DualSeal

    func testDualSealRoundTrip() throws {
        let bob = try KEMPrivatePair.generate()
        let pt = Data("friend request".utf8)
        let sealed = try DualSeal.seal(pt, to: bob.publicPair, aad: Data("req|bob".utf8))
        XCTAssertEqual(sealed.envelope.count, DualSeal.headerSize + pt.count + 32)
        let (opened, res) = try DualSeal.open(sealed.envelope, with: bob, aad: Data("req|bob".utf8))
        XCTAssertEqual(opened, pt)
        XCTAssertEqual(res.exporter, sealed.exporter)
        XCTAssertEqual(res.transcript, sealed.transcript)
    }

    func testDualSealRejectsWrongRecipientAadAndTamper() throws {
        let bob = try KEMPrivatePair.generate(), eve = try KEMPrivatePair.generate()
        let env = try DualSeal.seal(Data("secret".utf8), to: bob.publicPair, aad: Data("x".utf8)).envelope
        XCTAssertThrowsError(try DualSeal.open(env, with: eve, aad: Data("x".utf8)))
        XCTAssertThrowsError(try DualSeal.open(env, with: bob, aad: Data("y".utf8)))
        for i in [0, 1, 500, 1119, 1121, 2000, 2688, env.count - 1] {
            var t = env
            t[i] ^= 1
            XCTAssertThrowsError(try DualSeal.open(t, with: bob, aad: Data("x".utf8)), "byte \(i)")
        }
    }

    // MARK: Identity & bundle

    func testIdentityIsDeterministicFromSeed() throws {
        let seed = IdentityKeys.newSeed()
        let a = try IdentityKeys(seed: seed), b = try IdentityKeys(seed: seed)
        XCTAssertEqual(try a.bundle(username: "alice").keyMaterial, try b.bundle(username: "alice").keyMaterial)
        XCTAssertEqual(a.inboxTopic, b.inboxTopic)
        XCTAssertEqual(a.announceKey, b.announceKey)
        let c = try IdentityKeys(seed: IdentityKeys.newSeed())
        XCTAssertNotEqual(try a.bundle(username: "alice").keyMaterial, try c.bundle(username: "alice").keyMaterial)
        XCTAssertNotEqual(a.inboxTopic, c.inboxTopic)
    }

    func testBundleLayoutMatchesServer() throws {
        let id = try IdentityKeys(seed: IdentityKeys.newSeed())
        let b = try id.bundle(username: "cedar_lunar_pilot_0042")
        XCTAssertEqual(b.raw.count, 8182, "4+1+32+32+1952+1216+1568+4+64+3309")
        XCTAssertEqual(b.raw.prefix(5), Data("PRVB".utf8) + Data([2]))
        let parsed = try KeyBundle.parse(b.raw)
        XCTAssertEqual(parsed, b)
        XCTAssertTrue(parsed.belongs(to: "cedar_lunar_pilot_0042"))
        XCTAssertTrue(parsed.belongs(to: "  CEDAR_LUNAR_PILOT_0042 "), "normalised")
        XCTAssertFalse(parsed.belongs(to: "cedar_lunar_pilot_0043"))
        XCTAssertNil(b.raw.range(of: Data("cedar".utf8)), "the bundle never contains the username")
    }

    func testBundleTamperRejected() throws {
        let b = try IdentityKeys(seed: IdentityKeys.newSeed()).bundle(username: "amber_frost_pilot_1234")
        for i in [5, 20, 40, 1000, 3000, 5000, 6700, b.raw.count - 3000, b.raw.count - 1] {
            var t = b.raw
            t[i] ^= 1
            XCTAssertThrowsError(try KeyBundle.parse(t), "byte \(i)")
        }
        XCTAssertThrowsError(try KeyBundle.parse(b.raw + Data([0])))
        XCTAssertThrowsError(try KeyBundle.parse(b.raw.dropLast()))
    }

    func testUsernameRules() {
        XCTAssertTrue(Username.isValid("abc"))
        XCTAssertTrue(Username.isValid("cedar_lunar_pilot_5821"))
        XCTAssertFalse(Username.isValid("ab"))
        XCTAssertFalse(Username.isValid("Alice"))
        XCTAssertFalse(Username.isValid("ålice"))
        XCTAssertFalse(Username.isValid(String(repeating: "a", count: 25)))
        XCTAssertEqual(Username.normalize("  @Cedar Lunar-Pilot.5821 "), "cedar_lunar_pilot_5821")
    }

    func testRandomUsernames() {
        XCTAssertEqual(Username.words.count, 1024)
        XCTAssertEqual(Set(Username.words).count, 1024)
        var seen = Set<String>()
        for _ in 0..<500 {
            let n = Username.random()
            XCTAssertTrue(Username.isValid(n), n)
            XCTAssertLessThanOrEqual(n.count, 22)
            let parts = n.split(separator: "_")
            XCTAssertEqual(parts.count, 4)
            XCTAssertEqual(parts[3].count, 4)
            XCTAssertTrue(parts[3].allSatisfy { $0.isNumber })
            seen.insert(n)
        }
        XCTAssertEqual(seen.count, 500, "no collisions in 500 draws from 2^43")
        XCTAssertGreaterThan(Username.entropyBits, 43)
    }

    func testUsernameCommitmentAndTopicsAreIndependent() {
        let a = UsernameKey.derive("cedar_lunar_pilot_0042"), b = UsernameKey.derive("cedar_lunar_pilot_0043")
        XCTAssertEqual(a.ucommit.count, 32)
        XCTAssertNotEqual(a.ucommit, b.ucommit)
        XCTAssertNotEqual(a.ucommit, a.topicKey, "commitment and topic key are separate branches")
        XCTAssertTrue(UsernameKey.requestTopic("cedar_lunar_pilot_0042").hasPrefix("r-"))
        XCTAssertEqual(UsernameKey.commitment("cedar_lunar_pilot_0042"), a.ucommit, "deterministic")
    }

    func testRenameAnnouncement() throws {
        let old = try IdentityKeys(seed: IdentityKeys.newSeed()), new = try IdentityKeys(seed: IdentityKeys.newSeed())
        let oldBundle = try old.bundle(username: "old_name_zzz_0001"), newBundle = try new.bundle(username: "new_name_zzz_0002")
        let env = try Announcement.make(old: old, oldUsername: "old_name_zzz_0001", newUsername: "new_name_zzz_0002",
                                        newBundle: newBundle, displayName: "Al", generation: 7)
        let p = try Announcement.open(env, announceKey: old.announceKey, pinned: oldBundle, oldUsername: "old_name_zzz_0001")
        XCTAssertEqual(p.new, "new_name_zzz_0002")
        XCTAssertEqual(p.generation, 7)
        let mallory = try IdentityKeys(seed: IdentityKeys.newSeed())
        let forged = try Announcement.make(old: mallory, oldUsername: "old_name_zzz_0001", newUsername: "evil_name_zzz_0003",
                                           newBundle: try mallory.bundle(username: "evil_name_zzz_0003"), displayName: nil, generation: 8)
        XCTAssertThrowsError(try Announcement.open(forged, announceKey: old.announceKey, pinned: oldBundle, oldUsername: "old_name_zzz_0001"),
                             "not signed by the pinned old keys")
        XCTAssertThrowsError(try Announcement.open(env, announceKey: Bytes.random(32), pinned: oldBundle, oldUsername: "old_name_zzz_0001"),
                             "unreadable without the announce key")
        let pr = Announcement.renameProof(announceKey: old.announceKey, friend: "bob", newUsername: "new_name_zzz_0002")
        XCTAssertNotEqual(pr, Announcement.renameProof(announceKey: old.announceKey, friend: "eve", newUsername: "new_name_zzz_0002"))
        XCTAssertNotEqual(old.revokeSecret, new.revokeSecret)
        XCTAssertEqual(old.revokeHash, KDF.sha256(old.revokeSecret).hex)
    }

    func testDirectoryStatusIsEvaluatedOnDevice() {
        let now = Date()
        XCTAssertEqual(PrivaAPI.evaluate(status: nil, leaseWeek: nil, now: now), .removed)
        XCTAssertEqual(PrivaAPI.evaluate(status: "uninstalled", leaseWeek: now.addingTimeInterval(86_400 * 20), now: now), .uninstalled)
        XCTAssertEqual(PrivaAPI.evaluate(status: "active", leaseWeek: now.addingTimeInterval(86_400 * 10), now: now), .active)
        XCTAssertEqual(PrivaAPI.evaluate(status: "active", leaseWeek: now.addingTimeInterval(-86_400 * 8), now: now), .uninstalled,
                       "lapsed lease ⇒ uninstalled, decided by the device")
    }

    // MARK: Recovery phrase

    func testRecoveryPhraseKnownVector() throws {
        // BIP-39 test vector: 32 zero bytes.
        let words = RecoveryPhrase.encode(Data(count: 32))
        XCTAssertEqual(words, Array(repeating: "abandon", count: 23) + ["art"])
        // BIP-39 test vector: 0x7f × 32.
        let w2 = RecoveryPhrase.encode(Data(repeating: 0x7f, count: 32))
        XCTAssertEqual(w2.joined(separator: " "),
                       "legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth title")
    }

    func testRecoveryPhraseRoundTripAndChecksum() throws {
        for _ in 0..<50 {
            let seed = IdentityKeys.newSeed()
            let words = RecoveryPhrase.encode(seed)
            XCTAssertEqual(words.count, 24)
            XCTAssertEqual(try RecoveryPhrase.decode(words), seed)
            XCTAssertEqual(try RecoveryPhrase.decode(words.joined(separator: "  ").uppercased()), seed)
        }
        var words = RecoveryPhrase.encode(IdentityKeys.newSeed())
        words.swapAt(0, 1)
        if words[0] != words[1] { XCTAssertThrowsError(try RecoveryPhrase.decode(words)) }
        XCTAssertThrowsError(try RecoveryPhrase.decode(Array(words.prefix(23))))
        XCTAssertThrowsError(try RecoveryPhrase.decode(Array(words.prefix(23)) + ["notaword"]))
    }

    // MARK: Safety numbers

    func testSafetyNumberSymmetric() throws {
        let a = try IdentityKeys(seed: IdentityKeys.newSeed()).bundle(username: "alice")
        let b = try IdentityKeys(seed: IdentityKeys.newSeed()).bundle(username: "bob")
        let ab = SafetyNumber.digits(me: "alice", a, them: "bob", b), ba = SafetyNumber.digits(me: "bob", b, them: "alice", a)
        XCTAssertEqual(ab, ba)
        XCTAssertEqual(ab.count, 12)
        XCTAssertTrue(ab.allSatisfy { $0.count == 5 && $0.allSatisfy(\.isNumber) })
        let m = try IdentityKeys(seed: IdentityKeys.newSeed()).bundle(username: "bob")
        XCTAssertNotEqual(SafetyNumber.digits(me: "alice", a, them: "bob", m), ab, "a key change must change the number")
        XCTAssertTrue(SafetyNumber.matches(qr: SafetyNumber.qrPayload(username: "bob", bundle: b), username: "bob", bundle: b))
        XCTAssertFalse(SafetyNumber.matches(qr: SafetyNumber.qrPayload(username: "bob", bundle: m), username: "bob", bundle: b))
    }

    // MARK: Pairing, signalling, handshake

    private func pair() throws -> (PairSecrets, PairSecrets) {
        let alice = try IdentityKeys(seed: IdentityKeys.newSeed()), bob = try IdentityKeys(seed: IdentityKeys.newSeed())
        let req = try DualSeal.seal(Data("req".utf8), to: bob.kem.publicPair, aad: Data())
        let (_, reqB) = try DualSeal.open(req.envelope, with: bob.kem, aad: Data())
        let acc = try DualSeal.seal(Data("acc".utf8), to: alice.kem.publicPair, aad: Data())
        let (_, accA) = try DualSeal.open(acc.envelope, with: alice.kem, aad: Data())
        let a = PairSecrets.establish(requestExporter: req.exporter, requestTranscript: req.transcript,
                                      acceptExporter: accA.exporter, acceptTranscript: accA.transcript, usernames: ("alice", "bob"))
        let b = PairSecrets.establish(requestExporter: reqB.exporter, requestTranscript: reqB.transcript,
                                      acceptExporter: acc.exporter, acceptTranscript: acc.transcript, usernames: ("bob", "alice"))
        return (a, b)
    }

    func testPairRootAgreesOnBothSides() throws {
        let (a, b) = try pair()
        XCTAssertEqual(a.current, b.current)
        XCTAssertEqual(a.current.count, 64)
    }

    func testSignalEnvelope() throws {
        let (a, b) = try pair()
        let env = try SignalEnvelope.seal(Data("hello".utf8), root: a.current, from: "alice", to: "bob", topic: "i-bob")
        XCTAssertTrue(Padding.buckets.contains(env.count - 1 - 12 - 32), "padded to a bucket")
        let opened = SignalEnvelope.open(env, roots: b.candidates, from: "alice", to: "bob", topic: "i-bob")
        XCTAssertEqual(opened?.0, Data("hello".utf8))
        XCTAssertNil(SignalEnvelope.open(env, roots: b.candidates, from: "bob", to: "alice", topic: "i-bob"), "direction bound")
        XCTAssertNil(SignalEnvelope.open(env, roots: b.candidates, from: "alice", to: "bob", topic: "i-eve"), "topic bound")
        XCTAssertNil(SignalEnvelope.open(env, roots: [Bytes.random(64)], from: "alice", to: "bob", topic: "i-bob"))
    }

    func testRatchetHealsAndKeepsPreviousForResync() throws {
        var (a, b) = try pair()
        let base = a.current
        let secret = Bytes.random(64)
        a.ratchet(from: base, sessionSecret: secret)
        // bob has not ratcheted yet (e.g. crashed): alice's new-root envelopes are not readable,
        // but alice can still read bob's old-root envelopes via `previous`.
        let fromBob = try SignalEnvelope.seal(Data("x".utf8), root: b.current, from: "bob", to: "alice", topic: "t")
        XCTAssertNotNil(SignalEnvelope.open(fromBob, roots: a.candidates, from: "bob", to: "alice", topic: "t"))
        b.ratchet(from: base, sessionSecret: secret)
        XCTAssertEqual(a.current, b.current)
        XCTAssertNotEqual(a.current, base)
    }

    func testHandshakeAgreesAndIsBoundToRoot() throws {
        let (a, b) = try pair()
        let ini = try Handshake.Initiator(me: "alice", peer: "bob", root: a.current)
        let res = try Handshake.Responder(me: "bob", peer: "alice", root: b.current, hello: ini.hello)
        let (fin, ka) = try ini.finish(with: res.ack)
        let kb = try res.complete(with: fin)
        XCTAssertEqual(ka.master, kb.master)
        XCTAssertEqual(ka.transcript, kb.transcript)
        XCTAssertEqual(ka.sas, kb.sas)
        XCTAssertEqual(ka.mediaKeys.send, kb.mediaKeys.receive)
        XCTAssertEqual(ka.mediaKeys.receive, kb.mediaKeys.send)
        XCTAssertNotEqual(ka.mediaKeys.send, ka.mediaKeys.receive)

        // An attacker without the pair root derives different keys → frames fail.
        let evil = try Handshake.Responder(me: "bob", peer: "alice", root: Bytes.random(64), hello: ini.hello)
        let (fin2, kaEvil) = try ini.finish(with: evil.ack)
        let kEvil = try evil.complete(with: fin2)
        XCTAssertNotEqual(kaEvil.master, kEvil.master)

        // Forward secrecy: a new session with the same root has independent keys.
        let ini2 = try Handshake.Initiator(me: "alice", peer: "bob", root: a.current)
        let res2 = try Handshake.Responder(me: "bob", peer: "alice", root: b.current, hello: ini2.hello)
        let (_, ka2) = try ini2.finish(with: res2.ack)
        XCTAssertNotEqual(ka.master, ka2.master)
    }

    /// Three-trip handshake: the responder's SDP offer travels in the ack, sealed with a key from the pair root and
    /// the initiator's fresh ephemeral. Only the friend can make it, and yesterday's ack can't be replayed or spliced.
    func testEarlyOfferKeyIsSharedAndBoundToTheRootAndThisHandshake() throws {
        let (a, b) = try pair()
        let ini = try Handshake.Initiator(me: "alice", peer: "bob", root: a.current)
        let res = try Handshake.Responder(me: "bob", peer: "alice", root: b.current, hello: ini.hello)
        let aad = Handshake.earlyAAD(sid: ini.hello.sid)
        let offer = try DualAEAD.sealRandom(Data("v=0 offer".utf8), key: res.earlyKey, aad: aad)
        let (fin, ka, early) = try ini.finishEarly(with: res.ack)
        XCTAssertEqual(try DualAEAD.openRandom(offer, key: early, aad: aad), Data("v=0 offer".utf8))
        XCTAssertEqual(ka.master, try res.complete(with: fin).master, "session keys unchanged by the early offer")

        // Someone without the pair root can't produce an offer the initiator opens.
        let evil = try Handshake.Responder(me: "bob", peer: "alice", root: Bytes.random(64), hello: ini.hello)
        let forged = try DualAEAD.sealRandom(Data("evil".utf8), key: evil.earlyKey, aad: aad)
        let (_, _, earlyVsEvil) = try ini.finishEarly(with: evil.ack)
        XCTAssertThrowsError(try DualAEAD.openRandom(forged, key: earlyVsEvil, aad: aad))

        // Yesterday's ack against today's hello: refused outright, and spliced under the new session id it opens nothing.
        let ini2 = try Handshake.Initiator(me: "alice", peer: "bob", root: a.current)
        XCTAssertThrowsError(try ini2.finishEarly(with: res.ack), "session id mismatch")
        let spliced = Handshake.Ack(sid: ini2.hello.sid, ctX: res.ack.ctX, ctK: res.ack.ctK, ephX: res.ack.ephX, ephK: res.ack.ephK)
        if let (_, _, early2) = try? ini2.finishEarly(with: spliced) {
            XCTAssertThrowsError(try DualAEAD.openRandom(offer, key: early2, aad: Handshake.earlyAAD(sid: ini2.hello.sid)))
        }
        // …and the sealed offer is bound to its session id.
        XCTAssertThrowsError(try DualAEAD.openRandom(offer, key: early, aad: Handshake.earlyAAD(sid: Bytes.random(16))))
    }

    /// Phones on an older build send JSON signals without the three-trip fields; they still decode.
    func testSignalsFromOlderBuildsStillDecode() throws {
        let hello = #"{"hello":{"sid":"AAAA","ephX":"AAAA","ephK":"AAAA","intent":"data","ts":1}}"#
        guard case .hello(_, _, _, _, let ts, let early)? = Signal.decode(Data(hello.utf8)) else { return XCTFail("old hello") }
        XCTAssertEqual(ts, 1)
        XCTAssertNil(early)
        let ack = #"{"ack":{"sid":"AAAA","ctX":"AAAA","ctK":"AAAA","ephX":"AAAA","ephK":"AAAA","ts":2}}"#
        guard case .ack(_, _, _, _, _, _, let sdp)? = Signal.decode(Data(ack.utf8)) else { return XCTFail("old ack") }
        XCTAssertNil(sdp)
        let fin = Signal.finish(sid: Data([1]), ctX: Data([2]), ctK: Data([3]), sdp: Data([4]), ts: 5)
        guard case .finish(let sid, _, _, let box, let t)? = Signal.decode(try fin.encoded()) else { return XCTFail("finish") }
        XCTAssertEqual(sid, Data([1]))
        XCTAssertEqual(box, Data([4]))
        XCTAssertEqual(t, 5)
    }

    func testFrameCipherOrderingAndReplay() throws {
        let (a, b) = try pair()
        let ini = try Handshake.Initiator(me: "alice", peer: "bob", root: a.current)
        let res = try Handshake.Responder(me: "bob", peer: "alice", root: b.current, hello: ini.hello)
        let (fin, ka) = try ini.finish(with: res.ack)
        let kb = try res.complete(with: fin)
        let sendA = FrameCipher(keys: ka.channelKeys("c"), channel: "c")
        let recvB = FrameCipher(keys: kb.channelKeys("c"), channel: "c")
        let f0 = try sendA.seal(type: 1, Data("zero".utf8))
        let f1 = try sendA.seal(type: 1, Data("one".utf8))
        XCTAssertThrowsError(try recvB.open(f1), "out of order")
        XCTAssertEqual(try recvB.open(f0).payload, Data("zero".utf8))
        XCTAssertThrowsError(try recvB.open(f0), "replay")
        XCTAssertEqual(try recvB.open(f1).payload, Data("one".utf8))
        // Channel separation: a control-channel frame is not valid on the file channel.
        let recvBf = FrameCipher(keys: kb.channelKeys("f"), channel: "f")
        XCTAssertThrowsError(try recvBf.open(try sendA.seal(type: 1, Data())))
    }

    func testKeyConfirmationDetectsDTLSSplice() throws {
        let (a, b) = try pair()
        let ini = try Handshake.Initiator(me: "alice", peer: "bob", root: a.current)
        let res = try Handshake.Responder(me: "bob", peer: "alice", root: b.current, hello: ini.hello)
        let (fin, ka) = try ini.finish(with: res.ack)
        let kb = try res.complete(with: fin)
        // Honest: both see initiator=AA:01, responder=BB:02.
        let fromA = ka.confirmation(fromInitiator: true, initiatorFingerprint: "AA:01", responderFingerprint: "BB:02")
        XCTAssertEqual(fromA, kb.confirmation(fromInitiator: true, initiatorFingerprint: "AA:01", responderFingerprint: "BB:02"))
        // MITM: bob was shown the attacker's certificate EE:66 instead of alice's.
        XCTAssertNotEqual(fromA, kb.confirmation(fromInitiator: true, initiatorFingerprint: "EE:66", responderFingerprint: "BB:02"))
        // Role binding: a reflected tag is not accepted as the other side's.
        XCTAssertNotEqual(fromA, kb.confirmation(fromInitiator: false, initiatorFingerprint: "AA:01", responderFingerprint: "BB:02"))
    }

    // MARK: Files

    func testFileCipherRoundTripRangesAndTamper() throws {
        let dir = FileManager.default.temporaryDirectory
        let src = dir.appendingPathComponent(UUID().uuidString)
        let enc = dir.appendingPathComponent(UUID().uuidString)
        let plain = Bytes.random(3 * FileCipherHeader.defaultChunk + 12_345)
        try plain.write(to: src)
        let key = SymmetricKey(size: .bits256)
        let (header, digest) = try FileCipher.encrypt(file: src, to: enc, key: key)
        XCTAssertEqual(digest, KDF.sha256(plain))
        XCTAssertEqual(header.chunkCount, 4)
        let size = try FileManager.default.attributesOfItem(atPath: enc.path)[.size] as! NSNumber
        XCTAssertEqual(size.uint64Value, header.encryptedSize)

        let reader = try FileCipher.Reader(url: enc, key: key)
        XCTAssertEqual(try reader.decryptAll(), plain)
        XCTAssertEqual(try reader.plainRange(offset: 131_000, length: 5_000), plain.subdata(in: 131_000..<136_000))
        XCTAssertEqual(try reader.plainRange(offset: UInt64(plain.count - 10), length: 100), plain.suffix(10))

        // Swapping two chunks, or presenting a middle chunk as the last one, must fail.
        let c0 = try reader.encryptedChunk(0), c1 = try reader.encryptedChunk(1)
        XCTAssertThrowsError(try FileCipher.openChunk(c1, index: 0, header: header, key: key))
        XCTAssertThrowsError(try FileCipher.openChunk(c0, index: 1, header: header, key: key))
        let truncated = FileCipherHeader(chunkSize: header.chunkSize, plainSize: UInt64(2 * header.chunkSize), nonceSalt: header.nonceSalt)
        XCTAssertThrowsError(try FileCipher.openChunk(c1, index: 1, header: truncated, key: key), "truncation detected")

        // Writer verifies each chunk; a corrupted chunk is refused.
        let out = dir.appendingPathComponent(UUID().uuidString)
        let writer = try FileCipher.Writer(url: out, header: header, key: key, resume: false)
        var bad = c0
        bad[10] ^= 1
        XCTAssertThrowsError(try writer.write(chunk: bad, index: 0))
        for i in (0..<header.chunkCount).reversed() { try writer.write(chunk: try reader.encryptedChunk(i), index: i) }
        XCTAssertTrue(writer.isComplete)
        try writer.finish()
        XCTAssertEqual(try FileCipher.Reader(url: out, key: key).decryptAll(), plain)
        for u in [src, enc, out] { try? FileManager.default.removeItem(at: u) }
    }

    // MARK: Blind tokens

    func testBlindTokenRejectsUnpinnedIssuerKey() throws {
        let other = try _RSABlindKeyFactory.unpinnedSPKI()
        XCTAssertThrowsError(try BlindToken.begin(spki: other))
    }

    // MARK: Password KDF

    func testPasswordKDF() throws {
        let salt = Bytes.random(16)
        let a = try PasswordKDF.derive("correct horse battery staple", salt: salt)
        XCTAssertEqual(a.count, 32)
        XCTAssertEqual(a, try PasswordKDF.derive("correct horse battery staple", salt: salt))
        XCTAssertNotEqual(a, try PasswordKDF.derive("correct horse battery staplE", salt: salt))
        XCTAssertNotEqual(a, try PasswordKDF.derive("correct horse battery staple", salt: Bytes.random(16)))
        // Unicode normalization: é composed vs decomposed give the same key.
        XCTAssertEqual(try PasswordKDF.derive("caf\u{E9}", salt: salt), try PasswordKDF.derive("cafe\u{301}", salt: salt))
    }
}

import CryptoExtras

nonisolated enum _RSABlindKeyFactory {
    static func unpinnedSPKI() throws -> Data {
        let k = try _RSA.BlindSigning.PrivateKey<SHA384>(keySize: .bits2048, parameters: .RSABSSA_SHA384_PSS_Deterministic)
        return k.publicKey.derRepresentation
    }


}
