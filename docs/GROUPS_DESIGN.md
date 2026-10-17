# Priva: Groups, Group Calls & Onion Routing

Status: design of record. Nothing described here touches Supabase.

---

## 1. Requirements (owner's words) → design

| Requirement | Design |
|---|---|
| Group chats, group voice calls, group video calls | Star topology over Priva's existing Dual-PQ peer-to-peer sessions |
| "The host handles the processing … he's the main server for the group call or the group chat" | The **host's iPhone is the group server**: it receives every message, applies the rules, stores the history and fans out to members; in calls it forwards (re-encodes) everyone's media |
| "The host carries all the messages" | Authoritative history + per-member delivery queues live on the host (sender-queue principle) |
| "The host is the admin … add member, remove member, keyword filtering, etc." | Host-enforced admin actions (§5) |
| "Check what happens if the host uninstalls their app" | Signed **succession charter** + group links; an admin (or the oldest member) takes over automatically (§6) |
| "Don't keep anything on Supabase" | Groups use only P2P sessions; the rendezvous plane only carries the same sealed, ephemeral signalling as 1:1 chats |

---

## 2. Trust model (explicit)

* **Between members and the host**: every hop is the normal 1:1 Priva session (X-Wing + ML-KEM-1024 handshake,
  AES-256-GCM ∘ ChaCha20-Poly1305 frames, PQ-keyed media frame encryption).
* **The host sees group plaintext**: by design, because the owner wants the host to *process* the group
  (keyword filtering, moderation, forwarding). Members are told this in the group info screen.
* **Members do not learn each other's IP addresses or keys**: they only connect to the host.
* **Supabase / networks** learn nothing new: no group identifiers, rosters or messages ever leave the P2P plane.

(Alternative considered: MLS / sender-key groups where the host can't read content. Rejected here because it
makes host-side keyword filtering impossible; it can be offered later as a "private group" mode.)

---

## 3. Data model (on every member's device; the host's copy is authoritative)

```
Group      id (16 B random) · name · host · epoch · created
           members [ username · role (host | admin | member) · muted · joined ]
           rules   { announceOnly, keywordFilter [words], filterAction (block | mask), maxMembers }
           charter { groupID, epoch, host, successors [usernames] }  ← signed by host (Ed25519 + ML-DSA-65)
GroupMsg   groupID · seq (host-assigned, monotonic) · sender · envelope (same as 1:1) · status
Host only  groupOutbox (member, groupID, seq): messages waiting for an offline member
```

Membership requires the host to be friends with each member (invites go over friend links). Members need not
be friends with each other.

---

## 4. Message flow

```
member A ──Wire.groupPost──► HOST ──(rules: member? muted? announceOnly? keyword filter)──► assign seq, store
                               │                                                           │
                               └──Wire.groupAck(seq)──► A                                   ├──Wire.groupDeliver──► B
                                                                                           └──Wire.groupDeliver──► C (queued until online)
```

* Keyword filter: **block** (the post is rejected; the sender sees "Blocked by group filter") or **mask**
  (matched words become •••). Matching is case- and diacritic-insensitive, whole-word.
* Attachments: A uploads to the host through the normal chunked, verified file transfer; once the host holds
  the complete (still encrypted) file it fans out the message; members download from the host.
* Offline members: the host queues per member and delivers when a session forms, nothing on any server.

---

## 5. Admin actions (enforced by the host)

| Action | Who | Effect |
|---|---|---|
| Add member | host, admins | Host sends a signed invite over its friend link; invitee joins or declines |
| Remove member | host, admins (not the host) | Host stops relaying, sends `removed`, new epoch, group links rotated |
| Promote / demote admin | host | Admins become successors in the charter |
| Mute / unmute | host, admins | Host rejects posts from muted members |
| Keyword filter + action | host, admins | Applied to every post before fan-out |
| Announcement-only mode | host, admins | Only admins may post |
| Rename group | host, admins | New state broadcast |
| Delete message for everyone | host, admins, and the sender | Host removes it from history and tells members |
| Transfer host | host | Planned handover (§6.1) |
| Disband | host | Members are notified; history stays on their phones |

