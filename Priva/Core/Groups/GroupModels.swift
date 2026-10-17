import Foundation

/// Host-centric groups (docs/GROUPS_DESIGN.md). Stored only on members' iPhones, never on a server.
nonisolated struct PrivaGroup: Codable, Identifiable, Sendable, Hashable {
    enum Role: String, Codable, Sendable { case host, admin, member }
    enum FilterAction: String, Codable, Sendable { case block, mask }

    struct Member: Codable, Sendable, Hashable, Identifiable {
        var id: String { username }
        let username: String
        var role: Role
        var muted: Bool = false
        var name: String?
        let joined: Date
        /// Public keys, so every member can verify charters and successors can reach members.
        var bundleRaw: Data
        var inbox: String
        /// The group's last post when they joined: the host never serves them anything older (audit SEC-10).
        var joinedSeq: Int64? = nil
    }

    struct Rules: Codable, Sendable, Hashable {
        var announceOnly = false
        var keywords: [String] = []
        var filterAction: FilterAction = .block
        var maxMembers = 100
    }

    let id: String
    var name: String
    var host: String
    var epoch: Int
    var members: [Member]
    var rules = Rules()
    var created: Date = .now
    /// Last charter signed by the host that appointed the current host (for failover proofs).
    var charter: SignedCharter?
    var ended: Bool = false
    var lastSeq: Int64 = 0
    /// Members who restored their account under a new username, with the proof signed by their old keys
    /// (kept briefly so every member can check a roster change is a move and not a swap).
    var moves: [MemberMove]? = nil

    struct MemberMove: Codable, Sendable, Hashable {
        let old: String
        let new: String
        /// The friend the proof was addressed to (the host that forwarded it).
        let to: String
        let ts: Int64
        let sig: Data
    }

    var threadKey: String { "g:\(id)" }
    func member(_ u: String) -> Member? { members.first { $0.username == u } }
    func role(of u: String) -> Role? { member(u)?.role }
    func isAdmin(_ u: String) -> Bool { let r = role(of: u); return r == .host || r == .admin }
    func isMuted(_ u: String) -> Bool { member(u)?.muted ?? false }

    /// Successors in order: admins (by join date), then the two longest-standing members.
    var successors: [String] {
        let admins = members.filter { $0.role == .admin }.sorted { $0.joined < $1.joined }.map(\.username)
        let others = members.filter { $0.role == .member }.sorted { $0.joined < $1.joined }.prefix(2).map(\.username)
        return admins + others
    }

    static let maxVideoParticipants = 4
    static let maxVoiceParticipants = 8
}

/// Who may host the group next, signed by the current host with its hybrid identity keys.
nonisolated struct Charter: Codable, Sendable, Hashable {
    let groupID: String
    let epoch: Int
    let host: String
    let successors: [String]
    let ts: Int64
}

nonisolated struct SignedCharter: Codable, Sendable, Hashable {
    let charter: Charter
    let signature: Data

    private static func message(_ c: Charter) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        return Data("PRIVA-GROUP-CHARTER-v1".utf8) + KDF.sha512(try enc.encode(c))
    }

    static func sign(_ c: Charter, identity: IdentityKeys) throws -> SignedCharter {
        SignedCharter(charter: c, signature: try identity.signing.sign(try message(c)))
    }

    func verify(with bundle: KeyBundle) -> Bool {
        guard let m = try? Self.message(charter) else { return false }
        return bundle.verifying.verify(signature, for: m)
    }
}

/// Everything a member needs to know about a group; the host pushes it on every change.
nonisolated struct GroupSnapshot: Codable, Sendable {
    let group: PrivaGroup
    let hostName: String?
    /// Invites only: how many members there are. The invite itself carries just the host, so someone who
    /// declines never learns who is in the group (the full roster arrives in the first state after joining).
    var memberCount: Int? = nil

    static func invite(for g: PrivaGroup, hostName: String?) -> GroupSnapshot {
        var r = g
        r.members = g.members.filter { $0.username == g.host }
        r.charter = nil
        r.moves = nil
        return GroupSnapshot(group: r, hostName: hostName, memberCount: g.members.count)
    }
}

/// Admin operations, requested by admins and enforced by the host.
nonisolated enum GroupAction: Codable, Sendable {
    case add(username: String)
    case remove(username: String)
    case promote(username: String)
    case demote(username: String)
    case mute(username: String, on: Bool)
    case rename(String)
    case rules(PrivaGroup.Rules)
    case deleteMessage(id: String)
    case transferHost(to: String)
    case disband
    case leave
}

