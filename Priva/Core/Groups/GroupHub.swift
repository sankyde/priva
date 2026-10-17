import CryptoKit
import Foundation
import Observation
import UIKit

/// Host-centric groups (docs/GROUPS_DESIGN.md). The same code runs on the host (the group's
/// server: rules, history, fan-out, per-member queues) and on members (post to host, receive).
@Observable
final class GroupHub {
    init() { LiveObjects.born("GroupHub") }
    deinit { LiveObjects.died("GroupHub") }

    struct Invite: Identifiable, Sendable, Codable {
        var id: String { snapshot.group.id }
        let snapshot: GroupSnapshot
        let from: String
        var received: Date? = .now
    }

    /// Invites and the host's record of who it invited outlive the engine, which is rebuilt at every lock (audit
    /// STA-01: an invite accepted after the host had locked once was dropped, and the invitee was told "You joined").
    static let inviteLifetime: TimeInterval = 30 * 86_400

    private(set) var groups: [String: PrivaGroup] = [:]
    private(set) var invites: [Invite] = []
    @ObservationIgnored weak var engine: PrivaEngine?
    /// fileID → groupID for attachments this iPhone serves as host (kept in the store: no thread scan at unlock).
    /// fileID → "gid|seq" of the post it came with (just "gid" for files from before the seq was kept).
    @ObservationIgnored private var groupFiles: [String: String] = [:] {
        didSet { try? engine?.store.set(groupFiles, for: "group-files") }
    }
    /// fileID → the post waiting for its upload to finish before it's sent to everyone. Kept in the store: the upload
    /// resumes after a lock, and the post must still go out when it completes (audit STA-02).
    @ObservationIgnored private var pendingFanout: [String: (gid: String, mid: String)] = [:] {
        didSet { try? engine?.store.set(pendingFanout.mapValues { [$0.gid, $0.mid] }, for: "group-pending-fanout") }
    }
    #if DEBUG
    var debugPendingFanout: Int { pendingFanout.count }
    var debugDeferredClaims: Int { deferredClaims.count }
    #endif
    @ObservationIgnored private var issuedLinks: Set<String> = []
    @ObservationIgnored private var lastFailoverCheck = Date.distantPast
    /// gid → when this successor may ask the directory about the group's quiet host again (audit STA-04).
    @ObservationIgnored private var failoverNextCheck: [String: Date] = [:]
    @ObservationIgnored private var failoverChecking: Set<String> = []
    /// Failover claims this member couldn't confirm yet (the directory still listed the host, or didn't answer):
    /// gid → the claim, asked about again later. Kept in the store, since the new host sends its claim once.
    nonisolated struct DeferredClaim: Codable, Sendable {
        let previous: SignedCharter
        let next: SignedCharter
        let from: String
        var retryAt: Date
        var tries: Int
        var verified = false
    }
    @ObservationIgnored private var deferredClaims: [String: DeferredClaim] = [:] {
        didSet { try? engine?.store.set(deferredClaims, for: "group-deferred-claims") }
    }
    /// Control packets waiting for a peer to come online (state, admin, invites, links, handovers).
    @ObservationIgnored private var outbox: [String: [GroupPacket]] = [:]

