import Foundation
import Observation
import Security

// MARK: - Models

/// Backup settings, stored inside the encrypted vault. Holds only the backup *public* key.
nonisolated struct BackupConfig: Codable, Sendable, Equatable {
    var xwingPK: Data
    var mlkemPK: Data
    var passwordKey: Data          // K₂ = scrypt(password), re-derived when the password changes
    var passwordSalt: Data
    var passwordRounds: Int
    var usesKeychain: Bool
    var icloud: Bool
    var automatic = true
    var created = Date.now
    var lastBackup: Date?
    var lastSize: Int64?
    var hint: String
    /// Photos, videos and files too. Off by default: text-only backups stay small (nil = off).
    var includeMedia: Bool?
    /// iCloud is on, but the last backup stayed on this iPhone (iCloud Drive off, signed out, full): why, for the
    /// backup screen. nil once a backup reaches iCloud again.
    var icloudIssue: String?

    var publicKey: KEMPublicPair? { try? KEMPublicPair(xwingRaw: xwingPK, mlkemRaw: mlkemPK) }
}

nonisolated struct BackupManifest: Codable, Sendable, Equatable {
    var version = 1
    let username: String
    let seed: Data
    let bundleRaw: Data
    let registered: Bool
    let created: Date
    let displayName: String?
    let messageCount: Int
    let contactCount: Int
    let groupCount: Int
    let mediaCount: Int
    /// Security choices that live in the vault (not the store), so a restore keeps them.
    var wipeAfterFailures: Bool? = nil
    /// false: a text-only backup (attachments keep their thumbnails, not their files). nil: older backups, which had media.
    var includesMedia: Bool? = nil
}

nonisolated struct BackupRecords: Codable, Sendable {
    var contacts: [Contact]?
    var messages: [Message]?
    var outgoing: [OutgoingRequest]?
    var incoming: [IncomingRequest]?
    var control: [ControlItem]?
    var calls: [CallRecord]?
    var kv: [String: Data]?
    var groupQueue: [Store.GroupQueued]?
}

nonisolated struct BackupMediaStart: Codable, Sendable { let fileID: String; let size: Int64 }

// MARK: - Factor F3: iCloud Keychain secret

