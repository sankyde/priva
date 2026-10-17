import AVFoundation
import Foundation
import LiveKitWebRTC

@MainActor
protocol PeerLinkDelegate: AnyObject {
    func linkSendSignal(_ link: PeerLink, _ signal: Signal)
    func linkDidBecomeReady(_ link: PeerLink)
    func linkDidClose(_ link: PeerLink, reason: PeerLink.CloseReason)
    func link(_ link: PeerLink, didReceive wire: Wire)
    func linkDidRatchet(_ link: PeerLink, base: Data, secret: Data)
    func linkRemoteVideoChanged(_ link: PeerLink)
    /// Whether a call with this peer is in progress right now: the only time an offer from it may start this
    /// iPhone's microphone or camera.
    func linkMayStartMedia(_ link: PeerLink) -> Bool
}

/// One end-to-end encrypted peer-to-peer session with a friend.
///
/// Layering: DTLS/SCTP (WebRTC) → FrameCipher (Dual-AEAD with PQ session keys) → Wire.
/// Media: SRTP (WebRTC) → frame encryption keyed from the same PQ session.
final class PeerLink: NSObject {
    enum Role { case initiator, responder }
    enum State: Equatable { case handshaking, connecting, ready, closed }
    enum CloseReason: Equatable { case normal, timeout, failed, remoteBye, superseded, authentication }

    let peer: String
    let me: String
    let role: Role
    let sid: Data
    let createdAt = Date()
    private(set) var state: State = .handshaking
    private(set) var keys: SessionKeys?
    private(set) var lastActivity = Date()
    private(set) var connectedAt: Date?
    weak var delegate: PeerLinkDelegate?

    let root: Data
    private let settings: PrivaSettings
    private var initiator: Handshake.Initiator?
    private var responder: Handshake.Responder?
    private var pc: LKRTCPeerConnection?
    private var control: LKRTCDataChannel?
    let bulk = BulkChannel()
    private var cipherC: FrameCipher?
    private var pendingRemoteICE: [LKRTCIceCandidate] = []
    private var outgoingICE: [ICECandidateDTO] = []
    private var iceFlushScheduled = false
    private var remoteConfirmed = false
    private var sentConfirm = false
    private var timeoutTask: Task<Void, Never>?
    private var queuedWire: [Wire] = []
    let intent: Signal.Intent
    /// Responder: the initiator can take the three-trip handshake (our SDP offer goes in the ack).
    private let peerTakesEarlyOffer: Bool
    private var earlyOfferSent = false
    /// Three-trip handshake: seals (responder) or opens (initiator) candidates sent before the session keys exist.
    private var earlyKey: DualKey?

    // media
    private var keyProvider: LKRTCFrameCryptorKeyProvider?
    private var cryptors: [LKRTCFrameCryptor] = []
    private var audioTrack: LKRTCAudioTrack?
    private var videoTrack: LKRTCVideoTrack?
    private var videoSource: LKRTCVideoSource?
    private var camera: LKRTCCameraVideoCapturer?
    #if targetEnvironment(simulator)
    private var synthetic: SyntheticCapturer?
    #endif
    private var usingFrontCamera = true
    private(set) var remoteVideoTrack: LKRTCVideoTrack?
    private(set) var mediaActive = false
    /// Set by the callee on "accept": local tracks are attached when the caller's media offer arrives.
    var acceptedMedia: Bool?
    /// Group call member: send a lighter 640×360 @ 20 fps stream (the host re-encodes it for everyone).
    var groupMedia = false
    private var makingOffer = false
    var polite: Bool { me > peer }

    deinit { LiveObjects.died("PeerLink") }

    init(me: String, peer: String, root: Data, settings: PrivaSettings, intent: Signal.Intent) throws {
        self.me = me
        self.peer = peer
        self.root = root
        self.settings = settings
        self.intent = intent
        role = .initiator
        peerTakesEarlyOffer = false
        let ini = try Handshake.Initiator(me: me, peer: peer, root: root)
        initiator = ini
        sid = ini.hello.sid
        super.init()
        LiveObjects.born("PeerLink")
    }

    init(me: String, peer: String, root: Data, settings: PrivaSettings, hello: Handshake.Hello, intent: Signal.Intent,
         early: Bool = false) throws {
        self.me = me
        self.peer = peer
        self.root = root
        self.settings = settings
        self.intent = intent
        role = .responder
        #if DEBUG
        peerTakesEarlyOffer = early && !Self.debugLegacyUsers.contains(me)
        #else
        peerTakesEarlyOffer = early
        #endif
        let res = try Handshake.Responder(me: me, peer: peer, root: root, hello: hello)
        responder = res
        sid = hello.sid
        super.init()
        LiveObjects.born("PeerLink")
    }

    // MARK: handshake

    func start() {
        armTimeout(10)
        // Created now, not when the keys arrive: its candidate pool gathers network addresses while the handshake
        // crosses the server, so the offer / answer can carry them without waiting.
        createPeerConnection()
        switch role {
        case .initiator:
            guard let h = initiator?.hello else { return }
            var early = true
            #if DEBUG
            if Self.debugLegacyUsers.contains(me) { early = false }
            #endif
            delegate?.linkSendSignal(self, .hello(sid: h.sid, ephX: h.ephX, ephK: h.ephK, intent: intent, ts: Signal.now,
                                                  early: early ? true : nil))
        case .responder:
            guard let res = responder else { return }
            if peerTakesEarlyOffer {
                Task { await self.sendAckWithOffer(res) }
            } else {
                let a = res.ack
                delegate?.linkSendSignal(self, .ack(sid: a.sid, ctX: a.ctX, ctK: a.ctK, ephX: a.ephX, ephK: a.ephK, ts: Signal.now))
            }
        }
    }

