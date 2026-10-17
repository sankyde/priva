import Foundation

nonisolated struct Contact: Codable, Identifiable, Sendable, Hashable {
    var id: String { username }
    let username: String
    var bundleRaw: Data
    var pair: PairSecrets
    /// The friend's inbox topic (derived from the inbox secret they shared with us).
    var inboxTopic: String
    var verified: Bool = false
    var addedAt: Date = .now
    var lastSeen: Date?
    var nickname: String?
    var disappearAfter: TimeInterval?
    var keyChangedAt: Date?
    /// Friend-chosen display name, received only inside end-to-end-encrypted payloads.
    var remoteName: String?
    /// The friend's announce key: we can receive their rename announcement (IDENTITY_DESIGN §7).
    var announceKey: Data?
    var announceGeneration: Int?
    /// Device-evaluated directory state ("active" / "uninstalled" / "removed") and when we checked.
    var directoryState: String?
    var directoryCheckedAt: Date?
    var pendingRename: PendingRename?
    /// Hidden contact created by a group host so a successor can reach members (GROUPS_DESIGN §6).
    var groupOnly: Bool?

    struct PendingRename: Codable, Sendable, Hashable {
        let newUsername: String
        let bundleRaw: Data
        let name: String?
        let receivedAt: Date
    }

    var displayName: String {
        if let n = nickname, !n.isEmpty { return n }
        if let n = remoteName, !n.isEmpty { return n }
        return username
    }
    var bundle: KeyBundle? { try? KeyBundle.parse(bundleRaw) }
    var looksGone: Bool { directoryState == "uninstalled" || directoryState == "removed" }

    static func == (a: Contact, b: Contact) -> Bool {
        a.username == b.username && a.verified == b.verified && a.lastSeen == b.lastSeen &&
            a.nickname == b.nickname && a.disappearAfter == b.disappearAfter && a.pair == b.pair &&
            a.remoteName == b.remoteName && a.directoryState == b.directoryState && a.pendingRename == b.pendingRename &&
            a.groupOnly == b.groupOnly && a.keyChangedAt == b.keyChangedAt && a.bundleRaw == b.bundleRaw &&
            a.inboxTopic == b.inboxTopic && a.announceKey == b.announceKey && a.addedAt == b.addedAt &&
            a.directoryCheckedAt == b.directoryCheckedAt
    }
    func hash(into h: inout Hasher) { h.combine(username) }
}

nonisolated struct Attachment: Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable { case image, video, file }
    let fileID: String
    let kind: Kind
    let name: String
    let mime: String
    let size: UInt64
    var key: Data
    let header: Data
    let sha256: Data
    var thumbnail: Data?
    var width: Int?
    var height: Int?
    var duration: Double?
    /// Local only: fraction of chunks present on this phone.
    var progress: Double = 0
    /// Local only: the file was deleted by the 90-day group media rule (key and thumbnail wiped too).
    var expired: Bool?
    /// Local only: restored from a text-only backup, the thumbnail is here, the file isn't.
    var notBackedUp: Bool?
    /// Local only: too big to fetch by itself (or not enough free space): waits for a tap (audit SEC-12).
    var held: Bool?
    /// Local only: the sender no longer has the file, so it can't be downloaded (audit STA-09).
    var unavailable: Bool?

    var isComplete: Bool { progress >= 1 }
    /// The sender chose this name: shown only after stripping deceptive characters.
    var displayName: String { let n = TextSafety.clean(name, max: 120); return n.isEmpty ? "File" : n }
    var aspect: Double {
        guard let width, let height, width > 0, height > 0 else { return 4.0 / 3.0 }
        return Double(width) / Double(height)
    }
}

nonisolated struct Message: Codable, Identifiable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable { case text, media, call, system }
    enum Status: String, Codable, Sendable { case queued, sending, delivered, read, failed, received }

    let id: String
    var contact: String
    let outgoing: Bool
    var kind: Kind
    var text: String?
    var attachment: Attachment?
    let sentAt: Date
    var receivedAt: Date?
    var status: Status
    var replyTo: String?
    var expiresAt: Date?
    var readAt: Date?
    /// Group messages: host-assigned sequence number and the member who wrote it.
    var seq: Int64?
    var sender: String?

    var needsDelivery: Bool { outgoing && (status == .queued || status == .sending) }
}

nonisolated struct OutgoingRequest: Codable, Identifiable, Sendable, Hashable {
    enum State: String, Codable, Sendable { case pending, accepted, declined }
    let id: String
    let username: String
    let bundleRaw: Data
    let envelope: Data
    let exporter: Data
    let transcript: Data
    let note: String?
    let createdAt: Date
    var attempts: Int = 0
    var lastAttempt: Date?
    var state: State = .pending
    /// Set when this request answers a friend's rename announcement: the old contact to migrate.
    var migratesContact: String?
    /// Sent after a restore to re-key an existing friendship (same identity keys; friends re-pair silently).
    var rekey: Bool?
    /// The other side refuses requests older than 30 days, so retrying stops then (audit STA-19).
    var expired: Bool { createdAt.timeIntervalSinceNow < -Self.lifetime }
    static let lifetime: TimeInterval = 30 * 86_400
}

