# Audit fix status

What was done about each finding in [security.md](security.md), [state-and-correctness.md](state-and-correctness.md)
and [ui-ux.md](ui-ux.md). **Fixed** means changed in code with a test that fails without the fix (test names in
brackets). **Partly** says what is left. **Owner** means it needs a deploy or a decision from the owner.

## Owner actions

| | What | Why |
|---|---|---|
| 1 | Deploy the relay Worker: `scripts/setup_cloudflare.sh` (put `CF_TURN_KEY_ID` / `CF_TURN_KEY_API_TOKEN` in `.env` first) | SEC-05 (TURN behind the relay pass), SEC-06 (per-message cost, no storage for unowned topics), SEC-24. Until then the app falls back to the old open function, so relay and Tor mode keep working. |
| 2 | Then delete the open function: `scripts/setup_supabase.sh` offers it once the relay serves `/turn` (or `npx supabase functions delete turn --project-ref $SUPABASE_PROJECT_REF`) | SEC-05: today anyone with the app's public key can mint TURN credentials (`RelayTests.testTURNCredentialsNeedARelayPass` fails until 1 and 2 are done). |
| 2b | Redeploy the other functions: `scripts/setup_supabase.sh` | SEC-24: bodies without a length are refused before they're read (`_shared/util.ts`). |
| 2c | Fill in the secrets `.env` doesn't have yet: `SUPABASE_DB_URL`, `CF_TURN_KEY_ID`, `CF_TURN_KEY_API_TOKEN` (they were never in the code). Then `scripts/setup_supabase.sh --check` and `scripts/setup_cloudflare.sh --check` | The setup and launch scripts read them from `.env` now |
| 2d | Supabase › Project Settings › API Keys: disable the **legacy** anon (JWT) key, unless something outside Priva still uses it | The app uses only the publishable key; the legacy key is still enabled |
| 2e | Before publishing the source: choose a license (`LICENSE`), and publish from a **fresh repository** (one commit), not this history | History has no secrets, but it does carry the old hard-coded project ref, publishable key, Apple Team ID and Cloudflare account ID, and the device journeys' past phone and simulator IDs |
| 3 | Decide SEC-03, SEC-06 (per-day keys), SEC-07, SEC-13 (padding). SEC-02, SEC-04 and STA-24 are done (2026-10-16) | See "Decisions" below. |

## Decisions

- **SEC-02 · purchase ↔ username correlation.** **Done (2026-10-16).** Every call that carries the App Store
  proof happens together at "Purchase verified" (the token and the month's relay passes), so nothing purchase-related
  goes out when the username is registered minutes later, or after a restore. In Tor mode each purchase or
  registration call has its own Tor circuit, so they leave through different exits [RelaySecurityTests.
  testThePurchaseIsProvedOnlyAtThePurchaseCheck, OnionModeTests.testUnlinkableCallsLeaveThroughDifferentTorExits].
  Left: with very few sign-ups a day, an operator watching live could still guess by timing on a direct connection.
  Tor mode removes that.
- **SEC-03 · relay social graph.** One daily pass is shown with every send and listen, so the relay operator can
  group a day's topics per phone; inbox topics never change. Options: a fresh pass per connection (needs more passes
  per month), rotating inbox topics (a protocol change).
- **SEC-04 · recovery phrase moves friends silently.** **Done (2026-10-16).** Friends no longer follow a signed
  move at once. They wait 12 hours, or follow at once when the old iPhone confirms ("It was me"), or never when it
  says "It wasn't me": then they're warned, and the account carries on. The chat offers "Follow now" and "Not
  them". The old iPhone used to shut itself off; now it asks [RestoreJourneyTests.
  testTheOldIPhoneSaysItWasntThemAndFriendsDontFollow, testTheOldIPhoneConfirmsAndFriendsFollowAtOnce,
  testWithNoAnswerFriendsFollowAfterTheWait].
