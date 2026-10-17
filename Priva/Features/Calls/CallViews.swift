import LiveKitWebRTC
import SwiftUI

// MARK: - Call screen

struct CallView: View {
    @Environment(PrivaEngine.self) private var engine
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var pipCorner: Corner = .topTrailing
    @State private var drag: CGSize = .zero
    @State private var now = Date()
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    enum Corner { case topLeading, topTrailing, bottomLeading, bottomTrailing }

    var body: some View {
        let calls = engine.calls
        ZStack {
            if let call = calls.call {
                background(call)
                if call.phase == .incoming {
                    IncomingCallOverlay(call: call, name: engine.contact(call.peer)?.displayName ?? call.peer)
                } else {
                    activeOverlay(call)
                }
            }
        }
        // Backgrounds extend under the bars themselves; the controls stay inside the safe area
        // (clear of the Dynamic Island and home indicator).
        .statusBarHidden(!controlsVisible)
        .onReceive(clock) { now = $0 }
        .onTapGesture { toggleControls() }
        .onAppear { scheduleHide() }
        .persistentSystemOverlays(.hidden)
        .keepsScreenAwake(calls.isInCall && calls.call?.video == true && calls.call?.phase != .incoming)
    }

    @ViewBuilder private func background(_ call: CallCenter.Call) -> some View {
        let calls = engine.calls
        if call.video, let remote = calls.remoteVideo, call.remoteCameraOn {
            VideoTrackView(track: remote, mirrored: false, fill: true)
                .overlay {
                    // Scrims keep the white controls legible on bright video.
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom).frame(height: 220)
                        Spacer()
                        LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom).frame(height: 240)
                    }
                    .allowsHitTesting(false)
                }
                .ignoresSafeArea()
                .transition(.opacity)
        } else {
            ZStack {
                LinearGradient(colors: [Color(hex: 0x14163A), Color(hex: 0x07080D)], startPoint: .top, endPoint: .bottom)
                Circle().fill(Theme.violet.opacity(0.35)).frame(width: 420).blur(radius: 120).offset(y: -160)
            }
            .ignoresSafeArea()
        }
    }

    @ViewBuilder private func activeOverlay(_ call: CallCenter.Call) -> some View {
        let calls = engine.calls
        let name = engine.contact(call.peer)?.displayName ?? call.peer
        GeometryReader { geo in
            ZStack {
                if !(call.video && calls.remoteVideo != nil && call.remoteCameraOn) {
                    VStack(spacing: 18) {
                        PulsingAvatar(name: call.peer, level: calls.stats.audioLevel ?? 0, active: call.phase == .active)
                        Text(name).font(.system(.title, design: .rounded).weight(.bold)).foregroundStyle(.white)
                        Text(status(call)).font(.headline.monospacedDigit()).foregroundStyle(.white.opacity(0.75)).contentTransition(.numericText())
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .offset(y: -40)
                }
                if call.video, let local = calls.localVideo, call.cameraOn {
                    VideoTrackView(track: local, mirrored: true, fill: true)
                        .frame(width: 112, height: 168)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.25), lineWidth: 1))
                        .shadow(color: .black.opacity(0.4), radius: 12)
                        .position(pipPosition(in: geo.size))
                        .offset(drag)
                        .gesture(DragGesture()
                            .onChanged { drag = $0.translation }
                            .onEnded { v in
                                let p = pipPosition(in: geo.size)
                                let end = CGPoint(x: p.x + v.predictedEndTranslation.width, y: p.y + v.predictedEndTranslation.height)
                                withAnimation(Theme.bouncy) {
                                    pipCorner = end.x < geo.size.width / 2 ? (end.y < geo.size.height / 2 ? .topLeading : .bottomLeading)
                                                                          : (end.y < geo.size.height / 2 ? .topTrailing : .bottomTrailing)
                                    drag = .zero
                                }
                            })
                        .accessibilityLabel("Your camera preview")
                }
                VStack {
                    if controlsVisible { topBar(call, name: name).transition(.move(edge: .top).combined(with: .opacity)) }
                    Spacer()
                    if controlsVisible { controls(call).transition(.move(edge: .bottom).combined(with: .opacity)) }
                }
                .padding(.top, 8)
                .padding(.bottom, 18)
            }
        }
        .animation(Theme.snappy, value: controlsVisible)
    }

    private func topBar(_ call: CallCenter.Call, name: String) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill").foregroundStyle(Theme.mint)
                Text("End-to-end encrypted").font(.caption.weight(.semibold)).foregroundStyle(.white)
                if call.phase == .active {
                    QualityDot(stats: engine.calls.stats, failures: engine.calls.decryptFailures)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
            if call.video && engine.calls.remoteVideo != nil {
                Text("\(name) · \(status(call))").font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(.white)
                    .shadow(radius: 4)
            }
            if !call.sas.isEmpty, call.phase == .active || call.phase == .connecting {
                HStack(spacing: 6) {
                    Text(call.sas.joined(separator: " ")).font(.title3)
                    Text("Call code").font(.caption2).foregroundStyle(.white.opacity(0.8))
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .glassEffect(.regular, in: .capsule)
                .accessibilityLabel("Security code \(call.sas.joined(separator: " ")). Compare it with your friend.")
            }
        }
    }

    private func controls(_ call: CallCenter.Call) -> some View {
        let calls = engine.calls
        return GlassEffectContainer(spacing: 16) {
            HStack(spacing: 16) {
                GlassIconButton(systemImage: call.muted ? "mic.slash.fill" : "mic.fill", active: call.muted, label: call.muted ? "Unmute" : "Mute") {
                    calls.toggleMute(); scheduleHide()
                }
                if call.video {
                    GlassIconButton(systemImage: call.cameraOn ? "video.fill" : "video.slash.fill", active: !call.cameraOn,
                                    label: call.cameraOn ? "Turn camera off" : "Turn camera on") { calls.toggleCamera(); scheduleHide() }
                    GlassIconButton(systemImage: "arrow.triangle.2.circlepath.camera.fill", label: "Flip camera") { calls.flipCamera(); scheduleHide() }
                }
                GlassIconButton(systemImage: call.speaker ? "speaker.wave.3.fill" : "speaker.fill", active: call.speaker, label: "Speaker") {
                    calls.toggleSpeaker(); scheduleHide()
                }
                GlassIconButton(systemImage: "phone.down.fill", size: 66, tint: Theme.callDecline, label: "End call") { calls.hangUp() }
            }
            .padding(.horizontal, 18)
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: call.muted)
    }

    private func status(_ c: CallCenter.Call) -> String {
        switch c.phase {
        case .dialing: return "Connecting…"
        case .ringing: return "Ringing…"
        case .incoming: return "Incoming call"
        case .connecting: return "Connecting…"
        case .active:
            let t = Int(now.timeIntervalSince(c.connectedAt ?? now))
            return String(format: "%d:%02d", t / 60, t % 60)
        case .ended(let r): return r
        }
    }

    private func pipPosition(in size: CGSize) -> CGPoint {
        // Top corners sit below the security bar and emoji code; bottom corners above the controls.
        let w: CGFloat = 112 / 2 + 16, h: CGFloat = 168 / 2 + 140
        switch pipCorner {
        case .topLeading: return CGPoint(x: w, y: h)
        case .topTrailing: return CGPoint(x: size.width - w, y: h)
        case .bottomLeading: return CGPoint(x: w, y: size.height - 168 / 2 - 110)
        case .bottomTrailing: return CGPoint(x: size.width - w, y: size.height - 168 / 2 - 110)
        }
    }

    private func toggleControls() {
        withAnimation(Theme.snappy) { controlsVisible.toggle() }
        if controlsVisible { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, engine.calls.call?.video == true, engine.calls.call?.phase == .active else { return }
            withAnimation(Theme.gentle) { controlsVisible = false }
        }
    }
}