/// 32 random bytes in a *synchronizable* Keychain item: end-to-end encrypted by iCloud Keychain and present
/// only on devices trusted by the user's Apple Account. Survives app deletion, never reaches Priva's servers.
nonisolated enum BackupKeychainFactor {
    private static let service = "com.priva.app.backup"
    private static let account = "backup.factor.v1"

    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func read() -> Data? {
        var q = base
        q[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data, d.count == 32 else { return nil }
        return d
    }

    /// Existing secret, or a new one. `nil` when iCloud Keychain can't hold it (the factor is then skipped).
    static func obtain() -> Data? {
        if let d = read() { return d }
        let secret = Bytes.random(32)
        var q = base
        q[kSecValueData as String] = secret
        q[kSecAttrSynchronizable as String] = kCFBooleanTrue!
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { return nil }
        return read() == secret ? secret : nil
    }

    static func delete() {
        var q = base
        q[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        SecItemDelete(q as CFDictionary)
    }

    #if DEBUG
    /// Multi-simulator journeys only: plays the part of iCloud Keychain bringing the secret to another iPhone.
    static func debugInstall(_ secret: Data) {
        delete()
        var q = base
        q[kSecValueData as String] = secret
        q[kSecAttrSynchronizable as String] = kCFBooleanTrue!
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }
    #endif
}

// MARK: - Where backups live

nonisolated struct BackupFile: Identifiable, Sendable, Hashable {
    enum Location: String, Sendable { case icloud, device, received, picked }
    var id: String { url.path }
    let url: URL
    let location: Location
    let header: BackupHeader
    let size: Int64

    static func == (a: Self, b: Self) -> Bool { a.url == b.url }
    func hash(into h: inout Hasher) { h.combine(url) }
}

nonisolated enum BackupLocations {
    static let fileExtension = "privabackup"
    static let keep = 2

    static func deviceDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var dir = base.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? dir.setResourceValues(rv)
        return dir
    }

    #if DEBUG
    /// Tests: plays iCloud Drive (a folder; nil = off or signed out).
    nonisolated(unsafe) static var debugICloud: (() -> URL?)?
    #endif

    /// iCloud Drive › Priva › Backups. `nil` when iCloud Drive is off or the user isn't signed in. Blocking: call off-main.
    static func icloudDirectory() -> URL? {
        #if DEBUG
        if let d = debugICloud { return d() }
        #endif
        guard FileManager.default.ubiquityIdentityToken != nil,
              let root = FileManager.default.url(forUbiquityContainerIdentifier: nil) else { return nil }
        let dir = root.appendingPathComponent("Documents", isDirectory: true).appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Right after install or an iCloud sign-in the container often isn't ready for a few seconds: ask again
    /// (signed in to iCloud at all? then up to `seconds`) instead of concluding there's no iCloud.
    static func icloudDirectory(waiting seconds: TimeInterval) async -> URL? {
        #if DEBUG
        if let d = debugICloud { return d() }
        #endif
        guard FileManager.default.ubiquityIdentityToken != nil else { return nil }
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if let dir = icloudDirectory() { return dir }
            try? await Task.sleep(for: .seconds(1))
        } while Date() < deadline
        return nil
    }

    /// Backups iCloud knows about but this iPhone hasn't listed yet (a new iPhone, a fresh install): iCloud's own
    /// index, which is ahead of the local folder listing.
    @MainActor static func indexedICloudBackups(timeout: TimeInterval) async -> [URL] {
        await withCheckedContinuation { (cont: CheckedContinuation<[URL], Never>) in
            MetadataGather(timeout: timeout, extension: fileExtension) { cont.resume(returning: $0) }.start()
        }
    }

    @MainActor private final class MetadataGather {
        private let query = NSMetadataQuery()
        private let timeout: TimeInterval
        private var done: (([URL]) -> Void)?
        private var token: NSObjectProtocol?

        init(timeout: TimeInterval, extension ext: String, done: @escaping ([URL]) -> Void) {
            self.timeout = timeout
            self.done = done
            query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
            query.predicate = NSPredicate(format: "%K LIKE %@", NSMetadataItemFSNameKey, "*." + ext)
        }

        func start() {
            token = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [self] _ in
                MainActor.assumeIsolated { self.finish() }
            }
            guard query.start() else { finish(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [self] in MainActor.assumeIsolated { self.finish() } }
        }

        private func finish() {
            guard let done else { return }
            self.done = nil
            query.disableUpdates()
            let urls = (0..<query.resultCount).compactMap { (query.result(at: $0) as? NSMetadataItem)?.value(forAttribute: NSMetadataItemURLKey) as? URL }
            query.stop()
            if let token { NotificationCenter.default.removeObserver(token) }
            done(urls)
        }
    }

    static func files(in dir: URL, location: BackupFile.Location) -> [BackupFile] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.filter { $0.pathExtension == fileExtension }.compactMap { u in
            guard let h = try? BackupReader.peek(u) else { return nil }
            let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
            return BackupFile(url: u, location: location, header: h, size: size)
        }.sorted { $0.header.created > $1.header.created }
    }

    /// Every backup this iPhone can see (iCloud first). Blocking: call off-main.
    static func list() -> [BackupFile] {
        var out: [BackupFile] = []
        if let icloud = icloudDirectory() {
            for u in (try? FileManager.default.contentsOfDirectory(at: icloud, includingPropertiesForKeys: nil)) ?? []
            where u.lastPathComponent.hasSuffix(".icloud") {
                try? FileManager.default.startDownloadingUbiquitousItem(at: u)   // placeholder → fetch
            }
            out += files(in: icloud, location: .icloud)
        }
        if let dev = try? deviceDirectory() { out += files(in: dev, location: .device) }
        return out
    }

    /// Files opened in Priva from AirDrop, Files or Mail (iOS copies them into Documents/Inbox).
    static func receivedDirectory() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("Inbox", isDirectory: true)
    }

    /// iCloud files not downloaded yet show up as `.name.icloud` placeholders.
    static func icloudPlaceholders(in dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent.hasSuffix(".\(fileExtension).icloud") }
    }

    /// "Search for backup": iCloud Drive (downloading what isn't on this iPhone yet, waiting up to `wait`), this
    /// iPhone, and files received from elsewhere. The same backup found twice is listed once. Never picks one.
    static func search(wait: TimeInterval = 10, status: @escaping @Sendable (String) -> Void = { _ in }) async -> [BackupFile] {
        var out: [BackupFile] = []
        status("Searching iCloud Drive…")
        if let icloud = await icloudDirectory(waiting: 8) {
            // What iCloud's index knows (a new iPhone may not list it locally yet), plus local placeholders.
            let indexed = await indexedICloudBackups(timeout: 6).filter { !FileManager.default.fileExists(atPath: $0.path) }
            let pending = icloudPlaceholders(in: icloud)
            for u in pending + indexed { try? FileManager.default.startDownloadingUbiquitousItem(at: u) }
            let deadline = Date().addingTimeInterval(wait)
            func left() -> Int { icloudPlaceholders(in: icloud).count + indexed.filter { !FileManager.default.fileExists(atPath: $0.path) }.count }
            var waiting = left()
            while waiting > 0, Date() < deadline {
                status("Downloading \(waiting) backup\(waiting == 1 ? "" : "s") from iCloud…")
                try? await Task.sleep(for: .milliseconds(500))
                waiting = left()
            }
            out += files(in: icloud, location: .icloud)
        }
        status("Searching this iPhone…")
        if let dev = try? deviceDirectory() { out += files(in: dev, location: .device) }
        if let inbox = receivedDirectory() { out += files(in: inbox, location: .received) }
        var seen = Set<Data>()
        // Prefer the local copy of a backup that is also in iCloud (same header id).
        let ranked = out.sorted { rank($0.location) < rank($1.location) }.filter { seen.insert($0.header.id).inserted }
        return ranked.sorted { $0.header.created > $1.header.created }
    }

    private static func rank(_ l: BackupFile.Location) -> Int {
        switch l { case .device: 0; case .received: 1; case .icloud: 2; case .picked: 3 }
    }

    /// Where a finished backup went besides this iPhone.
    enum ICloudCopy: Equatable, Sendable { case notWanted, copied(URL), unavailable, failed }

    /// Moves a finished backup into place (this iPhone, and iCloud when enabled), keeping the newest two. Only the
    /// iPhone's copy can fail the backup: iCloud being off, signed out or full leaves a good backup on this iPhone,
    /// and says so.
    static func store(_ temp: URL, name: String, icloud: Bool) throws -> ICloudCopy {
        let dev = try deviceDirectory().appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dev)
        try FileManager.default.moveItem(at: temp, to: dev)
        prune(try deviceDirectory())
        guard icloud else { return .notWanted }
        guard let dir = icloudDirectory() else { return .unavailable }
        let dst = dir.appendingPathComponent(name)
        var err: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(writingItemAt: dst, options: .forReplacing, error: &err) { url in
            // Copied under a name the list ignores, then renamed: Priva quitting mid-copy can't leave a truncated
            // "newest backup" in iCloud (its header would still read fine, and the restore would fail).
            let part = url.appendingPathExtension(partialExtension)
            do {
                try? FileManager.default.removeItem(at: part)
                try FileManager.default.copyItem(at: dev, to: part)
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.moveItem(at: part, to: url)
            } catch {
                try? FileManager.default.removeItem(at: part)
                copyError = error
            }
        }
        if err != nil || copyError != nil { return .failed }
        prune(dir)
        return .copied(dst)
    }

    static func prune(_ dir: URL) {
        for old in files(in: dir, location: .device).dropFirst(keep) { try? FileManager.default.removeItem(at: old.url) }
    }

    static let partialExtension = "partial"

    /// At launch: what an interrupted backup left behind, the half-written file in tmp, and copies that never got
    /// their final name. (Finished backups are untouched; the previous ones were never replaced.)
    static func removeLeftovers() {
        let fm = FileManager.default
        for u in (try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil)) ?? []
        where u.pathExtension == fileExtension { try? fm.removeItem(at: u) }
        for dir in [try? deviceDirectory(), icloudDirectory()].compactMap({ $0 }) {
            for u in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            where u.pathExtension == partialExtension { try? fm.removeItem(at: u) }
        }
    }

    static func deleteAll() {
        if let dev = try? deviceDirectory() { try? FileManager.default.removeItem(at: dev) }
        if let dir = icloudDirectory() {
            for f in files(in: dir, location: .icloud) { try? FileManager.default.removeItem(at: f.url) }
        }
    }
}

