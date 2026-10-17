import CryptoKit
import Foundation
import Observation
import UIKit

/// The running, unlocked Priva node. Owns the encrypted store, the rendezvous connection,
/// every peer-to-peer link, the sender-side queue and all friend / message / file flows.
@Observable
final class PrivaEngine {
    struct Summary: Identifiable, Hashable {
        var id: String { contact.username }
        var contact: Contact
        var last: Message?
        var unread: Int
    }

    enum Presence: Equatable { case offline, connecting, online }

    /// Last message + unread count of a group thread (key "g:<id>").
    struct GroupActivity: Hashable {
        var last: Message?
        var unread: Int
    }

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let body: String
        let contact: String?
    }

    struct Diagnostics: Equatable {
        var lastHandshakeMs: Double?
        var lastRoundTripMs: Double?
        var signalsSent = 0
        var signalsReceived = 0
        var rejectedEnvelopes = 0
        var keyChangeRequests = 0
        /// Requests and group posts from blocked people that were dropped.
        var blockedDropped = 0
        /// Messages this iPhone couldn't save (storage full): not acknowledged, so they come again.
        var storageErrors = 0
        /// Connections this iPhone started.
        var linkAttempts = 0
        /// Friend requests that came again with an id already answered (retries or replays): nothing new was made.
        var repeatedRequests = 0
        /// Why sessions ended (diagnostics screen and tests: "timeout", "failed", "authentication"…).
        var linkCloses: [String: Int] = [:]
    }

    private(set) var vault: UnlockedVault
    let store: Store
    let calls = CallCenter()
    let groups = GroupHub()
    let groupCalls = GroupCallCenter()
    let backup = BackupCenter()
    @ObservationIgnored let api = PrivaAPI.shared
    @ObservationIgnored let realtime = RealtimeClient()
    @ObservationIgnored let transfers = TransferRegistry()

    var settings: PrivaSettings {
        didSet {
            try? store.set(settings, for: "settings")
            // The name goes to friends a second after the last keystroke, not with every letter (audit STA-29).
            if oldValue.displayName != settings.displayName { scheduleProfileBroadcast() }
            if settings.relayCalls && !oldValue.relayCalls { closeLinksForPrivacy() }
        }
    }
    private(set) var contacts: [Contact] = []
    private(set) var incomingRequests: [IncomingRequest] = []
    private(set) var outgoingRequests: [OutgoingRequest] = []
    /// After a restore: the new recovery phrase hasn't been shown or saved yet (audit STA-30).
    private(set) var phraseUnsaved = false
    private(set) var summaries: [Summary] = []
    private(set) var groupActivity: [String: GroupActivity] = [:]
    private(set) var threads: [String: [Message]] = [:]
    private(set) var presence: [String: Presence] = [:]
    private(set) var typing: Set<String> = []
    private(set) var realtimeStatus: RealtimeClient.Status = .disconnected
    private(set) var callHistory: [CallRecord] = []
    var toast: Toast?
    var openChat: String? { didSet { if let openChat { markRead(openChat); connectEarly(openChat) } } }
    private(set) var diagnostics = Diagnostics()
    private(set) var uploadProgress: [String: Double] = [:]
    /// Live download progress by file: kept out of `threads`, so a transfer doesn't rebuild every open chat ten
    /// times a second (audit STA-21). Only the bubble showing that file reads it.
    private(set) var downloadProgress: [String: Double] = [:]

    var me: String { vault.username }
    var myBundle: KeyBundle { vault.bundle }
    var identity: IdentityKeys { vault.identity }

    @ObservationIgnored private var links: [String: PeerLink] = [:]
    @ObservationIgnored private var nextAttempt: [String: Date] = [:]
    @ObservationIgnored private var attempts: [String: Int] = [:]
    @ObservationIgnored private var requestRetry: [String: Date] = [:]
    @ObservationIgnored private var revoking: Set<Data> = []
    @ObservationIgnored private var streaming: Set<String> = []
    @ObservationIgnored private var fileWants: [String: [Date]] = [:]
    @ObservationIgnored private var revokeFailures: [Data: Int] = [:]
    @ObservationIgnored private var revokeRetry: [Data: Date] = [:]
    @ObservationIgnored private var replay = ReplayCache()
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var lastExpirySweep = Date.distantPast
    @ObservationIgnored private var lastResendSweep = Date.distantPast
    @ObservationIgnored private lazy var incomingTap = UIImpactFeedbackGenerator(style: .light)
    @ObservationIgnored private var lastIncomingTap = Date.distantPast
    @ObservationIgnored private var lastStorageWarning = Date.distantPast
    @ObservationIgnored private var lastDailyDuties = Date.distantPast
    @ObservationIgnored private var typingExpiry: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let signalOut = SignalOutbox()
    /// Files this iPhone is sending (fileID → message) and receiving; kept in the store so a restart resumes them
    /// without scanning every chat.
    struct FileRef: Codable, Sendable, Equatable { let message: String; let contact: String }
    @ObservationIgnored private var outgoingFiles: [String: FileRef] = [:] {
        didSet { try? store.set(outgoingFiles, for: "files.outgoing") }
    }
    @ObservationIgnored private var incomingFiles: [String: FileRef] = [:] {
        didSet { try? store.set(incomingFiles, for: "files.incoming") }
    }
    @ObservationIgnored private var pingSent: [Int64: Date] = [:]
    @ObservationIgnored private(set) var started = false

    deinit {
        LiveObjects.died("PrivaEngine")
        if !closed { LiveObjects.died("Session") }
    }

    /// Closed for good (Priva locked or erased).
    @ObservationIgnored private(set) var closed = false

    /// Priva locks: stop, and empty this object. SwiftUI copies its environment (and with it this engine) into
    /// UIKit trait collections, which UIKit caches in long-lived views (the keyboard, bar buttons, list cells), so
    /// the object itself can outlive the lock. What it held mustn't: the database closes and its keys go, the
    /// account keys are swapped for random ones, and messages, contacts, groups and backup settings are dropped
    /// from memory. (Found by MEM-01 on the iPhone: every lock used to leave a whole session behind.)
    func close() {
        guard !closed else { return }
        stop()
        closed = true
        store.close()
        vault = vault.wiped()
        threads = [:]
        contacts = []
        summaries = []
        groupActivity = [:]
        incomingRequests = []
        outgoingRequests = []
        pendingMoves = [:]
        callHistory = []
        presence = [:]
        typing = []
        uploadProgress = [:]
        downloadProgress = [:]
        toast = nil
        links.removeAll()
        replay = ReplayCache()
        typingExpiry.values.forEach { $0.cancel() }
        typingExpiry.removeAll()
        groups.close()
        backup.close()
        calls.call = nil
        groupCalls.call = nil
        transfers.cancelAll()
        LiveObjects.died("Session")
    }

    init(vault: UnlockedVault, store: Store) {
        self.vault = vault
        self.store = store
        settings = store.get(PrivaSettings.self, for: "settings") ?? PrivaSettings()
        calls.engine = self
        groups.engine = self
        groupCalls.engine = self
        backup.engine = self
        transfers.onProgress = { [weak self] messageID, fileID, source, fraction, complete in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.incomingProgress(messageID: messageID, fileID: fileID, source: source, fraction: fraction, complete: complete) } }
        }
        LiveObjects.born("PrivaEngine")
        LiveObjects.born("Session")
    }

    // MARK: lifecycle

    func start() {
        guard !closed else { return }          // a closed engine never comes back: unlock makes a new one
        guard !started else { return }
        started = true
        lastPresence = .distantPast          // a fresh unlock always says hello once
        connectedOnce = false
        expireDisappearing()            // before the chat list is built: nothing past its time is shown at unlock
        reload()
        groups.load()
        backup.load()
        for gid in groups.groups.keys { refreshGroupActivity(gid) }
        resumeIncomingTransfers()
        // Weak: the App Store can take its time (or never answer offline), and a lock mustn't wait for it.
        Task { [weak self] in await self?.rememberPurchase() }
        realtime.onMessage = { [weak self] topic, event, data in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handleEnvelope(topic: topic, event: event, data: data) } }
        }
        realtime.onStatus = { [weak self] status in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.realtimeStatus = status
                    if status == .connected {
                        // After a drop, spread retries over a few seconds: when the server restarts, every
                        // iPhone reconnects at the same moment, and the project's message rate is capped.
                        let spread: ClosedRange<TimeInterval> = self.connectedOnce ? 0...4 : 0...0
                        for c in self.contacts { self.nextAttempt[c.username] = Date().addingTimeInterval(.random(in: spread)) }
                        self.connectedOnce = true
                        self.retryRequestsNow()
                    }
                }
            }
        }
        // "I'm online" only once our inbox join is confirmed: friends answer presence immediately, and a
        // reply sent before the join completes would be lost (costing a 10 s handshake timeout).
        let inbox = identity.inboxTopic
        realtime.onJoined = { [weak self] topic in
            guard topic == inbox else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.started else { return }
                    if self.settings.announcePresence {
                        if self.lastPresence == .distantPast {
                            self.announcePresence()          // just unlocked: say hello right away
                        } else {
                            // A reconnect (rate-limited to one note per 3 minutes anyway): spread over 20 s so a
                            // server restart doesn't make every iPhone announce itself in the same second.
                            Task { [weak self] in
                                try? await Task.sleep(for: .seconds(.random(in: 0...20)))
                                guard let self, self.started else { return }
                                self.announcePresence()
                            }
                        }
                    }
                    self.tick()
                }
            }
        }
        loadMigration()
        refreshTopics()
        // The scheduler runs even on an iPhone whose account moved: disappearing messages still have to go.
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
        // This account now lives on another iPhone: keep what's here readable, but stay offline (once the move is
        // settled: until then this iPhone may still have to tell friends whether it was its owner).
        guard !moveSettled else { return }
        if NetworkPrivacy.current.mode == .tor {
            TorService.shared.start()
            TorService.shared.whenReady("engine") { [weak self] in self?.realtime.reconfigure(); ManagedRelay.refresh(force: true) }
        }
        realtime.connect()
        ManagedRelay.refreshIfNeeded()
    }

    func stop() {
        // Calls end properly first: peers hear the end, and each call gives the shared audio session back.
        if calls.isInCall { calls.hangUp() }
        if groupCalls.isInCall { groupCalls.hangUp() }
        started = false
        ticker?.cancel()
        ticker = nil
        for l in links.values { l.close(.normal) }
        links.removeAll()
        realtime.disconnect()
        realtimeStatus = .disconnected          // at once, not when the socket's callback catches up
        transfers.cancelAll()
        backup.cancel()
    }

    func reload() {
        contacts = (try? store.contacts()) ?? []
        incomingRequests = ((try? store.incomingRequests()) ?? []).sorted { $0.receivedAt > $1.receivedAt }
        outgoingRequests = ((try? store.outgoingRequests()) ?? []).filter { $0.state == .pending }
        withdrawals = store.get([PendingWithdrawal].self, for: "requests-withdrawn") ?? []
        phraseUnsaved = store.get(Bool.self, for: "phrase.unsaved") ?? false
        callHistory = (try? store.calls()) ?? []
        accountMoved = store.get(AccountMovedNotice.self, for: "account.moved")
        pendingMoves = store.get([String: PendingMove].self, for: "moves.pending") ?? [:]
        blocked = store.get([BlockedUser].self, for: "blocked") ?? []
        rebuildSummaries()
    }

    private func rebuildSummaries() {
        summaries = contacts.filter { $0.groupOnly != true }.map { c in
            let last = threads[c.username]?.last ?? (try? store.messages(with: c.username, limit: 1))?.last
            return Summary(contact: c, last: last, unread: (try? store.unreadCount(for: c.username)) ?? 0)
        }.sorted { ($0.last?.sentAt ?? $0.contact.addedAt) > ($1.last?.sentAt ?? $1.contact.addedAt) }
    }

    func refreshGroupActivity(_ gid: String) {
        let key = "g:\(gid)"
        groupActivity[gid] = GroupActivity(last: threads[key]?.last ?? (try? store.messages(with: key, limit: 1))?.last,
                                           unread: (try? store.unreadCount(for: key)) ?? 0)
    }

    private func updateSummary(_ username: String) {
        if username.hasPrefix("g:") { refreshGroupActivity(String(username.dropFirst(2))); return }
        guard let c = contacts.first(where: { $0.username == username }), c.groupOnly != true else { return }
        let s = Summary(contact: c, last: threads[username]?.last ?? (try? store.messages(with: username, limit: 1))?.last,
                        unread: (try? store.unreadCount(for: username)) ?? 0)
        summaries.removeAll { $0.id == username }
        summaries.insert(s, at: 0)
        summaries.sort { ($0.last?.sentAt ?? $0.contact.addedAt) > ($1.last?.sentAt ?? $1.contact.addedAt) }
    }

    /// Onion mode: new API sessions pick it up immediately; the rendezvous socket reconnects through it;
    /// new peer links go relay-only when a TURN server is configured.
    func setNetworkPrivacy(_ p: NetworkPrivacy) {
        guard p != NetworkPrivacy.current else { return }
        let morePrivate = p.onion && !NetworkPrivacy.current.onion
        NetworkPrivacy.save(p)
        // Connections made before the switch may be direct: they'd keep showing friends this iPhone's IP address.
        if morePrivate { closeLinksForPrivacy() }
        if p.mode == .tor {
            TorService.shared.start()
            TorService.shared.whenReady("engine") { [weak self] in self?.realtime.reconfigure(); ManagedRelay.refresh(force: true) }
        } else {
            TorService.shared.stop()
        }
        realtime.reconfigure()
    }

    /// Tor or "Relay calls" was just turned on: every open connection goes (a call ends), and new ones are made
    /// relay-only (audit TST-02).
    private func closeLinksForPrivacy() {
        if calls.isInCall { calls.hangUp() }
        if groupCalls.isInCall { groupCalls.hangUp() }
        for l in links.values { l.close(.normal) }
    }

    func contact(_ username: String) -> Contact? { contacts.first { $0.username == username } }
    /// Real friends only: hidden group links (successor sessions) never show up as friends.
    var friends: [Contact] { contacts.filter { $0.groupOnly != true } }

    /// Display name for a username in group context: friend nickname → shared name → @username.
    func name(of username: String, in g: PrivaGroup? = nil) -> String {
        if username == me { return "You" }
        if let c = contact(username), c.groupOnly != true { return c.displayName }
        return g?.member(username)?.name ?? username
    }

    private func saveContact(_ c: Contact) {
        try? store.upsert(c)
        if let i = contacts.firstIndex(where: { $0.username == c.username }) { contacts[i] = c } else {
            contacts.append(c)
            contacts.sort { $0.username < $1.username }
        }
    }

    #if DEBUG
    /// Tests: the next background connection attempt to `u` waits until `date`.
    func debugBackoff(_ u: String, until date: Date) { nextAttempt[u] = date }

    /// Tests: change what this iPhone knows about a contact (say, when it last heard from them).
    func debugEditContact(_ u: String, _ f: (inout Contact) -> Void) {
        guard var c = contact(u) else { return }
        f(&c)
        saveContact(c)
    }
    #endif

    // MARK: threads

    func loadThread(_ username: String) -> [Message] {
        if let t = threads[username] { return t }
        let t = (try? store.messages(with: username, limit: 400)) ?? []
        threads[username] = t
        return t
    }

    /// iOS is short of memory: keep only the open chat's latest messages and drop decoded photos, all of it comes
    /// back from the encrypted store when needed. Being killed instead would end a call or a transfer.
    func trimMemory() {
        threads = threads.filter { $0.key == openChat }.mapValues { Array($0.suffix(400)) }
        MediaVault.shared.trim()
    }

    /// One more page of history above what's loaded. False once the first message is reached.
    func loadOlder(_ username: String) -> Bool {
        guard let first = threads[username]?.first else { return false }
        let older = (try? store.messages(with: username, limit: Self.olderPage, before: first.sentAt, beforeID: first.id)) ?? []
        guard !older.isEmpty else { return false }
        threads[username] = older + (threads[username] ?? [])
        return older.count == Self.olderPage
    }

    static let olderPage = 200

    /// Several messages for one thread: one copy of the thread, one sort at most.
    private func upsertInThread(_ ms: [Message]) {
        guard let key = ms.first?.contact else { return }
        guard ms.count > 1 else { upsertInThread(ms[0]); return }
        var t = threads[key] ?? loadThread(key)
        threads[key] = nil                          // so the edits below don't copy the whole thread
        var index = Dictionary(t.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        var needsSort = false
        for m in ms {
            if let i = index[m.id] { t[i] = m; continue }
            if let last = t.last, (last.sentAt, last.id) > (m.sentAt, m.id) { needsSort = true }
            index[m.id] = t.count
            t.append(m)
        }
        if needsSort { t.sort { ($0.sentAt, $0.id) < ($1.sentAt, $1.id) } }
        threads[key] = t
    }

    private func upsertInThread(_ m: Message) {
        var t = threads[m.contact] ?? loadThread(m.contact)
        if let i = t.firstIndex(where: { $0.id == m.id }) { t[i] = m } else {
            t.append(m)
            // Same order as the store (time, then id), so equal timestamps never swap between phones.
            if t.count >= 2, (t[t.count - 2].sentAt, t[t.count - 2].id) > (m.sentAt, m.id) { t.sort { ($0.sentAt, $0.id) < ($1.sentAt, $1.id) } }
        }
        threads[m.contact] = t
    }

    /// One light tap per burst, only while Priva is in front. 200 queued messages arriving together used to buzz
    /// 200 times, at ≈ 30 ms of main-thread haptics each on an iPhone (6 s for the burst; found by XD-02).
    private func feelIncoming() {
        guard Date().timeIntervalSince(lastIncomingTap) > 1.5, UIApplication.shared.applicationState == .active else { return }
        lastIncomingTap = .now
        incomingTap.impactOccurred(intensity: 0.6)
    }

    // MARK: arrivals, saved together

    /// Messages that arrived in the same moment. They're saved in one write instead of one each: on an iPhone every
    /// write waits for the flash, and a burst of 200 queued messages held the main thread for 4.5 s (XD-02).
    @ObservationIgnored private var arriving: [(message: Message, link: PeerLink)] = []

    private func arrived(_ m: Message, on link: PeerLink) {
        arriving.append((m, link))
        // Everything already waiting on the main queue (the rest of a burst) joins this batch.
        if arriving.count == 1 { DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.saveArrivals() } } }
    }

    private func saveArrivals() {
        let batch = arriving
        arriving = []
        guard !batch.isEmpty else { return }
        // Saves first: nothing is shown or acknowledged unless it's on disk (otherwise it all comes again).
        do { try store.importMessages(batch.map(\.message)) } catch { storageFailed(); return }
        for (contact, items) in Dictionary(grouping: batch.map(\.message), by: \.contact) {
            upsertInThread(items)
            updateSummary(contact)
            typing.remove(contact)
        }
        var byLink: [ObjectIdentifier: (link: PeerLink, ids: [String], read: [String])] = [:]
        for (m, link) in batch {
            var entry = byLink[ObjectIdentifier(link)] ?? (link, [], [])
            entry.ids.append(m.id)
            if m.readAt != nil, settings.readReceipts { entry.read.append(m.id) }
            byLink[ObjectIdentifier(link)] = entry
            if let a = m.attachment { beginIncoming(a, messageID: m.id, from: m.contact, link: link) }
        }
        for entry in byLink.values {
            for chunk in stride(from: 0, to: entry.ids.count, by: 500) { entry.link.send(.ack(Array(entry.ids[chunk..<min(entry.ids.count, chunk + 500)]))) }
            if !entry.read.isEmpty { entry.link.send(.read(entry.read)) }
        }
        if let last = batch.last?.message, openChat != last.contact {
            let a = last.attachment
            let preview = last.kind == .media ? (a?.kind == .video ? "Video" : a?.kind == .image ? "Photo" : "File") : (last.text ?? "")
            toast = Toast(title: contact(last.contact)?.displayName ?? last.contact, body: preview, contact: last.contact)
        }
        feelIncoming()
    }

    /// Delivery and read receipts for what we sent, saved in one write.
    private func markOutgoing(_ ids: [String], from peer: String, as status: Message.Status) {
        var changed: [Message] = []
        for id in ids.prefix(500) {
            guard var m = message(id, contact: peer), m.outgoing, m.contact == peer else { continue }
            if status == .delivered && m.status == .read { continue }
            guard m.status != status else { continue }
            m.status = status
            changed.append(m)
        }
        guard !changed.isEmpty else { return }
        do { try store.importMessages(changed) } catch { storageFailed(); return }
        upsertInThread(changed)
        updateSummary(peer)
    }

    /// Saves first, shows second: a message that isn't on disk is never shown, sent or acknowledged.
    @discardableResult
    func persist(_ m: Message) -> Bool {
        do { try store.save(m) } catch { storageFailed(); return false }
        upsertInThread(m)
        updateSummary(m.contact)
        return true
    }

    /// Writing failed: on a phone, almost always because storage is full. What arrives isn't acknowledged, so
    /// the sender keeps it and tries again; what was typed stays in the box.
    func storageFailed() {
        diagnostics.storageErrors += 1
        guard Date().timeIntervalSince(lastStorageWarning) > 600 else { return }
        lastStorageWarning = .now
        toast = Toast(title: "iPhone storage is full", body: "Free up space. New messages wait until then.", contact: nil)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    private func message(_ id: String, contact: String) -> Message? {
        threads[contact]?.first { $0.id == id } ?? (try? store.message(id))
    }

    func markRead(_ username: String) {
        // One transaction for the whole thread (audit STA-07: more than the loaded 400 used to stay unread forever,
        // and each message was its own write).
        let read = (try? store.markRead(username)) ?? []
        guard !read.isEmpty else { return }
        let loaded = Set(loadThread(username).map(\.id))
        let visible = read.filter { loaded.contains($0.id) }
        if !visible.isEmpty { upsertInThread(visible) }
        updateSummary(username)
        if settings.readReceipts, let l = links[username], l.isReady {
            let ids = read.map(\.id)
            for start in stride(from: 0, to: ids.count, by: 500) { l.send(.read(Array(ids[start..<min(ids.count, start + 500)]))) }
        }
    }

    // MARK: sending

    /// False when it couldn't be saved (storage full): the caller keeps the draft.
    @discardableResult
    func send(text: String, to username: String, replyTo: String? = nil) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let c = contact(username) else { return true }
        let m = Message(id: UUID().uuidString, contact: username, outgoing: true, kind: .text, text: String(trimmed.prefix(16_000)),
                        attachment: nil, sentAt: .now, status: .queued, replyTo: replyTo,
                        expiresAt: c.disappearAfter.map { Date().addingTimeInterval($0) })
        guard persist(m) else { return false }
        deliver(m, to: username)
        return true
    }

    /// Encrypts prepared media into this iPhone's media store (the plaintext temp file is deleted).
    func encryptForSending(_ media: MediaPrep.Prepared) async -> Attachment? {
        let fileID = UUID().uuidString
        let key = SymmetricKey(size: .bits256)
        let dest = store.mediaURL(fileID)
        let src = media.url
        let result = await Task.detached(priority: .userInitiated) { () -> (FileCipherHeader, Data)? in
            defer { try? FileManager.default.removeItem(at: src) }
            return try? FileCipher.encrypt(file: src, to: dest, key: key)
        }.value
        guard let (header, sha) = result else { toast = Toast(title: "Couldn't prepare file", body: "Please try again.", contact: nil); return nil }
        return Attachment(fileID: fileID, kind: media.kind, name: media.name, mime: media.mime, size: header.plainSize,
                          key: key.withUnsafeBytes { Data($0) }, header: header.encoded, sha256: sha, thumbnail: media.thumbnail,
                          width: media.width, height: media.height, duration: media.duration, progress: 0)
    }

    func registerOutgoingFile(_ fileID: String, message: String, contact: String) { outgoingFiles[fileID] = FileRef(message: message, contact: contact) }

    func dropFromThread(_ id: String, key: String) {
        threads[key]?.removeAll { $0.id == id }
    }

    /// Messages in `key` were rewritten in the store: reload them next time the thread is shown.
    func forgetThreadCache(_ key: String) { threads[key] = nil }

    func diagnosticsRejected() { diagnostics.rejectedEnvelopes += 1 }
    func diagnosticsBlocked() { diagnostics.blockedDropped += 1 }

    /// A group host introduced us to a fellow member (successor link). Never overrides a real friend.
    func installGroupLink(peer: String, bundle: KeyBundle, inbox: String, root: Data) {
        if let existing = contact(peer), existing.groupOnly != true { return }
        var c = Contact(username: peer, bundleRaw: bundle.raw, pair: PairSecrets(current: root, previous: nil, epoch: 0), inboxTopic: inbox)
        c.groupOnly = true
        c.directoryState = "active"
        saveContact(c)
    }

    func send(media: MediaPrep.Prepared, to username: String) async {
        guard let c = contact(username) else { return }
        guard let att = await encryptForSending(media) else { return }
        let fileID = att.fileID
        let m = Message(id: UUID().uuidString, contact: username, outgoing: true, kind: .media, text: nil, attachment: att,
                        sentAt: .now, status: .queued, replyTo: nil, expiresAt: c.disappearAfter.map { Date().addingTimeInterval($0) })
        guard persist(m) else { store.removeMedia(fileID); return }
        outgoingFiles[fileID] = FileRef(message: m.id, contact: username)
        deliver(m, to: username)
    }

    func envelope(_ m: Message) -> Wire.Envelope {
        var att = m.attachment
        att?.progress = 0
        return Wire.Envelope(id: m.id, sentAt: m.sentAt, kind: m.kind, text: m.text, attachment: att, replyTo: m.replyTo,
                             expiresIn: m.expiresAt.map { max(1, $0.timeIntervalSince(m.sentAt)) })
    }

    private func deliver(_ m: Message, to username: String) {
        if let l = links[username], l.isReady {
            l.send(.message(envelope(m)))
        } else {
            nextAttempt[username] = .distantPast
            tick()
        }
    }

    func retry(_ m: Message) {
        if m.contact.hasPrefix("g:") { groups.resubmit(m); return }
        var m = m
        m.status = .queued
        persist(m)
        deliver(m, to: m.contact)
    }

    /// A whole conversation, not just the loaded part, with its files.
    func deleteThread(_ key: String) {
        for f in (try? store.deleteThread(key)) ?? [] { MediaVault.shared.forget(f) }
        threads[key] = nil
        updateSummary(key)
    }

    func delete(_ m: Message) {
        try? store.deleteMessage(m.id)
        if let f = m.attachment?.fileID { store.removeMedia(f); if outgoingFiles[f] != nil { outgoingFiles[f] = nil } }
        threads[m.contact]?.removeAll { $0.id == m.id }
        updateSummary(m.contact)
    }

    func setTyping(_ on: Bool, to username: String) {
        guard settings.typingIndicators, let l = links[username], l.isReady else { return }
        l.send(.typing(on))
    }

    // MARK: delivery scheduler (sender-side queue)

    /// Control items (acceptances) travel by broadcast, not over a link: they don't need one.
    private func hasPending(_ username: String, pendingHashes: Set<String>) -> Bool {
        pendingHashes.contains(store.hashFor(username)) || !transfers.activeFiles(for: username).isEmpty
    }

    private func tick() {
        // Disappearing messages go on time whether or not Priva is connected (audit STA-06). Every 10 s (a modulo on
        // the 1.5 s tick could skip every multiple of 30 forever).
        if started, Date().timeIntervalSince(lastExpirySweep) >= 10 {
            lastExpirySweep = .now
            expireDisappearing()
        }
        if started { followDueMoves(); settleMoveIfDue() }
        guard started, realtimeStatus == .connected else { return }
        ManagedRelay.refreshIfNeeded()
        let now = Date()
        let hashes = (try? store.pendingContactHashes()) ?? []
        let control = (try? store.controlItems()) ?? []
        let groupPeers = groups.peersNeedingLink(pendingHashes: hashes).union(groupCalls.peersNeedingLink())
        groups.checkFailover()
        let answering = accountMoved?.answer != nil ? moveAnswerQueue : []
        for c in contacts {
            let want = hasPending(c.username, pendingHashes: hashes) || groupPeers.contains(c.username)
                || (calls.call?.peer == c.username && calls.isInCall) || openChat == c.username
                || answering.contains(c.username)
            guard want else { continue }
            if let l = links[c.username], l.state != .closed { continue }
            if now >= nextAttempt[c.username, default: .distantPast] { attemptLink(c) }
        }
        for r in outgoingRequests where r.state == .pending && !r.expired && now >= requestRetry[r.id, default: .distantPast] {
            sendRequestEnvelope(r)
        }
        if withdrawals.contains(where: { $0.until < now }) { withdrawals.removeAll { $0.until < now } }
        for w in withdrawals where now >= requestRetry[w.id, default: .distantPast] { sendWithdrawal(w) }
        for item in control where now >= requestRetry[item.id, default: .distantPast] {
            let n = item.attempts
            requestRetry[item.id] = now.addingTimeInterval(min(300, 10 * pow(1.6, Double(n))) * .random(in: 0.8...1.2))
            var updated = item
            updated.attempts += 1
            try? store.save(updated)
            signalOut.broadcast(api: api, [.init(topic: item.topic, event: "d", data: item.envelope)], key: item.contact)
        }
        // Idle links close after 5 minutes, but never one carrying a call (1:1 or group: group media flows
        // over RTP, so the data channel can be quiet for the whole call).
        let groupCallPeers = groupCalls.peersNeedingLink()
        let idle = Self.idleTimeout(onion: NetworkPrivacy.current.onion)
        for (peer, l) in links where l.isReady {
            // A file still moving keeps it too: chunks don't count as activity, and a long transfer used to be cut
            // every 5 minutes (audit STA-09).
            let moving = !transfers.activeFiles(for: peer).isEmpty || streaming.contains { $0.hasPrefix(peer + "|") }
            let busy = (calls.call?.peer == peer && calls.isInCall) || groupCallPeers.contains(peer) || l.mediaActive || moving
            if !busy, openChat != peer, now.timeIntervalSince(l.lastActivity) > idle { l.close(.normal) }
        }
        // Unanswered messages on a link that has been up a minute go again, once a minute: the other iPhone may have
        // been unable to save them (storage full). It drops what it already has, by id, and acknowledges it.
        if now.timeIntervalSince(lastResendSweep) >= 60 {
            lastResendSweep = now
            let queued = (try? store.groupQueueMemberHashes()) ?? []
            for (peer, l) in links where l.isReady && (l.connectedAt.map { now.timeIntervalSince($0) > 60 } ?? false) {
                if hasPending(peer, pendingHashes: hashes) {
                    for m in (try? store.pending(for: peer)) ?? [] where now.timeIntervalSince(m.sentAt) > 30 { l.send(.message(envelope(m))) }
                }
                if groupPeers.contains(peer) { groups.resendStuck(to: peer, queuedHashes: queued) }
            }
        }
        if now.timeIntervalSince(lastDailyDuties) > 3600 {
            lastDailyDuties = now
            pruneGroupMedia()
            dropUnusedGroupLinks()
            reconnectAfterRestore()
            backup.backUpIfDue()
        }
        maintainLease()
        sweepDirectory()
        runMigrationDuties()
    }

    private func attemptLink(_ c: Contact, intent: Signal.Intent = .data) {
        diagnostics.linkAttempts += 1
        let n = attempts[c.username, default: 0]
        attempts[c.username] = n + 1
        // 6 s, 9 s, 13 s … up to 5 minutes: a friend who comes back online announces it (presence resets this),
        // so steady retries would mostly spend the server's message quota.
        let delay = min(300, 6 * pow(1.5, Double(min(n, 12))))
        nextAttempt[c.username] = Date().addingTimeInterval(delay * .random(in: 0.85...1.15))
        // Alternate roots if the peer may not have completed the last ratchet step.
        let roots = c.pair.candidates
        let root = roots[n % roots.count]
        guard let link = try? PeerLink(me: me, peer: c.username, root: root, settings: settings, intent: intent) else { return }
        adopt(link)
        presence[c.username] = .connecting
        link.start()
    }

    static let maxLinks = 128
    /// A quiet connection is kept this long while Priva is open: re-connecting costs ~5 rendezvous messages,
    /// keeping it costs a keep-alive every few seconds. (Locking Priva closes everything anyway.)
    static let idleLinkTimeout: TimeInterval = 300

    /// Over Tor a new connection costs three trips through Tor (≈ 4 s before the first message), so an idle one is
    /// kept three times longer: a conversation with pauses doesn't pay that again and again. Keep-alives go to the
    /// relay, not through Tor, and are tiny.
    static func idleTimeout(onion: Bool) -> TimeInterval { onion ? idleLinkTimeout * 3 : idleLinkTimeout }

    /// At the cap, the least-recently-active idle connection (no call, no media, not the open chat) makes room;
    /// it reconnects by itself the next time there's something to send.
    private func makeRoomForLink(except peer: String) {
        let open = links.filter { $0.value.state != .closed }
        guard open.count >= Self.maxLinks else { return }
        let groupCallPeers = groupCalls.peersNeedingLink()
        let idle = open.filter { p, l in
            p != peer && openChat != p && !l.mediaActive && !groupCallPeers.contains(p) && !(calls.call?.peer == p && calls.isInCall)
        }
        if let victim = idle.min(by: { $0.value.lastActivity < $1.value.lastActivity }) { victim.value.close(.normal) }
    }

    private func adopt(_ link: PeerLink) {
        makeRoomForLink(except: link.peer)
        link.delegate = self
        let peer = link.peer
        link.bulk.onChunk = { [transfers] fileID, index, data in
            transfers.receive(fileID: fileID, index: index, data: data, from: peer)
        }
        links[peer] = link
    }

    /// Opening a chat starts connecting now rather than at the next tick: a new connection takes three trips through
    /// the server, and it's usually up before the first message is typed. Keeps the retry backoff, so reopening a
    /// chat with an offline friend doesn't spend a signal each time.
    private func connectEarly(_ username: String) {
        guard started, realtimeStatus == .connected, let c = contact(username), c.groupOnly != true, link(for: username) == nil,
              Date() >= nextAttempt[username, default: .distantPast] else { return }
        attemptLink(c)
    }

    /// Connect now. Background work (group fan-out, requeues) waits for the retry backoff like the scheduler does:
    /// each attempt is a metered hello, and a host posting to 30 offline members used to send 30 on every post
    /// (audit STA-10). A call is someone waiting: `urgent` dials at once.
    func requestLink(_ username: String, intent: Signal.Intent, urgent: Bool = false) {
        guard let c = contact(username) else { return }
        if let l = links[username], l.state != .closed { return }
        if !urgent, Date() < nextAttempt[username, default: .distantPast] { return }
        nextAttempt[username] = .distantPast
        attemptLink(c, intent: intent)
    }

    func link(for username: String) -> PeerLink? { links[username].flatMap { $0.state == .closed ? nil : $0 } }

    // MARK: rendezvous: outgoing signals

    private func sendSignal(_ s: Signal, to c: Contact, root: Data) {
        let me = self.me
        diagnostics.signalsSent += 1
        let payload: Data
        do { payload = try s.encoded() } catch { return }
        let topic = c.inboxTopic, peer = c.username
        signalOut.enqueue(key: peer) { [api] in
            guard let env = try? SignalEnvelope.seal(payload, root: root, from: me, to: peer, topic: topic) else { return }
            await SignalOutbox.deliver(api, [.init(topic: topic, event: "s", data: env)])
        }
    }

    /// "I'm online": lets friends with something queued for us deliver it now instead of retrying blindly.
    /// Each note is a metered rendezvous message, so: friends active in the last 30 days only (someone long quiet
    /// announces themselves when they return), the 60 most recent, and on reconnects at most every 3 minutes.
    func announcePresence() {
        guard Date().timeIntervalSince(lastPresence) > Self.presenceInterval else { return }
        lastPresence = .now
        let me = self.me
        // Friends only: not someone blocked, and not a hidden group link (a fellow member who isn't a friend has no
        // business knowing when this iPhone comes online; audit STA-20, SEC-11).
        let recent = contacts
            .filter { $0.groupOnly != true && !isBlocked($0.username) }
            .filter { ($0.lastSeen ?? $0.addedAt).timeIntervalSinceNow > -Self.presenceRecency }
            .sorted { ($0.lastSeen ?? $0.addedAt) > ($1.lastSeen ?? $1.addedAt) }
            .prefix(Self.presenceMaxFriends)
        let items = recent.map { ($0.inboxTopic, $0.username, $0.pair.current) }
        guard !items.isEmpty, let payload = try? Signal.presence(ts: Signal.now).encoded() else { return }
        signalOut.enqueue(key: "*presence") { [api] in
            let out = items.compactMap { topic, peer, root in
                (try? SignalEnvelope.seal(payload, root: root, from: me, to: peer, topic: topic)).map { PrivaAPI.Outbound(topic: topic, event: "s", data: $0) }
            }
            for chunk in stride(from: 0, to: out.count, by: 20) {
                await SignalOutbox.deliver(api, Array(out[chunk..<min(out.count, chunk + 20)]))
            }
        }
    }

    static let presenceInterval: TimeInterval = 180
    static let presenceRecency: TimeInterval = 30 * 86_400
    static let presenceMaxFriends = 60
    @ObservationIgnored private var lastPresence = Date.distantPast
    @ObservationIgnored private var connectedOnce = false

    // MARK: rendezvous: incoming

    private func handleEnvelope(topic: String, event: String = "", data: Data) {
        guard started, replay.insert(KDF.sha256(data)) else { return }
        diagnostics.signalsReceived += 1
        if topic == myRequestTopic {
            processFriendRequest(data)
        } else if topic.hasPrefix("m-") {
            processAnnouncement(data, topic: topic)
        } else if topic == identity.inboxTopic, event == "m" {
            processOwnMove(data)
        } else if topic == identity.inboxTopic {
            if data.first == DualSeal.version { processAcceptance(data) } else if data.first == SignalEnvelope.tag { processSignal(data, topic: topic) }
        }
    }

    private func processSignal(_ data: Data, topic: String) {
        let me = self.me
        let candidates = contacts.map { ($0.username, $0.pair.candidates) }
        Task.detached(priority: .userInitiated) { [weak self] in
            for (peer, roots) in candidates {
                if let (payload, root) = SignalEnvelope.open(data, roots: roots, from: peer, to: me, topic: topic),
                   let signal = Signal.decode(payload) {
                    await MainActor.run { self?.handleSignal(signal, from: peer, root: root) }
                    return
                }
            }
            await MainActor.run { self?.diagnostics.rejectedEnvelopes += 1 }
        }
    }

    private func handleSignal(_ s: Signal, from peer: String, root: Data) {
        guard abs(Signal.now - s.timestamp) < Signal.maxSkewMs, var c = contact(peer) else { return }
        c.lastSeen = .now
        if c.looksGone {
            c.directoryState = "active"
            saveContact(c)
            refreshTopics()
        } else {
            contacts = contacts.map { $0.username == peer ? c : $0 }
        }
        // Any authenticated signal proves the peer holds the pair root → our acceptance arrived.
        for item in (try? store.controlItems()) ?? [] where item.contact == peer && item.kind == .acceptance {
            try? store.deleteControl(item.id)
        }
        switch s {
        case .hello(let sid, let x, let k, let intent, _, let early):
            acceptHello(from: c, root: root, hello: .init(sid: sid, ephX: x, ephK: k), intent: intent, early: early == true)
        case .presence:
            nextAttempt[peer] = .distantPast
            attempts[peer] = 0
            if let l = links[peer], l.role == .initiator, l.state == .handshaking, Date().timeIntervalSince(l.createdAt) > 1.5 {
                l.close(.superseded, notify: false)
            }
            tick()
        case .welcome(let rid, _):
            for item in (try? store.controlItems()) ?? [] where item.id == rid { try? store.deleteControl(item.id) }
        default:
            links[peer]?.handle(s)
        }
    }

    private func acceptHello(from c: Contact, root: Data, hello: Handshake.Hello, intent: Signal.Intent, early: Bool) {
        // A hidden group link (a fellow member who isn't a friend) is answered only while the group needs it: they
        // host a live group of ours, may take it over (a successor in its charter), or we host it and they're in it.
        // Anyone else (an ex-member, a group that ended) gets nothing, not even this iPhone's address (audit SEC-11).
        if c.groupOnly == true, !groups.groups.values.contains(where: { g in
            !g.ended && (g.host == c.username || g.charter?.charter.successors.contains(c.username) == true
                         || (g.host == me && g.member(c.username) != nil))
        }) {
            diagnostics.rejectedEnvelopes += 1
            return
        }
        if let existing = links[c.username], existing.state != .closed {
            if existing.sid == hello.sid { return }
            // Glare: both dialled at once. The smaller name keeps the initiator role, but only while its
            // own hello is fresh; after 1.5 s the peer evidently never got it, so we answer theirs.
            if existing.role == .initiator && existing.state == .handshaking && me < c.username
                && Date().timeIntervalSince(existing.createdAt) < 1.5 {
                return
            }
            existing.close(.superseded, notify: false)
        }
        guard let link = try? PeerLink(me: me, peer: c.username, root: root, settings: settings, hello: hello, intent: intent,
                                       early: early) else { return }
        adopt(link)
        presence[c.username] = .connecting
        link.start()
    }

    // MARK: friend requests (identity v2)

    enum FriendError: Error, Equatable { case notFound, isSelf, alreadyFriends, alreadyPending, uninstalled, network }

    struct FoundUser: Sendable, Equatable { let username: String; let bundle: KeyBundle }

    /// Exact lookup: the commitment is computed on this device; the server never sees the name.
    func findUser(_ query: String) async throws -> FoundUser {
        let name = Username.normalize(query)
        guard Username.isValid(name) else { throw FriendError.notFound }
        guard name != me else { throw FriendError.isSelf }
        let entry: PrivaAPI.DirectoryEntry
        do { entry = try await api.lookup(name) } catch { throw FriendError.network }
        switch entry.status {
        case .removed: throw FriendError.notFound
        case .uninstalled: throw FriendError.uninstalled
        case .active:
            guard let b = entry.bundle else { throw FriendError.notFound }
            return FoundUser(username: name, bundle: b)
        }
    }

    func sendFriendRequest(to user: FoundUser, note: String?, renameProof: Data? = nil, renamedFrom: String? = nil,
                           migrates: String? = nil, rekey: Bool = false, moved: Data? = nil, ts: Int64? = nil) throws {
        // Someone we only know from a group (a hidden successor link) can still become a real friend.
        if !rekey, let existing = contact(user.username), existing.bundle == user.bundle, existing.groupOnly != true { throw FriendError.alreadyFriends }
        guard !outgoingRequests.contains(where: { $0.username == user.username }) else { throw FriendError.alreadyPending }
        // Asking to be friends again is an explicit choice (automatic requests, moves, re-keys, never unblock).
        if renamedFrom == nil, moved == nil, migrates == nil, !rekey { unblock(user.username); friendsAgain(user.username) }
        if let inc = incomingRequests.first(where: { $0.username == user.username }) {
            try accept(inc)
            return
        }
        let sealed = try FriendProtocol.makeRequest(from: me, identity: identity, myBundle: myBundle, to: user.username, them: user.bundle,
                                                    note: note, name: sharedName, renameProof: renameProof, renamedFrom: renamedFrom,
                                                    moved: moved, ts: ts)
        var r = OutgoingRequest(id: sealed.rid, username: user.username, bundleRaw: user.bundle.raw, envelope: sealed.envelope,
                                exporter: sealed.exporter, transcript: sealed.transcript, note: note, createdAt: .now)
        r.migratesContact = migrates
        r.rekey = rekey ? true : nil
        try store.save(r)
        outgoingRequests.append(r)
        if withdrawals.contains(where: { $0.username == user.username }) { withdrawals.removeAll { $0.username == user.username } }
        sendRequestEnvelope(r)
    }

    @ObservationIgnored private var profileBroadcast: Task<Void, Never>?

    private func scheduleProfileBroadcast() {
        profileBroadcast?.cancel()
        profileBroadcast = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            for l in self.links.values where l.isReady { l.send(.profile(name: self.sharedName)) }
        }
    }

    /// Display name shared with friends (encrypted payloads only).
    var sharedName: String? {
        let n = settings.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? nil : String(n.prefix(40))
    }

    private func sendRequestEnvelope(_ r: OutgoingRequest) {
        let delay = min(300, 15 * pow(1.5, Double(r.attempts)))
        requestRetry[r.id] = Date().addingTimeInterval(delay * .random(in: 0.8...1.2))
        if let i = outgoingRequests.firstIndex(where: { $0.id == r.id }) {
            outgoingRequests[i].attempts += 1
            outgoingRequests[i].lastAttempt = .now
            try? store.save(outgoingRequests[i])
        }
        let username = r.username, env = r.envelope, api = self.api
        // The request topic comes from the recipient's username (memory-hard, cached): the
        // server cannot map it to any directory entry.
        signalOut.enqueue(key: "req:" + r.id) {
            let topic = UsernameKey.requestTopic(username)
            await SignalOutbox.deliver(api, [.init(topic: topic, event: "r", data: env)])
        }
    }

    private func retryRequestsNow() { for r in outgoingRequests { requestRetry[r.id] = .distantPast } }

    func cancelRequest(_ r: OutgoingRequest) {
        try? store.deleteRequest(outgoing: r.id)
        outgoingRequests.removeAll { $0.id == r.id }
    }

    private func processFriendRequest(_ data: Data) {
        let me = self.me, identity = self.identity
        let formerKeys = migration.announcements.map(\.formerAnnounceKey)
        let pinned = Dictionary(contacts.map { ($0.username, $0.bundleRaw) }, uniquingKeysWith: { a, _ in a })
        let movedAway = self.movedAway
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let opened = try? FriendProtocol.openRequest(data, me: me, identity: identity) else {
                await MainActor.run { self?.diagnostics.rejectedEnvelopes += 1 }
                return
            }
            // Bind the claimed name to the directory: a stranger cannot impersonate "alice".
            let entry: PrivaAPI.DirectoryEntry
            do { entry = try await PrivaAPI.shared.lookup(commit: opened.bundle.ucommit) } catch APIError.network {
                // The directory didn't answer: the request isn't refused, just not checked yet. Its next resend
                // gets through the replay filter (audit STA-35).
                await MainActor.run { self?.replay.forget(KDF.sha256(data)) }
                return
            } catch APIError.http(let code, _) where code >= 500 || code == 429 {
                await MainActor.run { self?.replay.forget(KDF.sha256(data)) }
                return
            } catch {
                await MainActor.run { self?.diagnostics.rejectedEnvelopes += 1 }
                return
            }
            guard entry.status == .active, entry.bundle == opened.bundle else {
                await MainActor.run { self?.diagnostics.rejectedEnvelopes += 1 }
                return
            }
            let former = opened.payload.renameProof.map { proof in
                formerKeys.contains { Bytes.equal(Announcement.renameProof(announceKey: $0, friend: opened.payload.from, newUsername: me), proof) }
            } ?? false
            // Restored under a new username: the move must be signed by the keys we pinned for the old one.
            var movedFrom: String?, conflict: String?
            if let old = opened.payload.renamedFrom, let sig = opened.payload.moved {
                let p = opened.payload
                let check = { (raw: Data) in
                    (try? KeyBundle.parse(raw)).map { MoveProof.verify(sig, pinned: $0, old: old, new: p.from, newBundle: opened.bundle, to: me, ts: p.ts) } ?? false
                }
                if let raw = pinned[old], check(raw) {
                    movedFrom = old
                } else if let gone = movedAway[old], gone.new != p.from, check(gone.oldBundleRaw) {
                    conflict = gone.new
                } else if movedAway[old] == nil || movedAway[old]?.new != p.from {
                    await MainActor.run { self?.diagnostics.rejectedEnvelopes += 1 }
                    return
                }
            }
            await MainActor.run { self?.receivedRequest(opened, formerFriend: former, movedFrom: movedFrom, moveConflict: conflict) }
        }
    }

    private func receivedRequest(_ o: FriendProtocol.OpenedRequest, formerFriend: Bool, movedFrom: String? = nil, moveConflict: String? = nil) {
        let p = o.payload
        if incomingRequests.contains(where: { $0.id == p.rid }) { return }
        // Blocked: also under a new username (same identity key, or following from a blocked one).
        if isBlocked(p.from, key: o.bundle.verifying.ed.rawRepresentation) || isBlocked(p.renamedFrom) {
            diagnostics.blockedDropped += 1
            return
        }
        if let rid = p.withdraws { requestWithdrawn(rid, by: p.from); return }
        if let h = handledRequests[p.rid] { repeatedRequest(o, h); return }
        var req = IncomingRequest(id: p.rid, username: p.from, bundleRaw: o.bundle.raw, inboxTopic: p.inbox,
                                  exporter: o.exporter, transcript: o.transcript, note: p.note, receivedAt: .now)
        req.name = p.name.flatMap { TextSafety.name($0) }
        req.announce = p.announce
        req.formerFriend = formerFriend ? true : nil
        req.renamedFrom = formerFriend ? p.renamedFrom : nil
        if let old = movedFrom, contact(old) != nil, contact(p.from) == nil {
            // A friend restored their account on another iPhone (the proof is signed by their old keys). Held until
            // their old iPhone answers, or `moveWait` passes: whoever has the recovery phrase or the backup can sign
            // this too (audit SEC-04).
            req.movedFrom = old
            req.moveProof = p.moved
            req.moveTs = p.ts
            holdMove(req, from: old)
            return
        }
        if let taken = moveConflict {
            // The same backup restored twice: whoever came second has that backup's keys and password too.
            req.renamedFrom = p.renamedFrom
            req.moveConflict = taken
            incomingRequests.removeAll { $0.username == p.from }
            incomingRequests.insert(req, at: 0)
            try? store.save(req)
            diagnostics.keyChangeRequests += 1
            let who = contact(taken)?.displayName ?? taken
            systemMessage("@\(p.from) claims to be @\(p.renamedFrom ?? "?"), but \(who) already restored it. Someone else has that backup: don't accept.", with: taken)
            toast = Toast(title: "Security warning", body: "A second iPhone restored \(who)'s old account.", contact: taken)
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        // A friend re-sending a request with the SAME keys (e.g. lost pair state): re-pair silently. (A fellow group
        // member we only have a hidden link with is asking to become a friend: that's a normal request.)
        if let existing = contact(p.from), existing.bundle == o.bundle, existing.groupOnly != true {
            try? accept(req, silent: true)
            return
        }
        // Same username, different keys: never automatic. The pinned keys stay until the user explicitly replaces them.
        let changedKeys = contact(p.from).map { $0.bundle != o.bundle } ?? false
        req.keyChange = changedKeys ? true : nil
        diagnostics.keyChangeRequests += changedKeys ? 1 : 0
        incomingRequests.removeAll { $0.username == p.from }
        incomingRequests.insert(req, at: 0)
        try? store.save(req)
        if !changedKeys, outgoingRequests.contains(where: { $0.username == p.from }) { try? accept(req) }
        if changedKeys {
            let who = contact(p.from)?.displayName ?? p.from
            systemMessage("A request as @\(p.from) has different security keys. Decline unless \(who) confirms in person.", with: p.from)
            toast = Toast(title: "Security warning", body: "A request claiming to be \(who) has different keys.", contact: p.from)
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        if formerFriend {
            toast = Toast(title: "A friend followed you", body: "\(p.name ?? p.from) updated to your new username.", contact: nil)
        } else {
            toast = Toast(title: "Friend request", body: "\(p.name ?? p.from) wants to connect", contact: nil)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func accept(_ req: IncomingRequest, silent: Bool = false) throws {
        let (env, pair) = try FriendProtocol.makeAcceptance(from: me, identity: identity, request: req, name: sharedName)
        guard let pair else { return }
        let keyChanged = contact(req.username).map { $0.bundle != (try? KeyBundle.parse(req.bundleRaw)) } ?? false
        var c = contact(req.username) ?? Contact(username: req.username, bundleRaw: req.bundleRaw, pair: pair, inboxTopic: req.inboxTopic)
        c.pair = pair
        c.bundleRaw = req.bundleRaw
        c.inboxTopic = req.inboxTopic
        c.announceKey = req.announce ?? c.announceKey
        c.remoteName = req.name ?? c.remoteName
        c.directoryState = "active"
        if keyChanged { c.verified = false; c.keyChangedAt = .now }
        let moving = req.movedFrom.flatMap { contact($0) }
        if !silent && moving == nil { c.groupOnly = nil; friendsAgain(req.username) }      // accepted by the user: a real friend now
        if let previous = moving {
            // Everything that was ours about this friend moves over; verification doesn't (the keys are new).
            c.nickname = previous.nickname
            c.disappearAfter = previous.disappearAfter
            c.groupOnly = previous.groupOnly
            c.addedAt = previous.addedAt
            c.lastSeen = previous.lastSeen
            c.remoteName = req.name ?? previous.remoteName
            c.verified = false
            c.keyChangedAt = previous.verified ? .now : nil
        }
        saveContact(c)
        if let previous = moving { finishMove(from: previous, to: c, req: req) }
        let item = ControlItem(id: req.id, kind: .acceptance, contact: req.username, topic: req.inboxTopic, envelope: env, createdAt: .now)
        try store.save(item)
        remember(req.id, .accepted)
        requestRetry[item.id] = .distantPast
        try? store.deleteRequest(incoming: req.id)
        incomingRequests.removeAll { $0.id == req.id }
        if let out = outgoingRequests.first(where: { $0.username == req.username }) { cancelRequest(out) }
        if !silent {
            let text = req.formerFriend == true
                ? "\(req.name ?? req.username) followed you to your new username."
                : "You're now connected."
            systemMessage(text, with: req.username)
        }
        rebuildSummaries()
        tick()
    }

    /// A contact restored their account under a new username: their conversation, groups and settings follow.
    private func finishMove(from previous: Contact, to c: Contact, req: IncomingRequest) {
        let old = previous.username, new = c.username
        try? store.migrateConversation(from: old, to: new)
        links[old]?.close(.normal)
        links[old] = nil
        contacts.removeAll { $0.username == old }
        threads[old] = nil
        threads[new] = nil
        for r in outgoingRequests where r.username == old { cancelRequest(r) }
        for r in incomingRequests where r.username == old { try? store.deleteRequest(incoming: r.id) }
        incomingRequests.removeAll { $0.username == old }
        var gone = movedAway
        gone[old] = MovedAway(old: old, new: new, oldBundleRaw: previous.bundleRaw, at: .now)
        movedAway = gone
        let proof = req.moveProof.map { PrivaGroup.MemberMove(old: old, new: new, to: me, ts: req.moveTs ?? 0, sig: $0) }
        groups.contactMoved(old: old, new: new, bundleRaw: c.bundleRaw, inbox: c.inboxTopic, proof: proof)
        if c.groupOnly != true {
            let who = previous.displayName == old ? "@\(old)" : previous.displayName
            systemMessage("\(who) restored their account and is now @\(new)" + (previous.verified ? ". Verify their keys again in person." : "."), with: new)
            toast = Toast(title: "\(previous.displayName) is back", body: "Restored from a backup as @\(new).", contact: new)
        }
        rebuildSummaries()
        refreshTopics()
    }

    /// Friends who restored a backup and moved to a new username (old → where they went), kept 90 days.
    private(set) var movedAway: [String: MovedAway] {
        get { (store.get([String: MovedAway].self, for: "moved-away") ?? [:]).filter { $0.value.at.timeIntervalSinceNow > -90 * 86_400 } }
        set { try? store.set(newValue, for: "moved-away") }
    }

    /// "Accept all" for friends who followed us to a new username.
    func acceptAllFormerFriends() {
        for r in incomingRequests where r.formerFriend == true { try? accept(r) }
    }

    func decline(_ req: IncomingRequest) {
        sendDecline(req)
        remember(req.id, .declined)
        try? store.deleteRequest(incoming: req.id)
        incomingRequests.removeAll { $0.id == req.id }
    }

    private func sendDecline(_ req: IncomingRequest) {
        guard let (env, _) = try? FriendProtocol.makeAcceptance(from: me, identity: identity, request: req, name: nil, decline: true) else { return }
        signalOut.broadcast(api: api, [.init(topic: req.inboxTopic, event: "d", data: env)], key: "decline:" + req.id)
    }

    // MARK: answered requests (audit SEC-08, STA-18, STA-19)

    nonisolated struct HandledRequest: Codable, Sendable {
        enum Outcome: String, Codable, Sendable { case accepted, declined, withdrawn }
        let at: Date
        let outcome: Outcome
    }

    /// Request ids this iPhone already answered, for as long as a request can still arrive (30 days).
    private var handledRequests: [String: HandledRequest] {
        get { (store.get([String: HandledRequest].self, for: "requests-handled") ?? [:]).filter { $0.value.at.timeIntervalSinceNow > -OutgoingRequest.lifetime } }
        set { try? store.set(newValue, for: "requests-handled") }
    }

    private func remember(_ rid: String, _ outcome: HandledRequest.Outcome) {
        var h = handledRequests
        h[rid] = HandledRequest(at: h[rid]?.at ?? .now, outcome: outcome)
        handledRequests = h
    }

    /// The same request again (same id): its sender is still retrying because our answer hasn't reached them yet,
    /// or someone replays it. The first answer goes again; nothing new is made: a fresh pair root here would leave
    /// the two phones with different keys and the friendship silently broken.
    private func repeatedRequest(_ o: FriendProtocol.OpenedRequest, _ h: HandledRequest) {
        let p = o.payload
        diagnostics.repeatedRequests += 1
        switch h.outcome {
        case .accepted:
            if ((try? store.controlItems()) ?? []).contains(where: { $0.id == p.rid }) { requestRetry[p.rid] = .distantPast }
        case .declined:
            sendDecline(IncomingRequest(id: p.rid, username: p.from, bundleRaw: o.bundle.raw, inboxTopic: p.inbox,
                                        exporter: o.exporter, transcript: o.transcript, note: nil, receivedAt: .now))
        case .withdrawn:
            break
        }
    }

    /// The sender withdrew a request: it disappears. If it was already accepted and they never confirmed, the
    /// friendship never started on their side, so it's undone here too (no one-sided contact whose messages queue).
    private func requestWithdrawn(_ rid: String, by from: String) {
        let before = handledRequests[rid]
        remember(rid, .withdrawn)
        if incomingRequests.contains(where: { $0.id == rid && $0.username == from }) {
            try? store.deleteRequest(incoming: rid)
            incomingRequests.removeAll { $0.id == rid }
        }
        let items = ((try? store.controlItems()) ?? []).filter { $0.contact == from && $0.kind == .acceptance }
        guard before?.outcome == .accepted, items.map(\.id) == [rid], let at = before?.at, let c = contact(from),
              c.groupOnly != true, abs(c.addedAt.timeIntervalSince(at)) < 10 else { return }
        try? store.deleteControl(rid)
        removeFriend(from)
        toast = Toast(title: "Request withdrawn", body: "@\(from) withdrew their friend request.", contact: nil)
    }

    nonisolated struct PendingWithdrawal: Codable, Sendable {
        let id: String
        let username: String
        let envelope: Data
        let until: Date
        var attempts = 0
    }

    @ObservationIgnored private var withdrawals: [PendingWithdrawal] = [] {
        didSet { try? store.set(withdrawals, for: "requests-withdrawn") }
    }

    /// The user cancels a sent request: it stops, and a signed notice asks the other side to drop it. Repeated like a
    /// request (they get it whenever they're online) for a week.
    func withdrawRequest(_ r: OutgoingRequest) {
        cancelRequest(r)
        guard let them = try? KeyBundle.parse(r.bundleRaw),
              let sealed = try? FriendProtocol.makeRequest(from: me, identity: identity, myBundle: myBundle, to: r.username, them: them,
                                                           note: nil, name: nil, withdraws: r.id) else { return }
        let w = PendingWithdrawal(id: sealed.rid, username: r.username, envelope: sealed.envelope, until: .now.addingTimeInterval(7 * 86_400))
        withdrawals.append(w)
        sendWithdrawal(w)
    }

    private func sendWithdrawal(_ w: PendingWithdrawal) {
        requestRetry[w.id] = Date().addingTimeInterval(min(300, 15 * pow(1.5, Double(w.attempts))) * .random(in: 0.8...1.2))
        if let i = withdrawals.firstIndex(where: { $0.id == w.id }) { withdrawals[i].attempts += 1 }
        let username = w.username, env = w.envelope, api = self.api
        signalOut.enqueue(key: "req:" + w.id) {
            await SignalOutbox.deliver(api, [.init(topic: UsernameKey.requestTopic(username), event: "r", data: env)])
        }
    }

    private func processAcceptance(_ data: Data) {
        let me = self.me, identity = self.identity, outgoing = outgoingRequests
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let (req, opened) = try? FriendProtocol.openAcceptance(data, me: me, identity: identity, outgoing: outgoing) else {
                await MainActor.run { self?.diagnostics.rejectedEnvelopes += 1 }
                return
            }
            await MainActor.run { self?.receivedAcceptance(req, opened) }
        }
    }

    private func receivedAcceptance(_ req: OutgoingRequest, _ o: FriendProtocol.OpenedAcceptance) {
        cancelRequest(req)
        guard let pair = o.pair else {
            toast = Toast(title: "Request declined", body: "@\(req.username) declined your request.", contact: nil)
            return
        }
        var c = Contact(username: req.username, bundleRaw: req.bundleRaw, pair: pair, inboxTopic: o.payload.inbox)
        c.announceKey = o.payload.announce
        c.remoteName = o.payload.name.flatMap { TextSafety.name($0) }
        c.directoryState = "active"
        if req.migratesContact == nil, var existing = contact(req.username), existing.bundle == c.bundle {
            // Re-key of an existing friendship (after a restore): fresh pair keys, everything else kept, no noise.
            // A group-only contact who accepted our friend request becomes a real friend.
            let becameFriend = req.rekey != true && existing.groupOnly == true
            if becameFriend { existing.groupOnly = nil }
            existing.pair = pair
            existing.inboxTopic = o.payload.inbox
            existing.announceKey = o.payload.announce ?? existing.announceKey
            existing.remoteName = o.payload.name.flatMap { TextSafety.name($0) } ?? existing.remoteName
            existing.directoryState = "active"
            saveContact(existing)
            sendSignal(.welcome(rid: req.id, ts: Signal.now), to: existing, root: pair.current)
            links[req.username]?.close(.superseded)
            nextAttempt[req.username] = .distantPast
            refreshTopics()
            if becameFriend {
                systemMessage("You're now connected.", with: req.username)
                rebuildSummaries()
            }
            return
        }
        if let old = req.migratesContact, let previous = contact(old) {
            // A friend we followed to their new username: carry the conversation and preferences over.
            c.nickname = previous.nickname
            c.disappearAfter = previous.disappearAfter
            c.remoteName = o.payload.name.flatMap { TextSafety.name($0) } ?? previous.pendingRename?.name ?? previous.remoteName
            saveContact(c)
            try? store.migrateConversation(from: old, to: req.username)
            links[old]?.close(.normal)
            contacts.removeAll { $0.username == old }
            threads[old] = nil
            threads[req.username] = nil
            systemMessage("@\(old) is now @\(req.username), with new keys.", with: req.username)
        } else {
            saveContact(c)
            systemMessage("You're now connected.", with: req.username)
        }
        sendSignal(.welcome(rid: req.id, ts: Signal.now), to: c, root: pair.current)
        rebuildSummaries()
        refreshTopics()
        toast = Toast(title: "Request accepted", body: "You and \(c.displayName) are now connected.", contact: req.username)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func saveToPhotos(_ a: Attachment) {
        let store = self.store
        Task { [weak self] in          // the Photos permission prompt can wait as long as the user does
            do {
                try await MediaSaver.save(a, store: store)
                self?.toast = Toast(title: "Saved to Photos", body: a.kind == .video ? "The video is in your library." : "The photo is in your library.", contact: nil)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch MediaSaver.Failure.denied {
                self?.toast = Toast(title: "Can't save to Photos", body: "Allow Priva to add photos in the Settings app.", contact: nil)
            } catch {
                self?.toast = Toast(title: "Couldn't save", body: "Try again.", contact: nil)
            }
        }
    }

    // MARK: group media retention

    static let groupMediaRetention: TimeInterval = 90 * 86_400

    /// Group chats keep media for 90 days: older files are deleted from this iPhone (and stop being served
    /// by a host). The message stays, marked as expired; its key and thumbnail are wiped too.
    func pruneGroupMedia(now: Date = .now) {
        for g in groups.groups.values {
            for var m in (try? store.mediaMessages(in: g.threadKey, before: now.addingTimeInterval(-Self.groupMediaRetention))) ?? [] {
                guard var a = m.attachment else { continue }
                store.removeMedia(a.fileID)
                groups.forgetFile(a.fileID)
                MediaVault.shared.releasePlayer(a.fileID)
                a.expired = true
                a.key = Data()
                a.thumbnail = nil
                m.attachment = a
                try? store.save(m)
                threads[m.contact]?.removeAll { $0.id == m.id }
                upsertInThread(m)
            }
        }
    }

    // MARK: restore

    /// After a restore (always under a new username): prove the move to every friend and fellow group member with
    /// the old keys, then forget those keys.
    func reconnectAfterRestore() {
        guard store.get(Bool.self, for: "restore.reconnect") == true else { return }
        if let prev = store.get(RestoredFrom.self, for: "restore.previous"), prev.username != me,
           let old = try? IdentityKeys(seed: prev.seed) {
            groups.selfMoved(from: prev.username)
            // Not to anyone blocked: they'd learn the new username.
            for c in contacts where !c.looksGone && !isBlocked(c.username) {
                guard let b = c.bundle else { continue }
                let ts = Signal.now
                let proof = try? MoveProof.sign(old: old, oldUsername: prev.username, newUsername: me, newBundle: myBundle, to: c.username, ts: ts)
                try? sendFriendRequest(to: FoundUser(username: c.username, bundle: b), note: nil, renamedFrom: prev.username,
                                       rekey: true, moved: proof, ts: ts)
            }
            for r in prev.reissue where contact(r.username) == nil && !isBlocked(r.username) {
                guard let b = try? KeyBundle.parse(r.bundleRaw) else { continue }
                try? sendFriendRequest(to: FoundUser(username: r.username, bundle: b), note: r.note)
            }
            store.removeValue(for: "restore.previous")
            store.removeValue(for: "restore.abandoned")
        }
        store.removeValue(for: "restore.reconnect")
    }

    /// Old iPhone: set when this account was restored (or signed back in) on another iPhone.
    private(set) var accountMoved: AccountMovedNotice?

    /// A notice on our own inbox, sealed with our announce key and signed with our identity: only whoever holds
    /// this account's keys (a restored backup, the recovery phrase) can send it.
    private func processOwnMove(_ data: Data) {
        let key = identity.announceKey, mine = myBundle, me = self.me
        Task.detached(priority: .utility) { [weak self] in
            guard let p = try? Announcement.open(data, announceKey: key, pinned: mine, oldUsername: me), p.new != me else { return }
            await MainActor.run {
                guard let self, self.accountMoved == nil else { return }
                // Not offline at once: this iPhone is asked "was it you?", and its answer reaches friends over the
                // connections they already trust (audit SEC-04). It goes read-only once the move is settled.
                let n = AccountMovedNotice(newUsername: p.new, at: .now)
                self.accountMoved = n
                try? self.store.set(n, for: "account.moved")
                self.toast = Toast(title: "Was this you?", body: "Your account is being moved to @\(p.new) on another iPhone.", contact: nil)
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
        }
    }

    // MARK: moves held for the old iPhone's answer (audit SEC-04)

    /// A friend's signed move to a new username, waiting. The old iPhone is asked; without an answer it's followed
    /// at `followAt`, and the chat offers to follow sooner.
    struct PendingMove: Codable, Sendable { var request: IncomingRequest; var followAt: Date }
    struct MoveAnswer: Codable, Sendable { let new: String; let mine: Bool; let at: Date }

    #if DEBUG
    /// Tests: a shorter wait (the friends of a restored test account would otherwise wait 12 hours).
    nonisolated(unsafe) static var debugMoveWait: TimeInterval?
    static var moveWait: TimeInterval { debugMoveWait ?? 12 * 3600 }
    #else
    static let moveWait: TimeInterval = 12 * 3600
    #endif

    /// Old username → the move waiting for it.
    private(set) var pendingMoves: [String: PendingMove] = [:]

    private func savePendingMoves(_ m: [String: PendingMove]) {
        pendingMoves = m
        try? store.set(m, for: "moves.pending")
    }

    /// Answers old iPhones sent (kept 30 days: a request can arrive after the answer).
    private var moveAnswers: [String: MoveAnswer] {
        get { (store.get([String: MoveAnswer].self, for: "moves.answers") ?? [:]).filter { $0.value.at.timeIntervalSinceNow > -30 * 86_400 } }
        set { try? store.set(newValue, for: "moves.answers") }
    }

    /// Friends this (old) iPhone still has to tell its answer.
    private var moveAnswerQueue: Set<String> {
        get { Set(store.get([String].self, for: "moves.answer-queue") ?? []) }
        set { try? store.set(Array(newValue), for: "moves.answer-queue") }
    }

    private func holdMove(_ req: IncomingRequest, from old: String) {
        if let a = moveAnswers[old], a.new == req.username {
            if a.mine { try? accept(req, silent: true) } else { moveRefused(req.username, from: old, byOldPhone: true) }
            return
        }
        guard pendingMoves[old]?.request.username != req.username else { return }       // a resend
        var moves = pendingMoves
        moves[old] = PendingMove(request: req, followAt: Date().addingTimeInterval(Self.moveWait))
        savePendingMoves(moves)
        let who = contact(old).map { $0.displayName == old ? "@\(old)" : $0.displayName } ?? "@\(old)"
        let hours = max(1, Int((Self.moveWait / 3600).rounded()))
        systemMessage("\(who) restored their account on another iPhone as @\(req.username). Priva follows in \(hours) hour\(hours == 1 ? "" : "s"), "
                      + "or as soon as their old iPhone confirms. If their old iPhone says it wasn't them, you won't follow.", with: old)
        toast = Toast(title: "\(who) is moving", body: "Restored on another iPhone as @\(req.username).", contact: old)
        rebuildSummaries()
    }

    /// From the chat: follow now (the user has heard from their friend).
    func followMoveNow(of old: String) {
        guard let pm = pendingMoves[old] else { return }
        var moves = pendingMoves
        moves[old] = nil
        savePendingMoves(moves)
        try? accept(pm.request, silent: true)
    }

    /// From the chat: "not them", don't follow, and keep the friend as they were.
    func refuseMove(of old: String) {
        guard let pm = pendingMoves[old] else { return }
        var moves = pendingMoves
        moves[old] = nil
        savePendingMoves(moves)
        moveRefused(pm.request.username, from: old, byOldPhone: false)
    }

    private func followDueMoves() {
        let now = Date()
        for (old, pm) in pendingMoves where pm.followAt <= now { followMoveNow(of: old) }
    }

    /// The old account's own iPhone answered, over the connection we pinned for it (no one else can send this).
    private func moveAnswered(by old: String, new: String, mine: Bool) {
        guard contact(old) != nil else { return }
        var answers = moveAnswers
        answers[old] = MoveAnswer(new: new, mine: mine, at: .now)
        moveAnswers = answers
        if let pm = pendingMoves[old], pm.request.username == new {
            if mine { followMoveNow(of: old) } else {
                var moves = pendingMoves
                moves[old] = nil
                savePendingMoves(moves)
                moveRefused(new, from: old, byOldPhone: true)
            }
        } else if !mine {
            moveRefused(new, from: old, byOldPhone: true)
        }
        // Signing back in without a backup asks first anyway (pendingRename): the old iPhone's answer settles it.
        if let r = contact(old)?.pendingRename, r.newUsername == new {
            if mine { try? acceptRename(of: old) } else { dismissRename(of: old) }
        }
    }

    private func moveRefused(_ new: String, from old: String, byOldPhone: Bool) {
        for r in incomingRequests where r.username == new && r.movedFrom == old { try? store.deleteRequest(incoming: r.id) }
        incomingRequests.removeAll { $0.username == new && $0.movedFrom == old }
        let who = contact(old).map { $0.displayName == old ? "@\(old)" : $0.displayName } ?? "@\(old)"
        if byOldPhone {
            systemMessage("\(who)'s own iPhone says it didn't move to @\(new). Someone else has their recovery phrase or a backup: "
                          + "don't trust @\(new), and tell \(who) in person.", with: old)
            toast = Toast(title: "Security warning", body: "\(who) says the move to @\(new) wasn't them.", contact: old)
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        } else {
            systemMessage("You didn't follow @\(new).", with: old)
        }
        rebuildSummaries()
    }

    /// The old iPhone: "was it you?" Its answer reaches every friend over the connection they already trust: "yes"
    /// lets them follow at once, "no" stops them following and warns them.
    func answerMove(mine: Bool) {
        guard var n = accountMoved, n.answer == nil else { return }
        n.answer = mine
        accountMoved = n
        try? store.set(n, for: "account.moved")
        moveAnswerQueue = Set(contacts.map(\.username))
        for (peer, l) in links where l.isReady {
            l.send(.moveAnswer(new: n.newUsername, mine: mine))
            if l.isReady { var q = moveAnswerQueue; q.remove(peer); moveAnswerQueue = q }
        }
        tick()
    }

    /// Settled: told "it was me" to everyone (or the wait is over), or nothing answered in time. Then this iPhone
    /// keeps a read-only copy and stays offline. "It wasn't me" never settles: the account carries on here.
    var moveSettled: Bool {
        guard let n = accountMoved else { return false }
        if n.answer == false { return false }
        let waited = Date().timeIntervalSince(n.at) > Self.moveWait
        return waited || (n.answer == true && moveAnswerQueue.isEmpty)
    }

    private func settleMoveIfDue() {
        guard accountMoved != nil, moveSettled, realtimeStatus != .disconnected else { return }
        realtime.disconnect()
        for l in links.values { l.close(.normal) }
    }

    // MARK: identity lifecycle (IDENTITY_DESIGN §5–7), all decided on this device

    @ObservationIgnored private(set) var migration = MigrationState()
    @ObservationIgnored private var lastAnnounce = Date.distantPast
    @ObservationIgnored private var lastDirectorySweep = Date.distantPast
    @ObservationIgnored private var leaseChecked = false

    /// Derived from this engine's own username (scrypt, so memoised). The Keychain meta is only a cache and
    /// is used only when it belongs to the same username, never another account's identity.
    var myRequestTopic: String {
        if let t = requestTopicCache { return t }
        // Not cached if it couldn't be worked out (memory pressure): the next call tries again (audit STA-32).
        guard let t = Vault.meta.flatMap({ $0.username == me ? $0.requestTopic : nil }) ?? (try? UsernameKey.requestTopicStrict(me))
        else { return UsernameKey.requestTopic(me) }
        requestTopicCache = t
        return t
    }
    @ObservationIgnored private var requestTopicCache: String?

    private func loadMigration() { migration = store.get(MigrationState.self, for: "migration") ?? MigrationState() }
    func saveMigration(_ m: MigrationState) { migration = m; try? store.set(m, for: "migration") }

    func markPhraseUnsaved() { phraseUnsaved = true; try? store.set(true, for: "phrase.unsaved") }
    func phraseSaved() { guard phraseUnsaved else { return }; phraseUnsaved = false; store.removeValue(for: "phrase.unsaved") }

    /// Topics to listen on, each with the key that owns it on the relay: our inbox and request topics (keys from
    /// our seed) and, for friends who look gone, their announcement topics (keys from their announce key, which only
    /// their friends hold). Never all friends' topics: that would expose the friend graph through subscriptions.
    func refreshTopics() {
        var topics: [String: Curve25519.Signing.PrivateKey] = [:]
        for t in [identity.inboxTopic, myRequestTopic] { topics[t] = ListenKey.derive(identity.seed, topic: t) }
        let gone = contacts.filter { $0.looksGone && $0.announceKey != nil && $0.pendingRename == nil }.prefix(8)
        for c in gone {
            let t = Announcement.topic(announceKey: c.announceKey!)
            topics[t] = ListenKey.derive(c.announceKey!, topic: t)
        }
        realtime.setTopics(topics)
    }

    /// Keeps our own username "active" while Priva is in use (≤ one signed renewal a week).
    private func maintainLease() {
        guard !leaseChecked else { return }
        leaseChecked = true
        let commit = myBundle.ucommit, identity = self.identity, api = self.api
        let delay = Double.random(in: 4...40)
        Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let entry = try? await api.lookup(commit: commit) else { return }
            var state = entry.status
            // A lapsed lease (e.g. restoring a backup weeks later) still has its row and keys: renewing revives it.
            let lapsed = entry.status == .uninstalled && entry.bundle != nil
            if lapsed || (entry.status == .active && (entry.leaseWeek?.timeIntervalSinceNow ?? 0) < 14 * 86_400) {
                if (try? await api.renew(ucommit: commit, identity: identity)) != nil, lapsed { state = .active }
            }
            await MainActor.run { self?.ownDirectoryState = state }
        }
    }

    private(set) var ownDirectoryState: PrivaAPI.DirectoryEntry.Status?

    /// Friends' side: check (at most daily) whether contacts who went quiet still exist.
    private func sweepDirectory() {
        guard Date().timeIntervalSince(lastDirectorySweep) > 60 else { return }
        lastDirectorySweep = .now
        // Each lookup tells the directory server "this IP asked about that friend", so as few as possible (audit
        // SEC-13): real friends only (no hidden group links, nobody blocked), and a friend last seen active is asked
        // about weekly, not daily.
        let due = contacts.filter { c in
            guard c.groupOnly != true, !isBlocked(c.username), c.pendingRename == nil else { return false }
            let quiet = (c.lastSeen ?? c.addedAt).timeIntervalSinceNow < -48 * 3600
            let every: TimeInterval = c.directoryState == "active" ? 7 * 86_400 : 86_400
            let stale = (c.directoryCheckedAt ?? .distantPast).timeIntervalSinceNow < -every
            return quiet && stale
        }.prefix(3)
        for c in due {
            let name = c.username, api = self.api
            Task.detached(priority: .utility) { [weak self] in
                guard let entry = try? await api.lookup(name) else { return }
                await MainActor.run { self?.updateDirectoryState(name, entry.status) }
            }
        }
    }

    func updateDirectoryState(_ username: String, _ status: PrivaAPI.DirectoryEntry.Status) {
        guard var c = contact(username) else { return }
        c.directoryState = status == .active ? "active" : status == .uninstalled ? "uninstalled" : "removed"
        c.directoryCheckedAt = .now
        saveContact(c)
        rebuildSummaries()
        refreshTopics()
        if c.looksGone { groups.checkFailover(force: true) }
    }

    /// Returning user's side: rebroadcast rename announcements and remove previous usernames.
    private func runMigrationDuties() {
        let now = Date()
        var m = migration
        let before = (m.announcements.count, m.revocations.count)
        m.announcements.removeAll { $0.until < now }
        // Every minute on the first day, then hourly: friends who were offline still hear it, without two relay
        // messages a minute for a month (audit STA-40).
        let firstDay = m.announcements.contains { ($0.created ?? .distantPast).timeIntervalSince(now) > -86_400 }
        if now.timeIntervalSince(lastAnnounce) > (firstDay ? 60 : 3600), !m.announcements.isEmpty {
            lastAnnounce = now
            signalOut.broadcast(api: api, m.announcements.map { .init(topic: $0.topic, event: "m", data: $0.envelope) }, key: "announce")
        }
        // One request at a time per username, backing off 30 s → 1 h while the server fails (this runs every tick:
        // it used to start a new request each time, audit STA-12).
        for r in m.revocations where r.notBefore <= now && now >= revokeRetry[r.ucommit, default: .distantPast]
            && !revoking.contains(r.ucommit) {
            let api = self.api
            revoking.insert(r.ucommit)
            Task.detached(priority: .utility) { [weak self] in
                do {
                    try await api.revoke(ucommit: r.ucommit, secret: r.secret)
                } catch APIError.http(404, _) {
                    // Already removed.
                } catch {
                    await MainActor.run {
                        guard let self else { return }
                        self.revoking.remove(r.ucommit)
                        let n = (self.revokeFailures[r.ucommit] ?? 0) + 1
                        self.revokeFailures[r.ucommit] = n
                        self.revokeRetry[r.ucommit] = Date().addingTimeInterval(min(3600, 30 * pow(2, Double(n - 1))))
                    }
                    return
                }
                await MainActor.run {
                    guard let self else { return }
                    self.revoking.remove(r.ucommit)
                    self.revokeFailures[r.ucommit] = nil
                    var mm = self.migration
                    mm.revocations.removeAll { $0.ucommit == r.ucommit }
                    self.saveMigration(mm)
                    if Vault.revocationRecord?.ucommit == r.ucommit { Vault.clearRevocation() }
                }
            }
        }
        if (m.announcements.count, m.revocations.count) != before { saveMigration(m) }
    }

    private func processAnnouncement(_ data: Data, topic: String) {
        guard let c = contacts.first(where: { $0.announceKey.map { Announcement.topic(announceKey: $0) } == topic }),
              let key = c.announceKey, let pinned = c.bundle else { return }
        let old = c.username, lastGen = c.announceGeneration ?? -1
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let p = try? Announcement.open(data, announceKey: key, pinned: pinned, oldUsername: old), p.generation > lastGen,
                  let bundle = try? KeyBundle.parse(p.bundle), bundle.belongs(to: p.new),
                  let entry = try? await PrivaAPI.shared.lookup(commit: bundle.ucommit), entry.status == .active, entry.bundle == bundle else {
                await MainActor.run { self?.diagnostics.rejectedEnvelopes += 1 }
                return
            }
            await MainActor.run { self?.receivedRename(old: old, payload: p, bundle: bundle) }
        }
    }

    private func receivedRename(old: String, payload p: Announcement.Payload, bundle: KeyBundle) {
        guard var c = contact(old), !isBlocked(old) else { return }
        c.announceGeneration = p.generation
        c.pendingRename = Contact.PendingRename(newUsername: p.new, bundleRaw: bundle.raw, name: p.name, receivedAt: .now)
        saveContact(c)
        refreshTopics()
        rebuildSummaries()
        toast = Toast(title: "\(c.displayName) has a new username", body: "@\(old) is now @\(p.new). Tap to update.", contact: old)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Friend taps "Update": befriend the new username with a proof that we were friends before.
    func acceptRename(of old: String) throws {
        guard let c = contact(old), let r = c.pendingRename, let key = c.announceKey, let bundle = try? KeyBundle.parse(r.bundleRaw) else { return }
        let proof = Announcement.renameProof(announceKey: key, friend: me, newUsername: r.newUsername)
        try sendFriendRequest(to: FoundUser(username: r.newUsername, bundle: bundle), note: nil,
                              renameProof: proof, renamedFrom: old, migrates: old)
        systemMessage("Update sent to @\(r.newUsername). The conversation moves over once they confirm.", with: old)
    }

    func dismissRename(of old: String) {
        guard var c = contact(old) else { return }
        c.pendingRename = nil
        saveContact(c)
        rebuildSummaries()
    }

    private func systemMessage(_ text: String, with username: String) {
        persist(Message(id: UUID().uuidString, contact: username, outgoing: false, kind: .system, text: text, attachment: nil,
                        sentAt: .now, receivedAt: .now, status: .received, readAt: .now))
    }

    /// Hidden group links (fellow members who aren't friends) once no live group needs them: they'd otherwise pile up,
    /// keep their keys and be tried on every signal (audit STA-20, SEC-11).
    func dropUnusedGroupLinks() {
        for c in contacts where c.groupOnly == true && !groups.sharesGroup(with: c.username) { removeFriend(c.username) }
    }

    func removeFriend(_ username: String) {
        links[username]?.close(.normal)
        links[username] = nil
        // Every file of the chat, loaded or not: the rows (and with them the files' keys) go next (audit STA-25).
        for f in (try? store.mediaFileIDs(for: username)) ?? [] { store.removeMedia(f); MediaVault.shared.forget(f) }
        try? store.deleteContact(username)
        contacts.removeAll { $0.username == username }
        threads[username] = nil
        rebuildSummaries()
    }

    // MARK: blocking

    /// People this user blocked: their friend requests, messages, calls and group invites are dropped, and their
    /// posts in groups you share are hidden. Stays on this iPhone; the blocked person isn't told.
    private(set) var blocked: [BlockedUser] = []

    func isBlocked(_ username: String?, key: Data? = nil) -> Bool {
        guard let username else { return false }
        return blocked.contains { $0.username == username || (key != nil && $0.identityKey == key) }
    }

    func block(_ username: String) {
        guard !isBlocked(username) else { return }
        let bundle = contact(username)?.bundle ?? incomingRequests.first { $0.username == username }.flatMap { try? KeyBundle.parse($0.bundleRaw) }
        blocked.append(BlockedUser(username: username, identityKey: bundle?.verifying.ed.rawRepresentation, at: .now))
        try? store.set(blocked, for: "blocked")
        for r in incomingRequests where r.username == username { try? store.deleteRequest(incoming: r.id) }
        incomingRequests.removeAll { $0.username == username }
        for r in outgoingRequests where r.username == username { cancelRequest(r) }
        groups.dropInvites(from: username)
        if calls.call?.peer == username { calls.hangUp() }
        guard var c = contact(username) else { rebuildSummaries(); return }
        if groups.sharesGroup(with: username) {
            // Still in a group together: only the hidden group link remains, and it carries no 1:1 traffic.
            deleteThread(username)
            threads[username] = nil
            c.groupOnly = true
            saveContact(c)
            links[username]?.close(.normal)
            links[username] = nil
            rebuildSummaries()
        } else {
            removeFriend(username)
        }
    }

    /// They can send a friend request again; being friends again needs a new request.
    func unblock(_ username: String) {
        guard let b = blocked.first(where: { $0.username == username }) else { return }
        blocked.removeAll { $0.username == username }
        try? store.set(blocked, for: "blocked")
        var past = pastBlocks
        past[username] = DateInterval(start: b.at, end: .distantFuture)
        pastBlocks = past
    }

    /// When each unblocked person was blocked, until the friendship started again. What they wrote in that time
    /// waited on their iPhone (they were never told) and would arrive all at once after a new request: it never
    /// shows, as if the block had dropped it. Times are this iPhone's own: the block's start and the new friendship.
    private var pastBlocks: [String: DateInterval] {
        get { (store.get([String: DateInterval].self, for: "blocked.past") ?? [:]).filter { $0.value.start.timeIntervalSinceNow > -86_400 * 365 } }
        set { try? store.set(newValue, for: "blocked.past") }
    }

    /// Asking (or accepting) to be friends again closes the window: from now on what they send is shown.
    private func friendsAgain(_ username: String) {
        var past = pastBlocks
        guard let w = past[username], w.end == .distantFuture else { return }
        past[username] = DateInterval(start: w.start, end: .now)
        pastBlocks = past
    }

    /// Written while they were blocked (by their own timestamp: skewing it only hides their own messages).
    func sentWhileBlocked(_ username: String, at sent: Date) -> Bool {
        guard let w = pastBlocks[username] else { return false }
        return sent >= w.start && sent < w.end
    }

    func setNickname(_ username: String, _ name: String) {
        guard var c = contact(username) else { return }
        let n = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        c.nickname = n.isEmpty ? nil : n
        saveContact(c)
        rebuildSummaries()
    }

    func clearCallHistory() {
        try? store.clearCalls()
        callHistory = []
    }

    func setVerified(_ username: String, _ on: Bool) {
        guard var c = contact(username) else { return }
        c.verified = on
        if on { c.keyChangedAt = nil }
        saveContact(c)
        rebuildSummaries()
    }

    func setDisappearing(_ username: String, _ seconds: TimeInterval?) {
        guard var c = contact(username) else { return }
        c.disappearAfter = seconds
        saveContact(c)
        let label = seconds.map { "Disappearing messages set to \(Self.durationLabel($0))." } ?? "Disappearing messages turned off."
        systemMessage(label, with: username)
    }

    static func durationLabel(_ s: TimeInterval) -> String {
        switch s {
        case ..<3600: return "\(Int(s / 60)) minutes"
        case ..<86_400: return "\(Int(s / 3600)) hours"
        default: return "\(Int(s / 86_400)) days"
        }
    }

    /// Removes what's past its time, and refreshes those chats' rows: the chat list must not keep showing a message
    /// that has disappeared (audit STA-06).
    private func expireDisappearing() {
        let gone = (try? store.expireMessages()) ?? []
        guard !gone.isEmpty else { return }
        for m in gone {
            if let f = m.attachment?.fileID {
                store.removeMedia(f)
                MediaVault.shared.forget(f)
            }
            threads[m.contact]?.removeAll { $0.id == m.id }
        }
        for contact in Set(gone.map(\.contact)) { updateSummary(contact) }
    }

    func recordCall(_ r: CallRecord) {
        try? store.save(r)
        callHistory.insert(r, at: 0)
        let icon = r.video ? "Video call" : "Voice call"
        let text: String
        switch r.outcome {
        case .answered: text = "\(icon) · \(Self.clock(r.duration))"
        case .missed: text = "Missed \(icon.lowercased())"
        case .declined: text = "\(icon) declined"
        case .cancelled: text = r.outgoing ? "\(icon) · no answer" : "Missed \(icon.lowercased())"
        case .failed: text = "\(icon) failed"
        }
        persist(Message(id: UUID().uuidString, contact: r.contact, outgoing: r.outgoing, kind: .call, text: text, attachment: nil,
                        sentAt: r.startedAt, receivedAt: .now, status: .received, readAt: .now))
    }

    static func clock(_ t: TimeInterval) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }

    // MARK: incoming files

    /// Files up to this size download by themselves; bigger ones wait for a tap, so a friend (or a group) can't fill
    /// this iPhone or its data plan without the user choosing to (audit SEC-12).
    static let autoDownloadLimit: UInt64 = 100 << 20

    /// Room for `bytes` more, keeping some free for everything else on the iPhone.
    nonisolated static func hasRoom(for bytes: UInt64) -> Bool {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard let free = (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        else { return true }
        return free > Int64(clamping: bytes) + 300 << 20
    }

    /// `userAsked`: the user tapped Download, or this iPhone hosts the group and must hold the file to pass it on.
    func beginIncoming(_ att: Attachment, messageID: String, from peer: String, link: PeerLink?, userAsked: Bool = false) {
        guard let header = try? FileCipherHeader(att.header), header.plainSize == att.size, att.key.count == 32 else { return }
        if !userAsked, att.size > Self.autoDownloadLimit || !Self.hasRoom(for: att.size) {
            hold(messageID)
            return
        }
        guard let writer = try? FileCipher.Writer(url: store.mediaURL(att.fileID), header: header, key: SymmetricKey(data: att.key), resume: false) else { return }
        transfers.begin(fileID: att.fileID, messageID: messageID, contact: peer, writer: writer)
        incomingFiles[att.fileID] = FileRef(message: messageID, contact: peer)
        // Without a connection yet, the request goes when it's ready (linkDidBecomeReady asks for what's missing).
        link?.send(.fileWant(fileID: att.fileID, missing: Array(0..<header.chunkCount)))
    }

    private func hold(_ messageID: String) {
        guard var m = try? store.message(messageID), var att = m.attachment, att.held != true else { return }
        att.held = true
        m.attachment = att
        persist(m)
    }

    /// The user tapped Download on a held file.
    func download(_ m: Message) {
        guard var att = m.attachment, att.held == true else { return }
        guard Self.hasRoom(for: att.size) else {
            toast = Toast(title: "Not enough space", body: "Free up \(Format.bytes(att.size)) to download this.", contact: nil)
            return
        }
        att.held = nil
        var mm = m
        mm.attachment = att
        persist(mm)
        // Group files come from the host.
        let source = m.contact.hasPrefix("g:") ? groups.groups[String(m.contact.dropFirst(2))]?.host ?? m.contact : m.contact
        let l = link(for: source)
        beginIncoming(att, messageID: m.id, from: source, link: l?.isReady == true ? l : nil, userAsked: true)
        if l?.isReady != true { requestLink(source, intent: .data, urgent: true) }
    }

    /// After a restart: re-open partially received files, check what's already on disk (off the main thread,
    /// a big file is thousands of chunks), then ask for the rest when the sender is reachable.
    private func resumeIncomingTransfers() {
        outgoingFiles = store.get([String: FileRef].self, for: "files.outgoing") ?? [:]
        let pending = store.get([String: FileRef].self, for: "files.incoming") ?? [:]
        var resume: [(fileID: String, ref: FileRef, header: FileCipherHeader, key: SymmetricKey, url: URL)] = []
        for (fileID, ref) in pending {
            guard let m = try? store.message(ref.message), let att = m.attachment, att.fileID == fileID, !att.isComplete,
                  let header = try? FileCipherHeader(att.header) else { continue }
            resume.append((fileID, ref, header, SymmetricKey(data: att.key), store.mediaURL(fileID)))
        }
        incomingFiles = Dictionary(uniqueKeysWithValues: resume.map { ($0.fileID, $0.ref) })
        let transfers = self.transfers
        Task.detached(priority: .utility) {
            for r in resume {
                var have = IndexSet()
                if let reader = try? FileCipher.Reader(url: r.url, key: r.key) {
                    for i in 0..<r.header.chunkCount where (try? reader.plainChunk(i)) != nil { have.insert(i) }
                }
                guard let writer = try? FileCipher.Writer(url: r.url, header: r.header, key: r.key, resume: true) else { continue }
                writer.markReceived(have)
                transfers.begin(fileID: r.fileID, messageID: r.ref.message, contact: r.ref.contact, writer: writer)
            }
        }
    }

    private func incomingProgress(messageID: String, fileID: String, source: String, fraction: Double, complete: Bool) {
        guard var m = (try? store.message(messageID)), var att = m.attachment, att.fileID == fileID else { return }
        att.progress = complete ? 1 : fraction
        m.attachment = att
        if complete {
            downloadProgress[fileID] = nil
            persist(m)
            incomingFiles[fileID] = nil
            links[source]?.send(.fileDone(fileID: fileID))
            groups.fileCompleted(fileID)
        } else {
            downloadProgress[fileID] = fraction
            if Int(fraction * 100) % 10 == 0 { try? store.save(m) }
        }
    }

    // MARK: validation of untrusted envelopes

    static func isValid(_ e: Wire.Envelope) -> Bool {
        // Queued messages can arrive long after they were written, but never from the future: a far-future
        // timestamp would pin a message under everything said afterwards.
        let age = -e.sentAt.timeIntervalSinceNow
        guard UUID(uuidString: e.id) != nil, (e.text?.count ?? 0) <= 16_000, age < 86_400 * 365, age > -600 else { return false }
        if let a = e.attachment {
            guard UUID(uuidString: a.fileID) != nil, a.key.count == 32, a.size <= 8 << 30, a.name.count <= 200,
                  (a.thumbnail?.count ?? 0) <= 96 * 1024, let h = try? FileCipherHeader(a.header), h.plainSize == a.size else { return false }
        }
        if e.kind == .system || e.kind == .call { return false }
        return true
    }
}

// MARK: - PeerLinkDelegate

extension PrivaEngine: PeerLinkDelegate {
    func linkSendSignal(_ link: PeerLink, _ signal: Signal) {
        guard let c = contact(link.peer), links[link.peer] === link else { return }
        sendSignal(signal, to: c, root: link.root)
    }

    func linkDidBecomeReady(_ link: PeerLink) {
        guard links[link.peer] === link else { return }
        presence[link.peer] = .online
        attempts[link.peer] = 0
        diagnostics.lastHandshakeMs = link.connectedAt.map { $0.timeIntervalSince(link.createdAt) * 1000 }
        let pending = (try? store.pending(for: link.peer)) ?? []
        for m in pending { link.send(.message(envelope(m))); guard link.isReady else { return } }
        for f in transfers.activeFiles(for: link.peer) {
            if let missing = transfers.missing(fileID: f) { link.send(.fileWant(fileID: f, missing: missing)) }
        }
        ping(link)
        link.send(.profile(name: sharedName))
        if let n = accountMoved, let mine = n.answer, moveAnswerQueue.contains(link.peer) {
            link.send(.moveAnswer(new: n.newUsername, mine: mine))
            if link.isReady { var q = moveAnswerQueue; q.remove(link.peer); moveAnswerQueue = q }
        }
        // A send above can fail and close the link: then nothing below may treat it as ready (audit STA-34).
        guard link.isReady else { return }
        calls.linkReady(link)
        groups.linkReady(link.peer)
        groupCalls.linkReady(link)
    }

    func linkDidClose(_ link: PeerLink, reason: PeerLink.CloseReason) {
        guard links[link.peer] === link else { return }
        links[link.peer] = nil
        presence[link.peer] = .offline
        diagnostics.linkCloses["\(reason)", default: 0] += 1
        typing.remove(link.peer)
        calls.linkClosed(peer: link.peer)
        groupCalls.linkClosed(peer: link.peer)
        groups.linkClosed(link.peer)
        if reason == .authentication { diagnostics.rejectedEnvelopes += 1 }
    }

    func linkDidRatchet(_ link: PeerLink, base: Data, secret: Data) {
        guard var c = contact(link.peer) else { return }
        c.pair.ratchet(from: base, sessionSecret: secret)
        saveContact(c)
    }

    func linkMayStartMedia(_ link: PeerLink) -> Bool {
        let peer = link.peer
        if let c = calls.call, c.peer == peer, calls.isInCall { return true }
        if let g = groupCalls.call, groupCalls.isInCall {
            switch g.phase {
            case .active, .requesting: return g.host == peer || (g.host == me && g.participants.contains(peer))
            default: return false
            }
        }
        return false
    }

    func linkRemoteVideoChanged(_ link: PeerLink) {
        calls.remoteVideoChanged(link)
        groupCalls.remoteMediaChanged(link)
    }

    func link(_ link: PeerLink, didReceive wire: Wire) {
        let peer = link.peer
        // A hidden group link (a co-member who is not a friend) exists only for group traffic: no direct
        // messages, typing, read receipts or 1:1 calls, those need an accepted friend request.
        if contact(peer)?.groupOnly == true {
            switch wire {
            case .group, .fileWant, .fileDone, .profile, .ping, .pong, .bye, .moveAnswer: break
            default: diagnostics.rejectedEnvelopes += 1; return
            }
        }
        switch wire {
        case .message(let e):
            guard Self.isValid(e) else { return }
            if message(e.id, contact: peer) != nil || arriving.contains(where: { $0.message.id == e.id }) {
                link.send(.ack([e.id])); return
            }
            if sentWhileBlocked(peer, at: e.sentAt) { diagnostics.blockedDropped += 1; link.send(.ack([e.id])); return }
            var att = e.attachment
            att?.progress = 0
            var m = Message(id: e.id, contact: peer, outgoing: false, kind: e.kind, text: e.text, attachment: att, sentAt: e.sentAt,
                            receivedAt: .now, status: .received, replyTo: e.replyTo,
                            expiresAt: e.expiresIn.map { Date().addingTimeInterval(min($0, 86_400 * 30)) })
            if openChat == peer && UIApplication.shared.applicationState == .active { m.readAt = .now }
            arrived(m, on: link)
        case .ack(let ids):
            markOutgoing(ids, from: peer, as: .delivered)
        case .read(let ids):
            markOutgoing(ids, from: peer, as: .read)
        case .typing(let on):
            typingExpiry[peer]?.cancel()
            if on {
                typing.insert(peer)
                typingExpiry[peer] = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(6))
                    if !Task.isCancelled { self?.typing.remove(peer) }
                }
            } else { typing.remove(peer) }
        case .fileWant(let fileID, let missing):
            let header: FileCipherHeader
            if let owner = outgoingFiles[fileID], owner.contact == peer, let m = message(owner.message, contact: peer),
               let h = try? FileCipherHeader(m.attachment?.header ?? Data()) {
                header = h
            } else if groups.servesFile(fileID, to: peer), let reader = try? FileCipher.Reader(url: store.mediaURL(fileID)) {
                header = reader.header      // the host relays a group attachment it already holds in full
            } else {
                // Nothing to serve: say so, or the other iPhone keeps reconnecting to ask (audit STA-09).
                link.send(.fileGone(fileID: fileID))
                return
            }
            // One stream per file and peer at a time, and at most 12 asks an hour: repeated asks used to upload the
            // whole file again each time (audit SEC-12).
            let key = peer + "|" + fileID
            let recent = (fileWants[key] ?? []).filter { $0.timeIntervalSinceNow > -3600 }
            guard !streaming.contains(key), recent.count < 12 else { fileWants[key] = recent; return }
            fileWants[key] = recent + [.now]
            streaming.insert(key)
            let chunks = FileSender.chunksToSend(requested: missing, chunkCount: header.chunkCount)
            let url = store.mediaURL(fileID)
            FileSender.stream(url: url, fileID: fileID, chunks: chunks, over: link.bulk, progress: { [weak self] f in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.uploadProgress[fileID] = f } }
            }, done: { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { _ = self?.streaming.remove(key) } }
            })
        case .fileGone(let fileID):
            guard let ref = incomingFiles[fileID], ref.contact == peer else { return }
            transfers.cancel(fileID: fileID)
            incomingFiles[fileID] = nil
            store.removeMedia(fileID)
            if var m = try? store.message(ref.message), var a = m.attachment, a.fileID == fileID, !a.isComplete {
                a.unavailable = true
                m.attachment = a
                persist(m)
            }
        case .fileDone(let fileID):
            guard let owner = outgoingFiles[fileID], owner.contact == peer else { return }
            outgoingFiles[fileID] = nil
            uploadProgress[fileID] = nil
            guard var m = message(owner.message, contact: peer), var a = m.attachment else { return }
            a.progress = 1
            m.attachment = a
            persist(m)
        case .profile(let name):
            guard var c = contact(peer) else { return }
            let clean = name.flatMap { TextSafety.name($0) }
            if c.remoteName != clean {
                c.remoteName = (clean?.isEmpty ?? true) ? nil : clean
                saveContact(c)
                rebuildSummaries()
            }
        case .pong(let t):
            if let sent = pingSent.removeValue(forKey: t) { diagnostics.lastRoundTripMs = Date().timeIntervalSince(sent) * 1000 }
        case .callInvite, .callAccept, .callDecline, .callEnd, .callState:
            calls.handle(wire, from: peer, link: link)
        case .group(let p):
            groups.handle(p, from: peer, link: link)
        case .moveAnswer(let new, let mine):
            moveAnswered(by: peer, new: new, mine: mine)
        default:
            break
        }
    }

    /// Measures application-level round-trip time over the encrypted data channel.
    #if DEBUG
    /// Tests: a round-trip probe on an open link.
    func ping(_ username: String) {
        guard let l = links[username], l.isReady else { return }
        ping(l)
    }
    #endif

    private func ping(_ l: PeerLink) {
        let t = Signal.now
        pingSent = pingSent.filter { $0.value.timeIntervalSinceNow > -60 }     // unanswered pings don't pile up
        pingSent[t] = .now
        l.send(.ping(t))
    }
}

