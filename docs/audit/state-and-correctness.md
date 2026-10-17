# Priva: state-machine, correctness, robustness and performance audit

Date: 2026-10-06. Scope: `Priva/` app sources (about 18k lines), read line by line for the core (App, Engine, P2P,
Groups, Storage, Backup, Security, Network) and selectively for the Features views. Read only. Nothing was built,
run, or sent to a server. The fixed findings in `PRODUCTION_AUDIT.md` (A1–A37) and `DEVICE_JOURNEYS.md` (fixes 1–20)
are not reported again unless a fix is incomplete.

Confidence levels:
- **Confirmed**: traced through the code end to end; the failure follows directly from the code.
- **Likely**: the code path is certain, but the impact depends on runtime behaviour (WebRTC, iOS, timing).
- **Possible**: needs a specific race or condition to happen.

A note on why the tests miss several of these: most test harnesses "relaunch" a phone with `engine.stop(); engine.start()`
on the **same** `PrivaEngine` (FreeTierBudgetTests, GroupEndToEndTests, ...). The real app throws the engine away on
every lock (`AppModel.lock()` sets `engine = nil`). With the default auto-lock ("Immediately", `autoLockSeconds = 0`),
that happens on every app switch. Any state held only in memory in `GroupHub`, `GroupCallCenter` or `PrivaEngine` survives
in the tests but is lost on a real iPhone. `MultiDeviceJourneyTests.relaunch` does the right thing (it builds a new
engine); more tests should use it.

## Summary

| Severity | Count |
|---|---|
| Critical | 1 |
| High | 5 |
| Medium | 19 |
| Low | 13 |
| Info | 4 |
| **Total** | **42** |

Top 5:
1. **STA-01 (Critical)**: Group invites and joins are kept only in memory, on both sides. Once the host's app has
   locked even once, an accepted invite is silently dropped. The invitee is told "You joined", but every post they make
   is refused.
2. **STA-02 (High)**: A photo or video posted to a group is lost for good if the host's app locks or relaunches while
   the upload is in progress. The sender sees "Delivered".
3. **STA-03 (High)**: Backgrounding the app during a **group** call (default auto-lock) locks the app and kills the
   call. For a host, it ends the call for everyone. The host's claim on the shared audio session is never released.
4. **STA-04 (High)**: Group failover can split a group in two when a live host has simply been quiet for 72 hours.
5. **STA-06 (High)**: Disappearing messages don't disappear while the app isn't connected. In every case, the chat
   list keeps showing the text of a message that has already disappeared.

---

## Findings (most severe first)

### STA-01 · Critical · state: group invites and joins live only in memory
- **Where:**
  - Host: `Priva/Core/Groups/GroupHub.swift:131` (`pendingInvites.insert`), `:137` (declaration), `:634` (`.join`
    requires `pendingInvites.remove(...) != nil`).
  - Member: `GroupHub.swift:13` (`invites`) and `:627-632`.
  - Neither is restored by `load()` at `:30-37`.
- **What's wrong:**
  - The host accepts a `.join` only if the matching `"gid|user"` is in `pendingInvites`, an in-memory `Set`.
  - The invitee's list of invites is also in memory only.
  - The `.invite` and `.join` packets themselves are durable (queued and persisted), so they arrive later, after
    the state they rely on is gone.
- **Failure scenario A (host side):**
  1. Alice (host) invites Bob. The invite is queued, Bob is offline.
  2. Alice switches apps. Auto-lock "Immediately" calls `lock()`, which builds a new `PrivaEngine` and `GroupHub` on
     the next unlock.
  3. Bob comes online, sees the invite, taps Join. `respond(accept:)` saves the group locally and shows "You joined X."
  4. Alice's host drops the `.join` because `pendingInvites` is empty.
  5. Bob's posts come back "Not delivered: You're not a member of this group". Bob never receives a roster or posts.
- **Failure scenario B (member side):** the invite arrives while Bob is in Priva. Bob switches apps before tapping
  Join, and the invite is gone for good.
- **Fix:**
  - Persist `pendingInvites` with an expiry, for example kv `group-pending-invites` holding `[key: Date]` with a
    30-day TTL. Alternative that needs no state: the invite carries an HMAC over `gid|invitee|epoch` made with a
    host-only key, and the `.join` echoes it back.
  - Persist member invites (kv `group-invites`).
  - On the member, keep a joined group in a "joining" state, not active and not able to post, until the first
    `.state` that lists them arrives.
- **Tests:**
  - `testAnInviteAcceptedAfterTheHostRelaunchesStillJoins`: invite; host relaunched with a new engine (as in
    `MultiDeviceJourneyTests.relaunch`); member accepts; within 30 s the host roster contains the member and the
    member's post is delivered.
  - `testAPendingInviteSurvivesTheInviteesRelaunch`.
- **Confidence:** Confirmed.

### STA-02 · High · data: group attachments are lost if the host relaunches mid-upload; the sender sees "Delivered"
- **Where:**
  - `GroupHub.swift:19` (`pendingFanout`, in memory) and `:280`.
  - `GroupHub.swift:351` (`fileCompleted` returns early when the entry is missing).
  - Member side `:667-683`: `posted(seq: nil, rejected: nil)` sets `.delivered` at `:681`.
- **What's wrong:**
  - The host acknowledges an attachment post before it has fanned it out (it waits for the upload to finish).
  - The mapping from file to post (`pendingFanout`) isn't persisted.
  - `resumeIncomingTransfers` (`PrivaEngine.swift:1520-1542`) does resume the file after a relaunch, but
    `fileCompleted` then finds no entry and returns.
  - The post stays on the host with `seq == nil` and is never sent to anyone.
  - The member already marked it `.delivered`. Because `.delivered` isn't `needsDelivery`, nothing ever retries it.
- **Failure scenario:**
  1. Carol posts a 200 MB video to Alice's group.
  2. Alice switches apps while the upload is under way (auto-lock), then reopens Priva.
  3. The upload resumes and completes. `fileCompleted` returns immediately.
  4. No other member ever sees the video. Carol sees ✓ Delivered.
- **Fix:**
  - In `fileCompleted`, don't depend on memory: look up the message for the file through the persisted
    `incomingFiles[fileID]`. If it is in a group thread this host hosts, has `seq == nil` and `sender != me`, call
    `accept(post:)`. Alternatively, persist `pendingFanout`.
  - On the member, a `posted` with `seq == nil` should leave the post `.sending` ("Uploaded, waiting for the host"),
    not `.delivered`.