// MARK: - Export / import

nonisolated enum BackupExporter {
    static let groupMediaDays: TimeInterval = 90

    /// Writes the whole account to `url`. Runs off the main thread; memory stays flat (paged + streamed).
    /// `created` goes in the (authenticated) header with full precision: backups made within the same second
    /// still sort, and prune, newest first.
    static func write(to url: URL, keys: BackupWriteKeys, store: Store, manifest: BackupManifest, created: Date = .now,
                      progress: @Sendable (Double) -> Void = { _ in }) throws -> BackupHeader {
        let w = try BackupWriter(url: url, keys: keys, created: created)
        let includeMedia = manifest.includesMedia != false
        try w.writeJSON(.manifest, manifest)
        var r = BackupRecords()
        r.contacts = try store.contacts()
        r.outgoing = try store.outgoingRequests()
        r.incoming = try store.incomingRequests()
        r.control = try store.controlItems()
        r.calls = try store.calls(limit: 100_000)
        r.kv = try store.exportKV()      // includes backup.config: after a restore, backups continue with the same Backup Key
        r.groupQueue = try store.allGroupQueued()
        // Not compressed: it holds friends' names (which they choose) next to everything else about the account, and
        // compress-then-encrypt would let an injected name leak the rest through the backup's size (Threema, 2023).
        // One frame when it fits (as always); split by kind only when it doesn't.
        if try BackupWriter.encode(r).count <= BackupWriter.recordsBudget {
            try w.writeJSON(.records, r, compress: false)
        } else {
            try w.writeRecords(r.contacts ?? [], compress: false) { BackupRecords(contacts: $0) }
            try w.writeRecords(r.outgoing ?? [], compress: false) { BackupRecords(outgoing: $0) }
            try w.writeRecords(r.incoming ?? [], compress: false) { BackupRecords(incoming: $0) }
            try w.writeRecords(r.control ?? [], compress: false) { BackupRecords(control: $0) }
            try w.writeRecords(r.calls ?? [], compress: false) { BackupRecords(calls: $0) }
            try w.writeRecords((r.kv ?? [:]).sorted { $0.key < $1.key }, compress: false) { BackupRecords(kv: Dictionary(uniqueKeysWithValues: $0.map { ($0.key, $0.value) })) }
            try w.writeRecords(r.groupQueue ?? [], compress: false) { BackupRecords(groupQueue: $0) }
        }

        let now = Date()
        var media: [String] = []
        var done = 0
        let total = max(1, manifest.messageCount)
        try store.exportMessages { page in
            try Task.checkCancellation()        // Priva locked or the account was replaced: stop (audit STA-33)
            // Messages with a timer stay out of backups altogether: a backup would outlive the timer the friend set
            // (audit SEC-19).
            let keep = page.filter { $0.expiresAt == nil }
            // One compression context per conversation: anything a friend injects compresses only with the
            // conversation they're already part of, so the backup's size can't leak another chat.
            for thread in Dictionary(grouping: keep, by: \.contact).keys.sorted() {
                try w.writeRecords(keep.filter { $0.contact == thread }, compress: true) { BackupRecords(messages: $0) }
            }
            for m in keep where includeMedia {
                guard let a = m.attachment, a.isComplete, a.expired != true else { continue }
                if m.contact.hasPrefix("g:"), now.timeIntervalSince(m.sentAt) > groupMediaDays * 86_400 { continue }
                media.append(a.fileID)
            }
            done += page.count
            progress(min(0.6, Double(done) / Double(total) * 0.6))
        }
        let unique = Array(Set(media)).sorted()
        for (i, fileID) in unique.enumerated() {
            try Task.checkCancellation()
            let src = store.mediaURL(fileID)
            guard let size = (try? FileManager.default.attributesOfItem(atPath: src.path)[.size] as? NSNumber)?.int64Value,
                  let h = try? FileHandle(forReadingFrom: src) else { continue }
            try w.writeJSON(.mediaStart, BackupMediaStart(fileID: fileID, size: size))
            while true {
                let chunk: Data? = try autoreleasepool { try h.read(upToCount: 1 << 20) }
                guard let chunk, !chunk.isEmpty else { break }
                try w.write(.mediaBytes, chunk, compress: false)
            }
            try? h.close()
            try w.write(.mediaEnd, Data(), compress: false)
            progress(0.6 + 0.4 * Double(i + 1) / Double(unique.count))
        }
        try w.finish()
        progress(1)
        return w.header
    }
}