Every state change increments `epoch`; the host re-signs the charter and pushes the full state to all members.

New members see only what's posted after they join: the host records each member's join point and never serves
older posts or files, even when asked with `.sync(since: 0)` (audit SEC-10).

---

## 6. When the host disappears

### 6.1 Planned (host leaves the group or uses "Leave Priva")
Host picks a successor (default: first admin, else longest-standing member) and sends a signed **handover**:
new charter with `host = successor`. The successor already holds the full history as a member; members
switch to it and re-sync anything they missed by sequence number.

### 6.2 Unplanned (uninstall, lost phone)
* The group moves only when the host's directory entry reads `uninstalled`/removed. Silence (72 h without a signal)
  is only a reason to ask the directory: two people on different hours can go days without one (audit STA-04). A
  successor who gets "active" asks again a day later; one that gets no answer, ten minutes later. An earlier
  successor heard from in the last week goes first.
* The first successor in the **last charter signed by the old host** who is online claims the group:
  `Wire.groupHandover { charter (signed by old host), claim (signed by successor) }`.
* Members verify the old host's signature over the succession list and the successor's claim, then accept.
* **A claim alone proves nothing about the host being gone.** Every member does a live directory lookup and accepts
  only if the entry is `uninstalled`/removed; a claim it can't confirm yet is kept and asked about again (10 min →
  6 h while the directory doesn't answer, daily while it lists the host, for two weeks). Only the latest charter
  counts: a claim built on an older one (say, from before an admin was demoted) is refused outright. A live host
  never accepts a claim against itself and signs a new charter, which makes that claim stale everywhere.
  (Otherwise any listed successor, or a lying directory, could hijack a working group.)
* The successor reaches members it isn't friends with through **group links**: when a member joins, the host
  gives each successor–member pair a fresh random pair root and each other's inbox topic (sent inside the
  encrypted host sessions). These appear as hidden, group-only contacts, so all the normal P2P machinery works.
* No successor online ⇒ the group becomes read-only ("Host left: waiting for an admin"), history intact.

The host always appoints successors automatically (all admins, then the two longest-standing members), so
a group survives its host uninstalling Priva.

---

## 7. Group calls: host as media processor

```
      member B ─┐                 ┌─► B receives: host + C + D
      member C ─┼─► HOST (forward/re-encode) ─┼─► C receives: host + B + D
      member D ─┘                 └─► D receives: host + B + C
```

* Each member keeps one PeerConnection (its normal session) to the host; the host adds every other
  participant's received track to each member's connection (libwebrtc decodes and re-encodes).
* Media keys are per hop (member↔host), installed before any frame flows; the host is the trusted processor.
* Limits sized for an iPhone host: **voice ≤ 8**, **video ≤ 4** participants at 360p/20 fps, adaptive.
* Renegotiation over the encrypted data channel when people join or leave; the host rings members with
  `groupCallInvite`. Members who are offline when the call starts are rung as soon as their session comes up.
* Members send a lighter 640×360 @ 20 fps stream in group calls (the host re-encodes everything anyway).
* Frame cryptors are keyed on native sender/receiver ids: re-installing one on renegotiation would replace the
  live frame transformer mid-stream (this was a real bug: invisible in 1:1 calls, which negotiate once).
* Lesson from testing: the host's per-receiver re-encode is the cost centre (N−1 encodes per forwarded
  stream). Forwarding *encoded* frames (SFU-style, no re-encode) would need raw encoded-frame hooks that the
  iOS WebRTC SDK doesn't expose today; it is the main scaling item if the 4-video limit is to be raised.

---

## 8. Onion routing (research outcome)

| Option | Works for | Cost | Verdict |
|---|---|---|---|
| Embedded Tor client (Tor.framework, CocoaPods; swift-tor, SPM, pre-1.0) | Account + rendezvous HTTPS/WebSocket (TCP) | +10–20 MB app size, 0.5–2 s extra per request, slower call setup | **Adopt as "Onion mode"** |
| Orbot VPN on iOS | TCP only; cannot carry audio/video | User installs a second app | Supported automatically (no code) |
| Tor for calls / media | - | UDP not supported; latency kills calls | **Not viable**: use TURN relay to hide IPs instead |