- **SEC-06 · stacked passes.** One purchase can ask for 160 passes all dated the same day (the day is inside the
  blinded token). Fix needs per-day signing keys on the issuer and the relay.
- **SEC-07 · App Attest.** Nothing proves requests come from the genuine app. Adding DCAppAttest needs a privacy
  review (it ties a device key to the purchase on the server).
- **SEC-13 · directory lookups.** Done now: no lookups for blocked people or hidden group links, and a friend last
  seen active is checked weekly instead of daily. Open: padding lookups with dummy commitments or sending them over
  Oblivious HTTP.
- **STA-24 · calls drop on a network change.** **Done (2026-10-16).** A link whose path dies (Wi-Fi ↔ cellular)
  keeps its session and call. The initiator sends new ICE credentials over the rendezvous plane, sealed with the
  session's keys; the responder answers; the call carries on (0.85 s in the test). It gives up and reconnects as
  before after 25 s [NetworkChangeTests]. On the iPhone: XD-26, manual.

## Security

| ID | Status |
|---|---|
| SEC-01 | Fixed [GroupCallE2ETests.testAnEndedCallRequestNeverLetsTheHostStartTheMembersMic] |
| SEC-02 | Fixed (see Decisions) [RelaySecurityTests.testThePurchaseIsProvedOnlyAtThePurchaseCheck, OnionModeTests.testUnlinkableCallsLeaveThroughDifferentTorExits] |
| SEC-03, 07 | Owner decision (SEC-07: recommended not to add) |
| SEC-04 | Fixed (see Decisions) [RestoreJourneyTests.testTheOldIPhoneSaysItWasntThemAndFriendsDontFollow and two more] |
| SEC-05 | Fixed in code (Worker `/turn` behind a pass, 1 h credentials, 10/min per pass, Supabase function removed); **needs owner deploy** [RelayTests.testTURNCredentialsNeedARelayPass] |
| SEC-06 | Partly: sends count per 16 messages, no storage for unowned topics (needs deploy). Per-day keys: decision. |
| SEC-08 | Fixed [WireSecurityTests.testReplayingAnAcceptedFriendRequestChangesNothing, testADeclinedRequestDoesNotComeBack] |
| SEC-09 | Fixed with STA-04 [GroupFeatureE2ETests.testAClaimWithAnOutdatedCharterIsRefused, testAQuietHostIsNotReplacedWhileItsDirectoryEntryIsActive, testAClaimTheMemberCouldNotConfirmIsAskedAboutAgain] |
| SEC-10 | Fixed [GroupFeatureE2ETests.testANewMemberCannotSyncHistoryFromBeforeTheyJoined] |
| SEC-11 | Mostly: a hidden group link is answered only while its owner hosts, may succeed, or is a member of a group we host; no presence to group links; unused links are deleted [GroupFeatureE2ETests.testARemovedSuccessorCannotReachMembers]. Left: relay-only ICE for group links (waits on the TURN deploy). |
| SEC-12 | Fixed: files over 100 MB or without free space wait for a tap; one stream per file and peer, 12 asks an hour; the host refuses uploads it has no room for [EndToEndTests.testE2ELargeFileTransfer, ProductionHardeningTests.testAFileItsSenderDeletedStopsBeingRequested] |
| SEC-13 | Partly (see Decisions) |
| SEC-14 | Open (directory lease week is public by design) |
| SEC-15 | Fixed: "not in backup" thumbnails go through SafeImage |
| SEC-16 | Open: revocation secret outside the vault key; username on the lock screen |
| SEC-17 | Fixed: "Relay calls" fails closed [RelayTests.testRelayCallsNeverGoDirectWithoutARelay] |
| SEC-18 | Mostly: showing the phrase, leaving and deleting the account need the password and Face ID. Left: restoring over the current account (Face ID only). |
| SEC-19 | Partly: the write-ahead log is checkpointed after expiry; messages with a timer stay out of backups. Left: plaintext timestamp columns, per-day keys. |
| SEC-20 | Open (key-file "Apple Account" factor wording) |
| SEC-21 | Fixed [AttackSurfaceTests.testImagesSentAsFilesLoseTheirLocation] |
| SEC-22 | Fixed: no system text selection on bubbles, purchase ID, username |
| SEC-23 | Fixed: the privacy manifest declares User ID (linked) and Purchase History (not linked) |
| SEC-24 | Fixed in code: no body without a length on the relay and the functions (needs deploy) |
| SEC-25 | Fixed: only Supabase responses adjust the protocol clock |
| SEC-26 | Fixed: look-alike Greek/Cyrillic letters folded before the brand check; attachment names go through the keyword filter [AttackSurfaceTests.testLookAlikeLettersDontImpersonatePriva] |
| SEC-27 | Fixed: a host-delivered post "from you" that this iPhone never sent is dropped [GroupFeatureE2ETests.testAHostCantPutWordsInAMembersMouthOrReopenALeftGroup] |
| SEC-28 | Owner, before launch: `allow_dev_purchases = false`, decide on Sandbox receipts (LAUNCH_CHECKLIST) |