nonisolated enum BackupImporter {
    struct Result: Sendable { let manifest: BackupManifest; let messages: Int; let media: Int }

    /// Reads and verifies every frame into `store` (a fresh store under the new vault key).
    /// The caller throws the staging store away on any error: nothing is half-imported.
    static func importAll(_ reader: BackupReader, into store: Store) throws -> Result {
        var manifest: BackupManifest?
        var messages = 0, mediaCount = 0
        var media: (h: FileHandle, url: URL, expected: Int64, got: Int64)?
        while let (type, payload) = try reader.next() {
            switch type {
            case .manifest:
                guard manifest == nil else { throw BackupError.corrupted }
                let m = try reader.decodeJSON(BackupManifest.self, payload)
                guard m.seed.count == IdentityKeys.seedSize, Username.isValid(m.username) else { throw BackupError.corrupted }
                manifest = m
            case .records:
                guard manifest != nil, media == nil else { throw BackupError.corrupted }
                let r = try reader.decodeJSON(BackupRecords.self, payload)
                for c in r.contacts ?? [] where Username.isValid(c.username) { try store.upsert(c) }
                if var ms = r.messages {
                    // A text-only backup: attachments come back as their thumbnails, marked "not in backup".
                    if manifest?.includesMedia == false {
                        for i in ms.indices where ms[i].attachment != nil {
                            ms[i].attachment?.progress = 0
                            ms[i].attachment?.notBackedUp = true
                        }
                    }
                    try store.importMessages(ms)
                    messages += ms.count
                }
                for x in r.outgoing ?? [] { try store.save(x) }
                for x in r.incoming ?? [] { try store.save(x) }
                for x in r.control ?? [] { try store.save(x) }
                for x in r.calls ?? [] { try store.save(x) }
                for (k, v) in r.kv ?? [:] { try store.importKV(k, json: v) }
                for q in r.groupQueue ?? [] { try store.enqueueGroup(member: q.member, gid: q.gid, mid: q.mid, seq: q.seq) }
            case .mediaStart:
                guard media == nil else { throw BackupError.corrupted }
                let s = try reader.decodeJSON(BackupMediaStart.self, payload)
                // File ids are UUIDs: no path traversal out of the media folder.
                guard UUID(uuidString: s.fileID) != nil, s.size >= 0, s.size <= 8 << 30 else { throw BackupError.corrupted }
                let url = store.mediaURL(s.fileID)
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete])
                media = (try FileHandle(forWritingTo: url), url, s.size, 0)
            case .mediaBytes:
                guard var m = media else { throw BackupError.corrupted }
                m.got += Int64(payload.count)
                guard m.got <= m.expected else { throw BackupError.corrupted }
                try m.h.write(contentsOf: payload)
                media = m
            case .mediaEnd:
                guard let m = media, m.got == m.expected else { throw BackupError.corrupted }
                try m.h.close()
                media = nil
                mediaCount += 1
            case .padding:
                continue
            case .end:
                throw BackupError.corrupted
            }
        }
        guard reader.ended, media == nil, let manifest else { throw BackupError.truncated }
        return Result(manifest: manifest, messages: messages, media: mediaCount)
    }
}