struct IncomingCallOverlay: View {
    @Environment(PrivaEngine.self) private var engine
    @Environment(\.dynamicTypeSize) private var size
    let call: CallCenter.Call
    let name: String

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            PulsingAvatar(name: call.peer, level: 0.4, active: true)
            Text(name).font(.system(.largeTitle, design: .rounded).weight(.bold)).foregroundStyle(.white)
            Label(call.video ? "Video call" : "Voice call", systemImage: call.video ? "video.fill" : "phone.fill")
                .font(.headline).foregroundStyle(.white.opacity(0.8))
            SecureChip()
            Spacer()
            HStack(spacing: size.isAccessibilitySize ? 28 : 70) {
                VStack(spacing: 10) {
                    GlassIconButton(systemImage: "phone.down.fill", size: 76, tint: Theme.callDecline, label: "Decline") { engine.calls.decline() }
                    Text("Decline").font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
                }
                VStack(spacing: 10) {
                    GlassIconButton(systemImage: call.video ? "video.fill" : "phone.fill", size: 76, tint: Theme.callAccept, label: "Accept") { engine.calls.accept() }
                        .motionPulse(to: 1.08, duration: 0.8)
                    Text("Accept").font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
                }
            }
            .padding(.bottom, 70)
        }
        .frame(maxWidth: .infinity)
    }
}

