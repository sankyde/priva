# Priva: Identity & Username System (v2)

Status: design of record · supersedes §4–§5 of SYSTEM_DESIGN.md where they differ.

---

## 0. The owner's requirements, verbatim → how each is met

| # | Requirement | Design answer |
|---|---|---|
| U1 | "No link between who buys the app and the username." | RFC 9474 blind tokens (cryptographic unlinkability) + metadata minimisation (no fine timestamps) + timing jitter. §3, §6 |
| U2 | "The username should be randomly generated." | Generated **on the device** from a CSPRNG: 3 words + 4 digits (≈ 43 bits). §2 |
| U3 | "…and then stored in the database as active." | The directory stores the name's **commitment**, status `active`, and the public keys. §4 |
| U4 | "If a customer uninstalls the app then it should go to uninstalled." | iOS gives apps no uninstall hook, so the device holds a **lease** it renews while Priva is in use. No renewal for 21 days ⇒ every device treats the name as `uninstalled`. "Leave Priva" in Settings sets `uninstalled` instantly. §5 |
| U5 | "If the customer wants to sign back in, their ID is checked in the paid table, and a new username is generated … updated in Supabase … the previous username should be removed." | Reinstall ⇒ App Store receipt re-verified against the paid table ⇒ fresh blind token ⇒ new random name registered `active`; the previous name's row is **deleted** with the revocation secret. §6 |
| U6 | "All of their friends get the update … and the option to update the username." | Signed **rename announcement** on a private channel only friends know, derived from the 24-word phrase. Friends see "@old is now @new: Update?" §7 |
| U7 | "Nothing should be done on the server side, everything should be happening on the user side." | The server is a **verifier and a dumb store**. It never sees a username, runs no jobs, makes no decisions. It only does what cannot be done safely on a phone: check Apple's signature, blind-sign, check owner signatures, store rows. §8 |

---

## 1. What we learned from the most private systems

| System | Identifier | What it gets right | What Priva adopts |
|---|---|---|---|
| **Threema** | Random 8-char ID, no phone/email; ID revocable with a revocation password | Paid + anonymous; revocation independent of the device | Random IDs; a **revocation secret** |
| **Signal usernames** | Nickname + discriminator; server stores only a hash; ZK proof of knowledge | Server never sees the displayable username | **Server never sees usernames**, only a device-computed commitment |
| **SimpleX** | No identifiers at all; pairwise one-way queues | No global ID ⇒ nothing to correlate | Per-pair secret topics after friendship; **no global topic that the server can map to a user** |
| **Session** | 66-hex public key as ID; onion-routed | Network anonymity | Documented as next step (OHTTP / Tor): see §9 |
| **Privacy Pass / Apple PAT** (RFC 9576–9578) | Blind-signed anonymous tokens | Prove "I paid" without saying who | Blind tokens for registration |
| **Oblivious HTTP** (RFC 9458) | - | Relay sees IP not content; gateway sees content not IP | Recommended phase-2 transport for account requests |
| **Key Transparency** (WhatsApp AKD, iMessage CKV) | - | Server can't silently swap keys | Phase-2; today: pinned keys + safety numbers + signed continuity |
| **PIR** (Apple swift-homomorphic-encryption, Live Caller ID Lookup) | - | Server can't see *which* entry was looked up | Phase-2 option for directory lookups |

Priva combines the strongest ideas that work with a paid App Store app and exact-username search.

---

## 2. Random usernames (generated on the device)

```
username = w1 "_" w2 "_" w3 "_" dddd        e.g.  cedar_lunar_pilot_5821
w1..w3  ∈ 1,024 short words (BIP-39 English, 3–5 letters)   → 30 bits
dddd    ∈ 0000–9999                                         → 13.3 bits
                                                   total    ≈ 43.3 bits,  ≤ 22 characters
```

* CSPRNG (`SecRandomCopyBytes`); the user cannot type a vanity name, but may **shuffle** before
  registration (each candidate is still random and is never sent anywhere until claimed).
* Collisions: the registration call fails with `taken`; the device simply draws again.
* The name is **registered before it is ever displayed**, so nobody can learn it and claim it first.
  The server cannot check that a commitment matches a real name (it never sees names): it doesn't
  need to: names are unguessable, first-come-first-served, and retired commitments are blocked.
* Sharing: long names are shared as a QR code / `priva://add/<name>` link, and friends can give
  each other a **local display name** that travels only inside end-to-end-encrypted messages.

### 2.1 The username never leaves the device in plaintext