// MARK: - Backup center (per unlocked account)

@Observable
final class BackupCenter {
    init() { LiveObjects.born("BackupCenter") }
    deinit { LiveObjects.died("BackupCenter") }

    enum Phase: Equatable { case idle, working(Double), failed(String) }

    private(set) var config: BackupConfig?
    private(set) var phase: Phase = .idle
    private(set) var files: [BackupFile] = []
    @ObservationIgnored weak var engine: PrivaEngine?

    var isOn: Bool { config != nil }
    /// Signed in to iCloud with iCloud Drive on (cheap; safe on the main thread).
    var icloudAvailable: Bool { FileManager.default.ubiquityIdentityToken != nil }
    var isWorking: Bool { if case .working = phase { return true }; return false }

    func load() { config = engine?.store.get(BackupConfig.self, for: "backup.config") }

    private func save(_ c: BackupConfig?) {
        config = c
        guard let store = engine?.store else { return }
        if let c { try? store.set(c, for: "backup.config") } else { store.removeValue(for: "backup.config") }
    }

    /// Makes a new 24-word Backup Key and the config that goes with it: nothing is saved yet. Backups turn on
    /// only in `activate`, after the user has proved they wrote the key down (an app kill mid-setup leaves them off).
    func prepare(password: String, icloud: Bool) async throws -> (BackupKey, BackupConfig) {
        let key = BackupKey.generate()
        let salt = Bytes.random(16)
        let (pk, k2): (KEMPublicPair, Data) = try await Task.detached(priority: .userInitiated) {
            (try key.keyPair().publicPair, try BackupPasswordKDF.derive(password, salt: salt))
        }.value
        let usesKeychain = await Task.detached { BackupKeychainFactor.obtain() != nil }.value
        let c = BackupConfig(xwingPK: pk.xwingRaw, mlkemPK: pk.mlkemRaw, passwordKey: k2, passwordSalt: salt,
                             passwordRounds: BackupPasswordKDF.defaultRounds, usesKeychain: usesKeychain, icloud: icloud,
                             hint: BackupKey.hint(for: pk))
        return (key, c)
    }

