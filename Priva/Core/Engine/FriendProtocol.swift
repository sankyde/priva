import Foundation

/// Friend request / acceptance messages (sealed with DualSeal, signed with hybrid signatures).
/// Identity v2: usernames travel only inside these encrypted payloads; the receiver checks the
/// sender's bundle against the device-computed commitment of the claimed username.
nonisolated enum FriendProtocol {
    struct RequestPayload: Codable, Sendable {
        let from: String
        let bundle: Data
        let inbox: String
        /// The sender's announce key: lets us receive their signed rename announcement one day.
        let announce: Data
        /// Optional name shown to friends only (never sent to any server).
        let name: String?
        let note: String?
        let rid: String
        let ts: Int64
        /// Present when this request answers a rename announcement: HMAC(announceKey, …).
        let renameProof: Data?
        let renamedFrom: String?
        /// Restored from a backup under a new username: `MoveProof` signed by the keys of `renamedFrom`.
        var moved: Data? = nil
        /// Not a request: the sender withdraws their earlier request with this id (signed like any request).
        var withdraws: String? = nil
    }

    struct AcceptPayload: Codable, Sendable {
        let from: String
        let rid: String
        let inbox: String
        let announce: Data?
        let name: String?
        let ts: Int64
        let decline: Bool?
    }

    static func requestAAD(to username: String) -> Data { Data("req|\(username)".utf8) }
    static func acceptAAD(to username: String) -> Data { Data("acc|\(username)".utf8) }

    private static func frame(_ payload: Data, _ sig: Data) -> Data {
        var d = Data()
        d.appendField(payload)
        d.append(sig)
        return d
    }

    private static func unframe(_ d: Data) throws -> (Data, Data) {
        var r = ByteReader(d)
        let p = try r.readField(max: 64 * 1024)
        let s = try r.read(HybridSigningKey.signatureSize)
        guard r.isAtEnd else { throw CryptoFailure.malformed }
        return (p, s)
    }

    // MARK: request

    struct Sealed: Sendable { let envelope: Data; let exporter: Data; let transcript: Data; let rid: String }

    static func makeRequest(from me: String, identity: IdentityKeys, myBundle: KeyBundle, to username: String, them: KeyBundle,
                            note: String?, name: String?, renameProof: Data? = nil, renamedFrom: String? = nil,
                            moved: Data? = nil, ts: Int64? = nil, withdraws: String? = nil) throws -> Sealed {
        let rid = Bytes.random(16).hex
        let payload = try JSONEncoder().encode(RequestPayload(
            from: me, bundle: myBundle.raw, inbox: identity.inboxTopic, announce: identity.announceKey, name: name,
            note: note, rid: rid, ts: ts ?? Signal.now, renameProof: renameProof, renamedFrom: renamedFrom, moved: moved,
            withdraws: withdraws))
        let sealer = try DualSeal.Sealer(to: them.kem, aad: requestAAD(to: username))
        let sig = try identity.signing.sign(Data("PRIVA-FR-v2".utf8) + sealer.transcript + KDF.sha512(payload))
        let result = try sealer.seal(frame(payload, sig))
        return Sealed(envelope: result.envelope, exporter: result.exporter, transcript: result.transcript, rid: rid)
    }

    struct OpenedRequest: Sendable {
        let payload: RequestPayload
        let bundle: KeyBundle
        let exporter: Data
        let transcript: Data
    }

    /// Decrypts and authenticates a request, including the memory-hard username binding.
    /// The caller must still confirm `bundle` against the directory.
    static func openRequest(_ env: Data, me: String, identity: IdentityKeys) throws -> OpenedRequest {
        let (pt, res) = try DualSeal.open(env, with: identity.kem, aad: requestAAD(to: me))
        let (payloadData, sig) = try unframe(pt)
        let p = try JSONDecoder().decode(RequestPayload.self, from: payloadData)
        guard Username.isValid(p.from), p.from != me, p.announce.count == 32 else { throw CryptoFailure.malformed }
        let bundle = try KeyBundle.parse(p.bundle)
        guard bundle.verifying.verify(sig, for: Data("PRIVA-FR-v2".utf8) + res.transcript + KDF.sha512(payloadData)) else {
            throw CryptoFailure.authentication
        }
        let age = Signal.now - p.ts
        guard age < 30 * 86_400_000, age > -300_000 else { throw CryptoFailure.authentication }
        guard (p.note ?? "").count <= 280, (p.name ?? "").count <= 40, p.inbox.hasPrefix("i-"), p.inbox.count < 64 else {
            throw CryptoFailure.malformed
        }
        guard bundle.belongs(to: p.from) else { throw CryptoFailure.authentication }
        return OpenedRequest(payload: p, bundle: bundle, exporter: res.exporter, transcript: res.transcript)
    }

    // MARK: acceptance

    static func makeAcceptance(from me: String, identity: IdentityKeys, request: IncomingRequest, name: String?,
                               decline: Bool = false) throws -> (Data, PairSecrets?) {
        let them = try KeyBundle.parse(request.bundleRaw)
        let payload = try JSONEncoder().encode(AcceptPayload(from: me, rid: request.id, inbox: identity.inboxTopic,
                                                             announce: decline ? nil : identity.announceKey, name: decline ? nil : name,
                                                             ts: Signal.now, decline: decline ? true : nil))
        let sealer = try DualSeal.Sealer(to: them.kem, aad: acceptAAD(to: request.username))
        let sig = try identity.signing.sign(Data("PRIVA-FA-v2".utf8) + sealer.transcript + request.transcript + KDF.sha512(payload))
        let res = try sealer.seal(frame(payload, sig))
        guard !decline else { return (res.envelope, nil) }
        let pair = PairSecrets.establish(requestExporter: request.exporter, requestTranscript: request.transcript,
                                         acceptExporter: res.exporter, acceptTranscript: res.transcript,
                                         usernames: (me, request.username))
        return (res.envelope, pair)
    }

    struct OpenedAcceptance: Sendable { let payload: AcceptPayload; let pair: PairSecrets? }

    static func openAcceptance(_ env: Data, me: String, identity: IdentityKeys, outgoing: [OutgoingRequest]) throws -> (OutgoingRequest, OpenedAcceptance) {
        let (pt, res) = try DualSeal.open(env, with: identity.kem, aad: acceptAAD(to: me))
        let (payloadData, sig) = try unframe(pt)
        let p = try JSONDecoder().decode(AcceptPayload.self, from: payloadData)
        guard let req = outgoing.first(where: { $0.id == p.rid && $0.username == p.from }) else { throw CryptoFailure.authentication }
        let them = try KeyBundle.parse(req.bundleRaw)
        guard them.verifying.verify(sig, for: Data("PRIVA-FA-v2".utf8) + res.transcript + req.transcript + KDF.sha512(payloadData)),
              p.inbox.hasPrefix("i-"), (p.name ?? "").count <= 40, p.announce.map({ $0.count == 32 }) ?? true else {
            throw CryptoFailure.authentication
        }
        if p.decline == true { return (req, OpenedAcceptance(payload: p, pair: nil)) }
        let pair = PairSecrets.establish(requestExporter: req.exporter, requestTranscript: req.transcript,
                                         acceptExporter: res.exporter, acceptTranscript: res.transcript,
                                         usernames: (me, p.from))
        return (req, OpenedAcceptance(payload: p, pair: pair))
    }
}
