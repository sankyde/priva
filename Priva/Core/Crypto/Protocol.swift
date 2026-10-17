import CryptoKit
import Foundation

// MARK: - Padding (hide message types/sizes from the rendezvous server)

nonisolated enum Padding {
    /// Sizes a sealed signal can have. They hide the SDP's length (network interfaces, media sections), not which
    /// step of a handshake it is, the order of signals shows that anyway, so steps of 2 KiB up to 8 KiB are fine,
    /// and much cheaper than jumping from 4 to 12 KiB (the server's egress is metered).
    static let buckets = [1_024, 2_048, 4_096, 6_144, 8_192, 12_288, 16_384, 32_768, 65_536]

    static func pad(_ d: Data) -> Data {
        let need = d.count + 4
        let size = buckets.first { $0 >= need } ?? (need + 4095) / 4096 * 4096
        var out = Data(capacity: size)
        out.appendBE(UInt32(d.count))
        out.append(d)
        out.append(Data(count: size - need))
        return out
    }

    static func unpad(_ d: Data) throws -> Data {
        var r = ByteReader(d)
        let n = Int(try r.readBE(UInt32.self))
        guard n <= r.remaining else { throw CryptoFailure.malformed }
        return try r.read(n)
    }
}

// MARK: - Pair root key (established by friend request + acceptance)

nonisolated struct PairSecrets: Codable, Sendable, Equatable {
    var current: Data
    var previous: Data?
    var epoch: UInt32

    static func establish(requestExporter: Data, requestTranscript: Data,
                          acceptExporter: Data, acceptTranscript: Data,
                          usernames: (String, String)) -> PairSecrets {
        var info = Data("priva/pair/v1".utf8)
        let names = [usernames.0, usernames.1].sorted()
        info.appendField(names[0])
        info.appendField(names[1])
        let root = KDF.derive(requestExporter + acceptExporter,
                              salt: KDF.sha512(requestTranscript, acceptTranscript), info: info, count: 64)
        return PairSecrets(current: root, previous: nil, epoch: 0)
    }

    /// Post-compromise healing: after a key-confirmed session, both sides roll the root forward.
    mutating func ratchet(from base: Data, sessionSecret: Data) {
        let next = KDF.derive(base + sessionSecret, salt: Data("priva/pair-ratchet/v1".utf8),
                              info: Data("root".utf8), count: 64)
        previous = base
        current = next
        epoch &+= 1
    }

    var candidates: [Data] { [current] + (previous.map { [$0] } ?? []) }

    static func signalKey(root: Data, from: String, to: String) -> DualKey {
        var info = Data("priva/signal/v1".utf8)
        info.appendField(from)
        info.appendField(to)
        return DualKey(KDF.derive(root, salt: Data(), info: info, count: 64))
    }
}

// MARK: - Signalling envelope (friend → friend inbox)

nonisolated enum SignalEnvelope {
    static let tag: UInt8 = 0x53 // "S"
    static func aad(topic: String) -> Data { Data("PRIVA-SIG-v1".utf8) + Data(topic.utf8) }

    static func seal(_ payload: Data, root: Data, from: String, to: String, topic: String) throws -> Data {
        let key = PairSecrets.signalKey(root: root, from: from, to: to)
        return Data([tag]) + (try DualAEAD.sealRandom(Padding.pad(payload), key: key, aad: aad(topic: topic)))
    }

    /// Trial-decrypts with every candidate root; returns the payload and which root matched.
    static func open(_ envelope: Data, roots: [Data], from: String, to: String, topic: String) -> (Data, Data)? {
        guard envelope.first == tag else { return nil }
        let body = envelope.detached.dropFirst().detached
        for root in roots {
            let key = PairSecrets.signalKey(root: root, from: from, to: to)
            if let pt = try? DualAEAD.openRandom(body, key: key, aad: aad(topic: topic)),
               let unpadded = try? Padding.unpad(pt) {
                return (unpadded, root)
            }
        }
        return nil
    }
}

// MARK: - Session handshake (4 fresh PQ encapsulations per session)