struct PulsingAvatar: View {
    let name: String
    let level: Double
    let active: Bool

    var body: some View {
        ZStack {
            ForEach(0..<3) { i in
                Circle()
                    .stroke(Theme.aurora, lineWidth: 2)
                    .frame(width: 150 + CGFloat(i) * 34 + CGFloat(level) * 50, height: 150 + CGFloat(i) * 34 + CGFloat(level) * 50)
                    .opacity(active ? 0.35 - Double(i) * 0.1 : 0)
                    .animation(.easeOut(duration: 0.25), value: level)
            }
            Avatar(name: name, size: 140)
        }
        .frame(height: 260)
        .accessibilityHidden(true)
    }
}

struct QualityDot: View {
    let stats: PeerLink.Stats
    let failures: Int
    var body: some View {
        let rtt = stats.rttMs ?? 0
        let good = failures == 0 && rtt < 250 && stats.packetsLost < 200
        HStack(spacing: 4) {
            Circle().fill(good ? Theme.mint : Theme.amber).frame(width: 7, height: 7)
            // Not by colour alone: a weak connection says so.
            Text(good ? (stats.candidate == "relay" ? "Relayed" : "Direct") : "Weak connection")
                .font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
        }
        .accessibilityLabel(good ? "Connection quality good" : "Connection quality fair")
    }
}

/// Metal-rendered WebRTC video track.
struct VideoTrackView: UIViewRepresentable {
    let track: LKRTCVideoTrack
    let mirrored: Bool
    let fill: Bool

    final class Coordinator { var track: LKRTCVideoTrack? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> LKRTCMTLVideoView {
        let v = LKRTCMTLVideoView(frame: .zero)
        v.videoContentMode = fill ? .scaleAspectFill : .scaleAspectFit
        v.clipsToBounds = true
        v.transform = mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        track.add(v)
        context.coordinator.track = track
        return v
    }

    func updateUIView(_ v: LKRTCMTLVideoView, context: Context) {
        if context.coordinator.track !== track {
            context.coordinator.track?.remove(v)
            track.add(v)
            context.coordinator.track = track
        }
    }

    static func dismantleUIView(_ v: LKRTCMTLVideoView, coordinator: Coordinator) {
        coordinator.track?.remove(v)
    }
}

// MARK: - Call history

struct CallsListView: View {
    @Environment(PrivaEngine.self) private var engine
    @State private var confirmClear = false
    @State private var picking = false