nonisolated struct IncomingRequest: Codable, Identifiable, Sendable, Hashable {
    let id: String
    let username: String
    let bundleRaw: Data
    let inboxTopic: String
    let exporter: Data
    let transcript: Data
    let note: String?
    let receivedAt: Date
    var name: String?
    var announce: Data?
    /// A friend of our previous username who is following us to the new one.
    var formerFriend: Bool?
    var renamedFrom: String?
    /// Claims to be an existing friend but carries different keys. Priva never changes a friend's keys under the
    /// same username (reinstalls get a new username), so this is treated as a likely interception attempt.
    var keyChange: Bool?
    /// A friend (or fellow group member) who restored their account under this new username; the move was
    /// proven with their old keys (`MoveProof`).
    var movedFrom: String?
    var moveProof: Data?
    var moveTs: Int64?
    /// A second, different account claims to be the restored @old, who already moved to this username.
    /// Someone else has that backup's keys and password: never accepted automatically.
    var moveConflict: String?
}

/// Written into a restored store: the username (and keys) the backup belonged to. The restored iPhone uses them
/// once, after registering its new username, to prove the move to friends, then deletes them.
nonisolated struct RestoredFrom: Codable, Sendable {
    struct Reissue: Codable, Sendable { let username: String; let bundleRaw: Data; let note: String? }
    let username: String
    let seed: Data
    let bundleRaw: Data
    /// Friend requests the old username still had pending: sent again from the new one.
    var reissue: [Reissue] = []
}

/// Someone this user blocked. Kept on this iPhone only: nobody is told, including the blocked person. Matched by
/// username and by identity key, so renaming doesn't get around it.
nonisolated struct BlockedUser: Codable, Sendable, Identifiable, Hashable {
    var id: String { username }
    let username: String
    let identityKey: Data?
    let at: Date
}

/// Friend's side: someone we followed to a new username after they restored a backup (catches a second restore).
nonisolated struct MovedAway: Codable, Sendable {
    let old: String
    let new: String
    let oldBundleRaw: Data
    let at: Date
}

/// Old iPhone's side: this account was restored (or signed back in) on another iPhone.
nonisolated struct AccountMovedNotice: Codable, Sendable, Equatable {
    let newUsername: String
    let at: Date
    /// This iPhone's answer to "was it you?" (audit SEC-04): true = it was, false = it wasn't, nil = not yet.
    var answer: Bool?
}

/// Control items waiting in the sender's queue (e.g. an acceptance the requester hasn't received).
nonisolated struct ControlItem: Codable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case acceptance, decline }
    let id: String
    let kind: Kind
    let contact: String
    let topic: String
    let envelope: Data
    let createdAt: Date
    var attempts: Int = 0
    var lastAttempt: Date?
}

nonisolated struct CallRecord: Codable, Identifiable, Sendable, Hashable {
    enum Outcome: String, Codable, Sendable { case answered, missed, declined, failed, cancelled }
    let id: String
    let contact: String
    let outgoing: Bool
    let video: Bool
    let startedAt: Date
    var duration: TimeInterval
    var outcome: Outcome
}

nonisolated struct PrivaSettings: Codable, Sendable, Equatable {
    var readReceipts = false
    var typingIndicators = true
    var announcePresence = true
    var relayCalls = false
    var autoLockSeconds = 0
    var turnURL = ""
    var turnUsername = ""
    var turnCredential = ""
    var videoQuality = 720
    /// Name shown to friends only (sent inside end-to-end-encrypted messages).
    var displayName = ""

    init() {}

    /// Tolerant decoding: a new setting never resets the user's existing preferences.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PrivaSettings()
        readReceipts = try c.decodeIfPresent(Bool.self, forKey: .readReceipts) ?? d.readReceipts
        typingIndicators = try c.decodeIfPresent(Bool.self, forKey: .typingIndicators) ?? d.typingIndicators
        announcePresence = try c.decodeIfPresent(Bool.self, forKey: .announcePresence) ?? d.announcePresence
        relayCalls = try c.decodeIfPresent(Bool.self, forKey: .relayCalls) ?? d.relayCalls
        autoLockSeconds = try c.decodeIfPresent(Int.self, forKey: .autoLockSeconds) ?? d.autoLockSeconds
        turnURL = try c.decodeIfPresent(String.self, forKey: .turnURL) ?? d.turnURL
        turnUsername = try c.decodeIfPresent(String.self, forKey: .turnUsername) ?? d.turnUsername
        turnCredential = try c.decodeIfPresent(String.self, forKey: .turnCredential) ?? d.turnCredential
        videoQuality = try c.decodeIfPresent(Int.self, forKey: .videoQuality) ?? d.videoQuality
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? d.displayName
    }
}

/// Work the device still owes after moving to a new username (IDENTITY_DESIGN §6–7).
nonisolated struct MigrationState: Codable, Sendable {
    var announcements: [PendingAnnouncement] = []
    var revocations: [PendingRevocation] = []

    struct PendingAnnouncement: Codable, Sendable {
        let topic: String
        let envelope: Data
        let until: Date
        let formerAnnounceKey: Data
        let oldUsername: String
        var created: Date? = nil
    }

    struct PendingRevocation: Codable, Sendable {
        let username: String
        let ucommit: Data
        let secret: Data
        let notBefore: Date
    }
}
