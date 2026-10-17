import Foundation

/// Daily passes for the rendezvous relay: "this is a Priva buyer" without saying which one. Once a month the phone
/// proves its App Store purchase to functions/relay-pass, the same check as registration, and gets a batch of
/// passes blind-signed (RFC 9474): the server signs without seeing them, so a pass the relay later sees can't be
/// tied to the purchase or the username. Each pass is good for one day; the relay refuses anything without one.
nonisolated enum RelayPass {
    /// SHA-256 of the pass keys' SubjectPublicKeyInfo: the active one and a standby (pinned here and in the relay's
    /// configuration).
    static let pinnedKeyIDs = PrivaConfig.passKeyIDs
    static let prefix = Data("PRIVA-PASS-v1".utf8)
    /// One month at a time; topped up when fewer than a week remain.
    static let batch = 35
    static let refillBelow = 7

    struct Stored: Codable, Sendable { let day: Int; let token: Data; let signature: Data }

    private static let account = "relay.passes"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var inFlight: Task<Void, Never>?
    /// After a failed fetch nobody asks again before this (1 min doubling to 1 h; a used-up month waits for the next
    /// UTC day). Every signal used to trigger a fresh App Store proof and issuer call (STA-13).
    nonisolated(unsafe) private static var retryAt = Date.distantPast
    nonisolated(unsafe) private static var failures = 0

    /// Days since 1970 (UTC), on the server's clock.
    static var today: Int {
        let now = ServerClock.serverNow?.timeIntervalSince1970 ?? (Date().timeIntervalSince1970 + ServerClock.offset)
        return Int(floor(now / 86_400))
    }

    /// Kept in memory after the first read: every broadcast and socket open asks (audit STA-38).
    nonisolated(unsafe) private static var cache: [Stored]?
    static var stored: [Stored] { lock.withLock { storedLocked() } }
    private static func storedLocked() -> [Stored] {
        if let cache { return cache }
        let s = Keychain.getCodable([Stored].self, account: account) ?? []
        cache = s
        return s
    }
    private static func writeLocked(_ s: [Stored]) {
        try? Keychain.setCodable(s, account: account)
        cache = s
    }

    /// `Authorization` value for today's pass, fetching a new batch first when needed.
    static func header() async -> String? {
        let day = today
        let have = stored.filter { $0.day >= day }
        if let pass = have.first(where: { $0.day == day }) {
            if have.count < refillBelow { Task.detached(priority: .utility) { await refill() } }
            return format(pass)
        }
        await refill()
        return stored.first { $0.day == day }.map(format)
    }

    /// A fresh batch unless at least two weeks' worth are already here: called with the purchase check at sign-up
    /// and restore, so no purchase proof goes out right after the username is registered (audit SEC-02).
    static func prefetch() async {
        let day = today
        guard stored.filter({ $0.day >= day }).count < 14 else { return }
        await refill()
    }

    nonisolated(unsafe) private static var discards: [Date] = []

    /// The relay refused today's pass (e.g. the key was rotated): forget it so the next request fetches anew. Refused
    /// again soon after means something else is wrong (a relay that refuses every pass): then the next batch waits,
    /// 10 min → 30 min → … 6 h, instead of spending the month's passes in minutes (audit TST-03).
    static func discardToday() {
        let day = today
        lock.withLock {
            writeLocked(storedLocked().filter { $0.day != day })
            discards = discards.filter { $0.timeIntervalSinceNow > -86_400 } + [.now]
            if let wait = waitAfter(discards: discards.count) { retryAt = max(retryAt, Date().addingTimeInterval(wait)) }
        }
    }

    /// How long a refill waits after the `n`-th refused pass in a day: nil (at once) for the first.
    static func waitAfter(discards n: Int) -> TimeInterval? {
        n <= 1 ? nil : min(6 * 3600, 600 * pow(3, Double(n - 2)))
    }

    private static func save(_ fresh: [Stored], keepingFrom oldest: Int) {
        lock.withLock {
            var byDay = Dictionary(storedLocked().filter { $0.day >= oldest }.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
            for p in fresh { byDay[p.day] = p }
            writeLocked(byDay.values.sorted { $0.day < $1.day })
        }
    }

    private static func format(_ p: Stored) -> String { "Pass " + (p.token + p.signature).base64EncodedString() }

    /// One fetch at a time, however many callers are waiting.
    static func refill() async {
        let task = lock.withLock { () -> Task<Void, Never>? in
            if let t = inFlight { return t }
            guard Date() >= retryAt else { return nil }
            let t = Task.detached(priority: .userInitiated) { await fetch() }
            inFlight = t
            return t
        }
        guard let task else { return }
        await task.value
        lock.withLock { inFlight = nil }
    }

    private static func failed(_ error: Error) {
        #if DEBUG
        // Debug builds prove a stand-in purchase (no App Store receipt): when its month's passes are used up, heavy
        // test runs do that, a new stand-in takes over instead of leaving every test without the relay until next
        // month. A real purchase (Release) keeps its limit.
        if case APIError.http(429, _) = error, PurchaseService.developmentNonce != nil {
            PurchaseService.developmentNonce = Bytes.random(32)
            lock.withLock { retryAt = .distantPast }
            return
        }
        #endif
        lock.withLock {
            failures += 1
            if case APIError.http(429, _) = error {           // this month's passes are used up
                retryAt = Date(timeIntervalSince1970: Double(today + 1) * 86_400 - ServerClock.offset)
            } else {
                retryAt = Date().addingTimeInterval(min(3600, 60 * pow(2, Double(failures - 1))))
            }
        }
    }

    private static func fetch() async {
        do {
            let spki = try await PrivaAPI.shared.relayPassKey()
            let first = today
            var pending: [(day: Int, p: BlindToken.Pending)] = []
            for day in first..<(first + batch) {
                var d = UInt32(day).bigEndian
                let token = prefix + Data(bytes: &d, count: 4) + Bytes.random(32)
                pending.append((day, try BlindToken.begin(spki: spki, pinned: pinnedKeyIDs, token: token)))
            }
            let sigs = try await PrivaAPI.shared.relayPasses(proof: try await PurchaseService.proof(), blinded: pending.map(\.p.blinded))
            var fresh: [Stored] = []
            for (item, sig) in zip(pending, sigs) {
                let r = try BlindToken.finish(item.p, blindSignature: sig)
                fresh.append(Stored(day: item.day, token: r.token, signature: r.signature))
            }
            save(fresh, keepingFrom: first - 1)
            lock.withLock { failures = 0; retryAt = .distantPast }
        } catch {
            failed(error)
            #if DEBUG
            PrivaAPI.debugCount("relay-pass-error")
            #endif
        }
    }

    #if DEBUG
    static func debugForget() { Keychain.delete(account); lock.withLock { failures = 0; retryAt = .distantPast; cache = nil; discards = [] } }

    /// Tests that wipe the Keychain put the passes back afterwards: each wipe would otherwise spend another batch of
    /// the test purchase's monthly passes (audit TST-07).
    static func debugRestore(_ passes: [Stored]) { lock.withLock { writeLocked(passes) } }


    #endif
}
