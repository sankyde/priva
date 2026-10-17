# Priva: Encrypted Backups

Design of record for Priva's end-to-end encrypted backups (iCloud and on-device).

## 1. Goals

| # | Requirement | How |
|---|---|---|
| B1 | Only the owner can ever open a backup | Four independent factors, below; Face ID gates every backup action |
| B2 | Stored in the user's iCloud, with consent | iCloud Drive (app container), opt-in screen before first upload |
| B3 | A big recovery secret that can't be guessed | 24-word **Backup Key** (256 bits), separate from the account recovery phrase |
| B4 | "Doubly encrypted", best post-quantum crypto | Hybrid PQ KEM (X-Wing + ML-KEM-1024) → AES-256-GCM *inside* ChaCha20-Poly1305 |
| B5 | Opens only inside Priva | Opaque format; keys exist only inside the app after the user's factors are combined |
| B6 | Lean | Per-frame LZFSE compression; group media older than 90 days is deleted |
| B7 | Nothing on Priva's servers | Backups never touch Supabase; the server can't tell a backup exists |

## 2. What others do (research)

| System | Secret | Server role | Face / device binding |
|---|---|---|---|
| Signal Secure Backups (2025) | 64-char recovery key made on device | Stores ciphertext, unlinked from the account | None |
| WhatsApp E2EE backup | 64-digit key **or** password + HSM Backup Key Vault (rate-limits guesses) | HSM holds the key when a password is used | Passkey option |
| Apple Advanced Data Protection | Keys on trusted devices; 28-char recovery key or recovery contact | iCloud Keychain / HSM escrow | Trusted-device passcode |

Lessons applied: a high-entropy key generated on the device (Signal, WhatsApp); media re-encrypted and padded
so sizes don't leak (Signal); a device-trust factor (Apple). An HSM vault (WhatsApp) would mean keeping
per-user secrets on our server, which Priva's design forbids.

## 3. Factors

| Factor | What it is | Protects against |
|---|---|---|
| **F1 Backup Key** | 24 BIP-39 words (256 bits + checksum), shown once | Anyone with just the file (Apple, a thief with the Apple ID) |
| **F2 Priva password** | The password used to open Priva when the backup was made | Someone who finds the written-down Backup Key |
| **F3 iCloud Keychain secret** | 32 random bytes in a *synchronizable* Keychain item: end-to-end encrypted by iCloud Keychain, available only on devices trusted by the user's Apple Account (joining needs a trusted device's passcode) | Someone with the Apple ID password + the Backup Key + the Priva password |
| **Face ID** | Required to create, reveal, export or restore a backup; the restored vault is sealed to the new iPhone's Secure Enclave and opens only with the owner's face + password | Someone holding an unlocked phone |

**Why the face itself can't be in the backup.** Face ID templates never leave the Secure Enclave, and Secure
Enclave keys can't be exported, so no backup can carry "the face" to a new iPhone. The cryptographically sound
way to bind a backup to biometrics across devices is a synced **passkey with the WebAuthn PRF extension**
(iOS 18+): the PRF secret is produced only after Face ID on a device that holds the user's passkey. It requires an
Apple Developer Team ID and an associated domain, so it's the planned F4 once the app is signed for release.

## 4. Cryptography

```
F1: phrase ──scrypt(N=2^16, r=8)──► K₁ ──HKDF──► seeds ──► X-Wing sk/pk,  ML-KEM-1024 sk/pk   (the "backup key pair")
F2: password ──scrypt(N=2^17, r=8, per-key salt)──► K₂
F3: iCloud Keychain secret S (32 B, random)

Per backup:
  CK            ← random 256-bit content key
  (ctX,ctK,ss)  ← DualKEM.encapsulate(pk)                       X-Wing(ML-KEM-768+X25519) ‖ ML-KEM-1024
  WK            ← HKDF-SHA512(ss ‖ K₂ ‖ S, salt = "PRIVA-BACKUP-v1" ‖ id, info = SHA-512(header))
  wrapped CK    ← DualAEAD(WK)                                   AES-256-GCM inside ChaCha20-Poly1305
  frame i       ← DualAEAD(HKDF(CK), nonce = i, aad = SHA-512(header) ‖ i ‖ final?)
```

* **Write-only on the phone.** The phone keeps only the backup *public* key (plus K₂ and S inside the
  encrypted vault), so automatic backups need no phrase, and the Backup Key's private half never exists on disk.