## State and correctness

| ID | Status |
|---|---|
| STA-01 | Fixed [GroupFeatureE2ETests.testAnInviteAcceptedAfterTheHostRelaunchesStillJoins, testAPendingInviteSurvivesTheInviteesRelaunch] |
| STA-02 | Fixed [GroupFeatureE2ETests.testAGroupFileUploadedAcrossAHostRelaunchStillReachesMembers] |
| STA-03 | Fixed [GroupCallE2ETests.testAGroupCallSurvivesBackgroundingAndStopReleasesTheAudio] |
| STA-04 | Fixed (see SEC-09) |
| STA-05 | Fixed [GroupScaleProbeTests] |
| STA-06 | Fixed [ProductionHardeningTests.testDisappearingMessagesExpireOfflineAndLeaveNoPreview] |
| STA-07 | Fixed [ProductionHardeningTests.testOpeningAChatWithAThousandUnreadClearsTheBadge] |
| STA-08 | Fixed: (time, id) cursor, group chats page too [ProductionHardeningTests.testScrollingUpReachesTheFirstMessage] |
| STA-09 | Fixed: `fileGone` reply, transfers keep the link, "Delete for me" stops serving [ProductionHardeningTests.testAFileItsSenderDeletedStopsBeingRequested] |
| STA-10 | Fixed: background dials wait for the backoff, calls don't [ProductionHardeningTests.testBackgroundDialsWaitForTheBackoffButCallsDont] |
| STA-11 | Fixed [GroupFeatureE2ETests.testADisbandedGroupLeavesNoQueue] |
| STA-12 | Fixed: one revocation at a time, 30 s → 1 h backoff |
| STA-13 | Fixed: pass refills back off 1 min → 1 h; a used-up month waits for the next day |
| STA-14 | Fixed: the migration is saved before the vault says "registered" |
| STA-15 | Fixed: the lock screen says the data couldn't open and lets you retry |
| STA-16 | Fixed: Welcome back handles erase, lockout and not set up |
| STA-17 | Fixed: relay credentials retried in 30 s after a failure, and again once Tor is ready |
| STA-18, 19 | Fixed [WireSecurityTests.testAWithdrawnRequestCannotBeAccepted, ProductionHardeningTests.testRequestsOlderThan30DaysStopRetrying] |
| STA-20 | Fixed [WireSecurityTests.testABlockedGroupMemberGetsNoPresence] |
| STA-21 | Partly: transfer progress no longer rewrites threads. Left: per-thread observation. |
| STA-22 | Fixed: leftover-backup cleanup runs off the main thread |
| STA-23 | Fixed: a roster for a group you left is ignored [GroupFeatureE2ETests.testAHostCantPutWordsInAMembersMouthOrReopenALeftGroup] |
| STA-24 | Fixed (see Decisions) [NetworkChangeTests] |
| STA-25 | Fixed [ProductionHardeningTests.testRemovingAFriendDeletesAllTheirMedia] |
| STA-26 | Fixed: a call turns active on received media (inbound RTP), not data-channel bytes |
| STA-27 | Fixed: a refused chunk closes the link instead of stalling transfers |
| STA-28 | Partly: a member's renamed posts are rewritten off the main thread in one transaction. Left: `migrateConversation`, `reconnectAfterRestore`. |
| STA-29 | Fixed: dead settings removed; the name goes to friends a second after typing stops |
| STA-30 | Open: after a restore the new recovery phrase is only mentioned, not shown |
| STA-31 | Fixed: only a wrong key counts as a wrong password |
| STA-32 | Fixed: this user's own username hash is computed strictly (throws, retried later) instead of storing a random stand-in |
| STA-33 | Fixed: locking cancels a backup under way |
| STA-34 | Fixed |
| STA-35 | Fixed: a request the directory couldn't check gets through on its resend |
| STA-36 | Fixed: Contact equality covers every shown field |
| STA-37 | Fixed: one Tor-ready handler per owner |
| STA-38 | Fixed: relay passes cached in memory |
| STA-39, 41 | Open (Info) |
| STA-40 | Fixed: announcements every minute on the first day, then hourly |
| STA-42 | Fixed: SYSTEM_DESIGN, GROUPS_DESIGN, IDENTITY_DESIGN corrected |
| Dead code | Removed: no-op progress line, duplicate status, `BulkChannel.onOpen`, `localCandidateType`, `isValidGroup`; test-only `inboundStreams` and `ping(_:)` under DEBUG; misplaced comments |