    private func armTimeout(_ seconds: Double) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.state != .ready, self.state != .closed else { return }
            self.close(.timeout)
        }
    }

    func handle(_ signal: Signal) {
        guard state != .closed, signal.sid == sid else { return }
        lastActivity = .now
        do {
            switch signal {
            case .ack(_, let ctX, let ctK, let ephX, let ephK, _, let earlyOffer):
                guard role == .initiator, keys == nil, let ini = initiator else { return }
                let (fin, k, earlyKey) = try ini.finishEarly(with: .init(sid: sid, ctX: ctX, ctK: ctK, ephX: ephX, ephK: ephK))
                keys = k
                initiator = nil
                try installKeys()
                if let earlyOffer {
                    // Three trips: answer the responder's offer and send our key share with it.
                    let plain = try DualAEAD.openRandom(earlyOffer, key: earlyKey, aad: Handshake.earlyAAD(sid: sid))
                    guard let offer = String(data: plain, encoding: .utf8) else { throw CryptoFailure.malformed }
                    self.earlyKey = earlyKey
                    Task {
                        await self.answer(remoteOffer: offer) { [sid] box in
                            .finish(sid: sid, ctX: fin.ctX, ctK: fin.ctK, sdp: box, ts: Signal.now)
                        }
                        for box in self.earlyICE { try? self.applyICE(box) }     // candidates that overtook the ack
                        self.earlyICE.removeAll()
                    }
                } else {
                    Task { await self.makeInitialOffer(finish: fin) }
                }
            case .offer(_, let ctX, let ctK, let sdpBox, _):
                guard role == .responder, keys == nil, let res = responder else { return }
                let k = try res.complete(with: .init(sid: sid, ctX: ctX, ctK: ctK))
                keys = k
                responder = nil
                try installKeys()
                let sdp = try openSDP(sdpBox)
                Task {
                    await self.answer(remoteOffer: sdp) { [sid] box in .answer(sid: sid, sdp: box, ts: Signal.now) }
                    for box in self.earlyICE { try? self.applyICE(box) }
                    self.earlyICE.removeAll()
                }
            case .finish(_, let ctX, let ctK, let sdpBox, _):
                guard role == .responder, keys == nil, earlyOfferSent, let res = responder else { return }
                keys = try res.complete(with: .init(sid: sid, ctX: ctX, ctK: ctK))
                responder = nil
                try installKeys()
                let sdp = try openSDP(sdpBox)
                Task {
                    try? await self.pc?.setRemoteDescription(LKRTCSessionDescription(type: .answer, sdp: sdp))
                    self.drainRemoteICE()
                    for box in self.earlyICE { try? self.applyICE(box) }
                    self.earlyICE.removeAll()
                    self.flushLocalICE()        // candidates found after the ack waited for the keys
                }
            case .answer(_, let sdpBox, _):
                guard role == .initiator, let pc else { return }
                let sdp = try openSDP(sdpBox)
                Task {
                    try? await pc.setRemoteDescription(LKRTCSessionDescription(type: .answer, sdp: sdp))
                    self.drainRemoteICE()
                }
            case .ice(_, let box, _):
                // REST deliveries can race: candidates may overtake the offer. Hold them until keys exist.
                guard keys != nil else { if earlyICE.count < 64 { earlyICE.append(box) }; return }
                try applyICE(box)
            case .bye:
                close(.remoteBye, notify: false)
            case .restart(_, let sdpBox, _):
                guard role == .responder, keys != nil, state == .ready, let pc else { return }
                let sdp = try openSDP(sdpBox)
                beginRestartWindow()
                Task {
                    do {
                        try await pc.setRemoteDescription(LKRTCSessionDescription(type: .offer, sdp: sdp))
                        self.drainRemoteICE()
                        let ans = try await pc.answer(for: WebRTCEnv.constraints)
                        try await pc.setLocalDescription(ans)
                        let full = await self.gatheredDescription(fallback: ans.sdp, maxWait: 0.5)
                        self.delegate?.linkSendSignal(self, .restarted(sid: self.sid, sdp: try self.sealBox(Data(full.utf8)), ts: Signal.now))
                        if self.pathWorks { self.restartSettled() }
                    } catch { self.close(.failed, notify: false) }
                }
            case .restarted(_, let sdpBox, _):
                guard role == .initiator, restartingSince != nil, let pc else { return }
                let sdp = try openSDP(sdpBox)
                Task {
                    try? await pc.setRemoteDescription(LKRTCSessionDescription(type: .answer, sdp: sdp))
                    self.drainRemoteICE()
                    if self.pathWorks { self.restartSettled() }
                }
            default: break
            }
        } catch {
            close(.authentication)
        }
    }

    // MARK: ICE restart (audit STA-24)

    private var pathWorks: Bool { pc.map { $0.iceConnectionState == .connected || $0.iceConnectionState == .completed } ?? false }

    /// A path again (ICE reports it, or it never stopped working).
    private func restartSettled() {
        guard restartingSince != nil else { return }
        restartingSince = nil
        restartOffers = 0
        #if DEBUG
        debugRestarts += 1
        #endif
    }

    /// How long a link that lost its path waits for a new one before giving up (then a fresh session, as before).
    static let restartGiveUp: TimeInterval = 25
    private(set) var restartingSince: Date?
    private var restartOffers = 0
    #if DEBUG
    /// Tests: ICE restarts this link completed.
    private(set) var debugRestarts = 0
    #endif

    /// The path died: Wi-Fi ↔ cellular, a new address, a NAT that forgot us. A link that isn't up yet closes as
    /// before; an established one keeps its session (keys, data channel, call) and looks for a new path: the initiator
    /// offers fresh ICE credentials over the rendezvous plane (the data channel rides the dead path) and the
    /// responder answers. Calls used to drop here ("Connection lost").
    private func pathLost() {
        guard state == .ready, keys != nil else { close(.failed, notify: false); return }
        beginRestartWindow()
        if role == .initiator { Task { await self.offerRestart() } }
    }

    private func beginRestartWindow() {
        guard restartingSince == nil else { return }
        let since = Date()
        restartingSince = since
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.restartGiveUp))
            guard let self, self.restartingSince == since else { return }
            if self.pathWorks { self.restartSettled() } else { self.close(.failed, notify: false) }
        }
    }

    private func offerRestart() async {
        guard let pc, state == .ready, restartingSince != nil else { return }
        restartOffers += 1
        pc.restartIce()
        do {
            let offer = try await pc.offer(for: WebRTCEnv.constraints)
            try await pc.setLocalDescription(offer)
            let sdp = await gatheredDescription(fallback: offer.sdp, maxWait: 0.5)
            guard restartingSince != nil else { return }
            delegate?.linkSendSignal(self, .restart(sid: sid, sdp: try sealBox(Data(sdp.utf8)), ts: Signal.now))
        } catch { close(.failed, notify: false); return }
        // No answer yet (on a new network the relay may still be reconnecting): offer again, a few times.
        let n = restartOffers
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, self.restartingSince != nil, self.restartOffers == n, n < 4 else { return }
            await self.offerRestart()
        }
    }

    #if DEBUG
    /// Tests: behave as if the path had just died (an ICE restart follows).
    func debugPathLost() { pathLost() }
    #endif

    private var earlyICE: [Data] = []

    private func applyICE(_ box: Data) throws {
        let plain: Data
        if let k = earlyKey, let p = try? DualAEAD.openRandom(box, key: k, aad: Handshake.earlyICEAAD(sid: sid)) {
            plain = p                   // a three-trip responder's candidates from before our answer reached it
        } else {
            plain = try openBox(box)
        }
        let list = try JSONDecoder().decode([ICECandidateDTO].self, from: plain)
        for c in list.prefix(64) { addRemote(LKRTCIceCandidate(sdp: c.sdp, sdpMLineIndex: c.mline, sdpMid: c.mid)) }
    }

    private func sealBox(_ d: Data) throws -> Data {
        guard let keys else { throw CryptoFailure.malformed }
        return try DualAEAD.sealRandom(d, key: keys.signalKeys.send, aad: Data("PRIVA-SDP-v1".utf8) + sid)
    }

    private func openBox(_ d: Data) throws -> Data {
        guard let keys else { throw CryptoFailure.malformed }
        return try DualAEAD.openRandom(d, key: keys.signalKeys.receive, aad: Data("PRIVA-SDP-v1".utf8) + sid)
    }

    private func openSDP(_ d: Data) throws -> String {
        guard let s = String(data: try openBox(d), encoding: .utf8) else { throw CryptoFailure.malformed }
        return s
    }

    private func createPeerConnection() {
        guard pc == nil, let pc = WebRTCEnv.factory.peerConnection(with: WebRTCEnv.configuration(settings),
                                                                    constraints: WebRTCEnv.constraints, delegate: self) else { return }
        self.pc = pc
        // Pre-negotiated channels: both sides create them with fixed ids → no DCEP round trip. Nothing can flow
        // on them before the keys are installed: they open only after an offer / answer, which needs the keys.
        let cfgC = LKRTCDataChannelConfiguration()
        cfgC.isNegotiated = true
        cfgC.channelId = 1
        cfgC.isOrdered = true
        let cfgF = LKRTCDataChannelConfiguration()
        cfgF.isNegotiated = true
        cfgF.channelId = 2
        cfgF.isOrdered = true
        control = pc.dataChannel(forLabel: "c", configuration: cfgC)
        control?.delegate = self
        bulkChannel = pc.dataChannel(forLabel: "f", configuration: cfgF)
    }

    private var bulkChannel: LKRTCDataChannel?

    private func installKeys() throws {
        guard let keys else { return }
        createPeerConnection()
        guard pc != nil else { throw CryptoFailure.keyGeneration }
        state = .connecting
        cipherC = FrameCipher(keys: keys.channelKeys("c"), channel: "c")
        if let f = bulkChannel {
            bulk.attach(channel: f, cipher: FrameCipher(keys: keys.channelKeys("f"), channel: "f"))
            bulk.onBroken = { [weak self] in DispatchQueue.main.async { MainActor.assumeIsolated { self?.close(.failed) } } }
            bulkChannel = nil
        }
        // Media keys are installed before any track exists: no frame ever leaves unencrypted.
        let kp = LKRTCFrameCryptorKeyProvider(ratchetSalt: keys.mediaSalt, ratchetWindowSize: 0, sharedKeyMode: false,
                                              uncryptedMagicBytes: nil, failureTolerance: -1, keyRingSize: 16,
                                              discardFrameWhenCryptorNotReady: true, keyDerivationAlgorithm: .HKDF)
        kp.setKey(keys.mediaKeys.send, with: 0, forParticipant: "tx")
        kp.setKey(keys.mediaKeys.receive, with: 0, forParticipant: "rx")
        keyProvider = kp
        #if DEBUG
        debugReceiveKey = keys.mediaKeys.receive
        #endif
        armTimeout(20)
    }

    /// Every sealed data-channel frame passes here on its way out (a no-op outside tests).
    nonisolated static func tapped(_ frame: Data) -> LKRTCDataBuffer {
        #if DEBUG
        WireTap.record("dc", frame)
        #endif
        return LKRTCDataBuffer(data: frame, isBinary: true)
    }

    #if DEBUG
    private var debugReceiveKey: Data?
    /// Tests only: decrypt incoming media with a wrong key, what a relay, TURN server or SFU without the
    /// end-to-end key would be left with. DTLS-SRTP keeps working; only the end-to-end layer is broken.
    func debugScrambleReceiveMediaKey() { keyProvider?.setKey(Bytes.random(32), with: 0, forParticipant: "rx") }
    func debugRestoreReceiveMediaKey() { if let k = debugReceiveKey { keyProvider?.setKey(k, with: 0, forParticipant: "rx") } }
    /// Tests only: media sections in the current local description (grows if transceivers are never recycled).
    var debugMediaSections: Int { (pc?.localDescription?.sdp.components(separatedBy: "\r\nm=").count ?? 1) - 1 }
    #endif

    private func makeInitialOffer(finish: Handshake.Finish) async {
        guard let pc else { return }
        do {
            let offer = try await pc.offer(for: WebRTCEnv.constraints)
            try await pc.setLocalDescription(offer)
            let sdp = await gatheredDescription(fallback: offer.sdp)
            let box = try sealBox(Data(sdp.utf8))
            delegate?.linkSendSignal(self, .offer(sid: sid, ctX: finish.ctX, ctK: finish.ctK, sdp: box, ts: Signal.now))
        } catch { close(.failed) }
    }

    /// `reply` wraps the sealed answer: `.answer` (four trips) or `.finish` with our key share (three trips).
    private func answer(remoteOffer sdp: String, reply: (Data) -> Signal) async {
        guard let pc else { return }
        do {
            try await pc.setRemoteDescription(LKRTCSessionDescription(type: .offer, sdp: sdp))
            drainRemoteICE()
            let ans = try await pc.answer(for: WebRTCEnv.constraints)
            try await pc.setLocalDescription(ans)
            let full = await gatheredDescription(fallback: ans.sdp)
            delegate?.linkSendSignal(self, reply(try sealBox(Data(full.utf8))))
        } catch { close(.failed) }
    }

    /// Three-trip handshake, responder: our SDP offer goes in the ack, sealed with the early key (the session keys
    /// need the initiator's key share, which comes back with its answer). Saves one trip through the server.
    private func sendAckWithOffer(_ res: Handshake.Responder) async {
        guard let pc else { close(.failed); return }
        do {
            let offer = try await pc.offer(for: WebRTCEnv.constraints)
            try await pc.setLocalDescription(offer)
            // Don't hold the ack for the server-reflexive candidate (this connection only just started gathering):
            // anything found later follows under the early key while the initiator prepares its answer.
            let sdp = await gatheredDescription(fallback: offer.sdp, maxWait: 0.03)
            let box = try DualAEAD.sealRandom(Data(sdp.utf8), key: res.earlyKey, aad: Handshake.earlyAAD(sid: sid))
            guard state != .closed else { return }
            earlyOfferSent = true
            earlyKey = res.earlyKey
            let a = res.ack
            delegate?.linkSendSignal(self, .ack(sid: a.sid, ctX: a.ctX, ctK: a.ctK, ephX: a.ephX, ephK: a.ephK, ts: Signal.now, sdp: box))
        } catch { close(.failed) }
    }

    #if DEBUG
    /// Tests only: these users behave like a build without the three-trip handshake (mixed-version compatibility).
    nonisolated(unsafe) static var debugLegacyUsers: Set<String> = []
    #endif

    /// The first candidates travel inside the offer / answer instead of as separate rendezvous messages (each one
    /// counts against the server's quota). The candidate pool has usually gathered them while the handshake crossed
    /// the server; a connection younger than half a second gets up to 200 ms for its server-reflexive candidate (the
    /// usual reachable address). Anything gathered later still trickles.
    private func gatheredDescription(fallback: String, maxWait: TimeInterval = 0.2) async -> String {
        let deadline = min(Date().addingTimeInterval(maxWait), max(Date().addingTimeInterval(min(0.03, maxWait)), createdAt.addingTimeInterval(0.5)))
        while let pc, pc.iceGatheringState != .complete, Date() < deadline,
              !(pc.localDescription?.sdp.contains(" typ srflx") ?? false) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let sdp = pc?.localDescription?.sdp ?? fallback
        sentDescription = sdp
        sentCandidates = Set(sdp.split(whereSeparator: \.isNewline).compactMap { SDPUtil.candidateKey($0) })
        outgoingICE.removeAll()          // already inside the description
        return sdp
    }

    /// Local candidates are held until our description (which carries them) goes out; later ones trickle.
    private var sentDescription: String?
    /// Candidates already inside it. WebRTC re-announces pooled candidates after the description is set, with
    /// slightly different trailing attributes: compared by the fields that identify a candidate.
    private var sentCandidates: Set<String> = []

    private func addRemote(_ c: LKRTCIceCandidate) {
        guard let pc else { return }
        if pc.remoteDescription == nil { pendingRemoteICE.append(c); return }
        pc.add(c) { _ in }
    }

    private func drainRemoteICE() {
        guard let pc, pc.remoteDescription != nil else { return }
        for c in pendingRemoteICE { pc.add(c) { _ in } }
        pendingRemoteICE.removeAll()
    }

    private func queueLocalICE(_ dto: ICECandidateDTO) {
        if state == .ready { send(.ice(dto)); return }
        if let key = SDPUtil.candidateKey(dto.sdp[...]), sentCandidates.contains(key) { return }   // already in our description
        outgoingICE.append(dto)
        flushLocalICE()
    }

    /// Candidates found after our description went out trickle in small batches: once there are keys to seal them
    /// (a three-trip responder has none until the initiator's answer arrives).
    private func flushLocalICE() {
        guard sentDescription != nil, keys != nil || (role == .responder && earlyKey != nil), !outgoingICE.isEmpty,
              !iceFlushScheduled else { return }
        iceFlushScheduled = true
        // Before the session keys (a three-trip responder waiting for the answer) nothing can use them sooner than
        // the answer's trip back: gather for longer so they go out as one signal.
        let wait = keys == nil ? 200 : 80
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(wait))
            guard let self else { return }
            self.iceFlushScheduled = false
            // A path already works: the late ones (usually the relay's, slower to gather) wait for the data channel
            // instead of costing more rendezvous signals; checkReady sends them.
            if let st = self.pc?.iceConnectionState, st == .connected || st == .completed { return }
            let batch = self.outgoingICE
            self.outgoingICE.removeAll()
            guard !batch.isEmpty, let data = try? JSONEncoder().encode(batch) else { return }
            let box: Data?
            if self.keys != nil {
                box = try? self.sealBox(data)
            } else if let k = self.earlyKey {
                box = try? DualAEAD.sealRandom(data, key: k, aad: Handshake.earlyICEAAD(sid: self.sid))
            } else {
                box = nil
            }
            guard let box else { return }
            self.delegate?.linkSendSignal(self, .ice(sid: self.sid, candidates: box, ts: Signal.now))
        }
    }

    // MARK: key confirmation

    private func sendConfirm() {
        guard !sentConfirm, let keys, let pc, let local = pc.localDescription.flatMap({ SDPUtil.fingerprint($0.sdp) }),
              let remote = pc.remoteDescription.flatMap({ SDPUtil.fingerprint($0.sdp) }) else { return }
        let ini = role == .initiator
        let tag = keys.confirmation(fromInitiator: ini, initiatorFingerprint: ini ? local : remote,
                                    responderFingerprint: ini ? remote : local)
        guard let frame = try? cipherC?.seal(type: FrameType.confirm, tag), let control else { return }
        sentConfirm = control.sendData(Self.tapped(frame))
        checkReady()
    }

    private func verifyConfirm(_ tag: Data) {
        guard let keys, let pc, let local = pc.localDescription.flatMap({ SDPUtil.fingerprint($0.sdp) }),
              let remote = pc.remoteDescription.flatMap({ SDPUtil.fingerprint($0.sdp) }) else { return }
        let ini = role == .initiator
        // The peer computed its tag with the opposite role and its own view of the fingerprints.
        let expected = keys.confirmation(fromInitiator: !ini, initiatorFingerprint: ini ? local : remote,
                                         responderFingerprint: ini ? remote : local)
        guard Bytes.equal(expected, tag) else { close(.authentication); return }
        remoteConfirmed = true
        checkReady()
    }

    private func checkReady() {
        guard sentConfirm, remoteConfirmed, state == .connecting, let keys else { return }
        state = .ready
        connectedAt = .now
        timeoutTask?.cancel()
        delegate?.linkDidRatchet(self, base: root, secret: keys.ratchetSecret)
        delegate?.linkDidBecomeReady(self)
        for w in queuedWire { send(w) }
        queuedWire.removeAll()
        for c in outgoingICE { send(.ice(c)) }      // held back while the connection was being confirmed
        outgoingICE.removeAll()
        Task { _ = await self.stats() }      // seeds the byte counters, so the first call-quality sample has a rate
    }

    // MARK: messaging

    var isReady: Bool { state == .ready }

    @discardableResult
    func send(_ wire: Wire) -> Bool {
        guard state != .closed else { return false }
        guard state == .ready, control != nil, cipherC != nil else { queuedWire.append(wire); return true }
        guard let payload = try? JSONEncoder().encode(wire) else { return false }
        return sendPayload(payload)
    }

    private func sendPayload(_ payload: Data) -> Bool {
        guard state == .ready, let cipherC else { return false }
        lastActivity = .now
        if payload.count <= Self.fragmentSize {
            guard let frame = try? cipherC.seal(type: FrameType.control, payload) else { return false }
            return transmit(frame)
        }
        // Large messages go as sealed fragments (each well under WebRTC's 256 KiB message limit).
        guard payload.count <= Self.maxAssembled else { return false }
        nextFragmentID &+= 1
        let parts = stride(from: 0, to: payload.count, by: Self.fragmentSize).map { payload[$0..<min($0 + Self.fragmentSize, payload.count)] }
        for (i, part) in parts.enumerated() {
            var body = Data()
            body.appendBE(nextFragmentID)
            body.appendBE(UInt16(i))
            body.appendBE(UInt16(parts.count))
            body.append(part)
            guard let frame = try? cipherC.seal(type: FrameType.fragment, body), transmit(frame) else { return false }
        }
        return true
    }

    /// A sealed frame used up its counter: if the channel refuses it, the peer would reject every later frame
    /// as out of order. End the session cleanly instead (the engine reconnects with fresh keys; nothing is lost:
    /// unacknowledged messages stay queued).
    private func transmit(_ frame: Data) -> Bool {
        guard let control, control.sendData(Self.tapped(frame)) else {
            close(.failed, notify: false)
            return false
        }
        return true
    }

    static let fragmentSize = 48 * 1024
    static let maxAssembled = 8 * 1024 * 1024
    private var nextFragmentID: UInt32 = 0
    private var partial: [UInt32: (parts: [Int: Data], total: Int, bytes: Int, started: Date)] = [:]

    /// Reassembles a fragmented control message; nil until complete. Bounded: ≤ 8 MiB, ≤ 4 in flight, 30 s.
    private func assemble(_ body: Data) -> Data? {
        guard body.count > 8 else { return nil }
        let b = [UInt8](body.prefix(8))
        let id = UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
        let index = Int(UInt16(b[4]) << 8 | UInt16(b[5])), total = Int(UInt16(b[6]) << 8 | UInt16(b[7]))
        let chunk = body.dropFirst(8)
        guard total >= 2, total <= Self.maxAssembled / Self.fragmentSize + 1, index < total, chunk.count <= Self.fragmentSize else { return nil }
        partial = partial.filter { Date().timeIntervalSince($0.value.started) < 30 }
        if partial[id] == nil {
            guard partial.count < 4 else { return nil }
            partial[id] = ([:], total, 0, .now)
        }
        guard var p = partial[id], p.total == total, p.parts[index] == nil, p.bytes + chunk.count <= Self.maxAssembled else {
            partial[id] = nil
            return nil
        }
        p.parts[index] = Data(chunk)
        p.bytes += chunk.count
        guard p.parts.count == total else { partial[id] = p; return nil }
        partial[id] = nil
        return (0..<total).reduce(into: Data()) { $0.append(p.parts[$1]!) }
    }

    private func receiveControl(_ data: Data) {
        guard let cipherC else { return }
        do {
            var (type, payload) = try cipherC.open(data)
            lastActivity = .now
            if type == FrameType.fragment {
                guard let whole = assemble(payload) else { return }
                (type, payload) = (FrameType.control, whole)
            }
            switch type {
            case FrameType.confirm: verifyConfirm(payload)
            case FrameType.control:
                // Authentic but not understood (a newer app's message type): skip it, keep the session.
                guard let wire = try? JSONDecoder().decode(Wire.self, from: payload) else {
                    unknownMessages += 1
                    return
                }
                if case .sdp(let type, let sdp) = wire { Task { await self.handleRenegotiation(type: type, sdp: sdp) }; return }
                if case .ice(let dto) = wire { addRemote(LKRTCIceCandidate(sdp: dto.sdp, sdpMLineIndex: dto.mline, sdpMid: dto.mid)); return }
                if case .ping(let t) = wire { send(.pong(t)); return }
                if case .bye = wire { close(.remoteBye, notify: false); return }
                delegate?.link(self, didReceive: wire)
            default: break
            }
        } catch {
            close(.authentication)
        }
    }

    #if DEBUG
    /// Tests only: send an arbitrary authenticated control payload (large ones are fragmented like real messages).
    func sendRaw(_ payload: Data) { _ = sendPayload(payload) }
    #endif

    /// Authenticated control messages this version couldn't decode (forward compatibility).
    private(set) var unknownMessages = 0

    // MARK: media (voice / video)

    func startMedia(video: Bool, shared: GroupLocalMedia? = nil) {
        guard let pc, let keyProvider else { return }
        if let shared {
            // Group host: one camera + mic feeds every member link; lower caps since the uplink is shared.
            attach(track: shared.audio, kind: .audio, pc: pc, keyProvider: keyProvider)
            if let v = shared.video { attach(track: v, kind: .video, pc: pc, keyProvider: keyProvider, maxBitrate: 900_000, maxFps: 20) }
            _ = pc.setBweMinBitrateBps(NSNumber(value: 100_000), currentBitrateBps: NSNumber(value: video ? 900_000 : 64_000),
                                       maxBitrateBps: NSNumber(value: 3_000_000))
            mediaActive = true
            return
        }
        WebRTCEnv.configureAudioSession(video: video, owner: self)
        if audioTrack == nil {
            let src = WebRTCEnv.factory.audioSource(with: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: [
                "googEchoCancellation": "true", "googNoiseSuppression": "true", "googAutoGainControl": "true", "googHighpassFilter": "true",
            ]))
            audioTrack = WebRTCEnv.factory.audioTrack(with: src, trackId: "a-\(sid.prefix(4).hex)")
        }
        attach(track: audioTrack!, kind: .audio, pc: pc, keyProvider: keyProvider)
        if video { startVideo(pc: pc, keyProvider: keyProvider) }
        if groupMedia {
            _ = pc.setBweMinBitrateBps(NSNumber(value: 100_000), currentBitrateBps: NSNumber(value: video ? 800_000 : 64_000),
                                       maxBitrateBps: NSNumber(value: 1_500_000))
            mediaActive = true
            return
        }
        // Start the bandwidth estimator high instead of ramping up from ~300 kbps: sharp video within a second.
        _ = pc.setBweMinBitrateBps(NSNumber(value: 150_000), currentBitrateBps: NSNumber(value: video ? 1_800_000 : 64_000),
                                   maxBitrateBps: NSNumber(value: settings.videoQuality >= 1080 ? 4_500_000 : 3_000_000))
        mediaActive = true
    }

    private func startVideo(pc: LKRTCPeerConnection, keyProvider: LKRTCFrameCryptorKeyProvider) {
        if videoTrack == nil {
            let source = WebRTCEnv.factory.videoSource()
            videoSource = source
            videoTrack = WebRTCEnv.factory.videoTrack(with: source, trackId: "v-\(sid.prefix(4).hex)")
        }
        guard let videoTrack, let videoSource else { return }
        attach(track: videoTrack, kind: .video, pc: pc, keyProvider: keyProvider,
               maxBitrate: groupMedia ? 900_000 : nil, maxFps: groupMedia ? 20 : 30)
        startCapture(source: videoSource)
    }

    private func startCapture(source: LKRTCVideoSource) {
        let res = groupMedia ? (640, 360) : settings.videoQuality >= 1080 ? (1920, 1080) : settings.videoQuality <= 540 ? (960, 540) : (1280, 720)
        #if targetEnvironment(simulator)
        let s = SyntheticCapturer(delegate: source, width: res.0, height: res.1, label: me)
        synthetic = s
        s.start(fps: groupMedia ? 20 : 30)
        #else
        let cam = LKRTCCameraVideoCapturer(delegate: source)
        camera = cam
        startCamera(cam, width: res.0, height: res.1)
        #endif
    }

    private func startCamera(_ cam: LKRTCCameraVideoCapturer, width: Int, height: Int) {
        let position: AVCaptureDevice.Position = usingFrontCamera ? .front : .back
        guard let device = LKRTCCameraVideoCapturer.captureDevices().first(where: { $0.position == position })
                ?? LKRTCCameraVideoCapturer.captureDevices().first else { return }
        let formats = LKRTCCameraVideoCapturer.supportedFormats(for: device)
        let best = formats.min { a, b in
            let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription), db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            return abs(Int(da.width) - width) + abs(Int(da.height) - height) < abs(Int(db.width) - width) + abs(Int(db.height) - height)
        }
        guard let best else { return }
        let fps = min(30, Int(best.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30))
        cam.startCapture(with: device, format: best, fps: fps)
    }

    func flipCamera() {
        usingFrontCamera.toggle()
        #if !targetEnvironment(simulator)
        if let camera { camera.stopCapture { }; startCamera(camera, width: 1280, height: 720) }
        #endif
    }

    func setMuted(_ muted: Bool) { audioTrack?.isEnabled = !muted }

    func setVideoEnabled(_ on: Bool) {
        videoTrack?.isEnabled = on
        #if targetEnvironment(simulator)
        if on { synthetic?.start() } else { synthetic?.stop() }
        #endif
    }

    var localVideoTrack: LKRTCVideoTrack? { videoTrack }

    private func attach(track: LKRTCMediaStreamTrack, kind: LKRTCRtpMediaType, pc: LKRTCPeerConnection, keyProvider: LKRTCFrameCryptorKeyProvider,
                        maxBitrate: Int? = nil, maxFps: Int = 30) {
        let transceiver: LKRTCRtpTransceiver
        // Own camera/mic go only on our own transceivers ("s" stream), never on a forwarded one.
        if let existing = pc.transceivers.first(where: { t in
            t.mediaType == kind && !t.isStopped && (t.sender.streamIds.contains("s") || ownMids.contains(t.mid))
        }) {
            existing.sender.track = track
            var err: NSError?
            existing.setDirection(.sendRecv, error: &err)
            transceiver = existing
        } else {
            let initParams = LKRTCRtpTransceiverInit()
            initParams.direction = .sendRecv
            initParams.streamIds = ["s"]
            if kind == .video {
                let enc = LKRTCRtpEncodingParameters()
                enc.maxBitrateBps = NSNumber(value: maxBitrate ?? (settings.videoQuality >= 1080 ? 4_000_000 : 2_500_000))
                enc.maxFramerate = NSNumber(value: maxFps)
                enc.networkPriority = .high
                initParams.sendEncodings = [enc]
            }
            guard let t = pc.addTransceiver(with: track, init: initParams) else { return }
            transceiver = t
        }
        if kind == .video {
            let params = transceiver.sender.parameters
            params.degradationPreference = NSNumber(value: LKRTCDegradationPreference.balanced.rawValue)
            transceiver.sender.parameters = params
        }
        installCryptors(on: transceiver, keyProvider: keyProvider, pc: pc)
    }

    private func installCryptors(on t: LKRTCRtpTransceiver, keyProvider: LKRTCFrameCryptorKeyProvider, pc: LKRTCPeerConnection) {
        // pc.transceivers hands out fresh ObjC wrappers on every call, so key on the native ids: installing a
        // second cryptor would replace the live frame transformer mid-stream (dropped/undecryptable frames).
        let senderID = "s:" + t.sender.senderId, receiverID = "r:" + t.receiver.receiverId
        if !installedCryptors.contains(senderID),
           let enc = LKRTCFrameCryptor(factory: WebRTCEnv.factory, rtpSender: t.sender, participantId: "tx", algorithm: .aesGcm, keyProvider: keyProvider) {
            enc.enabled = true
            enc.keyIndex = 0
            enc.delegate = self
            cryptors.append(enc)
            installedCryptors.insert(senderID)
        }
        if !installedCryptors.contains(receiverID),
           let dec = LKRTCFrameCryptor(factory: WebRTCEnv.factory, rtpReceiver: t.receiver, participantId: "rx", algorithm: .aesGcm, keyProvider: keyProvider) {
            dec.enabled = true
            dec.keyIndex = 0
            dec.delegate = self
            cryptors.append(dec)
            installedCryptors.insert(receiverID)
        }
    }

    private var installedCryptors: Set<String> = []
    private(set) var cryptorFailures = 0

    /// Caller side: after the callee accepted, offer media over the encrypted data channel.
    func negotiateMedia() async {
        guard let pc else { return }
        // One offer at a time: if a negotiation is in flight, run again once its answer lands.
        if makingOffer || pc.signalingState != .stable { negotiationPending = true; return }
        makingOffer = true
        defer { makingOffer = false }
        do {
            let offer = try await pc.offer(for: WebRTCEnv.constraints)
            let tuned = LKRTCSessionDescription(type: .offer, sdp: SDPUtil.tuneOpus(offer.sdp))
            try await pc.setLocalDescription(tuned)
            send(.sdp(type: "offer", sdp: tuned.sdp))
        } catch { }
    }

    private func handleRenegotiation(type: String, sdp: String) async {
        guard let pc, let keyProvider else { return }
        do {
            if type == "offer" {
                if makingOffer || pc.signalingState != .stable {
                    guard polite else { return } // impolite peer ignores the colliding offer
                }
                try await pc.setRemoteDescription(LKRTCSessionDescription(type: .offer, sdp: sdp))
                parseRemoteStreams(sdp)
                // Consent (acceptedMedia) only counts while the matching call is up: a peer can't use a consent left
                // behind by an ended or unanswered call to switch the mic or camera on later (audit SEC-01).
                if let video = acceptedMedia, !mediaActive {
                    if delegate?.linkMayStartMedia(self) == true { startMedia(video: video) } else { acceptedMedia = nil }
                }
                for t in pc.transceivers where !t.isStopped { installCryptors(on: t, keyProvider: keyProvider, pc: pc) }
                updateRemoteVideo()
                let ans = try await pc.answer(for: WebRTCEnv.constraints)
                let tuned = LKRTCSessionDescription(type: .answer, sdp: SDPUtil.tuneOpus(ans.sdp))
                try await pc.setLocalDescription(tuned)
                send(.sdp(type: "answer", sdp: tuned.sdp))
                // Transceiver directions only become current once our answer is applied.
                updateRemoteVideo()
            } else {
                try await pc.setRemoteDescription(LKRTCSessionDescription(type: .answer, sdp: sdp))
                parseRemoteStreams(sdp)
                updateRemoteVideo()
                if negotiationPending {
                    negotiationPending = false
                    Task { await self.negotiateMedia() }
                }
            }
        } catch { }
    }

    // MARK: group media (host = processor, GROUPS_DESIGN §7)

    private var negotiationPending = false
    /// mid → stream id announced by the remote side (host uses "s" for its own media, a username for forwarded media).
    private(set) var remoteStreams: [String: String] = [:]
    private var ownMids: Set<String> { Set(remoteStreams.filter { $0.value == "s" }.keys) }
    private var forwarded: [String: [LKRTCRtpTransceiver]] = [:]

    private func parseRemoteStreams(_ sdp: String) {
        var map: [String: String] = [:]
        for section in sdp.components(separatedBy: "\r\nm=").dropFirst() {
            var mid: String?, stream: String?
            for line in section.components(separatedBy: "\r\n") {
                if line.hasPrefix("a=mid:") { mid = String(line.dropFirst(6)) }
                if line.hasPrefix("a=msid:") { stream = line.dropFirst(7).split(separator: " ").first.map(String.init) }
            }
            if let mid { map[mid] = stream ?? "-" }
        }
        remoteStreams = map
    }

    /// Tracks this peer is currently sending us, with the participant they belong to.
    /// Stream labels are only trusted from a group host; everything else is attributed to `peer`.
    func receivedTracks(trustLabels: Bool) -> [(participant: String, track: LKRTCMediaStreamTrack)] {
        guard let pc else { return [] }
        return pc.transceivers.compactMap { t in
            guard !t.isStopped, let track = t.receiver.track else { return nil }
            var dir = LKRTCRtpTransceiverDirection.inactive
            guard t.currentDirection(&dir), dir == .sendRecv || dir == .recvOnly else { return nil }
            let label = remoteStreams[t.mid] ?? "-"
            let who = trustLabels && label != "s" && label != "-" && Username.isValid(label) ? label : peer
            return (who, track)
        }
    }

    /// Host: send another participant's (decrypted, re-encoded) track to this member.
    /// Returns true when a new transceiver was added (the caller must renegotiate).
    @discardableResult
    func forward(_ track: LKRTCMediaStreamTrack, from participant: String) -> Bool {
        guard let pc, let keyProvider else { return false }
        if forwarded[participant]?.contains(where: { $0.sender.track?.trackId == track.trackId }) == true { return false }
        let initParams = LKRTCRtpTransceiverInit()
        initParams.direction = .sendOnly
        initParams.streamIds = [participant]
        if track.kind == "video" {
            let enc = LKRTCRtpEncodingParameters()
            enc.maxBitrateBps = 700_000
            enc.maxFramerate = 20
            initParams.sendEncodings = [enc]
        }
        guard let t = pc.addTransceiver(with: track, init: initParams) else { return false }
        installCryptors(on: t, keyProvider: keyProvider, pc: pc)
        forwarded[participant, default: []].append(t)
        return true
    }

    /// A forwarded participant left: stop (not just pause) their transceivers so a long-lived link doesn't gain
    /// two m-lines per participant per group call: the renegotiation lets WebRTC recycle them.
    func removeForwards(from participant: String) {
        for t in forwarded[participant] ?? [] {
            t.sender.track = nil
            t.stopInternal()
        }
        forwarded[participant] = nil
    }

    private func updateRemoteVideo() {
        let own = pc?.transceivers.first(where: { $0.mediaType == .video && !$0.isStopped && (remoteStreams[$0.mid].map { $0 == "s" || $0 == "-" } ?? true) })
        remoteVideoTrack = own?.receiver.track as? LKRTCVideoTrack
        delegate?.linkRemoteVideoChanged(self)
    }

    /// `keepAudioSession`: a group host dropping one member keeps the call's audio session running. Otherwise this
    /// link gives back its claim on the (process-wide) audio session; it switches off only when no call needs it.
    func stopMedia(keepAudioSession: Bool = false) {
        #if targetEnvironment(simulator)
        synthetic?.stop()
        synthetic = nil
        #endif
        camera?.stopCapture { }
        camera = nil
        if let pc {
            let forwardedIDs = Set(forwarded.values.flatMap { $0 }.map(\.sender.senderId))
            for t in pc.transceivers where (t.mediaType == .audio || t.mediaType == .video) && !t.isStopped {
                t.sender.track = nil
                if forwardedIDs.contains(t.sender.senderId) {
                    t.stopInternal()            // a relayed participant's stream: done for good (see removeForwards)
                } else {
                    var err: NSError?
                    t.setDirection(.inactive, error: &err)      // our own: reused by the next call
                }
            }
        }
        audioTrack?.isEnabled = false
        audioTrack = nil
        videoTrack = nil
        videoSource = nil
        mediaActive = false
        acceptedMedia = nil
        groupMedia = false
        remoteVideoTrack = nil
        forwarded.removeAll()
        if !keepAudioSession { WebRTCEnv.releaseAudioSession(owner: self) }
    }

    // MARK: stats

    struct Stats: Sendable {
        var rttMs: Double?
        var candidate: String = "-"
        var outKbps: Double = 0
        var inKbps: Double = 0
        var fps: Double?
        var width: Int?
        var height: Int?
        var packetsLost: Int = 0
        var jitterMs: Double?
        var framesDecoded: Int = 0
        var framesDropped: Int = 0
        var audioLevel: Double?
        var audioPacketsReceived: Int = 0
    }

    private var lastBytes: (sent: Double, recv: Double, at: Double)?

    func stats() async -> Stats {
        guard let pc else { return Stats() }
        let report = await pc.statistics()
        var s = Stats()
        var sent = 0.0, recv = 0.0
        var local: [String: String] = [:]
        var selectedLocal: String?
        for (_, st) in report.statistics {
            let v = st.values
            switch st.type {
            case "candidate-pair":
                if (v["state"] as? String) == "succeeded", (v["nominated"] as? NSNumber)?.boolValue == true {
                    if let r = v["currentRoundTripTime"] as? NSNumber { s.rttMs = r.doubleValue * 1000 }
                    selectedLocal = v["localCandidateId"] as? String
                }
            case "local-candidate":
                local[st.id] = v["candidateType"] as? String
            case "transport":
                sent += (v["bytesSent"] as? NSNumber)?.doubleValue ?? 0
                recv += (v["bytesReceived"] as? NSNumber)?.doubleValue ?? 0
            case "inbound-rtp":
                if (v["kind"] as? String) == "video" {
                    s.fps = (v["framesPerSecond"] as? NSNumber)?.doubleValue
                    s.width = (v["frameWidth"] as? NSNumber)?.intValue
                    s.height = (v["frameHeight"] as? NSNumber)?.intValue
                    s.framesDecoded = (v["framesDecoded"] as? NSNumber)?.intValue ?? 0
                    s.framesDropped = (v["framesDropped"] as? NSNumber)?.intValue ?? 0
                }
                if (v["kind"] as? String) == "audio" {
                    s.jitterMs = ((v["jitter"] as? NSNumber)?.doubleValue).map { $0 * 1000 }
                    s.audioLevel = (v["audioLevel"] as? NSNumber)?.doubleValue
                    s.audioPacketsReceived = (v["packetsReceived"] as? NSNumber)?.intValue ?? 0
                }
                s.packetsLost += (v["packetsLost"] as? NSNumber)?.intValue ?? 0
            default: break
            }
        }
        if let id = selectedLocal, let type = local[id] { s.candidate = type }
        let now = report.timestamp_us / 1_000_000
        if let last = lastBytes, now > last.at {
            s.outKbps = (sent - last.sent) * 8 / 1000 / (now - last.at)
            s.inKbps = (recv - last.recv) * 8 / 1000 / (now - last.at)
        }
        lastBytes = (sent, recv, now)
        return s
    }

    #if DEBUG
    /// Tests: per-stream receive counters (group-call verification), one entry per inbound RTP stream.
    struct InboundStream: Sendable {
        let kind: String
        let mid: String?
        let packets: Int
        let framesDecoded: Int
        let fps: Double
        let width: Int
    }

    func inboundStreams() async -> [InboundStream] {
        guard let pc else { return [] }
        let report = await pc.statistics()
        return report.statistics.values.compactMap { st in
            guard st.type == "inbound-rtp" else { return nil }
            let v = st.values
            return InboundStream(kind: v["kind"] as? String ?? "?", mid: v["mid"] as? String,
                                 packets: (v["packetsReceived"] as? NSNumber)?.intValue ?? 0,
                                 framesDecoded: (v["framesDecoded"] as? NSNumber)?.intValue ?? 0,
                                 fps: (v["framesPerSecond"] as? NSNumber)?.doubleValue ?? 0,
                                 width: (v["frameWidth"] as? NSNumber)?.intValue ?? 0)
        }
    }
    #endif

    // MARK: teardown

    func close(_ reason: CloseReason = .normal, notify: Bool = true) {
        guard state != .closed else { return }
        if notify, reason == .normal || reason == .superseded {
            if state == .ready { send(.bye) } else if keys != nil || role == .initiator {
                delegate?.linkSendSignal(self, .bye(sid: sid, ts: Signal.now))
            }
        }
        state = .closed
        timeoutTask?.cancel()
        stopMedia()
        for c in cryptors { c.enabled = false }
        cryptors.removeAll()
        bulk.close()
        control?.delegate = nil
        control?.close()
        bulkChannel = nil
        pc?.close()
        pc = nil
        delegate?.linkDidClose(self, reason: reason)
    }
}

