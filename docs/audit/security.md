# Priva: security & privacy audit (October 2026)

Scope: every file under `Priva/` (Core, App, Features, DesignSystem), `supabase/functions/*`, `supabase/migrations/*`,
`rendezvous/src/index.ts` + `wrangler.jsonc`, `Info.plist`, entitlements, privacy manifest, `project.yml`, `scripts/`,
and the design/verification docs. Method: line-by-line reading and end-to-end tracing of each code path. Nothing was
built, run, deployed or called. Confidence levels: **Confirmed** (code path traced end to end, outcome follows from
the code alone), **Likely** (traced, but the outcome depends on runtime/platform behaviour I couldn't execute),
**Possible** (plausible, needs a test to settle).

Items the docs already list as fixed or accepted (A1–A36, device-journey fixes 1–20, `allow_dev_purchases`, first-contact
TOFU, "host can read group content") are not repeated unless the fix is incomplete or the documented guarantee is wrong.

---

## Summary

| Severity | Count |
|---|---|
| Critical | 0 |
| High | 5 |
| Medium | 8 |
| Low | 11 |
| Info | 4 |
| **Total** | **28** |

The cryptography itself is in good shape: DualAEAD, DualSeal, the session handshake, FrameCipher, FileCipher and
the backup container are correctly built, nonces are unique per key, transcripts are length-prefixed and
domain-separated, and parsers are bounded. The serious problems are in **metadata and protocol logic around the
crypto**: what the servers can link, what a group host or ex-member can switch on or see, and what one leaked secret
lets an attacker do without anyone noticing.

**Top 5 risks**

1. **SEC-01: A group host can switch on a member's microphone/camera without consent.** A member's group-call
   request that times out leaves `acceptedMedia` set on the link to the host. Any later SDP offer from the host
   starts the member's capture, with no call screen showing.
2. **SEC-02: The server can link a purchase to a username.** This breaks the owner's "no correlation" rule. The app
   sends the App Store JWS to `relay-pass` seconds after `register`, and again every month in the same session (same
   IP, or the same Tor circuit) as identity-bearing directory calls. Postgres row versions (`xmin`) also order the two
   writes.
3. **SEC-03: The relay can see the whole social graph.** One daily pass goes on every socket and every send. Since
   inbox topics never change, the Cloudflare relay can link all of a phone's topics, everyone it signals and its old
   and new identity after a move. The Privacy Policy says the opposite.
4. **SEC-04: The 24-word recovery phrase on its own lets an attacker take over every friendship silently.**
   `MoveProof` needs only the old identity key, which the phrase gives. Friends then follow automatically
   (`accept(silent: true)`). Showing the phrase needs only Face ID, not the password.
5. **SEC-05: The `turn` function is open to anyone.** It hands Cloudflare TURN credentials to anyone holding the
   publishable key shipped in the app: no pass, no purchase, no rate limit. That makes it a free relay for the
   internet, billed to the owner, and a way to drain quotas.

---

## Findings

### SEC-01 · High · Calls / consent: stale `acceptedMedia` lets a group host covertly start a member's mic/camera

**Where:** `Priva/Core/Groups/GroupCallCenter.swift:134-149` (member `start` sets `link(g.host)?.acceptedMedia = video`),
`:144-148` (30 s timeout → `finish`), `:196-204` (`decline` → `finish`), `:395-403` (`linkReady` sets `acceptedMedia` again),
`:416-438` (`finish` never calls `link.stopMedia()`); `Priva/Core/P2P/PeerLink.swift:739-748` (`handleRenegotiation`:
`if let video = acceptedMedia, !mediaActive { startMedia(video:) }`), `:843-872` (`stopMedia` is the only place that
clears `acceptedMedia`).

**What's wrong:** a member who taps "Group voice/video call" marks its link to the host as consented. If the host
doesn't answer, the 30-second timeout ends the call in the UI (`finish("The host didn't answer")`), but nothing clears
`acceptedMedia` on the link. The link stays up as long as group traffic keeps `lastActivity` fresh, and a
host can keep it fresh by sending pings. Any `.sdp(type:"offer")` that arrives later on the encrypted data channel
runs `startMedia`, which configures the audio session, enables audio, attaches mic and camera tracks and streams
them to the host. No call screen is shown and the user gets no prompt; only the iOS orange/green indicator gives it away.

**Exploit:** a malicious host (a modified client) ignores a member's call request. Some time later it sends a
renegotiation offer with sendrecv audio/video m-lines. The member's phone sends mic (and camera, if the request was
video) to the host. This is the 🔴 "caller forces callee to transmit" class that SECURITY_RESEARCH §2 says Priva is not
vulnerable to.

**Fix:** clear `acceptedMedia`/`groupMedia` on the link in every member-side `finish`/`decline`/timeout path (call
`link(c.host)?.stopMedia()` or a new `revokeMediaConsent()`). Also bind consent to the call: give `acceptedMedia` a
call ID and an expiry, and have `handleRenegotiation` start capture only while the matching `GroupCallCenter`/`CallCenter`
call is `.active` (or `.connecting` for 1:1).

**Test:** `GroupCallE2ETests.testATimedOutCallRequestNeverLetsTheHostStartTheMembersMic`. The member requests a call,
the host ignores it for 31 s, then the host sends a raw `.sdp` offer through `sendRaw`. Assert the member sends 0
RTP packets, `mediaActive == false` and `audioOwners == 0`. Repeat for member decline and for the `linkReady` path.

**Confidence:** Confirmed.

---

### SEC-02 · High · Unlinkability (hard constraint): purchase ↔ username correlation through relay-pass refills, Tor circuit sharing and DB row ordering

**Where:** `Priva/Core/Network/RelayPass.swift:27-36, 55-88` (refill sends the JWS, and the freshly minted pass is used at once);
`Priva/Core/Network/API.swift:251-260`; `Priva/Core/Network/Realtime.swift:125-133`;
`Priva/Features/Onboarding/OnboardingViews.swift:385-394` → `AppModel.finishRegistration` → `PrivaEngine.start`
(`PrivaEngine.swift:190`); `PrivaEngine.swift:1241-1257` (each unlock looks up the user's own ucommit and renews it,
4–40 s after start); `AppModel.swift:384-389` (`token_spent` → a new token → register within ~1 s);
`Priva/Core/Network/TorService.swift:69-72` + `NetworkPrivacy.swift:87-92` (one SOCKS port, no isolation flags, no
per-request SOCKS credentials); `supabase/functions/_shared/purchase.ts:13-34`;
`supabase/migrations/20261002000002_relay_passes.sql:7-23` (UPDATE on `purchases`) and `svc_register` (INSERT into
`directory`).