- **Test:** `testAGroupPhotoUploadedAcrossAHostRelaunchStillReachesMembers`. The host relaunches with a new engine in
  the middle of the upload. Assert that the third member receives the post and the file bit-exact.
- **Confidence:** Confirmed.

### STA-03 · High · state/privacy: going to the background during a group call locks the app and kills the call; the audio session claim leaks
- **Where:**
  - `Priva/App/AppModel.swift:229`: `inCall = engine?.calls.isInCall`, the 1:1 call only.
  - `AppModel.swift:234` and `:246`: the lock checks.
  - `PrivaEngine.stop()` at `PrivaEngine.swift:200-209` doesn't end either call center.
  - `GroupCallCenter.finish` at `GroupCallCenter.swift:416-438` is the only place that releases its audio claim
    (`:432`).
  - `WebRTCEnv.swift:71-100` (`audioOwners`).
- **What's wrong:**
  - The guard that stops auto-lock during a call ignores `groupCalls.isInCall`. With the default "Immediately",
    pressing Home or the side button during a group call locks the app.
  - On a member, the link to the host closes, so the call ends.
  - On the host, every member link closes (`hostLeave` for each), which ends the call for everyone. The host's own
    `GroupCallCenter` is then released while it still has `call` set, so `finish` never runs.
  - `WebRTCEnv.audioOwners` keeps the stale `ObjectIdentifier(GroupCallCenter)` for good. The shared audio session
    is never deactivated, even by later calls.
  - `Info.plist` declares `UIBackgroundModes: audio`, so keeping calls alive in the background is clearly the intent.
- **Failure scenario:**
  1. The host starts a group voice call and switches to Maps.
  2. Everyone's call ends.
  3. Afterwards the audio session stays active: `releaseAudioSession` never empties the owner set. Other apps' audio
     stays interrupted or ducked, and later calls can't switch the session off.
- **Fix:**
  - `inCall = calls.isInCall || groupCalls.isInCall`.
  - Make `PrivaEngine.stop()` call `calls.hangUp()` and `groupCalls.hangUp()` before it closes links.
  - Add a `deinit` or explicit teardown to `GroupCallCenter` that releases its audio claim.
- **Tests:**
  - `testBackgroundingDuringAGroupCallKeepsTheCall`: with `autoLockSeconds == 0`, `scenePhaseChanged(.background)`
    while `groupCalls.isInCall`; assert the phase is still `.unlocked` and the call is still in progress.
  - `testEngineStopReleasesEveryAudioClaim`: after `engine.stop()` in a hosted group call, assert
    `WebRTCEnv.debugAudioOwners == 0`.
- **Confidence:**
  - Lock and call teardown: Confirmed.
  - Lasting audio-session effect: Likely.

### STA-04 · High · state: group failover can split a group with a live host
- **Where:**
  - `GroupHub.swift:531-557`: `checkFailover` and `hostGone`, where "gone" means `lastSeen` is older than 72 hours.
  - `GroupHub.swift:585-597`: members accept a claim with no directory check when their own view also says the host
    has been silent for 72 hours.
  - `PrivaEngine.swift:738`: `lastSeen` is updated only by rendezvous signals.
  - `GroupHub.swift:545-551`: if the directory lookup fails, the claim is refused once and never retried.
- **What's wrong:**
  - `lastSeen` reflects only when this phone last received a signal from the host. Two people who use Priva at
    different times of day can go 72 hours without that, even though both are active.
  - The successor claims the group without checking the directory itself, and removes the host from the roster
    (`claim`, `:563`).
  - Members who are just as out of date accept immediately. Others do a live lookup, see the host is "active", and
    refuse.
  - The live host refuses any claim against itself.
  - The result is two hosts, each with part of the members. Nothing ever merges them back.
- **Failure scenario:** a quiet 5-member group. The host opens Priva every evening; the successor and two members
  open it in the morning.
  1. On day 4 the successor's `checkFailover` claims the group.
  2. Two members accept; one member and the host keep the old host.
  3. Posts now go to two different hosts.
- **Fix:**
  - Claim only after a live directory lookup by the claimant shows `uninstalled` or `removed`. Treat 72 hours of
    silence only as a reason to check.
  - Members should always do a live check (cache the result for a day), and retry a failed lookup with backoff.
  - When a live host receives a claim against itself, it should re-publish its state with `epoch + 1` to everyone, so
    members who switched can come back.
- **Test:** `testAQuietHostIsNotReplacedWhileItsDirectoryEntryIsActive`. Set the host's `lastSeen` to 73 hours ago on
  the successor and on one member, with the directory entry active. Run `checkFailover()` and assert every member
  still has the original host.
- **Confidence:** Likely.

### STA-05 · High · perf: every group post rewrites the whole group record, including every member's public keys
- **Where:**
  - `GroupHub.swift:39-44` (`save` writes `group:<id>` and the `groups` list).
  - Called per post on the host (`accept(post:)`, `:212`) and per delivered post on every member (`.deliver`, `:700`).
  - Also called from `.posted` (`:672`) and `respond` (`:152`).
- **What's wrong:**
  - `PrivaGroup.members[].bundleRaw` holds each member's roughly 8.6 KB key bundle, which is about 11.5 KB once
    base64-encoded in JSON.
  - Each post, sent or received, JSON-encodes and AES-encrypts the whole roster and writes it to SQLite on the main
    thread. `save(g)` in `.deliver` runs even when `lastSeq` didn't change.
  - `groups` is `@Observable`, so every save also re-renders every view that observes it.
- **Failure scenario:** in a 100-member group, each delivered post costs about 1.2 MB of JSON and encryption plus a
  1.2 MB SQLite write. A catch-up of 200 posts writes about 230 MB and freezes the UI for seconds on an iPhone. The
  host pays the same per post, on top of one `enqueueGroup` write per member (`:219`, not in one transaction).
- **Fix:**
  - Keep `lastSeq` (and other per-post counters) in a separate small kv row, `group-seq:<id>`.
  - Store member bundles separately, written only when the roster changes.
  - Do the host's per-member `enqueueGroup` writes in one transaction per post.
- **Test:** `testGroupPostCostDoesNotScaleWithRosterSize`. Deliver 200 posts to a member of a 100-member group and to
  a member of a 3-member group. Main-thread time and bytes written should be within 1.5× of each other.