## UI, UX and accessibility

| ID | Status |
|---|---|
| UX-01 | Fixed: `priva://add/<name>` opens Find with the name searched; Find has "Scan code" |
| UX-02 – 04 | Fixed (checked at AX5 on the iPhone 17e) |
| UX-05 | Fixed: confirmation to turn on, countdown from the 5th wrong password |
| UX-06 | Fixed: the report footer says it's sent from the user's email app |
| UX-07 | Fixed: amber instead of orange, `Theme.tint`, deep call-button fills, darker avatar pairs, darker mint |
| UX-08 | Fixed: contact tiles, chat rows, empty states, incoming call, chips, Appearance, Blocked, lock title, tour cards |
| UX-09 – 28 | Fixed |
| UX-29 – 45 | Fixed |

## Tests and coverage ([tests-and-coverage.md](tests-and-coverage.md))

| ID | Status |
|---|---|
| TST-02 | Fixed in the app: turning on Tor or "Relay calls" closes open connections and calls [RelayTests.testTurningOnRelayCallsClosesExistingConnections] |
| TST-03 | Fixed in the app: refused passes back off (10 min → 6 h), and the pass day follows the server's clock [RelayTests.testRefusedPassesDoNotBurnTheMonth, testThePassDayFollowsTheServerClockNotThePhones] |
| TST-07 | Partly: EndToEnd cleanup is awaited; CrossDevice revokes the phone account in a last test; the erase test puts relay passes and the dev purchase back. Left: local-only tests still register live users; `-PrivaReset` doesn't revoke. |
| TST-08 | Fixed: the KeywordFilter test runs (UnitModelTests), plus soft hyphen and full-width cases |
| TST-09 | Fixed: the ghost-member check looks for Dave by name |
| TST-10 | Mostly: pass-day boundary, onion no-relay case, backup media check. Left: idle-close test, free-tier budget wording, MARK labels, old simulator ids in scripts. |
| TST-11 | Mostly: STA-07 budget, STA-20 positive control (Bob alone in the window), large-file "no download under way". Found: the frame cryptor never reports decryption failures (`failureTolerance: -1`), so the call screen's quality dot can't show a key mismatch; the vacuous assertion was replaced by a metric. Left: one-write counters, failover lookup count, CrossDevice budgets. |
| TST-01 | Partly: a DEBUG URLProtocol seam (`PrivaAPI.debugProtocolClasses`) and offline NetworkFailureTests (5xx, timeout, malformed and empty directory answers, a server clock days off). Left: register/token/pass-issuer error mapping. |
| TST-06 | Partly: change password [ProductionHardeningTests.testChangingThePasswordNeedsTheCurrentOne]. Left: leave/delete (live) and AC-01/02 device journeys. |
| TST-04, 05, 12 – 23 | Open: CI and test plans, deterministic registration-retry and Face ID renewal tests, fuzzing, flood, media-memory and call-timeout tests (see the backlog in tests-and-coverage.md) |