**What's wrong:** blind signatures only protect the *cryptographic* link. Three channels re-link the identities:

1. **Timing and IP at sign-up.** `register(ucommit, bundle, revoke_hash)` is followed seconds later, on the same IP,
   by `relay-pass {jws}`. On sign-up `engine.start()` → `realtime.connect()` → `RelayPass.header()` → `refill()` →
   `PurchaseService.proof()`. The design's mitigation ("human-scale delay between the two calls") applies only between
   `issue-token` and `register`. The relay-pass call re-proves the purchase right after registration.
2. **Every month.** A refill happens when fewer than 7 passes remain, inside a normal session. That session also
   does `lookup_directory(own ucommit)` (every unlock) and `directory renew {ucommit, sig}` (weekly), from the same IP.
   The edge functions see the ucommit in plaintext. So the link renews every month, not once in an account's life.
3. **Tor doesn't help.** All of Priva's streams share one SOCKS port with no `IsolateSOCKSAuth` credentials or
   `IsolateDestAddr`. The JWS call, `register`/`renew` and the relay connections leave from the same exit within
   Tor's 10-minute circuit lifetime. `register()`'s "new URLSession" does not get a new circuit.
4. **The database alone, without logs.** Postgres keeps `xmin` (transaction IDs) on every row. The `purchases` row
   updated by `svc_authorize_relay`/`svc_authorize_issue` and the `directory` row inserted by `svc_register` carry
   adjacent xids at low traffic. A dump or backup therefore orders, and usually pairs, purchase refs with ucommits.
   This defeats the "no timestamps" minimisation.

**Exploit:** anyone holding Supabase logs (the owner, a breach, a subpoena) matches the `relay-pass` request that
follows each `register`/`renew` from the same IP or Tor exit. That joins `purchase_ref = HMAC(pepper, appTransactionID)`
to the `ucommit`. With the pepper (same database) and Apple's knowledge of who owns an appTransactionID, this names the
person behind a username, which is exactly what R10/U1 forbid.

**Fix:**
- Decouple passes from identity activity. Fetch passes at random times far from `register`/`renew` (hours, not
  seconds), never in the same session as an identity-bearing call. Never use a pass on the day it was minted.
- Bundle the initial month of passes into the registration-token flow: same request as `issue-token`, before the
  username exists, with the existing human-scale delay.
- In Tor mode, use a fresh random SOCKS username/password per request class (purchase, directory, relay) so Tor
  isolates circuits (`IsolateSOCKSAuth` is on by default); in proxy mode, document the limit.
- Move purchase-bearing calls behind an OHTTP relay operated by a third party (already noted as phase 2 in
  IDENTITY_DESIGN §9; this finding makes it a launch item).
- To break DB row ordering, batch purchase-counter updates through a delayed queue, or recreate the `purchases` row
  (DELETE+INSERT at a random later time). At minimum, document `xmin` as a residual risk.

**Test:** `UnlinkabilityTests.testNoPurchaseProofWithinMinutesOfAnIdentityCall`. Use WireTap to record every HTTPS call
with timestamps across sign-up, 10 unlocks and a forced refill. Assert no `relay-pass`/`issue-token` request falls
within N minutes (e.g. 30) of `register`, `renew` or `lookup_directory(own)`. A Tor variant asserts different SOCKS
credentials for each class.

**Confidence:** Confirmed for timing and IP adjacency (code path); Likely for log availability and `xmin` adjacency
(platform behaviour).

---

### SEC-03 · High · Relay metadata: one daily pass and static inbox topics give the relay the social graph and link old ↔ new identities

**Where:** `Priva/Core/Network/Realtime.swift:129, 143` (the same `Authorization: Pass` on every topic socket);
`API.swift:268-279` (the same pass on every send); `RelayPass.swift:29-32, 52`; `rendezvous/src/index.ts:155, 163`
(the relay even computes `hexDigest(pass)` per request); `Priva/Core/Crypto/Identity.swift:38-40` (one inbox topic per
identity, used by every friend); `PrivaEngine.swift:679-697` (presence fan-out to up to 60 inbox topics at unlock);
`PrivaEngine.swift:1290-1298` (a returning device broadcasts every 60 s to the old identity's announce and inbox
topics); `Priva/Resources/Legal/Privacy.md:20, 25`.

**What's wrong:** `ListenKey` derives a separate key per topic "so the relay can't link one phone's topics". But
every WebSocket (inbox, request topic, announce topics of gone friends) and every `/send` carries today's identical
pass. The relay therefore links, per day, the topics a phone listens on and the inbox topics it signals. Inbox topics
never change for the life of an identity, so the daily graphs stitch together into a long-term friend graph. The
request topic `r-…` can be computed from a username, so anyone who knows one username (a friend, the review buddy, a
reported user) maps it to an inbox topic and then to that user's whole graph. After a restore or sign-back-in, the
new phone listens on its new topics while sending to the old inbox and announce topics every 60 s, under one pass.
The relay links the old and new identities, which the move design tries to prevent at Supabase. In Tor mode, where
the IP no longer links anything, the pass is the identifier. `Privacy.md` says inboxes "can't be linked to each other
or to you".

**Exploit:** a curious or compromised Cloudflare account logs `(hexDigest(pass), topic, event, time)` in the Worker
(observability is off, but code can change, and Cloudflare itself sees requests). Grouping by pass gives
`listen{i-A, r-A}` + `send{i-B, i-C, …}` every day. Joining across days on the stable `i-*` gives the friend graph and
contact frequency, plus online times from the presence bursts.

**Fix:**
- Use single-use or short-lived tokens: one blind-signed token per socket and per send batch (Privacy Pass style,
  with redemption tracking in the DO), or at least per socket/topic and refreshed hourly.