// MARK: - WebRTC delegates (called on WebRTC's signalling thread → hop to main in order)

extension PeerLink: LKRTCPeerConnectionDelegate, LKRTCDataChannelDelegate, LKRTCFrameCryptorDelegate {
    private nonisolated func main(_ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated(body) }
    }

    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {}

    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
        main { [weak self] in
            guard let self else { return }
            switch newState {
            case .failed: self.pathLost()
            case .disconnected:
                // A few seconds to recover by itself (a blip); then an ICE restart keeps the session and the call.
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    guard let self, let pc = self.pc, pc.iceConnectionState == .disconnected else { return }
                    self.pathLost()
                }
            case .connected, .completed:
                self.restartSettled()
            default: break
            }
        }
    }

    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {
        let dto = ICECandidateDTO(sdp: candidate.sdp, mline: candidate.sdpMLineIndex, mid: candidate.sdpMid)
        main { [weak self] in self?.queueLocalICE(dto) }
    }

    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didStartReceivingOn transceiver: LKRTCRtpTransceiver) {
        main { [weak self] in self?.updateRemoteVideo() }
    }

    nonisolated func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        let open = dataChannel.readyState == .open
        let closed = dataChannel.readyState == .closed
        main { [weak self] in
            guard let self else { return }
            if open { self.sendConfirm() }
            if closed, self.state == .ready { self.close(.failed, notify: false) }
        }
    }

    nonisolated func dataChannel(_ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        let data = buffer.data
        main { [weak self] in self?.receiveControl(data) }
    }

    nonisolated func frameCryptor(_ frameCryptor: LKRTCFrameCryptor, didStateChangeWithParticipantId participantId: String,
                                  with stateChanged: LKRTCFrameCryptorState) {
        guard stateChanged == .decryptionFailed || stateChanged == .encryptionFailed || stateChanged == .missingKey else { return }
        main { [weak self] in self?.cryptorFailures += 1 }
    }
}

