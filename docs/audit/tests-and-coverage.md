# Tests and coverage audit

Audited at `81e65ee` (2026-10-06), after the security, state and UI fixes listed in [FIX_STATUS.md](FIX_STATUS.md).
This audit only read code: nothing was built, run or deployed. Line numbers refer to `81e65ee`.

What was read:
- every file in `PrivaTests/`, `PrivaDeviceJourneys/`, `supabase/functions/tests/` and `scripts/`;
- the app sources the tests exercise (engine, P2P, groups, vault, backup, network, media);
- `rendezvous/src/index.ts` and the edge functions.

Gaps that FIX_STATUS's new tests now cover are not repeated here. Weaknesses in those new tests are listed (TST-11,
TST-07).

---

## 1. Summary

### The picture

| Layer | Size | Where it runs |
|---|---|---|
| XCTest (`PrivaTests`) | 264 methods in 41 files | ≈ 37 skip unless an env var is set; ≈ 150 are live (real Supabase, the Cloudflare relay, real WebRTC, some real Tor) |
| XCUITest (`PrivaDeviceJourneys`) | 69 journeys | real iPhone; FID-08 and SU-13 opt-in; SocialJourneys need SimPeer |
| Phone + simulator (`CrossDeviceTests` ↔ `SimPeer`) | 20 journeys | opt-in, scripted |
| Edge functions (Deno) | 8 offline + 9 live tests | run by hand, no script or CI |
| Relay Worker | 0 unit tests | probed live from XCTest only |
| SQL migrations | 0 tests | - |

**Strong:**
- Cryptography and protocol: deep, including tamper sweeps, replay and DTLS-splice tests.
- Backup and key-file formats: deep.
- Engine flows: covered end to end over the live network, with good adversarial coverage (forged packets, MITM
  directory, replayed requests, ghost members, poisoned media, malicious group host).
- The new audit tests close real holes: group failover now needs the directory, history sync for new members,
  relaunch survival, disappearing messages expire offline, paging, `fileGone`, request withdrawal.

**Weak:**
1. **No hermetic layer.** There are no seams for the network, clock, Keychain or biometrics. Server failure modes
   (429, 5xx, timeouts, malformed bodies), clock jumps and Keychain errors are untested. Every test that touches the
   engine goes live, including new checks that are purely local.
2. **The app's state machines are tested only through the UI on a real iPhone:** `AppModel`, `OnboardingModel` and
   `LockView` (approval renewal, auto-lock, registration retries). Two key journeys can't reliably hit the case they
   are named for (TST-05).
3. **Server and relay code** is only probed live from the app's test bundle. The relay has no unit tests, the SQL no
   tests, and nothing runs in CI. There is no CI at all.
4. **Performance budgets are 10–50× looser than measured values,** so a regression of that size still passes. There
   are no startup, large-history, flood or media-memory budgets.
5. **Hygiene:**
   - one dead test;
   - several vacuous or stale assertions;
   - cleanup that may never run;
   - destructive global wipes inside the default suite;
   - one test (TURN behind the pass) that fails until the owner deploys.

### Biggest gaps (risk order)

1. Turning on Tor or "Relay calls" leaves existing direct connections and calls open (`PrivaEngine.swift:265-275`).
   This is an IP leak the tests never look for (TST-02).
2. Relay-pass burn loop: a 401 discards today's pass, and the refetch succeeds, so nothing backs off. A clock more
   than a day off can use up the month's 160 passes in minutes, and it stays broken after the clock is fixed
   (TST-03).
3. Server failures are untested: no URLProtocol stub exists (TST-01).
4. Registration retry (fix 6) and Face ID approval renewal (fix 17) have no deterministic test (TST-05).
5. Change password, Leave Priva and Delete account have no test at any level (TST-06). App Review requires account
   deletion.
6. Inbound flood cost (junk signals and requests) and fragment reassembly bounds have no adversarial test
   (TST-13, TST-14).
7. Media memory: the full-size `decryptAll` preallocation for "photos" up to 8 GiB, and the video loader, are
   untested (TST-15).

### Top 10 tests to add

1. `OnionModeTests.testTurningOnTorClosesDirectLinksAndCalls`: after the switch, every link is closed or uses a relay
   candidate within 5 s.
2. `RelayPassTests.testRefusedPassesDoNotBurnTheMonth`: a stubbed relay always answers 401 → at most 1 refill an
   hour; the same with the clock 2 days ahead.
3. `NetworkFailureTests` (URLProtocol stub): 5xx and timeouts on register, 429 on `/send`, malformed lookup JSON,
   409/429/403 mapping in `obtainToken`.
4. `OnboardingModelTests.testRegisterTakenByOwnKeysCountsAsRegistered` and
   `…testSpentTokenGetsOneFreshToken` (stub API).
5. `LockFlowTests.testOldApprovalIsRenewedBeforeThePasswordCheck` (after extracting the logic from `LockView`, with a
   fake clock and gate).
6. `AccountLifecycleTests`:
   - `testChangePasswordWrongCurrentCounts`, `testChangePasswordThenUnlockWithNew` (unit);
   - `testDeleteAccountRemovesUsernameAndBackups` and `testLeavePrivaRetires` (live);
   - device journeys `AC-01`/`AC-02`.
7. `FloodTests.testJunkRequestsAndSignalsStayCheap`: 2,000 of each; legitimate request in < 10 s; main thread < 16 ms
   per batch.
8. `FuzzTests`: Signal (plist and JSON), `FriendProtocol.openRequest`, `KeyFile.peek`, `BackupReader.peek`,
   `FileCipherHeader`, and fragment reassembly via a DEBUG hook.
9. `MediaMemoryTests.testAHugeImageAttachmentIsNeverDecodedWhole` and `…testVideoPlaysFromTheEncryptedFile`
   (byte-range reads, resident memory bounded).
10. `CallTimeoutTests`: missed after 45 s, "Couldn't connect" after 20 s, caller cancels while ringing, glare, busy
    while in a group call, auto-lock during a 1:1 call.

---

## 2. Coverage map

Depth: **none** · **shallow** (happy path) · **good** (happy + main errors) · **deep** (error, adversarial and
regression cases).

### App code

