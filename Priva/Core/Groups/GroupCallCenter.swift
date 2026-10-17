import AVFoundation
import Foundation
import LiveKitWebRTC
import Observation
import UIKit

/// One camera + microphone shared by every member link while this iPhone hosts a group call.
final class GroupLocalMedia {
    let audio: LKRTCAudioTrack
    let video: LKRTCVideoTrack?
    private let source: LKRTCVideoSource?
    #if targetEnvironment(simulator)
    private var synthetic: SyntheticCapturer?
    #endif
    private var camera: LKRTCCameraVideoCapturer?

    #if DEBUG
    /// Tests: shared call media pipelines alive right now.
    nonisolated(unsafe) static var debugLive = 0
    deinit { Self.debugLive -= 1 }
    #endif

    init(video: Bool, label: String) {
        #if DEBUG
        Self.debugLive += 1
        #endif
        let src = WebRTCEnv.factory.audioSource(with: nil)
        audio = WebRTCEnv.factory.audioTrack(with: src, trackId: "ga-\(Bytes.random(4).hex)")
        guard video else { self.video = nil; source = nil; return }
        let vs = WebRTCEnv.factory.videoSource()
        source = vs
        self.video = WebRTCEnv.factory.videoTrack(with: vs, trackId: "gv-\(Bytes.random(4).hex)")
        // Group video is sized for an iPhone acting as the media processor: 640×360 @ 20 fps.
        #if targetEnvironment(simulator)
        let s = SyntheticCapturer(delegate: vs, width: 640, height: 360, label: label)
        synthetic = s
        s.start(fps: 20)
        #else
        let cam = LKRTCCameraVideoCapturer(delegate: vs)
        camera = cam
        if let device = LKRTCCameraVideoCapturer.captureDevices().first(where: { $0.position == .front }),
           let format = LKRTCCameraVideoCapturer.supportedFormats(for: device).min(by: { a, b in
               let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription), db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
               return abs(Int(da.width) - 640) < abs(Int(db.width) - 640)
           }) {
            cam.startCapture(with: device, format: format, fps: 20)
        }
        #endif
    }

    func setMuted(_ m: Bool) { audio.isEnabled = !m }
    func setCamera(_ on: Bool) {
        video?.isEnabled = on
        #if targetEnvironment(simulator)
        if on { synthetic?.start(fps: 20) } else { synthetic?.stop() }
        #endif
    }

    func stop() {
        #if targetEnvironment(simulator)
        synthetic?.stop()
        #endif
        camera?.stopCapture { }
        audio.isEnabled = false
        video?.isEnabled = false
    }
}

/// Group voice/video calls. Star topology: the HOST's iPhone is the processor, it receives each
/// member's media over their Dual-PQ session, decrypts it and forwards (re-encodes) it to the others.
@Observable
final class GroupCallCenter {
    init() { LiveObjects.born("GroupCallCenter") }
    deinit { LiveObjects.died("GroupCallCenter") }

    enum Phase: Equatable { case requesting, incoming, active, ended(String) }

    struct Call: Equatable {
        let gid: String
        var callID: String
        let host: String
        var video: Bool
        var phase: Phase
        var participants: [String]
        var muted = false
        var cameraOn = true
        var speaker = true
        let startedAt = Date()
        /// Host side: the member asking the host to start a call (the host must accept first).
        var requestedBy: String? = nil
    }

    struct ParticipantState: Equatable {
        var cameraOn = true
        var muted = false
    }

    var call: Call?
    /// Camera / mic state of the other participants (shown on their tiles).
    private(set) var states: [String: ParticipantState] = [:]
    /// participant → their video (host: straight from each member; member: as forwarded by the host).
    private(set) var tiles: [String: LKRTCVideoTrack] = [:]
    private(set) var localVideo: LKRTCVideoTrack?
    @ObservationIgnored weak var engine: PrivaEngine?
    @ObservationIgnored private var local: GroupLocalMedia?
    /// Host: members we couldn't ring yet (offline); they're rung as soon as their link comes up.
    @ObservationIgnored private var unrung: Set<String> = []
    @ObservationIgnored private var aloneCheck = UUID()

    /// The host alone in its call, nobody answered, or everyone left, ends it after this long, so the iPhone isn't
    /// left "in a call" with nobody in it (and busy to every 1:1 caller) until someone notices.
    static var aloneLimit: TimeInterval = 60
    @ObservationIgnored private var connectedAt: Date?