```
S        = scrypt("priva-username-v1|" ‖ username, salt "priva.directory.v1", N=2^16, r=8, p=1, 64 B)
ucommit  = HKDF(S, "priva/ucommit")[32]     → the directory key the server stores and is queried with
topicKey = HKDF(S, "priva/request-topic")[32] → friend-request topic, never sent to the server as such
```

* The server stores and compares **ucommit** only. It cannot list, search or display usernames.
* Brute-forcing a leaked directory costs one 64 MiB scrypt per guess over a 2^43 space
  (≈ decades of GPU time for a full sweep; ~a CPU-month to find *one* random user among a million).
* **Request topic** = `r-` ‖ base32(HKDF(topicKey)). The server has every public key but cannot
  compute any request topic, so it cannot tell *who* is receiving a friend request (v1 derived
  topics from public keys: that leak is closed).

---

## 3. Purchase → anonymous token (unchanged core, hardened metadata)

1. Device fetches the App Store receipt (`AppTransaction`, JWS signed by Apple).
2. Device generates `T = "PRIVA-TOKEN-v1" ‖ 32 random bytes`, blinds it with the pinned server key.
3. `issue-token` verifies Apple's signature chain, computes `purchase_ref = HMAC(pepper, appTransactionID)`,
   looks it up in the **paid table**, applies the reinstall rate limit, blind-signs.
4. Device unblinds → `(T, σ)`, verifies σ with the pinned key (defeats per-user key tagging), discards the receipt.

The server saw `blind(T)`; later it sees `T`. RFC 9474 blinding makes them **information-theoretically
unlinkable**.

**Rate limit for reinstalls** (anti-abuse, not identity): ≤ 3 tokens per calendar month, ≤ 10 per year,
stored as month buckets (`"2026-09"`), never days or times.

---

## 4. What the database holds (and deliberately does not)

```
purchases        purchase_ref (HMAC), environment, verified_month, issued_months[]      ← the paid list
directory        ucommit (PK), status active|uninstalled, bundle (public keys, nullable),
                 lease_week (Monday of expiry week), revoke_hash (SHA-256 of revocation secret)
retired_commits  ucommit                                                                 ← anti-hijack tombstones
redeemed_tokens  SHA-256(token)                                                          ← double-spend guard
server_secrets / app_config                                                              ← operational
```

Removed compared to v1: plaintext usernames, `created_on`, `redeemed_on`, day-level purchase dates.
With no creation dates anywhere, the database cannot be used to match "a purchase on day D" with
"a username created on day D".

---

## 5. Lifecycle: active → uninstalled → removed

```
          register (token)            lease lapses (21 d, no renewal)       sign back in (revocation secret)
 (none) ────────────────► ACTIVE ─────────────────────────────────► UNINSTALLED ──────────────────────► REMOVED
                          │  ▲ renew (signed, ≤ weekly)                ▲                               (row deleted,
                          │  └────────────────────                     │ "Leave Priva" (signed)         commitment kept
                          └────────────────────────────────────────────┘                                in retired set)
```

* **Renewal** is decided by the device: when the stored lease expires in < 14 days, the next unlock
  sends a signed `renew` at a random moment of that session. The server stores only the week.
* **Uninstalled** is evaluated **on devices**: `status = uninstalled` or `lease_week < this week`.
  No server job flips it: the phone reading the directory decides, as the brief requires.
* **Removed**: the row and its keys are deleted. Only the irreversible commitment stays in
  `retired_commits` so nobody can later register the same name to impersonate its former owner.

---

## 6. Signing back in after a reinstall

What survives an uninstall is **not guaranteed by Apple** (Keychain persistence is an implementation
detail that iOS 10.3 betas briefly removed). The flow therefore works from the recovery phrase alone
and only *uses* surviving Keychain items as a shortcut:

| What the returning user has | Old username removed | Friends notified |
|---|---|---|
| Surviving vault (password + Face ID unlock) | ✓ automatically | ✓ |
| 24-word recovery phrase | ✓ | ✓ |
| Recovery Key file + the password it was saved with (same Apple Account) | ✓ | ✓ |
| Surviving revocation secret only | ✓ | ✗ (friends see "left Priva") |
| Nothing | lease lapses → uninstalled | ✗ |

Steps (all on the device):
1. **Purchase re-check**: App Store receipt → `issue-token` confirms the purchase is in the paid
   table → a fresh anonymous token.
2. **New random username + new keys** (new seed, new recovery phrase). Keys are rotated so the
   server cannot link old and new names by key material.