    func activate(_ c: BackupConfig) { save(c) }

    /// `prepare` + `activate` in one step (tests, automation).
    func setUp(password: String, icloud: Bool) async throws -> BackupKey {
        let (key, c) = try await prepare(password: password, icloud: icloud)
        activate(c)
        return key
    }

    /// Checks a typed Backup Key against this account's (for the "confirm you wrote it down" step).
    func matches(_ key: BackupKey) async -> Bool {
        guard let c = config else { return false }
        let pk = await Task.detached { try? key.keyPair().publicPair }.value
        return pk?.xwingRaw == c.xwingPK && pk?.mlkemRaw == c.mlkemPK
    }

    func setICloud(_ on: Bool) { guard var c = config else { return }; c.icloud = on; save(c) }
    func setAutomatic(_ on: Bool) { guard var c = config else { return }; c.automatic = on; save(c) }
    func setIncludeMedia(_ on: Bool) { guard var c = config else { return }; c.includeMedia = on; save(c) }

    func turnOff(deleteFiles: Bool) {
        save(nil)
        if deleteFiles { Task.detached { BackupLocations.deleteAll() } }
    }

    /// The Priva password is factor F2: re-derive it when the password changes (future backups need the new one).
    func passwordChanged(to password: String) async {
        guard var c = config else { return }
        let salt = Bytes.random(16)
        guard let k2 = await Task.detached(operation: { try? BackupPasswordKDF.derive(password, salt: salt) }).value else { return }
        c.passwordKey = k2
        c.passwordSalt = salt
        save(c)
    }