    private var me: String { engine?.me ?? "" }
    var isHost: Bool { call?.host == me }
    var isInCall: Bool {
        guard let c = call else { return false }
        if case .ended = c.phase { return false }
        return true
    }

    private func link(_ u: String) -> PeerLink? { engine?.link(for: u).flatMap { $0.isReady ? $0 : nil } }

    @discardableResult
    private func send(_ p: GroupPacket, to u: String) -> Bool {
        guard let engine, u != me else { return false }
        if let l = link(u) { l.send(.group(p)); return true }
        engine.requestLink(u, intent: .audio, urgent: true)
        return false
    }

    private func limit(_ video: Bool) -> Int { video ? PrivaGroup.maxVideoParticipants : PrivaGroup.maxVoiceParticipants }

    // MARK: start / join

    func start(gid: String, video: Bool) {
        guard !isInCall, !(engine?.calls.isInCall ?? false), let g = engine?.groups.groups[gid], !g.ended else { return }
        let callID = UUID().uuidString
        if g.host == me {
            beginHosting(g, callID: callID, video: video)
        } else {
            call = Call(gid: gid, callID: callID, host: g.host, video: video, phase: .requesting, participants: [])
            link(g.host)?.acceptedMedia = video
            link(g.host)?.groupMedia = true
            send(.callInvite(groupID: gid, callID: callID, video: video), to: g.host)
            let id = callID
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                if self?.call?.callID == id, self?.call?.phase == .requesting { self?.finish("The host didn't answer") }
            }
        }
    }

    private func beginHosting(_ g: PrivaGroup, callID: String, video: Bool) {
        call = Call(gid: g.id, callID: callID, host: me, video: video, phase: .active, participants: [me])
        local = GroupLocalMedia(video: video, label: me)
        localVideo = local?.video
        connectedAt = .now
        WebRTCEnv.configureAudioSession(video: video, owner: self)
        WebRTCEnv.setSpeaker(true)
        unrung = []
        for m in g.members where m.username != me {
            if !send(.callInvite(groupID: g.id, callID: callID, video: video), to: m.username) { unrung.insert(m.username) }
        }
        endIfLeftAlone()
    }

    private func endIfLeftAlone() {
        guard let c = call, isHost, c.participants.count <= 1 else { return }
        let token = UUID(), id = c.callID
        aloneCheck = token
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.aloneLimit))
            guard let self, self.aloneCheck == token, let c = self.call, c.callID == id, self.isHost, self.isInCall,
                  c.participants.count <= 1 else { return }
            self.hangUp()
        }
    }

    func accept() {
        // Host: a member asked for a call. Camera and mic start only now, with the host's consent.
        if let c = call, c.phase == .incoming, c.host == me, let g = engine?.groups.groups[c.gid], !g.ended {
            let requester = c.requestedBy
            beginHosting(g, callID: c.callID, video: c.video)
            if let requester { hostJoin(requester) }
            return
        }
        guard var c = call, c.phase == .incoming, let l = link(c.host) else { return }
        c.phase = .active
        call = c
        connectedAt = .now
        l.acceptedMedia = c.video
        l.groupMedia = true
        l.send(.group(.callJoin(groupID: c.gid, callID: c.callID)))
        WebRTCEnv.setSpeaker(true)
    }

    func decline() {
        guard let c = call else { return }
        if c.host == me {
            if let r = c.requestedBy { send(.callEnd(groupID: c.gid, callID: c.callID), to: r) }
        } else {
            send(.callLeave(groupID: c.gid, callID: c.callID), to: c.host)
        }
        finish("Declined")
    }

    func hangUp() {
        guard let c = call else { return }
        if isHost {
            // Everyone who was rung hears the end, not just those who joined, or their phones keep ringing.
            let rung = Set(engine?.groups.groups[c.gid]?.members.map(\.username) ?? []).union(c.participants)
            for p in rung where p != me { send(.callEnd(groupID: c.gid, callID: c.callID), to: p) }
            for p in c.participants where p != me { link(p)?.stopMedia(keepAudioSession: true) }
        } else {
            send(.callLeave(groupID: c.gid, callID: c.callID), to: c.host)
            link(c.host)?.stopMedia()
        }
        finish("Call ended")
    }

    func toggleMute() {
        guard var c = call else { return }
        c.muted.toggle()
        call = c
        if isHost { local?.setMuted(c.muted) } else { link(c.host)?.setMuted(c.muted) }
        announceState()
    }

    func toggleCamera() {
        guard var c = call, c.video else { return }
        c.cameraOn.toggle()
        call = c
        if isHost { local?.setCamera(c.cameraOn) } else { link(c.host)?.setVideoEnabled(c.cameraOn) }
        announceState()
    }

    /// Tell the others: members tell the host, the host tells everyone.
    private func announceState() {
        guard let c = call, isInCall else { return }
        let p = GroupPacket.callState(groupID: c.gid, callID: c.callID, participant: me, cameraOn: c.cameraOn, muted: c.muted)
        if isHost { for u in c.participants where u != me { send(p, to: u) } } else { send(p, to: c.host) }
    }

    func toggleSpeaker() {
        guard var c = call else { return }
        c.speaker.toggle()
        call = c
        WebRTCEnv.setSpeaker(c.speaker)
    }

    // MARK: host: participants

    private func hostJoin(_ member: String) {
        guard var c = call, isHost, let g = engine?.groups.groups[c.gid], g.member(member) != nil, let l = link(member) else { return }
        if c.participants.contains(member) { return }
        guard c.participants.count < limit(c.video) else {
            l.send(.group(.callEnd(groupID: c.gid, callID: c.callID)))
            return
        }
        c.participants.append(member)
        call = c
        unrung.remove(member)
        l.startMedia(video: c.video, shared: local)
        // Everyone already in the call is forwarded to the newcomer.
        for p in c.participants where p != me && p != member {
            for (_, track) in link(p)?.receivedTracks(trustLabels: false) ?? [] { l.forward(track, from: p) }
        }
        Task { await l.negotiateMedia() }
        broadcastRoster()
        l.send(.group(.callState(groupID: c.gid, callID: c.callID, participant: me, cameraOn: c.cameraOn, muted: c.muted)))
        for (who, s) in states where who != member && c.participants.contains(who) {
            l.send(.group(.callState(groupID: c.gid, callID: c.callID, participant: who, cameraOn: s.cameraOn, muted: s.muted)))
        }
    }

    private func hostLeave(_ member: String) {
        guard var c = call, isHost, c.participants.contains(member) else { return }
        c.participants.removeAll { $0 == member }
        call = c
        link(member)?.stopMedia(keepAudioSession: true)
        tiles[member] = nil
        for p in c.participants where p != me {
            guard let l = link(p) else { continue }
            l.removeForwards(from: member)
            Task { await l.negotiateMedia() }
        }
        broadcastRoster()
        endIfLeftAlone()
    }

    private func broadcastRoster() {
        guard let c = call, isHost else { return }
        for p in c.participants where p != me { send(.callRoster(groupID: c.gid, callID: c.callID, participants: c.participants), to: p) }
    }

    // MARK: engine hooks

    func handle(_ p: GroupPacket, from peer: String, link l: PeerLink) {
        guard let engine else { return }
        switch p {
        case .callInvite(let gid, let callID, let video):
            guard let g = engine.groups.groups[gid], !g.ended, g.member(peer) != nil else { return }
            if g.host == me {
                if !isInCall, !engine.calls.isInCall, !g.isMuted(peer) {
                    // A member asked the host to start a call: ring the host. Nothing is captured until
                    // the host accepts (a member must never be able to switch on the host's camera or mic).
                    call = Call(gid: gid, callID: callID, host: me, video: video, phase: .incoming, participants: [],
                                requestedBy: peer)
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    let id = callID
                    Task { [weak self] in
                        try? await Task.sleep(for: .seconds(30))
                        if self?.call?.callID == id, self?.call?.phase == .incoming { self?.decline() }
                    }
                } else if let c = call, c.gid == gid, c.phase == .active {
                    // Joining a call the host already started.
                    l.send(.group(.callInvite(groupID: gid, callID: c.callID, video: c.video)))
                    hostJoin(peer)
                } else {
                    l.send(.group(.callEnd(groupID: gid, callID: callID)))  // busy
                }
            } else if g.host == peer {
                if var c = call, c.gid == gid, c.phase == .requesting {
                    // The host started the call for us (or we joined one already running): adopt its id.
                    c.callID = callID
                    c.video = video
                    c.phase = .active
                    call = c
                    connectedAt = .now
                    l.acceptedMedia = video
                    l.groupMedia = true
                    WebRTCEnv.setSpeaker(true)
                } else if !isInCall, !engine.calls.isInCall {
                    call = Call(gid: gid, callID: callID, host: peer, video: video, phase: .incoming, participants: [peer])
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    // Stop ringing if nobody answers (or the host's end never arrives).
                    Task { [weak self] in
                        try? await Task.sleep(for: .seconds(45))
                        if self?.call?.callID == callID, self?.call?.phase == .incoming { self?.finish("Missed group call") }
                    }
                }
            }
        case .callJoin(let gid, let callID):
            guard call?.gid == gid, call?.callID == callID else { return }
            hostJoin(peer)
        case .callLeave(let gid, let callID):
            guard call?.gid == gid, call?.callID == callID else { return }
            if isHost { hostLeave(peer) }
        case .callEnd(let gid, let callID):
            guard let c = call, c.gid == gid, c.callID == callID || c.phase == .requesting, c.host == peer else { return }
            l.stopMedia()
            finish("Call ended")
        case .callState(let gid, let callID, let who, let cameraOn, let muted):
            guard let c = call, c.gid == gid, c.callID == callID, who != me else { return }
            if isHost {
                // Members speak only for themselves; the host relays to everyone else in the call.
                guard who == peer, c.participants.contains(peer) else { return }
                states[who] = ParticipantState(cameraOn: cameraOn, muted: muted)
                for u in c.participants where u != me && u != peer { send(p, to: u) }
            } else {
                guard peer == c.host, c.participants.contains(who) else { return }
                states[who] = ParticipantState(cameraOn: cameraOn, muted: muted)
            }
        case .callRoster(let gid, let callID, let participants):
            guard var c = call, c.gid == gid, c.callID == callID, c.host == peer else { return }
            c.participants = participants.filter(Username.isValid)
            call = c
            tiles = tiles.filter { c.participants.contains($0.key) }
        default: break
        }
    }

    /// Remote media changed on a link: the host forwards new member tracks; members refresh tiles.
    func remoteMediaChanged(_ l: PeerLink) {
        guard let c = call, isInCall else { return }
        if isHost {
            guard c.participants.contains(l.peer) else { return }
            let tracks = l.receivedTracks(trustLabels: false)
            if let v = tracks.first(where: { $0.track.kind == "video" })?.track as? LKRTCVideoTrack { tiles[l.peer] = v }
            for receiver in c.participants where receiver != me && receiver != l.peer {
                guard let rl = link(receiver) else { continue }
                var added = false
                for (_, track) in tracks where rl.forward(track, from: l.peer) { added = true }
                if added { Task { await rl.negotiateMedia() } }
            }
        } else if l.peer == c.host {
            var t: [String: LKRTCVideoTrack] = [:]
            for (who, track) in l.receivedTracks(trustLabels: true) {
                if let v = track as? LKRTCVideoTrack { t[who] = v }
            }
            tiles = t
            localVideo = l.localVideoTrack
        }
    }

    func linkReady(_ l: PeerLink) {
        guard let c = call, isInCall else { return }
        if isHost, unrung.remove(l.peer) != nil {
            l.send(.group(.callInvite(groupID: c.gid, callID: c.callID, video: c.video)))
        } else if !isHost, c.phase == .requesting, l.peer == c.host {
            l.acceptedMedia = c.video
            l.groupMedia = true
            l.send(.group(.callInvite(groupID: c.gid, callID: c.callID, video: c.video)))
        }
    }

    func linkClosed(peer: String) {
        guard let c = call, isInCall else { return }
        if isHost { hostLeave(peer) } else if peer == c.host { finish("The host's connection dropped") }
    }

    func peersNeedingLink() -> Set<String> {
        guard let c = call, isInCall else { return [] }
        return isHost ? Set(c.participants.filter { $0 != me }).union(unrung) : [c.host]
    }

    private func finish(_ reason: String) {
        guard var c = call else { return }
        // A member's consent to send to the host ends with the call, however it ended (timeout, decline, drop).
        if c.host != me { link(c.host)?.stopMedia() }
        if let start = connectedAt, let engine, let g = engine.groups.groups[c.gid] {
            let text = "Group \(c.video ? "video" : "voice") call · \(PrivaEngine.clock(Date().timeIntervalSince(start)))"
            engine.persist(Message(id: UUID().uuidString, contact: g.threadKey, outgoing: isHost, kind: .call, text: text, attachment: nil,
                                   sentAt: start, receivedAt: .now, status: .received, readAt: .now))
        }
        connectedAt = nil
        unrung = []
        local?.stop()
        local = nil
        localVideo = nil
        tiles = [:]
        states = [:]
        c.phase = .ended(reason)
        call = c
        WebRTCEnv.releaseAudioSession(owner: self)
        let id = c.callID
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            if self?.call?.callID == id { self?.call = nil }
        }
    }
}