- **Confidence:** Confirmed (code). Magnitude: Likely.

### STA-06 · High · privacy/state: disappearing messages don't expire while offline, and expired text stays in the chat list
- **Where:**
  - `PrivaEngine.swift:534`: `tick()` returns unless `realtimeStatus == .connected`. Expiry runs from inside it, at
    `:580-583`.
  - `PrivaEngine.swift:185`: an account that moved never starts the ticker at all.
  - `PrivaEngine.swift:1483-1488`: `expireDisappearing` removes the message from `threads` but doesn't call
    `updateSummary` or `refreshGroupActivity`.
- **What's wrong:**
  - Expiry only runs while the rendezvous socket is connected: not in airplane mode, not when the relay is down, not
    while Tor bootstraps, not on an old phone after "Your account moved".
  - At unlock, `start()` builds the chat summaries before the first connected tick. Messages that expired while the
    phone was locked are therefore shown in the chat list, and stay readable in the chat until the app connects.
  - Even when connected, the chat list's preview (`Summary.last`) keeps the expired message's text and unread count
    until something else refreshes that row.
- **Failure scenario:**
  1. Bob receives "meet at 7, door code 4411" with a 5-minute timer.
  2. Ten minutes later, on the subway with no signal, he opens Priva. The message is still in the chat.
  3. Back online, the message leaves the chat, but the Chats tab still shows "meet at 7, door code 4411" as that
     chat's preview.
- **Fix:**
  - Run the expiry sweep on its own timer, independent of connectivity, and once in `start()` before `reload()`.
  - Use `expireMessages` results to `updateSummary` each affected thread.
  - Also drop cached thumbnails (`MediaVault.thumbs`) for expired attachments.
- **Test:** `testDisappearingMessagesExpireOfflineAndLeaveNoPreview`. Keep the realtime client disconnected, insert a
  message with `expiresAt` in the past, start the engine. Assert the store has no such row and no `summaries[].last`
  or `groupActivity` refers to it.
- **Confidence:** Confirmed.

### STA-07 · Medium · data/perf: the unread badge can never reach zero; opening a chat does one write per message
- **Where:**
  - `PrivaEngine.swift:419-425` (`markRead` covers only `loadThread`, the newest 400).
  - `Store.swift:202-204`: the unread count covers the whole thread.
  - `PrivaEngine.swift:422`: one `store.save` plus one `upsertInThread` per message (copy-on-write of the thread
    each time).
- **What's wrong:**
  - With more than 400 unread messages (for example, a busy group while you were away), the messages beyond the
    newest 400 are never marked read. The badge stays at N − 400 forever.
  - Opening a chat with 400 unread messages also costs 400 separate SQLite writes and about 160k message copies on
    the main thread.
- **Fix:**
  - Add `Store.markRead(thread:)`: select `id, blob WHERE h = ? AND unread = 1`, set `readAt`, and write everything in
    one transaction.
  - Update the cached thread in one pass.
  - Send read receipts in chunks of 500.
- **Test:** `testOpeningAChatWithAThousandUnreadClearsTheBadge`. Assert `unreadCount == 0` and a single transaction.
- **Confidence:** Confirmed.

### STA-08 · Medium · state/UX: chat history beyond about 600 messages can't be reached
- **Where:**
  - `ChatView.swift:20` and `:58`: `loadedOlder` is set once per view and never reset.
  - Group chats have no older-page loading at all (`GroupViews.swift:341`, 400 newest only).
  - `PrivaEngine.swift:293-299` and `Store.swift:181-186`: the page boundary is `ts < first.sentAt`, so rows that
    share the boundary millisecond are skipped.
- **What's wrong:**
  - A 1:1 chat loads one extra page of 200 per visit. The cache keeps it, so each later visit adds another 200. Depth
    depends on how often you open the chat.
  - Group chats never go past the newest 400.
  - This contradicts SYSTEM_DESIGN §11 ("no hitches with 10k msgs, paged loading").
- **Fix:**
  - Page with an `(ts, id)` cursor (`ORDER BY ts DESC, id DESC` with `(ts, id) < (?, ?)`).
  - Re-arm loading whenever the top sentinel appears and the last page was full.
  - Add the same paging to the group chat.
- **Test:** `testScrollingUpReachesTheFirstMessage`, with 2,000 messages including a pair that share a timestamp.
- **Confidence:** Confirmed.

### STA-09 · Medium · perf/battery/quota: stuck incoming transfers keep a connection wanted forever; long transfers get idle-closed
- **Where:**
  - `PrivaEngine.swift:529-531`: `hasPending` counts any active incoming file.
  - `PrivaEngine.swift:563-566`: idle close doesn't consider transfers.
  - `PeerLink.swift:149`, `:478`, `:542`: `lastActivity` is updated only by control frames, never by bulk chunks.
  - `PrivaEngine.swift:1510-1516`, `:1592-1594`: `fileWant` is sent only at the start and when a link becomes ready.
  - `PrivaEngine.swift:1662-1669`: a `fileWant` the sender can't serve is silently ignored.
  - `PrivaEngine.swift:514-519`: "Delete for me" removes the media but leaves `outgoingFiles`.
  - `GroupHub.swift:425-432`: a host's own delete removes a file it still serves.
- **What's wrong:**
  - An incoming transfer can wait forever, and nothing ever times it out or abandons it. That happens when:
    - the sender deleted or expired the message,
    - the host's 90-day rule removed the file,
    - the sender's `outgoingFiles` contact is now a different username (after a restore),
    - a chunk was dropped on a link that is still up.
  - Meanwhile `hasPending` stays true. The engine connects, the link idles 5 minutes and closes, and the engine
    connects again (attempts reset to 0 each time). That costs about 4 metered signals per 5 minutes for every stuck
    file, for as long as the app is open.
  - Separately, a transfer that runs longer than 5 minutes without control traffic, with the chat not open on that
    side, is cut by the idle sweep. It then resumes after a fresh handshake, every 5 minutes.
- **Failure scenario:** Alice sends a video, then uses "Delete for me" before Bob finishes downloading it. Bob's phone
  reconnects to Alice roughly every 5 minutes for the rest of the session. His attachment shows a spinner forever.
