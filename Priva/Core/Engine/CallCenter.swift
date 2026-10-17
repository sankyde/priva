import Foundation
import LiveKitWebRTC
import Observation
import UIKit

@Observable
final class CallCenter {
    init() { LiveObjects.born("CallCenter") }
    deinit { LiveObjects.died("CallCenter") }

    enum Phase: Equatable {
        case dialing, ringing, incoming, connecting, active
        case ended(String)
    }

    struct Call: Equatable {
        let id: String
        let peer: String
        let outgoing: Bool
        var video: Bool
        var phase: Phase
        let startedAt: Date = .now
        var connectedAt: Date?
        var muted = false
        var speaker = false
        var cameraOn = true
        var remoteMuted = false
        var remoteCameraOn = true
        var sas: [String] = []
    }

    var call: Call?
    var remoteVideo: LKRTCVideoTrack?
    var localVideo: LKRTCVideoTrack?
    var stats = PeerLink.Stats()
    var decryptFailures = 0
    @ObservationIgnored weak var engine: PrivaEngine?
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private var firstMediaAt: Date?

    var isInCall: Bool {
        guard let call else { return false }
        if case .ended = call.phase { return false }
        return true
    }

    private var link: PeerLink? { call.flatMap { engine?.link(for: $0.peer) } }

    // MARK: outgoing

    func start(peer: String, video: Bool) {
        guard !isInCall, let engine, !engine.groupCalls.isInCall else { return }
        call = Call(id: UUID().uuidString, peer: peer, outgoing: true, video: video, phase: .dialing)
        arm(45, reason: "No answer")
        if let l = engine.link(for: peer), l.isReady { sendInvite(l) } else { engine.requestLink(peer, intent: video ? .video : .audio, urgent: true) }
    }

    private func sendInvite(_ l: PeerLink) {
        guard var c = call, c.outgoing, c.phase == .dialing else { return }
        c.phase = .ringing
        c.sas = l.keys?.sas ?? []
        call = c
        l.send(.callInvite(callID: c.id, video: c.video))
    }

    // MARK: engine hooks

    func linkReady(_ l: PeerLink) {
        guard let c = call, c.peer == l.peer else { return }
        if c.outgoing && c.phase == .dialing { sendInvite(l) }
    }

    func linkClosed(peer: String) {
        guard let c = call, c.peer == peer else { return }
        switch c.phase {
        case .ended: return
        case .dialing: return // the engine keeps retrying while we dial
        default: finish(reason: "Connection lost", notify: false)
        }
    }

    func remoteVideoChanged(_ l: PeerLink) {
        guard call?.peer == l.peer else { return }
        remoteVideo = l.remoteVideoTrack
    }

    func handle(_ wire: Wire, from peer: String, link l: PeerLink) {
        switch wire {
        case .callInvite(let id, let video):
            if (isInCall && call?.id != id) || engine?.groupCalls.isInCall == true {
                l.send(.callDecline(callID: id, busy: true))
                engine?.recordCall(CallRecord(id: id, contact: peer, outgoing: false, video: video, startedAt: .now, duration: 0, outcome: .missed))
                return
            }
            call = Call(id: id, peer: peer, outgoing: false, video: video, phase: .incoming, sas: l.keys?.sas ?? [])
            arm(45, reason: "Missed")
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .callAccept(let id):
            guard var c = call, c.id == id, c.peer == peer, c.outgoing else { return }
            c.phase = .connecting
            call = c
            arm(20, reason: "Couldn't connect")
            l.startMedia(video: c.video)
            localVideo = l.localVideoTrack
            Task { await l.negotiateMedia() }
            monitorMedia()
        case .callDecline(let id, let busy):
            guard call?.id == id, call?.peer == peer else { return }
            finish(reason: busy ? "Busy" : "Declined", notify: false, outcome: .declined)
        case .callEnd(let id):
            guard call?.id == id, call?.peer == peer else { return }
            finish(reason: "Call ended", notify: false)
        case .callState(let video, let muted):
            guard call?.peer == peer else { return }           // another friend can't fake this call's state
            call?.remoteCameraOn = video
            call?.remoteMuted = muted
        default: break
        }
    }