| Source file (main types) | Tests that exercise it | Depth | Notable gaps |
|---|---|---|---|
| `App/AppModel.swift` (AppModel, OnboardingModel, IntegrityCheck) | Device: SU-01…17, FID-*, LI-*, RS-*. GroupCallE2E STA-03 (`scenePhaseChanged(.background)` in a group call). RestoreSecurity (`migration()`, `clearLeftovers`, `shouldShowTour`) | unit shallow · device good | `register()` 409 `username_taken` / `token_spent` branches (`:390,:403`); `lockEpoch`; auto-lock thresholds; `didUnlock` branches; `restore()` failure; `received(url)`; IntegrityCheck |
| `App/PrivaApp.swift` | indirectly (journeys) | none | memory-warning → `trimMemory` wiring; `priva://add` (UX-01); scene phases |
| `App/DebugAutomation.swift` | used by journeys; `launch_check.sh` `strings` grep | n/a | - |
| `Core/Backup/BackupCrypto.swift` | BackupTests (14), BackupJourney attackers, ProductionHardening A13, AttackSurface compression | deep | fuzzing `peek` / frame lengths beyond 4 fixed cases |
| `Core/Backup/BackupService.swift` (BackupCenter, Locations, Exporter, Importer, KeychainFactor) | BackupTests, BackupJourney, BackupStress, RestoreSecurity search; device BK-*, RS-02, RS-09 | local good · iCloud device-only | "iCloud Keychain is unavailable" (`backUpNow`); `includeMedia = true` through BackupCenter; storage full during a backup; STA-33 (lock cancels a backup) |
| `Core/Backup/BackupRestore.swift` | RestoreSecurity (`resolve`, throttle, staging), RestoreJourney, RS-* | deep | `commit()` with a real vault only on device |
| `Core/Crypto/BlindToken.swift` (+PasswordKDF) | CryptoTests, RelaySecurity pinned key, every registration | good | - |
| `Core/Crypto/FileCipher.swift` | CryptoTests, A2, E2E 128 MB | deep | `decryptAll` preallocates `plainSize` (`:164`) |
| `Core/Crypto/Identity.swift` | CryptoTests, RestoreSecurity MoveProof, A1, Safety vector | deep | - |
| `Core/Crypto/KeyFile.swift` | KeyFileTests (9), BackupTests, KF-* | deep | - |
| `Core/Crypto/PrivaCrypto.swift` | CryptoTests DualAEAD/DualSeal | deep | DualKEM, HybridSigningKey only indirectly |
| `Core/Crypto/Protocol.swift` | CryptoTests handshake/ratchet/frames/early key | deep | - |
| `Core/Crypto/RecoveryPhrase.swift` | CryptoTests BIP-39 vectors, safety numbers | deep | - |
| `Core/Engine/CallCenter.swift` | FeatureE2E, E2E video, LiveAttack, Perf, MITM, XD-06…09/15 | good | 45 s missed/no answer (`arm(45)`); 20 s couldn't connect; caller cancels while ringing; glare; busy during a group call; auto-lock during a 1:1 call; STA-26 (active on inbound RTP) |
| `Core/Engine/FriendProtocol.swift` | E2E adversarial, MITM, Restore forged move, WireSecurity replay/decline/withdraw | deep | fuzzing mutated envelopes |
| `Core/Engine/PrivaEngine.swift` | nearly every live test | deep happy paths | Tor/relay switch keeps live links (`:265`); `maxLinks` eviction; flood cost (`processSignal`, request topic); `maintainLease` renew/revive; `sweepDirectory` timing (tests call `updateDirectoryState` directly); explicit key-change accept; receiver relaunch mid 1:1 transfer; message-id reuse across chats |
| `Core/Engine/Transfers.swift` | E2E large file (held), A9, A22 `fileGone`, STA-02 relaunch | good | two concurrent files on one link; chunks for a wrong fileID or contact |
| `Core/Groups/GroupCallCenter.swift` | GroupCallE2E (9), WireSecurity group media, Perf, Stress 8-cap, XD-12/16/20 | good | 5th video participant (cap 4); host change mid-call |
| `Core/Groups/GroupHub.swift` | GroupEndToEnd, GroupFeatureE2E (13), SecurityE2E, Safety, A12, dead-connection requeue, Restore moves, Stress | deep | keyword-filter invisible characters (the unit test is dead, TST-08); outbox 200 cap; 256-member invite cap |
| `Core/Groups/GroupModels.swift` | UnitModel charter/snapshot/isDurable, GroupScaleProbe | good | KeywordFilter unit test never runs |
| `Core/Media/MediaPrep.swift` | AttackSurface (photo, video, images-as-files), every photo send | good | plaintext `priva-prep` temp files after a crash; video optimise time and size |
| `Core/Media/MediaSaver.swift` | `canSave` only | shallow | `save()` to Photos; permission denied |
| `Core/Media/MediaVault.swift` (EncryptedAssetLoader) | `image(for:)` in FeatureE2E, LiveAttack | shallow | EncryptedAssetLoader (video, byte ranges) none; memory bound of `image(for:)` |
| `Core/Media/SafeImage.swift` (TextSafety) | AttackSurface formats, bomb, RTLO, brand names | deep | brand false positives ("Priva Happy" contains "app") |
| `Core/Network/API.swift` | every live test, ServerSurface, A21 | happy good · failures none | no stub seam: 429/5xx/timeouts/malformed JSON/`bundleMismatch` |
| `Core/Network/NetworkPrivacy.swift` | UnitModel, OnionModeTests | good | - |
| `Core/Network/Realtime.swift` | RealtimeProbe, RelaySecurity, BackendAdversarial | good | 401 → `discardToday` loop (`:193`); 1013 "replaced" reconnect thrash; 403 600 s backoff |
| `Core/Network/RelayPass.swift` | RelaySecurity (genuine, forged, other day), BackendAdversarial (160/month) | shallow | refill backoff STA-13 untested; clock-skew burn (TST-03); 429 → wait for the next day |
| `Core/Network/TorService.swift` | UnitModel `parsePort`, OnionModeTests (real Tor), OnionJourney, MultiDevice | good · flaky | Tor dying mid-call; STA-37 (one ready handler per owner) |
| `Core/P2P/PeerLink.swift` | all live; GroupScaleProbe 2 MiB control message; SecurityE2E unknown types; HandshakeJourney | good | adversarial fragments (`assemble`); ICE disconnected → 4 s → close; refused send (A8/STA-27); 10 s handshake timeout |
| `Core/P2P/WebRTCEnv.swift` (ManagedRelay) | RelayTests, OnionMode ICE policy, audio-owner tests | good | STA-17 30 s retry after failure; credentials expiring mid-call |
| `Core/P2P/Wire.swift` (Signal, ServerClock, SDPUtil) | CryptoTests decoding, UnitModel fuzz (JSON only), A21 | good | plist Signal fuzz; negative offsets; `tuneOpus` / `candidateKey` units |
| `Core/Purchase/PurchaseService.swift` | dev path in every registration, KeyFileTests | shallow | Release AppTransaction (PU-01 manual); error mapping (`:67-75`) |
| `Core/Security/BiometricGate.swift` | device FID-*; AttackSurface bio test (skipped on simulator, tests Apple's Keychain) | device-only | no seam; enrolment change (FID-11 manual); `confirm()` gates |
| `Core/Security/Keychain.swift` | A3 (weak, TST-11) | shallow | item errors (`errSecInteractionNotAllowed`) |
| `Core/Security/Vault.swift` (PasswordPolicy) | erase test (A14), LI/FID journeys | shallow | `changePassword`, `resetPassword` wrong phrase, PasswordPolicy, lockout schedule and clock changes, `exists` on a Keychain error, STA-31 |
| `Core/Storage/Models.swift` | UnitModel settings decoding, indirect | good | STA-36 Contact equality |
| `Core/Storage/SQLite.swift` | via Store | good | SQLITE_BUSY, corrupt file |
| `Core/Storage/Store.swift` | UnitModel, A22, A18/A19 (new), Backup*, Perf | deep | `migrate()` from v<3; search at 100k; `migrateConversation` at 100k (STA-28 left) |
| `Core/Util/*` | indirect | good | - |
| `DesignSystem/*` | ScreenshotTour (opt-in render, no assertions), journeys | shallow | snapshot comparisons |
| `Features/Backup/*` | BK-*, RS-*, KF-* | device good | - |
| `Features/Calls/CallViews.swift` | SO-02 voice | shallow | incoming-call overlay, video UI, speaker |
| `Features/Chat/ChatView.swift` | SO-01, SO-05 | shallow | photo/video viewer, held "Download", reply, delete, 16,000-character message |
| `Features/Chats/MainView.swift` | SO-05 search | shallow | AccountMovedView, compose sheet, 500-chat scroll |
| `Features/Friends/FriendsViews.swift` | SO-01, SO-03, SO-04 | shallow | security code / QR verify; "Replace keys" confirmation; rename card; `priva://add` |
| `Features/Groups/*` | SO-06 | shallow | GroupInfo admin actions, KeywordFilterView, GroupCallView |
| `Features/Lock/LockView.swift` | FID-*, LI-* | device good | renewal logic only in FID-08 (opt-in); WelcomeBackView (STA-16) |
| `Features/Onboarding/*` | SU-* | device deep | purchase failure (SU-16 manual); WelcomeTour |
| `Features/Safety/SafetyViews.swift` | SafetyTests (report, legal), SO-03, SO-04 | good | MailComposer |
| `Features/Settings/SettingsViews.swift` | FID-13/15/16/17, PU-03, BK-* | shallow | Change password, Leave Priva, Delete account (SEC-18), Network/Tor, Relay, Privacy toggles, display name |

### Server and relay

| Source | Tests | Depth | Notable gaps |
|---|---|---|---|
| `_shared/apple.ts` | `server_test.ts` (4) | good | expired leaf with an old `signedDate`; DER signatures |
| `_shared/blind.ts` | live only | shallow | `check` bounds (m ≤ 1, m ≥ n); `blindSign` self-check; key-creation race |
| `_shared/bundle.ts` | `server_test.ts` | good | - |
| `_shared/db.ts`, `_shared/purchase.ts` | none offline | none | dev path off → 403; pepper race |
| `_shared/util.ts` | live junk tests | shallow | SEC-24 `readJson` without a length (no test; needs deploy) |
| `directory/` | `live_test.ts`, ServerSurface | good | `update` success path; skew boundary |
| `issue-token/`, `register/` | `live_test.ts`, BackendAdversarial, ServerSurface | good | - |
| `relay-pass/` | BackendAdversarial (XCTest) | good | no Deno test; month rollover and `last_month` pruning |
| `migrations/*.sql` | none | none | `svc_authorize_relay` / `svc_authorize_issue` month boundaries, grants |
| `rendezvous/src/index.ts` | RelaySecurity, BackendAdversarial, RealtimeProbe, RelayTests (all live) | live good · unit none | ±1-day pass window; `/turn` 10/min; SEC-06 per-16 counting; SEC-24 length refusal; listener replacement thrash (TST-16) |

---

## 3. Findings

Severity: High · Medium · Low. Category: gap · weak · flaky · stale · opt-in · cleanup · server · device · perf ·
security.

### TST-01 · High · gap/infra: Server and network failure modes are untested: there is no seam

- **Where:**
  - `API.swift:56-74` (`request`), `:266-326` (`broadcast`).
  - `PurchaseService.swift:54-80`.
  - `Realtime.swift:188-197`.
  - Sessions come from `PrivaAPI.makeSession()` / RealtimeClient with no injectable `protocolClasses`.
- **Risk:** 429s from the relay, 5xx or timeouts from Supabase, a malformed lookup body
  (`JSONSerialization` throws a non-`APIError`), and `bundleMismatch` all ship unexercised. Retry storms or silent
  drops would reach users first.
- **Add (unit, no network):**
  - Add `#if DEBUG static var debugProtocolClasses: [AnyClass]` to `makeSession()` and RealtimeClient, and a
    `StubURLProtocol` with scripted responses.
  - `NetworkFailureTests.testRegisterRetriesAfter5xxWithoutSpendingASecondToken`:
    - 503 then 200 → one `register` call succeeds.
    - Assert `PurchaseService.storedToken` is reused (not refetched).
  - `…testRelaySend429BacksOffThenDelivers`:
    - `/send` → 429, 429, 202.
    - Assert `SignalOutbox.deliver` makes 3 attempts with growing gaps (≥ 0.3 s, then ≥ 0.6 s) and the message
      arrives.
  - `…testMalformedLookupIsANetworkErrorNotNotFound`: body `{"x":1}` → `findUser` throws `.network`, never
    `.notFound`.
  - `…testIssueTokenErrorMapping`: 409 → `limitReached`, 429 → `limitReached`, 403 → `notPurchased`, 500 /
    timeout → `network`.
  - `…testLookupWithAnotherCommitmentsBundleIsRejected`: `bundleMismatch` → the friend request is rejected.

### TST-02 · High · security: Turning on Tor or "Relay calls" leaves existing direct links and calls running

- **Where:**
  - `PrivaEngine.swift:265-275`: `setNetworkPrivacy` only reconfigures the rendezvous socket; links keep their
    `iceTransportPolicy .all` peer connections.
  - MultiDevice scene 10 (`MultiDeviceJourneyTests.swift:403-431`) only checks that messages and a call still work.
  - The idle timeout on Tor is 15 min, so a direct path can outlive the switch by that long.
- **Risk:** the user's IP stays visible to friends (and during a call) after choosing Tor, which contradicts
  SECURITY_VERIFICATION §5 ("relay-only, always").
- **Add (live):** `OnionModeTests.testTurningOnTorClosesDirectLinksAndCalls`.
  1. Befriend a and b. Send a message and wait for the link.
  2. Assert `await la.stats().candidate != "relay"` (direct), then start a voice call.
  3. Call `a.engine.setNetworkPrivacy(.init(mode: .tor))` (or flip `settings.relayCalls` with a relay installed).
  4. Assert within 5 s that every existing link is closed or reports `candidate == "relay"`, and that no inbound or
     outbound RTP flows on a non-relay pair.
  5. A message sent next goes through a relay link.
  - Same for "Relay calls": `testRelayCallsAppliesToOpenLinks`.

### TST-03 · High · gap: The relay-pass burn loop and clock changes are untested

- **Where:**
  - `RelayPass.swift:43-56`: `header` / `discardToday`.
  - `:95-112`: a successful fetch resets `failures`/`retryAt`.
  - `API.swift:91,325` and `Realtime.swift:193`: every 401 discards today's pass.
  - `Wire.swift:148`: `ServerClock.maxOffset` = 1 h.
  - Relay `index.ts:82`: ±1 day.
- **Risk:**
  - A phone whose clock is more than a day off (set by hand), or a rotated relay key, gets a 401 on every send and
    connect. Each 401 drops the pass, and the next `header()` refetches 35 successfully, so no backoff applies.
  - Four cycles use up 160 passes. The 429 then waits only until the next day, and the cycle repeats.
  - After the clock is fixed, the month is still used up, and the phone can't reach anyone.
  - STA-13 added backoff for *failed* refills only.
- **Add (unit, stubbed):** `RelayPassTests`.
  - `testRefusedPassesDoNotBurnTheMonth`:
    - Stub `relay-pass` to OK and `/send` + `/connect` to 401.
    - Run 50 `broadcast`s and 5 reconnects over 10 simulated minutes.
    - Assert ≤ 2 refill requests, and that `debugCount("relay-pass-error")` and the refills follow a backoff.
  - `testAClockTwoDaysAheadAsksForPassesOnce`: `ServerClock.debugSet(0)`, local date +2 days → ≤ 1 refill.
    `today` stays bounded by server time: when an HTTPS `Date` header disagrees with the local clock by more than a
    day, the pass day comes from the server day.
  - `testA429WaitsUntilTomorrowUTC`.

### TST-04 · High · infra/opt-in: No CI and no split test plans; the default run is live, slow, destructive and currently red

- **Where:**
  - The `Priva` scheme runs all of `PrivaTests` (`project.yml` schemes).
  - There is no `.xctestplan` and no CI configuration.
  - Default-run tests include:
    - ≈ 150 live tests;
    - real Tor and `check.torproject.org` (`OnionModeTests.swift:59-162`, `OnionJourneyTests`);
    - a 5-minute sleep (`FreeTierBudgetTests.swift:78`);
    - a 2-minute call (`GroupCallE2ETests`);
    - erases (TST-07).
  - `RelayTests.testTURNCredentialsNeedARelayPass` fails until owner actions 1–2 are done (FIX_STATUS).
- **Risk:**
  - Nobody runs the suite routinely, so regressions land unnoticed.
  - A permanently red test teaches people to ignore failures.
  - Once `allow_dev_purchases` is switched off for launch, `registerTestUser` (`EndToEndTests.swift:28`) can't
    register anyone, and every live test breaks: there is no staging project.
- **Add:**
  1. Test plans:
     - `Unit.xctestplan`: offline classes only (Crypto, UnitModel, Backup, KeyFile, RestoreSecurity, AttackSurface,
       parts of ProductionHardening). Target < 3 min.
     - `Live.xctestplan`.
     - `Slow.xctestplan`: Tor, FreeTier, Stress, 2-minute calls.
     - `Device`.
  2. A CI job (or `scripts/test_unit.sh` run before every commit) for `Unit`, plus `deno test
     supabase/functions/tests/server_test.ts`.
  3. Mark the TURN test `XCTExpectFailure("owner deploy pending, FIX_STATUS 1-2")` until deployed.
  4. A staging Supabase project (or a `allow_dev_purchases`-only staging config) so live tests survive launch.

### TST-05 · High · gap/device: Registration retry (fix 6) and Face ID approval renewal (fix 17) have no deterministic test

- **Where:**
  - SU-06 kills Priva 0.6 s after "I've written it down" (`SignUpJourneys.swift:107`).
  - `OnboardingModel.register()` waits 350 ms, then `obtainToken`, then a random 400–1500 ms before the POST
    (`AppModel.swift:377,382`). The kill almost always lands *before* the server call, so the "taken by our own
    keys" branch (`:390-401`) and the `token_spent` branch (`:403-407`) don't run.
  - Approval renewal lives inside `LockView.unlock()` (`LockView.swift`, `approvalLifetime` 300 s, retry-once on
    `.invalidated`). Its only test is FID-08, which is opt-in and takes ≈ 16 min.
  - `AppModel.scenePhaseChanged` / `lockEpoch` are tested only through UI journeys, apart from the new STA-03 check.
- **Risk:** regressions in the two worst bugs the journeys found would ship unnoticed.
- **Add:**
  - `OnboardingModelTests.testRegisterTakenByOwnKeysCountsAsRegistered`:
    - Stub `register` → 409 `username_taken`, stub `lookup` → an entry with our own bundle.
    - Assert `create == .done`, `Vault.meta.registered`, one `register` call.
  - `…testSpentTokenGetsOneFreshToken`: 409 `token_spent` then 200 → exactly one more `issue-token`.
  - `…testTakenBySomeoneElseDrawsANewName`.
  - Move LockView's decision logic into a `LockController` (injectable clock and `BiometricGate`), then:
    - `testOldApprovalIsRenewedBeforeThePasswordCheckKeepingTheTypedPassword`;
    - `testInvalidatedWithAnOldApprovalRetriesOnce`;
    - `testInvalidatedWithAFreshApprovalSaysFaceIDChangedAndDoesNotCount`.
  - `AppModelTests.testAutoLockThresholds` (0 s, 60 s, in-call exemption, `lockEpoch` increments only after
    `.background`).
  - Device: SU-06b using a DEBUG hook `-PrivaCrashAfterRegister` that exits right after the 200 and before
    `markRegistered`.

### TST-06 · High · gap: Change password, Leave Priva and Delete account have no test anywhere

- **Where:**
  - `Vault.swift:179` (`changePassword`).
  - `SettingsViews.swift` `leave(delete:)`: revoke/retire, then delete backups, then wipe.
  - Grep finds no reference in `PrivaTests` or `PrivaDeviceJourneys` (KF-07 is manual).
- **Risk:** these are irreversible flows that App Review requires (account deletion). A wrong order, wipe before the
  server call succeeds, or a lockout from a bad `changePassword` would be unrecoverable.
- **Add:**
  - Unit `VaultTests`:
    - `testChangePasswordNeedsTheCurrentOneAndCountsWrongGuesses`;
    - `testAfterChangeOnlyTheNewPasswordUnlocks` (simulator Keychain path);
    - `testResetPasswordWithAnotherAccountsPhraseIsWrongPhrase`.
  - Live `AccountLifecycleTests`:
    - `testDeleteAccountRemovesTheUsernameAndEveryBackup`: lookup → `.removed`; `BackupLocations.list()` is empty;
      `Vault.exists` false.
    - `testLeavePrivaRetiresAndKeepsTheRevocationRecord`.
    - `testDeleteOfflineChangesNothing` (stub 503 → nothing wiped).
  - Device AC-01 (change password, lock, unlock with the new one) and AC-02 (delete account, Welcome, old username
    not findable from SimPeer).

### TST-07 · High · cleanup: Leftover server data, cleanup that may never run, and destructive wipes in the default suite

- **Cleanup that may never run:**
  - `EndToEndTests.swift:109,155,174,211,257,288,338`: `defer { Task { await cleanup } }`. The Task runs after the
    test returns, or never at process exit, so revokes and directory removals are skipped.
  - `CrossDeviceTests.swift:33-42`: the class `tearDown` launches a Task and returns at once, so the phone's test
    username is never revoked.
- **New leftovers on every run:**
  - Every `registerTestUser` creates a new dev purchase row (`EndToEndTests.swift:28`, random `devNonce`).
  - Device journeys' `-PrivaReset` wipes the revocation record, so each fresh sign-up leaves an *active* username for
    21 days.
  - The new ProductionHardening tests (`…ThousandUnread`, `…ScrollingUp…`, `…RemovingAFriend…`,
    `…RequestsOlderThan30Days`) and `testDisappearingMessages…` register live users or connect for purely local
    checks.
- **Destructive wipes in the default suite:**
  - `ProductionHardeningTests.swift:331,358`: `Vault.wipeEverything()`, which deletes all Keychain items including
    relay passes and the dev nonce, plus UserDefaults.
  - `:48`: `Vault.wipeFiles()` deletes all of `tmp`.
  - `BackupLocations.deleteAll()` in BackupJourney, BackupStress, RestoreJourney and RestoreSecurity.
  - `GroupCallE2ETests` builds an `AppModel()`, whose init can run `clearLeftovers` / `purgeTemp`.
  - On the Air simulator that also hosts ReviewBuddy, this deletes the buddy's relay passes. After
    `allow_dev_purchases` is off, the buddy can't get new ones and goes offline during App Review.
- **Add / change:**
  - Use `addTeardownBlock` (awaited) everywhere and an awaited `class func tearDown() async`.
  - Add a teardown audit test `ZZServerLeftoversTests.testThisRunLeftNoActiveTestUsernames` (a list of commitments
    registered this run, each looked up → `.removed`).
  - Add a DEBUG `-PrivaReset` that revokes the server username before wiping.
  - Make the local-only tests use `localEngine()` (as BackupJourneyTests does).
  - Gate destructive tests behind `TEST_RUNNER_PRIVA_DESTRUCTIVE=1` or run them in a dedicated simulator plan.
  - Have `AppModel` take a `performLaunchCleanup: Bool` for tests.

### TST-08 · Medium · weak (dead): The KeywordFilter unit test never runs

- **Where:** `CryptoTests.swift:424-447`. `testKeywordFilterResistsInvisibleCharactersAndMasksPhrases` is declared
  inside `enum _RSABlindKeyFactory`, not an `XCTestCase`.
- **Risk:** no test covers the zero-width-space / word-joiner bypasses or the "whole words only" behaviour. The live
  GroupEndToEnd §3–4 checks only plain words and accents.
- **Fix:** move the test into `UnitModelTests` (or a `GroupModelTests` class), unchanged. Add the case
  `"spo\u{00AD}iler"` (soft hyphen) and full-width letters.

### TST-09 · Medium · weak: The ghost-member check is vacuous

- **Where:** `LiveAttackTests.swift:171-175` waits for any system line ending in "joined.". Bob and Carol already have
  "…joined." lines from the setup (`group()` joins Bob, then Carol), so it passes before Dave joins.
- **Fix:** match Dave's name: `$0.text == "\(dave display name or @dave) joined."`. Also assert the count of
  `joined.` lines rose by exactly 1.

### TST-10 · Medium · stale: Names, comments and assertions that no longer match the code

| Where | What's stale | Fix |
|---|---|---|
| `GroupCallE2ETests.swift:6,205-215` | "past the 90 s idle close", but idle is 300 s (900 s on Tor) (`PrivaEngine.idleLinkTimeout`). The 2-minute test proves nothing about the call exemption. | Use a DEBUG `idleLinkTimeout` override of 20 s and run 60 s; add a 1:1-call twin. |
| `FreeTierBudgetTests.swift:4-7`, `FreeTierCapacityTests.swift:4-10` | They describe Supabase Realtime (2 M messages, 200 sockets). The rendezvous is now the Cloudflare relay; the budget is Worker + DO requests a day (≈ 100 k free, per 16 messages since SEC-06). | Rewrite the budget in relay requests (sends, connects, DO calls) per everyday action, and assert against `FREE_TIER_CAPACITY.md`. |
| `BackupJourneyTests.swift:164-169` | "the backup carries only live media" (`lastSize < 256 KiB`): vacuous since backups are text-only by default (`includeMedia` nil). | Set `includeMedia = true`, then assert the pruned file is absent and the recent one present. |
| `RelaySecurityTests.swift:67-70` | "a pass only works on its day", but the relay accepts ±1 day (`index.ts:82`) and only day+3 is tested. | Assert day+1 → 202, day+2 → 401, day−2 → 401. |
| `OnionModeTests.swift:180-183` | The "no relay yet: onion waits, never direct" assertion runs only `if ManagedRelay.servers.isEmpty`. Earlier live tests fill it, so it's silently skipped. | Call `ManagedRelay.debugReset()` first. |
| `ProductionHardeningTests` MARKs | "A15, group invites…", "A14, Erase…", "A13, storage full" don't match PRODUCTION_AUDIT IDs. | Relabel. |
| `scripts/multi_device_journey.sh`, `restore_showcase.sh` | Default carol/old simulator UDID no longer existed. | **Fixed (2026-10-15):** scripts find simulators by name (`scripts/devices.sh`) and say which one to create. |

### TST-11 · Medium · weak: Assertions that pass even if the feature breaks (including new audit tests)

- **Older tests:**
  - `WireSecurityTests.swift:302`: `cryptorFailures >= failuresBefore` is always true. Use `>`.
  - `ProductionHardeningTests.swift:24-34` (A3): set twice, then read. This passes with delete+add too. Add a DEBUG
    counter on `SecItemDelete` for plain items and assert 0.
  - `GroupScaleProbeTests.testSnapshotSizeGrowsWithMembers`: metrics only.
  - STA-05's guard is `perPost < 250 ms` at ≤ 256 members (measured 36 ms). Tighten to < 80 ms and assert one store
    write per post.
- **New audit tests:**
  - `testOpeningAChatWithAThousandUnreadClearsTheBadge` measures but has no budget and doesn't prove "one write"
    (STA-07's point). Add `< 100 ms` and a DEBUG `Store.writeTransactions` delta == 1.
  - `testABlockedGroupMemberGetsNoPresence` has no positive control. Assert the host *does* get presence in the
    same window, or the test passes when presence is broken for everyone.
  - `testAQuietHostIsNotReplacedWhileItsDirectoryEntryIsActive` doesn't prove a directory check happened. Assert
    `debugFailoverChecks` incremented (or the lookup was seen via WireTap).
  - `testE2ELargeFileTransfer` (SEC-12) checks `progress == 0` after a 2 s sleep. Also assert
    `downloadProgress.isEmpty` and that the sender saw no `fileWant`.
  - `testRelayCallsNeverGoDirectWithoutARelay` is good. Add the same check for Tor with `ManagedRelay.debugReset()`
    and a stale credential.
- **CrossDevice:** XD-01, 02, 07, 09 and 11 record metrics with no budgets. XD-07 asserts neither remote video nor
  `decryptFailures == 0`; XD-11 doesn't check the 20 phone posts reached the simulator.
- **AttackSurface:** `testTheBiometricSecretCantBeReadWithoutARealFaceMatch` (`:236-254`) is skipped on the
  simulator and never runs on the phone (CrossDevice runs only its own class). It also tests Apple's Keychain rather
  than `BiometricGate`. Run `BiometricGate.secret(context: LAContext())` with `interactionNotAllowed` in a device
  journey instead.

### TST-12 · Medium · perf: Budgets are far looser than measured, and key perf paths have none

- **Loose budgets (simulator):**

  | Test | Budget | Measured |
  |---|---|---|
  | Day-in-the-life heap (`PerformanceJourneyTests.swift:426`) | < 150 MB | +2.7 MB |
  | 8 calls (`:468`) | < 80 MB | +0.7 MB |
  | Cold first message (`:225`) | < 8 s | 1.3 s |
  | Warm RTT p50 (`:224`) | < 250 ms | 28 ms |
  | Backup streaming (`BackupTests.swift:320`) | < 400 MB | - |
  | Soak (`UsageSoakTests.swift:58`) | < 250 MB resident | - |

  In addition:
  - `testLockUnlockCyclesLeaveNothingBehind` checks only the *last* engine is freed and doesn't assert memory.
  - `testGroupPostAndCallSetupLatency` has no call-setup budget.
- **Missing:** startup, large history, inbound floods (TST-14), media memory (TST-15), `migrateConversation` at
  scale (STA-28 left), search at 100k.
- **Add:** see §4 "Memory and latency" for budgets. The tests are:
  - `PerformanceJourneyTests.testColdLaunchToLockScreen` (XCTApplicationLaunchMetric in a device journey);
  - `…testSearchOver100kMessages`;
  - `…testFollowingARenameWith50kMessagesStaysOffTheMainThread`;
  - `…testHeapPerLockUnlockCycle`;
  - `…testAnHourOfChurnHasNoHeapSlope` (opt-in).

### TST-13 · Medium · security: Parsers and fragment reassembly lack adversarial and fuzz tests

- **Where:**
  - `UnitModelTests.swift:167-197` fuzzes JSON `Wire`, Settings and NetworkPrivacy only.
  - Signals are binary property lists (`Wire.swift` `encoded()` / `decode`).
  - Not fuzzed: `FriendProtocol.openRequest`, `Announcement.open`, `KeyFile.peek`, `BackupReader.peek`,
    `FileCipherHeader.init`, `KeyBundle.parse`.
  - `PeerLink.assemble` (≤ 4 in flight, ≤ 8 MiB, 30 s; `PeerLink.swift`) has only a happy-path 2 MiB test.
- **Risk:** a trap or unbounded allocation in a parser reachable by a friend (or by anyone, for requests).
- **Add:**
  - `FuzzTests` (unit): 2,000 mutations per sample (byte flip, truncate, extend, length fields set to `0xFFFFFFFF`)
    for each parser above. Assertions:
    - no crash;
    - each decode < 50 ms;
    - resident memory growth < 20 MB.
  - Live `SecurityE2ETests.testFragmentFloodsAreBounded` (DEBUG `sendRawFragment`):
    - 5 interleaved partial sets, inconsistent totals, a duplicate index, 9 MiB worth, a set never completed.
    - Assert the link stays ready, `partial.count ≤ 4`, and memory grows < 40 MB.

### TST-14 · Medium · security/perf: Inbound floods are untested (junk signals and friend requests)

- **Where:**
  - `PrivaEngine.processSignal` tries every contact's root candidates per envelope.
  - A request topic is derivable from a username (memory-hard but cached), and each request costs a DualSeal open
    plus a directory lookup (`processFriendRequest`).
  - `ReplayCache` grows without bound inside its 10-minute window.
  - LiveAttackTests "Careless Whisper" checks only that nothing replies.
- **Risk:** with one relay pass (300 sends/min × 64 messages), anyone who knows a username can make the victim's
  phone burn CPU, battery and directory lookups. Lookups are rate-limited on the free plan.
- **Add (live, opt-in heavy):** `FloodTests.testJunkRequestsAndSignalsStayCheap`.
  - The victim has 300 contacts (seeded locally). Send 2,000 junk "r" and 2,000 junk "s" envelopes.
  - Assertions:
    - main-thread stalls < 16 ms (sample with a 5 ms ticker);
    - resident growth < 30 MB;
    - directory lookups ≤ number of *decryptable* requests;
    - a genuine request sent mid-flood is listed within 10 s.

### TST-15 · Medium · perf/security: Media memory and video playback are untested

- **Where:**
  - `MediaVault.image(for:)` calls `FileCipher.Reader.decryptAll()`, which does `Data(capacity: plainSize)`
    (`FileCipher.swift:164`).
  - `isValid` accepts `kind .image` up to 8 GiB (`PrivaEngine.swift:1838`). Auto-download now stops at 100 MB
    (SEC-12), but a tapped "Download" still decodes whole.
  - `EncryptedAssetLoader` (video, byte ranges) has no test.
- **Add:**
  - `MediaMemoryTests.testAHugeImageAttachmentIsNeverDecodedWhole` (unit):
    - A 300 MB `.image` file written with FileCipher.
    - `image(for:)` returns nil or a downsampled image, peak resident delta < 60 MB, no crash.
  - `…testVideoPlaysFromTheEncryptedFile`:
    - Prepare a 50 MB video, play 5 s through `playerItem(for:)`.
    - Assert ranges are served, no plaintext file is written (scan `tmp` and Caches), and resident delta < 80 MB.
  - `…testMemoryWarningDropsDecodedPhotos`: 30 photos → `trim()` → cache empty.

### TST-16 · Medium · gap (cost): An announce topic with more than 16 listeners may thrash

- **Where:**
  - Every friend of a "gone" user listens on that user's announce topic with the same derived key
    (`PrivaEngine.swift:1425-1426`).
  - The relay replaces the oldest listener beyond 16 (`index.ts:144`, close 1013).
  - The client reconnects after backoff (`Realtime.swift:188-197`), and the backoff resets on each successful open.
- **Risk (suspected):** with 17+ friends online, sockets evict each other in a loop. Each round is billed Worker and
  DO requests against a free budget of ≈ 100 k a day.
- **Add (live):** `BackendAdversarialTests.testSeventeenListenersOnOneTopicSettle`.
  - 18 RealtimeClients on one topic with the same key, observed for 60 s.
  - Assert total reconnects ≤ 18 + 2, and that a broadcast reaches ≥ 16 of them.

### TST-17 · Medium · gap: 1:1 call edge cases

- **Where:** `CallCenter.swift`: `arm(45)` "No answer" / "Missed", `arm(20)` "Couldn't connect", `hangUp()` while
  ringing, busy while in a group call, glare. None are tested. STA-03 covers backgrounding only for group calls.
- **Add (live):** `CallTimeoutTests`.
  - `testUnansweredCallEndsAsMissedOnBothSides` (45 s → `.missed` / `.cancelled`; history lines).
  - `testAcceptedButNoMediaEndsCouldntConnect`: relay-only with no relay on the callee → after 20 s.
  - `testCallerCancelsWhileRinging`: callee stops ringing < 3 s, history "Missed".
  - `testBothCallAtOnce`: one call survives and both phones agree on the call id.
  - `testA1to1CallWhileInAGroupCallIsBusy`.
  - `testAutoLockDuringA1to1CallKeepsItUp`: AppModel `scenePhaseChanged(.background)`, as in the STA-03 test.

### TST-18 · Medium · server: Edge functions, SQL and the relay have no offline tests, and none run automatically

- **Where:**
  - `server_test.ts` covers `apple.ts` and `bundle.ts` only.
  - `blind.ts`, `purchase.ts`, `util.readJson` (SEC-24), `relay-pass` and `directory` `update` have no Deno tests.
  - The SQL has no pgTAP tests.
  - The relay has no Workers/miniflare tests; only live probes from XCTest.
  - `live_test.ts` assumes `max_tokens_per_month = 3`.
- **Add:**
  - `server_test.ts`:
    - `blindSign` round trip with a test key;
    - `check` rejects m ≤ 1 and m ≥ n;
    - `purchaseFrom` with dev off → 403;
    - `readJson` refuses a body without a length (SEC-24) and one over 64 KiB.
  - `supabase/tests/*.sql` (pgTAP): `svc_authorize_relay` at a month boundary, 160 + 1 → `limit`;
    `svc_authorize_issue` reissue doesn't count; anon has no grants.
  - `rendezvous/test/index.test.ts` (vitest-pool-workers):
    - pass day ±1 / ±2;
    - `/turn` 401 without a pass and 429 after 10/min;
    - 17th listener replaced;
    - send to an unowned topic leaves no storage (SEC-06);
    - missing `content-length` → 411/413.
  - Wire all of them into `scripts/test_server.sh` and CI.

### TST-19 · Medium · device: Real-iPhone behaviour still uncovered

- **No journey for:**
  - comparing the security code or scanning the QR;
  - the "Replace keys" confirmation;
  - Tor / Network / Relay settings;
  - video and group calls through the UI;
  - picking, sending and viewing a photo or video;
  - disappearing messages in the UI;
  - change password, delete account (TST-06);
  - an airplane-mode toggle (SU-16 is manual);
  - auto-lock or locking during a call;
  - huge names, emoji and RTL in names and messages;
  - scrolling 500 chats.
- **Weak device restore journeys:** RS-01 / RS-02 restore an account with no messages or friends, so "the chats come
  back" is never checked.
- **Timing-dependent:**
  - BK-06 kills 0.5 s after "Back up now" (`BackupJourneys.swift:73`). A small backup may already be done, so the
    "killed while encrypting" case isn't reached.
  - SU-06 (TST-05).
- **Add:** device journeys:
  - SO-07 (verify the security code by QR with SimPeer showing its code via `!peer qr`);
  - SO-08 (photo both ways, open viewer, save to Photos: the tester grants permission);
  - SO-09 (video call 15 s, camera toggle, speaker);
  - SO-10 (Tor on in Network settings, then message SimPeer: works, and Diagnostics shows candidate `relay`);
  - RS-10 (restore an account with SimPeer history; assert specific old messages are shown);
  - BK-06b (with a DEBUG `-PrivaSlowBackup` so the kill lands mid-encryption);
  - AC-01 / AC-02 (TST-06).

### TST-20 · Medium · gap: Vault, Keychain and lockout edge cases

- **Where:**
  - `Vault.exists` is `try?` (`Vault.swift:60`), so a Keychain *error* reads as "no vault" and AppModel shows
    onboarding. STA-15/16 cover only the store failing to open.
  - The lockout uses the wall clock (`:104-107`): setting the clock forward skips the wait; setting it back stretches
    it.
  - PasswordPolicy and STA-31 ("only a wrong key counts") have no tests.
- **Add (unit):**
  - `VaultTests.testAKeychainErrorIsNotAMissingVault`: DEBUG Keychain fault injection
    (`errSecInteractionNotAllowed`) → `AppModel.phase == .locked`, with an error, not `.onboarding`.
  - `testLockoutScheduleAndClockJumps`: 5 → 30 s, 6 → 60 s, cap 1 h. The clock +2 h doesn't unlock early (use a
    monotonic counter or the server-corrected time, or document the limitation).
  - `testPasswordPolicyBoundaries`: 7/8 characters, common list, < 5 unique characters, scores 0–4.
  - `testACorruptedMetaIsNotCountedAsAWrongPassword`.

### TST-21 · Low · flaky: Tests that depend on the public Internet or fixed sleeps

- **Public Internet:** OnionModeTests' real-Tor tests and OnionJourney use the public Tor network and
  `check.torproject.org`. They already showed a TLS flake (PRODUCTION_AUDIT third pass).
- **Fixed sleeps instead of conditions:**
  - `EndToEndTests.swift:157-159` (1 s + 4 s);
  - WireSecurity presence (`4 s` / `5 s`);
  - LiveAttack (`5 s`);
  - CrossDevice XD-03/04 (`5 s` / `40 s`).
- **Testing the test's own copy of the code:** `RestoreJourneyTests.restoreOnNewPhone` (`:29-45`) re-implements the
  app's restore, so the tests exercise their own version, not `AppModel.restore`.
- **Fix:**
  - Move the real-Tor tests to `Slow.xctestplan`.
  - Replace sleeps with `waitUntil` on the signal that matters (for example `diagnostics.signalsSent` stops rising).
  - Drive `AppModel.restore(_:password:context:)` with a stub biometric context.

### TST-22 · Low · gap: Remaining engine paths

- `maxLinks` eviction (128); idle-close of the least active link.
  - Add `PerformanceJourneyTests.testTheLinkCapEvictsTheQuietest` with a DEBUG `maxLinks` = 3.
- `maintainLease` renew and lapsed revive.
  - Add `testALapsedLeaseIsRevivedAtUnlock`: retire with a bundle kept → unlock → `.active`.
- `sweepDirectory` timing (48 h quiet / 24 h stale / 7 days for active since SEC-13).
  - Add a unit with `debugEditContact` and a stubbed lookup counter.
- Explicit key-change accept: `MITMSecurityTests` stops at "flagged".
  - Add `testReplacingKeysAfterInPersonCheck`: accept the flagged request → new safety number, verified cleared,
    messaging works.
- Receiver relaunch in the middle of a 1:1 transfer (`resumeIncomingTransfers`).
  - Add `testA1to1DownloadResumesAfterTheReceiverRelaunches`.
- A friend reusing a message id from another chat.
  - Add a unit: the message is ignored, and the other chat's row is untouched.

### TST-23 · Low · gap: Small untested pieces

- `MediaSaver.save` (denied permission);
- clipboard expiry of the purchase ID (2 min);
- `IntegrityCheck`;
- `PrivaApp` memory-warning wiring;
- STA-36 Contact equality;
- `Store.migrate()` from a v2 database;
- `TextSafety.name` false positives ("Priva Happy").

Each is a small unit test.

---

## 4. Prioritized "tests to add" backlog

Order is by risk. Type: **U** unit (offline), **L** live, **D** device, **X** phone + simulator, **S** server.

| # | Test | Type | Finding |
|---|---|---|---|
| 1 | `OnionModeTests.testTurningOnTorClosesDirectLinksAndCalls`, `testRelayCallsAppliesToOpenLinks` | L | TST-02 |
| 2 | `RelayPassTests.testRefusedPassesDoNotBurnTheMonth`, `testAClockTwoDaysAheadAsksForPassesOnce`, `testA429WaitsUntilTomorrowUTC` | U | TST-03 |
| 3 | `StubURLProtocol` + `NetworkFailureTests` (5 tests) | U | TST-01 |
| 4 | Test plans Unit/Live/Slow/Device + CI for Unit + Deno; TURN test `XCTExpectFailure`; staging project | infra | TST-04 |
| 5 | `OnboardingModelTests` (taken-by-own-keys, spent token, taken by other) + `LockController` tests + `AppModelTests.testAutoLockThresholds` | U | TST-05 |
| 6 | `VaultTests` change/reset password; `AccountLifecycleTests` delete/leave; device AC-01/AC-02 | U/L/D | TST-06 |
| 7 | Awaited cleanup everywhere; `ZZServerLeftoversTests`; revoking `-PrivaReset`; destructive tests gated | infra | TST-07 |
| 8 | Move the KeywordFilter test into an XCTestCase; fix the ghost-member assertion | U/L | TST-08, TST-09 |
| 9 | `FuzzTests` (7 parsers) + `testFragmentFloodsAreBounded` | U/L | TST-13 |
| 10 | `FloodTests.testJunkRequestsAndSignalsStayCheap` | L (opt-in) | TST-14 |
| 11 | `MediaMemoryTests` (huge image, video loader, memory warning) | U | TST-15 |
| 12 | `CallTimeoutTests` (6) | L | TST-17 |
| 13 | Server: Deno units, pgTAP, relay vitest; `scripts/test_server.sh` | S | TST-18 |
| 14 | `testSeventeenListenersOnOneTopicSettle` | L | TST-16 |
| 15 | Stale fixes: idle-timeout override test, free-tier relay budgets, `includeMedia` backup check, pass ±1 day, `ManagedRelay.debugReset` in OnionMode | U/L | TST-10 |
| 16 | Tighten assertions (TST-11 list), including the new STA-07 one-write and STA-20 positive-control checks | U/L | TST-11 |
| 17 | `VaultTests` Keychain fault, lockout/clock, PasswordPolicy, STA-31 | U | TST-20 |
| 18 | Device SO-07…10, RS-10, BK-06b | D | TST-19 |
| 19 | Engine leftovers (link cap, lease, sweep, key replace, 1:1 resume, id reuse) | L/U | TST-22 |
| 20 | Small units (TST-23) | U | TST-23 |

### Weird-behaviour journeys to add

| ID | Journey | Type | Expect |
|---|---|---|---|
| W-01 | Lock (Settings › Lock) and auto-lock "Immediately" during a 1:1 call, then come back | D + X | Call continues while backgrounded; Settings › Lock ends it cleanly; microphone released (`debugAudioOwners == 0`) |
| W-02 | Restore a backup while a call is ringing or active | L | Call ended first, no crash, restore completes, friends follow |
| W-03 | Background Priva in the middle of a handshake (kill the engine 300 ms after `requestLink`), then reopen | L | No half-open link left; the message is delivered once |
| W-04 | Tor on/off 10 times in 30 s while messaging | L | Never a direct link while on; every message delivered once; ≤ 1 Tor bootstrap in flight |
| W-05 | Airplane mode on during a 50 MB transfer, off after 60 s | D + X | Resumes from the missing chunks, bit-exact; no duplicate message |
| W-06 | Phone clock +2 days, then −2 days, then correct | U + L | Clear "check your clock" state; passes not burned (TST-03); disappearing timers still honest |
| W-07 | Memory warning during a video call and during a group upload | L (`trimMemory` + `MediaVault.trim`) | Call and transfer survive; caches dropped |
| W-08 | 16,000-character message; 40-character RTL/emoji display names; Zalgo text | L + D | Delivered intact; bubble renders < 100 ms; names cleaned (TextSafety) |
| W-09 | 256-member group (host on the phone, members from 2 simulators) | X (opt-in) | Roster ≤ 3 MB; post p95 < 2 s; host main thread < 100 ms per post |
| W-10 | 500 chats × 200 messages, scroll Chats and search | D | Scroll hitch rate < 5 ms/s; search first page < 1 s on the phone |
| W-11 | Rapid back/forward through Settings › Recovery phrase / Purchase ID while Face ID is up | D | Never shown without a fresh approval; one prompt |
| W-12 | iCloud Drive signed out mid-backup (manual) and iCloud slow (an NSMetadataQuery stub in DEBUG) | D + U | Amber "kept on this iPhone"; no `.partial` left; the search waits ≤ 10 s |
| W-13 | Low storage during restore (DEBUG `failMessageWrites` on the staged store) | U | Restore refused cleanly, old account intact |
| W-14 | Face ID enrolment changed (manual FID-11), with the LockController unit (TST-05) as the automated counterpart | D + U | "Face ID changed" only on a fresh-approval refusal; reset with the key file works |

### Memory and latency tests, with budgets

Budgets are for the simulator on the Mac unless marked "phone". A phone is about 2–3× slower on CPU work. Each test
prints `METRIC` lines and asserts the budget.

| Test | Measures | Budget |
|---|---|---|
| `testColdLaunchToLockScreen` (D, XCTApplicationLaunchMetric) | Launch → "Priva is locked" | phone p50 < 900 ms, p95 < 1.5 s |
| `testUnlockAndBackgroundWorkOnAHeavyAccount` (tighten) | Unlock main-thread work | < 60 ms (measured 19); expiry sweep < 5 ms |
| `testHeapPerLockUnlockCycle` | Heap delta over 15 cycles | < 2 MB total; every engine, store and realtime freed (not only the last) |
| `testOpeningAChatWithAThousandUnreadClearsTheBadge` (tighten) | `markRead` 1,000 | < 100 ms, 1 write transaction |
| `testSearchOver100kMessages` | No-hit search; cancel latency | < 4 s total; cancel honoured < 150 ms; main thread never blocked > 16 ms |
| `testFollowingARenameWith50kMessagesStaysOffTheMainThread` | `migrateConversation` | Main thread < 50 ms; total < 6 s; peak resident < 120 MB |
| `testMessagingLatencyColdWarmBurstAndFiles` (tighten) | Latency | Cold < 3 s; warm p50 < 80 ms, p95 < 150 ms; 300-burst < 1.5 s; 12 MB file > 2 MB/s |
| XD-01 / XD-02 (add asserts) | Phone round trip; 200-burst | p95 < 300 ms; 200-burst < 1 s (measured 0.1 s) |
| `testADayInTheLifeLatencyAndMemory` (tighten) | Heap growth | < 20 MB (measured 2.7); 1:1 p50 < 200 ms |
| `testRepeatedCallsDontKeepGrowingMemory` (tighten) | Heap growth over 8 calls | < 10 MB (measured 0.7) |
| `testAnHourOfChurnHasNoHeapSlope` (opt-in soak) | Heap slope | < 1 MB per 10 min after the first 10 min; links ≤ friends |
| `GroupScaleProbeTests` (tighten) | Host post at 256 members | < 80 ms; queue check < 2 ms |
| `MediaMemoryTests.testAHugeImageAttachmentIsNeverDecodedWhole` | 300 MB image | Peak resident delta < 60 MB |
| `MediaMemoryTests.testVideoPlaysFromTheEncryptedFile` | 50 MB video | Resident delta < 80 MB; first frame < 1 s |
| `FloodTests.testJunkRequestsAndSignalsStayCheap` | 2,000 + 2,000 junk | Main-thread stall < 16 ms; resident < 30 MB; legitimate request < 10 s |
| `BackupTests.testStressLargeBackupStreamsInFlatMemory` (tighten) | 64 MB media backup | Resident delta < 120 MB |

---

## 5. Notes on the new audit tests

Most are well aimed: real engines, a relaunch through `LiveTestCase.relaunched`, and conditions waited for rather
than slept. Remaining issues:
- Four of them register live users for local-only checks (TST-07).
- Three lack a budget or a positive control (TST-11).
- `testAGroupCallSurvivesBackgroundingAndStopReleasesTheAudio` builds a real `AppModel()`, whose init runs launch
  cleanup in the shared test process (TST-07).
- `testTURNCredentialsNeedARelayPass` fails until the owner deploys (TST-04).
- SEC-01's test spends up to 45 s waiting for the request timeout. A DEBUG timeout override would keep the
  live suite shorter.