    var body: some View {
        Group {
            if engine.callHistory.isEmpty {
                EmptyStateView(icon: "phone.badge.waveform", title: "No calls yet",
                               message: engine.friends.isEmpty ? "Add a friend in Find, then call them here." : "Calls show up here.",
                               actionTitle: engine.friends.isEmpty ? nil : "Call a friend", action: { picking = true })
            } else {
                List(engine.callHistory) { r in
                    let name = engine.contact(r.contact)?.displayName ?? r.contact
                    HStack(spacing: 12) {
                        Avatar(name: r.contact, size: 44)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(name).font(.headline).foregroundStyle(r.outcome == .missed ? Theme.rose : Theme.textPrimary)
                            Label(detail(r), systemImage: r.outgoing ? "arrow.up.right" : "arrow.down.left")
                                .font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Text(Format.relative(r.startedAt)).font(.caption).foregroundStyle(Theme.textTertiary)
                        Button { engine.calls.start(peer: r.contact, video: r.video) } label: {
                            Image(systemName: r.video ? "video.fill" : "phone.fill").foregroundStyle(Theme.violet).frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Call \(name)")
                        .disabled(engine.contact(r.contact) == nil)
                    }
                    .listRowBackground(Theme.background)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Calls")
        .toolbar {
            if !engine.friends.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { Button("New call", systemImage: "phone.badge.plus") { picking = true } }
            }
            if !engine.callHistory.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { Button("Clear", systemImage: "trash") { confirmClear = true } }
            }
        }
        .sheet(isPresented: $picking) { CallPickerSheet().environment(engine) }
        .confirmationDialog("Clear call history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear history", role: .destructive) { engine.clearCallHistory() }
        }
    }

    private func detail(_ r: CallRecord) -> String {
        let kind = r.video ? "Video" : "Voice"
        switch r.outcome {
        case .answered: return "\(kind) · \(PrivaEngine.clock(r.duration))"
        case .missed: return "Missed \(kind.lowercased()) call"
        case .declined: return "\(kind) · declined"
        case .cancelled: return "\(kind) · no answer"
        case .failed: return "\(kind) · failed"
        }
    }
}

/// "Call a friend" from the Calls tab: pick, then voice or video.
struct CallPickerSheet: View {
    @Environment(PrivaEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(engine.friends) { c in
                HStack(spacing: 12) {
                    Avatar(name: c.username, size: 40).accessibilityHidden(true)
                    Text(c.displayName).font(.headline)
                    Spacer()
                    Button { call(c.username, video: false) } label: {
                        Image(systemName: "phone.fill").foregroundStyle(Theme.tint).frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain).accessibilityLabel("Voice call \(c.displayName)")
                    Button { call(c.username, video: true) } label: {
                        Image(systemName: "video.fill").foregroundStyle(Theme.tint).frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain).accessibilityLabel("Video call \(c.displayName)")
                }
            }
            .navigationTitle("Call a friend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", systemImage: "xmark") { dismiss() } } }
        }
    }

    /// The call screen can't appear while this sheet is still on screen: start once it has gone.
    private func call(_ username: String, video: Bool) {
        dismiss()
        Task { try? await Task.sleep(for: .milliseconds(400)); engine.calls.start(peer: username, video: video) }
    }
}

/// Video calls keep the screen on, as FaceTime does: nobody touches the screen while they talk, and Auto-Lock would
/// otherwise dim and lock the iPhone mid-call. Only while the call is up, and only Priva's own screen.
struct KeepsScreenAwake: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .onAppear { UIApplication.shared.isIdleTimerDisabled = active }
            .onChange(of: active) { _, on in UIApplication.shared.isIdleTimerDisabled = on }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

extension View {
    func keepsScreenAwake(_ active: Bool) -> some View { modifier(KeepsScreenAwake(active: active)) }
}
