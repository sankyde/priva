# Priva vs. the attacks that hit other messengers

What went wrong in Signal, WhatsApp, Threema, Matrix, Telegram, Session, iMessage and others, checked
against Priva one by one. **Status** is what we found in Priva before this review; **now** is after the
fixes. Every "tested" row is an automated test.

Severity: 🔴 high · 🟠 medium · 🟡 low · ⚪ not applicable.

## What the server is for (and what it never sees)

| Server piece | Holds / carries | Never |
|---|---|---|
| Directory table | one row per user: a **one-way hash** of the username + that user's public keys (needed so a new friend can encrypt to you), status, lease week | the username itself, names, friends, messages |
| Purchases table | a **keyed hash** of the App Store transaction ID + monthly counters (limits new usernames per purchase) | any link to a username (tokens are blind-signed) |
| Realtime (rendezvous) | sealed, padded "how to reach me" notes so two phones behind routers can set up the direct connection; not stored | messages, files, calls, group traffic, sender or recipient names |

Messages, files, photos, calls and groups go phone to phone over encrypted WebRTC. Some rendezvous is unavoidable
for phone-to-phone apps (phones have no public address), but it only carries encrypted connection set-up.

## 1. Messages and encryption

| Attack (where it happened) | Priva status → now | Evidence |
|---|---|---|
| **Compression side channel in backups:** the attacker injects text, watches the backup's size and recovers secrets (Threema 2023, key recovered; WhatsApp/Signal "injection attacks" 2024) 🟠 | Vulnerable in principle (one compression context mixed all chats) → **fixed**: one context per conversation, contacts frame uncompressed, deterministic encoding | `AttackSurfaceTests.testBackupCompressionNeverMixesConversations` (2×2 experiment: size effect independent of the secret) |
| **Replay / reorder / drop by the server** (Threema 2023, Session 2026) 🟠 | Not vulnerable: messages never go through the server; the signalling that does is sealed, timestamped and replay-cached | `WireSecurityTests` (replays after a restart change nothing), `CryptoTests.testFrameCipherOrderingAndReplay` |
| **Key substitution by the server** (Session 2026; any key directory at first contact) 🟠 | Existing friends: a "new keys" request looked normal and could be auto-accepted → **fixed**: flagged, warned, never automatic. First contact: detectable by security code | `MITMSecurityTests` |
| **Cross-protocol key reuse / "Kompromat"** (Threema 2023) 🟡 | Not vulnerable: separate keys and domain-separated derivations per purpose (signalling, requests, sessions, media, backup, directory) | code review |
| **Prekey depletion degrading forward secrecy** (WhatsApp "Prekey Pogo" 2025) ⚪ | No prekeys: every session uses fresh post-quantum encapsulations while both phones are online. The *first* friend request is sealed to long-term keys (documented) | design |
| **Plaintext copies kept server-side** (TeleMessage, Signal clone, 2025) ⚪ | Nothing is stored server-side; proven on the wire | `WireSecurityTests.testNothingReadableLeavesThePhoneOrRestsOnDisk` |

## 2. Calls

| Attack | Priva status → now | Evidence |
|---|---|---|
| **Caller forces the callee to transmit before answering** (Signal, Duo, Messenger, JioChat, Mocha, 2019–21) 🔴 | Not vulnerable: **0 packets** leave the callee while ringing, after declining, or after hanging up, even when a modified caller renegotiates media | `LiveAttackTests.testACallerCannotSwitchOnTheCalleesMicOrCamera` |
| **Group call auto-starts the host's mic/camera** (FaceTime group bug, 2019) 🔴 | Not vulnerable: the host rings first | `GroupEndToEndTests.testAdversarialGroupAbuseIsRefused` |
| **A third party fakes or ends someone else's call** 🟡 | Call messages weren't checked against the sender → **fixed** (only the friend in the call counts) | `LiveAttackTests.testAnotherFriendCannotSpoofOrEndSomeoneElsesCall` |
| **A relay or SFU can see media** 🟠 | Not vulnerable: frames are end-to-end encrypted above DTLS-SRTP (with the wrong key, 0 frames decode) | `WireSecurityTests.testCallMediaIsEndToEndEncryptedAboveTheTransport` |
| **Malformed RTP/RTCP → code execution** (WhatsApp CVE-2019-3568) 🟠 | Only *friends* can open a media session; the parsing is WebRTC's (kept updated). Residual risk shared by every WebRTC app | design |

