import AVFoundation
import LiveKitWebRTC

enum WebRTCEnv {
    static let factory: LKRTCPeerConnectionFactory = {
        _ = LKRTCInitializeSSL()
        // Manual audio: the mic and speaker only run while Priva has a call up. A peer renegotiating
        // media outside a call can't make this iPhone play or record anything.
        let audio = LKRTCAudioSession.sharedInstance()
        audio.useManualAudio = true
        audio.isAudioEnabled = false
        let enc = LKRTCDefaultVideoEncoderFactory()
        // Prefer hardware H.264 (VideoToolbox): lowest latency and battery use on iPhone.
        if let h264 = LKRTCDefaultVideoEncoderFactory.supportedCodecs().first(where: { $0.name == "H264" }) {
            enc.preferredCodec = h264
        }
        let factory = LKRTCPeerConnectionFactory(encoderFactory: enc, decoderFactory: LKRTCDefaultVideoDecoderFactory())
        #if DEBUG
        // Stress tests run dozens of phones in one simulator process, and each connection opens sockets on every
        // network interface the Mac has (here ≈ 20, 11 of them VPN tunnels): that, not Priva, ran out of file
        // handles near 60 phones. TEST_RUNNER_PRIVA_LEAN_NET=1 skips VPN, ethernet and cellular adapters.
        if ProcessInfo.processInfo.environment["PRIVA_LEAN_NET"] == "1" {
            let o = LKRTCPeerConnectionFactoryOptions()
            o.ignoreVPNNetworkAdapter = true
            o.ignoreEthernetNetworkAdapter = true
            o.ignoreCellularNetworkAdapter = true
            factory.setOptions(o)
        }
        #endif
        return factory
    }()

    static func configuration(_ s: PrivaSettings) -> LKRTCConfiguration {
        let c = LKRTCConfiguration()
        c.sdpSemantics = .unifiedPlan
        c.bundlePolicy = .maxBundle
        c.rtcpMuxPolicy = .require
        c.continualGatheringPolicy = .gatherContinually
        // Gather as soon as the connection exists (see PeerLink.start): the offer / answer then carry the candidates.
        c.iceCandidatePoolSize = 1
        c.keyType = .ECDSA
        c.enableImplicitRollback = true
        let onion = NetworkPrivacy.current.onion
        // STUN asks a server what our IP is: onion mode never does.
        var servers = onion ? [] : [LKRTCIceServer(urlStrings: PrivaConfig.defaultICEServers)]
        var relays = 0
        if !s.turnURL.isEmpty {
            servers.append(LKRTCIceServer(urlStrings: [s.turnURL], username: s.turnUsername, credential: s.turnCredential))
            relays += 1
        }
        for r in ManagedRelay.servers {
            servers.append(LKRTCIceServer(urlStrings: r.urls, username: r.username, credential: r.credential))
            relays += 1
        }
        c.iceServers = servers
        // "Relay calls" hides both IP addresses from the peer (when a TURN server exists; otherwise it's a fallback).
        // Onion mode is relay-only always: with no relay yet, connections wait instead of showing the peer our IP,
        // hiding it from the server but not from friends would be half a measure (and Tor itself fails closed too).
        // "Relay calls" fails closed too: no relay means waiting, never a direct path that shows the peer our IP
        // (audit SEC-17).
        c.iceTransportPolicy = onion || s.relayCalls ? .relay : .all
        c.cryptoOptions = LKRTCCryptoOptions(
            srtpEnableGcmCryptoSuites: true, srtpPreferGcmCryptoSuites: true,
            srtpEnableAes128Sha1_32CryptoCipher: false, srtpEnableAes128Sha1_80CryptoCipher: true,
            srtpEnableEncryptedRtpHeaderExtensions: true, sframeRequireFrameEncryption: false)
        return c
    }

    static let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: ["DtlsSrtpKeyAgreement": "true"])

    /// Who is using the audio session: a 1:1 call's link, a hosted group call. It switches off only when the last one
    /// is done: a stale link closing (a dropped group member, an old call's session) must not mute a live call.
    private static var audioOwners: Set<ObjectIdentifier> = []
    #if DEBUG
    static var debugAudioOwners: Int { audioOwners.count }
    #endif

    /// Voice-processing I/O (hardware echo cancellation, noise suppression, AGC).
    static func configureAudioSession(video: Bool, owner: AnyObject) {
        audioOwners.insert(ObjectIdentifier(owner))
        let session = LKRTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        let cfg = LKRTCAudioSessionConfiguration.webRTC()
        cfg.category = AVAudioSession.Category.playAndRecord.rawValue
        cfg.mode = (video ? AVAudioSession.Mode.videoChat : AVAudioSession.Mode.voiceChat).rawValue
        cfg.categoryOptions = video ? [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
                                    : [.allowBluetoothHFP, .allowBluetoothA2DP]
        try? session.setConfiguration(cfg)
        try? session.setActive(true)
        session.isAudioEnabled = true
    }

    /// `owner` is done with audio (a no-op if it never claimed it).
    static func releaseAudioSession(owner: AnyObject) {
        guard audioOwners.remove(ObjectIdentifier(owner)) != nil, audioOwners.isEmpty else { return }
        let session = LKRTCAudioSession.sharedInstance()
        session.isAudioEnabled = false
        session.lockForConfiguration()
        try? session.setActive(false)
        session.unlockForConfiguration()
    }

    static func setSpeaker(_ on: Bool) {
        let session = LKRTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        try? session.overrideOutputAudioPort(on ? .speaker : .none)
        session.unlockForConfiguration()
    }
}