    var sorted: [PrivaGroup] { groups.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
    private var me: String { engine?.me ?? "" }

    /// The engine closed (Priva locked): nothing about the groups stays in memory.
    func close() {
        groups = [:]
        invites = []
        pendingInvites = [:]
        outbox = [:]
        unconfirmed = [:]
        bundlesSent = [:]
    }

    // MARK: persistence

    func load() {
        guard let store = engine?.store else { return }
        let ids = store.get([String].self, for: "groups") ?? []
        groups = Dictionary(uniqueKeysWithValues: ids.compactMap { store.get(PrivaGroup.self, for: "group:\($0)") }.map { g -> (String, PrivaGroup) in
            var g = g
            if let seq = store.get(Int64.self, for: "group-seq:\(g.id)"), seq > g.lastSeq { g.lastSeq = seq }
            return (g.id, g)
        })
        issuedLinks = store.get(Set<String>.self, for: "group-links") ?? []
        outbox = store.get([String: [GroupPacket]].self, for: "group-ctl-outbox") ?? [:]
        groupFiles = store.get([String: String].self, for: "group-files") ?? [:]
        deferredClaims = store.get([String: DeferredClaim].self, for: "group-deferred-claims") ?? [:]
        pendingFanout = (store.get([String: [String]].self, for: "group-pending-fanout") ?? [:])
            .compactMapValues { $0.count == 2 ? (gid: $0[0], mid: $0[1]) : nil }
        let cutoff = Date().addingTimeInterval(-Self.inviteLifetime)
        invites = (store.get([Invite].self, for: "group-invites") ?? []).filter { ($0.received ?? .now) > cutoff }
        pendingInvites = (store.get([String: Date].self, for: "group-pending-invites") ?? [:]).filter { $0.value > cutoff }
    }

    private func saveInvites() {
        try? engine?.store.set(invites, for: "group-invites")
        try? engine?.store.set(pendingInvites, for: "group-pending-invites")
    }

    private func save(_ g: PrivaGroup) {
        groups[g.id] = g
        guard let store = engine?.store else { return }
        try? store.set(g, for: "group:\(g.id)")
        try? store.set(Array(groups.keys), for: "groups")
        try? store.set(g.lastSeq, for: "group-seq:\(g.id)")
    }

    /// Only the sequence number moved (every post, sent or received): a few bytes instead of the whole group with
    /// every member's keys, ≈ 11.5 KB each (audit STA-05).
    private func saveSeq(_ g: PrivaGroup) {
        groups[g.id] = g
        try? engine?.store.set(g.lastSeq, for: "group-seq:\(g.id)")
    }

    /// Durable packets that went straight out on a live connection, and when. A peer that crashed still looks
    /// connected for ≈ 10–15 s, so if that connection then closes, what went out in the last half-minute may never
    /// have arrived: it's queued again for the next connection (receivers ignore repeats). Found by XD-20.
    @ObservationIgnored private var unconfirmed: [String: [(packet: GroupPacket, at: Date)]] = [:]
    static let confirmWindow: TimeInterval = 30

    private func send(_ p: GroupPacket, to username: String) {
        guard let engine, username != me else { return }
        if let l = engine.link(for: username), l.isReady {
            // Remembered before sending: a send that fails closes the connection at once, and linkClosed then
            // requeues what's remembered.
            if p.isDurable { sentLive(p, to: username) }
            l.send(.group(p))
            return
        }
        engine.requestLink(username, intent: .data)
        guard p.isDurable else { return }
        queue([p], for: username)
    }

    private func queue(_ ps: [GroupPacket], for username: String) {
        var q = outbox[username] ?? []
        for p in ps {
            // Only the newest state snapshot per group matters.
            if case .state(let snap) = p { q.removeAll { if case .state(let o) = $0 { return o.group.id == snap.group.id }; return false } }
            q.append(p)
        }
        outbox[username] = Array(q.suffix(200))
        saveOutbox()
    }

    private func sentLive(_ p: GroupPacket, to username: String) {
        let cutoff = Date().addingTimeInterval(-Self.confirmWindow)
        var list = (unconfirmed[username] ?? []).filter { $0.at > cutoff }
        list.append((p, .now))
        unconfirmed[username] = Array(list.suffix(200))
    }

    /// The engine's connection to `peer` closed: requeue what may have been lost with it, ahead of anything queued
    /// since, and ask for a new connection.
    func linkClosed(_ peer: String) {
        guard let sent = unconfirmed.removeValue(forKey: peer) else { return }
        let recent = sent.filter { Date().timeIntervalSince($0.at) < Self.confirmWindow }.map(\.packet)
        guard !recent.isEmpty else { return }
        let later = outbox.removeValue(forKey: peer) ?? []
        queue(recent + later, for: peer)
        engine?.requestLink(peer, intent: .data)
    }

    private func saveOutbox() { try? engine?.store.set(outbox, for: "group-ctl-outbox") }

    #if DEBUG
    func debugQueued(for peer: String) -> Int { outbox[peer]?.count ?? 0 }
    func debugUnconfirmed(for peer: String) -> Int { unconfirmed[peer]?.count ?? 0 }
    #endif

    private func flushOutbox(to peer: String) {
        // Taken off the queue only once there's a ready connection to send it on.
        guard let l = engine?.link(for: peer), l.isReady, let q = outbox.removeValue(forKey: peer) else { return }
        saveOutbox()
        for p in q { sentLive(p, to: peer) }               // before sending, as in send(_:to:)
        for p in q where l.isReady { l.send(.group(p)) }
    }

    // MARK: host: create / invite

    func create(name: String, members: [String]) throws -> PrivaGroup {
        guard let engine else { throw CryptoFailure.malformed }
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        var g = PrivaGroup(id: Bytes.random(16).hex, name: clean.isEmpty ? "New group" : clean, host: me, epoch: 1,
                           members: [.init(username: me, role: .host, name: engine.sharedName, joined: .now,
                                           bundleRaw: engine.myBundle.raw, inbox: engine.identity.inboxTopic)])
        g.charter = try SignedCharter.sign(Charter(groupID: g.id, epoch: g.epoch, host: me, successors: [], ts: Signal.now),
                                          identity: engine.identity)
        save(g)
        system("You created the group.", in: g)
        for m in members { invite(m, to: g.id) }
        return g
    }

    func invite(_ username: String, to gid: String) {
        guard let g = groups[gid], let engine, engine.contact(username)?.groupOnly != true else { return }
        if g.host == me {
            guard engine.contact(username) != nil, g.member(username) == nil, g.members.count < g.rules.maxMembers else { return }
            send(.invite(.invite(for: g, hostName: engine.sharedName)), to: username)
            pendingInvites["\(gid)|\(username)"] = .now
            saveInvites()
        } else if g.isAdmin(me) {
            send(.admin(groupID: gid, action: .add(username: username)), to: g.host)
        }
    }

    @ObservationIgnored private var pendingInvites: [String: Date] = [:]

    /// A group we're in (not ended) that `username` is also in.
    func sharesGroup(with username: String) -> Bool {
        groups.values.contains { !$0.ended && $0.member(username) != nil }
    }

    func dropInvites(from username: String) {
        invites.removeAll { $0.from == username }
        saveInvites()
    }

    func respond(to invite: Invite, accept: Bool) {
        invites.removeAll { $0.id == invite.id }
        saveInvites()
        send(.join(groupID: invite.snapshot.group.id, accept: accept, name: engine?.sharedName), to: invite.from)
        if accept {
            var g = invite.snapshot.group
            g.lastSeq = 0
            save(g)
            system("You joined \(g.name).", in: g)
        }
    }

    // MARK: posting

    /// False when it couldn't be saved (storage full): the caller keeps the draft.
    @discardableResult
    func post(text: String, to gid: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let g = groups[gid], !g.ended else { return true }
        let m = Message(id: UUID().uuidString, contact: g.threadKey, outgoing: true, kind: .text, text: String(t.prefix(16_000)),
                        attachment: nil, sentAt: .now, status: .queued, sender: me)
        return submit(m, in: g)
    }

    func post(media: MediaPrep.Prepared, to gid: String) async {
        guard let engine, let g = groups[gid], !g.ended else { return }
        guard let att = await engine.encryptForSending(media) else { return }
        let m = Message(id: UUID().uuidString, contact: g.threadKey, outgoing: true, kind: .media, text: nil, attachment: att,
                        sentAt: .now, status: .queued, sender: me)
        engine.registerOutgoingFile(att.fileID, message: m.id, contact: g.host)
        submit(m, in: g)
    }

    /// Retry a queued/failed post (the host re-applies its rules; duplicates are ignored by id).
    func resubmit(_ m: Message) {
        guard m.outgoing, m.contact.hasPrefix("g:"), let g = groups[String(m.contact.dropFirst(2))], !g.ended, g.host != me else { return }
        var mm = m
        mm.status = .queued
        submit(mm, in: g)
    }

    @discardableResult
    private func submit(_ m: Message, in g: PrivaGroup) -> Bool {
        guard engine?.persist(m) == true else { return false }
        if g.host == me {
            var mm = m
            mm.status = .delivered
            accept(post: mm, from: me, in: g)
        } else if engine?.link(for: g.host)?.isReady == true {
            // Never overtake our own older posts that are still waiting: they go first, oldest first.
            resendPending(to: g.host, onlyUnsent: true)
        } else {
            engine?.requestLink(g.host, intent: .data)
        }
        return true
    }

    // MARK: host processing

    /// The host is the group's processor: rules, sequencing, storage, fan-out.
    @discardableResult
    private func accept(post m: Message, from sender: String, in g0: PrivaGroup) -> Bool {
        var g = g0
        var msg = m
        g.lastSeq += 1
        msg.seq = g.lastSeq
        msg.sender = sender
        saveSeq(g)
        guard engine?.persist(msg) == true else { saveSeq(g0); return false }
        if let a = msg.attachment { groupFiles[a.fileID] = "\(g.id)|\(msg.seq ?? 0)" }
        guard let engine else { return false }
        let packet = GroupPacket.deliver(groupID: g.id, seq: msg.seq ?? 0, sender: sender, envelope: engine.envelope(msg))
        let others = g.members.map(\.username).filter { $0 != sender && $0 != me }
        // Queued until each member acks (one write for all of them); sent right away when online (the full queue
        // replays on reconnect).
        try? engine.store.enqueueGroup(members: others, gid: g.id, mid: msg.id, seq: msg.seq ?? 0)
        for member in others {
            if let l = engine.link(for: member), l.isReady { l.send(.group(packet)) } else { engine.requestLink(member, intent: .data) }
        }
        return true
    }

    private func hostHandlePost(_ e: Wire.Envelope, from sender: String, in g: PrivaGroup, link: PeerLink) {
        guard let member = g.member(sender), !g.ended else {
            link.send(.group(.posted(groupID: g.id, id: e.id, seq: nil, rejected: "You're not a member of this group")))
            return
        }
        if member.muted { link.send(.group(.posted(groupID: g.id, id: e.id, seq: nil, rejected: "An admin muted you in this group"))); return }
        if g.rules.announceOnly && !g.isAdmin(sender) {
            link.send(.group(.posted(groupID: g.id, id: e.id, seq: nil, rejected: "Only admins can post in this group")))
            return
        }
        guard PrivaEngine.isValid(e) else { return }
        // A resend of a post we already hold is just re-acknowledged (and doesn't spend the sender's budget).
        // An id that belongs to something else on this iPhone is refused, not "acknowledged".
        if let existing = try? engine?.store.message(e.id) {
            let ours = existing.contact == g.threadKey && existing.sender == sender
            link.send(.group(.posted(groupID: g.id, id: e.id, seq: ours ? existing.seq : nil, rejected: ours ? nil : "Duplicate message")))
            return
        }
        // While a sender is being paced, hold their later posts until the oldest refused one comes back, so a
        // token that refills mid-burst can never let a later post overtake an earlier one.
        if let hold = holdAfter[sender], Date().timeIntervalSince(hold.since) < 60, e.sentAt > hold.sentAt {
            link.send(.group(.posted(groupID: g.id, id: e.id, seq: nil, rejected: Self.slowDown)))
            return
        }
        if !allowPost(from: sender) {
            if holdAfter[sender].map({ e.sentAt < $0.sentAt }) ?? true { holdAfter[sender] = (e.sentAt, .now) }
            link.send(.group(.posted(groupID: g.id, id: e.id, seq: nil, rejected: Self.slowDown)))
            return
        }
        holdAfter[sender] = nil
        if let a = e.attachment, a.size > Self.maxAttachment {
            link.send(.group(.posted(groupID: g.id, id: e.id, seq: nil, rejected: "Attachments in groups are limited to 2 GB")))
            return
        }
        var text = e.text
        if let t = e.text {
            let r = KeywordFilter.apply(t, rules: g.rules)
            if r.blocked {
                link.send(.group(.posted(groupID: g.id, id: e.id, seq: nil, rejected: "Blocked by the group's keyword filter")))
                return
            }
            text = r.text
        }
        // A file's name is words too: a blocked word can't travel as "spoiler.jpg" (audit SEC-26).
        if let name = e.attachment?.name, KeywordFilter.apply((name as NSString).deletingPathExtension, rules: g.rules).hit {
            link.send(.group(.posted(groupID: g.id, id: e.id, seq: nil, rejected: "Blocked by the group's keyword filter")))
            return
        }
        var att = e.attachment
        att?.progress = 0
        let m = Message(id: e.id, contact: g.threadKey, outgoing: false, kind: e.kind, text: text, attachment: att,
                        sentAt: e.sentAt, receivedAt: .now, status: .received, sender: sender)
        if let a = att {
            // Upload first: the host fans out only once it holds the complete (still encrypted) file.
            guard PrivaEngine.hasRoom(for: a.size) else {
                link.send(.group(.posted(groupID: g.id, id: e.id, seq: nil, rejected: "The host's iPhone is out of space")))
                return
            }
            guard engine?.persist(m) == true else {
                // The host's storage is full: paced, so the member keeps it queued and sends it again later.
                link.send(.group(.posted(groupID: g.id, id: e.id, seq: nil, rejected: Self.slowDown)))
                return
            }
            pendingFanout[a.fileID] = (g.id, m.id)
            engine?.beginIncoming(a, messageID: m.id, from: sender, link: link, userAsked: true)     // the host must hold it
            link.send(.group(.posted(groupID: g.id, id: e.id, seq: nil, rejected: nil)))
            return
        }
        guard accept(post: m, from: sender, in: g) else {
            link.send(.group(.posted(groupID: g.id, id: e.id, seq: nil, rejected: Self.slowDown)))
            return
        }
        link.send(.group(.posted(groupID: g.id, id: e.id, seq: groups[g.id]?.lastSeq, rejected: nil)))
    }

    /// The host's iPhone stores and relays every attachment, so it bounds what a member can make it hold.
    static let maxAttachment: Int64 = 2 << 30
    /// Token bucket per member: a burst of 30 posts, then 3 per second. Beyond that the host answers
    /// `slowDown`; honest clients keep the post queued and resend it paced, so nothing is lost.
    static let postBurst = 30.0
    static let postRefillPerSecond = 3.0
    static let slowDown = "You're sending messages too quickly"
    @ObservationIgnored private var buckets: [String: (tokens: Double, at: Date)] = [:]
    @ObservationIgnored private var holdAfter: [String: (sentAt: Date, since: Date)] = [:]

    private func allowPost(from sender: String) -> Bool {
        let now = Date()
        var b = buckets[sender] ?? (Self.postBurst, now)
        b.tokens = min(Self.postBurst, b.tokens + now.timeIntervalSince(b.at) * Self.postRefillPerSecond)
        b.at = now
        defer { buckets[sender] = b }
        guard b.tokens >= 1 else { return false }
        b.tokens -= 1
        return true
    }

    // MARK: member-side pacing

    @ObservationIgnored private var pacedResend: Set<String> = []

    /// The host asked us to slow down: resend what's still queued for it in small batches.
    private func schedulePacedResend(to host: String) {
        guard pacedResend.insert(host).inserted else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self else { return }
            self.pacedResend.remove(host)
            // Keep pacing while anything is still waiting (a batch that's fully accepted brings no new "slow down").
            if self.resendPending(to: host, limit: Int(Self.postRefillPerSecond * 3), onlyUnsent: true) { self.schedulePacedResend(to: host) }
        }
    }