## 3. Zero-click media and deceptive content

| Attack | Priva status → now | Evidence |
|---|---|---|
| **Malicious image parsed without a tap** (FORCEDENTRY/GIF+JBIG2, BLASTPASS/WebP, Triangulation) 🔴 | Thumbnails from any friend or group member were decoded automatically by `UIImage(data:)`, which accepts every format → **fixed**: `SafeImage` accepts only JPEG/PNG/HEIC by their bytes, checks the pixel budget in the header, downsamples | `AttackSurfaceTests.testReceivedImagesDecodeOnlySafeFormatsWithinBudget`, `LiveAttackTests.testPoisonedMediaFromAFriendIsNeverDecoded` |
| **Decompression bombs** 🟠 | A 3.6-gigapixel header is refused in < 1 ms; backups are bounded (64 MiB per frame) | same tests, `BackupTests.testDecompressionIsBounded` |
| **File disguised with a right-to-left override** (Telegram "EvilVideo" 2024) 🟠 | Names were shown verbatim → **fixed**: `TextSafety` strips bidi and invisible characters from file names, display names, group names and member names | `AttackSurfaceTests.testDeceptiveFileAndDisplayNamesAreNeutralised` |
| **Location in photos and videos** 🟠 | Not vulnerable: photos are re-encoded with no EXIF/GPS/camera model; videos have their location and model removed | `AttackSurfaceTests.testPhotoMetadataAndLocationAreStripped`, `.testVideoLocationIsStripped` |
| **Link previews leaking IP or fetching content** (Mysk 2020) ⚪ | No link previews and no automatic fetching of anything | code review |
| **CDN cache geolocation via attachments** (Signal/Discord 2025) ⚪ | Attachments go peer-to-peer; the app never fetches attacker-chosen URLs | design |
| **Path traversal in received file names** 🟠 | Not vulnerable | `AttackSurfaceTests`, `BackupTests.testImporterRejectsPathTraversalMediaIDs` |

## 4. Metadata and tracking

| Attack | Priva status → now | Evidence |
|---|---|---|
| **"Careless Whisper": silent pings reveal when you're online** (WhatsApp, Signal, 2024) 🟠 | Not vulnerable to strangers: a stranger's request or junk gets **no automatic response**; inbox topics derive from a secret only friends learn. Friends can see when you're online (optional setting) | `LiveAttackTests.testAStrangerGetsNoAutomaticResponseFromYourPhone` |
| **Account enumeration** (WhatsApp 3.5 billion, 2025) 🟠 | Not practical: random usernames (46 bits); each guess costs ~0.5 s of memory-hard hashing, so enumeration takes ~1.3 million CPU-core years | `AttackSurfaceTests.testGuessingUsernamesIsTooExpensiveToEnumerate` |
| **Ghost member added to a group** (WhatsApp 2018 "More is Less", Matrix 2022) 🟠 | Members weren't told when the host added someone → **fixed**: every member works out joins and leaves locally and says so in the chat | `LiveAttackTests.testEveryMemberSeesWhenSomeoneIsAdded` |
| **Message previews stored in the iOS notification database** (FBI recovering deleted Signal messages, 2026) 🔴 | Not vulnerable: Priva posts **no** system notifications, so nothing lands in iOS's notification store | code review |
| **IP address visible to peers via WebRTC/STUN** 🟠 | By design for peer-to-peer; hidden with your own relay server (onion mode then forces relay-only); documented in the app | `OnionModeTests` |

