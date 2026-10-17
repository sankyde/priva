# Priva: production readiness audit (September 2026)

Every source file was read (app ≈ 14k lines, server ≈ 1k, UI included). Each hole found was logged below, fixed
where it could be fixed in code, and given a test that tries to break it. Latency and memory were measured with
user journeys before and after the fixes.

## Verdict

The code is in good shape: the cryptography, the protocol checks and the attack surface held up to a line-by-line
read, and every hole found in code is now fixed and tested. **It is not yet ready to launch**, for reasons that are
infrastructure and product decisions rather than code quality: see *Launch blockers*.

Second pass (free tier, App Store readiness): the App Review blockers that code could fix are fixed (block, report,
terms, review buddy, relay plumbing); what remains needs the developer's accounts, a support address, a privacy-policy
URL, a Cloudflare TURN key, test-data cleanup, switching off development purchases, a TestFlight pass on two iPhones,
plus one product decision: wake-up notifications (L2). On the free Supabase plan Priva serves roughly 300 daily
active users (docs/FREE_TIER_CAPACITY.md).

## Launch blockers

Updated in the second pass (below the table: what changed). `scripts/launch_check.sh` checks what can be checked;
docs/LAUNCH_CHECKLIST.md has the steps.

| # | Blocker | Why it matters | Status / what to do |
|---|---|---|---|
| L1 | **No TURN relay by default** (STUN only) | When both phones sit behind symmetric / carrier-grade NAT, no direct path exists: the link never opens and messages stay queued. Industry measurements put relay-only sessions at roughly 10–25% of consumer WebRTC traffic, most of it on mobile carriers. | **Built, needs two secrets.** The `turn` edge function (deployed) mints 6-hour Cloudflare TURN credentials (1,000 GB/month free); the app fetches them at unlock and offers them to WebRTC. Create a Cloudflare TURN key and set `CF_TURN_KEY_ID` / `CF_TURN_KEY_API_TOKEN`. |
| L2 | **No delivery while the app is closed** | iOS suspends Priva in the background, so its rendezvous socket closes. Messages move only while *both* phones have Priva open (groups: while the host's is). Calls can't ring a phone that isn't in Priva. | Designed (docs/PUSH_DESIGN.md: content-free APNs alerts + VoIP/CallKit for calls, per-friend push topics). Needs an APNs key from the developer account. |
| L3 | `allow_dev_purchases` is still **on** in `priva.app_config` | Anyone who calls the token function directly gets free usernames. | Switch it off: after registering the review buddy (checklist steps 4–6). |
| L4 | Supabase **free tier** | Caps usage. | Measured and optimised: see docs/FREE_TIER_CAPACITY.md (≈ 300 daily active users; 200+ online at once). |
| L5 | Hardware-only paths untested | Secure Enclave key agreement, real Face ID, iCloud Drive + iCloud Keychain sync, App Store receipts, CallKit/audio routes, camera. | One pass on two physical iPhones (TestFlight) before submission. |
| L6 | The app didn't compile for a real iPhone | - | Fixed in the first pass. |
| L7 | **App Review guideline 1.2** (apps where people message each other): block, report, terms, 24-hour moderation | Guaranteed rejection without them. | **Built** (A26). Remaining: set `PrivaSupportEmail`, publish the privacy policy at a URL, handle reports (docs/MODERATION.md). |
| L8 | **A reviewer can't test a peer-to-peer app alone** | One iPhone, nobody to message → "couldn't review the app's features". | **Built:** `ReviewBuddy`, a persistent test account that accepts, replies, answers calls and joins groups while the app is in review. |
| L10 | **Rendezvous region** (us-east-2, Ohio) | Every trip through the server costs ≈ 1 round trip to the region: ≈ 270 ms from India, so a first message there takes ≈ 1.1 s; near Ohio ≈ 0.3 s. | Create the production project in the region nearest most users (a new project: the region can't be moved). |
| L9 | Test data in the production project (≈ 2,000 dev purchases, ~140 test usernames) | Real users would share the directory with test accounts. | Clean before launch (checklist step 4). |

## Findings and fixes

Severity: 🔴 high · 🟠 medium · 🟡 low · ⚪ hardening

| ID | Sev | Area | Finding | Fix | Test |
|---|---|---|---|---|---|
| A1 | 🟠 | Identity | If scrypt failed (memory pressure), a username's commitment fell back to a **constant** and was cached: every name would map to one directory row that an attacker could pre-register, receiving other people's friend requests. | Retry, then fail closed with a random, uncached value. | `ProductionHardeningTests.testAUsernameHashThatCantBeComputedFailsClosed` |
| A2 | ⚪ | Files | A file header's size fed overflow-trapping arithmetic. Not reachable (attachments are capped at 8 GB first) but one missing check away from a crash. | Header parser refuses sizes over 1 TB. | `testCraftedFileSizesAndBackupCostsAreRefusedCheaply` |
| A3 | 🟠 | Vault | Keychain writes deleted the item and re-added it: a kill in between (e.g. after a password change or registration) loses `vault.meta`, i.e. the account, until the recovery phrase is used. | Update in place; only biometric-policy items are replaced. | `testKeychainWritesReplaceInPlace` |
| A4 | 🟡 | Erase | "Erase after 10 tries" / delete account left backups kept on the phone, backup files received by AirDrop and restore staging folders. | `Vault.wipeFiles()` removes them all. | `testEraseRemovesBackupsReceivedFilesAndRestoresInProgress` |
| A5 | 🔴 perf | Scheduler | Disappearing messages: every 10 s, **every chat's last 5,000 messages were decrypted** to find expired ones (212 ms per sweep on a 60-chat account). | Indexed `expires` column; the sweep is one index lookup. | `PerformanceJourneyTests` budget |
| A6 | 🟠 perf | Groups | Every 1.5 s tick a host decrypted up to 2,000 queued rows to see who needed a connection. | `SELECT DISTINCT` over the opaque member key. | same |
| A7 | 🟠 leak | Network | Locking leaked the realtime client (its URLSession held it as delegate, never invalidated): a socket client, session and network monitor per lock. | Session exists only while connected; invalidated on disconnect. | `testLockUnlockCyclesLeaveNothingBehind` |
| A8 | 🟡 | P2P | A frame the data channel refused had already used its counter; the next frame then failed authentication and the session died with a misleading reason. | Refused send → clean close and reconnect (queued messages survive). | code review |
| A9 | 🟡 | Files | A friend's single `fileWant` could list chunks any number of times, making this phone upload the file over and over. | De-duplicated, bounded to the file's chunks. | `testFileRequestsAreDeduplicatedAndBounded` |
| A10 | 🟠 perf | Unlock | Unlock re-read the last 300 messages of every chat twice (resume transfers), decrypted up to 100,000 messages per group (media rule) and 2,000 per hosted group (file map): all on the main thread. | Persisted indexes for in-flight files and hosted group files; media rule runs from an index, not at unlock; chunk checks moved off the main thread. | `testUnlockAndBackgroundWorkOnAHeavyAccount` |
| A12 | 🟠 | Groups | A group host (or an admin, through the host) could **delete any message on a member's phone by id**, their 1:1 chats or other groups, and rewrite the status of any outgoing message. | Deletes, "posted" acks and duplicate checks are scoped to the group's own thread. | `testAGroupHostCantDeleteOrAlterMessagesOutsideTheGroup` (live) |
| A13 | 🟡 | Backup | A crafted backup header could demand 1 GiB of scrypt memory → the app is killed when the user tries to unlock it. | Cost capped at 2¹⁸ (256 MiB); refused before allocating. | `testCraftedFileSizesAndBackupCostsAreRefusedCheaply` |
| A14 | 🟡 perf | UI | The security-code screen recomputed 2,048 SHA-512 rounds and a PQ signature check on every redraw (presence updates redraw often). | Computed once, off the main thread. | code review |
| A15 | 🟡 | Messages | A friend could date messages up to a year in the future, pinning them under everything said later. | Future skew limited to 10 minutes (queued messages may still be old). | `testFutureDatedMessagesAreRefused` |
| A16 | ⚪ perf | Crypto | Contacts' key bundles were re-verified (Ed25519 + ML-DSA-65) on every read. | Verified bundles cached by the SHA-256 of their exact bytes. | existing crypto tests |
| A17 | ⚪ perf | Store | Every query recomputed an HMAC of the name and hex-encoded it with `String(format:)` per byte. | Memoised name keys; table-driven hex. | - |
| A18 | ⚪ | Engine | Two maps grew without bound over long sessions (unanswered pings, per-request broadcast chains). | Pruned. | code review |
| A19 | ⚪ | Transfers | Incoming chunks were decrypted and written while holding the registry lock the main thread waits on. | Written outside the lock; the writer has its own lock. | file-transfer tests |
| A20 | 🟡 | Password | Changing the password needs Face ID while unlocked, not the current password. | Logged (design choice; an attacker also needs the owner's face). | - |
| A21 | 🟠 | Protocol | Signals must be within ±2 minutes: a phone whose clock is set by hand or has drifted could connect to **no one**, and its directory operations were refused. | Protocol time is corrected by the server's HTTPS `Date` header (ignored under 5 s, capped at ±1 h so a dishonest server gains nothing). | `testAWrongPhoneClockIsCorrectedByTheServersClockWithinLimits` |
| A22 | 🟠 | Store | Lists decrypt row by row and threw on the first bad row: one damaged row (bit rot, torn write) made **every contact** or a whole chat disappear. | Unreadable rows are skipped, the rest still load. | `testADamagedRowIsSkippedNotFatal` |
| A23 | 🟡 leak | Group calls | Relayed participants' transceivers were paused, never stopped: a long-lived host link gained two media sections per member per group call. | Stopped, so renegotiation recycles them (media sections stay at 5 across calls). | `testRepeatedCallsDontKeepGrowingMemory` |

### Second pass (free tier, App Store readiness, UX)

| ID | Sev | Area | Finding | Fix | Test |
|---|---|---|---|---|---|
| A24 | 🟠 | Free tier | Every rendezvous signal is metered (Supabase counts 1 sent + 1 per receiver; 2 M a month free). Priva announced itself to **every** contact on every reconnect, retried offline friends every 60 s forever, sent network candidates as separate signals and closed idle links after 90 s. | Presence only to friends active in the last 30 days (≤ 60), once per unlock and at most every 3 minutes on reconnects; retry backoff up to 5 minutes (presence brings the friend back sooner); candidates travel inside the offer / answer (a candidate pool gathers them while the handshake crosses the server); idle links kept 5 minutes. A cold connection went from 9 signals to 5. | `FreeTierBudgetTests` (budgets per everyday action) |
| A25 | 🟠 | Free tier | Signals were JSON with base64 key material inside, padded to 1/4/12/16 KiB: an ack or offer of 7–8 KiB travelled as 16 KiB. A cold connection moved ≈ 49 KB through the server (egress: 5 GB a month free). | Binary encoding (JSON still accepted) and 2 KiB padding steps up to 8 KiB. An eavesdropper still sees only 4 distinct sizes. Builds from before 26 Sept 2026 read only JSON, so they can't connect to newer ones: irrelevant before launch, but every TestFlight tester must update. | `FreeTierBudgetTests` (bytes), `WireSecurityTests` (eavesdropper) |
| A26 | 🔴 | App Store | No way to block or report anyone, no terms: rejection under guideline 1.2. | Block (requests, messages, calls, invites dropped; group posts hidden; survives renames via the identity key), Report (email with only what the reporter includes), terms at sign-up, bundled Terms/Privacy, `scripts/moderate.py`. | `SafetyTests` (5, two live) |
| A27 | 🟠 | Resilience | After a server restart every phone reconnects at once and would announce itself and retry every friend in the same second: above the project's 100 messages/s, which disconnects everyone. | Reconnect presence spread over 20 s, retries over 4 s (the first connect after unlock stays immediate). | code review |
| A28 | 🟡 | Password | (A20) Changing the password needed only Face ID. | Needs the current password too; wrong guesses count toward the lockout. | UI check |
| A29 | 🟡 | UX | The welcome tagline was truncated ("Private by design....") once the terms line was added; on a 4.7" iPhone SE the actions fell below the fold. | Adaptive layout: compact mark and one-line features on short screens, scrolling as a last resort. | Air + SE screenshots |
| A30 | 🟡 | UX | Blocking or removing a friend from the profile sheet left their chat open behind it. | The chat closes when the friendship ends. | code review |
| A32 | ⚪ | Blocking | A blocked person who still has you as a friend can learn your new username if you *sign back in* under a new name: the rename announcement key is per account, not per friend. (Restoring a backup doesn't tell them: moves go only to people you haven't blocked.) | Logged; per-friend announce keys would fix it (protocol change). | - |
| A33 | 🟠 perf | Cold start | Every new connection took four trips through the server (hello, ack, offer, answer): about 1 RTT each to the Supabase region. | **Three-trip handshake**: the responder's SDP offer rides in the ack under an early key (pair root + the initiator's fresh encapsulation; forward secret, replay-proof); the initiator answers with its key share. Older builds keep four trips (negotiated in the hello). Cold first message 1.33 s → **1.12 s** median here (India → Ohio). | `HandshakeJourneyTests` (three trips, mixed versions, calls), `CryptoTests` (early key bound to root and handshake; old signals decode) |
| A34 | 🟡 | Free tier | WebRTC re-announces pooled candidates after the description is set, with different trailing attributes, so "already sent" didn't match and every connection spent an extra signal on duplicates. | Candidates compared by the fields that identify them. A new connection: **4 signals** either way (was 5). | `HandshakeJourneyTests`, `FreeTierBudgetTests` |
| A35 | ⚪ perf | Files | File transfers measured at 4–8 MB/s on the simulator. | Profiled: encryption 56 ms, receive callbacks 72 ms and disk writes 14 ms of a 1.5 s 12 MB transfer, the rest is WebRTC's SCTP transport (both test phones share one network thread). No app-side bottleneck; nothing changed. | `PerformanceJourneyTests` |
| A36 | 🔴 | Calls | The iPhone's audio session is shared by every call, and any link that stopped its media switched it off, so a group **host losing one member's connection went silent for everyone still in the call** (and a stale link closing could mute a new call). | Audio session claimed per owner (a call's link, a hosted group call) and switched off only when the last one lets go. Verified: with the old code the host sends 0 packets after a member drops. | `GroupCallE2ETests.testAMemberDroppingDoesntSilenceTheCallForTheOthers`, `…testTheAudioSessionStaysOnWhileAnyCallNeedsIt`; microphone released after 1:1, group, leave/rejoin and video calls |
| A37 | 🟡 perf | Messaging | Opening a chat started connecting only at the next scheduler tick (≤ 1.5 s later). | Connects as soon as the chat opens (keeping the retry backoff): the first message after opening a chat arrives in **33 ms** instead of ≈ 1.1 s. | `HandshakeJourneyTests.testOpeningAChatWarmsTheConnectionBeforeTheFirstMessage` |
| A31 | 🟡 | Cold start | Candidate gathering started only after the handshake: waiting for it inside the offer added ≈ 0.4 s. | Peer connection created at handshake start (candidate pool); keys installed when they arrive. Cold first message 1.4 s → **1.3 s**. | `PerformanceJourneyTests` |

**Third pass (26 Sept 2026, later):** full suite 172 tests, 161 passed, 10 opt-in skipped, 1 transient (a TLS error
from a Tor exit relay fetching a website; passes on rerun). The Tor call-audio flake of the second pass is gone: it was
A36 (another test's link closing switched the shared audio session off mid-call). Release device build clean.

**Second-pass test run (26 Sept 2026):** full suite 166 tests, 155 passed, 10 opt-in skipped, 1 timing flake (the
Tor journey wants ≥ 150 audio packets within 20 s; under full-suite load it saw 114, alone it passes). Stress (opt-in):
61 phones online, a hub holding 60 connections, a 41-member group fanning out 8,200 deliveries: all pass. Capacity
(opt-in): 180–240 sockets online, signals delivered in ≈ 0.3 s. Release device build: no warnings in Priva's sources,
no debug hooks in the binary.

## Latency and memory (iPhone Air simulator on a Mac; a phone is ≈ 2–3× slower on CPU-bound work)

| Journey | Before | After |
|---|---|---|
| Unlock → chat list, main-thread work (2-year account: 60 chats × 500 messages, 3 hosted groups × 5,000) | ≈ 700 ms (1,097 ms raw, incl. a one-time hash a phone reads from its vault) | **19 ms** |
| Disappearing-message sweep (every 10 s) | 212 ms | **0.02 ms** |
| Group "who needs a connection" (every 1.5 s) | 7.8 ms | **0.25 ms** |
| Hourly 90-day group media check | 111 ms | **0.03 ms** |
| Lock/unlock × 15: realtime client released | ✗ leaked | ✓ released |
| Lock/unlock × 15: memory growth | 23.6 MB | **0.03 MB** |
| 8 video + group calls after warm-up: heap in use | - | **+0.7 MB** (every camera source and call pipeline released; host link stays at 5 media sections) |
| Day in the life, 3 phones (300 1:1 messages, 150 group posts, photos, a video call, a group call, a lock/unlock): heap in use | - | **+2.7 MB** |
| 12 connections + 4 calls: every link released | ✓ | ✓ |
| First message, no connection yet (PQ handshake + ICE + DTLS) | 1.4 s | 1.4 s → **1.3 s** (second pass: candidates in the offer, binary signals) |
| Warm round trip (p50 / p95) | 28 / 29 ms | same |
| 300-message burst | 1,441 msg/s | same |
| Group post fan-out, 4 phones (p50) | 28 ms | same |
| 1:1 call: accept → audio | 280 ms | same |
| Group voice call: start → all 4 in | 220 ms | same |
| 12 MB file | 4.3 MB/s | same |
| Day in the life: 1:1 delivery under mixed load (p50) | - | 27 ms |
| Day in the life: three photos sent at once (1:1, 1:1, group) | - | 0.66 s |
| Day in the life: unlock → 20 waiting messages received | - | 3.0 s |

The network paths were already fast; the wins were all in local work that grew with the size of the account.
Cold connection time is dominated by four rendezvous hops through the server (≈ 150–300 ms each on real networks).
Resident memory on the simulator swings by hundreds of MB during video calls (pixel buffers the OS reclaims
lazily, three phones' codecs in one process); leaks are judged by heap in use and by counting live objects.
One run of the day journey saw a 61 s photo delay that six further attempts didn't reproduce; session-close
reasons are now recorded (`Diagnostics.linkCloses`) so a repeat can be traced.

## System design review

* **Trust boundaries are right.** The server holds a username *commitment*, public keys and a purchase HMAC; it
  relays sealed, padded signals it can't read; tokens are blind-signed; usernames never leave the phone in clear.
* **Two separate services, each a single point of failure for its job.** Rendezvous is Priva's Cloudflare relay
  (`rendezvous/`; only buyers with a daily blind-signed pass get in, and only a topic's owner can listen); the
  directory and the pass issuer are on Supabase. If the relay is down, existing peer links keep working until they
  idle out (5 minutes) and nothing new connects. If Supabase is down, lookups and registration stop, but phones
  holding passes (up to 35 days) keep connecting. Watch the free plan's daily request limit (FREE_TIER_CAPACITY).
* **Reachability is the weakest part** (L1, L2 above): P2P without relay and without background delivery works
  well when both people are online and on friendly networks, and not otherwise.
* **Groups depend on one phone.** The host stores, orders and relays every post and file; failover to successors
  exists, but a host on cellular carries N× the upload for media. Group calls are a star through the host (≤ 8
  voice / 4 video), which is the right limit for a phone.
* **Local storage scales now.** Recurring work reads indexes (unread, expires, media, queue keys) instead of
  decrypting threads; unlock does constant work regardless of history size.
* **Hot paths stay off the main thread** where they can (scrypt, file crypto, chunk writes, backup, restore); the
  database still runs synchronously from the main thread: fine at these sizes, worth moving if chats reach
  hundreds of thousands of messages.

## Cleanup

38 outdated, unreferenced screenshots (23 MB, from before the new start screen) were removed from `docs/`; they
remain in git history. Removed dead code (`Store.lastMessages`, `Store.pending(forKey:)`, `PeerLink.touch`, `PeerLink.outboundStreams`,
`TransferRegistry.isActive`, `Theme.mono`, the legacy `NetworkPrivacy(onion:)` initialiser, a duplicated doc
comment); the simulator's synthetic camera is no longer compiled into release builds; message rows are written in
exactly one place (`Store.insert`); the Release binary was checked for debug strings (none).

## Tests added

* `ProductionHardeningTests` (10): one per hole above, fail-closed username hash, Keychain replace-in-place,
  erase coverage, file-request flood, future-dated messages, crafted sizes / backup costs, wrong phone clock,
  damaged rows, and a live malicious group host reaching outside its group.
* `PerformanceJourneyTests` (7): heavy-account unlock and scheduler budgets, lock/unlock leaks, cold / warm /
  burst / file latency, group post fan-out and call setup, connection + call leaks, repeated-call memory, and the
  three-phone day in the life.

* `SafetyTests` (5), `FreeTierBudgetTests` (1, with bytes), `FreeTierCapacityTests` (opt-in, 180 sockets),
  `RelayTests` (3), `ReviewBuddy` (opt-in: the buddy itself and a check that it answers).

## Sources

* TURN usage in practice: https://bloggeek.me/webrtcglossary/turn/ · https://celloip.com/blog/webrtc-turn-server-production-guide/
* Carrier-grade NAT behaviour: https://www.forasoft.com/learn/video-streaming/articles-streaming/nat-stun-turn-ice-webrtc
* Cloudflare Durable Objects / Workers pricing and limits: https://developers.cloudflare.com/durable-objects/platform/pricing/ · https://developers.cloudflare.com/workers/platform/pricing/ · Supabase free-project pausing: https://supabase.com/docs/guides/platform/free-project-pausing
* Cloudflare Realtime TURN (1,000 GB free, short-lived credentials): https://developers.cloudflare.com/realtime/turn/generate-credentials/ · https://developers.cloudflare.com/realtime/sfu/pricing
* App Store age-rating questionnaire (messaging, blocking, reporting): https://developer.apple.com/news/?id=tlur8uvi
* Encryption export rules (§740.17(b)(1), annual self-classification): https://www.bis.gov/learn-support/encryption-controls/annual-self-classification