- Move to pairwise, rotating inbox topics: `topic = HKDF(pair root, "inbox" ‖ epoch/day)`, so each friend reaches
  you on a different topic that changes over time and the fan-in isn't one topic.
- Stop rebroadcasting from the new identity's network context to the old identity's topics, or do it from a
  different pass and circuit at random times.
- Correct the Privacy Policy now.

**Test:** `RelayMetadataTests.testOnePhonesTopicsAreNotLinkableByPass`. Record all relay requests for one phone over a
session. Assert no credential value appears on more than one topic (or more than k requests).
`testAMoveIsNotLinkableAtTheRelay`: no single credential is used both for listening on new topics and for sending to
old ones.

**Confidence:** Confirmed.

---

### SEC-04 · High · Account takeover: the recovery phrase alone is enough to silently move every friend to an attacker's username

**Where:** `PrivaEngine.swift:880-895` (move check against the pinned old key only), `:913-919`
(`try? accept(req, silent: true)`), `:1008-1031` (`finishMove` moves the conversation, nickname, timer and groups,
then deletes the old contact); `Priva/Core/Crypto/Identity.swift:288-313` (`MoveProof` signed by the identity key
derived from the seed); `Identity.swift:47` (the revocation secret also comes from the seed);
`Priva/Features/Settings/SettingsViews.swift:398-403` (the phrase is shown after `BiometricGate.confirm`, no password);
`GroupHub.swift:777-797` (group roles follow the move).

**What's wrong:** BACKUP_DESIGN presents automatic friend-following as protected by three factors (Backup Key +
password + iCloud Keychain). In code, a valid `MoveProof` only needs the old identity's signing keys, which come
straight from the 24-word recovery phrase (or a `.privakey` file plus its password). A modified client holding the
phrase can sign a move for every friend, which it learns from… nothing the attacker needs: friends' usernames are in
the victim's chats, or they can be guessed from groups. Friends then:
- accept silently and re-key;
- delete the old contact;
- move the history;
- transfer group host/admin roles.

The real owner gets no notice, because only an honest client sends the old-inbox notice. The owner's later
legitimate move is then flagged as the "second restore" conflict, so the owner looks like the attacker. The same
phrase also revokes the owner's username (`revokeSecret`).

**Exploit:** shoulder-surf or phish the phrase (the "Priva support" phishing pattern), or briefly take an unlocked
phone that the owner opens with Face ID → Settings › Recovery phrase. Register any username with your own purchase.
Send `moved` friend requests to all of the victim's friends. Every friend's chat now talks to the attacker.

**Fix:**
- Don't auto-follow. Show "@old says they moved to @new" with Accept/Decline (at least when the friend has verified
  keys).
- Or require a second proof that the phrase alone can't produce: a key from the Backup Key, or a signature by the
  old *device*, or require that the old username is already revoked or retired in the directory *and* wait N hours
  while the old inbox is notified, letting the old phone object (a signed "I did not move").
- Require the password, not just Face ID, to reveal the phrase.

**Test:** `RestoreSecurityTests.testAPhraseOnlyAttackerCannotSilentlyMoveFriends`. Derive the identity from a phrase,
forge `MoveProof`s from a fresh account and send them. Assert the friends' contacts for @old are unchanged and only a
prompt (an `IncomingRequest` with `movedFrom` pending) exists.

**Confidence:** Confirmed.

---

### SEC-05 · High · Server abuse: the `turn` function mints Cloudflare TURN credentials for anyone

**Where:** `supabase/functions/turn/index.ts:12-29`; `Priva/Core/Network/API.swift:79-89`; `WebRTCEnv.swift:204-210`;
`scripts/launch_check.sh` (calls it with only the `apikey` header).

**What's wrong:** the function takes no relay pass, no purchase proof and no rate limit. It returns 6-hour
TURN/TURNS credentials from the owner's Cloudflare Realtime key to anyone holding the publishable key, which ships in
every IPA and is readable with `strings`.

**Exploit:** a script hits `POST /functions/v1/turn` with the publishable key in a loop. It gets unlimited
credentials and uses Cloudflare TURN as an anonymous relay for arbitrary UDP/TCP traffic: 1,000 GB free, then
metered to the owner. It also burns the Supabase free-tier function quota (500k/month), which takes down `issue-token`,
`register`, `directory` and `relay-pass` for everyone. The abuse is attributed to the owner's account. This also
violates "only the app should be able to connect".

**Fix:**
- Require a valid relay pass (verify RSA-PSS against `relay_sk_v1` in the function, or mint TURN credentials in the
  Worker, which already verifies passes).
- Rate-limit per pass and per IP.
- Shorten the TTL to about 1 h.
- Optionally set Cloudflare TURN key limits and alerts.

**Test:** `ServerSurfaceSecurityTests.testTURNCredentialsNeedAPassAndAreRateLimited`. Without a pass → 401. With a pass,
the 31st request in a minute → 429.

**Confidence:** Confirmed.

---

### SEC-06 · Medium · Relay quotas: the pass "day" is chosen by the client, multiplying per-pass limits; send fan-out and DO creation amplify cost