- **Fix:**
  - Count bulk send and receive in `lastActivity`, or treat a link with an active transfer as busy.
  - Re-send `fileWant` for missing chunks when a ready link has made no progress for 30 seconds.
  - Add a `fileGone(fileID)` reply. The receiver then marks the attachment unavailable and drops the transfer.
  - Give up after N reconnects without progress.
  - On "Delete for me", clear `outgoingFiles` for that file.
- **Tests:**
  - `testAnIncomingFileWhoseSenderDeletedItStopsBeingRequested`: assert `linkAttempts` stops growing.
  - `testATransferLongerThanTheIdleTimeoutIsNotCut`: shorten `idleLinkTimeout` in the test.
- **Confidence:** Confirmed.

### STA-10 · Medium · quota: `requestLink` bypasses retry backoff, so group fan-out dials every offline member on every post
- **Where:**
  - `PrivaEngine.swift:653-658`: sets `nextAttempt = .distantPast` and dials whenever no link exists.
  - Callers: `GroupHub.swift:61` (every send), `:220` (fan-out per member per post), `:372`, `:92` (immediate redial
    after a close), `:197`; `GroupCallCenter.swift:126`.
- **What's wrong:** the 6 s to 5 min backoff (A24) applies only to the scheduler. The group code calls `requestLink`
  for every offline member each time it has something to send. Each call is one metered hello, and is repeated as
  soon as the previous handshake times out (10 s).
- **Failure scenario:** a host in a 40-member group with 30 members offline posts 100 times in a day, more than 10 s
  apart. That's about 3,000 hello signals, against the 4-signal budget per connection the free-tier work aimed for.
  Every `publish` (a join, rename or rules change) adds another round of 30.
- **Fix:**
  - `requestLink` honours `nextAttempt` unless the caller is user-initiated (calls).
  - The group code relies on the scheduler. `peersNeedingLink` already reports those members.
- **Test:** add to `FreeTierBudgetTests`: `testAHostPostingToOfflineMembersRespectsBackoff`. Ten posts 15 s apart to
  5 offline members send at most about 5 × (number of backoff slots) hellos.
- **Confidence:** Confirmed.

### STA-11 · Medium · quota/state: after a handover, disband or lost failover, the old host's member queues are never emptied, causing endless reconnects
- **Where:**
  - `GroupHub.swift:875-887`: `peersNeedingLink` adds every member that has rows in `group_outbox`, whatever the
    group's state.
  - `:865-868` and `:858-862`: `deliverPending` runs only for groups where `host == me && !ended`.
  - `:437-443`: disband doesn't clear the queue.
  - `:513-527`: handover doesn't clear it either. Neither does losing a failover.
- **What's wrong:** queued posts for members who were offline stay on the former host. The scheduler keeps connecting
  to those members, the links idle out, and it connects again. Nothing ever delivers or removes the rows.
- **Fix:**
  - Clear a group's queue rows on disband, on handover (the new host re-syncs through `.sync`), and when another host
    takes over.
  - Count only hosted, not-ended groups in `peersNeedingLink`.
- **Test:** `testADisbandedGroupLeavesNoQueueAndNoReconnects`. Disband with an offline member; assert
  `groupQueueMemberHashes()` is empty and `linkAttempts` stays flat for 10 minutes of simulated ticks.
- **Confidence:** Confirmed.

### STA-12 · Medium · error/backoff: username revocation is retried every 1.5 s with no in-flight guard
- **Where:** `PrivaEngine.swift:1299-1317` (`runMigrationDuties`, called from every tick).
- **What's wrong:**
  - Every tick starts a new `api.revoke` for each due revocation while earlier calls are still in flight.
  - On a network error or 5xx it returns without backoff, so the next tick tries again.
- **Failure scenario:** during a Supabase slowdown (20 s request timeout), one phone can have about 13 revoke requests
  in flight at once, and keeps sending one every 1.5 s for as long as it lasts. That eats into the free plan's daily
  request limit.
- **Fix:** track in-flight revocations in a set, and on failure back off exponentially from 30 s up to 1 h.
- **Test:** `testARevocationIsSentOnceAndBacksOffOnServerErrors`, using an API stub that counts calls.
- **Confidence:** Confirmed.

### STA-13 · Medium · error/backoff: a failing relay-pass refill is retried on every signal
- **Where:**
  - `RelayPass.swift:27-36` and `:55-64`.
  - Callers: `API.swift:268-273` (every broadcast, including `SignalOutbox` retries) and `Realtime.swift:129` (every
    socket open).
- **What's wrong:**
  - Nothing remembers a failure. If there is no pass for today, every `header()` call waits for a full refill: an
    App Store proof (`AppTransaction.shared`) plus an issuer round trip.
  - With fewer than 7 passes left, every call starts a background refill.
  - If the relay-pass function fails (monthly limit, outage, Tor not ready), each signal and each of its four retries
    triggers another fetch.
- **Fix:** remember the last failure, back off from 1 min up to 1 h, and treat limit errors (429/409) as hard stops
  until the next UTC day.
- **Test:** `testAFailingPassIssuerIsAskedAtMostOncePerBackoff`. With the stub failing, 50 broadcasts lead to at most
  one fetch.
- **Confidence:** Confirmed.

### STA-14 · Medium · state: killing the app right after registration loses the friend announcements and the old-username removal
- **Where:**
  - `AppModel.swift:391-398`: `markRegistered`, then `pendingMigration` is built in memory and `Vault.storeRevocation`
    overwrites the previous record.
  - `OnboardingViews.swift` `open()`: the migration is saved to the engine only when "Open Priva" is tapped.
- **What's wrong:** between "username registered" and the user tapping "Open Priva", which can be minutes, the
  migration exists only in `OnboardingModel`. That migration holds the signed announcements and the old username's
  revocation secret.
- **Failure scenario:**
  1. A returning user signs back in. The new name registers.
  2. iOS kills Priva on the "You're all set" screen.
  3. On relaunch the vault is registered, so the app goes straight to `.unlocked`. No announcement goes to friends,
     and the old username stays "active" in the directory until its lease lapses.
  4. The old revocation record has already been overwritten, so the phone can no longer remove it.
- **Fix:** before `markRegistered`, persist the migration in a device-only Keychain item, or straight into the store.
  Have `didUnlock` pick it up.
- **Test:** `testKillingAfterRegistrationStillRemovesTheOldUsername`. Simulate the kill by discarding
  `OnboardingModel` after `register()` returns; after unlocking, assert `migration.revocations` contains the old
  commit.