3. **Register** the new name (`active`) over a separate TLS session after a random delay.
4. **Announce** to friends (§7), signed by the old identity.
5. **Remove the old name**: `revoke(ucommit_old, R_old)` at a random time later in the session
   (10 min – 24 h, retried on later launches), so removal and registration are not adjacent events.
   `R = HKDF(old seed, "priva/revoke/v1")`: the phrase alone suffices.

---

## 7. Friend migration: private rename announcements

Every user has an **announce key** `A = HKDF(seed, "priva/announce/v1")`, shared with each friend
inside the encrypted friend request / acceptance. Friends store it with the contact.

```
announce topic  M = "m-" ‖ base32(HKDF(A, "topic"))           (server cannot derive it)
announcement    = DualAEAD(HKDF(A, "key"), {old, new, newBundle, displayName, ts})
                  ‖ HybridSig_old("PRIVA-RENAME-v1" ‖ …)        (Ed25519 + ML-DSA-65, old pinned keys)
```

* The returning device re-broadcasts the announcement on `M` whenever it is online, for 30 days
  (the same sender-side-queue principle: nothing is stored on a server).
* Friends subscribe to `M` **only for a contact that looks gone**: silent for > 48 h *and* the
  directory (checked at most daily) shows `uninstalled` or removed. Subscribing to every friend's
  topic all the time would let the server read each user's friend set from subscriber lists; this
  policy leaks nothing beyond what ordinary messaging already does. Max 40 topics (Realtime allows
  100 channels per connection).
* Each announcement carries a **generation number**; friends keep the highest seen and ignore
  replays of older announcements.
* A friend verifies (1) the old identity's hybrid signature with the **pinned** old keys, (2) the new
  bundle against the directory by `ucommit(new)`, then shows **"@old is now @new: Update / Dismiss"**.
* **Update** sends a normal Dual-PQ friend request to the new name, carrying
  `proof = HMAC(A, "priva/rename-ack" ‖ friend ‖ new)`. The returning user sees "Former friends
  updated to your new name" with **Accept all**. Fresh encapsulations ⇒ new pair keys (the old ones
  are never reused); the friend keeps the chat history under the new name.
* Forgery needs the old private keys (vault or phrase). A stranger can neither read nor fake it.
* Known limit: a friend you *removed* still holds `A` and could see a future rename. The
  "Start fresh" option skips announcing entirely.

---

### 7.1 Restoring a backup = moving to a new username

A restore (docs/BACKUP_DESIGN.md §8) always registers a **new** identity and username. Friends are not asked to tap
anything: the restored iPhone sends each of them a friend request from the new username with a `MoveProof`, the
old identity's hybrid signature over (old, new, new keys, recipient, time). A friend follows only if that verifies
against the key pinned for the old username and the new keys are active in the directory. Friends remember each
move for 90 days; a second, different move of the same account is flagged, never followed. The old username is
removed from the directory 10 min – 6 h later, and the old iPhone gets a signed *your account moved* notice.

## 8. Where each piece of logic runs

| Logic | Where | Why it can't be on the phone (if server) |
|---|---|---|
| Generate username, commitment, topics | **Device** | - |
| Decide renew / uninstalled / removed | **Device** | - |
| Friend notification, update prompt, history migration | **Device (P2P)** | - |
| Verify Apple receipt, check paid table, rate limit | Server | A phone could lie about having paid |
| Blind-sign token | Server | Needs the issuer's private key |
| Check owner signatures before changing a row | Server | Otherwise anyone could delete others' names |
| Compare revocation hash | Server | Same |

---

## 9. Residual risks (honest) and the path beyond

| Risk | Today | Hardening |
|---|---|---|
| **Network metadata**: a server that logs IPs/precise times could correlate "receipt check" with "new registration" from the same IP | Blind tokens + no DB timestamps + random delays + separate TLS sessions + deferred removal | **Oblivious HTTP relay** run by an independent operator (RFC 9458) or Tor for account requests: removes the IP link entirely |
| Directory lookup reveals *which* commitment someone looked up | Commitments, not names; lookups when adding a friend, checking a request, and weekly for friends quiet for 2+ days (never for blocked people or group links) | **PIR** (Apple's swift-homomorphic-encryption) |
| Malicious server swaps a user's keys | Pinned keys, safety numbers, signed continuity on renames | **Key transparency** log (AKD/CKV-style) |
| Keychain wiped by a future iOS on uninstall | Phrase-based recovery covers it | - |
| One purchase → several usernames over a year | ≤ 3/month, ≤ 10/year | Tighter limits in `app_config` |