**Where:** `RelayPass.swift:71-75` (the client puts the day inside the blinded token); `supabase/functions/relay-pass/index.ts:14-43`
(only a monthly count of 160); `rendezvous/src/index.ts:64-78` (accepts `|day − today| ≤ 1`), `:155, :163` (300/min
per pass), `:177` (one DO call per message, 64 per request), `:93` (the DO constructor writes SQLite storage for
every topic it's instantiated for).

**What's wrong:**
- The server signs blinded tokens and cannot see the day. A buyer can request all 160 monthly passes for the same
  day, so 160 passes are valid at once, each with its own 300/min budget (48,000 requests/min) and each spread across
  IPs to dodge the 600/min per-IP limit.
- Every `/send` fans out to 64 Durable Object invocations.
- Sending to a random valid-looking topic instantiates a new DO whose constructor creates a table, leaving
  persistent storage behind.

**Exploit:** one purchase (or one leaked JWS, see SEC-07) exhausts the free plan's 100k requests/day, and DO request
quotas, within minutes: relay-wide denial of service. Flooding random topics fills DO storage.

**Fix:**
- Enforce one pass per day per purchase: issue passes in a per-day batch and use per-day signing keys (key ID =
  day), so a pass's day is bound by the key, not the client.
- Count `/send` messages (not requests) against the pass limit.
- Create the `owner` table lazily, only on a successful listen.
- Reject sends to topics with no owner, without instantiating storage (or use a cheap in-memory presence map).

**Test:** `RelaySecurityTests.testPassesForTheSameDayCannotBeStacked` (40 passes for today from one purchase → the
relay refuses all but one). `testSendsToUnownedTopicsLeaveNoStorage`.

**Confidence:** Confirmed (protocol); impact Likely.

---

### SEC-07 · Medium · "Only the app can connect": no app attestation; the AppTransaction JWS is a reusable bearer credential

**Where:** `supabase/functions/_shared/apple.ts:21-71` (no `deviceVerification`/`deviceVerificationNonce` check, no
freshness); `purchase.ts:13-34`; `PurchaseService.swift:24-30`; entitlements (no App Attest);
`rendezvous/src/index.ts:65-78` (passes are bearer tokens).

**What's wrong:** the server accepts any valid AppTransaction JWS, forever and from anywhere. The JWS has no nonce
binding and the server doesn't verify `deviceVerification` against a server nonce. A buyer, or anyone who copies a
buyer's JWS (Mac running the iOS app, jailbroken phone, proxy on their own device), can run a custom client that
gets registration tokens (3/month, 10/year) and 160 relay passes a month, and share them. Passes are bearer
tokens valid for three days, so they can be published for non-buyers. Nothing proves the request comes from the
genuine Priva binary.

**Fix:**
- Add DCAppAttest: attest at registration and pass issuance, and assert on relay-pass requests (store attestation
  key hashes per purchase_ref, which needs a privacy review).
- Have the client set `AppTransaction`'s device-verification nonce from a server challenge, and have the server
  verify `deviceVerification` (SHA-384 of nonce ‖ identifierForVendor isn't checkable server-side, so pair it with App
  Attest).
- Bind passes to a key held in the Secure Enclave (the pass signs a per-request challenge).

**Test:** `ServerSurfaceSecurityTests.testAReplayedJWSFromAnotherDeviceIsRefused` (same JWS, a new App Attest key →
403).

**Confidence:** Confirmed.

---

### SEC-08 · Medium · Protocol replay: a replayed friend request (≤ 30 days old) silently re-pairs an existing friend and breaks the friendship; declined requests come back

**Where:** `PrivaEngine.swift:707-708` + `:1755-1765` (replay cache only in memory, 10 min);
`FriendProtocol.swift:88-89` (30-day acceptance window); `PrivaEngine.swift:899-940` (after acceptance the incoming
request is deleted, so `contains(rid)` misses, and an existing contact with the same bundle → `accept(req, silent: true)`);
`:964-972` (`c.pair = pair`, a brand-new root; `PairSecrets.establish` sets `previous = nil`, `Protocol.swift:37-47`);
`FriendProtocol.swift:117-121` (the original requester rejects the acceptance because its outgoing request is gone).

**What's wrong:** an attacker who can capture and re-inject an `r-` topic envelope (the relay operator) replays a
friend request that was accepted within the last 30 days. The victim treats it as "a friend re-sending a request with
the same keys" and silently re-pairs, overwriting the pair root with no previous root kept. The friend can't open the
acceptance, so the two sides now hold different roots and every later signal fails both ways, permanently and
silently. Replaying a request the user declined brings it back. `WireSecurityTests` replays only a *pending* request,
so this case isn't covered.

**Fix:**
- Persist the RIDs of accepted, declined and deleted requests (bounded, for 30 days) and drop replays.
- On a same-keys re-request, keep the old root as `previous` (`PairSecrets(current: new, previous: old)`) and only
  switch once the friend proves the new root.
- Shrink the request timestamp window for requests from existing friends.

**Test:** `WireSecurityTests.testReplayingAnAcceptedFriendRequestChangesNothing`. Befriend, capture the `r` envelope,
replay it after a restart. Assert `pair.current` is unchanged and messaging still works. Do the same for a declined
request (assert no new `IncomingRequest`).

**Confidence:** Likely (traced end to end; not executed).

---

### SEC-09 · Medium · Groups: failover can be hijacked with stale charters and a purely local 72-hour silence; honest successors auto-claim

**Where:** `GroupHub.swift:531-542` (`checkFailover` claims whenever the *local* `hostGone`, run on the first tick
after unlock), `:553-557` (`hostGone` = `lastSeen` older than 72 h), `:559-574` (`claim` removes the host from the
roster), `:576-598` (`acceptHandover`: `previous` may be any charter the host ever signed that lists the claimant;
if the member's own view says the host is quiet for 72 h it skips the directory check).

**What's wrong:**
- A member who was once a successor (a demoted admin, or one of the "two longest-standing members" at the time)
  keeps an old signed charter that lists them. Demotion never revokes it.
- Members accept such a claim without a directory check whenever they haven't heard from the host for 72 h, which
  is common because iOS suspends apps. They then delete the real host from their roster.
- Even honest successors who open Priva after 3+ days away find `lastSeen(host)` older than 72 h and claim at once,
  before the host's presence can arrive. That splits the group.

**Exploit:** a demoted admin waits for a quiet weekend, sends `.handover(previous: oldCharter, next: myClaim)` to
members, and the members who were also away follow. The real host is evicted (GROUPS_DESIGN §6.2 says this needs
"uninstalled/removed").

**Fix:**
- Accept `previous` only if it equals the member's latest stored charter (same epoch and signature).
- Always do the live directory check (never the 72 h shortcut) before accepting a claim.
- On the successor side, require a fresh directory check and a failed contact attempt before claiming.
- Re-sign the charter (new epoch) on demotion and reject charters older than the stored epoch.

**Test:** `GroupEndToEndTests.testADemotedAdminCannotClaimWithAnOldCharter`;
`testASuccessorBackFromThreeDaysAwayDoesNotClaimALiveHost` (set `lastSeen` to −4 days, unlock, assert no `.handover`
is sent while the host's directory entry is active).

**Confidence:** Confirmed.

---

### SEC-10 · Medium · Groups privacy: `.sync(since: 0)` gives any new member the group's history (up to 500 posts plus media)

**Where:** `GroupHub.swift:724-729` (`.sync`: the host enqueues every message with `seq > since` for any current
member); `:640-641` (policy: "No history for new members"); `:365-368` (`servesFile` serves any group file to any
member).

**What's wrong:** the host never checks `since` against the member's join point. A freshly invited member sends
`.sync(groupID, since: 0)` and receives the last 500 posts, including attachment keys, and can download the files.

**Fix:** record each member's join `seq` on the host and clamp `since` to it. Apply the same floor in `servesFile`
(only files posted after the member's join).

**Test:** `GroupFeatureE2ETests.testANewMemberCannotSyncHistoryFromBeforeTheyJoined` (post 5, invite Carol, Carol sends
`.sync(since: 0)`; assert Carol receives 0 old posts and `fileWant` for an old file gets no chunks).

**Confidence:** Confirmed.

---

### SEC-11 · Medium · Groups privacy: hidden successor links let non-friends silently learn members' IP and presence, forever

**Where:** `GroupHub.swift:496-509` (`issueLinks`: every successor gets a root and inbox to every member);
`GroupModels.swift:57-62` (successors = all admins **plus the two longest-standing members**);
`PrivaEngine.swift:471-477` (`installGroupLink`); `:767-783` (`acceptHello` answers a hello from any contact,
group-only included, with a PeerConnection whose SDP carries host/srflx candidates); `:683-687` (presence goes to
group-only contacts too); `Models.swift:213` (`relayCalls = false` by default); no code ever deletes `groupOnly`
contacts on removal, leave or group end (grep).

**What's wrong:** GROUPS_DESIGN §2 says "Members do not learn each other's IP addresses: they only connect to the
host". In code, any early member automatically becomes a successor and gets a link to every member. A link lets them:
- send a hello at any time: the member's phone answers with an SDP offer containing its LAN and public IPs, with no
  user action, since the default ICE policy is `.all`;
- receive the member's presence notes.

Links survive removal, leaving and disbanding, so an ex-member keeps this ability indefinitely.

**Fix:**
- Make successor links dormant. Only answer a group-only contact's hello after a verified handover naming them, and
  only with relay-only ICE.
- Never send presence to group-only contacts.
- Delete group-only contacts (and their pair roots) when the shared group ends, the member is removed or leaves, or
  the successor list changes.
- Consider issuing links only to admins, not auto-successors.

**Test:** `GroupEndToEndTests.testARemovedSuccessorCannotReachMembers` (remove Carol after links are issued; Carol
sends a hello to Bob; assert Bob sends no ack or offer, and `contact(carol) == nil`). `testGroupOnlyContactsGetNoPresence`.

**Confidence:** Confirmed.

---

### SEC-12 · Medium · Resource exhaustion: automatic downloads of up to 8 GiB (1:1) / 2 GiB per post (groups); repeated `fileWant` re-uploads

**Where:** `PrivaEngine.swift:366` (`beginIncoming` for every arriving attachment), `:1510-1516`, `:1563-1571`
(`a.size <= 8 << 30`); `GroupHub.swift:272-283` (the host downloads member uploads up to `2 << 30`), `:694`
(members download every group attachment); `PrivaEngine.swift:1662-1674` + `Transfers.swift:62-64` (each `fileWant`
starts a new full stream; A9 deduplicates within one request, not across requests).

**What's wrong:** there is no user consent, free-space check or cellular policy for incoming files. A malicious
friend fills the victim's storage (which then makes Priva drop messages, per fix 11) and burns their data plan. A
group member can make the host store, and every member download, 2 GB per post, 30 posts per burst. Any peer
(friend, or group member against the host) can send `fileWant` for the same file in a loop and make the victim
upload it again and again.

**Fix:**
- Auto-download only below a size threshold (e.g. 25 MB on cellular, 100 MB on Wi-Fi); otherwise tap to download.
- Check `volumeAvailableCapacityForImportantUsage` before starting.
- Cap per-peer and per-group bytes per day on the host.
- Track one in-flight stream per (peer, fileID) and limit `fileWant` per file (e.g. 3 per hour).

**Test:** `ProductionHardeningTests.testALargeFileFromAFriendIsNotFetchedWithoutConsent`;
`testRepeatedFileWantsDontReuploadTheFile` (100 `fileWant` → at most 1 full stream).

**Confidence:** Confirmed.

---

### SEC-13 · Medium · Directory metadata: automated lookups hand Supabase the social graph (contradicting "lookups only when adding a friend")

**Where:** `PrivaEngine.swift:1262-1277` (`sweepDirectory`: daily lookups of every friend quiet for 48 h, by name →
ucommit), `:871-875` (a lookup for every received friend request), `:1328` (every announcement), `:1248` (own
ucommit at every unlock); `GroupHub.swift:545-551` (failover checks); IDENTITY_DESIGN §9 ("lookups only when adding a
friend").

**What's wrong:** each lookup is `POST rpc/lookup_directory {p_commit}` from the user's IP (or a Tor circuit shared
with their own identity calls, see SEC-02). Supabase and PostgREST logs give "IP/owner of U looked up commitments V, W
every day", which is the friend graph. Lookups on received requests also reveal who sent requests to whom and when.

**Fix:**
- Check liveness peer-to-peer (signed presence) before asking the directory.
- Batch and pad lookups (look up k random dummy commitments alongside).
- Route them through a separate Tor circuit or OHTTP.
- Correct the design doc.

**Test:** `FreeTierBudgetTests` / new `DirectoryPrivacyTests.testIdleFriendsCauseNoDailyLookups` (no `lookup_directory`
for friends who are reachable P2P; dummy padding present when a lookup happens).

**Confidence:** Confirmed.

---

### SEC-14 · Low · Directory metadata: each username's creation day and last-activity week are public

**Where:** `Identity.swift:54-56, 157-174` (`KeyBundle.day = today`, signed into the bundle); `Vault.swift:83`;
`supabase/migrations/20260922000006_metadata_minimisation.sql:52-58` (anonymous `lookup_directory` returns
`lease_week` and the bundle).

**What's wrong:** IDENTITY_DESIGN §4 says "no creation dates anywhere". The bundle stored in the directory, and
returned to anyone who knows the username, carries the day it was created. `lease_week` shows roughly when the owner
last used Priva.

**Fix:** set `day` to 0, or round it to the month, at registration (bundle v3). Return `lease_week` only as
active/uninstalled.

**Test:** `ServerSurfaceSecurityTests.testLookupRevealsNoDates` (bundle day = 0 and no `lease_week` in the anonymous
RPC).

**Confidence:** Confirmed.

---

### SEC-15 · Low · Zero-click parsing: "not backed up" thumbnails bypass `SafeImage`

**Where:** `Priva/Features/Chat/ChatView.swift:386-389` (`UIImage(data: t)`), compared with `SafeImage.thumbnail`
everywhere else.

**What's wrong:** after restoring a text-only backup, attachment thumbnails, which are sender-controlled bytes
stored as received, are decoded with `UIImage(data:)`. It accepts every ImageIO format (WebP, GIF, JBIG2-in-PDF…),
which reopens the FORCEDENTRY/BLASTPASS surface `SafeImage` exists to close.

**Fix:** use `MediaVault.shared.thumbnail(for:)` / `SafeImage.thumbnail`.

**Test:** `AttackSurfaceTests.testNotBackedUpThumbnailsDecodeOnlySafeFormats` (a WebP thumbnail in a text-only
restore → no image).

**Confidence:** Confirmed.

---

### SEC-16 · Low · Secrets at rest: revocation secret and plaintext username live outside the vault key and survive deletion

**Where:** `Vault.swift:49-56` (`RevocationRecord{username, ucommit, secret}` in the Keychain,
`WhenUnlockedThisDeviceOnly`, no access control); `Vault.swift:13-27` (`VaultMeta.username`, `requestTopic` in
plaintext); `AppModel.swift:73-86` (kept across reinstalls); `LockView.swift:32-34` (the locked screen shows
`@username`); `supabase/functions/directory/index.ts:28-36` (`revoke` needs only the secret).

**What's wrong:** anyone who can read Priva's Keychain items (a jailbreak or forensic extraction of an unlocked
device) can delete the user's username from the directory without the password or Face ID, and learns the username.
Anyone who picks up an unlocked iPhone sees the username on Priva's lock screen.

**Fix:** keep the revocation secret encrypted under the vault key and keep only a pointer. Re-derive it from the
seed (phrase) for the "sign back in" case. Drop the username from the lock screen, or show it only after Face ID.

**Test:** `UnitModelTests.testNothingInPlainKeychainCanRevokeTheUsername` (enumerate Priva's Keychain items; assert none
decodes to a 32-byte value whose SHA-256 equals the registered `revoke_hash`).

**Confidence:** Confirmed.

---

### SEC-17 · Low · Network privacy: "Relay calls" fails open, and the TURN operator sees both real IPs in relay and Tor modes

**Where:** `WebRTCEnv.swift:56-59` (`s.relayCalls && relays > 0 ? .relay : .all`); `Models.swift:213` (off by default);
`ManagedRelay` (`WebRTCEnv.swift:193-223`).

**What's wrong:**
- With "Relay calls" on, if TURN credentials can't be fetched (function down, rate-limited, SEC-05 fix not
  deployed), WebRTC silently connects directly and shows the friend your IP. Only Tor mode fails closed.
- When both peers use Cloudflare TURN, the operator (also the relay operator, SEC-03) maps both allocations' client
  IPs to each other. The docs say the relay "sees your IP address but not your friend's".

**Fix:** make "Relay calls" fail closed like onion mode, and show the same "waiting for a relay" note. Document TURN
endpoint-pair visibility; consider letting users bring their own TURN in high-security mode.

**Test:** `OnionModeTests.testRelayCallsNeverConnectsDirectlyWithoutARelay` (relayCalls = true, no servers → ICE policy
`.relay`, and no host/srflx candidates in the SDP).

**Confidence:** Confirmed (fail-open); Likely (TURN visibility).

---

### SEC-18 · Low · Biometric gates: `confirm()` discards the Secure Enclave secret; sensitive actions need only Face ID

**Where:** `BiometricGate.swift:43-46` (`_ = try secret(context:)`); `SettingsViews.swift:276` (delete account / leave),
`:400` (show recovery phrase), `:496` (purchase ID); `BackupViews.swift:682` (restore over the current account, which
also revokes it as "abandoned", `AppModel.swift:154, 163`).

**What's wrong:** fix 13 swapped boolean `evaluatePolicy` for "must unlock the SE key", but the result is thrown away
and the protected value (the seed) is already in memory. A Frida hook on `BiometricGate.confirm` or on the
`!= nil` branch bypasses it as easily as hooking LAContext, so the gate isn't cryptographically binding. Separately,
revealing the seed (SEC-04), deleting the account and restoring over it need only the owner's face, which is
coercible or available while the owner sleeps, and no password.

**Fix:**
- Make reveals binding: re-derive VK from `wrapPassword` with password + bio secret and decrypt `sealedSeed` at
  reveal time.
- Require the password for the phrase reveal, account deletion and restore-over.

**Test:** `FaceIDJourneys` / unit test asserting that `RecoveryPhraseRevealView` needs `Vault.unlock(password:context:)`.

**Confidence:** Confirmed.

---

### SEC-19 · Low · At rest / forensics: plaintext metadata columns, VK never rotated, disappearing messages survive in WAL and backups

**Where:** `Store.swift:36-46, 87-96` (plaintext `ts` (ms), thread hash `h`, `pending/unread/expires/media`; `calls.ts`);
`Store.swift:24-27` (row key = HKDF(VK); VK fixed for the account's life, and a password change only re-wraps it);
`SQLite.swift:16` (WAL + `secure_delete` doesn't scrub WAL frames); `BackupService.swift:351-355` (unexpired
disappearing messages go into backups, and the newest 2 backups are kept indefinitely if backups stop).

**What's wrong:** a file-system extraction of an unlocked device shows per-conversation message and call timelines
without any key. Anyone who later obtains VK (coerced password + face) can still decrypt "disappeared" rows left in
the WAL or flash, and messages a friend set to disappear stay in the iCloud backup.

**Fix:**
- Seal `ts` (keep only a coarse bucket for ordering), or use a keyed order-preserving index.
- `PRAGMA wal_checkpoint(TRUNCATE)` after expiry sweeps.
- Encrypt disappearing messages under per-day keys that are deleted at expiry (crypto-shredding).
- Leave disappearing messages out of backups, or expire their backup copies.

**Test:** `WireSecurityTests.testDisappearedMessagesAreUnrecoverableWithTheVaultKey` (send with a 1 min timer, expire,
then scan `priva.db`, `priva.db-wal` and the latest backup with VK; assert nothing decrypts to the text).

**Confidence:** Confirmed (columns, backups); Likely (WAL remnants).

---

### SEC-20 · Low · Key files: the "Apple Account" factor is not secret

**Where:** `KeyFile.swift:74-77`; `purchase.ts:13-20` (the edge functions see `appTransactionId` in plaintext on every
`issue-token`/`relay-pass`); `SettingsViews.swift:452-516` (shown and copyable).

**What's wrong:** the second factor is an identifier that Apple, Supabase's function runtime and the user's clipboard
all hold. Against the server operator or Apple, a stolen `.privakey` is protected by the password alone (scrypt 2¹⁷).
The docs present it as a strong account binding.

**Fix:** document it honestly, or bind key files to the iCloud Keychain factor (F3) as well.

**Test:** `KeyFileTests.testKeyFileStrengthDoesNotDependOnPurchaseIDSecrecy` (a documentation-style test asserting the KDF
cost alone meets the target).

**Confidence:** Confirmed.

---

### SEC-21 · Low · Metadata: files sent as "File" keep all metadata (EXIF/GPS, PDF author)

**Where:** `MediaPrep.swift:98-105` (`file(at:)` copies the bytes unchanged).

**What's wrong:** a photo sent through the Files picker, or a document, keeps GPS, camera serial or document author.
SYSTEM_DESIGN §6.7 promises metadata stripping.

**Fix:** for image/video UTTypes in `file(at:)`, route through `image(from:)`/`video(from:)` or strip metadata. Warn
for other types.

**Test:** `AttackSurfaceTests.testImagesSentAsFilesLoseTheirLocation`.

**Confidence:** Confirmed.

---

### SEC-22 · Low · Clipboard: system text selection bypasses `SecurePasteboard`

**Where:** `ChatView.swift:331` (`.textSelection(.enabled)` on bubbles), `SettingsViews.swift:474` (purchase ID),
`OnboardingViews.swift:436` (username).

**What's wrong:** the system selection menu's Copy writes to the general pasteboard with no `localOnly` and no
expiry, so the text goes to Universal Clipboard on the user's other devices and stays there. Look Up and Translate can
send text to Apple. It's unclear whether the attached `.contextMenu` blocks it on bubbles.

**Fix:** remove `.textSelection` and keep only the `SecurePasteboard` copy actions.

**Test:** UI test: long-press a bubble → no system Copy/Share/Look Up menu.

**Confidence:** Possible (bubbles); Likely (purchase ID / username views).

---

### SEC-23 · Low · Release / compliance: the privacy manifest declares no collected data

**Where:** `Priva/Resources/PrivacyInfo.xcprivacy` (`NSPrivacyCollectedDataTypes` empty) vs `docs/LAUNCH_CHECKLIST.md:38-45`
(User ID linked; Purchase History not linked) and actual data flows (commitment and keys, keyed purchase hash, IP).

**Fix:** declare `NSPrivacyCollectedDataTypeUserID` (linked, App Functionality) and `…PurchaseHistory` (not linked)
so the manifest matches the label.

**Test:** `launch_check.sh` check that the manifest's collected types match the checklist.

**Confidence:** Confirmed.

---

### SEC-24 · Low · Server robustness: unbounded bodies and storage clutter

**Where:** `rendezvous/src/index.ts:164-166` (size checked only via `Content-Length`; a chunked body skips it),
`:93`; `supabase/functions/_shared/util.ts:22-27` (`arrayBuffer()` reads everything before the size check when there's
no `Content-Length`).

**Fix:** stream-read with a byte cap (`request.body` reader that aborts past `MAX_BODY`), and reject a missing
`Content-Length` on `/send` and the edge functions.

**Test:** `RelaySecurityTests.testChunkedOversizedBodiesAreRefused`.

**Confidence:** Confirmed.

---

### SEC-25 · Info · Server-steered clock and session teardown

**Where:** `Wire.swift:145-172` (`ServerClock.observe` from any HTTPS response, Supabase or relay; last one wins;
±1 h); `API.swift:293`; `PrivaEngine.swift:767-777` (any authenticated hello with a new sid supersedes a ready
link).

**Note:** a malicious relay can skew a victim's protocol clock by ±1 h, so all its ±2-minute signals are rejected
(targeted DoS). It can also hold back a hello and release it within 2 minutes to tear down a fresh session. Both
are within the relay's "can drop traffic" power, but harder to diagnose. Consider taking clock corrections only from
Supabase, with a median of several observations.

**Confidence:** Confirmed.

---

### SEC-26 · Info · Homoglyph impersonation and keyword-filter gaps

**Where:** `SafeImage.swift:59-71` (`TextSafety.name` folds case, diacritics and width, but not confusables, so
Greek "Ρriva Support" passes); `GroupHub.swift:259-267` (the keyword filter checks only `e.text`, not attachment names).

**Fix:** apply a Unicode confusables skeleton (UTS #39) before the brand check, and filter `attachment.name`.

**Confidence:** Confirmed.

---

### SEC-27 · Info · A group host can make messages appear as sent by the victim on the victim's own phone

**Where:** `GroupHub.swift:684-692` (`outgoing: sender == me` for host-delivered posts).

**Note:** beyond the documented "host can forge members' posts", the host can plant posts that show as the user's own
(right-aligned, "delivered"). Ignore `.deliver` with `sender == me` unless the message ID is in the member's own
outbox.

**Confidence:** Confirmed.

---

### SEC-28 · Info · Release gating (documented, still open)

`allow_dev_purchases = true` (`20260922000001_priva_core.sql:43-45`; `purchase.ts:20-22`): anyone can mint tokens and
passes with a random `dev_nonce`. Sandbox receipts are accepted in production (`apple.ts:65-66`). Debug hooks are
correctly behind `#if DEBUG` (`DebugAutomation.swift`, `WireTap.swift`, `debugDirectoryOverride`, `debugFailStretch`),
Release doesn't define `DEBUG`, ATS has no exceptions, file sharing is off, data protection is `Complete`, and no
hard-coded secrets beyond the publishable key were found (scripts, tests and `supabase/.temp` checked). Switch the dev
flag off and decide on Sandbox before launch, and extend `launch_check.sh`'s string scan to every `debug*` symbol.

---

## Missing adversarial tests

| Scenario | Why no test covers it today |
|---|---|
| Malicious group host sends an SDP offer after a member's call request timed out or was declined (SEC-01) | `testACallerCannotSwitchOnTheCalleesMicOrCamera` covers 1:1 only; group tests use honest hosts |
| Purchase-proof timing vs identity calls, Tor circuit isolation, DB `xmin` ordering (SEC-02) | No test inspects request timing or SOCKS isolation |
| Credential reuse across relay topics and sends; old↔new identity linkage at the relay (SEC-03) | `testListenKeysAreDerivedPerTopic` checks keys, not the pass |
| Phrase-only attacker forging `MoveProof`s (SEC-04) | `testAForgedMoveIsIgnored…` forges with *wrong* keys only |
| Anonymous TURN credential minting / flooding (SEC-05) | `testTheProjectRelayHandsOutExpiringCredentials` asserts it works anonymously |
| Stacking same-day passes; DO fan-out cost; sends to unowned topics (SEC-06) | `testRelayPassesAreBoundedPerPurchase` counts per month only |
| JWS replay from another device / non-app client (SEC-07) | - |
| Replay of an *accepted* or *declined* friend request after restart (SEC-08) | Replay test uses a pending request and counts, not pair state |
| Stale charter claim by a demoted admin; successor returning after 72 h (SEC-09) | `testE2EGroupHostFailoverAfterUninstall` covers the happy path |
| `.sync(since: 0)` from a newly joined member (SEC-10) | - |
| Removed member/successor contacting members over hidden links; presence to group-only contacts (SEC-11) | Tests assert links are *installed*, never removed |
| Oversized auto-downloads; repeated `fileWant` (SEC-12) | A9 test covers a single request |
| Directory lookups made without user action (SEC-13) | Budget tests count signals, not lookups |
| Text-only restore + exotic-format thumbnail (SEC-15) | Poisoned-media tests cover live arrival only |
| Keychain contents usable without the vault key (SEC-16) | - |
| "Relay calls" with no relay available (SEC-17) | `testWithoutARelayOnlySTUNIsUsed` asserts the fail-open behaviour |
| Disappearing messages recoverable from WAL or backups with VK (SEC-19) | `testDisappearingMessagesExpireOnBothPhones` checks the UI and store only |
| Chunked oversize bodies to relay and edge functions (SEC-24) | Tests send `Content-Length` |
| Malicious relay skewing the clock / delayed hello teardown (SEC-25) | `testAWrongPhoneClockIs…` covers honest correction |
| Confusable display names posing as Priva (SEC-26) | `testDeceptiveFileAndDisplayNamesAreNeutralised` uses Latin only |

---

## Privacy exposure map

Modes: **Normal** = default (direct ICE, no Tor), **Relay calls** = `relayCalls` on with TURN available,
**Tor** = onion mode (relay-only ICE, Supabase and relay via Tor; TURN media goes direct).

| Party | Normal | Relay calls | Tor |
|---|---|---|---|
| **Friend** | Your public IP, LAN IPs and IPv6 whenever they send a hello, silently, any time Priva is open; online presence (default on); typing (default on); read receipts (off by default); display name; files and metadata of `.file` sends (SEC-21) | Your TURN relayed address only; presence and typing as Normal | Same as Relay calls; Priva waits instead of going direct |
| **Group host** | All group plaintext and media keys, every member's IP (members connect to the host), roster with every member's keys and inbox topic, who's online; can forge posts, including as you (SEC-27); can switch on your mic/camera after a timed-out call request (SEC-01) | Relayed addresses instead of IPs; content as Normal | As Relay calls |
| **Fellow member / ex-member with a successor link** | Your IP and presence, silently, indefinitely (SEC-11); full history if newly joined (SEC-10) | Relayed address | Relayed address |
| **Cloudflare relay (Worker/DO)** | Your IP; your stable inbox and request topics and announce topics you watch; via the daily pass, the inbox topics you signal (friend graph), message timing and padded sizes; old↔new identity link after a move (SEC-03) | Same | Tor exit instead of IP; graph still linked by pass (SEC-03) |
| **Supabase (DB, edge, PostgREST logs)** | IP + appTransactionID at issue-token/relay-pass, linkable to ucommit through timing, IP and `xmin` (SEC-02); IP + ucommit for register/renew/own lookup; the commitments you look up (friend graph, SEC-13); creation day and lease week of every bundle (SEC-14) | Same; plus TURN credential requests | Tor exit instead of IP, but one shared circuit still links purchase calls to identity calls (SEC-02) |
| **Cloudflare TURN** | Not used unless direct fails | Your real IP, your friend's real IP (both allocations), call timing and volume, a 6-h credential linking your sessions | Same as Relay calls: real IP (UDP isn't routed through Tor) |
| **Apple** | Who bought Priva (appTransactionID), StoreKit queries at each unlock (`rememberPurchase`), iCloud Drive backups (encrypted, plaintext header with exact creation time and key hint), iCloud Keychain factor (E2E), Universal Clipboard content if system Copy is used (SEC-22) | Same | Same |
| **Network observer (ISP/Wi-Fi)** | TLS to Supabase and workers.dev (timing: when you unlock, sign up, refill passes), WebRTC peer IPs (who you talk to, by IP), call volume | Only that you talk to Cloudflare TURN and when | Only that you use Tor (+ direct UDP to TURN) |
| **Device thief, locked phone** | Nothing readable (Complete protection); after the next unlock, Keychain items readable with forensics/jailbreak: username and revocation secret (SEC-16) | Same | Same |
| **Device thief, unlocked phone + owner's face** | Recovery phrase (→ SEC-04 silent takeover), account deletion, restore-over, all chats once Priva is unlocked; the username shown on Priva's lock screen without any unlock | Same | Same |
| **Support (abuse report email)** | Reporter's email identity, the reported username, the last 10 of their messages (included by default) | Same | Same |
