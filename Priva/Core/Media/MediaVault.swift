import AVFoundation
import CryptoKit
import UIKit

/// Decrypted media lives only in memory. Videos stream straight from the encrypted file through
/// an AVAssetResourceLoader, so no plaintext copy is ever written to disk.
final class MediaVault {
    static let shared = MediaVault()
    private let thumbs = NSCache<NSString, UIImage>()
    private let images = NSCache<NSString, UIImage>()
    private var loaders: [String: EncryptedAssetLoader] = [:]

    init() {
        thumbs.countLimit = 400
        // By bytes too: 400 thumbnails at up to 360 × 360 would be ≈ 200 MB in a media-heavy chat.
        thumbs.totalCostLimit = 48 * 1024 * 1024
        images.totalCostLimit = 160 * 1024 * 1024
    }

    func thumbnail(for a: Attachment) -> UIImage? {
        let k = a.fileID as NSString
        if let img = thumbs.object(forKey: k) { return img }
        guard let d = a.thumbnail, let img = SafeImage.thumbnail(d) else { return nil }
        thumbs.setObject(img, forKey: k, cost: Int(img.size.width * img.scale * img.size.height * img.scale * 4))
        return img
    }

    /// Photos Priva sends are re-encoded to at most 3072 px (a few MB). Anything far bigger labelled as a photo isn't
    /// decoded: it would be decrypted into memory whole first, and a friend could make that 2 GB.
    nonisolated static let maxPhotoBytes: UInt64 = 64 << 20

    func image(for a: Attachment, store: Store) async -> UIImage? {
        let k = a.fileID as NSString
        if let img = images.object(forKey: k) { return img }
        guard a.size <= Self.maxPhotoBytes else { return nil }
        let url = store.mediaURL(a.fileID), key = a.key
        let img = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let reader = try? FileCipher.Reader(url: url, key: SymmetricKey(data: key)),
                  let data = try? reader.decryptAll() else { return nil }
            return SafeImage.decode(data, maxPixel: 4096)?.preparingForDisplay()
        }.value
        if let img {
            images.setObject(img, forKey: k, cost: Int(img.size.width * img.size.height * 4))
            #if DEBUG
            decodedKeys.insert(a.fileID)
            #endif
        }
        return img
    }

    func playerItem(for a: Attachment, store: Store) -> AVPlayerItem? {
        guard let loader = try? EncryptedAssetLoader(url: store.mediaURL(a.fileID), key: SymmetricKey(data: a.key), mime: a.mime) else { return nil }
        loaders[a.fileID] = loader
        let asset = AVURLAsset(url: URL(string: "priva-enc://media/\(a.fileID).mp4")!)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        return AVPlayerItem(asset: asset)
    }

    func releasePlayer(_ fileID: String) { loaders[fileID] = nil }

    #if DEBUG
    /// Diagnostics: photos decoded and not dropped since (an upper bound: NSCache may also evict by itself).
    private var decodedKeys: Set<String> = []
    var debugDecoded: Int { decodedKeys.count }
    #endif

    /// Memory warning or going to the background: decoded photos go (thumbnails are small; a playing video keeps its
    /// loader).
    func trim() {
        images.removeAllObjects()
        #if DEBUG
        decodedKeys.removeAll()
        #endif
    }

    /// A file that's gone (disappearing message, deleted): no decoded copy stays in memory.
    func forget(_ fileID: String) {
        thumbs.removeObject(forKey: fileID as NSString)
        images.removeObject(forKey: fileID as NSString)
        loaders[fileID] = nil
        #if DEBUG
        decodedKeys.remove(fileID)
        #endif
    }

    func purge() {
        thumbs.removeAllObjects()
        images.removeAllObjects()
        loaders.removeAll()
        #if DEBUG
        decodedKeys.removeAll()
        #endif
    }
}

nonisolated final class EncryptedAssetLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "priva.media.loader", qos: .userInitiated)
    private let reader: FileCipher.Reader
    private let mime: String

    deinit { LiveObjects.died("EncryptedAssetLoader") }

    init(url: URL, key: SymmetricKey, mime: String) throws {
        reader = try FileCipher.Reader(url: url, key: key)
        self.mime = mime
        LiveObjects.born("EncryptedAssetLoader")
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource req: AVAssetResourceLoadingRequest) -> Bool {
        if let info = req.contentInformationRequest {
            info.contentType = mime.contains("quicktime") ? AVFileType.mov.rawValue : AVFileType.mp4.rawValue
            info.contentLength = Int64(reader.header.plainSize)
            info.isByteRangeAccessSupported = true
        }
        guard let dr = req.dataRequest else { req.finishLoading(); return true }
        var offset = UInt64(max(0, dr.currentOffset != 0 ? dr.currentOffset : dr.requestedOffset))
        let end = dr.requestsAllDataToEndOfResource ? reader.header.plainSize : min(reader.header.plainSize, UInt64(dr.requestedOffset) + UInt64(dr.requestedLength))
        while offset < end, !req.isCancelled {
            let n = Int(min(UInt64(1 << 20), end - offset))
            guard let chunk = try? reader.plainRange(offset: offset, length: n), !chunk.isEmpty else {
                req.finishLoading(with: NSError(domain: "Priva", code: 1))
                return true
            }
            dr.respond(with: chunk)
            offset += UInt64(chunk.count)
        }
        req.finishLoading()
        return true
    }
}