    /// Sends up to `limit` waiting posts to `host`, oldest first, marking them "sending" (awaiting the host's ack).
    /// `onlyUnsent` skips posts already sent on this link. Returns true if more are still waiting.
    @discardableResult
    private func resendPending(to host: String, limit: Int = .max, onlyUnsent: Bool = false) -> Bool {
        guard let engine, let l = engine.link(for: host), l.isReady else { return false }
        var budget = limit
        for g in groups.values where !g.ended && g.host == host {
            let waiting = ((try? engine.store.pending(for: g.threadKey)) ?? [])
                .filter { $0.outgoing && (!onlyUnsent || $0.status == .queued) }
                .sorted { ($0.sentAt, $0.id) < ($1.sentAt, $1.id) }
            for var m in waiting {
                guard budget > 0 else { return true }
                l.send(.group(.post(groupID: g.id, envelope: engine.envelope(m))))
                if m.status == .queued { m.status = .sending; engine.persist(m) }
                budget -= 1
            }
        }
        return false
    }

    /// Called by the engine when an incoming file finished downloading.
    func fileCompleted(_ fileID: String) {
        guard let (gid, mid) = pendingFanout.removeValue(forKey: fileID), let g = groups[gid],
              let m = try? engine?.store.message(mid), let sender = m.sender else { return }
        var done = m
        done.attachment?.progress = 1
        accept(post: done, from: sender, in: g)
        // The upload was acknowledged before it had a place in the order; tell the sender where it landed.
        if let seq = groups[gid]?.lastSeq, let l = engine?.link(for: sender), l.isReady {
            l.send(.group(.posted(groupID: gid, id: mid, seq: seq, rejected: nil)))
        }
    }