What onion routing adds: Supabase (and any network observer) no longer sees the user's IP for purchase
checks, registrations, lookups or rendezvous: removing the last metadata link (IP/timing correlation)
identified in IDENTITY_DESIGN §9. Implementation: a SOCKS5 proxy configuration applied to every URLSession
and the Realtime WebSocket (`ProxyConfiguration(socksv5Proxy:)`), fed by the embedded Tor client.

**Implemented (NetworkPrivacy.swift, Settings → Onion routing):**
* Applies to every PrivaAPI session and the rendezvous socket; sessions are rebuilt when the setting changes.
* **Fail-closed** (`allowFailover = false`): proxy down ⇒ Priva stops connecting, never falls back to direct.
* Hostnames are handed to the proxy (SOCKS5 domain addressing): no local DNS lookups of Priva's servers.
* Stored in a device-only Keychain item, because onboarding and unlock reach the directory before the vault opens.
* Onion mode is relay-only ICE, always: with no relay yet, connections wait rather than go direct (peers never see
  the IP), and no STUN server is asked for it. Idle connections are kept 15 min instead of 5 (a new one costs three
  Tor round trips).
* Verified by `OnionModeTests` against a local logging SOCKS5 proxy: both planes go via the proxy by hostname,
  nothing connects when the proxy is down, and direct connections resume when the mode is off.
* Still to ship: bundling a Tor client (swift-tor or Tor.framework) so no separate proxy is needed.

## 9. Delivery guarantees (as built)

* Group **control** packets (invite, join, state, admin, removal, deletion, links, handover, sync) are queued
  per peer on the sender's iPhone when the peer is offline and flushed when its session comes up, only the
  newest state snapshot per group is kept. Chat messages use the host's per-member queue (acked, replayed
  on reconnect); members' own unconfirmed posts are resubmitted to the host (deduplicated by message id).
* Measured (3 live nodes, simulator): member→members fan-out 27 ms; 100-message burst to 2 members 187 ms,
  in host order, exactly once; 24 MB attachment member→host→member bit-exact; host failover after uninstall
  1.4 s; group call ring 30–220 ms, accept→all tiles 80–480 ms, every member receives 2 video + 2 audio
  streams, 0 frame-decryption failures.

## 10. Adversarial audit (as fixed and tested)

| Finding | Fix | Test |
|---|---|---|
| A member's call request auto-started the host's camera/mic and streamed to them | Host rings first; media starts only after the host joins | `testAdversarialGroupAbuseIsRefused` §1 |
| Hidden group links could send DMs, typing, receipts, 1:1 calls | Group-only contacts may carry only the group protocol | §2 |
| WebRTC auto-managed audio (peer renegotiation could start I/O) | Manual audio; enabled only while a call is up | group call test (2 audio streams) |
| Closing any link released the audio session mid-call | Only a link that carried media releases it | group call test |
| Invites exposed the full roster and successor list | Invite = host + member count; roster after joining | §3 |
| Unlimited invites / oversized state | 5 per friend, 20 total; 256 members | - |
| Zero-width characters bypassed the keyword filter | Format characters stripped before matching | `testKeywordFilterResists…` |
| Members could flood the host / fill its disk | Token bucket per member (burst 30, then 3 posts/s); 2 GB attachments. Honest clients keep "slow down" posts queued and resend them paced, so nothing is lost (45-post burst: all delivered in ≈6 s) | §4 |
| Host end left unanswered members ringing forever | End sent to everyone rung; 45 s ring timeout | §1 |
| Engine read another account's request topic from the Keychain | Topic derived from the engine's own username | full E2E suite |

**Residual (by design or open):** the host can read and could forge group messages (trusted processor,
stated in the UI); homoglyph look-alikes can evade the keyword filter; forwarded video is re-encoded per
receiver (4-video cap); onion mode needs a SOCKS proxy until a Tor client is bundled; `allow_dev_purchases`
must be set to **false** in `priva.app_config` before App Store release.

## 11. Scale: how big a group can be (measured 2026-10-04)