nonisolated struct SessionKeys: Sendable {
    let sid: Data
    let isInitiator: Bool
    let master: Data
    let transcript: Data

    private func k(_ label: String, _ n: Int) -> Data {
        KDF.derive(master, salt: transcript, info: Data(("priva/session/" + label).utf8), count: n)
    }

    func channelKeys(_ channel: String) -> (send: DualKey, receive: DualKey) {
        let i2r = DualKey(k("dc/\(channel)/i2r", 64)), r2i = DualKey(k("dc/\(channel)/r2i", 64))
        return isInitiator ? (i2r, r2i) : (r2i, i2r)
    }

    var signalKeys: (send: DualKey, receive: DualKey) {
        let i2r = DualKey(k("sig/i2r", 64)), r2i = DualKey(k("sig/r2i", 64))
        return isInitiator ? (i2r, r2i) : (r2i, i2r)
    }

    /// Frame-encryption keys for voice/video (fed to the WebRTC frame cryptor).
    var mediaKeys: (send: Data, receive: Data) {
        let i2r = k("media/i2r", 32), r2i = k("media/r2i", 32)
        return isInitiator ? (i2r, r2i) : (r2i, i2r)
    }

    var confirmKey: Data { k("confirm", 32) }
    var ratchetSecret: Data { k("ratchet", 64) }
    var sas: [String] { SafetyNumber.sas(k("sas", 8)) }
    var mediaSalt: Data { k("media/salt", 16) }

    /// Key confirmation over the DTLS certificate fingerprints *as each side observed them*.
    /// `fromInitiator` says which side produced the tag. A DTLS man-in-the-middle presents
    /// different certificates to each side, so the two views, and therefore the tags, differ.
    func confirmation(fromInitiator: Bool, initiatorFingerprint: String, responderFingerprint: String) -> Data {
        var m = Data("PRIVA-CONFIRM-v1".utf8)
        m.append(fromInitiator ? 1 : 2)
        m.appendField(initiatorFingerprint.lowercased())
        m.appendField(responderFingerprint.lowercased())
        return KDF.hmac(confirmKey, m)
    }
}

nonisolated enum Handshake {
    struct Hello: Codable, Sendable { let sid: Data; let ephX: Data; let ephK: Data }
    struct Ack: Codable, Sendable { let sid: Data; let ctX: Data; let ctK: Data; let ephX: Data; let ephK: Data }
    struct Finish: Codable, Sendable { let sid: Data; let ctX: Data; let ctK: Data }

    static func transcript(initiator: String, responder: String, hello: Hello, ack: Ack, finish: Finish) -> Data {
        var t = Data("PRIVA-SESSION-v1".utf8)
        for f in [Data(initiator.utf8), Data(responder.utf8), hello.sid, hello.ephX, hello.ephK,
                  ack.ctX, ack.ctK, ack.ephX, ack.ephK, finish.ctX, finish.ctK] {
            t.appendField(f)
        }
        return KDF.sha512(t)
    }

    static func master(root: Data, ss1: Data, ss2: Data, transcript: Data) -> Data {
        KDF.derive(root + ss1 + ss2, salt: transcript, info: Data("priva/session/master".utf8), count: 64)
    }

    /// Three-trip handshake: the responder's SDP offer rides in the ack, sealed with a key from the pair root and ss1
    /// (encapsulated to the initiator's fresh ephemeral) over the hello and the ack. Only the friend holding the root
    /// can make or open it, and it stays forward secret once the ephemeral is gone. The session keys still need both
    /// encapsulations, and key confirmation after DTLS binds the fingerprints in both SDPs.
    static func earlyKey(root: Data, ss1: Data, initiator: String, responder: String, hello: Hello, ack: Ack) -> DualKey {
        var t = Data("PRIVA-EARLY-v1".utf8)
        for f in [Data(initiator.utf8), Data(responder.utf8), hello.sid, hello.ephX, hello.ephK, ack.ctX, ack.ctK, ack.ephX, ack.ephK] {
            t.appendField(f)
        }
        return DualKey(KDF.derive(root + ss1, salt: KDF.sha512(t), info: Data("priva/session/early-sdp".utf8), count: 64))
    }

    static func earlyAAD(sid: Data) -> Data { Data("PRIVA-SDP-early-v1".utf8) + sid }
    /// Candidates the responder finds after its ack, before the session keys exist (same early key, own label).
    static func earlyICEAAD(sid: Data) -> Data { Data("PRIVA-ICE-early-v1".utf8) + sid }

    /// Initiator side.
    struct Initiator: Sendable {
        let me: String, peer: String, root: Data
        let eph: KEMPrivatePair
        let hello: Hello

        init(me: String, peer: String, root: Data) throws {
            self.me = me
            self.peer = peer
            self.root = root
            eph = try KEMPrivatePair.generate()
            hello = Hello(sid: Bytes.random(16), ephX: eph.publicPair.xwingRaw, ephK: eph.publicPair.mlkemRaw)
        }

        func finish(with ack: Ack) throws -> (Finish, SessionKeys) {
            let (fin, keys, _) = try finishEarly(with: ack)
            return (fin, keys)
        }

        /// `finish`, plus the key that opens an SDP offer carried in the ack (three-trip handshake).
        func finishEarly(with ack: Ack) throws -> (Finish, SessionKeys, DualKey) {
            guard ack.sid == hello.sid else { throw CryptoFailure.authentication }
            let ss1 = try DualKEM.decapsulate(ctX: ack.ctX, ctK: ack.ctK, with: eph)
            let peerEph = try KEMPublicPair(xwingRaw: ack.ephX, mlkemRaw: ack.ephK)
            let (ctX, ctK, ss2) = try DualKEM.encapsulate(to: peerEph)
            let fin = Finish(sid: hello.sid, ctX: ctX, ctK: ctK)
            let th = transcript(initiator: me, responder: peer, hello: hello, ack: ack, finish: fin)
            let keys = SessionKeys(sid: hello.sid, isInitiator: true,
                                   master: master(root: root, ss1: ss1, ss2: ss2, transcript: th), transcript: th)
            return (fin, keys, earlyKey(root: root, ss1: ss1, initiator: me, responder: peer, hello: hello, ack: ack))
        }
    }

    /// Responder side.
    struct Responder: Sendable {
        let me: String, peer: String, root: Data
        let eph: KEMPrivatePair
        let hello: Hello
        let ack: Ack
        private let ss1: Data

        init(me: String, peer: String, root: Data, hello: Hello) throws {
            self.me = me
            self.peer = peer
            self.root = root
            self.hello = hello
            eph = try KEMPrivatePair.generate()
            let peerEph = try KEMPublicPair(xwingRaw: hello.ephX, mlkemRaw: hello.ephK)
            let (ctX, ctK, ss) = try DualKEM.encapsulate(to: peerEph)
            ss1 = ss
            ack = Ack(sid: hello.sid, ctX: ctX, ctK: ctK, ephX: eph.publicPair.xwingRaw, ephK: eph.publicPair.mlkemRaw)
        }

        var earlyKey: DualKey { Handshake.earlyKey(root: root, ss1: ss1, initiator: peer, responder: me, hello: hello, ack: ack) }

        func complete(with fin: Finish) throws -> SessionKeys {
            guard fin.sid == hello.sid else { throw CryptoFailure.authentication }
            let ss2 = try DualKEM.decapsulate(ctX: fin.ctX, ctK: fin.ctK, with: eph)
            let th = transcript(initiator: peer, responder: me, hello: hello, ack: ack, finish: fin)
            return SessionKeys(sid: hello.sid, isInitiator: false,
                               master: master(root: root, ss1: ss1, ss2: ss2, transcript: th), transcript: th)
        }
    }
}

