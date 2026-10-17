import Foundation

/// Payloads carried inside PRK-sealed signalling envelopes on the rendezvous plane.
nonisolated enum Signal: Codable, Sendable {
    enum Intent: String, Codable, Sendable { case data, audio, video }

    /// `early`: this phone can take the three-trip handshake (older builds don't send or read it).
    case hello(sid: Data, ephX: Data, ephK: Data, intent: Intent, ts: Int64, early: Bool? = nil)
    /// `sdp` (three-trip handshake only): the responder's SDP offer, sealed with `Handshake.earlyKey`.
    case ack(sid: Data, ctX: Data, ctK: Data, ephX: Data, ephK: Data, ts: Int64, sdp: Data? = nil)
    /// Four-trip handshake. `sdp` is additionally sealed with the session signalling key (forward secret).
    case offer(sid: Data, ctX: Data, ctK: Data, sdp: Data, ts: Int64)
    case answer(sid: Data, sdp: Data, ts: Int64)
    /// Three-trip handshake: the initiator's key share and its SDP answer (sealed with the session signalling key).
    case finish(sid: Data, ctX: Data, ctK: Data, sdp: Data, ts: Int64)
    case ice(sid: Data, candidates: Data, ts: Int64)
    case bye(sid: Data, ts: Int64)
    /// ICE restart (audit STA-24): the path died (Wi-Fi ↔ cellular). The initiator's new offer and the responder's
    /// answer, sealed with the session's signalling key: same session, same call, a new path.
    case restart(sid: Data, sdp: Data, ts: Int64)
    case restarted(sid: Data, sdp: Data, ts: Int64)
    /// "I'm online": lets friends with queued items for me start delivering.
    case presence(ts: Int64)
    /// Confirms an acceptance was received (the acceptor can drop it from its queue).
    case welcome(rid: String, ts: Int64)

    var timestamp: Int64 {
        switch self {
        case .hello(_, _, _, _, let t, _), .ack(_, _, _, _, _, let t, _), .offer(_, _, _, _, let t), .finish(_, _, _, _, let t),
             .answer(_, _, let t), .ice(_, _, let t), .bye(_, let t), .presence(let t), .welcome(_, let t),
             .restart(_, _, let t), .restarted(_, _, let t): return t
        }
    }

    var sid: Data? {
        switch self {
        case .hello(let s, _, _, _, _, _), .ack(let s, _, _, _, _, _, _), .offer(let s, _, _, _, _), .finish(let s, _, _, _, _),
             .answer(let s, _, _), .ice(let s, _, _), .bye(let s, _), .restart(let s, _, _), .restarted(let s, _, _): return s
        default: return nil
        }
    }

    /// Binary property list: key material travels as raw bytes, not base64 inside JSON (a third smaller; every
    /// rendezvous signal counts against the server's egress quota). JSON from older builds is still accepted.
    func encoded() throws -> Data {
        let e = PropertyListEncoder()
        e.outputFormat = .binary
        return try e.encode(self)
    }

    static func decode(_ d: Data) -> Signal? {
        (try? PropertyListDecoder().decode(Signal.self, from: d)) ?? (try? JSONDecoder().decode(Signal.self, from: d))
    }

    /// Protocol time: this phone's clock, corrected by the server's (see `ServerClock`), so two phones whose clocks
    /// disagree, a manually set clock, a dead RTC battery, still accept each other's ±2-minute signals.
    static var now: Int64 { Int64((Date().timeIntervalSince1970 + ServerClock.offset) * 1000) }
    static let maxSkewMs: Int64 = 120_000
}

nonisolated struct ICECandidateDTO: Codable, Sendable {
    let sdp: String
    let mline: Int32
    let mid: String?
}

/// Messages exchanged over the encrypted "c" data channel.
nonisolated enum Wire: Codable, Sendable {
    struct Envelope: Codable, Sendable {
        let id: String
        let sentAt: Date
        let kind: Message.Kind
        let text: String?
        let attachment: Attachment?
        let replyTo: String?
        let expiresIn: TimeInterval?
    }

    case message(Envelope)
    case ack([String])
    case read([String])
    case typing(Bool)
    /// Receiver asks for the chunks it is missing (resume support).
    case fileWant(fileID: String, missing: [Int])
    case fileDone(fileID: String)
    /// The sender no longer has this file (deleted, expired, or it can't serve it): stop asking.
    case fileGone(fileID: String)
    case callInvite(callID: String, video: Bool)
    case callAccept(callID: String)
    case callDecline(callID: String, busy: Bool)
    case callEnd(callID: String)
    case callState(video: Bool, muted: Bool)
    case sdp(type: String, sdp: String)
    case ice(ICECandidateDTO)
    /// Display name shared with this friend only.
    case profile(name: String?)
    /// Host-centric group protocol (GROUPS_DESIGN.md).
    case group(GroupPacket)
    case ping(Int64)
    case pong(Int64)
    case bye
    /// The old iPhone's answer about a move to `new` (audit SEC-04): it was this account's owner, or it wasn't.
    case moveAnswer(new: String, mine: Bool)
}