## 5. The phone itself

| Attack | Priva status → now | Evidence |
|---|---|---|
| **Biometric bypass by hooking `evaluatePolicy`** (OWASP MASTG, Frida/Objection) 🔴 | Not vulnerable on iPhone: the vault secret is computed *inside the Secure Enclave* with a biometry-bound key; a faked "success" yields no key | design (the simulator can't enforce this; test skips there) |
| **Adding your own face to someone's phone** 🟠 | Changing enrolled faces invalidates Priva's key; the attacker gains nothing | design |
| **App-switcher snapshot shows content** 🟠 | The cover didn't reach sheets and full-screen screens (media viewer, Backup Key) → **fixed**: a top-level window above everything | simulator check |
| **Screen recording / AirPlay / capture cable** 🔴 | The banner said "content hidden" but **nothing was hidden** → **fixed**: everything, including sheets, is covered while the screen is captured, including at launch | simulator check |
| **Clipboard leaking to other devices** 🟡 | Not vulnerable: copies are local-only and expire after 2 minutes | code review |
| **Third-party keyboards logging keystrokes** 🟠 | Blocked app-wide | code review |
| **iOS keyboard learning chat words** (forensic `dynamic-text.dat`) 🟡 | Open. Apple's keyboard learns words, as in Signal and WhatsApp on iOS. Possible opt-in "private keyboard" later | recommendation |
| **Logs and debug output in release builds** 🟡 | Not vulnerable: all logging and test taps are compiled out of release builds | code review |
| **Deep links, web views, URL-scheme hijacking** ⚪ | None exist | code review |
| **Lockout bypass by changing the clock** 🟡 | Possible, but every password attempt also needs the owner's Face ID, and "erase after 10" counts attempts, not time | documented |

## 6. Backups, recovery words and passwords

| Attack | Priva status → now | Evidence |
|---|---|---|
| **Phishing for the recovery key** ("Signal Support" waves 2025–26; FBI warning) 🟠 | → **hardened**: every screen that shows secret words says Priva will never ask for them; a friend can't display as "Priva Support" (falls back to the @username) | `AttackSurfaceTests` (names) |
| **Weak password protecting the backup / export** (Threema ID export 2023) 🟠 | Not vulnerable: a 256-bit Backup Key is required as well as the password; ~1.4 s memory-hard cost per guess | `BackupJourneyTests` attacker journeys |
| **Backup readable with the cloud account alone** (WhatsApp pre-2021) 🔴 | Not vulnerable: three factors (Backup Key, password, iCloud Keychain secret) | `BackupJourneyTests` |
| **Rollback to an older backup** 🟡 | Possible by design; always visible (date and contents shown before restoring) | `BackupJourneyTests.testOlderGenuineBackupIsDistinguishableByDate` |
| **Backup Key stored on the phone** 🟠 | Not vulnerable: its words and bytes are found nowhere on the phone | `BackupStressTests.testTwentyBackupsInARowAndTheKeyIsNeverStored` |
| **Screenshot or recording of the words** 🟠 | Screenshot warning, blurred until tapped, and now fully hidden while the screen is recorded or mirrored | simulator check |
| **Linked-device QR phishing** (Signal 2025, Russian intelligence) ⚪ | Priva has no linked devices; a scanned QR only fills in a username or checks a security code | design |

## 6b. Signing in, restoring and new devices (researched September 2026)

| Attack / incident | Priva status → now | Evidence |
|---|---|---|
| **SIM swap / stolen SMS code takes over the account** (Signal via Twilio 2022; WhatsApp "I sent you my code by mistake" scams 2024–26) 🔴 | Not applicable: no phone number, no SMS code. An account is its keys; getting it back needs the Backup Key + password + iCloud Keychain (or the recovery phrase) | design |
| **Re-registration keeps old secrets valid / account wiped and re-claimed after a lock expires** (Signal Registration Lock's 7-day window) 🟠 | A restore creates **new keys and a new username**; old backups and the old recovery phrase become useless for impersonation once friends have moved (they no longer hold the old key as a friend) | `RestoreJourneyTests` |
| **Silent device switch** (restore keeps identity keys, contacts see no change) 🟠 | Friends always see "restored their account from a backup", keys marked changed, verification reset: like WhatsApp's security-code notice | `RestoreJourneyTests` main journey |
| **Attacker restores a stolen backup** 🔴 | Needs all three factors. If they manage it anyway: the owner's old iPhone is told immediately; a second restore of the same backup is flagged to every friend and never followed | `testTheOldIPhoneIsToldItsAccountMovedAndGoesOffline`, `testTheSameBackupRestoredASecondTimeIsFlaggedNotFollowed` |
| **Forged "I moved" message from a friend or group host** 🔴 | Rejected: a move must be signed by the old identity key the friend pinned, name its recipient and be under 30 days old | `testAForgedMoveIsIgnoredAndTheFriendshipIsUntouched`, `testOnlyAMoveSignedByTheMembersOldKeysIsShownAsARestore` |
| **Malicious backup restore: symlinks / path traversal** (iOS CVE-2025-24104, Sparserestore CVE-2024-44258) 🔴 | Not vulnerable: a backup is one authenticated stream, never a file tree; media names must be UUIDs; picked files are copied as regular files; symlinks and junk in the inbox are never listed | `BackupTests.testImporterRejectsPathTraversalMediaIDs`, `RestoreSecurityTests` search test |
| **Keychain items survive app deletion** (stale tokens reused by the next person) 🟠 | A fresh install never silently reuses them: a surviving vault means *Welcome back* with an explicit choice; leftovers are wiped except the revocation record, the restore-attempt counter and the tour flag | `AppModel.init`, `RestoreSecurityTests` |
| **Password guessing on a found phone** 🟠 | Vault: optional erase after 10; restore: escalating delays kept in the Keychain across reinstalls | `testWrongKeyAttemptsSlowDownAndSurviveAReinstall` |
| **Cloud provider can read the backup** (UK ADP withdrawal 2025: iCloud Drive readable by Apple) 🔴 | Not vulnerable: Apple can hand over the file but not the 24 words or the password; the third factor lives in end-to-end-encrypted iCloud Keychain | `testAttackerWithOnlyTheFileLearnsNothing` |
| **Rollback to an older backup** 🟡 | Shown: authenticated date, a warning at 7+ days and when a newer backup with the same key exists; forged header dates don't open | `testAForgedDateInTheFileHeaderIsCaughtWhenOpening` |
| **Recovery-key phishing** 🟠 | Screens never ask for the words outside a restore Priva started; "Priva will never ask for them" on every secret screen | `AttackSurfaceTests` |

Found by these journeys and fixed: a member who met someone in a group (hidden successor link) could never add
them as a friend: the request said "already friends" and the other side re-paired silently.
`GroupFeatureE2ETests.testFellowGroupMembersCanBecomeRealFriends`.

## 7. Server and payments

| Attack | Priva status → now | Evidence |
|---|---|---|
| **Reading or changing the server with the app's public key** 🔴 | Not vulnerable: no table readable, no service function callable, only owner-signed directory changes | `ServerSurfaceSecurityTests` |
| **Forged or modified App Store purchase** 🔴 | Not vulnerable: Apple's root certificate is pinned, the chain and Apple's certificate markers are checked, the ES256 signature is verified, the bundle ID must match | `ServerSurfaceSecurityTests` (fake transaction refused), code review |
| **"Developer purchases" left on** 🔴 | **Currently ON** (needed for simulators): anyone who finds this path gets free usernames. **Must be switched off before launch** | `ServerSurfaceSecurityTests` reports it |
| **Sandbox/TestFlight receipts accepted in production** 🟡 | Accepted (only Priva's own TestFlight testers can produce them). Recommend a switch to refuse them after launch | code review |
| **Refund after registering** 🟡 | A refunded buyer keeps their username (tokens are blind, so they can't be linked back, by design). Recommend blocking *further* tokens after a refund notification | recommendation |
| **Family Sharing** 🟡 | If enabled in App Store Connect, family members get their own purchases → their own usernames | decide in App Store Connect |
| **Realtime quotas** (free tier: 200 connections, 100 messages/s) 🟠 | Fine for testing, too small for launch (it would cap how many people can be online) | plan upgrade before launch |

## 8. Load and stress (does it hold up?)

Real engines over the live network, many phones in one test process (opt-in: `TEST_RUNNER_PRIVA_STRESS=1`).

| Scenario | Result |
|---|---|
| One person, **60 friends** all messaging at once (10 each) | all 600 delivered, per-friend order intact; 60 simultaneous connections; 25–90 s (handshake back-off under a 60-way burst); replies to all 60 in 0.13 s; 10 photos at once in 1.9 s; no memory growth |
| **41-person group** relayed by one host, everyone posting at once | 205 posts → **8,200 deliveries in 39.5 s** (~208/s); identical order on all 41 phones; the host's queue peaked at ~8,000 and drained |
| 10 members offline while 40 posts arrive | caught up in 5 s after coming back |
| Group call size limit | 8 in a voice call; the 9th is turned away, the call carries on |
| Backup of 100k messages, 300 friends, 40 groups, 128 MB media | written in 9.3 s (+7 MB memory), restored in 13 s, **byte-identical** |
| Backup while 5,000 messages arrive | no duplicates, nothing lost |
| 20 backups back to back | 0.7 s total; only the newest 2 kept |

**Bugs the load tests found (fixed):**
1. **Groups larger than ~20 broke completely.** Every membership change sent each member a roster carrying every
   member's public keys (~11 KiB each). Past 256 KiB a WebRTC message isn't just refused, it **kills the connection**.
   Now:
   - large encrypted messages are fragmented (8 MiB cap, bounded reassembly);
   - rosters carry only the keys a member doesn't have yet;
   - bursts of changes are coalesced.
2. **Dropped rendezvous messages were silently lost.** A network blip or rate limit cost a whole handshake timeout;
   they're now retried with back-off.
3. **No ceiling on simultaneous connections.** Each connection holds several sockets and iOS's default open-file limit
   is low. The limit is now raised at launch, and connections are capped at 128 (least-recently-active idle ones make
   room).

**Launch capacity note:** Supabase's free tier allows 200 concurrent realtime connections and 100 rendezvous
messages per second project-wide. Setting up one connection costs ~10 messages, which caps the whole app at about
10 new connections per second. Upgrade (Pro: 500/s; Pro without spend cap: 2,500/s) before launch.

## Sources

- Three Lessons From Threema (Paterson, Scarlata, Truong, USENIX Security 2023): https://breakingthe3ma.app/ · https://www.usenix.org/system/files/usenixsecurity23-paterson.pdf
- Injection Attacks Against End-to-End Encrypted Applications (2024): https://arxiv.org/pdf/2411.09228
- Practically-exploitable Cryptographic Vulnerabilities in Matrix (2022): https://nebuchadnezzar-megolm.github.io/
- More is Less: group chats in Signal, WhatsApp and Threema (Rösler, Mainka, Schwenk 2018): https://www.researchgate.net/publication/326280602
- Careless Whisper: silent delivery receipts (RAID 2025): https://arxiv.org/pdf/2411.11194
- Hey there! Enumerating three billion WhatsApp accounts (NDSS 2026): https://arxiv.org/pdf/2511.20252
- Prekey Pogo: WhatsApp's handshake (WOOT 2025): https://arxiv.org/pdf/2504.07323
- Practical attacks on Session (2026): https://eprint.iacr.org/2026/1247
- Logic bugs letting callers hear callees (Project Zero, 2021): https://thehackernews.com/2021/01/google-discloses-flaws-in-signal-fb.html
- WhatsApp VoIP buffer overflow CVE-2019-3568: https://www.facebook.com/security/advisories/cve-2019-3568
- FORCEDENTRY: https://en.wikipedia.org/wiki/FORCEDENTRY
- Telegram EvilVideo (2024): https://www.welivesecurity.com/en/eset-research/cursed-tapes-exploiting-evilvideo-vulnerability-telegram-android/
- Link previews (Mysk 2020): https://mysk.blog/2020/10/25/link-previews/
- Cloudflare cache geolocation (2025): https://gist.github.com/hackermondev/45a3cdfa52246f1d1201c1e8cdef6117
- FBI recovering Signal messages from the iPhone notification database (2026): https://www.404media.co/fbi-extracts-suspects-deleted-signal-messages-saved-in-iphone-notification-database-2/
- Signal linked-device QR phishing (Google TAG, 2025): https://thehackernews.com/2025/02/hackers-exploit-signals-linked-devices.html
- Signal backup recovery-key phishing (2026): https://www.bleepingcomputer.com/news/security/fbi-russian-hackers-now-target-signal-backup-recovery-keys/
- TeleMessage breach (2025): https://techcrunch.com/2025/05/05/telemessage-a-modified-signal-clone-used-by-us-government-officials-has-been-hacked/
- WhatsApp end-to-end encrypted backups (HSM vault): https://engineering.fb.com/2021/09/10/security/whatsapp-e2ee-backups/
- OWASP MASTG, bypassing biometric authentication: https://mas.owasp.org/MASTG/techniques/ios/MASTG-TECH-0135/
- OWASP MASTG, keyboard cache: https://mas.owasp.org/MASTG/tests/ios/MASVS-STORAGE/MASTG-TEST-0055/
- WhatsApp "view once" bypasses (2024): https://techcrunch.com/2024/09/09/bug-lets-anyone-bypass-whatsapps-view-once-privacy-feature/
- Supabase Realtime limits: https://supabase.com/docs/guides/realtime/limits
- Signal Registration Lock and the 7-day window: https://support.signal.org/hc/en-us/articles/5440120029082-Re-registering-using-your-Signal-PIN · https://www.privacyguides.org/articles/2022/11/10/signal-number-registration-update/
- Signal accounts taken over through the Twilio SMS breach (2022): https://www.vice.com/en/article/how-a-third-party-sms-service-was-used-to-take-over-signal-accounts/
- Signal Secure Backups (recovery key, restore only at setup): https://signal.org/blog/introducing-secure-backups/ · https://support.signal.org/hc/en-us/articles/9708267671322-Signal-Secure-Backups
- WhatsApp security-code change notices: https://faq.whatsapp.com/1524220618005378/
- WhatsApp six-digit-code account hijacking (2026): https://www.forbes.com/sites/daveywinder/2026/08/06/whatsapp-scam-bypasses-passwords-using-6-digit-code-to-access-accounts/
- iOS backup restore symlink bug CVE-2025-24104: https://nvd.nist.gov/vuln/detail/CVE-2025-24104
- Sparserestore / CVE-2024-44258 (path traversal in restores): https://gist.github.com/leminlimez/c602c067349140fe979410ef69d39c28 · https://cvefeed.io/vuln/detail/CVE-2024-44258
- Keychain items surviving app deletion: https://developer.apple.com/forums/thread/36442 · https://tdcolvin.medium.com/this-ios-security-flaw-needs-to-be-addressed-in-every-app-e2b7d8b6cd95
- Apple Advanced Data Protection withdrawn in the UK (2025): https://support.apple.com/en-us/122234 · https://www.privacyguides.org/articles/2025/02/28/uk-forced-apple-to-remove-adp/
