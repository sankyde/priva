import CryptoKit
import Foundation

/// Receiver-side registry of in-flight incoming files. Chunks arrive on the bulk channel's
/// background thread and are verified + written there, never on the main thread.
nonisolated final class TransferRegistry: @unchecked Sendable {
    init() { LiveObjects.born("TransferRegistry") }
    deinit { LiveObjects.died("TransferRegistry") }

    struct Incoming {
        let messageID: String
        let contact: String
        let writer: FileCipher.Writer
        var lastReport: Date = .distantPast
    }

    private let lock = NSLock()
    private var incoming: [String: Incoming] = [:]
    var onProgress: (@Sendable (_ messageID: String, _ fileID: String, _ source: String, _ fraction: Double, _ complete: Bool) -> Void)?

    func begin(fileID: String, messageID: String, contact: String, writer: FileCipher.Writer) {
        lock.lock(); defer { lock.unlock() }
        incoming[fileID] = Incoming(messageID: messageID, contact: contact, writer: writer)
    }

    func missing(fileID: String) -> [Int]? {
        lock.lock(); defer { lock.unlock() }
        guard let t = incoming[fileID] else { return nil }
        let all = IndexSet(integersIn: 0..<t.writer.header.chunkCount)
        return Array(all.subtracting(t.writer.received))
    }

    func activeFiles(for contact: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return incoming.filter { $0.value.contact == contact }.map(\.key)
    }

    /// Called on the bulk channel's thread (one per link, so one file's chunks arrive in sequence). The chunk is
    /// verified and written outside the registry lock: the main thread's lookups never wait on disk or crypto.
    func receive(fileID: String, index: Int, data: Data, from contact: String) {
        lock.lock()
        let found = incoming[fileID]
        lock.unlock()
        guard let t = found, t.contact == contact, (try? t.writer.write(chunk: data, index: index)) != nil else { return }
        let done = t.writer.isComplete
        let fraction = Double(t.writer.received.count) / Double(t.writer.header.chunkCount)
        lock.lock()
        var report = done
        if var cur = incoming[fileID], cur.writer === t.writer {
            if Date().timeIntervalSince(cur.lastReport) > 0.1 { report = true; cur.lastReport = .now }
            incoming[fileID] = done ? nil : cur
        }
        lock.unlock()
        if done { try? t.writer.finish() }
        if report { onProgress?(t.messageID, fileID, t.contact, fraction, done) }
    }

    func cancelAll() { lock.lock(); incoming.removeAll(); lock.unlock() }

    func cancel(fileID: String) { lock.lock(); incoming[fileID] = nil; lock.unlock() }
}

/// Sender-side streaming of an encrypted file over a link's bulk channel.
nonisolated enum FileSender {
    /// What a receiver may ask for: each existing chunk at most once, in order (a request can't make this
    /// iPhone upload the same file over and over).
    static func chunksToSend(requested: [Int], chunkCount: Int) -> [Int] {
        Array(Set(requested.prefix(chunkCount * 2)).filter { (0..<chunkCount).contains($0) }).sorted()
    }

    static func stream(url: URL, fileID: String, chunks: [Int], over bulk: BulkChannel,
                       progress: @escaping @Sendable (Double) -> Void, done: @escaping @Sendable (Bool) -> Void) {
        bulk.queue.async {
            guard let reader = try? FileCipher.Reader(url: url) else { done(false); return }
            var sent = 0
            var lastReport = Date.distantPast
            for i in chunks {
                let ok = autoreleasepool { () -> Bool in
                    guard let chunk = try? reader.encryptedChunk(i) else { return false }
                    return bulk.sendChunk(fileID: fileID, index: i, data: chunk)
                }
                if !ok { done(false); return }
                sent += 1
                if Date().timeIntervalSince(lastReport) > 0.1 {
                    lastReport = .now
                    progress(Double(sent) / Double(chunks.count))
                }
            }
            progress(1)
            done(true)
        }
    }
}