* **Both KEMs must break** to recover `ss` (X-Wing is itself hybrid ML-KEM-768 + X25519).
* **Two AEADs** with independent keys around every byte; media is already encrypted with its own per-file key,
  so media ends up encrypted three times.
* **STREAM framing**: every frame's index and a "final" flag are authenticated, so frames can't be reordered,
  dropped, duplicated or spliced from another backup, and the backup can't be truncated.
* **Memory-hard KDFs** even for the 256-bit phrase (defence in depth against a weak RNG). Measured cost of a
  single guess (`BackupJourneyTests`): **≈1.5 s for a Backup Key guess** and **≈1.5 s for a password guess**,
  each with 64–128 MiB of memory. At 256 bits, 2²⁵⁵ guesses stay out of reach, and Grover's algorithm only
  halves that to 128 bits for a quantum attacker.
* **Header** (authenticated): magic, version, backup id, KDF salts & cost, KEM ciphertexts, wrapped CK,
  which factors are used, creation time, an 8-character key hint. No username or contents. Editing any header
  field (e.g. lowering the KDF cost to make guessing cheaper) makes the file unopenable.

## 5. Container

```
"PRIVABK1" | u32 header length | header JSON | frames…
frame on disk:  u32 length | DualAEAD(ciphertext)
frame plaintext: u8 type | u8 flags (bit0 = LZFSE) | payload
types: 1 manifest · 2 records (table + rows) · 3 media start · 4 media bytes · 5 media end · 6 padding · 0xFF end
```

Contents: identity seed, username, vault state, contacts, messages, groups (incl. host queues), call history,
settings, and media ciphertext. Records are compressed with LZFSE; the total is padded to a multiple of
64 KiB so the file size reveals little. Excluded: expired disappearing messages and group media older than
90 days (which is deleted from the phone as well).

## 6. Storage

* **iCloud** (opt-in, asked once): `iCloud Drive/Priva/Backups/<random id>.privabackup`. The newest 2 are kept.
  If iCloud Drive is off or signed out, backups stay on the phone and Settings says so.
* **This iPhone**: the app's private folder (excluded from device backups). The newest 2 are kept.
* **Restore sources**: iCloud, this iPhone, or "Choose a file…" (Files, AirDrop…).
* Backups run when Priva is unlocked, at most once a day, plus "Back up now". Nothing goes to Supabase.
* The backup's own settings (public key, K₂, schedule) travel inside the backup, so after a restore backups
  simply continue with the same Backup Key.

## 7. Setting up

1. Settings → Backup → **Turn on backups**.
2. **Where to keep backups**: iCloud (recommended) or this iPhone only. This is the iCloud consent step.
3. **Confirm it's you**: the Priva password, checked with Face ID against the vault (K₂ is derived from it).
4. **Your Backup Key**: 24 words, blurred until the user taps *Show*; a screenshot triggers a warning.
5. **Check your key**: pick the right word at 3 random positions. Only now are backups switched on. Cancelling
   or killing the app at any earlier step leaves backups off, so a key that was never written down is never used.
6. The first backup is written straight away. *Check my Backup Key* can re-verify the paper at any time without
   restoring anything.

### Key files instead of paper

Most people won't write 24 words down, so both 24-word keys, the Backup Key here and the recovery phrase at sign-up
(also later in Settings › Security & account), can be saved as an encrypted file (`.privakey`, `KeyFile.swift`)
through the Files sheet: iCloud Drive, On My iPhone, a drive. Saving the file replaces the 3-word check (the file holds
the exact key).

    file = "PRIVAKEY" | u32 len | header JSON (kind, created, salt, scrypt rounds) | DualAEAD(k, aad = H)(32-byte key)
    k    = DualKey(scrypt(password, salt; 2¹⁷, 8, 1) ‖ SHA-256(appTransactionID), "PRIVA-KEYFILE-v1", kind ‖ H)

* **Password:** the Priva password at the time of saving, stretched exactly like F2 (128 MiB), so a stolen file costs
  an attacker as much per guess as a backup. In Settings the password is checked against the vault (same failure
  counter as the lock screen) so a typo can't produce a file that never opens.
* **Apple Account:** StoreKit's `appTransactionID`, one per Apple Account that bought Priva, the same on every iPhone
  and after reinstalling. The file opens only in Priva on that Apple Account; a copy of the file plus the password
  isn't enough on someone else's iPhone. The ID is read on the phone and never sent anywhere for this (development
  builds use the simulated purchase).