// MARK: - Bulk channel (file chunks), runs entirely off the main thread

nonisolated final class BulkChannel: NSObject, LKRTCDataChannelDelegate, @unchecked Sendable {
    static let highWater: UInt64 = 8 * 1024 * 1024
    static let lowWater: UInt64 = 2 * 1024 * 1024

    private let lock = NSLock()
    private let sendLock = NSLock()
    private var channel: LKRTCDataChannel?
    private var cipher: FrameCipher?
    private let drained = DispatchSemaphore(value: 0)
    private var waiting = false
    private var closed = false
    let queue = DispatchQueue(label: "priva.bulk", qos: .userInitiated)
    var onChunk: (@Sendable (_ fileID: String, _ index: Int, _ data: Data) -> Void)?
    /// A sealed chunk was refused: its counter is spent, so every later chunk would be dropped by the receiver.
    var onBroken: (@Sendable () -> Void)?

    func attach(channel: LKRTCDataChannel, cipher: FrameCipher) {
        lock.lock()
        self.channel = channel
        self.cipher = cipher
        lock.unlock()
        channel.delegate = self
    }

    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return channel?.readyState == .open && !closed }

    /// Blocks the calling (background) thread while the SCTP buffer is above the high watermark.
    func sendChunk(fileID: String, index: Int, data: Data) -> Bool {
        lock.lock()
        guard let channel, let cipher, !closed else { lock.unlock(); return false }
        lock.unlock()
        while channel.bufferedAmount > Self.highWater {
            lock.lock(); waiting = true; lock.unlock()
            if drained.wait(timeout: .now() + 5) == .timedOut, isOpen == false { return false }
        }
        var payload = Data(fileID.utf8.prefix(36))
        payload.appendBE(UInt32(index))
        payload.append(data)
        // Counter assignment and send must be atomic, or concurrent transfers would reorder frames.
        sendLock.lock()
        defer { sendLock.unlock() }
        guard let frame = try? cipher.seal(type: FrameType.chunk, payload) else { return false }
        guard channel.sendData(PeerLink.tapped(frame)) else {
            // Close instead of stalling every transfer on this link until it ends (audit STA-27); a new connection
            // resumes them.
            lock.lock(); closed = true; lock.unlock()
            onBroken?()
            return false
        }
        return true
    }

    var bufferedAmount: UInt64 { lock.lock(); defer { lock.unlock() }; return channel?.bufferedAmount ?? 0 }

    func close() {
        lock.lock()
        closed = true
        let c = channel
        channel = nil
        let w = waiting
        waiting = false
        lock.unlock()
        c?.delegate = nil
        c?.close()
        if w { drained.signal() }
    }

    func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {}

    func dataChannel(_ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        lock.lock()
        let cipher = self.cipher
        lock.unlock()
        guard let cipher, let (type, payload) = try? cipher.open(buffer.data), type == FrameType.chunk, payload.count > 40 else { return }
        let p = payload.detached
        let fileID = String(decoding: p.prefix(36), as: UTF8.self)
        let index = p.subdata(in: 36..<40).reduce(0) { ($0 << 8) | Int($1) }
        onChunk?(fileID, index, p.subdata(in: 40..<p.count))
    }

    func dataChannel(_ dataChannel: LKRTCDataChannel, didChangeBufferedAmount amount: UInt64) {
        lock.lock()
        let shouldSignal = waiting && dataChannel.bufferedAmount <= Self.lowWater
        if shouldSignal { waiting = false }
        lock.unlock()
        if shouldSignal { drained.signal() }
    }
}