// MARK: - helpers

/// Serialises outgoing REST broadcasts per peer so that signalling arrives in order.
final class SignalOutbox {
    private var chains: [String: Task<Void, Never>] = [:]

    func enqueue(key: String, _ work: @escaping @Sendable () async -> Void) {
        let previous = chains[key]
        let task = Task.detached(priority: .userInitiated) {
            await previous?.value
            await work()
        }
        chains[key] = task
        // Forget a finished chain (keys include one per friend request, so they'd otherwise pile up).
        Task { [weak self] in
            await task.value
            if let self, self.chains[key] == task { self.chains[key] = nil }
        }
    }

    func broadcast(api: PrivaAPI, _ messages: [PrivaAPI.Outbound], key: String) {
        enqueue(key: key) { await Self.deliver(api, messages) }
    }

    /// A dropped rendezvous message (network blip, rate limit, a Tor circuit changing) is retried with jittered
    /// backoff instead of being lost, which would cost a whole handshake timeout. Signals stay valid for ±2 minutes.
    static func deliver(_ api: PrivaAPI, _ messages: [PrivaAPI.Outbound]) async {
        var delay = 0.4
        for attempt in 0..<4 {
            do { try await api.broadcast(messages); return } catch {
                if attempt == 3 { return }
                try? await Task.sleep(for: .seconds(delay * .random(in: 0.8...1.2)))
                delay *= 2
            }
        }
    }
}