* Restoring: *Open my Backup Key file* fills the 24 words, using the password already typed for the backup; *Open my
  Recovery Key file* (sign back in, forgot-password reset) asks for the file's password.
* **What it doesn't solve:** a forgotten password. The file needs the password it was saved with, so it helps with a
  lost or replaced iPhone or a changed Face ID, not with a forgotten password. That still needs the words on paper.
  After a password change, save a new file.
* Wrong password, other Apple Account or any changed byte give one indistinguishable error; a recovery file can't be
  opened as a Backup Key file or vice versa (the kind is bound into the key and the authenticated data); headers asking
  for more than 2¹⁸ rounds are refused before memory is reserved (KeyFileTests).

## 8. Restore: before any sign-up, on any iPhone

The first screen offers **Create new account** or **Restore from backup** (and, for someone without a backup,
*Use my recovery phrase*). A restore needs no sign-up: the backup *is* the account.

1. **Search for backup.** Priva looks in **iCloud Drive** (placeholders for files not yet on this iPhone are
   downloaded, waiting up to 10 s), **this iPhone**, and **received files**: a backup AirDropped or opened from
   Files/Mail lands in Priva's inbox (`Documents/Inbox`; Priva declares the `com.sanketdesai.priva.backup` type). The same
   backup found twice is listed once. **Nothing is picked automatically**: every backup is listed newest first
   with date, size and key hint, and the user chooses. **Browse Files…** is always there (and is the main action
   when nothing was found). *Settings › Backup › Save a copy…* makes the copy you AirDrop or keep on a drive.
2. **Unlock**: the 24-word Backup Key + the Priva password; the iCloud Keychain factor is read automatically, so
   a different Apple Account fails here. Wrong attempts slow down (30 s after 3, then 1 min, 5 min, 15 min, 1 h),
   counted in the Keychain so deleting and reinstalling Priva doesn't reset them. Even the *right* answer waits
   while a delay is in force, so the delay reveals nothing.
3. Everything is decrypted into a **staging folder**; the phone is untouched. The summary shows the account,
   the **authenticated** date and counts; it warns if the backup is a week or more old, or if a newer backup with
   the same key was found (rollback).
4. **Restore with Face ID.** First the App Store purchase is checked (the new username needs an anonymous token:
   the same one-time, unlinkable token as sign-up). Then the vault is created for this iPhone's Secure Enclave and
   face, with the backup's password as this iPhone's password, and the data folder is swapped in with directory
   renames (rolled back if anything fails).
5. **New keys, new username.** The restored account gets a fresh identity (new seed) and a new random username,
   registered in the directory (`ucommit` + keys). The server can't link it to the old row: different keys,
   different revocation hash, and the old username is removed 10 min – 6 h later (random), so the two changes
   aren't adjacent. Every username change is reflected in the directory: new row on registration, old row removed.
6. **Friends and groups follow automatically.** The restored iPhone sends every friend and fellow group member a
   friend request *from the new username* carrying a **move proof**: a hybrid (Ed25519 + ML-DSA-65) signature by
   the **old** identity key over `(old username, new username, new keys, recipient, time)`. The friend checks it
   against the key they pinned for the old username, checks the new keys in the directory, and moves the
   conversation, nickname, timer and group roles over: with a system message and "verified" reset, because the
   keys changed. Group hosts forward the proof in the roster so every member can check that a roster change is a
   move, not a swap. Groups the restored iPhone hosted continue with a new epoch (a backup may be older than the
   group).
7. **The old iPhone is told.** A notice sealed with the old announce key and signed with the old identity goes to
   the old iPhone's inbox. If it still runs Priva it shows *Your account moved*, goes offline and offers to erase
   itself. Only whoever holds the account's keys can send it.
8. The old keys are kept in the restored store only until the move is announced, then deleted. The recovery phrase
   changes with the keys (the summary says so); the Backup Key stays the same, so backups simply continue.

**A second restore of the same backup** (someone else with the file, the 24 words, the password and the Apple
Account) can't pass itself off: friends remember where @old moved; a second valid move for the same account is
shown as a red security warning and never followed automatically.

## 9. Attacker journeys (each one is a test)