    /// The file is gone from this iPhone (90-day group media rule): stop offering it.
    func forgetFile(_ fileID: String) { if groupFiles[fileID] != nil { groupFiles[fileID] = nil } }

    func servesFile(_ fileID: String, to peer: String) -> Bool {
        guard let entry = groupFiles[fileID] else { return false }
        let parts = entry.split(separator: "|")
        guard let g = groups[String(parts[0])], g.host == me, let member = g.member(peer) else { return false }
        // Only files posted after they joined, like the messages themselves.
        let seq = parts.count > 1 ? Int64(parts[1]) ?? .max : .max
        return seq > (member.joinedSeq ?? 0)
    }

    private func deliverPending(to member: String) {
        guard let engine else { return }
        guard let l = engine.link(for: member), l.isReady else { engine.requestLink(member, intent: .data); return }
        for item in (try? engine.store.groupPending(member: member)) ?? [] {
            guard let g = groups[item.gid], g.member(member) != nil, let m = try? engine.store.message(item.mid) else {
                try? engine.store.dequeueGroup(member: member, mid: item.mid)
                continue
            }
            l.send(.group(.deliver(groupID: g.id, seq: m.seq ?? item.seq, sender: m.sender ?? g.host, envelope: engine.envelope(m))))
        }
    }

    // MARK: admin

    func perform(_ action: GroupAction, in gid: String) {
        guard let g = groups[gid] else { return }
        if g.host == me { apply(action, by: me, in: g) } else { send(.admin(groupID: gid, action: action), to: g.host) }
        if case .leave = action, g.host != me { leftLocally(g, reason: "You left the group.") }
    }

    private func apply(_ action: GroupAction, by actor: String, in g0: PrivaGroup) {
        guard let engine, !g0.ended else { return }
        var g = g0
        let admin = g.isAdmin(actor)
        switch action {
        case .add(let u):
            guard admin else { return }
            invite(u, to: g.id)
            return
        case .remove(let u):
            guard admin, u != g.host, g.member(u) != nil, !(g.role(of: u) == .admin && actor != g.host) else { return }
            g.members.removeAll { $0.username == u }
            send(.removed(groupID: g.id, reason: "An admin removed you from \(g.name)."), to: u)
            try? engine.store.clearGroupQueue(member: u, gid: g.id)
            system("\(who(u, g0)) was removed.", in: g)
        case .promote(let u):
            guard actor == g.host, let i = g.members.firstIndex(where: { $0.username == u }) else { return }
            g.members[i].role = .admin
            system("\(who(u, g)) is now an admin.", in: g)
        case .demote(let u):
            guard actor == g.host, let i = g.members.firstIndex(where: { $0.username == u }), g.members[i].role == .admin else { return }
            g.members[i].role = .member
        case .mute(let u, let on):
            guard admin, let i = g.members.firstIndex(where: { $0.username == u }), g.members[i].role != .host else { return }
            g.members[i].muted = on
            system("\(who(u, g)) was \(on ? "muted" : "unmuted").", in: g)
        case .rename(let n):
            guard admin else { return }
            g.name = TextSafety.clean(n, max: 60)
        case .rules(let r):
            guard admin else { return }
            var rr = r
            rr.keywords = Array(r.keywords.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(200))
            rr.maxMembers = min(max(2, r.maxMembers), 256)
            g.rules = rr
        case .deleteMessage(let id):
            // Only a post of THIS group, never a 1:1 message or another group's post that happens to share an id.
            guard let m = try? engine.store.message(id), m.contact == g.threadKey, admin || m.sender == actor else { return }
            try? engine.store.deleteMessage(id)
            if let f = m.attachment?.fileID { engine.store.removeMedia(f); forgetFile(f) }
            engine.dropFromThread(id, key: g.threadKey)
            for member in g.members where member.username != me { send(.deleted(groupID: g.id, id: id), to: member.username) }
            return
        case .transferHost(let to):
            guard actor == g.host, g.member(to) != nil, to != me else { return }
            handOver(g, to: to)
            return
        case .disband:
            guard actor == g.host else { return }
            for member in g.members where member.username != me { send(.removed(groupID: g.id, reason: "The host ended \(g.name)."), to: member.username) }
            g.ended = true
            save(g)
            // Queued posts for offline members would only keep this iPhone reconnecting to them (audit STA-11).
            try? engine.store.clearGroupQueue(gid: g.id)
            system("You ended the group.", in: g)
            return
        case .leave:
            guard actor != g.host else { return }
            g.members.removeAll { $0.username == actor }
            try? engine.store.clearGroupQueue(member: actor, gid: g.id)
            system("\(who(actor, g0)) left.", in: g)
        }
        publish(&g)
    }

    /// New epoch: re-sign the charter, push state to everyone, make sure successors can reach members.
    private func publish(_ g: inout PrivaGroup) {
        guard let engine else { return }
        g.epoch += 1
        g.charter = try? SignedCharter.sign(Charter(groupID: g.id, epoch: g.epoch, host: me, successors: g.successors, ts: Signal.now),
                                           identity: engine.identity)
        save(g)
        schedulePublish(g.id)          // the roster goes out first; successor links follow it (see sendState)
    }

    @ObservationIgnored private var publishScheduled: Set<String> = []
    /// "gid|member" → members whose public keys that member already has from us.
    @ObservationIgnored private var bundlesSent: [String: Set<String>] = [:]

