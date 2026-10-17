import Foundation
import Security

nonisolated enum Bytes {
    static func random(_ count: Int) -> Data {
        var d = Data(count: count)
        let ok = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        precondition(ok == errSecSuccess, "CSPRNG failure")
        return d
    }

    /// Constant-time equality for secrets and MACs.
    static func equal(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        let x = [UInt8](a), y = [UInt8](b)
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}

nonisolated extension Data {
    init?(hex: String) {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        func nib(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 97...102: return c - 87
            case 65...70: return c - 55
            default: return nil
            }
        }
        var i = 0
        while i < chars.count {
            guard let h = nib(chars[i]), let l = nib(chars[i + 1]) else { return nil }
            out.append(h << 4 | l)
            i += 2
        }
        self = out
    }

    var hex: String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(count * 2)
        for b in self { out.append(digits[Int(b >> 4)]); out.append(digits[Int(b & 0x0f)]) }
        return String(decoding: out, as: UTF8.self)
    }

    mutating func appendBE<T: FixedWidthInteger>(_ v: T) {
        var be = v.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }

    /// Length-prefixed (u32 BE) field, used for unambiguous transcript encoding.
    mutating func appendField(_ d: Data) {
        appendBE(UInt32(d.count))
        append(d)
    }

    mutating func appendField(_ s: String) { appendField(Data(s.utf8)) }

    static func + (lhs: Data, rhs: String) -> Data { lhs + Data(rhs.utf8) }

    /// Returns a copy re-based at index 0 (Data slices keep their parent's indices).
    var detached: Data { Data(self) }
}

/// Sequential reader over binary buffers. Every read is bounds-checked.
nonisolated struct ByteReader {
    enum Failure: Error { case truncated, invalid }
    private let data: Data
    private(set) var offset: Int = 0

    init(_ data: Data) { self.data = data.detached }

    var remaining: Int { data.count - offset }
    var isAtEnd: Bool { offset == data.count }

    mutating func read(_ n: Int) throws -> Data {
        guard n >= 0, remaining >= n else { throw Failure.truncated }
        let out = data.subdata(in: offset..<(offset + n))
        offset += n
        return out
    }

    mutating func readByte() throws -> UInt8 { try read(1)[0] }

    mutating func readBE<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let bytes = try read(MemoryLayout<T>.size)
        return bytes.reduce(T(0)) { ($0 << 8) | T($1) }
    }

    mutating func readField(max: Int = 1 << 24) throws -> Data {
        let n = Int(try readBE(UInt32.self))
        guard n <= max else { throw Failure.invalid }
        return try read(n)
    }

    mutating func readRest() -> Data {
        let out = data.subdata(in: offset..<data.count)
        offset = data.count
        return out
    }
}

nonisolated enum Base32 {
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)

    /// Lowercase RFC 4648 base32 without padding (safe for topic names).
    static func encode(_ data: Data) -> String {
        var out = [UInt8]()
        var buffer: UInt32 = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[Int((buffer >> UInt32(bits - 5)) & 31)])
                bits -= 5
            }
        }
        if bits > 0 { out.append(alphabet[Int((buffer << UInt32(5 - bits)) & 31)]) }
        return String(decoding: out, as: UTF8.self)
    }
}
