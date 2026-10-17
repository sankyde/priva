import AVFoundation
import CoreTransferable
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Prepares outgoing media: strips metadata (EXIF, GPS, device model, QuickTime location),
/// optionally re-encodes for size, and produces a small thumbnail. All intermediate
/// plaintext lives in a complete-protection temp directory and is deleted immediately
/// after encryption.
nonisolated enum MediaPrep {
    struct Prepared: Sendable {
        let url: URL
        let kind: Attachment.Kind
        let name: String
        let mime: String
        let thumbnail: Data?
        let width: Int?
        let height: Int?
        let duration: Double?
    }

    enum Failure: Error { case unreadable, export }

    static func tempURL(_ ext: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("priva-prep", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        return dir.appendingPathComponent(UUID().uuidString + "." + ext)
    }

    static func purgeTemp() {
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("priva-prep"))
    }

    /// Re-encodes an image as HEIC without any metadata. `maxPixel` 0 keeps full resolution.
    static func image(from data: Data, maxPixel: Int = 3072) throws -> Prepared {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw Failure.unreadable
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel > 0 ? maxPixel : 16_384,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { throw Failure.unreadable }
        let url = try tempURL("heic")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            throw Failure.export
        }
        // Only encoding parameters, never source properties → no EXIF / GPS / TIFF / maker notes survive.
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Failure.export }
        try (url as NSURL).setResourceValue(FileProtectionType.complete, forKey: .fileProtectionKey)
        return Prepared(url: url, kind: .image, name: "Photo.heic", mime: "image/heic",
                        thumbnail: thumbnail(cg), width: cg.width, height: cg.height, duration: nil)
    }

    static func thumbnail(_ cg: CGImage, maxSide: CGFloat = 360) -> Data? {
        let scale = min(1, maxSide / CGFloat(max(cg.width, cg.height)))
        let size = CGSize(width: CGFloat(cg.width) * scale, height: CGFloat(cg.height) * scale)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            UIImage(cgImage: cg).draw(in: CGRect(origin: .zero, size: size))
        }
        return img.jpegData(compressionQuality: 0.6)
    }

    /// Video: "optimized" re-encodes to HEVC 1080p; otherwise passthrough. Both strip metadata.
    static func video(from source: URL, optimize: Bool) async throws -> Prepared {
        let asset = AVURLAsset(url: source)
        let preset = optimize ? AVAssetExportPresetHEVC1920x1080 : AVAssetExportPresetPassthrough
        guard let export = AVAssetExportSession(asset: asset, presetName: preset) else { throw Failure.export }
        let out = try tempURL("mp4")
        export.metadata = []
        export.metadataItemFilter = .forSharing()
        export.shouldOptimizeForNetworkUse = true
        do { try await export.export(to: out, as: .mp4) } catch { throw Failure.export }
        try (out as NSURL).setResourceValue(FileProtectionType.complete, forKey: .fileProtectionKey)
        let exported = AVURLAsset(url: out)
        let duration = try? await exported.load(.duration).seconds
        var w: Int?, h: Int?
        if let track = try? await exported.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize), let t = try? await track.load(.preferredTransform) {
            let r = CGRect(origin: .zero, size: size).applying(t)
            w = Int(abs(r.width)); h = Int(abs(r.height))
        }
        let gen = AVAssetImageGenerator(asset: exported)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 720, height: 720)
        let thumb = (try? await gen.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image).flatMap { thumbnail($0) }
        return Prepared(url: out, kind: .video, name: "Video.mp4", mime: "video/mp4", thumbnail: thumb,
                        width: w, height: h, duration: duration)
    }

    /// Arbitrary files are sent as-is (content is encrypted; only the sanitized name travels). A photo sent as a file
    /// keeps its pixels but loses its location, camera and other metadata (audit SEC-21).
    static func file(at source: URL) throws -> Prepared {
        let out = try tempURL(source.pathExtension.isEmpty ? "bin" : String(source.pathExtension.prefix(8)))
        let type = UTType(filenameExtension: source.pathExtension)
        if type?.conforms(to: .image) == true, copyWithoutMetadata(source, to: out) {
            // done
        } else {
            try FileManager.default.copyItem(at: source, to: out)
        }
        return Prepared(url: out, kind: .file, name: sanitize(source.lastPathComponent),
                        mime: type?.preferredMIMEType ?? "application/octet-stream", thumbnail: nil, width: nil, height: nil, duration: nil)
    }

    /// Same encoded image, no EXIF/GPS/XMP: ImageIO copies it without re-encoding. False if it can't.
    private static func copyWithoutMetadata(_ source: URL, to out: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil), let uti = CGImageSourceGetType(src),
              let dest = CGImageDestinationCreateWithURL(out as CFURL, uti, CGImageSourceGetCount(src), nil) else { return false }
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: CGImageMetadataCreateMutable(),
            kCGImageDestinationMergeMetadata: false,
            kCGImageMetadataShouldExcludeXMP: true,
            kCGImageMetadataShouldExcludeGPS: true,
        ]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(dest, src, options as CFDictionary, &error) else {
            try? FileManager.default.removeItem(at: out)
            return false
        }
        return true
    }

    static func sanitize(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
        let cleaned = TextSafety.clean(base, max: 200).unicodeScalars.filter { $0 != "/" && $0 != "\\" && $0 != ":" }
        let s = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespaces)
        return s.isEmpty || s == "." || s == ".." ? "File" : String(s.prefix(120))
    }
}

/// PhotosPicker transferable for videos (copied into our protected temp directory).
nonisolated struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in SentTransferredFile(movie.url) } importing: { received in
            let dest = try MediaPrep.tempURL(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return Self(url: dest)
        }
    }
}
