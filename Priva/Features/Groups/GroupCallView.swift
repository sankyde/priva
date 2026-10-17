import LiveKitWebRTC
import SwiftUI

/// Group voice/video call. Media flows member ⇄ host only; the host's iPhone forwards everyone else.
struct GroupCallView: View {
    @Environment(PrivaEngine.self) private var engine
    @Environment(\.dynamicTypeSize) private var size
    @State private var now = Date()
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let gc = engine.groupCalls
        ZStack {
            LinearGradient(colors: [Color(hex: 0x14163A), Color(hex: 0x07080D)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            Circle().fill(Theme.violet.opacity(0.3)).frame(width: 420).blur(radius: 120).offset(y: -200)
            if let call = gc.call {
                let g = engine.groups.groups[call.gid]
                if call.phase == .incoming {
                    incoming(call, group: g)
                } else {
                    active(call, group: g)
                }
            }
        }
        .onReceive(clock) { now = $0 }
        .persistentSystemOverlays(.hidden)
        .keepsScreenAwake(gc.isInCall && gc.call?.video == true && gc.call?.phase != .incoming)
    }

    // MARK: incoming

    private func incoming(_ call: GroupCallCenter.Call, group: PrivaGroup?) -> some View {
        VStack(spacing: 18) {
            Spacer()
            GroupAvatar(name: group?.name ?? "Group", size: 120)
                .motionPulse(to: 1.05, duration: 0.9)
            Text(group?.name ?? "Group call").font(.system(.largeTitle, design: .rounded).weight(.bold)).foregroundStyle(.white)
                .multilineTextAlignment(.center)
            if let r = call.requestedBy {
                Label("\(engine.name(of: r, in: group)) wants to start a group \(call.video ? "video" : "voice") call",
                      systemImage: call.video ? "video.fill" : "phone.fill")
                    .font(.headline).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
                SecureChip(text: "Camera and mic stay off until you join")
            } else {
                Label("\(engine.name(of: call.host, in: group)) · group \(call.video ? "video" : "voice") call",
                      systemImage: call.video ? "video.fill" : "phone.fill")
                    .font(.headline).foregroundStyle(.white.opacity(0.8))
                SecureChip()
            }
            Spacer()
            HStack(spacing: size.isAccessibilitySize ? 28 : 70) {
                VStack(spacing: 10) {
                    GlassIconButton(systemImage: "phone.down.fill", size: 76, tint: Theme.callDecline, label: "Decline") { engine.groupCalls.decline() }
                    Text("Decline").font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
                }
                VStack(spacing: 10) {
                    GlassIconButton(systemImage: call.video ? "video.fill" : "phone.fill", size: 76, tint: Theme.callAccept, label: "Join") { engine.groupCalls.accept() }
                    Text("Join").font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
                }
            }
            .padding(.bottom, 70)
        }
        .padding(.horizontal, 24)
    }

    // MARK: active

    private func active(_ call: GroupCallCenter.Call, group: PrivaGroup?) -> some View {
        VStack(spacing: 14) {
            header(call, group: group)
            tiles(call, group: group)
            controls(call)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func header(_ call: GroupCallCenter.Call, group: PrivaGroup?) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill").foregroundStyle(Theme.mint)
                Text(engine.groupCalls.isHost ? "Hosted by you" : "Hosted by \(engine.name(of: call.host, in: group))")
                    .font(.caption.weight(.semibold)).foregroundStyle(.white)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
            Text(group?.name ?? "Group call").font(.headline).foregroundStyle(.white)
            Text(status(call)).font(.subheadline.monospacedDigit()).foregroundStyle(.white.opacity(0.7)).contentTransition(.numericText())
        }
    }

    private func tiles(_ call: GroupCallCenter.Call, group: PrivaGroup?) -> some View {
        let people = participants(call)
        // 1–2 people: stacked. More: two per row, and an odd one out spans the row.
        let rows: [[String]] = people.count <= 2 ? people.map { [$0] }
            : stride(from: 0, to: people.count, by: 2).map { Array(people[$0..<min($0 + 2, people.count)]) }
        return VStack(spacing: 10) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 10) {
                    ForEach(row, id: \.self) { u in tile(u, call: call, group: group) }
                }
            }
        }
        .animation(Theme.snappy, value: people)
    }

    private func participants(_ call: GroupCallCenter.Call) -> [String] {
        var out = [engine.me]
        for p in call.participants where p != engine.me && !out.contains(p) { out.append(p) }
        if !engine.groupCalls.isHost, !out.contains(call.host) { out.insert(call.host, at: 1) }
        return out
    }

    @ViewBuilder private func tile(_ u: String, call: GroupCallCenter.Call, group: PrivaGroup?) -> some View {
        let gc = engine.groupCalls
        let isMe = u == engine.me
        let state = gc.states[u] ?? .init()
        let track: LKRTCVideoTrack? = isMe ? (call.cameraOn ? gc.localVideo : nil) : (state.cameraOn ? gc.tiles[u] : nil)
        let muted = isMe ? call.muted : state.muted
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 22).fill(Color.white.opacity(0.06))
            if call.video, let track {
                VideoTrackView(track: track, mirrored: isMe, fill: true)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
            } else {
                Avatar(name: u, size: 72).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 6) {
                if muted { Image(systemName: "mic.slash.fill").foregroundStyle(Theme.rose).accessibilityLabel("Muted") }
                if u == call.host { Image(systemName: "crown.fill").foregroundStyle(Theme.violetLight) }
                Text(isMe ? "You" : engine.name(of: u, in: group)).lineLimit(1)
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
            .padding(10)
        }
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.12), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel((isMe ? "You" : engine.name(of: u, in: group)) + (muted ? ", muted" : "") + (u == call.host ? ", host" : ""))
    }

    private func controls(_ call: GroupCallCenter.Call) -> some View {
        let gc = engine.groupCalls
        return GlassEffectContainer(spacing: 16) {
            HStack(spacing: 16) {
                GlassIconButton(systemImage: call.muted ? "mic.slash.fill" : "mic.fill", active: call.muted, label: call.muted ? "Unmute" : "Mute") { gc.toggleMute() }
                if call.video {
                    GlassIconButton(systemImage: call.cameraOn ? "video.fill" : "video.slash.fill", active: !call.cameraOn,
                                    label: call.cameraOn ? "Turn camera off" : "Turn camera on") { gc.toggleCamera() }
                }
                GlassIconButton(systemImage: call.speaker ? "speaker.wave.3.fill" : "speaker.fill", active: call.speaker, label: "Speaker") { gc.toggleSpeaker() }
                VStack(spacing: 4) {
                    GlassIconButton(systemImage: "phone.down.fill", size: 66, tint: Theme.callDecline, label: gc.isHost ? "End call for everyone" : "Leave call") { gc.hangUp() }
                    // The host's hang-up ends the call for everyone: say so where it's tapped.
                    if gc.isHost { Text("End for all").font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.85)).accessibilityHidden(true) }
                }
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: call.muted)
    }

    private func status(_ c: GroupCallCenter.Call) -> String {
        switch c.phase {
        case .requesting: return "Calling the host…"
        case .incoming: return "Incoming group call"
        case .active:
            let n = participants(c).count
            let t = Int(now.timeIntervalSince(c.startedAt))
            return n <= 1 ? "Ringing…" : String(format: "%d in call · %d:%02d", n, t / 60, t % 60)
        case .ended(let r): return r
        }
    }
}