nonisolated enum FrameType {
    static let confirm: UInt8 = 0x01
    static let control: UInt8 = 0x02
    static let chunk: UInt8 = 0x03
    /// Part of a control message too large for one data-channel message (WebRTC refuses > 256 KiB and drops the link).
    static let fragment: UInt8 = 0x04
}

nonisolated enum SDPUtil {
    /// Extracts the DTLS certificate fingerprint ("a=fingerprint:sha-256 AB:CD…").
    static func fingerprint(_ sdp: String) -> String? {
        for line in sdp.split(whereSeparator: \.isNewline) where line.hasPrefix("a=fingerprint:") {
            return String(line.dropFirst("a=fingerprint:".count)).trimmingCharacters(in: .whitespaces).lowercased()
        }
        return nil
    }

    /// "candidate:<foundation> <component> <transport> <priority> <address> <port> typ <type> …" → the part that
    /// identifies the candidate (trailing attributes such as generation or network-cost vary between reports).
    static func candidateKey(_ line: Substring) -> String? {
        guard let r = line.range(of: "candidate:") else { return nil }
        let parts = line[r.upperBound...].split(separator: " ")
        guard parts.count >= 8 else { return nil }
        return parts.prefix(8).joined(separator: " ")
    }

    /// Opus tuning: in-band FEC, DTX, stereo off, 20 ms frames, 32 kbps target.
    static func tuneOpus(_ sdp: String) -> String {
        var lines = sdp.components(separatedBy: "\r\n")
        guard let rtpmap = lines.first(where: { $0.hasPrefix("a=rtpmap:") && $0.lowercased().contains("opus/48000") }),
              let pt = rtpmap.dropFirst("a=rtpmap:".count).split(separator: " ").first else { return sdp }
        let params = "useinbandfec=1;usedtx=1;stereo=0;maxaveragebitrate=32000;minptime=10"
        if let i = lines.firstIndex(where: { $0.hasPrefix("a=fmtp:\(pt) ") }) {
            var existing = String(lines[i].dropFirst("a=fmtp:\(pt) ".count))
            for p in params.split(separator: ";") where !existing.contains(p.split(separator: "=")[0]) {
                existing += ";" + p
            }
            lines[i] = "a=fmtp:\(pt) " + existing
        } else if let i = lines.firstIndex(of: rtpmap) {
            lines.insert("a=fmtp:\(pt) \(params)", at: i + 1)
        }
        return lines.joined(separator: "\r\n")
    }
}

/// Offset between this phone's clock and the server's, learned from HTTPS `Date` headers. Only corrections over
/// 5 s are applied (the header has one-second resolution), and never more than an hour: a dishonest server could
/// at most widen replay windows it can already defeat by dropping traffic.
nonisolated enum ServerClock {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _offset: TimeInterval = 0
    static let maxOffset: TimeInterval = 3_600

    static var offset: TimeInterval { lock.lock(); defer { lock.unlock() }; return _offset }

    /// The server's own time, unclamped, carried forward with the uptime clock (which a user can't change). Decides
    /// which day's relay pass to use: a phone clock that's days off would otherwise pick passes the relay refuses
    /// (audit TST-03).
    nonisolated(unsafe) private static var lastServer: (date: Date, uptime: TimeInterval)?
    static var serverNow: Date? {
        lock.lock(); defer { lock.unlock() }
        return lastServer.map { $0.date.addingTimeInterval(ProcessInfo.processInfo.systemUptime - $0.uptime) }
    }

    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    /// `sentAt`/`receivedAt` bracket the request, so the header's time is compared with the midpoint.
    static func observe(_ response: URLResponse, sentAt: Date, receivedAt: Date = .now) {
        guard let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Date") else { return }
        lock.lock()
        let server = parser.date(from: header)
        lock.unlock()
        guard let server else { return }
        let local = sentAt.addingTimeInterval(receivedAt.timeIntervalSince(sentAt) / 2)
        let measured = server.timeIntervalSince(local)
        lock.lock()
        defer { lock.unlock() }
        _offset = abs(measured) < 5 ? 0 : max(-maxOffset, min(maxOffset, measured))
        let mid = receivedAt.timeIntervalSince(sentAt) / 2
        lastServer = (server, ProcessInfo.processInfo.systemUptime - mid)
    }

    #if DEBUG
    static func debugSet(_ o: TimeInterval) { lock.lock(); _offset = o; lastServer = nil; lock.unlock() }
    #endif
}
