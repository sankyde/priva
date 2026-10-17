import Foundation
import Network

/// Onion mode: route the account plane (directory, tokens) and the rendezvous socket through Tor,
/// the embedded client by default, or the user's own SOCKS5 proxy. Fail-closed: until the route is up,
/// nothing falls back to a direct connection.
///
/// Stored outside the vault (device-only Keychain) because onboarding and unlock already talk to
/// the directory before the encrypted store is open.
nonisolated struct NetworkPrivacy: Codable, Sendable, Equatable {
    enum Mode: String, Codable, Sendable { case direct, tor, proxy }

    var mode: Mode = .direct
    var host = "127.0.0.1"
    var port = 9050

    var onion: Bool { mode != .direct }

    init(mode: Mode = .direct, host: String = "127.0.0.1", port: Int = 9050) {
        self.mode = mode
        self.host = host
        self.port = port
    }

    private enum CodingKeys: String, CodingKey { case mode, host, port, onion }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? "127.0.0.1"
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 9050
        if let m = try c.decodeIfPresent(Mode.self, forKey: .mode) {
            mode = m
        } else {
            mode = (try c.decodeIfPresent(Bool.self, forKey: .onion) ?? false) ? .proxy : .direct
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mode, forKey: .mode)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
    }

    private static let account = "net.privacy"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: NetworkPrivacy?

    static var current: NetworkPrivacy {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let v = Keychain.getCodable(NetworkPrivacy.self, account: account) ?? NetworkPrivacy()
        cached = v
        return v
    }

    static func save(_ v: NetworkPrivacy) {
        lock.lock()
        cached = v
        lock.unlock()
        try? Keychain.setCodable(v, account: account)
    }

    var isValidProxy: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && (1...65535).contains(port)
    }

    /// Where traffic goes right now. A route that isn't up yet points at a closed loopback port (9), so
    /// requests fail instead of leaking out directly.
    var effectiveProxy: (host: String, port: Int)? {
        switch mode {
        case .direct: return nil
        case .tor:
            let p = TorService.socksPort
            return ("127.0.0.1", p > 0 ? p : 9)
        case .proxy: return isValidProxy ? (host, port) : ("127.0.0.1", 9)
        }
    }

    /// Changes whenever the effective route changes (sessions are rebuilt on change).
    var routeKey: String {
        guard let e = effectiveProxy else { return "direct" }
        return "\(mode.rawValue)|\(e.host):\(e.port)"
    }

    /// Applies the proxy (or nothing) to a session configuration.
    /// `isolation`: calls that must not be linked to each other (a purchase proof, a registration) each get their
    /// own label, and built-in Tor never puts streams with different SOCKS credentials on the same circuit
    /// (IsolateSOCKSAuth), so they leave through different exits (audit SEC-02). Not for the user's own proxy, which
    /// may not accept credentials.
    func apply(to cfg: URLSessionConfiguration, isolation: String? = nil) {
        guard let e = effectiveProxy, let p = NWEndpoint.Port(rawValue: UInt16(e.port)) else { return }
        var proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: .init(e.host), port: p))
        proxy.allowFailover = false          // fail closed: never leak a direct connection
        if let isolation, mode == .tor { proxy.applyCredential(username: isolation, password: "priva") }
        cfg.proxyConfigurations = [proxy]
    }
}
