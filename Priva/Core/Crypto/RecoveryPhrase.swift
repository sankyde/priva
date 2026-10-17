import Foundation

/// BIP-39 encoding of the 32-byte master seed: 256 bits + 8-bit checksum = 24 words.
nonisolated enum RecoveryPhrase {
    enum Failure: Error, Equatable { case wordCount, unknownWord(String), checksum }

    static let wordCount = 24

    static let words: [String] = {
        guard let url = Bundle.main.url(forResource: "bip39_english", withExtension: "txt")
                ?? Bundle.allBundles.lazy.compactMap({ $0.url(forResource: "bip39_english", withExtension: "txt") }).first,
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("BIP-39 wordlist missing from bundle")
        }
        let list = text.split(whereSeparator: \.isNewline).map(String.init)
        precondition(list.count == 2048, "BIP-39 wordlist must have 2048 words")
        return list
    }()

    private static let index: [String: Int] = Dictionary(uniqueKeysWithValues: words.enumerated().map { ($1, $0) })

    static func encode(_ seed: Data) -> [String] {
        precondition(seed.count == 32)
        let checksum = KDF.sha256(seed)[0]
        let bytes = [UInt8](seed) + [checksum]
        var out: [String] = []
        var acc = 0, bits = 0
        for b in bytes {
            acc = (acc << 8) | Int(b)
            bits += 8
            while bits >= 11 {
                bits -= 11
                out.append(words[(acc >> bits) & 0x7FF])
            }
            acc &= (1 << bits) - 1
        }
        return out
    }

    static func decode(_ phrase: [String]) throws -> Data {
        let normalized = phrase.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard normalized.count == wordCount else { throw Failure.wordCount }
        var bytes: [UInt8] = []
        var acc = 0, bits = 0
        for w in normalized {
            guard let i = index[w] else { throw Failure.unknownWord(w) }
            acc = (acc << 11) | i
            bits += 11
            while bits >= 8 {
                bits -= 8
                bytes.append(UInt8((acc >> bits) & 0xFF))
            }
            acc &= (1 << bits) - 1
        }
        guard bytes.count == 33 else { throw Failure.wordCount }
        let seed = Data(bytes.prefix(32))
        guard KDF.sha256(seed)[0] == bytes[32] else { throw Failure.checksum }
        return seed
    }

    static func decode(_ text: String) throws -> Data {
        try decode(text.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init))
    }

    /// Words beginning with a prefix: powers autocomplete when restoring.
    static func suggestions(for prefix: String, limit: Int = 4) -> [String] {
        let p = prefix.lowercased()
        guard p.count >= 1 else { return [] }
        return Array(words.lazy.filter { $0.hasPrefix(p) }.prefix(limit))
    }
}

nonisolated enum SafetyNumber {
    /// 60 digits (12 groups of 5): identical on both phones for the same pair.
    static func digits(me: String, _ mine: KeyBundle, them: String, _ theirs: KeyBundle) -> [String] {
        let sides = [(me, mine), (them, theirs)].sorted { $0.0 < $1.0 }
        return sides.flatMap { groups(for: $0.1) }
    }

    private static func groups(for b: KeyBundle) -> [String] {
        var h = b.fingerprint
        for _ in 0..<1024 { h = KDF.sha512(h, b.fingerprint) }
        return (0..<6).map { i in
            let chunk = h.subdata(in: (i * 5)..<(i * 5 + 5))
            let v = chunk.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } % 100_000
            return String(format: "%05llu", v)
        }
    }

    /// Payload encoded in the QR code for in-person verification.
    static func qrPayload(username: String, bundle: KeyBundle) -> String {
        "priva:v2:\(username):\(Base32.encode(bundle.fingerprint.prefix(32)))"
    }

    static func matches(qr: String, username: String, bundle: KeyBundle) -> Bool {
        Bytes.equal(Data(qr.utf8), Data(qrPayload(username: username, bundle: bundle).utf8))
    }

    /// Short authentication string shown during calls (4 emoji, 24 bits).
    static let emoji: [String] = [
        "🦊", "🐼", "🦉", "🐙", "🦋", "🐢", "🦄", "🐝", "🌵", "🌻", "🍄", "🌙", "⭐️", "🔥", "🌊", "❄️",
        "🍎", "🍋", "🍇", "🥑", "🍩", "🎈", "🎸", "🎧", "📷", "🔑", "⚓️", "🚀", "🛸", "⛵️", "🚲", "🏔️",
        "🎲", "🧩", "🪁", "🎯", "🧭", "⏳", "💎", "🔔", "🪐", "🌈", "☂️", "🧊", "🍀", "🐳", "🦜", "🐧",
        "🦒", "🦓", "🐞", "🦀", "🪼", "🍉", "🥥", "🌶️", "🧸", "🎁", "📚", "🖋️", "🔭", "🧪", "🛡️", "🏝️",
    ]

    static func sas(_ secret: Data) -> [String] {
        let b = [UInt8](secret.prefix(3))
        let v = (Int(b[0]) << 16) | (Int(b[1]) << 8) | Int(b[2])
        return (0..<4).map { emoji[(v >> (18 - $0 * 6)) & 63] }
    }
}
