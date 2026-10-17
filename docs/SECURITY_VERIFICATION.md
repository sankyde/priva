# Priva: Security verification

What was *proven* about Priva's protections, how, and with what result. Every row is an automated test
that can be re-run (`PrivaTests/…`), most over the live network with real WebRTC.

## 1. Does the encryption actually encrypt? (`WireSecurityTests`)

Test-only taps (`WireTap`, compiled out of release builds) capture **every byte Priva hands to the network**:
HTTPS request lines and bodies, every rendezvous WebSocket frame (in and out), and every sealed data-channel
frame. Three phones then do everything with planted secrets ("canaries"):
- a friend request with a private note;
- display names and a nickname;
- a direct message;
- a file with a secret name *and* secret contents;
- a group with a secret name and a post;
- a video call.

| Check | Result |
|---|---|
| Canaries anywhere on the wire: raw, inside JSON, base64- or hex-decoded | **0 found** in ~650 kB (HTTPS, WebSocket, data channel) |
| Usernames of all three phones on the wire | **0** (only one-way commitments travel) |
| Call SDP (`a=fingerprint`, `candidate:`, `ice-ufrag`, `m=audio/video`) | **0**: signalling is sealed |
| Randomness of large frames / envelopes | > 7.5 bits per byte for all 32 checked (ciphertext is noise) |
| Canaries or usernames **at rest** (database, WAL, media files, app preferences) of all three phones | **0** |

## 2. Can someone listening on the rendezvous (or running it) learn or replay anything?

"Eve" is given the worst case: she knows Bob's and Alice's topics, as the server operator would, and records
everything while Bob restarts, a session is set up and a friend request arrives.

