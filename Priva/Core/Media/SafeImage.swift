import ImageIO
import UIKit
import UniformTypeIdentifiers

/// The only way a received image is decoded (lesson of BLASTPASS / FORCEDENTRY / Triangulation, which all struck
/// through rarely-used image parsers): a short allowlist of formats recognised by their bytes, the pixel budget read
/// from the header before any decoding, and a downsampled decode so memory stays bounded.
nonisolated enum SafeImage {
    static let maxSide = 16_384
    static let maxPixels = 60_000_000
    static let maxThumbnailBytes = 256 * 1024

    enum Format: CaseIterable { case jpeg, png, heic }

    static func format(of d: Data) -> Format? {
        let b = [UInt8](d.prefix(12))
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if b.count == 12, Array(b[4..<8]) == Array("ftyp".utf8) {
            let brand = String(decoding: b[8..<12], as: UTF8.self)
            if ["heic", "heix", "hevc", "heim", "heis", "mif1", "msf1"].contains(brand) { return .heic }
        }
        return nil
    }

    /// Decodes only JPEG / PNG / HEIC within the pixel budget, scaled so the longer side is at most `maxPixel`.
    static func decode(_ d: Data, maxPixel: Int) -> UIImage? {
        guard let f = format(of: d) else { return nil }
        let hint: UTType = f == .jpeg ? .jpeg : f == .png ? .png : .heic
        let allowed: Set<String> = [UTType.jpeg.identifier, UTType.png.identifier, UTType.heic.identifier, UTType.heif.identifier]
        guard let src = CGImageSourceCreateWithData(d as CFData, [kCGImageSourceShouldCache: false,
                                                                  kCGImageSourceTypeIdentifierHint: hint.identifier] as CFDictionary),
              let type = CGImageSourceGetType(src) as String?, allowed.contains(type),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= maxSide, h <= maxSide, w * h <= maxPixels else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Thumbnails arrive with the message and are drawn without a tap, so they get the tightest limits.
    static func thumbnail(_ d: Data) -> UIImage? {
        guard d.count <= maxThumbnailBytes else { return nil }
        return decode(d, maxPixel: 720)
    }
}

/// Names and file names from other people are shown verbatim, so strip what can deceive: control characters and
/// invisible formatting (bidirectional overrides turn "photo‮gpj.exe" into "photoexe.jpg", as in Telegram's EvilVideo).
nonisolated enum TextSafety {
    /// A friend-chosen display name, or nil (show the @username) if it poses as Priva itself: the lure in the 2025–26
    /// "Signal Support" phishing waves that asked people for their recovery keys.
    static func name(_ s: String) -> String? {
        let c = clean(s, max: 40)
        let folded = skeleton(c.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil))
            .filter { $0.isLetter || $0.isNumber }
        let look = folded.replacingOccurrences(of: "1", with: "i").replacingOccurrences(of: "l", with: "i")
            .replacingOccurrences(of: "0", with: "o")
        let official = ["support", "team", "security", "secure", "admin", "official", "help", "staff", "service", "verify", "app", "bot"]
        if c.isEmpty { return nil }
        let brand = look.contains("priva") || folded.contains("priva")
        let officialWord = official.contains { folded.contains($0) || look.contains($0) }
        if look == "priva" || folded == "priva" || (brand && officialWord) { return nil }
        return c
    }

    /// Greek and Cyrillic letters that look like Latin ones, folded to them before the brand check ("Ρriva" with a
    /// Greek Rho is still "priva"). A short list of the usual suspects, not all of UTS #39 (audit SEC-26).
    static func skeleton(_ s: String) -> String {
        let map: [Character: Character] = [
            "а": "a", "е": "e", "о": "o", "р": "p", "с": "c", "у": "y", "х": "x", "і": "i", "ј": "j", "ѕ": "s", "ԁ": "d",
            "ν": "v", "ο": "o", "ρ": "p", "α": "a", "ι": "i", "κ": "k", "τ": "t", "υ": "u", "ε": "e", "η": "n",
            "ɑ": "a", "ı": "i", "ⅰ": "i", "ⅴ": "v",
        ]
        return String(s.map { map[$0] ?? $0 })
    }

    static func clean(_ s: String, max: Int) -> String {
        var out = String.UnicodeScalarView()
        var lastSpace = true
        for u in s.unicodeScalars {
            let cat = u.properties.generalCategory
            if u == "\u{200D}" { out.append(u); lastSpace = false; continue }        // keeps emoji sequences
            if u.properties.isWhitespace {                                           // newlines, tabs, U+2028 → one space
                if !lastSpace { out.append(" ") }
                lastSpace = true
                continue
            }
            if cat == .control || cat == .format || cat == .privateUse { continue }
            out.append(u)
            lastSpace = false
        }
        return String(String(out).trimmingCharacters(in: .whitespaces).prefix(max))
    }
}
