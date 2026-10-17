import CryptoKit
import Foundation
import Photos

/// "Save to Photos": asks only for add-only access (Priva never reads the library). Images are handed over
/// in memory; videos are decrypted to a protected temp file that Photos moves away (and we delete on failure).
enum MediaSaver {
    enum Failure: Error { case denied, unreadable, failed }

    /// The sender always holds the whole file; a receiver only once every chunk has arrived.
    static func canSave(_ a: Attachment, outgoing: Bool) -> Bool {
        (a.kind == .image || a.kind == .video) && (outgoing || a.isComplete) && a.expired != true && !a.key.isEmpty
    }

    static func save(_ a: Attachment, store: Store) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw Failure.denied }
        let src = store.mediaURL(a.fileID), key = a.key, kind = a.kind
        let ext = a.mime.contains("quicktime") ? "mov" : (kind == .video ? "mp4" : "jpg")
        let payload: (Data?, URL?) = try await Task.detached(priority: .userInitiated) {
            guard let r = try? FileCipher.Reader(url: src, key: SymmetricKey(data: key)) else { throw Failure.unreadable }
            if kind == .image {
                let data = try r.decryptAll()
                guard SafeImage.format(of: data) != nil else { throw Failure.unreadable }   // only formats we'd display
                return (data, nil)
            }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
            FileManager.default.createFile(atPath: tmp.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete])
            let h = try FileHandle(forWritingTo: tmp)
            defer { try? h.close() }
            for i in 0..<r.header.chunkCount { try h.write(contentsOf: try r.plainChunk(i)) }
            return (nil, tmp)
        }.value
        defer { if let u = payload.1 { try? FileManager.default.removeItem(at: u) } }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let req = PHAssetCreationRequest.forAsset()
                if let data = payload.0 {
                    req.addResource(with: .photo, data: data, options: nil)
                } else if let url = payload.1 {
                    let o = PHAssetResourceCreationOptions()
                    o.shouldMoveFile = true
                    req.addResource(with: .video, fileURL: url, options: o)
                }
            }
        } catch { throw Failure.failed }
    }
}
