import Foundation
import SQLite3

/// Minimal, allocation-light SQLite wrapper. Callers serialise access (see `Store`).
nonisolated final class SQLiteDB: @unchecked Sendable {
    enum Failure: Error { case open(String), sql(String), closed }
    private var db: OpaquePointer?
    /// Closed for good (Priva locked): every call fails instead of touching a dead handle.
    private var closed = false
    private var cache: [String: OpaquePointer] = [:]
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_FILEPROTECTION_COMPLETE
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else {
            throw Failure.open(String(cString: sqlite3_errmsg(db)))
        }
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA secure_delete=ON; PRAGMA foreign_keys=ON; PRAGMA temp_store=MEMORY;")
        LiveObjects.born("SQLiteDB")
    }

    deinit { close() }

    /// Callers serialise access (the Store's queue), so this never races a statement.
    func close() {
        guard !closed else { return }
        closed = true
        for s in cache.values { sqlite3_finalize(s) }
        cache.removeAll()
        sqlite3_close_v2(db)
        db = nil
        LiveObjects.died("SQLiteDB")
    }

    func exec(_ sql: String) throws {
        guard !closed else { throw Failure.closed }
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "?"
            sqlite3_free(err)
            throw Failure.sql(msg)
        }
    }

    enum Value { case int(Int64), text(String), blob(Data), null }

    private func statement(_ sql: String) throws -> OpaquePointer {
        guard !closed else { throw Failure.closed }
        if let s = cache[sql] { sqlite3_reset(s); sqlite3_clear_bindings(s); return s }
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else {
            throw Failure.sql(String(cString: sqlite3_errmsg(db)))
        }
        cache[sql] = s
        return s
    }

    private func bind(_ s: OpaquePointer, _ values: [Value]) {
        for (i, v) in values.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case .int(let n): sqlite3_bind_int64(s, idx, n)
            case .text(let t): sqlite3_bind_text(s, idx, t, -1, Self.transient)
            case .blob(let d): _ = d.withUnsafeBytes { sqlite3_bind_blob(s, idx, $0.baseAddress, Int32(d.count), Self.transient) }
            case .null: sqlite3_bind_null(s, idx)
            }
        }
    }

    func run(_ sql: String, _ values: [Value] = []) throws {
        let s = try statement(sql)
        bind(s, values)
        let rc = sqlite3_step(s)
        sqlite3_reset(s)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw Failure.sql(String(cString: sqlite3_errmsg(db))) }
    }

    struct Row {
        let s: OpaquePointer
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(s, i) }
        func text(_ i: Int32) -> String { sqlite3_column_text(s, i).map { String(cString: $0) } ?? "" }
        func blob(_ i: Int32) -> Data {
            guard let p = sqlite3_column_blob(s, i) else { return Data() }
            return Data(bytes: p, count: Int(sqlite3_column_bytes(s, i)))
        }
    }

    func query<T>(_ sql: String, _ values: [Value] = [], _ map: (Row) throws -> T) throws -> [T] {
        let s = try statement(sql)
        bind(s, values)
        defer { sqlite3_reset(s) }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_ROW { out.append(try map(Row(s: s))) } else if rc == SQLITE_DONE { break } else {
                throw Failure.sql(String(cString: sqlite3_errmsg(db)))
            }
        }
        return out
    }

    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do { try body(); try exec("COMMIT") } catch { try? exec("ROLLBACK"); throw error }
    }
}