    func refreshList() async {
        files = await Task.detached(priority: .utility) { BackupLocations.list() }.value
    }

    func backUpNow() async {
        guard let engine, let c = config, let pk = c.publicKey, !isWorking else { return }
        phase = .working(0)
        let keychain = c.usesKeychain ? BackupKeychainFactor.read() : nil
        if c.usesKeychain && keychain == nil {
            // These backups are locked to iCloud Keychain too, and it's gone (turned off, or signed out of iCloud).
            phase = .failed("iCloud Keychain is off, and these backups need it. Turn it on in the Settings app, or turn backups off and on again to make backups without it.")
            return
        }
        let keys = BackupWriteKeys(publicKey: pk, passwordKey: c.passwordKey, passwordSalt: c.passwordSalt,
                                   passwordRounds: c.passwordRounds, keychainSecret: keychain)
        let store = engine.store
        let manifest = BackupManifest(username: engine.me, seed: engine.identity.seed, bundleRaw: engine.myBundle.raw,
                                      registered: engine.vault.registered, created: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded()),
                                      displayName: engine.sharedName,
                                      messageCount: store.messageCount(), contactCount: engine.friends.count,
                                      groupCount: engine.groups.groups.count, mediaCount: 0,
                                      wipeAfterFailures: Vault.meta?.wipeAfterFailures,
                                      includesMedia: c.includeMedia == true)
        let icloud = c.icloud
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + BackupLocations.fileExtension)
        let task = Task.detached(priority: .utility) { [weak self] () -> Result<(BackupHeader, Int64, BackupLocations.ICloudCopy), Error> in
            do {
                let h = try BackupExporter.write(to: temp, keys: keys, store: store, manifest: manifest) { p in
                    DispatchQueue.main.async { MainActor.assumeIsolated { if self?.isWorking == true { self?.phase = .working(p) } } }
                }
                let size = (try FileManager.default.attributesOfItem(atPath: temp.path)[.size] as? NSNumber)?.int64Value ?? 0
                let copy = try BackupLocations.store(temp, name: h.id.hex + "." + BackupLocations.fileExtension, icloud: icloud)
                return .success((h, size, copy))
            } catch {
                try? FileManager.default.removeItem(at: temp)
                return .failure(error)
            }
        }
        exportTask = task
        let result = await task.value
        exportTask = nil
        switch result {
        case .success(let (_, size, copy)):
            var cc = config ?? c
            cc.lastBackup = .now
            cc.lastSize = size
            switch copy {
            case .notWanted, .copied: cc.icloudIssue = nil
            case .unavailable: cc.icloudIssue = "The last backup is only on this iPhone: iCloud Drive is off or you're signed out of iCloud."
            case .failed: cc.icloudIssue = "The last backup is only on this iPhone: it couldn't be copied to iCloud Drive. Is your iCloud storage full?"
            }
            save(cc)
            phase = .idle
            await refreshList()
        case .failure(let e) where e is CancellationError:
            phase = .idle
        case .failure:
            phase = .failed("Backup failed. Try again.")
        }
    }

    @ObservationIgnored private var exportTask: Task<Result<(BackupHeader, Int64, BackupLocations.ICloudCopy), Error>, Never>?

    /// Locking or replacing the account stops a backup under way: it holds the store's keys while it runs.
    func cancel() { exportTask?.cancel() }

    /// The engine closed: the backup settings (with their password-derived key) leave memory too.
    func close() {
        cancel()
        config = nil
        files = []
        phase = .idle
    }

    /// Daily automatic backup while Priva is unlocked.
    func backUpIfDue() {
        guard let c = config, c.automatic, !isWorking else { return }
        if let last = c.lastBackup, Date().timeIntervalSince(last) < 86_400 { return }
        Task { await backUpNow() }
    }
}