- **Confidence:** Confirmed.

### STA-15 · Medium · error: if the store can't open at unlock, the lock screen spins forever
- **Where:**
  - `AppModel.swift:105-139`: `didUnlock` catches the `Store` error and sets `phase = .locked`, which it already is.
  - `LockView.swift:150-161`: the stage stays `.unlocking`.
  - `LockView.swift:93-95`: `lockEpoch` is ignored while unlocking.
- **What's wrong:** the error is swallowed. The `LockView` instance stays in `.unlocking`, so the button shows a
  spinner forever and Face ID never re-arms. Possible causes: SQLite can't open, the v3 migration fails on a full
  disk, file protection.
- **Fix:** make `didUnlock` report failure (`throws` or returns `Bool`). In `LockView`, reset to `.password` and show
  "Couldn't open your data. Free up storage and try again."
- **Test:** `testAStoreThatCantOpenShowsAnErrorAndAllowsRetry` (inject a failing `Store`).
- **Confidence:** Confirmed.

### STA-16 · Medium · error/state: "Welcome back" misreports erase and lockout
- **Where:** `LockView.swift:350-357` (`WelcomeBackView.unlock`) and `Vault.swift:133-141`.
- **What's wrong:** every failure except `.biometric(.invalidated)` is shown as "Wrong password.", including:
  - `.wiped`: erase-after-10 just deleted everything;
  - `.lockedOut`: the attempt wasn't even made;
  - `.notSetUp`.
- **Failure scenario:** after a reinstall, with "Erase after 10 tries" on, a 10th wrong password erases the vault.
  The screen still offers "Sign back in", and every later try says "Wrong password." while there's nothing left to
  unlock.
- **Fix:** handle the cases explicitly:
  - `.wiped`: call `model.wipe()`.
  - `.lockedOut(until)`: show a countdown.
  - `.notSetUp`: go to onboarding.
- **Test:** `testWelcomeBackAfterTenWrongPasswordsWithEraseOnGoesToWelcome`.
- **Confidence:** Confirmed.

### STA-17 · Medium · state: in Tor mode, relay credentials are fetched before Tor is ready, then not retried for 30 minutes
- **Where:**
  - `PrivaEngine.swift:186-191`: `TorService.start()`, then `ManagedRelay.refreshIfNeeded()` straight away.
  - `WebRTCEnv.swift:204-223`: any failure means "ask again in 30 minutes".
  - `WebRTCEnv.swift:59`: onion mode is relay-only.
- **What's wrong:**
  - In onion mode, API requests fail until Tor's circuit is up. That often isn't the case at unlock, because Tor
    bootstrap takes 5–30 s.
  - The TURN fetch fails and is cached as "none" for 30 minutes.
  - Relay-only ICE with no TURN servers can't connect, so every connection times out for up to 30 minutes.
  - `whenReady` re-configures only the realtime socket, not the relay credentials.
- **Fix:**
  - In `TorService.whenReady`, also refresh relay credentials (add `ManagedRelay.refresh(force:)`).
  - Use a short backoff (30 s) for network errors, and the long one only for "none configured" (204).
- **Test:** `testOnionModeFetchesRelayCredentialsOnceTorIsReady` (SOCKS stub that becomes ready after 5 s).
- **Confidence:** Likely.

### STA-18 · Medium · state: silently re-accepting a re-sent request replaces the pair root and can desync the friendship
- **Where:**
  - `PrivaEngine.swift:935-940`: `receivedRequest` re-accepts silently when the contact exists with the same keys.
  - `PrivaEngine.swift:964-1005`: `accept` sets `c.pair = pair`, a brand-new root with `previous = nil`, and replaces
    the control item with the same id.
- **What's wrong:**
  - The requester keeps re-sending the identical request envelope until it gets an acceptance.
  - After the 10-minute replay window, the acceptor accepts it again and generates a new pair root.
  - If the first acceptance had already reached the requester (who then dropped its outgoing request), the second is
    refused (`openAcceptance` finds no outgoing request).
  - The two phones then hold different roots and can never connect again. Each side's signals fail to open on the
    other.
- **Failure scenario:** Bob accepts while Alice is offline. Alice comes online. Her retried request reaches Bob just
  after Bob's retried acceptance P1 was sent. Alice processes P1. Bob re-accepts and replaces it with P2. Alice
  refuses P2. They are now permanently unable to connect.
- **Fix:** when the contact exists and its pair came from this same `rid`, resend the stored acceptance instead of
  making a new one. Or keep the old root as a candidate:
  `PairSecrets(current: new, previous: old.current, epoch: …)`.
- **Test:** `testARepeatedRequestAfterAcceptanceDoesNotBreakThePair` (deliver P1, then the duplicate request; assert
  a message round trip works).
- **Confidence:** Possible.

### STA-19 · Medium · state: friend-request lifecycle gaps (declines lost, endless retries, one-sided contacts)
- **Where:**
  - `PrivaEngine.swift:1044-1050`: a decline is broadcast once, fire-and-forget. `ControlItem.Kind.decline` exists
    (`Models.swift:186`) but is never used.
  - `PrivaEngine.swift:836-853`: outgoing requests are retried forever.
  - `FriendProtocol.swift:88-89`: the receiver refuses requests older than 30 days.
  - `PrivaEngine.swift:855-858`: cancelling an outgoing request tells nobody.
- **What's wrong:**
  - **Decline lost:** a decline sent while the requester is offline is lost. The request keeps retrying, and after the
    10-minute replay window it shows up again as a new "Friend request" for the person who declined it.
  - **Endless retries:** a request is retried every ≤ 5 minutes forever. After 30 days every retry is refused, but the
    sender still shows "pending".
  - **One-sided contact:** if Alice cancels a request that Bob later accepts, Bob gets a contact and "You're now
    connected", and his messages queue forever.
- **Fix:**
  - Queue declines as a `ControlItem(kind: .decline)`.
  - Remember declined request ids for 30 days and drop repeats.
  - Expire outgoing requests after 30 days, and show "expired" in the UI.
  - Send a sealed "withdrawn" notice on cancel. The recipient removes the request.
- **Tests:**
  - `testADeclineReachesAnOfflineRequesterAndTheRequestDoesNotReturn`.
  - `testRequestsOlderThan30DaysStopRetrying`.
  - `testAWithdrawnRequestCannotBeAccepted`.
- **Confidence:** Confirmed.