A group lives on the host's iPhone: it stores every post, queues it for every member until acknowledged, and sends
it over a direct connection to each member. That puts the whole cost of a big group on one phone.

**The host's own work** (`GroupScaleProbeTests.testWhatAThousandMembersCostTheHost`, simulator; a phone is ≈ 2–3×
slower):

| Members | Roster a new member receives | Storing + queueing one post | Scheduler check per tick |
|---|---|---|---|
| 100 | 1.1 MB | 13 ms | 0.1 ms |
| 256 | 2.8 MB | 36 ms | 0.3 ms |
| 1,000 | 10.9 MB | 156 ms | 1.1 ms |

The roster is ≈ 11 KiB per member: every member carries every other member's post-quantum public keys (to verify
the host's charter and reach a successor if the host disappears). Large control messages are fragmented, so it
arrives, but each join also sends the newcomer's keys to everyone (≈ 11 KiB × members of host upload).

**Live** (`StressTests.testWholeGroupComesBackAtOnce`, one Mac process, the real relay): 20 members offline while
the host posts 30, then all 20 come back in the same second. Every member got all 30, once, in the host's order,
in **38 s**; the host's queue peaked at 600 items. That time is mostly back-off: all 21 simulated phones share the
Mac's one IP address, and the relay refused 252 of 677 sends with "slow down" (its per-IP limit is 600 sends a
minute). Real phones each have their own address. The same limit is why 40 and 60 members fail in this setup
(invites stall), and at 60 the process also runs out of file handles (each simulated phone opens sockets on every
network interface of the Mac). A real phone hosting a group opens one connection per online member; Priva raises
its open-file limit to 4,096 and keeps at most 128 connections (`PrivaEngine.maxLinks`), dropping the quietest
idle one to make room.

**Why not 1,000 members:**
- Connections: at most 128 open on the host. 1,000 members online would churn: every message to a member without a
  connection costs a new handshake (three relay trips, ≈ 6 relay requests). One "everyone comes back" moment is
  ≈ 6,000 relay requests: 6 % of the relay's free daily budget, for one group, once.
- Bandwidth: a 5 MB photo to 1,000 members is 5 GB of upload from one iPhone. Even at 256 it's 1.3 GB.
- Main thread: ≈ 0.4 s of host work per post on a phone at 1,000; busy groups would stutter.
- Roster: 11 MB to every newcomer, and 11 MB of host upload per join.
- iOS: the host must be open for the group to move. iOS suspends Priva in the background; with 1,000 people, the
  group would mostly be waiting for one phone.

**Across two simulators** (`scripts/herd.sh`: host + members on one simulator, the rest on another, coordinated
through a folder on the Mac; `TEST_RUNNER_PRIVA_LEAN_NET=1` skips the Mac's ≈ 20 network interfaces' VPN tunnels):
21 users, all back at once, caught up in 10.6–12.7 s, every post once and in order. The relay still refused 101 of
423 sends from the Mac's one address. **100 users needs the relay's per-IP limits raised for the run** (deploy with
10× limits, run, roll back to the previous version), not done yet.

**Watch item, the relay's per-IP limit:** 600 sends and 300 connections a minute per IP address. Phones behind
one carrier-grade NAT address (common on mobile networks) share it. Passes are limited too (300 a minute each), so
the per-IP limit could be raised several times over if many users ever share an address. That's a relay setting
(`rendezvous/wrangler.jsonc`), for the owner to decide.

**Limits as shipped:** 100 members by default, at most 256 (`PrivaGroup.Rules.maxMembers`), 8 in a voice call,
4 in a video call.

**What 1,000 would take** (none of it without giving up something the owner asked for):
1. A slim roster: members keep only each other's 32-byte identity keys; full key bundles only for the next hosts.
   ≈ 100× smaller rosters. Changes the group protocol (versioned).
2. Fan-out through co-hosts: the host sends each post to ~10 relaying members, each relays to ~100. Spreads
   bandwidth and connections, but adds a hop and trust in the relays.
3. A store-and-forward server for groups. Ruled out: "For groups, don't keep anything on Supabase."