/// Group protocol packets carried inside the encrypted 1:1 P2P session (Wire.group).
nonisolated enum GroupPacket: Codable, Sendable {
    case invite(GroupSnapshot)
    case join(groupID: String, accept: Bool, name: String?)
    case state(GroupSnapshot)
    case post(groupID: String, envelope: Wire.Envelope)
    case posted(groupID: String, id: String, seq: Int64?, rejected: String?)
    case deliver(groupID: String, seq: Int64, sender: String, envelope: Wire.Envelope)
    case ack(groupID: String, ids: [String])
    case admin(groupID: String, action: GroupAction)
    case removed(groupID: String, reason: String)
    case deleted(groupID: String, id: String)
    /// Host introduces two group members who aren't friends (successor ↔ member) with a fresh pair root.
    case link(groupID: String, peer: String, bundle: Data, inbox: String, root: Data)
    case handover(groupID: String, previous: SignedCharter, next: SignedCharter)
    case sync(groupID: String, since: Int64)
    case callInvite(groupID: String, callID: String, video: Bool)
    case callJoin(groupID: String, callID: String)
    case callLeave(groupID: String, callID: String)
    case callEnd(groupID: String, callID: String)
    case callRoster(groupID: String, callID: String, participants: [String])
    /// A participant's camera / mic state (member → host, host relays to everyone in the call).
    case callState(groupID: String, callID: String, participant: String, cameraOn: Bool, muted: Bool)

    var groupID: String {
        switch self {
        case .invite(let s), .state(let s): return s.group.id
        case .join(let g, _, _), .post(let g, _), .posted(let g, _, _, _), .deliver(let g, _, _, _), .ack(let g, _),
             .admin(let g, _), .removed(let g, _), .deleted(let g, _), .link(let g, _, _, _, _), .handover(let g, _, _),
             .sync(let g, _), .callInvite(let g, _, _), .callJoin(let g, _), .callLeave(let g, _), .callEnd(let g, _),
             .callRoster(let g, _, _), .callState(let g, _, _, _, _): return g
        }
    }

    /// Must survive the peer being offline (queued on this iPhone until the link is up).
    var isDurable: Bool {
        switch self {
        case .invite, .join, .state, .admin, .removed, .deleted, .link, .handover, .sync: return true
        default: return false
        }
    }
}

/// Case- and diacritic-insensitive whole-word keyword filter (applied by the host).
nonisolated enum KeywordFilter {
    static func normalise(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Returns nil if the text passes, or the filtered text / rejection reason.
    static func apply(_ raw: String, rules: PrivaGroup.Rules) -> (text: String, blocked: Bool, hit: Bool) {
        let words = Set(rules.keywords.map { normalise($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        guard !words.isEmpty else { return (raw, false, false) }
        // Invisible format characters (zero-width space/joiner, BOM, bidi controls) would split a word and
        // slip past the filter ("spo\u{200B}iler"); they are stripped before matching and delivery.
        let text = String(String.UnicodeScalarView(raw.unicodeScalars.filter { $0.properties.generalCategory != .format }))
        var hit = false
        var out = ""
        var token = ""
        func flush() {
            guard !token.isEmpty else { return }
            if words.contains(normalise(token)) {
                hit = true
                out += String(repeating: "•", count: max(3, min(token.count, 8)))
            } else {
                out += token
            }
            token = ""
        }
        for ch in text {
            if ch.isLetter || ch.isNumber || ch == "'" { token.append(ch) } else { flush(); out.append(ch) }
        }
        flush()
        // Multi-word phrases: match on normalised text with word boundaries.
        let normText = " " + normalise(text).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ") + " "
        for phrase in words where phrase.contains(" ") && normText.contains(" \(phrase) ") {
            hit = true
            var offset = 0
            while let start = out.index(out.startIndex, offsetBy: offset, limitedBy: out.endIndex),
                  let r = out.range(of: phrase, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], range: start..<out.endIndex) {
                offset = out.distance(from: out.startIndex, to: r.lowerBound) + 8
                out.replaceSubrange(r, with: String(repeating: "•", count: 8))
            }
        }
        if hit && rules.filterAction == .block { return (text, true, true) }
        return (out, false, hit)
    }
}
