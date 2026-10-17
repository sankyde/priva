import CryptoKit
import Foundation

/// Encrypted local database. Each row is AES-256-GCM(dbKey, JSON) with AAD = table ‖ id, so
/// rows cannot be swapped or moved between tables. Usernames appear only as HMAC keys.
nonisolated final class Store: @unchecked Sendable {
    private let db: SQLiteDB
    private var rowKey: SymmetricKey
    private var nameKey: Data
    private let queue = DispatchQueue(label: "priva.store", qos: .userInitiated)
    let mediaDirectory: URL

    static func directory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var dir = base.appendingPathComponent("Priva", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? dir.setResourceValues(rv)
        return dir
    }

    private var closed = false
    deinit { if !closed { LiveObjects.died("Store") } }

    /// Priva locked: the database closes and the keys go, even if something (a UIKit cache) still holds this
    /// object. Everything afterwards fails or reads as empty.
    func close() {
        sync {
            guard !closed else { return }
            closed = true
            db.close()
            rowKey = SymmetricKey(size: .bits256)
            hashLock.lock(); nameKey = Bytes.random(32); hashCache.removeAll(); hashLock.unlock()   // h() reads it off the queue
            LiveObjects.died("Store")
        }
    }

    init(vaultKey: SymmetricKey, directory: URL? = nil) throws {
        let vk = vaultKey.withUnsafeBytes { Data($0) }
        rowKey = SymmetricKey(data: KDF.derive(vk, info: "priva/db/rows/v1", count: 32))
        nameKey = KDF.derive(vk, info: "priva/db/names/v1", count: 32)
        let dir = try directory ?? Self.directory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        mediaDirectory = dir.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        db = try SQLiteDB(url: dir.appendingPathComponent("priva.db"))
        try db.exec("""
        CREATE TABLE IF NOT EXISTS contacts (h TEXT PRIMARY KEY, blob BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS messages (id TEXT PRIMARY KEY, h TEXT NOT NULL, ts INTEGER NOT NULL,
                                             pending INTEGER NOT NULL DEFAULT 0, blob BLOB NOT NULL);
        CREATE INDEX IF NOT EXISTS messages_by_contact ON messages(h, ts);
        CREATE INDEX IF NOT EXISTS messages_pending ON messages(pending, h, ts);
        CREATE TABLE IF NOT EXISTS requests (id TEXT PRIMARY KEY, dir INTEGER NOT NULL, blob BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS control (id TEXT PRIMARY KEY, h TEXT NOT NULL, ts INTEGER NOT NULL, blob BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS calls (id TEXT PRIMARY KEY, ts INTEGER NOT NULL, blob BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, blob BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS group_outbox (id TEXT PRIMARY KEY, h TEXT NOT NULL, seq INTEGER NOT NULL, blob BLOB NOT NULL);
        CREATE INDEX IF NOT EXISTS group_outbox_member ON group_outbox(h, seq);
        """)
        try migrate()
        LiveObjects.born("Store")
    }

    /// Plaintext-free columns that let recurring work find its rows without decrypting whole threads:
    /// unread (badges), expires (disappearing messages), media (the 90-day group media rule).
    private func migrate() throws {
        let version = try db.query("PRAGMA user_version") { $0.int(0) }.first ?? 0
        guard version < 3 else { return }
        for column in ["unread INTEGER NOT NULL DEFAULT 0", "expires INTEGER", "media INTEGER NOT NULL DEFAULT 0"] {
            try? db.exec("ALTER TABLE messages ADD COLUMN \(column)")      // already there on some older stores
        }
        let all = try db.query("SELECT id, blob FROM messages") { r in (r.text(0), r.blob(1)) }
        try db.transaction {
            for (id, blob) in all {
                guard let m = try? open(Message.self, blob, table: "messages", id: id) else { continue }
                try db.run("UPDATE messages SET unread = ?, expires = ?, media = ? WHERE id = ?",
                           [.int(Self.isUnread(m) ? 1 : 0), Self.expires(m), .int(Self.hasMedia(m) ? 1 : 0), .text(id)])
            }
        }
        try db.exec("""
        CREATE INDEX IF NOT EXISTS messages_unread ON messages(h, unread);
        CREATE INDEX IF NOT EXISTS messages_expires ON messages(expires) WHERE expires IS NOT NULL;
        CREATE INDEX IF NOT EXISTS messages_media ON messages(h, media, ts);
        PRAGMA user_version = 3;
        """)
    }

    private static func isUnread(_ m: Message) -> Bool { !m.outgoing && m.readAt == nil && m.kind != .system }
    private static func hasMedia(_ m: Message) -> Bool { m.attachment != nil && m.attachment?.expired != true }
    private static func expires(_ m: Message) -> SQLiteDB.Value {
        m.expiresAt.map { .int(Int64($0.timeIntervalSince1970 * 1000)) } ?? .null
    }

    /// The one way a message row is written (callers hold the queue).
    #if DEBUG
    /// Tests: message writes fail as they do on a full iPhone (SQLITE_FULL).
    var failMessageWrites = false
    #endif

    private func insert(_ m: Message) throws {
        #if DEBUG
        if failMessageWrites { throw SQLiteDB.Failure.sql("database or disk is full") }
        #endif
        try db.run("INSERT OR REPLACE INTO messages (id, h, ts, pending, unread, expires, media, blob) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", [
            .text(m.id), .text(h(m.contact)), .int(Int64(m.sentAt.timeIntervalSince1970 * 1000)),
            .int(m.needsDelivery ? 1 : 0), .int(Self.isUnread(m) ? 1 : 0), Self.expires(m), .int(Self.hasMedia(m) ? 1 : 0),
            .blob(seal(m, table: "messages", id: m.id)),
        ])
    }

    // MARK: crypto helpers

    private let hashLock = NSLock()
    private var hashCache: [String: String] = [:]

    /// Opaque, keyed name for a username / thread (memoised: it's on every query).
    private func h(_ username: String) -> String {
        hashLock.lock()
        defer { hashLock.unlock() }
        if let v = hashCache[username] { return v }
        let v = KDF.hmac(nameKey, Data(username.utf8)).prefix(16).hex
        if hashCache.count > 10_000 { hashCache.removeAll() }
        hashCache[username] = v
        return v
    }

    private func seal<T: Encodable>(_ v: T, table: String, id: String) throws -> Data {
        try AES.GCM.seal(try JSONEncoder().encode(v), using: rowKey, authenticating: Data("\(table)|\(id)".utf8)).combined!
    }

    private func open<T: Decodable>(_ t: T.Type, _ blob: Data, table: String, id: String) throws -> T {
        let pt = try AES.GCM.open(AES.GCM.SealedBox(combined: blob), using: rowKey, authenticating: Data("\(table)|\(id)".utf8))
        return try JSONDecoder().decode(t, from: pt)
    }

    private func sync<T>(_ body: () throws -> T) rethrows -> T { try queue.sync(execute: body) }

    /// Decrypts a `SELECT <id>, blob …` list. A row that no longer opens (bit rot, a half-written row from a crash)
    /// is skipped, not fatal: one bad row must not make every contact or a whole chat disappear.
    private func rows<T: Decodable>(_ t: T.Type, table: String, _ sql: String, _ values: [SQLiteDB.Value] = []) throws -> [T] {
        try db.query(sql, values) { r in (r.text(0), r.blob(1)) }.compactMap { try? open(t, $0.1, table: table, id: $0.0) }
    }

    // MARK: contacts

    func upsert(_ c: Contact) throws {
        let key = h(c.username)
        try sync { try db.run("INSERT OR REPLACE INTO contacts (h, blob) VALUES (?, ?)", [.text(key), .blob(seal(c, table: "contacts", id: key))]) }
    }

    func contacts() throws -> [Contact] {
        try sync {
            try rows(Contact.self, table: "contacts", "SELECT h, blob FROM contacts")
        }.sorted { $0.username < $1.username }
    }

    func deleteContact(_ username: String) throws {
        let key = h(username)
        try sync {
            try db.transaction {
                try db.run("DELETE FROM contacts WHERE h = ?", [.text(key)])
                try db.run("DELETE FROM messages WHERE h = ?", [.text(key)])
                try db.run("DELETE FROM control WHERE h = ?", [.text(key)])
            }
        }
    }

    /// A friend moved to a new username: move the conversation and drop the old contact record.
    func migrateConversation(from old: String, to new: String) throws {
        let msgs = try messages(with: old, limit: 1_000_000)
        try sync {
            try db.transaction {
                for var m in msgs {
                    m.contact = new
                    try insert(m)
                }
                try db.run("DELETE FROM contacts WHERE h = ?", [.text(h(old))])
                try db.run("DELETE FROM control WHERE h = ?", [.text(h(old))])
            }
        }
    }

    // MARK: messages

    func save(_ m: Message) throws { try sync { try insert(m) } }

    func message(_ id: String) throws -> Message? {
        try sync {
            try db.query("SELECT blob FROM messages WHERE id = ?", [.text(id)]) { r in try open(Message.self, r.blob(0), table: "messages", id: id) }
        }.first
    }

    /// Most recent `limit` messages before (`before`, `beforeID`) in (time, id) order, returned oldest → newest. The id
    /// breaks ties, so messages that share the boundary millisecond aren't skipped between pages.
    func messages(with username: String, limit: Int = 200, before: Date? = nil, beforeID: String? = nil) throws -> [Message] {
        let cutoff = Int64((before ?? .distantFuture).timeIntervalSince1970 * 1000)
        return try sync {
            if let beforeID {
                return try rows(Message.self, table: "messages",
                                "SELECT id, blob FROM messages WHERE h = ? AND (ts < ? OR (ts = ? AND id < ?)) ORDER BY ts DESC, id DESC LIMIT ?",
                                [.text(h(username)), .int(cutoff), .int(cutoff), .text(beforeID), .int(Int64(limit))])
            }
            return try rows(Message.self, table: "messages", "SELECT id, blob FROM messages WHERE h = ? AND ts < ? ORDER BY ts DESC, id DESC LIMIT ?",
                            [.text(h(username)), .int(cutoff), .int(Int64(limit))])
        }.reversed()
    }

    func pending(for username: String) throws -> [Message] {
        try sync {
            try rows(Message.self, table: "messages", "SELECT id, blob FROM messages WHERE pending = 1 AND h = ? ORDER BY ts ASC", [.text(h(username))])
        }
    }

    func pendingContactHashes() throws -> Set<String> {
        Set(try sync { try db.query("SELECT DISTINCT h FROM messages WHERE pending = 1") { $0.text(0) } })
    }

    /// The opaque key a username is stored under (lets the engine match index lookups to contacts).
    func hashFor(_ username: String) -> String { h(username) }

    /// Every unread message in a thread marked read, in one transaction: the whole thread, not just the loaded part
    /// (the badge counts all of it). Returns the updated messages.
    func markRead(_ username: String, at date: Date = .now) throws -> [Message] {
        try sync {
            let read = try rows(Message.self, table: "messages", "SELECT id, blob FROM messages WHERE h = ? AND unread = 1", [.text(h(username))])
                .map { m -> Message in var m = m; m.readAt = date; return m }
            guard !read.isEmpty else { return [] }
            try db.transaction { for m in read { try insert(m) } }
            return read
        }
    }

    func unreadCount(for username: String) throws -> Int {
        try sync { Int(try db.query("SELECT COUNT(*) FROM messages WHERE h = ? AND unread = 1", [.text(h(username))]) { $0.int(0) }.first ?? 0) }
    }

    func deleteMessage(_ id: String) throws { try sync { try db.run("DELETE FROM messages WHERE id = ?", [.text(id)]) } }

    /// Deletes and returns disappearing messages whose time is up (an index lookup: nothing else is decrypted).
    func expireMessages(now: Date = .now) throws -> [Message] {
        let cutoff = Int64(now.timeIntervalSince1970 * 1000)
        return try sync {
            let due = try rows(Message.self, table: "messages", "SELECT id, blob FROM messages WHERE expires IS NOT NULL AND expires <= ?", [.int(cutoff)])
            if !due.isEmpty {
                try db.run("DELETE FROM messages WHERE expires IS NOT NULL AND expires <= ?", [.int(cutoff)])
                // secure_delete zeroes the database pages, but the old rows still sit in the write-ahead log until it
                // is checkpointed: fold it in and truncate it now (audit SEC-19).
                try? db.exec("PRAGMA wal_checkpoint(TRUNCATE);")
            }
            return due
        }
    }

    /// Messages in `key` that still hold media and were sent before `cutoff` (the 90-day group media rule).
    func mediaMessages(in key: String, before cutoff: Date) throws -> [Message] {
        try sync {
            try rows(Message.self, table: "messages", "SELECT id, blob FROM messages WHERE h = ? AND media = 1 AND ts < ?",
                     [.text(h(key)), .int(Int64(cutoff.timeIntervalSince1970 * 1000))])
        }
    }

    // MARK: requests

    func save(_ r: OutgoingRequest) throws {
        try sync { try db.run("INSERT OR REPLACE INTO requests (id, dir, blob) VALUES (?, 0, ?)", [.text("o" + r.id), .blob(seal(r, table: "requests", id: "o" + r.id))]) }
    }

    func save(_ r: IncomingRequest) throws {
        try sync { try db.run("INSERT OR REPLACE INTO requests (id, dir, blob) VALUES (?, 1, ?)", [.text("i" + r.id), .blob(seal(r, table: "requests", id: "i" + r.id))]) }
    }

    func outgoingRequests() throws -> [OutgoingRequest] {
        try sync { try rows(OutgoingRequest.self, table: "requests", "SELECT id, blob FROM requests WHERE dir = 0") }
    }

    func incomingRequests() throws -> [IncomingRequest] {
        try sync { try rows(IncomingRequest.self, table: "requests", "SELECT id, blob FROM requests WHERE dir = 1") }
    }

    func deleteRequest(outgoing id: String) throws { try sync { try db.run("DELETE FROM requests WHERE id = ?", [.text("o" + id)]) } }
    func deleteRequest(incoming id: String) throws { try sync { try db.run("DELETE FROM requests WHERE id = ?", [.text("i" + id)]) } }

    // MARK: control queue

    func save(_ c: ControlItem) throws {
        try sync {
            try db.run("INSERT OR REPLACE INTO control (id, h, ts, blob) VALUES (?, ?, ?, ?)", [
                .text(c.id), .text(h(c.contact)), .int(Int64(c.createdAt.timeIntervalSince1970)), .blob(seal(c, table: "control", id: c.id)),
            ])
        }
    }

    func controlItems() throws -> [ControlItem] {
        try sync { try rows(ControlItem.self, table: "control", "SELECT id, blob FROM control ORDER BY ts") }
    }

    func deleteControl(_ id: String) throws { try sync { try db.run("DELETE FROM control WHERE id = ?", [.text(id)]) } }

    // MARK: calls

    func save(_ c: CallRecord) throws {
        try sync {
            try db.run("INSERT OR REPLACE INTO calls (id, ts, blob) VALUES (?, ?, ?)", [
                .text(c.id), .int(Int64(c.startedAt.timeIntervalSince1970)), .blob(seal(c, table: "calls", id: c.id)),
            ])
        }
    }

    func calls(limit: Int = 200) throws -> [CallRecord] {
        try sync { try rows(CallRecord.self, table: "calls", "SELECT id, blob FROM calls ORDER BY ts DESC LIMIT ?", [.int(Int64(limit))]) }
    }

    func clearCalls() throws { try sync { try db.run("DELETE FROM calls") } }

    // MARK: group host queues (messages waiting for an offline member)

    struct GroupQueued: Codable, Sendable { let member: String; let gid: String; let mid: String; let seq: Int64 }

    func enqueueGroup(member: String, gid: String, mid: String, seq: Int64) throws {
        let id = h(member) + "|" + mid
        let row = GroupQueued(member: member, gid: gid, mid: mid, seq: seq)
        try sync { try db.run("INSERT OR REPLACE INTO group_outbox (id, h, seq, blob) VALUES (?, ?, ?, ?)",
                              [.text(id), .text(h(member)), .int(seq), .blob(seal(row, table: "group_outbox", id: id))]) }
    }

    /// One post queued for many members in one transaction.
    func enqueueGroup(members: [String], gid: String, mid: String, seq: Int64) throws {
        guard !members.isEmpty else { return }
        try sync {
            try db.transaction {
                for member in members {
                    let id = h(member) + "|" + mid
                    let row = GroupQueued(member: member, gid: gid, mid: mid, seq: seq)
                    try db.run("INSERT OR REPLACE INTO group_outbox (id, h, seq, blob) VALUES (?, ?, ?, ?)",
                               [.text(id), .text(h(member)), .int(seq), .blob(seal(row, table: "group_outbox", id: id))])
                }
            }
        }
    }

    func dequeueGroup(member: String, mid: String) throws {
        try sync { try db.run("DELETE FROM group_outbox WHERE id = ?", [.text(h(member) + "|" + mid)]) }
    }

    func groupPending(member: String) throws -> [GroupQueued] {
        try sync {
            try rows(GroupQueued.self, table: "group_outbox", "SELECT id, blob FROM group_outbox WHERE h = ? ORDER BY seq ASC LIMIT 500", [.text(h(member))])
        }
    }

    func clearGroupQueue(member: String, gid: String) throws {
        for q in try groupPending(member: member) where q.gid == gid { try dequeueGroup(member: member, mid: q.mid) }
    }

    /// Everything this iPhone still had queued for a group's members (it stopped hosting, or the group ended).
    func clearGroupQueue(gid: String) throws {
        let rows = try allGroupQueued().filter { $0.gid == gid }
        guard !rows.isEmpty else { return }
        try sync { try db.transaction { for q in rows { try db.run("DELETE FROM group_outbox WHERE id = ?", [.text(h(q.member) + "|" + q.mid)]) } } }
    }

    /// Opaque keys (see `hashFor`) of members with something queued at this host: nothing is decrypted.
    func groupQueueMemberHashes() throws -> Set<String> {
        Set(try sync { try db.query("SELECT DISTINCT h FROM group_outbox") { $0.text(0) } })
    }

    func messageExists(_ id: String) -> Bool {
        ((try? sync { try db.query("SELECT 1 FROM messages WHERE id = ?", [.text(id)]) { _ in 1 } })?.isEmpty == false)
    }

    // MARK: key-value

    func set<T: Encodable>(_ v: T, for key: String) throws {
        try sync { try db.run("INSERT OR REPLACE INTO kv (k, blob) VALUES (?, ?)", [.text(key), .blob(seal(v, table: "kv", id: key))]) }
    }

    func removeValue(for key: String) {
        try? sync { try db.run("DELETE FROM kv WHERE k = ?", [.text(key)]) }
    }

    func get<T: Decodable>(_ t: T.Type, for key: String) -> T? {
        try? sync { try db.query("SELECT blob FROM kv WHERE k = ?", [.text(key)]) { r in try open(t, r.blob(0), table: "kv", id: key) } }.first
    }

    // MARK: backup export / import (plaintext records, re-sealed under the importing vault's keys)

    private func openRaw(_ blob: Data, table: String, id: String) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: blob), using: rowKey, authenticating: Data("\(table)|\(id)".utf8))
    }

    /// Messages whose text (or file name) contains `query`, newest first, on this iPhone only. Rows are encrypted,
    /// so every one is decrypted: a page at a time, so the main thread's reads and writes never wait behind a long
    /// search; `cancelled` stops it as soon as the query changes.
    func searchMessages(_ query: String, limit: Int = 60, cancelled: () -> Bool = { false }) -> [Message] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }
        var out: [Message] = [], before = Int64.max
        while out.count < limit, !cancelled() {
            let page: [(Int64, Message?)] = (try? sync {
                try db.query("SELECT rowid, id, blob FROM messages WHERE rowid < ? ORDER BY rowid DESC LIMIT 400", [.int(before)]) { r in
                    (r.int(0), try? open(Message.self, r.blob(2), table: "messages", id: r.text(1)))
                }
            }) ?? []
            guard let last = page.last else { break }
            before = last.0
            for case let (_, m?) in page where Self.matches(m, q) { out.append(m) }
        }
        return Array(out.sorted { $0.sentAt > $1.sentAt }.prefix(limit))
    }

    static func matches(_ m: Message, _ q: String) -> Bool {
        guard m.kind == .text || m.kind == .media, m.expiresAt.map({ $0 > .now }) ?? true else { return false }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return m.text?.range(of: q, options: opts) != nil || m.attachment?.name.range(of: q, options: opts) != nil
    }

    /// Streams every message in insertion order, a page at a time (constant memory).
    func exportMessages(page: Int = 500, _ body: ([Message]) throws -> Void) throws {
        var after: Int64 = 0
        while true {
            let batch: [(Int64, Message?)] = try sync {
                try db.query("SELECT rowid, id, blob FROM messages WHERE rowid > ? ORDER BY rowid LIMIT ?", [.int(after), .int(Int64(page))]) { r in
                    (r.int(0), try? open(Message.self, r.blob(2), table: "messages", id: r.text(1)))
                }
            }
            guard let last = batch.last else { return }
            after = last.0
            try body(batch.compactMap(\.1))
        }
    }

    func exportKV() throws -> [String: Data] {
        let rows = try sync { try db.query("SELECT k, blob FROM kv") { r in (r.text(0), r.blob(1)) } }
        var out: [String: Data] = [:]
        for (k, blob) in rows { out[k] = try openRaw(blob, table: "kv", id: k) }
        return out
    }

    func importKV(_ key: String, json: Data) throws {
        _ = try JSONSerialization.jsonObject(with: json, options: .fragmentsAllowed)   // must be JSON
        try sync {
            let blob = try AES.GCM.seal(json, using: rowKey, authenticating: Data("kv|\(key)".utf8)).combined!
            try db.run("INSERT OR REPLACE INTO kv (k, blob) VALUES (?, ?)", [.text(key), .blob(blob)])
        }
    }

    func allGroupQueued() throws -> [GroupQueued] {
        try sync { try rows(GroupQueued.self, table: "group_outbox", "SELECT id, blob FROM group_outbox") }
    }

    func messageCount() -> Int {
        (try? sync { try db.query("SELECT COUNT(*) FROM messages") { Int($0.int(0)) } }.first) ?? 0
    }

    /// Imports a page of messages in one transaction.
    func importMessages(_ ms: [Message]) throws {
        try sync { try db.transaction { for m in ms { try insert(m) } } }
    }

    // MARK: media files

    func mediaURL(_ fileID: String) -> URL { mediaDirectory.appendingPathComponent(fileID + ".pfe") }

    func removeMedia(_ fileID: String) { try? FileManager.default.removeItem(at: mediaURL(fileID)) }

    /// The files of every message in a thread that has one (the `media` index: no full scan, whatever was loaded).
    func mediaFileIDs(for username: String) throws -> [String] {
        try sync {
            try rows(Message.self, table: "messages", "SELECT id, blob FROM messages WHERE h = ? AND media = 1", [.text(h(username))])
                .compactMap { $0.attachment?.fileID }
        }
    }

    /// A whole thread: its messages and their files (audit STA-25: only the loaded 400 used to go). Returns the
    /// removed file ids.
    @discardableResult
    func deleteThread(_ username: String) throws -> [String] {
        let files = try mediaFileIDs(for: username)
        try sync { try db.run("DELETE FROM messages WHERE h = ?", [.text(h(username))]) }
        for f in files { removeMedia(f) }
        return files
    }

    func storageBytes() -> UInt64 {
        let urls = (try? FileManager.default.contentsOfDirectory(at: mediaDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.reduce(0) { $0 + UInt64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}