// MARK: - Data-channel frame cipher (strictly sequential counters ⇒ replay/reorder detection)

nonisolated final class FrameCipher: @unchecked Sendable {
    private let sendKey: DualKey
    private let receiveKey: DualKey
    private let label: Data
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0
    private let lock = NSLock()

    init(keys: (send: DualKey, receive: DualKey), channel: String) {
        sendKey = keys.send
        receiveKey = keys.receive
        label = Data("PRIVA-DC-v1/\(channel)".utf8)
    }

    private func aad(type: UInt8, counter: UInt64) -> Data {
        var a = label
        a.append(type)
        a.appendBE(counter)
        return a
    }

    /// frame = type(1) ‖ counter(8) ‖ DualAEAD(payload)
    func seal(type: UInt8, _ payload: Data) throws -> Data {
        lock.lock()
        let c = sendCounter
        sendCounter += 1
        lock.unlock()
        var frame = Data([type])
        frame.appendBE(c)
        frame.append(try DualAEAD.seal(payload, key: sendKey, nonce: DualAEAD.nonce(counter: c), aad: aad(type: type, counter: c)))
        return frame
    }

    func open(_ frame: Data) throws -> (type: UInt8, payload: Data) {
        var r = ByteReader(frame)
        let type = try r.readByte()
        let c = try r.readBE(UInt64.self)
        lock.lock()
        defer { lock.unlock() }
        guard c == receiveCounter else { throw CryptoFailure.authentication }
        let pt = try DualAEAD.open(r.readRest(), key: receiveKey, nonce: DualAEAD.nonce(counter: c), aad: aad(type: type, counter: c))
        receiveCounter += 1
        return (type, pt)
    }
}
