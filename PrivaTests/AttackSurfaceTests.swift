import AVFoundation
import CryptoKit
import ImageIO
import LocalAuthentication
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import Priva

/// Known attack classes from other messengers, checked against Priva without the network:
/// zero-click media parsing (BLASTPASS / FORCEDENTRY), metadata leaks in photos and videos, deceptive file and
/// display names (Telegram EvilVideo / RTLO), username enumeration (WhatsApp 2025), backup compression side
/// channels (Threema 2023, injection attacks 2024), and event-based biometric bypass (OWASP MASTG).
nonisolated final class AttackSurfaceTests: XCTestCase {

    // MARK: helpers

    private func encode(_ type: UTType, width: Int = 64, height: Int = 48, properties: [CFString: Any] = [:]) -> Data {
        let img = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: {
            let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f
        }()).image { ctx in UIColor.systemTeal.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height)) }
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img.cgImage!, properties as CFDictionary)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    // MARK: - 1. Received images: only safe formats, within a pixel budget (zero-click parsing)

    func testReceivedImagesDecodeOnlySafeFormatsWithinBudget() throws {
        // Allowed.
        for t in [UTType.jpeg, .png, .heic] {
            XCTAssertNotNil(SafeImage.decode(encode(t), maxPixel: 256), "\(t.identifier) should decode")
        }
        // Formats behind real zero-click exploits never reach a decoder.
        XCTAssertNil(SafeImage.decode(encode(.gif), maxPixel: 256), "GIF (FORCEDENTRY carried JBIG2 in a .gif)")
        XCTAssertNil(SafeImage.decode(encode(.tiff), maxPixel: 256), "TIFF")
        XCTAssertNil(SafeImage.decode(encode(.bmp), maxPixel: 256), "BMP")
        var webp = Data("RIFF".utf8); webp.append(Data([0x24, 0, 0, 0])); webp.append(Data("WEBPVP8 ".utf8)); webp.append(Bytes.random(64))
        XCTAssertNil(SafeImage.decode(webp, maxPixel: 256), "WebP (BLASTPASS / CVE-2023-4863)")
        XCTAssertNil(SafeImage.decode(Data("%PDF-1.7\n".utf8) + Bytes.random(200), maxPixel: 256), "PDF / JBIG2")
        XCTAssertNil(SafeImage.decode(Bytes.random(4096), maxPixel: 256), "random bytes")
        XCTAssertNil(SafeImage.decode(Data(), maxPixel: 256), "empty")
        // A GIF wearing a JPEG name/prefix mix: the type ImageIO detects must match too.
        var disguised = Data([0xFF, 0xD8, 0xFF]); disguised.append(encode(.gif))
        XCTAssertNil(SafeImage.decode(disguised, maxPixel: 256), "bytes that claim JPEG but aren't")

        // Decompression bomb: a PNG whose header claims 60,000 × 60,000 pixels.
        var png = encode(.png, width: 8, height: 8)
        let ihdr = png.range(of: Data("IHDR".utf8))!.upperBound
        png.replaceSubrange(ihdr..<ihdr + 8, with: Data([0, 0, 0xEA, 0x60, 0, 0, 0xEA, 0x60]))
        let t0 = Date()
        XCTAssertNil(SafeImage.decode(png, maxPixel: 256), "a 3.6-gigapixel header is refused before decoding")
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.5)

        // Thumbnails (drawn without a tap) have the tightest limits.
        XCTAssertNotNil(SafeImage.thumbnail(encode(.jpeg)))
        XCTAssertNil(SafeImage.thumbnail(Bytes.random(300_000)), "oversized thumbnail")
        XCTAssertNil(SafeImage.thumbnail(encode(.gif)), "GIF thumbnail")
        // Large images are decoded downsampled (bounded memory).
        let big = SafeImage.decode(encode(.jpeg, width: 3000, height: 2000), maxPixel: 800)
        XCTAssertEqual(max(big?.size.width ?? 0, big?.size.height ?? 0), 800)
    }

    // MARK: - 2. Photos and videos leave without location or camera metadata

    func testPhotoMetadataAndLocationAreStripped() throws {
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 48.8584, kCGImagePropertyGPSLatitudeRef: "N",
                                    kCGImagePropertyGPSLongitude: 2.2945, kCGImagePropertyGPSLongitudeRef: "E"]
        let exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: "2026:09:01 10:00:00", kCGImagePropertyExifUserComment: "secret comment"]
        let tiff: [CFString: Any] = [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 99 Pro"]
        let original = encode(.jpeg, width: 400, height: 300, properties: [kCGImagePropertyGPSDictionary: gps,
                                                                           kCGImagePropertyExifDictionary: exif,
                                                                           kCGImagePropertyTIFFDictionary: tiff])
        let before = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(original as CFData, nil)!, 0, nil) as! [CFString: Any]
        XCTAssertNotNil(before[kCGImagePropertyGPSDictionary], "fixture carries GPS")

        let prepared = try MediaPrep.image(from: original)
        let sent = try Data(contentsOf: prepared.url)
        let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(sent as CFData, nil)!, 0, nil) as! [CFString: Any]
        XCTAssertNil(props[kCGImagePropertyGPSDictionary], "no GPS leaves the phone")
        let tiffOut = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertNil(tiffOut?[kCGImagePropertyTIFFModel], "no camera model")
        let exifOut = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertNil(exifOut?[kCGImagePropertyExifDateTimeOriginal], "no capture time")
        XCTAssertNil(exifOut?[kCGImagePropertyExifUserComment])
        XCTAssertNil(sent.range(of: Data("iPhone 99 Pro".utf8)))
        XCTAssertNil(sent.range(of: Data("secret comment".utf8)))
        // The thumbnail is a fresh JPEG with no metadata either.
        let thumb = try XCTUnwrap(prepared.thumbnail)
        let tp = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(thumb as CFData, nil)!, 0, nil) as! [CFString: Any]
        XCTAssertNil(tp[kCGImagePropertyGPSDictionary])
    }

    /// Audit SEC-21: a photo picked from Files and sent as a file keeps its pixels (no re-encoding) but not where or
    /// with what it was taken.
    func testImagesSentAsFilesLoseTheirLocation() throws {
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 48.8584, kCGImagePropertyGPSLatitudeRef: "N",
                                    kCGImagePropertyGPSLongitude: 2.2945, kCGImagePropertyGPSLongitudeRef: "E"]
        let tiff: [CFString: Any] = [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 99 Pro"]
        let original = encode(.jpeg, width: 400, height: 300, properties: [kCGImagePropertyGPSDictionary: gps,
                                                                           kCGImagePropertyTIFFDictionary: tiff])
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("IMG_\(UUID().uuidString).jpg")
        try original.write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }
        let prepared = try MediaPrep.file(at: src)
        XCTAssertEqual(prepared.kind, .file, "still sent as a file")
        let sent = try Data(contentsOf: prepared.url)
        let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(sent as CFData, nil)!, 0, nil) as! [CFString: Any]
        XCTAssertNil(props[kCGImagePropertyGPSDictionary], "no GPS")
        XCTAssertNil((props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel], "no camera model")
        XCTAssertNil(sent.range(of: Data("iPhone 99 Pro".utf8)))
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 400, "same image")
    }

    func testVideoLocationIsStripped() async throws {
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("loc-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: src, fileType: .mov)
        let loc = AVMutableMetadataItem()
        loc.identifier = .quickTimeMetadataLocationISO6709
        loc.value = "+48.8584+002.2945/" as NSString
        loc.dataType = kCMMetadataBaseDataType_UTF8 as String
        let model = AVMutableMetadataItem()
        model.identifier = .quickTimeMetadataModel
        model.value = "iPhone 99 Pro" as NSString
        writer.metadata = [loc, model]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for i in 0..<15 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 15))
        }
        input.markAsFinished()
        await writer.finishWriting()
        let orig = try await AVURLAsset(url: src).load(.metadata)
        XCTAssertTrue(orig.contains { $0.identifier == .quickTimeMetadataLocationISO6709 }, "fixture carries a location")

        for optimize in [false, true] {
            let prepared = try await MediaPrep.video(from: src, optimize: optimize)
            let asset = AVURLAsset(url: prepared.url)
            let md = try await asset.load(.metadata)
            XCTAssertFalse(md.contains { $0.identifier == .quickTimeMetadataLocationISO6709 || $0.commonKey == .commonKeyLocation },
                           "no location in the sent video (optimize \(optimize))")
            let raw = try Data(contentsOf: prepared.url)
            XCTAssertNil(raw.range(of: Data("+48.8584".utf8)), "location bytes gone (optimize \(optimize))")
            XCTAssertNil(raw.range(of: Data("iPhone 99 Pro".utf8)), "device model gone (optimize \(optimize))")
        }
    }

    // MARK: - 3. Deceptive names

    func testDeceptiveFileAndDisplayNamesAreNeutralised() {
        let rtlo = "invoice\u{202E}fdp.exe"                         // shows as "invoiceexe.pdf"
        XCTAssertFalse(TextSafety.clean(rtlo, max: 120).unicodeScalars.contains("\u{202E}"))
        XCTAssertFalse(MediaPrep.sanitize(rtlo).unicodeScalars.contains("\u{202E}"))
        let att = Attachment(fileID: "x", kind: .file, name: rtlo, mime: "application/pdf", size: 1, key: Data(), header: Data(), sha256: Data())
        XCTAssertEqual(att.displayName, "invoicefdp.exe", "what you see is the real name")
        for sneaky in ["\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}", "\u{200E}", "\u{200F}", "\u{061C}", "\u{202A}", "\u{202B}", "\u{202D}", "\u{200B}", "\u{2060}", "\u{FEFF}"] {
            XCTAssertEqual(TextSafety.clean("Al\(sneaky)ice", max: 40), "Alice", "U+\(String(sneaky.unicodeScalars.first!.value, radix: 16))")
        }
        XCTAssertEqual(TextSafety.clean("Bob\n\n\u{2028}Admin\t ", max: 40), "Bob Admin", "no fake multi-line names")
        XCTAssertEqual(TextSafety.clean("👨‍👩‍👧 Family", max: 40), "👨‍👩‍👧 Family", "emoji sequences survive")
        XCTAssertEqual(TextSafety.clean(String(repeating: "A", count: 500), max: 40).count, 40)
        // Friends can't pose as the app (the lure in the "Signal Support" recovery-key phishing waves).
        for fake in ["Priva", "Priva Support", "PRIVA  Security", "Pr1va Team", "priva_official", "Príva Help", "Priva ‮ Admin"] {
            XCTAssertNil(TextSafety.name(fake), "\(fake) must fall back to the @username")
        }
        for real in ["Alice", "Privalov", "Olivia Privat", "Team Rocket"] {
            XCTAssertEqual(TextSafety.name(real), real)
        }
        XCTAssertEqual(MediaPrep.sanitize("../../../etc/passwd"), "passwd")
        XCTAssertEqual(MediaPrep.sanitize(".."), "File")
        XCTAssertEqual(MediaPrep.sanitize("a:b/c\\d"), "cd", "no path separators survive")
    }

    // MARK: - 4. Username enumeration is computationally out of reach

    /// Audit SEC-26: look-alike letters (a Greek Rho, Cyrillic o) don't get "Priva Support" past the brand check.
    func testLookAlikeLettersDontImpersonatePriva() {
        XCTAssertNil(TextSafety.name("\u{03A1}riva Support"), "Greek Rho")
        XCTAssertNil(TextSafety.name("Priv\u{0430} Team"), "Cyrillic a")
        XCTAssertNil(TextSafety.name("Pr\u{0456}va"), "Cyrillic i")
        XCTAssertEqual(TextSafety.name("Maya Chen"), "Maya Chen")
        XCTAssertEqual(TextSafety.name("Олег"), "Олег", "real Cyrillic names still work")
    }

    /// A "photo" far bigger than any photo Priva sends isn't decrypted whole into memory to be shown.
    func testAHugeFileLabelledAsAPhotoIsNotDecodedWhole() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("huge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let store = try Store(vaultKey: SymmetricKey(size: .bits256), directory: dir)
        let a = Attachment(fileID: UUID().uuidString, kind: .image, name: "p.jpg", mime: "image/jpeg",
                           size: MediaVault.maxPhotoBytes + 1, key: Bytes.random(32), header: Data(), sha256: Data(), progress: 1)
        let img = await MediaVault.shared.image(for: a, store: store)
        XCTAssertNil(img)
    }

    func testGuessingUsernamesIsTooExpensiveToEnumerate() {
        let names = (0..<3).map { _ in Username.random() }
        let t0 = Date()
        for n in names { _ = UsernameKey.commitment(n) }
        let perGuess = Date().timeIntervalSince(t0) / Double(names.count)
        let space = pow(Double(RecoveryPhrase.words.count), 3) * 10_000
        let coreYears = space * perGuess / (365 * 86_400)
        PrivaTestCase.metric("username_guess_cost", perGuess * 1000, "ms")
        PrivaTestCase.metric("username_space_bits", log2(space), "bits")
        PrivaTestCase.metric("username_enumeration_core_years", coreYears, "years")
        XCTAssertGreaterThan(perGuess, 0.03, "each guess costs a memory-hard hash")
        XCTAssertGreaterThan(coreYears, 10_000, "enumerating the space takes > 10,000 CPU-core years")
    }

    // MARK: - 5. Backup compression can't be used as a side channel (Threema 2023, injection attacks 2024)

    @MainActor func testBackupCompressionNeverMixesConversations() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("csc-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        func backup(injected: String, secret: String) throws -> (sizeOfCompressedFrames: Int, mixedFrames: Int, compressedMetadata: Int) {
            let d = dir.appendingPathComponent(UUID().uuidString)
            let store = try Store(vaultKey: .init(size: .bits256), directory: d)
            let alice = try IdentityKeys(seed: IdentityKeys.newSeed()), mallory = try IdentityKeys(seed: IdentityKeys.newSeed())
            try store.upsert(Contact(username: "alice_friend_0001", bundleRaw: try alice.bundle(username: "alice_friend_0001").raw,
                                     pair: PairSecrets(current: Bytes.random(64), previous: nil, epoch: 1), inboxTopic: "i-a"))
            var mal = Contact(username: "mallory_frnd_0002", bundleRaw: try mallory.bundle(username: "mallory_frnd_0002").raw,
                              pair: PairSecrets(current: Bytes.random(64), previous: nil, epoch: 1), inboxTopic: "i-m")
            mal.remoteName = String(injected.prefix(40))               // the attacker even controls their display name
            try store.upsert(mal)
            var ms: [Message] = []
            for i in 0..<40 {
                ms.append(Message(id: "a\(i)", contact: "alice_friend_0001", outgoing: i % 2 == 0, kind: .text,
                                  text: i == 20 ? secret : "ordinary message number \(i)", attachment: nil, sentAt: Date(timeIntervalSince1970: 1_000_000 + Double(i)), status: .delivered))
                // Mallory (a friend) sends text of her choosing: the "injection".
                ms.append(Message(id: "m\(i)", contact: "mallory_frnd_0002", outgoing: false, kind: .text,
                                  text: "\(injected) \(i)", attachment: nil, sentAt: Date(timeIntervalSince1970: 1_000_000 + Double(i)), status: .received))
            }
            try store.importMessages(ms)
            let key = BackupKey.generate(), salt = Bytes.random(16)
            let keys = BackupWriteKeys(publicKey: try key.keyPair().publicPair, passwordKey: Bytes.random(32), passwordSalt: salt,
                                       passwordRounds: BackupPasswordKDF.defaultRounds, keychainSecret: nil)
            let id = try IdentityKeys(seed: IdentityKeys.newSeed())
            let manifest = BackupManifest(username: "owner_user_0001", seed: id.seed, bundleRaw: try id.bundle(username: "owner_user_0001").raw,
                                          registered: true, created: Date(timeIntervalSince1970: 2_000_000), displayName: nil,
                                          messageCount: ms.count, contactCount: 2, groupCount: 0, mediaCount: 0)
            var size = 0, mixed = 0, compressedMeta = 0
            BackupWriter.debugOnFrame = { type, compressed, plain, sealed in
                guard type == .records else { return }
                let r = try? JSONDecoder.secondsSince1970.decode(BackupRecords.self, from: plain)
                if compressed { size += sealed }
                if let msgs = r?.messages, Set(msgs.map(\.contact)).count > 1, compressed { mixed += 1 }
                if r?.contacts?.isEmpty == false, compressed { compressedMeta += 1 }
            }
            defer { BackupWriter.debugOnFrame = nil }
            _ = try BackupExporter.write(to: d.appendingPathComponent("b.privabackup"), keys: keys, store: store, manifest: manifest)
            return (size, mixed, compressedMeta)
        }
        // 2×2 experiment: two possible secrets × Mallory's two guesses. If compression mixed her text with the secret,
        // guessing right would shrink the backup more than guessing wrong. With one context per conversation her
        // effect on the size is the same whatever the secret is: there's nothing to measure.
        let s1 = "the vault code is 7391-4485-2020", s2 = "the vault code is 5816-0327-9942"
        let r11 = try backup(injected: s1, secret: s1), r21 = try backup(injected: s2, secret: s1)
        let r12 = try backup(injected: s1, secret: s2), r22 = try backup(injected: s2, secret: s2)
        for r in [r11, r21, r12, r22] {
            XCTAssertEqual(r.mixedFrames, 0, "no compressed frame mixes two conversations")
            XCTAssertEqual(r.compressedMetadata, 0, "the contacts frame (friend-chosen names next to everything else) isn't compressed")
        }
        XCTAssertEqual(r11.sizeOfCompressedFrames - r21.sizeOfCompressedFrames, r12.sizeOfCompressedFrames - r22.sizeOfCompressedFrames,
                       "the size change from Mallory's guess doesn't depend on the secret")
    }

    // MARK: - 6. Biometrics are result-based, not event-based (Frida/Objection "evaluatePolicy → true")

    func testTheBiometricSecretCantBeReadWithoutARealFaceMatch() throws {
        #if targetEnvironment(simulator)
        // The simulator's Keychain doesn't enforce biometric access control; on an iPhone the vault secret is an ECDH
        // result computed inside the Secure Enclave with a biometry-bound key, so a hooked evaluatePolicy gets nothing.
        throw XCTSkip("biometric access control is enforced only on a device (Secure Enclave)")
        #endif
        guard let ac = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.biometryCurrentSet], nil) else {
            throw XCTSkip("no access control")
        }
        let account = "test.bio.\(UUID().uuidString)"
        do { try Keychain.set(Bytes.random(32), account: account, accessControl: ac) } catch {
            throw XCTSkip("no biometry enrolled on this simulator")
        }
        addTeardownBlock { Keychain.delete(account) }
        // A context that never saw a face: exactly what a hooked `evaluatePolicy` returning true would hand the app.
        let ctx = LAContext()
        ctx.interactionNotAllowed = true
        XCTAssertThrowsError(try Keychain.get(account, context: ctx), "the Keychain itself refuses without a real match")
    }
}

extension JSONDecoder {
    static var secondsSince1970: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }
}