### STA-20 · Medium · privacy/state: blocked group-mates still get presence, and hidden group-only contacts are never removed
- **Where:**
  - `PrivaEngine.swift:679-697`: `announcePresence` covers all recent contacts, including `groupOnly` and blocked ones.
  - `PrivaEngine.swift:1400-1408`: blocking someone who shares a group turns them into a `groupOnly` contact.
  - `PrivaEngine.swift:471-477`: `installGroupLink` creates hidden contacts, and nothing ever removes them.
- **What's wrong:**
  - Someone you blocked but still share a group with gets an "I'm online" signal on every unlock and reconnect.
    Blocking doesn't hide your presence from them.
  - Hidden successor links pile up across groups that have ended. They get presence signals (metered), are tried in
    `processSignal` trial decryption, are swept in the directory checks, and are messaged by
    `reconnectAfterRestore`.
- **Fix:**
  - Leave blocked contacts out of presence.
  - Delete `groupOnly` contacts when no live group references them (check on leave, disband and forget, and in the
    hourly duties).
- **Test:** `testABlockedGroupMemberGetsNoPresence` (WireTap count of presence signals to the blocked inbox is 0).
- **Confidence:** Confirmed.

### STA-21 · Medium · perf: one observable `threads` dictionary re-renders the open chat on any thread change
- **Where:**
  - `PrivaEngine.swift:72` (`threads`), `:1544-1556` (progress 10×/s goes through `upsertInThread`), `:1673`
    (`uploadProgress`).
  - `ChatView.swift:34-49`: `items` rebuilds the whole list with Calendar calls on every body evaluation.
- **What's wrong:** `@Observable` tracks `threads` as one property. Any of the following re-renders the open
  `ChatView` and recomputes the O(n) item list:
  - an incoming message in any chat;
  - a receipt;
  - transfer progress, 10 times a second.
  A download running in another chat makes the open chat recompute its 400–600-item list 10 times a second.
- **Fix:**
  - Use a per-thread observable (`ThreadModel` objects in a dictionary), or a separate observable progress store.
  - Cache `items` until the thread array changes.
- **Test:** perf test `testTransferProgressElsewhereDoesNotRebuildTheOpenChat` (count `items` evaluations).
- **Confidence:** Likely.

### STA-22 · Medium · perf: launch makes a blocking iCloud call on the main thread
- **Where:**
  - `AppModel.swift:41`: `BackupLocations.removeLeftovers()` runs from `AppModel.init`.
  - `BackupService.swift:304-312` calls `icloudDirectory()` (`:139-146`).
  - `icloudDirectory()` uses `url(forUbiquityContainerIdentifier:)`, which the code itself documents as "Blocking:
    call off-main".
- **What's wrong:** on a first launch, or with slow iCloud, launch blocks for up to seconds. That risks the launch
  watchdog and delays the lock screen.
- **Fix:** run `removeLeftovers` in a background `Task.detached(priority: .utility)`.
- **Test:** launch-time budget in `PerformanceJourneyTests`, plus a main-thread checker assertion in the debug build.
- **Confidence:** Confirmed.

### STA-23 · Medium · state: a stale roster can reopen a group you left or were removed from
- **Where:** `GroupHub.swift:642-663` (`.state` accepted when `epoch >= local` and `host == peer`) and `:746-751`
  (`leftLocally` only sets `ended`).