## Memory (2026-10-15)

Checked by `MemoryLeakTests` (a full session, then the app's own lock path), the existing PerformanceJourney leak
tests, Apple's `leaks` tool (`scripts/memory_leaks.sh`) and the device journeys MEM-01–03.

| What | Result |
|---|---|
| **Every lock left the whole session in memory** (MEM-01 on the simulator phone: 6 engines, databases and relay sockets after 5 lock/unlock cycles) | Fixed. SwiftUI copies its environment, and with it the engine, into UIKit trait collections, which UIKit caches in long-lived views (the keyboard's keys, bar buttons, list cells, accessibility nodes); `heap` + `leaks --traceTree` showed those paths. Priva can't stop UIKit caching, so locking now *closes* the engine: the database closes and its keys go, the account keys are swapped for random ones, and messages, contacts, groups and backup settings leave memory. A shell UIKit still holds is empty [MemoryLeakTests.testALockedEngineHoldsNothingEvenIfSomethingKeepsIt] |
| Engine, database, relay socket, call/group/backup centres, transfer registry, connections after a full session and lock | All released [MemoryLeakTests.testEverythingASessionMadeIsGoneWhenPrivaLocks] |
| Heap across three unlock → use → lock rounds | +0.7 MB (budget 25 MB) [MemoryLeakTests.testRepeatedUnlocksDontGrowTheHeap] |
| `leaks` after a full session | 32 leaks, 3.7 KB, none in Priva: Apple VideoToolbox's encoder texture caches (≈ 1.5 KB per video call) and simulator-only Metal sampler states |
| Decoded photos kept while Priva sits in the background (auto-lock later) | Fixed: dropped on going to the background, with other chats' cached messages (MEM-03) |
| A huge file labelled as a photo decrypted whole into memory | Fixed: over 64 MB isn't decoded; the viewer says it can't show it [AttackSurfaceTests.testAHugeFileLabelledAsAPhotoIsNotDecodedWhole] |
| Thumbnail cache limited by count only (≈ 200 MB worst case) | Fixed: also capped at 48 MB |
| Seeing it on a phone | Settings › Diagnostics (DEBUG) shows the footprint, decoded photos and live objects (`LiveObjects`, no-op in Release) |

## Resilience, purchases and the source release (2026-10-15)

| Finding | Status |
|---|---|
| **A full iCloud failed the whole backup**, though it was saved on the iPhone; the last-backup date never moved, so the daily backup failed every day. iCloud off or signed out kept backups local without saying so when iCloud was still signed in | Fixed. Only the iPhone's copy can fail a backup; the backup screen says when the latest one is only on this iPhone, and why [BackupJourneyTests.testBackupsSurviveICloudGoingAwayAndReachItWhenItsBack] |
| **Every Face ID failure read "Face ID is unavailable"**: a lockout, Face ID not set up, Face ID off for Priva, no passcode. A lockout only needs the iPhone's passcode, but nothing said so | Fixed. Each says what to do (`BiometricGate.unavailableMessage`), on the lock screen and at sign-up [FaceIDFailureJourneys, simulator] |
| Servers down: nothing tested what phones do in an outage | Tested: Supabase down, relay down, both down, a group through an outage. Nothing lost or shown twice; recovery 8 s after the relay is back, 28 s after both [OutageTests] |
| **Anyone with the published source could mint development purchases** while `allow_dev_purchases` is on (before launch, and whenever it's switched on again for testing) | Fixed in code: a development purchase must be signed with the operator's `PRIVA_DEV_PURCHASE_KEY` (in `.env`, Debug builds only; `launch_check.sh` fails a Release build that carries it) [server_test.ts; ServerSurfaceSecurityTests.testRegistrationNeedsAnUnspentTokenAndAFreshUsername, which fails until the server is redeployed]. **Owner:** `scripts/setup_supabase.sh` |
| **A backup could write fine and never restore.** The reader refuses frames over 4 MB, but the writer put every non-message record (contacts, requests, up to 100,000 calls, settings, group queues) into one frame without checking. An account with years of history got a backup the restore called "corrupted" (found by XD-21: the simulated friend's account, after many runs, crossed it) | Fixed. Records that don't fit one frame are split across several (the reader already merges them), one frame as before when they fit; a single record too big for any frame fails the backup as "too large" instead of writing it [BackupTests.testABackupBiggerThanOneFrameStillRestores, testOneRecordTooBigForAnyFrameFailsTheBackup] |
| Deployment details (project, keys, team, accounts, device IDs) were in the source | Moved to `.env` (`.env.example` documents it). Real secrets were never in the code or history |

## Release readiness: backend and app (2026-10-16)

| ID | Finding | Status |
|---|---|---|
| REL-01 | **The App Store would flag the build:** Priva checks free disk space (the storage-full protection) with an API Apple requires a declared reason for, and the privacy manifest didn't declare it (ITMS-91053) | Fixed: DiskSpace E174.1 declared; `launch_check.sh` now fails if a required-reason API is used without one |
| REL-02 | **The signing keys exist only in the database, and the free plan keeps no backups.** Lost, new keys would be made that no installed app trusts: sign-ups and relay passes would stop until an app update | Fixed in tooling: `scripts/backup_server.sh` (encrypted export of every `priva` table). **Owner:** run it, keep a copy offline, repeat weekly |
| REL-03 | **No way to switch signing keys** (one lost or leaked) without an app update: the app trusted exactly one of each | Fixed in code: the app and the relay trust a list (active + standby), the server's active key is a setting, and a switched-to key must already exist. `scripts/standby_keys.sh` makes the standby. **Owner:** run it before the release build ([OPERATIONS.md](../OPERATIONS.md)) |
| REL-04 | Capacity on free plans: the Cloudflare Worker limit (100,000 requests a day) is about 1,200 typical users; the database holds about 33,000 (15 KB a username, not the 8 KB estimated) | **Owner decision** before launch: Workers Paid ($5/month), Supabase Pro ($25/month; also daily backups and a spend cap) |
| REL-05 | Directory lookups are public and unthrottled, and each returns about 10 KB: heavy use or abuse could use up the free plan's 5 GB monthly egress, and the project would be restricted | **Owner decision:** Supabase Pro's spend cap, or lookups through the relay's rate limiter (a change of design). Usage alerts in [OPERATIONS.md](../OPERATIONS.md) |
| REL-06 | Nobody is told when a server nears a limit or fails | **Owner:** usage alerts in Supabase and Cloudflare ([OPERATIONS.md](../OPERATIONS.md) § Monitoring) |
| REL-07 | Checked and fine: no Supabase Auth users, sign-ups unused; no storage buckets; nothing published to Realtime; the public role can run only the directory lookup; RLS denies every table; Supabase's security and performance advisors raise nothing beyond these intended points | - |