/// Rejects any envelope seen in the last 10 minutes (the signal timestamp window is ±2 min).
struct ReplayCache {
    private var seen: [Data: Date] = [:]

    mutating func insert(_ digest: Data) -> Bool {
        let now = Date()
        if seen.count > 4096 { seen = seen.filter { now.timeIntervalSince($0.value) < 600 } }
        if let t = seen[digest], now.timeIntervalSince(t) < 600 { return false }
        seen[digest] = now
        return true
    }

    /// Processing failed for a reason that may pass (the directory didn't answer): let the sender's retry through.
    mutating func forget(_ digest: Data) { seen[digest] = nil }
}

// MARK: - App Store purchase ID (key files)

extension PrivaEngine {
    private static let purchaseKey = "purchase.ids"

    /// The App Store purchase IDs this account has run under, newest first. Kept in the encrypted store, so they
    /// travel inside backups (opened only with the Backup Key and password), never on a server. A key file saved on
    /// another Apple Account still opens after a restore.
    var purchaseIDs: [String] { store.get([String].self, for: Self.purchaseKey) ?? [] }

    func rememberPurchase() async {
        guard let id = try? await PurchaseService.purchaseID() else { return }
        var ids = purchaseIDs
        guard ids.first != id else { return }
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
        try? store.set(Array(ids.prefix(8)), for: Self.purchaseKey)
    }
}