| Check | Result |
|---|---|
| Envelopes captured | 11 |
| Readable content, usernames | none |
| Distinct envelope sizes | 4 (padding buckets; sizes don't reveal content) |
| Opening them with a guessed key, or with Eve's *own real* keys with Bob | impossible |
| Replaying all of it, then again after Bob's app restarts (empty replay cache) | no duplicate messages, requests or state |

## 3. Can anyone get between a call?

| Layer | Proof | Result |
|---|---|---|
| Signalling | Sealed with pair keys; tampered, forged and replayed envelopes rejected | `EndToEndTests`, `SecurityE2ETests` |
| DTLS | The DTLS fingerprints are bound into the post-quantum handshake, so a relay can't splice in its own DTLS | `CryptoTests.testKeyConfirmationDetectsDTLSSplice` |
| Media, 1:1 | Bob decrypts with a wrong end-to-end key, which is exactly what a TURN relay, SFU or someone who broke DTLS would be left with | **1,287 packets arrived, 0 frames decoded.** Right key back: 150 frames in 5 s |
| Media, group (relayed by the host) | Same, on the member's link to the host | no frame from the host or the forwarded member decodes without the key |
| Human check | The 4-emoji security code matches on both phones | every call, including the three-phone runs |

## 4. A compromised server (`MITMSecurityTests`)

| Attack | Result |
|---|---|
| The server hands out Mallory's keys under Bob's name, and Mallory asks Alice to be friends "as Bob" | **Flagged, never applied:** Bob's pinned keys stay; Alice gets a red warning in the request and a note in the chat; accepting needs an explicit "Replace keys" confirmation. *(Hardened in this round: before, the request looked normal and could be auto-accepted.)* |
| …meanwhile | Alice's messages and calls still reach the real Bob; security codes match; Mallory gets nothing |
| Key substitution at **first contact** (true of any key directory) | The security codes on the two phones differ, so comparing them in person or scanning the QR exposes it |

## 5. Does onion routing really hide you? (`OnionModeTests`, `OnionJourneyTests`)

| Check | Result |
|---|---|
| Tor Project's own check through Priva's session factory | `IsTor: true`; the server sees a Tor exit (e.g. 185.220.101.54), never our address |
| Logging SOCKS5 proxy | Both the API and the rendezvous WebSocket go through it **by hostname**, so DNS is resolved inside Tor and nothing is resolved locally |
| Proxy down, or Tor killed mid-session | **Fails closed**: every request errors, and the socket never connects directly |
| Friend request, 21 messages, a photo, a voice call with everyone on Tor | All work. Tor ready ≈ 20–30 s, friendship ≈ 6 s, first message ≈ 4 s |
| Call routing rules | Onion mode and "Relay calls": relay-only, always (onion mode also never asks STUN). Without a relay both wait instead of going direct (since 2026-10-06, audit SEC-17); turning either on closes connections already open (audit TST-02) |

**Honest limit.** Messages, files and calls travel peer-to-peer over WebRTC (UDP), which can't go through Tor, so
in onion mode they go through a relay (TURN), which sees your IP address but not your friend's. Without a relay,
onion mode waits instead of connecting directly, and the Network screen says so (until 2026-10-04 it fell back to
direct, showing friends your IP). Priva's relay (Cloudflare Realtime TURN) is configured since 2026-10-05:
`RelayTests.testTwoPhonesTalkThroughTheRelayOnly` connects two phones relay-only and checks both connections are
relay ones, with a message and a voice call through it. Onboarding recommends a VPN for high security: it hides
the IP from the relay and Priva's servers too, without Tor's delay.

## 6. The server as an attacker sees it (`ServerSurfaceSecurityTests`, Supabase linter)

Armed with the public API key that ships in every copy of the app:

| Attempt | Result |
|---|---|
| Read any table (8 names × 3 schemas), or list the API catalogue | nothing readable; no table or service function listed |
| Call any of the 8 service functions | refused |
| Look up a random, malformed or SQL-injection "commitment" | nothing |
| Look up a real user | only status, lease week and **public** keys; the bundle doesn't contain the username |
| Renew, retire or remove someone else's username; take over their keys | refused (hybrid Ed25519 + ML-DSA-65 owner signature) |
| Replay an owner-signed operation after 6 minutes; reuse a "renew" signature as "retire" | refused (5-minute window; the operation is signed) |
| Register without a token, with a forged token, a spent token, or a taken username | refused |
| Get a token without a purchase, or with a fake App Store transaction | refused |

The Supabase security linter reports two items, both intentional:
- **Deny-all tables:** row-level security is on and there are no policies, so only server code can touch the data.
- **One public lookup:** a function that takes a commitment and returns public keys.

The live schema holds:
- **No** messages, groups, names or plaintext usernames.
- One-way username commitments only.
- Keyed-hash purchase references that can't be linked to usernames (blind signatures).

**Before launch:** `allow_dev_purchases` is currently **on** (the test detects it). It must be switched off.

## 7. Three phones at once (`MultiDeviceJourneyTests`, `scripts/multi_device_journey.sh`)

Three simulators, three processes, three Keychains, talking only through Priva. Each phone runs its own
role in 11 scenes:
1. Friendships
2. Everyone messaging everyone at once (150 messages + photos)
3. Each person's read-receipt and typing settings honoured on the others' phones
4. A group with 60 simultaneous posts in identical order everywhere, plus a photo fan-out
5. Group voice call with leave + rejoin
6. Group video call with two live streams per phone and camera toggles
7. 1:1 video call while a third caller gets "Busy"; matching security codes
8. A phone switched off, relaunched, catching up exactly once while the others call without it
9. The group's host switched off, and members' posts sequenced on return
10. Switching to onion routing mid-conversation
11. An attacker living on one phone: impersonation of a friend, friend-request spam and junk envelopes

| Route | Result | Time |
|---|---|---|
| Everyone direct | **all 3 phones pass** | ~131 s |
| Mixed (Bob on Tor from the start, Carol switches mid-journey, Alice direct) | **all 3 phones pass** | ~158 s |
| Everyone on Tor | **all 3 phones pass** | ~184 s |

## 8. Bugs this round found and fixed

1. **Existing friend with new keys looked like a normal request** (and was auto-accepted if a request was
   pending). It is now flagged, never auto-accepted, warned in the request and the chat, and needs a confirmation.
2. **Members' own group posts didn't record the host's sequence number**, so their copy disagreed with everyone
   else's. Now recorded, including for duplicates and attachments; equal timestamps sort the same on every phone.
3. **Posts written while the link to the host was connecting could be overtaken by newer ones** (seen over
   Tor). Queued posts now always go first, oldest first. While pacing, the host holds a sender's later posts until
   their oldest refused one returns, so a burst can never be reordered.

## 9. Residual risks (by design, documented)

- **First contact trusts the directory,** as with any key directory. Mitigation: security codes / QR.
- **Peer-to-peer means peers see your IP** unless you use a relay server.
- **Owner-signed directory operations can be replayed within 5 minutes,** but only by someone who can break TLS.
  The operations are idempotent (renewing twice is harmless).
- **A device that is jailbroken or has a debugger attached** is flagged but can't be fully protected against.