- **What's wrong:**
  - Leaving or being removed doesn't change the local epoch.
  - A `.state` that was queued earlier on the host (it's durable and persisted) can arrive afterwards, replace the
    group with `ended = false`, and bring it back as active.
  - The member isn't in its roster, so their posts are refused.
- **Fix:** ignore `.state` for groups that are locally `ended`, or where `me` isn't in `next.members`.
- **Test:** `testAStaleRosterDoesNotReopenALeftGroup`.
- **Confidence:** Possible.

### STA-24 · Medium · state: calls drop on any network change (no ICE restart)
- **Where:**
  - `PeerLink.swift:1005-1021`: ICE `.disconnected` for 4 s closes the link. `.failed` closes it straight away.
  - No `restartIce` anywhere.
  - `CallCenter.linkClosed` (`CallCenter.swift:71-78`) then ends the call ("Connection lost").
  - `SYSTEM_DESIGN.md:326` claims "ICE restart on network change".
- **What's wrong:** moving from Wi-Fi to cellular, a short dead zone, or a VPN reconnect all end the call. The
  replacement link starts a fresh handshake, but the call doesn't come back.
- **Fix:** during a call (or while `mediaActive`), on `.disconnected` start an ICE restart: `pc.restartIce()`, then a
  new offer over the data channel (the existing renegotiation path) or over the signal path if the data channel is
  down. Close only if that fails within about 10 s.
- **Test:** `testACallSurvivesANetworkSwitch` (simulate with interface toggling on the simulator, or with a TURN
  relay drop).
- **Confidence:** Confirmed (missing feature); user impact Likely.

### STA-25 · Medium · data: media files and messages are left behind when friends are removed or blocked, or a group is forgotten
- **Where:**
  - `PrivaEngine.swift:1368-1376`: `removeFriend` deletes media only for the in-memory thread. The SQL in
    `deleteContact` (`Store.swift:144-153`) deletes the rows but not the files.
  - `PrivaEngine.swift:1400-1404`: blocking someone who shares a group deletes only the newest 400 messages.
  - `GroupHub.swift:736-744`: `forget` deletes only the newest 400 messages and doesn't clear `group_outbox` or
    `groupFiles`.
- **What's wrong:**
  - Removing a friend whose chat wasn't opened this session leaves every one of their media files on disk. The files
    are encrypted, but their keys are deleted with the rows, so this is an unbounded storage leak.
  - Older messages of a blocked group-mate stay in the database and reappear if you become friends again.
  - A forgotten group keeps every message beyond the newest 400.
- **Fix:**
  - Delete by query: select the media file ids for `h` (the `media` index), remove the files, then delete the rows.
  - Add an unlock-time (background) orphan sweep: files in `media/` minus the file ids referenced in `messages`.
- **Test:** `testRemovingAFriendDeletesAllTheirMedia` (1,000 media messages, never opened; assert the media directory
  is empty for them).
- **Confidence:** Confirmed.

### STA-26 · Low · state: a 1:1 call can turn "active" before any media flows
- **Where:** `CallCenter.swift:195` and `PeerLink.swift:911-912` and `:930-934`.
- **What's wrong:** `inKbps` comes from the transport's `bytesReceived`, which includes data-channel traffic. The
  renegotiation SDP sent right after accept (several KB in 250 ms) is enough to cross 1 kbps. The 20 s "Couldn't
  connect" timeout is then cancelled, and the duration starts early, even if media never decrypts.
- **Fix:** decide "active" from inbound-rtp `packetsReceived` for audio (and `framesDecoded` for video), and require
  `cryptorFailures == 0`.
- **Test:** `testACallWithUndecryptableMediaEndsWithCouldNotConnect` (use `debugScrambleReceiveMediaKey`).
- **Confidence:** Likely.

### STA-27 · Low · data: one refused chunk silently stalls the bulk channel for the rest of the session
- **Where:** `PeerLink.swift:1082-1098` (the counter is consumed in `seal`, then `sendData` returns false) and
  `Protocol.swift:279` (the receiver requires a strictly sequential counter).
- **What's wrong:** this is the same issue A8 fixed for the control channel. After one refused bulk send, every later
  chunk fails the counter check and is dropped (`try?`), while the link still reports ready. All transfers on that
  link stall until it closes.
- **Fix:** on `sendData == false`, close the bulk channel and the link (as `transmit` does), or ask the main actor to
  `close(.failed)`.
- **Test:** `testARefusedChunkClosesTheLinkInsteadOfStallingTransfers`.
- **Confidence:** Possible.

### STA-28 · Low · perf: whole-history loads and per-row writes on the main thread
- **Where:**
  - `Store.swift:157` (`migrateConversation` loads up to 1M messages).
  - `GroupHub.swift:845-852` (`renameSender`: 1M loaded, saved row by row).
  - `PrivaEngine.swift:1160-1181` (`reconnectAfterRestore`: one ML-DSA signature and one DualSeal per contact in a
    single tick).
  - `Store.swift:300-302` (`clearGroupQueue` row by row).
- **Fix:** page these, run them in transactions, and move them off the main actor.
- **Confidence:** Confirmed (cost grows with history and with the number of contacts).

### STA-29 · Low · stray/weird: settings that do nothing; the display name is sent on every keystroke
- **Where:**
  - `Models.swift:212`, `:215`, `:216`: `screenSecurity`, `showNamesInCallScreen` and `blockThirdPartyKeyboards` are
    never read. `AppDelegate` always blocks keyboards.
  - `PrivaEngine.swift:59-66` with `SettingsViews.swift:140`: every keystroke in "Your name" re-encrypts the settings
    row and sends a `.profile` frame to every connected friend. Friends see partial names, and each one triggers
    `rebuildSummaries`.
- **Fix:**
  - Remove or wire up the dead settings.
  - Debounce the profile broadcast (send when the field loses focus, or after 1 s idle).
- **Confidence:** Confirmed.

### STA-30 · Low · weird: after a restore, the user is never made to save the new recovery phrase
- **Where:** `AppModel.swift:126` (the phrase step is skipped when `restored != nil`) and `OnboardingViews.swift:585`
  (only a note).
- **What's wrong:** a restore creates a brand-new seed, so the old phrase no longer works for this account. Sign-up
  forces the phrase step (SYSTEM_DESIGN §10 principle 4); restore only shows a one-line note. A user who skips the
  note has no way to reset a forgotten password.
- **Fix:** show the phrase step, or a mandatory "save your new recovery key" step, after the restore summary.
- **Confidence:** Confirmed.

### STA-31 · Low · error: non-password failures count as wrong passwords
- **Where:** `Vault.swift:125-141`.
- **What's wrong:** any error after the biometric step counts toward the lockout and toward erase-after-10. That
  includes scrypt failing to allocate memory (A1 shows this happens), and `KeyBundle.parse` or `IdentityKeys` errors.
- **Fix:** count only an AES-GCM authentication failure on `wrapPassword`.
- **Confidence:** Possible.

### STA-32 · Low · data: the fail-closed username derivation can be stored permanently for your own account
- **Where:** `Identity.swift:101-120` (a random value returned under memory pressure) and `Vault.swift:96` and
  `:158` (cached into `VaultMeta.requestTopic` and `ucommit`).
- **What's wrong:** for other people's names, a random result is safe. For your own name at vault creation, a random
  request topic is stored for good: the account never receives friend requests. A random `ucommit` gets registered,
  so the name can't be found.
- **Fix:** have `derive` throw. `Vault.create`, `changeUnregisteredUsername` and `myRequestTopic` should fail and
  retry rather than store a random value.
- **Confidence:** Possible.

### STA-33 · Low · concurrency/lifetime: a backup keeps running after lock or restore
- **Where:** `BackupService.swift:535-575` (`backUpNow` runs a detached export that holds `store`) and `PrivaEngine.stop`.
- **What's wrong:**
  - Locking doesn't cancel the export. The `Store`, with its row key, stays in memory until the export finishes.
  - The result is saved into a released `BackupCenter`, so `lastBackup` is lost and the backup is redone at the next
    unlock.
  - After a restore, a backup of the replaced account can still land in the backup folder and push real backups out
    through `prune`.
- **Fix:** keep the export `Task`, cancel it in `engine.stop()`, and check `Task.isCancelled` per page.
- **Confidence:** Likely.

### STA-34 · Low · state: `linkDidBecomeReady` keeps going after a send closed the link
- **Where:** `PrivaEngine.swift:1585-1600`.
- **What's wrong:** if a pending-message send fails mid-loop, `transmit` closes the link and `linkDidClose` runs. The
  code then still calls `calls.linkReady(link)`. A dialing call moves to `.ringing` on a dead link and waits out the
  45 s timeout.
- **Fix:** after each send, `guard link.isReady else { return }`.
- **Confidence:** Possible.

### STA-35 · Low · error: the replay cache blocks reprocessing of identical re-sent envelopes
- **Where:** `PrivaEngine.swift:708` and `:1755-1765`. The envelope is recorded as "seen" before it is opened, while
  friend requests and acceptances are re-sent byte for byte.
- **What's wrong:** if the first attempt fails for a temporary reason (for example, the directory lookup in
  `processFriendRequest`, `:871-875`, fails), every retry within 10 minutes is dropped.
- **Fix:** record the digest only after successful processing, or forget it when processing fails.
- **Confidence:** Confirmed (impact: up to 10 minutes of delay).