    // MARK: user actions

    func accept() {
        guard var c = call, !c.outgoing, c.phase == .incoming, let l = link else { return }
        c.phase = .connecting
        call = c
        arm(20, reason: "Couldn't connect")
        l.acceptedMedia = c.video
        l.send(.callAccept(callID: c.id))
        monitorMedia()
    }

    func decline() {
        guard let c = call else { return }
        link?.send(.callDecline(callID: c.id, busy: false))
        finish(reason: "Declined", notify: false, outcome: .declined)
    }

    func hangUp() {
        guard let c = call else { return }
        if c.phase == .dialing || c.phase == .ringing {
            link?.send(.callEnd(callID: c.id))
            finish(reason: "Cancelled", notify: false, outcome: .cancelled)
        } else {
            finish(reason: "Call ended", notify: true)
        }
    }

    func toggleMute() {
        guard var c = call else { return }
        c.muted.toggle()
        call = c
        link?.setMuted(c.muted)
        link?.send(.callState(video: c.cameraOn, muted: c.muted))
    }

    func toggleCamera() {
        guard var c = call, c.video else { return }
        c.cameraOn.toggle()
        call = c
        link?.setVideoEnabled(c.cameraOn)
        link?.send(.callState(video: c.cameraOn, muted: c.muted))
    }

    func flipCamera() { link?.flipCamera() }

    func toggleSpeaker() {
        guard var c = call else { return }
        c.speaker.toggle()
        call = c
        WebRTCEnv.setSpeaker(c.speaker)
    }

    // MARK: internals

    private func arm(_ seconds: Double, reason: String) {
        timeout?.cancel()
        let id = call?.id
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, let c = self.call, c.id == id, c.phase != .active else { return }
            self.finish(reason: reason, notify: true, outcome: c.outgoing ? .cancelled : .missed)
        }
    }

    /// Polls transport stats; the call becomes "active" once decrypted media is actually flowing.
    private func monitorMedia() {
        statsTask?.cancel()
        firstMediaAt = nil
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let l = self.link, self.isInCall else { return }
                let s = await l.stats()
                self.stats = s
                self.decryptFailures = l.cryptorFailures
                if self.localVideo == nil { self.localVideo = l.localVideoTrack }
                // Media actually arriving, not just data-channel bytes (the renegotiation alone crosses 1 kbps; audit
                // STA-26).
                if var c = self.call, c.phase == .connecting, s.audioPacketsReceived > 0 || s.audioLevel != nil || s.framesDecoded > 0 {
                    c.phase = .active
                    c.connectedAt = .now
                    if c.sas.isEmpty { c.sas = l.keys?.sas ?? [] }
                    self.call = c
                    self.timeout?.cancel()
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                }
                try? await Task.sleep(for: .milliseconds(self.call?.phase == .active ? 1000 : 250))
            }
        }
    }

    private func finish(reason: String, notify: Bool, outcome: CallRecord.Outcome? = nil) {
        guard var c = call else { return }
        if case .ended = c.phase { return }
        if notify { link?.send(.callEnd(callID: c.id)) }
        link?.stopMedia()
        timeout?.cancel()
        statsTask?.cancel()
        let duration = c.connectedAt.map { Date().timeIntervalSince($0) } ?? 0
        let result = outcome ?? (c.connectedAt != nil ? .answered : (c.outgoing ? .cancelled : .missed))
        engine?.recordCall(CallRecord(id: c.id, contact: c.peer, outgoing: c.outgoing, video: c.video,
                                      startedAt: c.startedAt, duration: duration, outcome: result))
        c.phase = .ended(reason)
        call = c
        remoteVideo = nil
        localVideo = nil
        let id = c.id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            if self?.call?.id == id { self?.call = nil }
        }
    }
}
