import CryptoKit
import Foundation
import Network

/// Listens on Priva's rendezvous relay (rendezvous/, Cloudflare): one WebSocket per topic, receive only, sending
/// is `PrivaAPI.broadcast`. Every connection carries today's relay pass (a Priva buyer, unlinkable to the purchase)
/// and proves it owns the topic: the relay hands a topic to the first key that listens on it, and these keys are
/// derived from secrets only this phone holds (for a friend's announcement topic, only that friend's friends).
nonisolated final class RealtimeClient: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    enum Status: Sendable, Equatable { case disconnected, connecting, connected }
    typealias MessageHandler = @Sendable (_ topic: String, _ event: String, _ data: Data) -> Void
    typealias StatusHandler = @Sendable (Status) -> Void

    private final class Socket {
        let task: URLSessionWebSocketTask
        var open = false
        var awaitingPong = false
        init(_ task: URLSessionWebSocketTask) { self.task = task }
    }

    private let q = DispatchQueue(label: "priva.realtime")
    /// A URLSession holds its delegate (us) strongly until invalidated: it exists only while we want to be
    /// connected, so a locked engine's client is actually released.
    private var session: URLSession?
    private var keys: [String: Curve25519.Signing.PrivateKey] = [:]
    private var sockets: [String: Socket] = [:]
    private var starting: Set<String> = []
    private var backoff: [String: TimeInterval] = [:]
    private var heartbeat: DispatchSourceTimer?
    private var wantConnected = false
    private var status: Status = .disconnected
    private let monitor = NWPathMonitor()
    var onMessage: MessageHandler?
    var onStatus: StatusHandler?
    /// A topic's socket is open: signals sent to it now reach us.
    var onJoined: (@Sendable (String) -> Void)?
    /// The relay refused a topic (403: another key owns it; 401: no valid pass). Tests and diagnostics.
    private(set) var refusals: [String: Int] = [:]

    override init() {
        super.init()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self, path.status == .satisfied else { return }
            self.q.async {
                guard self.wantConnected else { return }
                for t in self.keys.keys where self.sockets[t]?.open != true { self.backoff[t] = nil; self.restart(t) }
            }
        }
        monitor.start(queue: q)
        LiveObjects.born("RealtimeClient")
    }

    deinit { monitor.cancel(); LiveObjects.died("RealtimeClient") }

    private func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.tlsMinimumSupportedProtocolVersion = .TLSv13
        cfg.httpCookieAcceptPolicy = .never
        cfg.urlCache = nil
        NetworkPrivacy.current.apply(to: cfg)
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    func connect() {
        q.async {
            self.wantConnected = true
            self.startHeartbeat()
            for t in self.keys.keys { self.open(t) }
            self.updateStatus()
        }
    }

    /// Onion mode changed: drop every socket and reconnect through the new route.
    func reconfigure() {
        q.async {
            self.closeAll()
            self.session?.invalidateAndCancel()
            self.session = nil
            guard self.wantConnected else { return }
            for t in self.keys.keys { self.open(t) }
            self.updateStatus()
        }
    }

    func disconnect() {
        q.async {
            self.wantConnected = false
            self.heartbeat?.cancel()
            self.heartbeat = nil
            self.closeAll()
            self.session?.invalidateAndCancel()
            self.session = nil
            self.updateStatus()
        }
    }

    /// The topics to listen on, each with the key that owns it.
    func setTopics(_ topics: [String: Curve25519.Signing.PrivateKey]) {
        q.async {
            let removed = Set(self.keys.keys).subtracting(topics.keys)
            self.keys = topics
            for t in removed { self.close(t) }
            if self.wantConnected { for t in topics.keys { self.open(t) } }
            self.updateStatus()
        }
    }

    /// Tests and probes: listen with fresh keys (each topic then belongs to that key).
    func setTopics(_ topics: Set<String>) {
        setTopics(Dictionary(uniqueKeysWithValues: topics.map { ($0, Curve25519.Signing.PrivateKey()) }))
    }

    var isConnected: Bool { q.sync { status == .connected } }
    func joinedTopics() -> Set<String> { q.sync { Set(sockets.filter { $0.value.open }.keys) } }
    func refusal(for topic: String) -> Int? { q.sync { refusals[topic] } }

    // MARK: internals (on q)

    private func updateStatus() {
        let s: Status = !wantConnected ? .disconnected : sockets.values.contains { $0.open } ? .connected : .connecting
        guard s != status else { return }
        status = s
        onStatus?(s)
    }

    private func open(_ topic: String) {
        guard wantConnected, sockets[topic] == nil, !starting.contains(topic), let key = keys[topic] else { return }
        starting.insert(topic)
        Task.detached(priority: .userInitiated) { [weak self] in
            let pass = await RelayPass.header()
            guard let self else { return }
            self.q.async { self.start(topic, key: key, pass: pass) }
        }
    }

    private func start(_ topic: String, key: Curve25519.Signing.PrivateKey, pass: String?) {
        starting.remove(topic)
        guard wantConnected, keys[topic] != nil, sockets[topic] == nil else { return }
        guard let pass else { retry(topic, after: nextDelay(topic)); return }
        var c = URLComponents(url: PrivaConfig.relayURL.appendingPathComponent("connect"), resolvingAgainstBaseURL: false)!
        c.scheme = "wss"
        c.queryItems = [URLQueryItem(name: "topic", value: topic)]
        var req = URLRequest(url: c.url!)
        req.setValue(pass, forHTTPHeaderField: "Authorization")
        let ts = Int((Date().timeIntervalSince1970 + ServerClock.offset).rounded())
        guard let sig = try? key.signature(for: Data("priva-listen-v1|\(topic)|\(ts)".utf8)) else { return }
        req.setValue("\(Self.b64url(key.publicKey.rawRepresentation)).\(ts).\(Self.b64url(sig))", forHTTPHeaderField: "X-Priva-Listen")
        #if DEBUG
        WireTap.record("ws-open", Data(c.url!.absoluteString.utf8))
        #endif
        let s = session ?? makeSession()
        session = s
        let t = s.webSocketTask(with: req)
        t.maximumMessageSize = 1 << 20
        sockets[topic] = Socket(t)
        t.resume()
        receive(topic, on: t)
    }

    private func close(_ topic: String) {
        sockets.removeValue(forKey: topic)?.task.cancel(with: .goingAway, reason: nil)
        starting.remove(topic)
    }

    private func closeAll() {
        for t in Array(sockets.keys) { close(t) }
        starting.removeAll()
    }

    private func restart(_ topic: String) {
        close(topic)
        open(topic)
    }

    private func nextDelay(_ topic: String) -> TimeInterval {
        let d = backoff[topic] ?? 0.5
        backoff[topic] = min(d * 2, 30)
        return d * Double.random(in: 0.8...1.2)
    }

    private func retry(_ topic: String, after delay: TimeInterval) {
        q.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.wantConnected, self.sockets[topic] == nil else { return }
            self.open(topic)
        }
    }

    /// The socket ended (or never opened): reconnect with backoff, a refusal backs off for longer.
    private func failed(_ topic: String, task: URLSessionWebSocketTask) {
        guard sockets[topic]?.task === task else { return }
        sockets[topic] = nil
        let code = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { refusals[topic] = code }
        if code == 401 { RelayPass.discardToday() }
        updateStatus()
        guard wantConnected, keys[topic] != nil else { return }
        retry(topic, after: code == 403 ? 600 : nextDelay(topic))
    }

    private func receive(_ topic: String, on t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            self.q.async {
                guard self.sockets[topic]?.task === t else { return }
                switch result {
                case .failure:
                    self.failed(topic, task: t)
                case .success(let msg):
                    switch msg {
                    case .data(let frame): self.deliver(frame, topic: topic)
                    case .string: break
                    @unknown default: break
                    }
                    self.receive(topic, on: t)
                }
            }
        }
    }

    /// Frame: [event length (1)] [event (utf-8)] [payload].
    private func deliver(_ frame: Data, topic: String) {
        #if DEBUG
        WireTap.record("ws-in", frame)
        #endif
        let f = frame.detached
        guard let n = f.first, f.count > 1 + Int(n), f.count <= 256 * 1024 + 32 else { return }
        let event = String(decoding: f[1..<(1 + Int(n))], as: UTF8.self)
        onMessage?(topic, event, f.subdata(in: (1 + Int(n))..<f.count))
    }

    /// A WebSocket protocol ping every 25 s per socket: Cloudflare doesn't bill incoming protocol pings (an application
    /// "ping" message would count as a request). No pong by the next tick means the
    /// connection is dead: reconnect it. URLSession only reads the pong while a receive is pending: `receive(_:on:)`
    /// always keeps one (RelaySecurityTests.testTheRelayAnswersProtocolPings).
    private func startHeartbeat() {
        heartbeat?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: q)
        timer.schedule(deadline: .now() + 25, repeating: 25)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            for (topic, s) in self.sockets where s.open {
                if s.awaitingPong { self.restart(topic); continue }
                s.awaitingPong = true
                let task = s.task
                task.sendPing { [weak self] error in
                    guard let self else { return }
                    self.q.async {
                        guard let s = self.sockets[topic], s.task === task else { return }
                        if error == nil { s.awaitingPong = false } else { self.failed(topic, task: task) }
                    }
                }
            }
        }
        timer.resume()
        heartbeat = timer
    }

    private static func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        q.async {
            guard let (topic, s) = self.sockets.first(where: { $0.value.task === webSocketTask }) else { return }
            s.open = true
            self.backoff[topic] = nil
            self.refusals[topic] = nil
            self.updateStatus()
            self.onJoined?(topic)
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        q.async {
            guard let topic = self.sockets.first(where: { $0.value.task === webSocketTask })?.key else { return }
            self.failed(topic, task: webSocketTask)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        q.async {
            guard let ws = task as? URLSessionWebSocketTask,
                  let topic = self.sockets.first(where: { $0.value.task === ws })?.key else { return }
            self.failed(topic, task: ws)
        }
    }
}

/// Keys that own relay topics: derived per topic, so the relay can't link a phone's topics by key.
nonisolated enum ListenKey {
    /// `secret`: the identity seed for this phone's own topics; a friend's announce key for their announcement topic.
    static func derive(_ secret: Data, topic: String) -> Curve25519.Signing.PrivateKey {
        // 32 bytes is always a valid Ed25519 seed.
        try! Curve25519.Signing.PrivateKey(rawRepresentation: KDF.derive(secret, info: "priva/listen/v1|" + topic, count: 32))
    }
}