| Attacker has | Result | Test |
|---|---|---|
| The backup file (Apple, iCloud breach, stolen laptop) | Nothing. No plaintext, not even the username; needs F1 + F2 + F3 | `testAttackerWithOnlyTheFileLearnsNothing` |
| File + Apple ID password | Nothing: F3 needs a trusted device's passcode; F1 and F2 are unknown | (F3 by design) |
| File + Backup Key (found the paper) | Nothing: wrong password → `wrongKey`, ≈1.5 s per guess | `testAttackerWithTheBackupKeyButNotThePasswordFails` |
| File + Backup Key + Priva password, another Apple Account | Nothing: `needsKeychainFactor` or `wrongKey` | `testAttackerWithKeyAndPasswordButAnotherAppleAccountFails` |
| Edits the header to cheapen the KDF | File no longer opens | `testLoweringThePasswordCostInTheHeaderIsDetected` |
| Knows the public backup key, plants a forged backup | The owner's restore rejects it; forging needs the password | `testForgedBackupWithoutThePasswordCannotBePlanted` |
| Near-miss / typo'd / reordered words | Rejected by checksum, or a different key | `testNearMissBackupKeysAreRejected` |
| Swaps in an older genuine backup (rollback) | Opens, but the list and summary show its date and contents | `testOlderGenuineBackupIsDistinguishableByDate` |
| Garbage, empty, huge length fields, future version | Refused cheaply, no large allocation | `testMalformedFilesAreRefusedCheaply` |
| Modified / truncated / reordered / spliced / duplicated frames | Rejected before any data is used | `BackupTests.testTamperingAnywhereIsRejected` |
| Decompression bomb, path-traversal media IDs | Refused (`tooLarge`, `corrupted`) | `BackupTests.testDecompressionIsBounded`, `testImporterRejectsPathTraversalMediaIDs` |
| Someone else's face at the restore step | Restore does not run (verified in the simulator: *Face Not Recognized*) | UI journey |
| Guesses passwords on the victim's unlocked iPhone | 30 s after 3 misses, up to 1 h; survives reinstalling; even the right answer waits | `RestoreSecurityTests.testWrongKeyAttemptsSlowDownAndSurviveAReinstall` |
| Edits the file's (plain) header date so an old backup looks new | Listed with the fake date, but the header is authenticated: it won't open | `RestoreSecurityTests.testAForgedDateInTheFileHeaderIsCaughtWhenOpening` |
| Drops junk or a symlink named `.privabackup` into the inbox | Not listed; only files with a valid header, and those still need every factor | `RestoreSecurityTests.testSearchFindsEveryBackupNewestFirstAndNeverPicksOne` |
| All factors, restores the backup *after* the owner did | Friends see a red warning; nothing follows | `RestoreJourneyTests.testTheSameBackupRestoredASecondTimeIsFlaggedNotFollowed` |
| All factors, restores *before* the owner | The owner's old iPhone is told at once (*Your account moved*); friends see "restored from a backup" and keys changed | `RestoreJourneyTests.testTheOldIPhoneIsToldItsAccountMovedAndGoesOffline` |
| A friend forges "Alice moved to me", or replays a proof made for someone else | Rejected: the proof must verify with Alice's pinned key and name its recipient | `RestoreJourneyTests.testAForgedMoveIsIgnoredAndTheFriendshipIsUntouched` |
| A group host swaps a member and labels it a restore | Shown as a leave + join: only the member's old key can sign a move | `RestoreSecurityTests.testOnlyAMoveSignedByTheMembersOldKeysIsShownAsARestore` |
| All three factors + a trusted device of the user | Can restore: the user is fully compromised at that point | residual |
| Priva's servers | Never see backups, keys or even their existence | by design |

**Residual risks.** Rollback to an older genuine backup can't be prevented cryptographically without a server,
but it is always visible to the user. A user who stores the 24 words *and* the password together, and whose
Apple Account is also compromised, has lost all three factors; the planned passkey-PRF factor (F4) closes that
gap once the app is signed with a Team ID.

## 10. Measured

| | |
|---|---|
| 5,000 messages | 1,085 KiB JSON → 256 KiB file (compressed, then padded to 64 KiB) |
| 20,000 messages + 64 MB media | written in 0.39 s, restored in 2.3 s, +72 MB peak memory |
| Live journey (3 phones, a group, a photo) | backup in 7 ms, staged restore in 1.4 s |
| New-iPhone journey (2 years / 1,500 messages, 3 friends, 2 groups) | all friends followed the new username 9.4 s after unlocking; groups relayed 1.8 s later |