    /// A burst of changes (e.g. 40 people joining) becomes one update per member, not one per change.
    private func schedulePublish(_ gid: String) {
        guard publishScheduled.insert(gid).inserted else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self else { return }
            self.publishScheduled.remove(gid)
            self.sendState(gid)
        }
    }

    /// Each member gets the roster with only the public keys they don't have yet: ~11 KiB per member otherwise,
    /// which past ~20 members exceeded what one data-channel message can carry.
    private func sendState(_ gid: String) {
        guard let engine, let g = groups[gid], g.host == me else { return }
        for m in g.members where m.username != me {
            let key = "\(gid)|\(m.username)"
            let known = bundlesSent[key] ?? []
            var slim = g
            for i in slim.members.indices where known.contains(slim.members[i].username) { slim.members[i].bundleRaw = Data() }
            let direct = engine.link(for: m.username)?.isReady == true
            send(.state(GroupSnapshot(group: slim, hostName: engine.sharedName)), to: m.username)
            // Only count keys as delivered when they went straight out; a queued snapshot may still be replaced.
            if direct { bundlesSent[key] = Set(g.members.map(\.username)) }
        }
        // After the roster: a member only accepts a link to someone already in their copy of it.
        issueLinks(g)
    }

    private func issueLinks(_ g: PrivaGroup) {
        let successors = Set(g.successors)
        for s in g.members where successors.contains(s.username) && s.username != me {
            for m in g.members where m.username != s.username && m.username != me {
                let key = [g.id, s.username, m.username].joined(separator: "|")
                guard !issuedLinks.contains(key) else { continue }
                issuedLinks.insert(key)
                let root = Bytes.random(64)
                send(.link(groupID: g.id, peer: m.username, bundle: m.bundleRaw, inbox: m.inbox, root: root), to: s.username)
                send(.link(groupID: g.id, peer: s.username, bundle: s.bundleRaw, inbox: s.inbox, root: root), to: m.username)
            }
        }
        try? engine?.store.set(issuedLinks, for: "group-links")
    }

    // MARK: host handover & failover (GROUPS_DESIGN §6)

    private func handOver(_ g0: PrivaGroup, to next: String) {
        guard let engine, let previous = g0.charter else { return }
        var g = g0
        g.epoch += 1
        guard let signed = try? SignedCharter.sign(Charter(groupID: g.id, epoch: g.epoch, host: next,
                                                           successors: g.successors.filter { $0 != next }, ts: Signal.now),
                                                  identity: engine.identity) else { return }
        if let i = g.members.firstIndex(where: { $0.username == me }) { g.members[i].role = .admin }
        if let i = g.members.firstIndex(where: { $0.username == next }) { g.members[i].role = .host }
        g.host = next
        g.charter = signed
        save(g)
        try? engine.store.clearGroupQueue(gid: g.id)     // the new host catches members up through .sync
        for m in g.members where m.username != me { send(.handover(groupID: g.id, previous: previous, next: signed), to: m.username) }
        system("\(who(next, g)) is now hosting the group.", in: g)
    }

    /// Successor side: the host looks gone (uninstalled / removed / silent for 72 h) → claim the group.
    /// `force`: a directory check just showed someone uninstalled, don't wait for the periodic check.
    func checkFailover(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastFailoverCheck) > 30, let engine else { return }
        lastFailoverCheck = .now
        retryDeferredClaims(force: force)
        for g in groups.values where g.host != me && !g.ended {
            guard let previous = g.charter, previous.charter.host == g.host, hostQuiet(g.host) else { continue }
            let order = previous.charter.successors
            guard let myIndex = order.firstIndex(of: me) else { continue }
            // An earlier successor heard from this week takes it; a longer silence passes it on to the next.
            let earlierAlive = order.prefix(myIndex).contains { !hostQuiet($0, for: 7 * 86_400) && engine.contact($0) != nil }
            if earlierAlive { continue }
            // Silence is only a reason to ask: two people on different hours can go days without a signal. The
            // group moves only when the directory says the host's account is gone (GROUPS_DESIGN §6.2).
            guard force || (failoverNextCheck[g.id] ?? .distantPast) < .now, failoverChecking.insert(g.id).inserted else { continue }
            let (gid, host, epoch) = (g.id, g.host, previous.charter.epoch)
            verifyHostGone(host) { [weak self] verdict in
                guard let self else { return }
                self.failoverChecking.remove(gid)
                switch verdict {
                case .gone:
                    guard let g = self.groups[gid], g.host == host, !g.ended, let c = g.charter, c.charter.epoch == epoch else { return }
                    self.claim(g, previous: c)
                case .active: self.failoverNextCheck[gid] = .now.addingTimeInterval(86_400)
                case .unknown: self.failoverNextCheck[gid] = .now.addingTimeInterval(600)
                }
            }
        }
    }

    enum HostVerdict: Sendable { case gone, active, unknown }

    /// Live directory check (the claimant's word isn't enough); updates the contact's state as a side effect.
    /// An answer from the last ten minutes is reused.
    private func verifyHostGone(_ u: String, then: @escaping (HostVerdict) -> Void) {
        if let c = engine?.contact(u), let at = c.directoryCheckedAt, at.timeIntervalSinceNow > -600, c.directoryState != nil {
            then(c.looksGone ? .gone : .active)
            return
        }
        Task { [weak self] in
            guard let entry = try? await PrivaAPI.shared.lookup(u) else { then(.unknown); return }
            self?.engine?.updateDirectoryState(u, entry.status)
            then(entry.status == .active ? .active : .gone)
        }
    }

    /// Nothing heard from them for a while (72 hours by default), or the directory already says they're gone.
    private func hostQuiet(_ u: String, for silence: TimeInterval = 72 * 3600) -> Bool {
        guard let c = engine?.contact(u) else { return true }
        if c.looksGone { return true }
        return (c.lastSeen ?? c.addedAt).timeIntervalSinceNow < -silence
    }

    /// Claims this member couldn't confirm: asked about again with backoff (10 min → 1 h → 6 h while the
    /// directory doesn't answer, daily while it still lists the host), for at most two weeks.
    private func retryDeferredClaims(force: Bool) {
        for (gid, d) in deferredClaims where force || d.retryAt < .now {
            guard let g = groups[gid], !g.ended, d.next.charter.epoch > g.epoch || d.next.charter.host != g.host,
                  d.tries < 14 else { deferredClaims[gid] = nil; continue }
            acceptHandover(previous: d.previous, next: d.next, in: g, from: d.from, retry: d)
        }
    }

    private func claim(_ g0: PrivaGroup, previous: SignedCharter) {
        guard let engine else { return }
        var g = g0
        let oldHost = g.host
        g.members.removeAll { $0.username == oldHost }
        if let i = g.members.firstIndex(where: { $0.username == me }) { g.members[i].role = .host }
        g.host = me
        g.epoch = max(g.epoch, previous.charter.epoch) + 1
        guard let next = try? SignedCharter.sign(Charter(groupID: g.id, epoch: g.epoch, host: me, successors: g.successors, ts: Signal.now),
                                                identity: engine.identity) else { return }
        g.charter = next
        save(g)
        for m in g.members where m.username != me { send(.handover(groupID: g.id, previous: previous, next: next), to: m.username) }
        system("You are now hosting this group.", in: g)
        engine.toast = .init(title: g.name, body: "You're now the host.", contact: g.threadKey)
    }

    private func acceptHandover(previous: SignedCharter, next: SignedCharter, in g0: PrivaGroup, from sender: String,
                                retry: DeferredClaim? = nil) {
        guard let engine, next.charter.groupID == g0.id, next.charter.epoch > g0.epoch || next.charter.host != g0.host else { return }
        let currentHost = g0.host
        let hostBundle = g0.member(currentHost).flatMap { try? KeyBundle.parse($0.bundleRaw) } ?? engine.contact(currentHost)?.bundle
        let newHost = next.charter.host
        let newBundle = g0.member(newHost).flatMap { try? KeyBundle.parse($0.bundleRaw) }
        var legit = false
        if let hb = hostBundle, next.verify(with: hb), sender == currentHost {
            legit = true   // planned handover, signed by the current host
        } else if let hb = hostBundle, previous.verify(with: hb), previous.charter.host == currentHost,
                  previous.charter.successors.contains(newHost), let nb = newBundle, next.verify(with: nb), sender == newHost {
            // Failover: the old host named this successor and the successor signed its claim. A claim alone
            // proves nothing about the host being gone, so every member checks that independently.
            guard currentHost != me else {
                // Someone claimed a group this iPhone still hosts: a new charter makes their claim stale everywhere.
                engine.diagnosticsRejected()
                if previous.charter.epoch >= g0.epoch { var g = g0; publish(&g) }   // once per claim, not per resend
                return
            }
            // Only the latest charter counts: an older one (say, from before an admin was demoted) proves nothing.
            guard previous.charter.epoch >= (g0.charter?.charter.epoch ?? 0) else { engine.diagnosticsRejected(); return }
            if retry?.verified != true {
                let gid = g0.id
                verifyHostGone(currentHost) { [weak self] verdict in
                    guard let self else { return }
                    var d = retry ?? DeferredClaim(previous: previous, next: next, from: sender, retryAt: .now, tries: 0)
                    switch verdict {
                    case .gone:
                        self.deferredClaims[gid] = nil
                        guard let g = self.groups[gid], g.host == currentHost else { return }
                        d.verified = true
                        self.acceptHandover(previous: previous, next: next, in: g, from: sender, retry: d)
                    case .active, .unknown:
                        d.tries += 1
                        let wait: TimeInterval = verdict == .active ? 86_400 : [600, 3600, 6 * 3600][min(d.tries, 3) - 1]
                        d.retryAt = .now.addingTimeInterval(wait)
                        self.deferredClaims[gid] = d
                    }
                }
                return
            }
            legit = true
        }
        guard legit else { engine.diagnosticsRejected(); return }
        var g = g0
        if next.charter.host != currentHost, sender == newHost, !(hostBundle.map { next.verify(with: $0) } ?? false) {
            g.members.removeAll { $0.username == currentHost }
        }
        for i in g.members.indices {
            if g.members[i].username == newHost { g.members[i].role = .host } else if g.members[i].role == .host { g.members[i].role = .admin }
        }
        g.host = newHost
        g.epoch = next.charter.epoch
        g.charter = next
        save(g)
        system(newHost == me ? "You are now hosting this group." : "\(who(newHost, g)) is now hosting the group.", in: g)
        if newHost == me {
            var gg = g
            publish(&gg)
        } else {
            send(.sync(groupID: g.id, since: g.lastSeq), to: newHost)
        }
    }

    // MARK: packets from peers

    func handle(_ p: GroupPacket, from peer: String, link: PeerLink) {
        switch p {
        case .invite(let snap):
            // Invites come only from real friends, at most 5 pending per friend and 20 overall.
            // A group we were removed from (or left) can invite us again; an active one can't be replaced.
            guard snap.group.host == peer, snap.group.member(me) == nil, groups[snap.group.id]?.ended ?? true,
                  engine?.contact(peer)?.groupOnly != true, engine?.isBlocked(peer) == false, snap.group.members.count <= 256,
                  invites.filter({ $0.from == peer }).count < 5, invites.count < 20 else { return }
            invites.removeAll { $0.id == snap.group.id }
            invites.append(Invite(snapshot: Self.cleaned(snap), from: peer))
            saveInvites()
            engine?.toast = .init(title: "Group invite", body: "\(engine?.name(of: peer) ?? peer) invited you to \(snap.group.name)", contact: nil)
        case .join(let gid, let ok, let name):
            guard var g = groups[gid], g.host == me, pendingInvites.removeValue(forKey: "\(gid)|\(peer)") != nil, ok,
                  let c = engine?.contact(peer), g.member(peer) == nil else { saveInvites(); return }
            saveInvites()
            g.members.append(.init(username: peer, role: .member, name: name.flatMap { TextSafety.name($0) } ?? c.remoteName,
                                   joined: .now, bundleRaw: c.bundleRaw, inbox: c.inboxTopic, joinedSeq: g.lastSeq))
            system("\(who(peer, g)) joined.", in: g)
            publish(&g)
            // No history for new members: they see what's said after they join (like Signal/WhatsApp),
            // earlier conversations stay with the people who were there.
        case .state(let snap):
            guard let g = groups[snap.group.id], g.host == peer, snap.group.epoch >= g.epoch,
                  snap.group.members.count <= 256, snap.group.id == g.id else { return }
            // A roster queued before we left (or were removed) mustn't bring the group back (audit STA-23); a new
            // invite is the way back in.
            guard !g.ended, snap.group.member(me) != nil else { return }
            var next = Self.cleaned(snap).group
            next.lastSeq = max(g.lastSeq, 0)
            // Keys the host left out are ones we already have.
            for i in next.members.indices where next.members[i].bundleRaw.isEmpty {
                next.members[i].bundleRaw = g.member(next.members[i].username)?.bundleRaw ?? Data()
            }
            // Every member works out membership changes for themselves and says so in the chat, so a host can't
            // add a (listed) member quietly: the "ghost member" problem found in WhatsApp and Matrix groups.
            let before = Set(g.members.map(\.username)), after = Set(next.members.map(\.username))
            let moved = Self.verifiedMoves(from: g, to: next, host: peer)
            let joined = after.subtracting(before).subtracting(moved.map(\.new))
            let left = before.subtracting(after).subtracting(moved.map(\.old))
            save(next)
            for (o, n) in moved {
                renameSender(o, to: n, in: next)
                system("@\(o) restored their account from a backup and is now @\(n).", in: next)
            }
            for u in joined.sorted() where u != me { system("\(who(u, next)) joined.", in: next) }
            for u in left.sorted() where u != me { system("\(who(u, g)) is no longer in the group.", in: next) }
        case .post(let gid, let e):
            guard let g = groups[gid], g.host == me else { return }
            hostHandlePost(e, from: peer, in: g, link: link)
        case .posted(let gid, let id, let seq, let rejected):
            guard var g = groups[gid], g.host == peer, var m = try? engine?.store.message(id), m.outgoing, m.contact == g.threadKey else { return }
            if let seq, rejected == nil {
                // The host's sequence number is the group's single order; keep it on our own copy too.
                m.seq = seq
                if seq > g.lastSeq { g.lastSeq = seq; saveSeq(g) }
            }
            if rejected == Self.slowDown {
                // Paced, not refused: stays queued ("Waiting to send") and goes out in the next batch.
                m.status = .queued
                engine?.persist(m)
                schedulePacedResend(to: peer)
                return
            }
            // No place in the order yet means the host is still taking the upload: it stays "Sending" (and is asked
            // about again on reconnect) until the host has sent it to everyone.
            m.status = rejected != nil ? .failed : seq == nil ? .sending : .delivered
            engine?.persist(m)
            if let r = rejected { system("Not delivered: \(r).", in: g) }
        case .deliver(let gid, let seq, let sender, let e):
            guard var g = groups[gid], g.host == peer, PrivaEngine.isValid(e) else { return }
            if engine?.isBlocked(sender) == true {
                engine?.diagnosticsBlocked()        // someone this user blocked: acknowledged, never shown
            } else if sender == me, engine?.store.messageExists(e.id) != true {
                // "Your" post that this iPhone never sent: a host could otherwise put words in your mouth on your own
                // screen (audit SEC-27). Acknowledged, never shown.
                engine?.diagnosticsRejected()
            } else if engine?.store.messageExists(e.id) != true {
                var att = e.attachment
                att?.progress = 0
                let m = Message(id: e.id, contact: g.threadKey, outgoing: sender == me, kind: e.kind, text: e.text, attachment: att,
                                sentAt: e.sentAt, receivedAt: .now, status: sender == me ? .delivered : .received, seq: seq, sender: sender)
                guard engine?.persist(m) == true else { return }      // not acknowledged: the host sends it again
                if let a = att, sender != me { engine?.beginIncoming(a, messageID: m.id, from: peer, link: link) }
                if engine?.openChat != g.threadKey, sender != me {
                    engine?.toast = .init(title: g.name, body: "\(engine?.name(of: sender, in: g) ?? sender): \(e.text ?? "Attachment")", contact: g.threadKey)
                }
            }
            if seq > g.lastSeq { g.lastSeq = seq; saveSeq(g) }
            link.send(.group(.ack(groupID: gid, ids: [e.id])))
        case .ack(let gid, let ids):
            guard groups[gid]?.host == me else { return }
            for id in ids.prefix(500) { try? engine?.store.dequeueGroup(member: peer, mid: id) }
        case .admin(let gid, let action):
            guard let g = groups[gid], g.host == me, g.member(peer) != nil else { return }
            apply(action, by: peer, in: g)
        case .removed(let gid, let reason):
            guard let g = groups[gid], g.host == peer else { return }
            leftLocally(g, reason: reason)
        case .deleted(let gid, let id):
            // A host can delete posts in its own group: nothing else on this iPhone.
            guard let g = groups[gid], g.host == peer, let m = try? engine?.store.message(id), m.contact == g.threadKey else { return }
            try? engine?.store.deleteMessage(id)
            if let f = m.attachment?.fileID { engine?.store.removeMedia(f) }
            engine?.dropFromThread(id, key: g.threadKey)
        case .link(let gid, let other, let bundleRaw, let inbox, let root):
            guard let g = groups[gid], g.host == peer, g.member(other) != nil, other != me, root.count == 64,
                  let bundle = try? KeyBundle.parse(bundleRaw), inbox.hasPrefix("i-") else { return }
            engine?.installGroupLink(peer: other, bundle: bundle, inbox: inbox, root: root)
        case .handover(let gid, let previous, let next):
            guard let g = groups[gid] else { return }
            acceptHandover(previous: previous, next: next, in: g, from: peer)
        case .sync(let gid, let asked):
            guard let g = groups[gid], g.host == me, let member = g.member(peer) else { return }
            // Never further back than when they joined: "no history for new members" is the host's rule to keep.
            let since = max(asked, member.joinedSeq ?? 0)
            for m in ((try? engine?.store.messages(with: g.threadKey, limit: 500)) ?? []) where (m.seq ?? 0) > since && m.kind != .system {
                try? engine?.store.enqueueGroup(member: peer, gid: gid, mid: m.id, seq: m.seq ?? 0)
            }
            deliverPending(to: peer)
        case .callInvite, .callJoin, .callLeave, .callEnd, .callRoster, .callState:
            engine?.groupCalls.handle(p, from: peer, link: link)
        }
    }

    /// Removes an ended group and its history from this iPhone.
    func forget(_ gid: String) {
        guard let g = groups[gid], g.ended, let engine else { return }
        engine.deleteThread(g.threadKey)
        for (f, entry) in groupFiles where entry.split(separator: "|").first.map(String.init) == gid { groupFiles[f] = nil }
        try? engine.store.clearGroupQueue(gid: gid)
        groups[gid] = nil
        engine.store.removeValue(for: "group:\(gid)")
        engine.store.removeValue(for: "group-seq:\(gid)")
        try? engine.store.set(Array(groups.keys), for: "groups")
        outbox = outbox.mapValues { $0.filter { $0.groupID != gid } }.filter { !$0.value.isEmpty }
        saveOutbox()
    }

    private func leftLocally(_ g0: PrivaGroup, reason: String) {
        var g = g0
        g.ended = true
        save(g)
        system(reason, in: g)
        engine?.dropUnusedGroupLinks()
    }

    /// A member as shown in notices: shared name or nickname if known, else @username.
    private func who(_ u: String, _ g: PrivaGroup) -> String {
        guard let engine else { return "@\(u)" }
        let n = engine.name(of: u, in: g)
        return n == u ? "@\(u)" : n
    }

    /// Names in a snapshot come from other people: strip what could deceive (see TextSafety).
    static func cleaned(_ s: GroupSnapshot) -> GroupSnapshot {
        var g = s.group
        g.name = TextSafety.clean(g.name, max: 60)
        for i in g.members.indices { g.members[i].name = g.members[i].name.flatMap { TextSafety.name($0) } }
        return GroupSnapshot(group: g, hostName: s.hostName.flatMap { TextSafety.name($0) }, memberCount: s.memberCount)
    }

    private func system(_ text: String, in g: PrivaGroup) {
        engine?.persist(Message(id: UUID().uuidString, contact: g.threadKey, outgoing: false, kind: .system, text: text, attachment: nil,
                                sentAt: .now, receivedAt: .now, status: .received, readAt: .now))
    }

    // MARK: restoring under a new username

    /// A friend or fellow member restored their account under a new username (proof already checked by the
    /// engine). Their roster entry, host role and past messages follow them; a host tells everyone else.
    func contactMoved(old: String, new: String, bundleRaw: Data, inbox: String, proof: PrivaGroup.MemberMove?) {
        for g0 in groups.values where !g0.ended {
            guard let i = g0.members.firstIndex(where: { $0.username == old }), g0.member(new) == nil else { continue }
            var g = g0
            let m = g.members[i]
            g.members[i] = .init(username: new, role: m.role, muted: m.muted, name: m.name, joined: m.joined, bundleRaw: bundleRaw, inbox: inbox,
                                 joinedSeq: m.joinedSeq)
            if g.host == old { g.host = new }
            if let proof { g.moves = Array(((g.moves ?? []).filter { $0.ts > Signal.now - 30 * 86_400_000 } + [proof]).suffix(5)) }
            save(g)
            renameSender(old, to: new, in: g)
            system("@\(old) restored their account from a backup and is now @\(new).", in: g)
            if g.host == me { publish(&g) }
        }
        if let q = outbox.removeValue(forKey: old) { outbox[new] = q; saveOutbox() }
        if let queued = try? engine?.store.allGroupQueued() {
            for q in queued where q.member == old {
                try? engine?.store.enqueueGroup(member: new, gid: q.gid, mid: q.mid, seq: q.seq)
                try? engine?.store.dequeueGroup(member: old, mid: q.mid)
            }
        }
    }

    /// This iPhone restored a backup and now has a new username: our own roster entries (and the groups we host)
    /// move over. Members follow once they've checked our move proof; hosts republish the roster.
    func selfMoved(from old: String) {
        guard let engine, old != me else { return }
        for g0 in groups.values {
            guard let i = g0.members.firstIndex(where: { $0.username == old }) else { continue }
            var g = g0
            let m = g.members[i]
            g.members[i] = .init(username: me, role: m.role, muted: m.muted, name: engine.sharedName ?? m.name, joined: m.joined,
                                 bundleRaw: engine.myBundle.raw, inbox: engine.identity.inboxTopic, joinedSeq: m.joinedSeq)
            renameSender(old, to: me, in: g)
            if g.host == old, !g.ended {
                // The backup may be older than the group: jump past any epoch / sequence members have seen since.
                g.host = me
                g.epoch = max(g.epoch + 1, Int(Date().timeIntervalSince1970))
                g.lastSeq = max(g.lastSeq + 1, Signal.now)
                save(g)
                publish(&g)
            } else {
                save(g)
            }
            if !g.ended { system("You restored this group from a backup. Members see your new username, @\(me).", in: g) }
        }
        // Links were issued between usernames; the new one needs its own.
        issuedLinks = issuedLinks.filter { !$0.split(separator: "|").contains(Substring(old)) }
        try? engine.store.set(issuedLinks, for: "group-links")
        outbox = outbox.mapValues { q in q.filter { if case .post = $0 { return false }; return true } }
        saveOutbox()
    }

    /// Roster changes that are members restoring under a new username. Only a proof signed by the member's OLD keys
    /// (from our own copy of the roster) counts, so a host can't relabel swapping someone out as a restore.
    static func verifiedMoves(from g: PrivaGroup, to next: PrivaGroup, host: String) -> [(old: String, new: String)] {
        let before = Set(g.members.map(\.username)), after = Set(next.members.map(\.username))
        var out: [(old: String, new: String)] = []
        for mv in next.moves ?? [] where !before.contains(mv.new) && !after.contains(mv.old) && before.contains(mv.old) && after.contains(mv.new) && mv.to == host {
            guard !out.contains(where: { $0.old == mv.old || $0.new == mv.new }),
                  let ob = g.member(mv.old).flatMap({ try? KeyBundle.parse($0.bundleRaw) }),
                  let nb = next.member(mv.new).flatMap({ try? KeyBundle.parse($0.bundleRaw) }),
                  MoveProof.verify(mv.sig, pinned: ob, old: mv.old, new: mv.new, newBundle: nb, to: mv.to, ts: mv.ts) else { continue }
            out.append((mv.old, mv.new))
        }
        return out
    }

    /// Past messages from someone who moved show under their new username.
    /// Their past posts follow them: rewritten off the main thread, in one transaction (audit STA-28).
    private func renameSender(_ old: String, to new: String, in g: PrivaGroup) {
        guard let engine else { return }
        let store = engine.store, key = g.threadKey
        Task { [weak engine] in
            await Task.detached(priority: .utility) {
                let moved = ((try? store.messages(with: key, limit: 1_000_000)) ?? []).filter { $0.sender == old }
                    .map { m -> Message in var m = m; m.sender = new; return m }
                if !moved.isEmpty { try? store.importMessages(moved) }
            }.value
            engine?.forgetThreadCache(key)
        }
    }

    // MARK: engine hooks

    /// The engine's once-a-minute sweep over links that have been up a while: what is still unacknowledged there is
    /// stuck (the other iPhone couldn't save it: storage full), so it goes again. Duplicates are dropped by id.
    func resendStuck(to peer: String, queuedHashes: Set<String>) {
        guard let engine else { return }
        if queuedHashes.contains(engine.store.hashFor(peer)),
           groups.values.contains(where: { !$0.ended && $0.host == me && $0.member(peer) != nil }) { deliverPending(to: peer) }
        if resendPending(to: peer, limit: Int(Self.postBurst)) { schedulePacedResend(to: peer) }
    }

    func linkReady(_ peer: String) {
        guard engine != nil else { return }
        flushOutbox(to: peer)
        if groups.values.contains(where: { !$0.ended && $0.host == me && $0.member(peer) != nil }) { deliverPending(to: peer) }
        // Queued posts go out on reconnect, at most one burst's worth; the rest follow paced.
        if resendPending(to: peer, limit: Int(Self.postBurst)) { schedulePacedResend(to: peer) }
    }

    /// Peers this device needs a session with for group work (host → members with queued items; member → host).
    /// Runs every scheduler tick, so it works from opaque indexes only: nothing is decrypted.
    func peersNeedingLink(pendingHashes: Set<String>) -> Set<String> {
        guard let engine else { return [] }
        let store = engine.store
        var out = Set(outbox.keys)
        let queued = (try? store.groupQueueMemberHashes()) ?? []
        if !queued.isEmpty {
            for c in engine.contacts where queued.contains(store.hashFor(c.username)) { out.insert(c.username) }
        }
        for g in groups.values where g.host != me && !g.ended && pendingHashes.contains(store.hashFor(g.threadKey)) {
            out.insert(g.host)
        }
        return out
    }
}
