import Foundation

/// The deployment this build talks to: .env → scripts/configure.sh → build settings → Info.plist. None of it is
/// secret (it ships inside the app), but it's the operator's, so it isn't in the source.
nonisolated enum PrivaConfig {
    private static let supabase = URL(string: "https://" + value("PrivaSupabaseHost"))!
    /// Publishable (client-safe) key. Grants nothing but the public RPC and edge functions.
    static let publishableKey = value("PrivaSupabasePublishableKey")
    static let defaultICEServers = ["stun:stun.cloudflare.com:3478", "stun:stun.cloudflare.com:53"]
    /// The rendezvous relay (rendezvous/, Cloudflare Workers + Durable Objects): passes signals between phones,
    /// stores nothing, and only admits Priva buyers (relay passes) listening on topics they own.
    private static let relay = URL(string: "https://" + value("PrivaRelayHost"))!
    #if DEBUG
    static var supabaseURL: URL { Outage.isDown(.supabase) ? Outage.deadEnd : supabase }
    static var relayURL: URL { Outage.isDown(.relay) ? Outage.deadEnd : relay }
    #else
    static var supabaseURL: URL { supabase }
    static var relayURL: URL { relay }
    #endif
    /// SHA-256 of the registration-token and relay-pass signing keys BlindToken and RelayPass accept: the active key
    /// and a standby kept offline, so the server can switch keys (one lost or leaked) without an app update.
    static let tokenKeyIDs = list("PrivaTokenKeyID")
    static let passKeyIDs = list("PrivaPassKeyID")

    private static func list(_ key: String) -> Set<String> {
        Set(value(key).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    private static func value(_ key: String) -> String {
        guard let v = Bundle.main.object(forInfoDictionaryKey: key) as? String, !v.isEmpty, !v.hasPrefix("$(") else {
            fatalError("\(key) isn't set: fill in .env and run scripts/configure.sh")   // the build checks this first
        }
        return v
    }
}

#if DEBUG
/// Tests (OutageTests): a server goes down for every phone in the process, as in a real outage. Its address then
/// leads nowhere, connections are refused, until it's back.
nonisolated enum Outage {
    enum Server: Hashable { case supabase, relay }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var down: Set<Server> = []
    static let deadEnd = URL(string: "https://127.0.0.1:9")!
    static func isDown(_ s: Server) -> Bool { lock.withLock { down.contains(s) } }
    static func set(_ s: Server, down isDown: Bool) { lock.withLock { if isDown { down.insert(s) } else { down.remove(s) } } }
}
#endif

nonisolated enum APIError: Error, Equatable {
    case http(Int, String?)
    case network
    case invalidResponse
    case bundleMismatch
}

/// All traffic: ephemeral sessions (no cookies, no cache, no credential storage), TLS 1.3 only.
/// On iOS 26 URLSession negotiates hybrid post-quantum TLS (X25519MLKEM768) when the edge supports it.
nonisolated final class PrivaAPI: Sendable {
    static let shared = PrivaAPI()

    private let lock = NSLock()
    nonisolated(unsafe) private var cachedSession: (String, URLSession)?

    /// Rebuilt whenever the route changes (onion mode toggled, Tor's port known), so no request
    /// ever takes a stale, or direct, route.
    private var session: URLSession {
        lock.lock(); defer { lock.unlock() }
        let key = NetworkPrivacy.current.routeKey
        if let c = cachedSession, c.0 == key { return c.1 }
        cachedSession?.1.invalidateAndCancel()
        let s = Self.makeSession()
        cachedSession = (key, s)
        return s
    }

    /// `isolated`: a session of its own, on its own Tor circuit in onion mode, for a call that must not be linked to
    /// any other (purchase proofs, registration: audit SEC-02).
    static func makeSession(isolated: Bool = false) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        NetworkPrivacy.current.apply(to: cfg, isolation: isolated ? "priva-" + Bytes.random(8).hex : nil)
        cfg.tlsMinimumSupportedProtocolVersion = .TLSv13
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpShouldSetCookies = false
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.timeoutIntervalForRequest = 20
        cfg.waitsForConnectivity = false
        cfg.httpAdditionalHeaders = ["User-Agent": "Priva"]
        #if DEBUG
        if let stubs = debugProtocolClasses { cfg.protocolClasses = stubs + (cfg.protocolClasses ?? []) }
        #endif
        return URLSession(configuration: cfg)
    }

    #if DEBUG
    /// Tests: answer requests from a URLProtocol stub instead of the network (server failure modes, audit TST-01).
    nonisolated(unsafe) static var debugProtocolClasses: [AnyClass]? {
        didSet { shared.lock.lock(); shared.cachedSession = nil; shared.lock.unlock() }
    }
    #endif

    init() {}

    private func request(_ path: String, method: String = "POST", json: [String: Any]? = nil,
                         session override: URLSession? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: PrivaConfig.supabaseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue(PrivaConfig.publishableKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let json { req.httpBody = try JSONSerialization.data(withJSONObject: json) }
        #if DEBUG
        WireTap.record("https", Data((req.url?.absoluteString ?? "").utf8) + (req.httpBody ?? Data()))
        #endif
        let data: Data, resp: URLResponse
        let sent = Date()
        do { (data, resp) = try await (override ?? session).data(for: req) } catch { throw APIError.network }
        ServerClock.observe(resp, sentAt: sent)
        guard let http = resp as? HTTPURLResponse else { throw APIError.invalidResponse }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(http.statusCode) else { throw APIError.http(http.statusCode, obj["error"] as? String) }
        return obj
    }

    // MARK: relay

    /// Short-lived TURN credentials from Priva's relay (nil when none is configured: 204). Needs today's relay pass,
    /// like every other relay request, so only someone who bought Priva can get them.
    func relayServers() async throws -> (servers: [ManagedRelay.Server], ttl: TimeInterval)? {
        guard let pass = await RelayPass.header() else { throw APIError.network }
        var req = URLRequest(url: PrivaConfig.relayURL.appendingPathComponent("turn"))
        req.httpMethod = "POST"
        req.setValue(pass, forHTTPHeaderField: "Authorization")
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: req) } catch { throw APIError.network }
        guard let http = resp as? HTTPURLResponse else { throw APIError.invalidResponse }
        if http.statusCode == 204 { return nil }                                 // none configured
        if http.statusCode == 404 { return try await legacyRelayServers() }      // the relay has no /turn yet
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { RelayPass.discardToday() }
            throw APIError.http(http.statusCode, nil)
        }
        return Self.parseRelay((try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
    }

    /// Until the relay Worker with `/turn` is deployed (LAUNCH_CHECKLIST step 3): the old Supabase function. Once that
    /// function is deleted it answers 404 and this returns nil.
    private func legacyRelayServers() async throws -> (servers: [ManagedRelay.Server], ttl: TimeInterval)? {
        let r: [String: Any]
        do { r = try await request("functions/v1/turn", json: [:]) } catch APIError.http(404, _) { return nil }
        return Self.parseRelay(r)
    }

    private static func parseRelay(_ r: [String: Any]) -> (servers: [ManagedRelay.Server], ttl: TimeInterval)? {
        guard let list = r["iceServers"] as? [[String: Any]] else { return nil }
        let servers = list.prefix(4).compactMap { s -> ManagedRelay.Server? in
            guard let urls = s["urls"] as? [String], let u = s["username"] as? String, let c = s["credential"] as? String else { return nil }
            let turn = urls.filter { $0.hasPrefix("turn:") || $0.hasPrefix("turns:") }.prefix(6)
            return turn.isEmpty ? nil : ManagedRelay.Server(urls: Array(turn), username: u, credential: c)
        }
        guard !servers.isEmpty else { return nil }
        return (servers, min(24 * 3600, max(600, r["ttl"] as? Double ?? 3600)))
    }

    // MARK: purchase → token → username

    func issuerPublicKey() async throws -> Data {
        let r = try await request("functions/v1/issue-token", method: "GET")
        guard let b64 = r["public_key"] as? String, let d = Data(base64Encoded: b64) else { throw APIError.invalidResponse }
        return d
    }

    func issueToken(jws: String?, devNonce: Data?, blinded: Data) async throws -> Data {
        let isolated = Self.makeSession(isolated: true)
        defer { isolated.invalidateAndCancel() }
        var body: [String: Any] = ["blinded": blinded.base64EncodedString()]
        if let jws { body["jws"] = jws }
        if let devNonce {
            body["dev_nonce"] = devNonce.base64EncodedString()
            body["dev_proof"] = PurchaseService.developmentProof(devNonce)
        }
        let r = try await request("functions/v1/issue-token", json: body, session: isolated)
        guard let s = r["blind_sig"] as? String, let d = Data(base64Encoded: s) else { throw APIError.invalidResponse }
        return d
    }

    /// Uses a brand-new URLSession so this call shares no connection with the purchase call.
    /// Sends only the username's commitment: the plaintext name never leaves the device.
    func register(ucommit: Data, bundle: KeyBundle, token: BlindToken.Redeemable, revokeHash: String) async throws {
        let isolated = Self.makeSession(isolated: true)
        defer { isolated.invalidateAndCancel() }
        _ = try await request("functions/v1/register", json: [
            "ucommit": ucommit.hex, "bundle": bundle.raw.base64EncodedString(), "revoke_hash": revokeHash,
            "token": token.token.base64EncodedString(), "token_sig": token.signature.base64EncodedString(),
        ], session: isolated)
    }

    // MARK: directory (identity v2, docs/IDENTITY_DESIGN.md)

    struct DirectoryEntry: Sendable, Equatable {
        enum Status: Sendable, Equatable { case active, uninstalled, removed }
        let status: Status
        let leaseWeek: Date?
        let bundle: KeyBundle?
    }

    /// The device decides what a row means: lapsed leases are treated as uninstalled (no server job).
    static func evaluate(status: String?, leaseWeek: Date?, now: Date = .now) -> DirectoryEntry.Status {
        guard let status else { return .removed }
        if status != "active" { return .uninstalled }
        if let lw = leaseWeek, lw.addingTimeInterval(7 * 86_400) < now { return .uninstalled }
        return .active
    }

    private static let weekFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    #if DEBUG
    private static let debugLock = NSLock()
    nonisolated(unsafe) private static var debugCounters: [String: Int] = [:]
    static func debugCount(_ k: String, by n: Int = 1) { debugLock.lock(); debugCounters[k, default: 0] += n; debugLock.unlock() }
    /// Tests only: outcomes of rendezvous broadcasts (per HTTP status, counted in messages).
    static var debugBroadcastStats: [String: Int] { debugLock.lock(); defer { debugLock.unlock() }; return debugCounters }

    /// Tests only: answer directory lookups as a compromised server would.
    nonisolated(unsafe) static var debugDirectoryOverride: (@Sendable (Data) -> DirectoryEntry?)?
    #endif

    func lookup(commit: Data) async throws -> DirectoryEntry {
        #if DEBUG
        if let o = Self.debugDirectoryOverride, let forged = o(commit) { return forged }
        #endif
        var req = URLRequest(url: PrivaConfig.supabaseURL.appendingPathComponent("rest/v1/rpc/lookup_directory"))
        req.httpMethod = "POST"
        req.setValue(PrivaConfig.publishableKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["p_commit": commit.hex])
        #if DEBUG
        WireTap.record("https", Data((req.url?.absoluteString ?? "").utf8) + (req.httpBody ?? Data()))
        #endif
        let data: Data, resp: URLResponse
        let sent = Date()
        do { (data, resp) = try await session.data(for: req) } catch { throw APIError.network }
        ServerClock.observe(resp, sentAt: sent)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, nil)
        }
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw APIError.invalidResponse }
        guard let row = rows.first else { return DirectoryEntry(status: .removed, leaseWeek: nil, bundle: nil) }
        let lease = (row["lease_week"] as? String).flatMap { Self.weekFormatter.date(from: $0) }
        var bundle: KeyBundle?
        if let b64 = row["bundle"] as? String, let raw = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) {
            let b = try KeyBundle.parse(raw)
            guard Bytes.equal(b.ucommit, commit) else { throw APIError.bundleMismatch }
            bundle = b
        }
        return DirectoryEntry(status: Self.evaluate(status: row["status"] as? String, leaseWeek: lease), leaseWeek: lease, bundle: bundle)
    }

    /// Exact-username lookup. The commitment is computed here, on the device (memory-hard, ~0.1–0.5 s).
    /// Opens the connection to the directory ahead of a search (it carries no data): a fresh connection costs two
    /// extra round trips before the lookup's own (≈ 0.98 s cold vs 0.54 s warm, measured to the project's region).
    /// At most every 30 s; goes through Tor or the proxy like everything else.
    func warmUp() {
        let now = Date()
        Self.warmLock.lock()
        defer { Self.warmLock.unlock() }
        guard now.timeIntervalSince(Self.lastWarm) > 30 else { return }
        Self.lastWarm = now
        var req = URLRequest(url: PrivaConfig.supabaseURL.appendingPathComponent("rest/v1/"))
        req.httpMethod = "HEAD"
        req.setValue(PrivaConfig.publishableKey, forHTTPHeaderField: "apikey")
        let session = self.session
        Task.detached(priority: .utility) { _ = try? await session.data(for: req) }
    }
    nonisolated(unsafe) private static var lastWarm = Date.distantPast
    private static let warmLock = NSLock()

    func lookup(_ username: String) async throws -> DirectoryEntry {
        let name = Username.normalize(username)
        let commit = await Task.detached(priority: .userInitiated) { UsernameKey.commitment(name) }.value
        return try await lookup(commit: commit)
    }

    private func signedDirectoryOp(op: UInt8, ucommit: Data, newBundle: Data?, identity: IdentityKeys) throws -> (Int64, Data) {
        let ts = Signal.now          // server-corrected: the directory checks it against its own clock
        var m = Data("PRIVA-DIR-OP-v2\0".utf8)
        m.append(op)
        m.append(ucommit)
        m.appendBE(UInt64(ts))
        m.append(KDF.sha512(newBundle ?? Data()))
        return (ts, try identity.signing.sign(m))
    }

    /// Extends the lease ("still installed"). The device decides when.
    func renew(ucommit: Data, identity: IdentityKeys) async throws {
        let (ts, sig) = try signedDirectoryOp(op: 1, ucommit: ucommit, newBundle: nil, identity: identity)
        _ = try await request("functions/v1/directory", json: ["op": "renew", "ucommit": ucommit.hex, "ts": ts, "sig": sig.base64EncodedString()])
    }

    /// "Leave Priva": marks the username uninstalled right now and erases its public keys.
    func retire(ucommit: Data, identity: IdentityKeys) async throws {
        let (ts, sig) = try signedDirectoryOp(op: 2, ucommit: ucommit, newBundle: nil, identity: identity)
        _ = try await request("functions/v1/directory", json: ["op": "retire", "ucommit": ucommit.hex, "ts": ts, "sig": sig.base64EncodedString()])
    }

    /// Deletes a previous username (sign back in). Needs only the revocation secret.
    func revoke(ucommit: Data, secret: Data) async throws {
        let isolated = Self.makeSession(isolated: true)
        defer { isolated.invalidateAndCancel() }
        _ = try await request("functions/v1/directory", json: ["op": "revoke", "ucommit": ucommit.hex, "secret": secret.base64EncodedString()],
                              session: isolated)
    }

    // MARK: relay passes (functions/relay-pass)

    func relayPassKey() async throws -> Data {
        let r = try await request("functions/v1/relay-pass", method: "GET")
        guard let b64 = r["public_key"] as? String, let d = Data(base64Encoded: b64) else { throw APIError.invalidResponse }
        return d
    }

    /// Blind-signs a batch of passes after the same purchase check as registration (the server never sees a pass).
    func relayPasses(proof: PurchaseService.Proof, blinded: [Data]) async throws -> [Data] {
        var body: [String: Any] = ["blinded": blinded.map { $0.base64EncodedString() }]
        switch proof {
        case .appStore(let jws): body["jws"] = jws
        case .development(let nonce):
            body["dev_nonce"] = nonce.base64EncodedString()
            body["dev_proof"] = PurchaseService.developmentProof(nonce)
        }
        let r = try await request("functions/v1/relay-pass", json: body)
        guard let list = r["blind_sigs"] as? [String], list.count == blinded.count else { throw APIError.invalidResponse }
        return try list.map { guard let d = Data(base64Encoded: $0) else { throw APIError.invalidResponse }; return d }
    }

    // MARK: rendezvous (the relay; see RealtimeClient for listening)

    struct Outbound: Sendable { let topic: String; let event: String; let data: Data }

    func broadcast(_ messages: [Outbound]) async throws {
        guard !messages.isEmpty else { return }
        guard let pass = await RelayPass.header() else {
            #if DEBUG
            Self.debugCount("relay-nopass")
            #endif
            throw APIError.network
        }
        let body: [String: Any] = ["messages": messages.map {
            ["topic": $0.topic, "event": $0.event, "d": $0.data.base64EncodedString()]
        }]
        var req = URLRequest(url: PrivaConfig.relayURL.appendingPathComponent("send"))
        req.httpMethod = "POST"
        req.setValue(pass, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        #if DEBUG
        WireTap.record("https", Data((req.url?.absoluteString ?? "").utf8) + (req.httpBody ?? Data()))
        #endif
        let resp: URLResponse
        do { (_, resp) = try await session.data(for: req) } catch {
            #if DEBUG
            Self.debugCount("broadcast-error")
            #endif
            throw APIError.network
        }
        // The relay doesn't steer the protocol clock: only Supabase does (audit SEC-25).
        #if DEBUG
        Self.debugCount("broadcast-\((resp as? HTTPURLResponse)?.statusCode ?? 0)", by: messages.count)
        for m in messages { Self.debugCount("bytes:\(m.event)", by: (m.data.count + 2) / 3 * 4) }
        #endif
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 { RelayPass.discardToday() }          // stale or rotated: fetch a fresh one next time
            throw APIError.http(code, nil)
        }
    }
}