### STA-36 · Low · state: `Contact ==` ignores many fields
- **Where:** `Models.swift:43-47`. It leaves out `groupOnly`, `keyChangedAt`, `bundleRaw`, `inboxTopic`,
  `announceKey`, `addedAt` and `directoryCheckedAt`.
- **What's wrong:** SwiftUI diffing and `Summary`'s synthesized `==` may skip re-rendering when only those fields
  change, for example the key-changed chip.
- **Fix:** use the synthesized `Equatable`, or include every field shown in the UI.
- **Confidence:** Possible.

### STA-37 · Low · lifetime: Tor ready-handlers pile up and a failed Tor is never retried
- **Where:** `TorService.swift:48-50`, `:115`, `:122`. Every unlock appends a handler. A `.failed` state stays until
  the app relaunches.
- **Fix:** replace the handler instead of appending, and retry with backoff.
- **Confidence:** Confirmed.

### STA-38 · Low · perf: Keychain reads on hot paths
- **Where:**
  - `RelayPass.stored` decodes from the Keychain on every broadcast and every socket open.
  - `LockView.lockout` reads the Keychain every second through the timer.
  - `NetworkPrivacy` is cached; these two are not.
- **Fix:** cache the passes in memory behind the existing lock.
- **Confidence:** Confirmed.

### STA-39 · Info · weird: undelivered disappearing messages vanish from the sender's queue
- **Where:** `PrivaEngine.swift:434-437` (`expiresAt` counts from send) and `Store.swift:209-216` (deletes rows
  where `pending = 1`).
- **What's wrong:** a queued message whose timer runs out is deleted before it was ever delivered, and nothing says
  so. Either count the timer from delivery for the sender's copy, or show "expired before delivery".

### STA-40 · Info · quota: rename announcements are re-broadcast every 60 s for 30 days
- **Where:** `PrivaEngine.swift:1295-1298` and `AppModel.swift:418-425`.
- **What's wrong:** that's 2 metered relay messages a minute while the app is open, for a month. Back off, for
  example hourly after the first day.

### STA-41 · Info · data: schema changes can make existing rows unreadable without any error
- **Where:** `Models.swift` (synthesized `Codable` on `Contact`, `Message` and `PrivaGroup`, with non-optional
  defaulted `var`s) and `Store.rows` (`Store.swift:127-129`, which skips rows that don't decode).
- **What's wrong:** adding a non-optional field in a future version would make every existing row fail to decode. The
  rows would then be skipped silently: contacts and chats "disappear" after an update.
- **Fix:** write tolerant decoders, as `PrivaSettings` does, and add fixture tests that decode v1 rows.

### STA-42 · Info · weird: the docs and the code disagree

| Topic | Docs say | Code does |
|---|---|---|
| CallKit (SYSTEM_DESIGN §9) | Calls use CallKit | Not implemented |
| ICE restart (§9) | Restart on network change | None; see STA-24 |
| Video degradation (§9) | `maintainFramerate` | `.balanced` (`PeerLink.swift:693`) |
| Padding buckets (§6.5) | 2/8/16/32 KB | 2 KiB steps up to 8 KiB (A25) |
| StoreKit after sign-up (R2, §5) | "StoreKit never queried again" | `RelayPass.fetch` asks `AppTransaction` for a proof every month |
| Handshake cost (§6.5) | "≈ 1 RTT to the Supabase region" | Signalling now goes through Cloudflare |

---

## Dead / redundant code to remove

**Dead code and no-ops:**
- `Priva/Core/Groups/GroupHub.swift:269`: `att?.progress = e.attachment == nil ? 0 : 0`, a no-op.
- `Priva/Core/Groups/GroupHub.swift:274`: `m.status = .received`, already set at `:271`.
- `Priva/Core/P2P/PeerLink.swift:1069` and `:1116`: `BulkChannel.onOpen` is never assigned.
- `Priva/Core/P2P/PeerLink.swift:33`, `:936`, `:940`, `:461`: `localCandidateType` and `refreshCandidateType` are
  written but never read by the app.
- `Priva/Core/P2P/PeerLink.swift:942-964`: `InboundStream` and `inboundStreams()` are test-only. Wrap them in
  `#if DEBUG`.
- `Priva/Core/Engine/PrivaEngine.swift:1703-1706`: `ping(_ username:)` is unused by the app.
- `Priva/Core/Engine/PrivaEngine.swift:1561`: `isValidGroup` is a pure alias of `isValid`.

**Values that are never produced:**
- `Priva/Core/Storage/Models.swift:105`: `OutgoingRequest.State.accepted` and `.declined` are never set (only
  `.pending` is). The filter at `PrivaEngine.swift:214` is then redundant.
- `Priva/Core/Storage/Models.swift:186`: `ControlItem.Kind.decline` is never produced; see STA-19.
- `Priva/Core/Storage/Models.swift:198` and `PrivaEngine.swift:1500`: `CallRecord.Outcome.failed` is never produced.
- `Priva/Core/Storage/Models.swift:83`: `Message.Status.failed` and `.sending` are never produced for 1:1 messages,
  only for groups. The 1:1 "Retry now" for `.failed` is unreachable (`ChatView.swift:341`).
- `Priva/Core/Storage/Models.swift:212`, `:215`, `:216`: unused settings; see STA-29.
- `Priva/Core/Backup/BackupService.swift:547`: `BackupManifest.mediaCount` is always written as 0 and never read.

**Comments in the wrong place:**
- `Priva/Core/Engine/PrivaEngine.swift:1224-1228`: two doc comments stacked on `refreshTopics`.
- `Priva/Core/Storage/Models.swift:161`: the `MovedAway` doc comment sits above `BlockedUser`.

**Duplicated logic to merge:**
- The "busy" predicate (in a call, a group call, `mediaActive`, the open chat) appears three times: `PrivaEngine.swift`
  `:543`, `:564` and `:629`. Make it one `isBusy(peer:)`.
- The summary sort closure appears twice: `PrivaEngine.swift:225` and `:241`.
- The conversation-move code appears twice, in `finishMove` (`:1008-1031`) and the migrate branch of
  `receivedAcceptance` (`:1094-1105`). Make it one `moveConversation(from:to:)`.
- Face ID approval renewal is written twice: `LockView.swift:144-149` and `:332-338`.
- `Store.messageExists` duplicates `message(_:) != nil`; the cheaper one is enough.