#if targetEnvironment(simulator)
/// Simulator stand-in for the camera: renders an animated test pattern at 30 fps so the full
/// encode → frame-encrypt → SRTP → decrypt → decode → render pipeline is exercised end to end.
/// Compiled only for the Simulator.
nonisolated final class SyntheticCapturer: LKRTCVideoCapturer, @unchecked Sendable {
    private let queue = DispatchQueue(label: "priva.synthetic.capture", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var pool: CVPixelBufferPool?
    private var frame: Int64 = 0
    private let width: Int, height: Int
    private let label: String

    /// Tests: capturers alive right now (each holds a pixel-buffer pool; none may outlive its call).
    nonisolated(unsafe) static var live = 0
    private static let liveLock = NSLock()

    deinit { Self.liveLock.lock(); Self.live -= 1; Self.liveLock.unlock() }

    init(delegate: LKRTCVideoCapturerDelegate, width: Int = 1280, height: Int = 720, label: String) {
        self.width = width
        self.height = height
        self.label = label
        Self.liveLock.lock(); Self.live += 1; Self.liveLock.unlock()
        super.init(delegate: delegate)
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
    }

    func start(fps: Int = 30) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / fps), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.emit() }
        t.resume()
        timer = t
    }

    func stop() { timer?.cancel(); timer = nil }

    private func emit() {
        guard let pool else { return }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let pb else { return }
        frame += 1
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb),
           let ctx = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                               bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            let t = CGFloat(frame) / 30
            let colors = [CGColor(red: 0.42, green: 0.36, blue: 1, alpha: 1), CGColor(red: 0.24, green: 0.78, blue: 1, alpha: 1)]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
            let dx = cos(t) * CGFloat(width) * 0.5, dy = sin(t) * CGFloat(height) * 0.5
            ctx.drawLinearGradient(gradient, start: CGPoint(x: CGFloat(width) / 2 - dx, y: CGFloat(height) / 2 - dy),
                                   end: CGPoint(x: CGFloat(width) / 2 + dx, y: CGFloat(height) / 2 + dy), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            // Moving orb + frame counter so motion, latency and dropped frames are visible.
            let r = CGFloat(height) * 0.12
            let cx = CGFloat(width) / 2 + cos(t * 2) * CGFloat(width) * 0.3
            let cy = CGFloat(height) / 2 + sin(t * 3) * CGFloat(height) * 0.25
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
            ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            ctx.setFillColor(CGColor(red: 0.03, green: 0.03, blue: 0.05, alpha: 0.85))
            for i in 0..<30 {
                let on = (frame % 30) == Int64(i)
                ctx.setFillColor(on ? CGColor(red: 0.24, green: 0.86, blue: 0.59, alpha: 1) : CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
                ctx.fill(CGRect(x: 24 + CGFloat(i) * 20, y: 24, width: 14, height: 14))
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        let rtcFrame = LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: pb), rotation: ._0,
                                       timeStampNs: Int64(DispatchTime.now().uptimeNanoseconds))
        delegate?.capturer(self, didCapture: rtcFrame)
    }
}
#endif

/// The project's relay (Cloudflare TURN through the `turn` function, when configured): lets two iPhones behind
/// strict NATs, common on mobile carriers, connect at all. Credentials expire; refreshed at unlock and when
/// half-way to expiry. Without a configured relay this stays empty and Priva connects directly (STUN only).
nonisolated enum ManagedRelay {
    struct Server: Sendable, Equatable { let urls: [String]; let username: String; let credential: String }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _servers: [Server] = []
    nonisolated(unsafe) private static var refreshAt = Date.distantPast
    nonisolated(unsafe) private static var inFlight = false

    static var servers: [Server] { lock.lock(); defer { lock.unlock() }; return Date() < expiresAt ? _servers : [] }
    nonisolated(unsafe) private static var expiresAt = Date.distantPast

    static func refreshIfNeeded() {
        lock.lock()
        guard Date() >= refreshAt, !inFlight else { lock.unlock(); return }
        inFlight = true
        lock.unlock()
        Task.detached(priority: .utility) {
            do { store(.success(try await PrivaAPI.shared.relayServers())) } catch { store(.failure(error)) }
        }
    }

    /// Ask now (e.g. Tor just finished connecting: what failed before it was up can work now).
    static func refresh(force: Bool) {
        if force { lock.withLock { refreshAt = .distantPast } }
        refreshIfNeeded()
    }

    private static func store(_ got: Result<(servers: [Server], ttl: TimeInterval)?, Error>) {
        lock.lock()
        defer { lock.unlock() }
        inFlight = false
        switch got {
        case .success(let got?):
            _servers = got.servers
            expiresAt = Date().addingTimeInterval(got.ttl)
            refreshAt = Date().addingTimeInterval(got.ttl / 2)
        case .success(nil):
            refreshAt = Date().addingTimeInterval(30 * 60)      // none configured: ask again much later
        case .failure:
            // Unreachable (no network yet, Tor still connecting): soon. Relay-only connections wait on this.
            refreshAt = Date().addingTimeInterval(30)
        }
    }

    #if DEBUG
    static func debugReset() { lock.lock(); _servers = []; refreshAt = .distantPast; expiresAt = .distantPast; lock.unlock() }
    static func debugInstall(_ s: [Server], ttl: TimeInterval) {
        lock.lock(); _servers = s; expiresAt = Date().addingTimeInterval(ttl); refreshAt = expiresAt; lock.unlock()
    }
    #endif
}
