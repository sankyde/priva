import Foundation
import Observation
import Tor

/// Embedded Tor client (C tor 0.4.9 via Tor.framework), used by onion mode.
///
/// * One per process: tor can only be started once, so "off" means `DisableNetwork 1`, not a restart.
/// * SOCKS listens on an automatic loopback port; `SafeSocks` refuses IP-addressed requests, so every
///   destination reaches tor as a hostname and DNS never leaves the Tor network.
/// * Control port is loopback-only with cookie authentication (the cookie lives in the app container).
@Observable
final class TorService {
    static let shared = TorService()

    enum State: Equatable {
        case off
        case starting(Int)      // bootstrap percent
        case ready
        case failed(String)
    }

    private(set) var state: State = .off
    @ObservationIgnored private var thread: TorThread?
    @ObservationIgnored private var controller: TorController?
    @ObservationIgnored private var configuration: TorConfiguration?
    @ObservationIgnored private var networkDisabled = false
    /// One per owner: a new engine (every unlock) replaces the last one's instead of adding to a pile (audit STA-37).
    @ObservationIgnored private var readyHandlers: [String: () -> Void] = [:]

    /// Loopback SOCKS port chosen by tor; 0 until tor is ready. Read from any thread by NetworkPrivacy.
    nonisolated static var socksPort: Int { portLock.lock(); defer { portLock.unlock() }; return _socksPort }
    nonisolated private static let portLock = NSLock()
    nonisolated(unsafe) private static var _socksPort = 0
    nonisolated private static func setPort(_ p: Int) { portLock.lock(); _socksPort = p; portLock.unlock() }

    var isReady: Bool { state == .ready }

    #if DEBUG
    /// Development diagnostics: tor's notice log and data directory listing.
    var debugReport: String {
        let dir = Self.directory("tor")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let log = (try? String(contentsOf: dir.appendingPathComponent("tor.log"), encoding: .utf8)) ?? "(no log)"
        return "files=\(files) controlPortFile=\(configuration?.controlPortFile?.path ?? "nil") cookie=\(configuration?.cookie != nil)\n\(log.suffix(3000))"
    }
    #endif

    /// Runs `handler` once tor is ready (immediately if it already is).
    func whenReady(_ owner: String, _ handler: @escaping () -> Void) {
        if isReady { handler() } else { readyHandlers[owner] = handler }
    }

    func start() {
        if thread != nil {
            if networkDisabled { setNetwork(enabled: true) }
            return
        }
        let dir = Self.directory("tor")
        // A previous run leaves its control-port file and auth cookie behind; reading those before tor
        // rewrites them means connecting to a dead port or authenticating with a stale cookie.
        for stale in ["controlport", "control_auth_cookie"] { try? FileManager.default.removeItem(at: dir.appendingPathComponent(stale)) }
        let c = TorConfiguration()
        c.ignoreMissingTorrc = true
        c.cookieAuthentication = true
        c.autoControlPort = true
        c.clientOnly = true
        c.avoidDiskWrites = true
        c.dataDirectory = dir
        c.cacheDirectory = Self.directory("tor-cache", caches: true)
        c.arguments = [
            "--SocksPort", "127.0.0.1:auto",
            "--SafeSocks", "1",
        ]
        #if DEBUG
        c.logfile = dir.appendingPathComponent("tor.log")   // development only; release builds keep no Tor log
        #endif
        configuration = c
        let t = TorThread(configuration: c)
        thread = t
        state = .starting(0)
        t.start()
        connectController(attempt: 0)
    }

    /// Onion mode switched off: keep tor alive (it can't restart in-process) but stop all its traffic.
    func stop() {
        guard thread != nil else { return }
        setNetwork(enabled: false)
        state = .off
        Self.setPort(0)
    }

    private func setNetwork(enabled: Bool) {
        networkDisabled = !enabled
        if enabled { state = .starting(0) }
        controller?.setConfForKey("DisableNetwork", withValue: enabled ? "0" : "1") { @Sendable [weak self] _, _ in
            guard enabled else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.checkEstablished() } }
        }
    }

    // MARK: control port

    private func connectController(attempt: Int) {
        guard let c = configuration else { return }
        // tor writes the control-port file shortly after its thread starts.
        // (TorController's initializer connects by itself.)
        guard let file = c.controlPortFile, FileManager.default.fileExists(atPath: file.path), let cookie = c.cookie,
              case let ctl = TorController(controlPortFile: file), ctl.isConnected else {
            if attempt > 150 { state = .failed("Tor didn't start"); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.connectController(attempt: attempt + 1) }
            return
        }
        controller = ctl
        ctl.authenticate(with: cookie) { @Sendable [weak self] ok, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard ok, let ctl = self.controller else {
                        // The cookie can still be mid-write right after tor starts: reconnect and retry.
                        self.controller?.disconnect()
                        self.controller = nil
                        if attempt > 150 { self.state = .failed("Couldn't authenticate to Tor"); return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.connectController(attempt: attempt + 1) }
                        return
                    }
                    self.observe(ctl)
                }
            }
        }
    }

    private func observe(_ ctl: TorController) {
        // Callbacks arrive on the controller's queue: @Sendable (not main-actor isolated), then hop to main.
        _ = ctl.addObserver(forStatusEvents: { @Sendable [weak self] type, _, action, args in
            guard type == "STATUS_CLIENT", action == "BOOTSTRAP", let p = args?["PROGRESS"].flatMap(Int.init) else { return false }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.networkDisabled, self.state != .ready else { return }
                    self.state = .starting(p)
                }
            }
            return false
        })
        _ = ctl.addObserver(forCircuitEstablished: { @Sendable [weak self] established in
            guard established else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.checkEstablished() } }
        })
        checkEstablished()
    }

    /// Circuit up → learn the SOCKS port tor picked, then release everyone waiting.
    private func checkEstablished() {
        controller?.getInfoForKeys(["status/circuit-established", "net/listeners/socks"]) { @Sendable [weak self] values in
            let up = values.first == "1"
            let port = values.count > 1 ? Self.parsePort(values[1]) : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.networkDisabled else { return }
                    guard up, let port else { return }
                    Self.setPort(port)
                    self.state = .ready
                    let handlers = self.readyHandlers
                    self.readyHandlers.removeAll()
                    handlers.values.forEach { $0() }
                }
            }
        }
    }

    /// `"127.0.0.1:53211"` (possibly several, space-separated) → 53211.
    nonisolated static func parsePort(_ listeners: String) -> Int? {
        for item in listeners.split(separator: " ") {
            let s = item.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard s.hasPrefix("127.0.0.1:"), let p = Int(s.dropFirst("127.0.0.1:".count)), (1...65535).contains(p) else { continue }
            return p
        }
        return nil
    }

    private static func directory(_ name: String, caches: Bool = false) -> URL {
        let base = FileManager.default.urls(for: caches ? .cachesDirectory : .applicationSupportDirectory, in: .userDomainMask)[0]
        var url = base.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
                                                              .posixPermissions: 0o700])
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? url.setResourceValues(rv)
        return url
    }
}
