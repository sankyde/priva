# Priva: UI/UX and accessibility audit

Date: 2026-10-06 · Build: `build/audit-ui` (Debug, iOS 26.5 simulators) · Method: rendered screenshots (seeded demo
accounts, no network) + a line-by-line read of `Priva/Features/*`, `Priva/DesignSystem/*` and the user-visible strings in
`Priva/Core`. Every finding below was seen in a screenshot or read in the code; confidence is stated for each.

## Summary

| Severity | Count |
|---|---|
| High | 6 |
| Medium | 22 |
| Low | 17 |
| **Total** | **45** |

**Top 5**

1. **UX-01** The username QR code ("Friends can type this name or scan the code") doesn't work: nothing in Priva or iOS handles `priva://add/…`, and Find has no scanner.
2. **UX-02** Recovery-phrase / Backup Key words get cut off ("togeth…", "lem…") at larger text sizes. Someone could write down the wrong word and lose their account for good.
3. **UX-03** At accessibility text sizes the pinned buttons on every onboarding-style screen cover the content: the 24 words, the Confirm password field and the "account moved" warning.
4. **UX-05** "Erase after 10 tries" gives no countdown on the lock screen, and turning it on needs no confirmation. Wrong guesses wipe the phone without warning.
5. **UX-06** "Report" sends the report from the user's own mail account, which shows Priva their email address. The sheet says "Priva's team sees only what you write here."

What works well: one consistent visual language (aurora gradient, glass controls, tokenised colours), real empty
states, honest one-line warnings in most places, confirmations on almost every destructive action, and right-to-left
layout that mirrors correctly throughout (`shots/17e-rtl/`). In both light and dark mode, all body/secondary/tertiary
text tokens pass AA (see UX-07 for the colours that don't).

## Screenshots

All under `docs/audit/shots/`, downscaled to 900 px (`<screen>-light.png` / `-dark.png`):

| Folder | Device | Config |
|---|---|---|
| `17e-default/` | iPhone 17e | default text, light + dark, 65 screens |
| `air-default/` | iPhone Air | default text, light + dark |
| `17e-xxxl/` | iPhone 17e | largest non-accessibility size (xxxLarge), light |
| `air-ax3/` | iPhone Air | accessibility size AX3, dark |
| `17e-ax5/` | iPhone 17e | largest accessibility size AX5, light |
| `17e-rtl/` | iPhone 17e | right-to-left, light |
| `17e-contrast-bold/` | iPhone 17e | Increase Contrast + Bold Text, light + dark |

Notes: the `17e-default` set was rendered just before the main session's commit d5b756f, which only changed call-consent
logic (no views or strings), so it still applies; every other set used the rebuilt app. The `main` (whole tab bar)
shot was dropped because a group call left over from the previous shot covered it. The test now clears it, but I didn't
re-render it to save usage; `tabsempty` and `moved` show MainView instead. The lock screen shot is its Face ID stage
(the system prompt itself isn't captured). Reduce Transparency can't be forced from a test, so it wasn't rendered.

## Findings

### High

**UX-01 · High · stray/flow · Ready screen, Profile: `Features/Onboarding/OnboardingViews.swift:437, 447`; `App/AppModel.swift:184`; `Resources/Info.plist`**
- What's wrong: `UsernameCard` shows a QR code of `priva://add/<username>`, and the line under it says "Friends can type this name or scan the code." But:
  - Info.plist has no `CFBundleURLTypes`, so iOS Camera can't open the link.
  - `AppModel.received(_:)` ignores everything except backup files.
  - Find (`FindUserView`) has no "Scan" button.
  - The only in-app scanner (Security code) rejects this payload.

  Shots: `17e-default/ready-light.png`, `17e-default/profile-light.png`.
- Why it matters: this is the first thing a new user is told to do ("Share your username so friends can add you"). The main shortcut for adding a friend, which saves typing a 20-character random name, silently fails.
- Fix: register the `priva` scheme, and make `priva://add/<name>` open Find with the name filled in and searched. Add a "Scan code" button next to Find's search field (reuse `QRScannerView`). Until that ships, remove the QR code and change the line to "Friends add you by typing this name."
- Confidence: High (verified in the code and the built Info.plist).

**UX-02 · High · a11y · Recovery phrase (onboarding + Settings), Backup Key reveal: `DesignSystem/Components.swift:423-431` (`WordGrid`)**
- What's wrong: each word sits in a fixed `frame(height: 44)` cell, on one line, in two columns. At xxxLarge, word 5 shows as "togeth…" (`17e-xxxl/phrase-light.png`). At AX3 on the larger phone, half the words are cut: "lem…", "wed…", "sil…", "cru…" (`air-ax3/phrase-dark.png`).
- Why it matters: these 24 words are the only way back into the account or backups. A user with large text writes down a fragment, and the account is gone for good.
- Fix:
  - Never truncate a secret word: use `.frame(minHeight: 44)` with `.fixedSize(horizontal: false, vertical: true)`.
  - Switch to one column when `dynamicTypeSize >= .xxxLarge`.
  - If anything, scale the word down, never cut it: `.lineLimit(1).minimumScaleFactor(0.6)`.
- Confidence: High.

**UX-03 · High · a11y/visual · Every `OnboardingScaffold` screen: `DesignSystem/Components.swift:226`**
- What's wrong: the footer (primary + secondary button + caption) is pinned outside the `ScrollView`. At AX5 it covers most of the screen:
  - Recovery phrase: no words visible above "I've written it down" (`17e-ax5/phrase-light.png`).
  - Create/Change password: only the first field is visible; "Confirm" is hidden behind the button (`17e-ax5/password-light.png`, `changepw-light.png`).
  - "Your account moved": the security warning is hidden under "Erase Priva from this iPhone" (`17e-ax5/moved-light.png`).
  - Also affects backup setup and sign back in.
- Why it matters: on the most important screens, the content the user must read sits in a sliver above the buttons.
- Fix: when `dynamicTypeSize.isAccessibilitySize`, put the footer inside the `ScrollView` after the content (keep it pinned at normal sizes). Or wrap the two layouts in `ViewThatFits`.
- Confidence: High.

**UX-04 · High · a11y · Security code: `Features/Friends/FriendsViews.swift:403-406`**
- What's wrong: the 12 five-digit groups sit in a 4-column grid with no line limit. At AX5 every group breaks across lines ("48 69 75 91 / 65 77 88 98 / 0 0 7 1"), so you can't read groups or compare them (`17e-ax5/safety-light.png`).
- Why it matters: comparing this code in person is the anti-interception step. A misread code is worse than none.
- Fix: keep each group on one line (`.lineLimit(1).fixedSize()`), and drop to 2 columns (3 at AX sizes is too many) when `dynamicTypeSize.isAccessibilitySize`.
- Confidence: High.

**UX-05 · High · flow · Lock screen, Security & account, tour: `Features/Lock/LockView.swift:169`; `Features/Settings/SettingsViews.swift:239-240`; `Features/Onboarding/WelcomeTour.swift:140-141`**
- What's wrong:
  - With "Erase after 10 tries" on, the lock screen only says "Wrong password · N failed attempts". It never warns that an erase is coming.
  - The toggle turns on with no confirmation. Errors are swallowed (`try? Vault.setWipeAfterFailures`), so the UI can show "on" when it isn't.
  - Shot: `17e-default/security-light.png` (toggle).
- Why it matters: a user (or their child) can wipe every chat without being told it was about to happen.
- Fix:
  - From the 5th wrong try, show: "Wrong password. 4 tries left before Priva erases this iPhone."
  - On enable, confirm: "Erase after 10 wrong passwords?" with an "Erase on" button.
  - Reflect a failed save back into the toggle.
- Confidence: High.

**UX-06 · High · text/flow · Report sheet: `Features/Safety/SafetyViews.swift:101, 139-149`**
- What's wrong: "Send report" opens the user's own Mail (or a `mailto:` link), so the report comes from their personal email address. The footer, though, says "Priva's team sees only what you write here." Shot: `17e-default/report-light.png`.
- Why it matters: Priva sells itself as anonymous ("No phone number, no email"). Reporting abuse quietly links the user's email to an incident, and the copy promises the opposite.
- Fix: say it before sending. Footer: "Sent from your email app, so Priva sees your email address." Better, post the report to a server endpoint with no identity.
- Confidence: High.

### Medium

**UX-07 · Medium · a11y (contrast) · several: `DesignSystem/Theme.swift:8`; `Features/Chat/ChatView.swift:304`; `Features/Chats/MainView.swift:69`; `Features/Backup/BackupViews.swift:556, 631, 634`; `Components.swift:80, 129-142`**

I calculated WCAG ratios from the tokens (alpha blended onto the surface):

| Where | Pair | Ratio | Needs |
|---|---|---|---|
| Restore "Too many tries", "A newer backup exists", "N days old"; moved-account banner | system `.orange` on light bg / white | **2.0–2.2:1** | 4.5 |
| Group sender name above bubbles (light) | `violetLight` 8B7BFF on F4F5FA | **3.03:1** | 4.5 |
| Tint-coloured caption buttons in dark mode ("Verify security code", "Members & rules") | violet 6C5CFF on 15171F / 0A0B10 | **3.9 / 4.3:1** | 4.5 |
| Accept-call glyph, dark mode | white on mint 3DDC97 | **1.77:1** | 3 (non-text) |
| Decline / End glyph, dark mode | white on rose FF5C7A | **2.97:1** | 3 |
| Avatar initials on yellow/mint/teal gradients | white on FFC857 / 3DDC97 / 2BD4C4 | **1.5–1.9:1** | 3 (large text) |
| Mint "online"/chip text on mint 12% over light bg | 0B7A4E | 4.19:1 | 4.5 |

Shots: `17e-default/group-light.png` (sender names), `17e-default/incoming-dark.png` (Accept), `17e-default/chats-light.png` (avatars).

- Fix:
  - Replace `.orange` with `Theme.amber` (5.3:1).
  - Use `Theme.violet` for sender names in light mode (5.9:1).
  - Give tint text a lighter dark-mode value (e.g. `#8B7BFF` → 5.97:1).
  - Use the light-mode (darker) mint and rose as call-button fills in both modes, or a dark glyph on the bright fill.
  - Drop the bright yellow/mint/teal avatar pairs, or darken their first stop.
- Confidence: High (calculated). The Theme comment "meet WCAG AA … on every surface" holds for the text tokens, not for these pairs.

**UX-08 · Medium · a11y/visual · Fixed layouts that break at large text: many**

At AX5 (`17e-ax5/`) / xxxLarge (`17e-xxxl/`):
- Contact Message/Voice/Video tiles are fixed at 84×64 and read "M…", "Vo…", "Vi…" (`FriendsViews.swift:381`; `contact-light.png`). Group info Voice/Video are clipped ("Voi", "Vid") (`groupinfo-light.png`).
- Chats list: the time stays beside the name, so names shrink to "Sar…" / "Ma…" (`MainView.swift:322-331`; `chatsstates-light.png`). The same happens in the Calls list (`CallViews.swift:309-323`).
- `EmptyStateView` doesn't scroll, so "No convers…" and its message are truncated (`Components.swift:169-190`; `chatsempty-light.png`).
- Incoming call: the fixed `HStack(spacing: 70)` pushes "Decline"/"Accept" off the screen edges (`CallViews.swift:211`, `GroupCallView.swift:49`; `incoming-light.png`). The group invite line is cut to "Maya Chen wants to s…".
- `SecureChip` is `lineLimit(1)`: "End-to-end enc…", "Camera and…" (`Components.swift:99`). The emoji security-code chip covers the avatar on the call screen (`callcode-light.png`).
- Mid-word breaks: "Ligh t", "Dar k" (Appearance), "Un blo ck" (Blocked), "Backu p Key" (Backup on).
- Truncated: the tour card text, the "Priva is locked" title, "Imm…iately" (Auto-lock).

Fix:
- Use `ViewThatFits` or `AnyLayout(HStack/VStack)` keyed on `dynamicTypeSize.isAccessibilitySize` for action tiles, list rows (time under the name) and call buttons.
- Wrap `EmptyStateView` and the tour cards in a `ScrollView`.
- Let chips wrap (`lineLimit(2)`).
- Give glass buttons `minWidth` instead of fixed frames.

Confidence: High.

**UX-09 · Medium · a11y · Reduce Motion is never honoured: `DesignSystem/Theme.swift:31` (comment claims it is)**
- What's wrong: nothing reads `accessibilityReduceMotion` (grep finds no use). Endless animations run regardless:
  - typing dots (`ChatView.swift:499`)
  - breathing logo (`OnboardingViews.swift:65`)
  - Face ID scan line (`OnboardingViews.swift:242`)
  - pulsing Accept/Join (`CallViews.swift:218`, `GroupCallView.swift:34`)
  - pulsing empty-state icon (`Components.swift:181`)
  - move-in bubble transitions (`ChatView.swift:69`)
- Fix: `@Environment(\.accessibilityReduceMotion)`. When on, use static symbols, `.opacity` transitions and no `repeatForever` or `phaseAnimator`.
- Confidence: High.

**UX-10 · Medium · a11y · VoiceOver reads raw usernames instead of names**
- What's wrong:
  - Incoming 1:1 bubbles are labelled `senderName ?? message.contact`, so VoiceOver reads "maya_chen_4821: Hey!" (`ChatView.swift:351`).
  - `Avatar` labels itself with whatever it's given, usually the username (`MainView.swift:320`, `CallViews.swift:310`, `FriendsViews.swift:60`). Inside combined rows that means the username is read before the name.
  - The member menu is "Actions for maya_chen_4821" (`GroupViews.swift:629`).
- Fix: pass `displayName` to the bubble label and `Avatar`. In combined rows, mark the avatar `accessibilityHidden(true)` and read the name once.
- Confidence: High (code).

**UX-11 · Medium · a11y · On/off state not exposed to VoiceOver**
- What's wrong:
  - The Speaker button's label is always "Speaker", with no `.isSelected` trait or value (`CallViews.swift:148`, `GroupCallView.swift:151`); only the glass tint changes.
  - Add-members rows have no `.isSelected` trait (`GroupViews.swift:646-656`). New group has one (line 176).
  - Group call tiles override their label with just the name, so "muted" and "host" are lost (`GroupCallView.swift:138-139`).
- Fix: add `.accessibilityAddTraits(active ? .isSelected : [])` in `GlassIconButton` (`Components.swift:85`), add the trait to AddMembers rows, and label tiles "Maya Chen, muted, host".
- Confidence: High.

**UX-12 · Medium · a11y · Toasts aren't announced: `Features/Chats/MainView.swift:47-49, 83-91`**
- What's wrong: toasts appear for 3.2 s with no `AccessibilityNotification.Announcement`. VoiceOver users miss "Password changed", "Couldn't send", "Security warning".
- Fix: post an announcement when `engine.toast` changes, and keep the toast on screen longer while VoiceOver is running.
- Confidence: High.

**UX-13 · Medium · flow · Nickname is lost unless Return is pressed: `Features/Friends/FriendsViews.swift:350-351`**
- What's wrong: `TextField("Only visible to you").onSubmit { setNickname }`. Typing a nickname and going Back drops it. Shot: `17e-default/contact-light.png`.
- Fix: save in `.onDisappear` and on a debounced `onChange`.
- Confidence: High.

**UX-14 · Medium · flow · Calling from a contact opened as a sheet: `FriendsViews.swift:313-314` vs `GroupViews.swift:480-481`**
- What's wrong: from a chat, tapping the title opens `ContactView` in a sheet. Its Voice/Video buttons start the call without dismissing, but the call screen is a `fullScreenCover` on `MainView`, which can't present while that sheet is up. Group info deliberately calls `dismiss()` first; ContactView doesn't.
- Fix: dismiss the sheet before `calls.start` (as GroupInfoView does), or present the call screen from a separate window.
- Confidence: Medium (code reading; not reproduced live).

**UX-15 · Medium · flow · Silent failures**
- What's wrong:
  - `IncomingRequestRow` sets `busy = true; try? engine.accept(request)`. If accept throws, the Accept button stays disabled forever with no message (`FriendsViews.swift:142-143, 150`).
  - Sending a file that can't be prepared (e.g. too big) does nothing (`ChatView.swift:183`, `GroupViews.swift:396`).
  - Creating a group fails silently (`GroupViews.swift:187`).
  - A failed friend request shows "Couldn't search / Check your connection" (`FriendsViews.swift:278`).
- Fix: reset `busy` and toast "Couldn't accept. Try again."; toast "Couldn't send <name>: too large" (or the real reason); show inline errors on group create and send request.
- Confidence: High.

**UX-16 · Medium · flow · "New chat" opens the chat inside the sheet: `Features/Chats/MainView.swift:375`**
- What's wrong: `ComposeSheet` pushes `ChatView` inside the modal. The conversation lives in a sheet, and swiping down closes it instead of going back to Chats.
- Fix: dismiss the sheet and call `openThread(username)`, as the new-group flow does.
- Confidence: High.

**UX-17 · Medium · visual · Call controls nearly invisible in light mode: `DesignSystem/Components.swift:76-87`**
- What's wrong: the call screens are always dark, but the glass follows the system style. In light mode the mute and speaker buttons are pale grey glass with white glyphs (`17e-default/call-light.png`, `groupcall-light.png`).
- Fix: force `.environment(\.colorScheme, .dark)` on `CallView` and `GroupCallView` (their backgrounds are fixed dark).
- Confidence: High.

**UX-18 · Medium · text · Inconsistent names for the same secrets**
- What's wrong:
  - The 24 words are the "recovery phrase" in onboarding and Settings, but their file is the "Recovery Key file" (`KeyFileViews.swift:55-56, 210`).
  - The tour says "safety codes" (`WelcomeTour.swift:63`); everywhere else says "Security code".
  - The call's four emoji are also called "Security code" (`CallViews.swift:127`), though they're a different code from the contact's 60 digits.
  - All this on top of a second 24-word secret (Backup Key), a purchase ID and iCloud Keychain.
- Fix: one term per thing:
  - "Recovery phrase" and "Recovery phrase file"
  - "Backup Key" and "Backup Key file"
  - "Security code" (60 digits)
  - "Call code" (emoji): "Call code, matches your friend's screen"
- Confidence: High.

**UX-19 · Medium · text · "Verified keys" on a stranger: `Features/Friends/FriendsViews.swift:263`**
- What's wrong: Find's result card shows a green "Verified keys" chip for someone never met. Everywhere else, the green shield/"verified" means "compared in person". Shot: n/a (needs a network lookup); verified in code.
- Fix: "Keys signed by @name". Better, drop the chip and keep only the fingerprint.
- Confidence: High.

**UX-20 · Medium · text · "Download" means "save an encrypted file": `KeyFileViews.swift:194, 261`; `OnboardingViews.swift:282`; `BackupViews.swift:294`**
- What's wrong: nothing is downloaded, and users expect "Download" to fetch from the internet. Shot: `17e-default/phrase-light.png`.
- Fix: button "Save as file". Subtitles "Write these 24 words down, or save them as a file." and "Shown only once. Write it down or save it as a file."
- Confidence: High.

**UX-21 · Medium · flow · Forgot password offers a file that needs the forgotten password: `Features/Lock/LockView.swift:210`**
- What's wrong: the "Open my Recovery Key file" button in Reset password asks for the password the file was saved with, which is exactly what the user forgot (the code comment admits this). Shot: `17e-default/forgot-light.png`.
- Fix: hide it here, or caption it "Needs the password you had when you saved it."
- Confidence: High.

**UX-22 · Medium · flow · Restore dead end on the iCloud Keychain factor: `Features/Backup/BackupViews.swift:598`**
- What's wrong: "This backup also needs iCloud Keychain from the Apple Account that made it." gives no next step.
- Fix: "Sign in with the Apple Account that made this backup and turn on iCloud Keychain, then try again."
- Confidence: High.

**UX-23 · Medium · flow/text · "Leave Priva" vs "Delete account": `Features/Settings/SettingsViews.swift:252-256, 269, 272`**
- What's wrong: two red buttons, with one footer saying "Both erase everything on this iPhone, including your backups." The user can't tell when to pick which. Shot: `17e-default/security-light.png`.
- Fix: one line under each. Leave: "Erase Priva here. Your username is retired; friends see you left." Delete: "Erase your account and all backups for good."
- Confidence: Medium (difference inferred from `retire` vs `revoke`).

**UX-24 · Medium · flow · Destructive action styled as the main action: `Features/Chats/MainView.swift:405`**
- What's wrong: "Your account moved" makes "Erase Priva from this iPhone" the violet primary button, and the safe choice is a small link (`17e-default/moved-light.png`).
- Fix: make the destructive button red (`.tint(Theme.rose)`, role destructive), or make "Keep the read-only copy" the primary.
- Confidence: High.

**UX-25 · Medium · flow · "Delete group" (ended group) deletes immediately: `Features/Groups/GroupViews.swift:528-531`**
- What's wrong: no confirmation, though it deletes the group's whole history from this iPhone.
- Fix: `confirmationDialog("Delete \(name)?", message: "Its messages are removed from this iPhone.")`.
- Confidence: High.

**UX-26 · Medium · flow · The host's hang-up ends everyone's call with no visible cue: `Features/Groups/GroupCallView.swift:152`**
- What's wrong: only VoiceOver hears "End call for everyone"; sighted hosts see the same red button as members.
- Fix: a caption under the host's button ("End for all"), or a confirmation when others are still in the call.
- Confidence: High.

**UX-27 · Medium · a11y · Touch targets under 44 pt**
- What's wrong:
  - Backup-nudge dismiss ✕ is a footnote-size glyph (`MainView.swift:196`).
  - The status-glyph "Info" button is about 12 pt (`ChatView.swift:359`).
  - The member ⋯ menu is 36×36 (`GroupViews.swift:627`).
  - The password show/hide eye has no frame (`Components.swift:268-271`).
- Fix: `.frame(minWidth: 44, minHeight: 44).contentShape(.rect)`.
- Confidence: High (code; visible in `17e-default/chats-light.png`).

**UX-28 · Medium · stray · Developer row in Release: "Pair key ratchet · epoch 0", `Features/Friends/FriendsViews.swift:345-347`**
- What's wrong: shown on every contact, outside `#if DEBUG` (`17e-default/contact-light.png`). It means nothing to users.
- Fix: move it under `#if DEBUG`, or into Diagnostics.
- Confidence: High.

### Low

**UX-29 · Low · visual · Group header chip truncates the host: `Features/Groups/GroupViews.swift:435` + `Components.swift:99`**
- What's wrong: "End-to-end encrypted · hosted by @leo_okafor_2…", even at default size on the 17e (`17e-contrast-bold/groupmember-light.png`). Group info also says "Hosted on @leo_okafor_2290's iPhone" rather than the name (`GroupViews.swift:477`).
- Fix: use `engine.name(of:)` and split into two chips ("End-to-end encrypted", "Hosted by Leo").

**UX-30 · Low · text · Weak loss warning for "This iPhone only" backups: `BackupViews.swift:226`**
- What's wrong: it says "Stays on this device. Export it yourself if you like."
- Fix: "Lost if this iPhone is lost or erased."

**UX-31 · Low · text · "How Priva protects you" jargon and one inaccurate claim: `SettingsViews.swift:758-759, 764`**
- What's wrong: "X-Wing and ML-KEM-1024 keys, AES-256 inside ChaCha20" and "Session keys ratchet" are jargon. "Nothing is stored on a server" doesn't fit friend requests ("Delivered when they next open Priva") or the relay.
- Fix: see Text rewrites.

**UX-32 · Low · text · Lockout shown in raw seconds ("Try again in 843s"): `LockView.swift:74`**
- Fix: format as minutes ("Try again in 15 min"), as Restore already does (`BackupViews.swift:578`).

**UX-33 · Low · text · Hard-coded "Face ID & Passcode": `OnboardingViews.swift:264`**
- What's wrong: wrong on Touch ID devices.
- Fix: build the path from `BiometricGate.kind`.

**UX-34 · Low · text · Confusing key-file alert: `SettingsViews.swift:424`**
- What's wrong: "Change it later? Save a new file." reads as a question to the user.
- Fix: see Text rewrites.

**UX-35 · Low · flow · Calls tab can't start a call: `CallViews.swift:303-324, 347`**
- What's wrong: the empty state has no action, rows do nothing when tapped (only the small icon calls), and the list says "Missed voice"/"Missed video".
- Fix: add "Call a friend" (opens the friends picker), make the row tap call or open the chat, and use "Missed voice call".

**UX-36 · Low · text · Toasts/system messages with raw usernames or more than 2 lines**
- What's wrong:
  - Raw usernames: "@peer invited you to …" (`GroupHub.swift:751`), "maya_chen_4821 declined your request." (`PrivaEngine.swift:1081`).
  - Three-line security notes: `FriendsViews.swift:118`, `PrivaEngine.swift:945`, `MainView.swift:396-398`.
- Fix: see Text rewrites.

**UX-37 · Low · visual · Host badge uses a server-rack glyph: `GroupViews.swift:35, 68`; `GroupCallView.swift:129`**
- What's wrong: at small size it reads as a "list/drawer" icon next to group names and "You" (`17e-default/chats-light.png`, `groupcall-light.png`).
- Fix: use `house.fill` or `crown.fill` with the "Host" text.

**UX-38 · Low · a11y · Small VoiceOver gaps**
- What's wrong:
  - The verified shield in Friends has no label (`FriendsViews.swift:64`); ChatRow labels it "Verified".
  - Unread badges read just "1" (`MainView.swift:341`, `GroupViews.swift:79`).
  - Previews read "camera Photo" because of the emoji (`MainView.swift:356-358`).
  - The media viewer image has no label (`ChatView.swift:621`).
- Fix: `.accessibilityLabel("Verified")`, "1 unread", plain-text previews for VoiceOver, and a "Photo from Maya" label.

**UX-39 · Low · a11y/text · Call quality shown by colour only, plus jargon: `CallViews.swift:254-258`**
- What's wrong: only the dot's colour (mint/amber) shows quality, and "Relayed/Direct" is jargon (`17e-default/call-light.png`).
- Fix: drop the dot and show "Weak connection" text only when it's bad.

**UX-40 · Low · visual · Restore key step has two leading buttons (✕ and ‹): `BackupViews.swift:405-416`**
- Fix: keep the back chevron on the left and move Cancel into the toolbar's trailing spot (or drop it on this step).
- Confidence: Medium (code only).

**UX-41 · Low · a11y · Theme ignores Increase Contrast: `DesignSystem/Theme.swift:55-61`**
- What's wrong: `adaptiveColor` only checks `userInterfaceStyle`. With Increase Contrast on, only system parts change (`17e-contrast-bold/*`).
- Fix: also branch on `traits.accessibilityContrast == .high` for `textSecondary`, `textTertiary`, `hairline` and the tints.

**UX-42 · Low · visual · Tour shows its page twice ("1 of 6" plus dots): `WelcomeTour.swift:45, 74-78`**
- Fix: keep the dots, and expose "Page 1 of 6" to VoiceOver only.

**UX-43 · Low · stray/flow · Leftover no-op view and a dead end**
- What's wrong: `EmptyView().font(...)` is left over (`FriendsViews.swift:280-281`). "Add friends first." in New group has no action (`GroupViews.swift:156`).
- Fix: delete the no-op; make the line a "Find a friend" button.

**UX-44 · Low · visual · "Connecting…" banner overlaps the toolbar at large text: `MainView.swift:36, 74-81`**
- What's wrong: at AX5 it covers the compose button (`17e-ax5/tabsempty-light.png`).
- Fix: put the banner under the navigation bar (`.safeAreaInset(edge: .top)`), or use the toolbar's subtitle.

**UX-45 · Low · text · Small wording issues**
- What's wrong:
  - "your face" for Face ID (`BackupViews.swift:87`).
  - "Original quality" (`ChatView.swift:520`).
  - "Export decrypted copy…" (`ChatView.swift:635`).
  - "Fallback" relay value (`SettingsViews.swift:564`).
  - "Key fingerprint …" / "Public key fingerprint" shown to regular users (`FriendsViews.swift:126, 260`).
- Fix: see the table below.

## Text rewrites

| file:line | Current | Proposed (≤ 2 lines) |
|---|---|---|
| Onboarding/OnboardingViews.swift:447 | Friends can type this name or scan the code. | Friends add you by typing this name. *(until UX-01 ships)* |
| Onboarding/OnboardingViews.swift:282 | Write these 24 words down, or download them. | Write these 24 words down, or save them as a file. |
| Backup/BackupViews.swift:294 | Shown only once. Write it down or download it. | Shown only once. Write it down or save it as a file. |
| Backup/KeyFileViews.swift:194, 261 | Download | Save as file |
| Backup/KeyFileViews.swift:55 | That's your Backup Key file. Choose your Recovery Key file. | That's your Backup Key file. Choose your recovery phrase file. |
| Backup/KeyFileViews.swift:56 | That's your Recovery Key file. Choose your Backup Key file. | That's your recovery phrase file. Choose your Backup Key file. |
| Backup/KeyFileViews.swift:210 | Open my Recovery Key file | Open my recovery phrase file |
| Lock/LockView.swift:169 | Wrong password · N failed attempts | Wrong password. N tries left before Priva erases this iPhone. *(when erase is on)* |
| Lock/LockView.swift:74 | Too many attempts. Try again in 843s | Too many attempts. Try again in 15 min. |
| Safety/SafetyViews.swift:101 | Priva's team sees only what you write here. | Sent from your email app, so Priva sees your email address. |
| Settings/SettingsViews.swift:255 | Both erase everything on this iPhone, including your backups. | Leave: erase Priva here; friends see you left. Delete: also erase your backups for good. |
| Settings/SettingsViews.swift:242 | With erase on, 10 wrong passwords in a row wipe Priva on this iPhone. | 10 wrong passwords in a row erase Priva on this iPhone. |
| Settings/SettingsViews.swift:424 | The file opens only with this password. Change it later? Save a new file. | The file opens only with this password. If you change it, save a new file. |
| Settings/SettingsViews.swift:758 | X-Wing and ML-KEM-1024 keys, AES-256 inside ChaCha20. | Two layers of quantum-safe encryption. |
| Settings/SettingsViews.swift:759 | Messages, files and calls go phone to phone. Nothing is stored on a server. | Messages, files and calls go phone to phone. Servers never see their content. |
| Settings/SettingsViews.swift:764 | Session keys ratchet after every conversation. | Keys change after every conversation. |
| Settings/SettingsViews.swift:564 | Fallback | If needed |
| Backup/BackupViews.swift:226 | Stays on this device. Export it yourself if you like. | Lost if this iPhone is lost or erased. |
| Backup/BackupViews.swift:87 | Restoring needs your Backup Key, your password and your face. | Restoring needs your Backup Key, your password and Face ID. |
| Backup/BackupViews.swift:598 | This backup also needs iCloud Keychain from the Apple Account that made it. | Turn on iCloud Keychain with the Apple Account that made this backup, then try again. |
| Backup/BackupViews.swift:556, 631, 634 | (orange text) | Same text, `Theme.amber` (contrast) |
| Friends/FriendsViews.swift:263 | Verified keys | Keys signed by @name |
| Friends/FriendsViews.swift:358 | Both delete the chat from this iPhone. Blocking also stops their messages, calls and invites. | Removing or blocking deletes this chat. Blocking also stops their calls and invites. |
| Friends/FriendsViews.swift:118 | Claims to be @old, but that account already moved to @new. Decline unless @new confirms in person. | Says it's @old, who already moved to @new. Decline unless they confirm in person. |
| Friends/FriendsViews.swift:126, 260 | Key fingerprint XXXX … / Public key fingerprint | *(hide; show only in Security code)* |
| Friends/FriendsViews.swift:278 → Find error state | Couldn't search · Check your connection and try again. *(after a failed request)* | Couldn't send the request. Try again. |
| Chat/ChatView.swift:520 | Original quality | Photos at full quality |
| Chat/ChatView.swift:635–636 | Export decrypted copy… / Exports an unencrypted copy. | Share a copy… / The copy isn't encrypted. |
| Calls/CallViews.swift:127 | Security code | Call code |
| Calls/CallViews.swift:347 | Missed voice / Missed video | Missed voice call / Missed video call |
| Calls/CallViews.swift:305 | Your call history appears here. | Call a friend from their chat. *(+ "Call a friend" button)* |
| Onboarding/WelcomeTour.swift:63 | Compare safety codes in person to be sure. | Compare security codes in person to be sure. |
| Onboarding/OnboardingViews.swift:264 | Turn it on in Settings › Face ID & Passcode. | Turn it on in Settings › \(kind) & Passcode. |
| Chats/MainView.swift:396 | It's now @new, and your friends moved with it. This iPhone keeps a read-only copy, offline. | It's now @new on the other iPhone. This one keeps a read-only copy. |
| Chats/MainView.swift:398 | Not you? Someone has your Backup Key and password. Start a new account and tell friends in person. | Not you? Someone has your Backup Key and password. Tell friends in person. |
| Core/Engine/PrivaEngine.swift:945 | @x claims to be @y, but who already restored it. Someone else has that backup: don't accept. | @x says it's @y, but @y already moved. Don't accept. |
| Core/Engine/PrivaEngine.swift:1081 | maya_chen_4821 declined your request. | Maya Chen declined your request. *(display name)* |
| Core/Groups/GroupHub.swift:751 | @peer invited you to Group | Maya Chen invited you to Group *(display name)* |
| Groups/GroupViews.swift:156 | Add friends first. | *(button)* Find a friend |
| Groups/GroupViews.swift:522 | On · blocks / On · masks | On · blocks messages / On · hides words |

## ScreenshotTour.swift changes (test code only)

`PrivaTests/ScreenshotTour.swift` gained opt-in options. With none set, the run is unchanged: the same 15 screens, light and
dark, no trait overrides.

- `TEST_RUNNER_PRIVA_SHOTS_EXTRA=1`: 50 more screens. They use the main demo account, a second "states" account (friend requests incl. a key-change warning, a former friend, a pending rename, an uninstalled friend, queued/failed/file/expired messages, call history, a group hosted by a friend with admins-only posting, a blocked user, a moved account, backups on) and an empty account. Naming screens in `SHOTS_ONLY` also enables them.
- `TEST_RUNNER_PRIVA_SHOTS_TEXT=xs…xxxl|ax1…ax5`: Dynamic Type (window trait + `.dynamicTypeSize`).
- `TEST_RUNNER_PRIVA_SHOTS_RTL=1`, `…_CONTRAST=1`, `…_BOLD=1`: right-to-left, Increase Contrast, Bold Text.
- `TEST_RUNNER_PRIVA_SHOTS_STYLES=light|dark`: only one appearance.

Example (small phone, AX5, light):

```
TEST_RUNNER_PRIVA_SHOTS=1 TEST_RUNNER_PRIVA_SHOTS_EXTRA=1 TEST_RUNNER_PRIVA_SHOTS_TEXT=ax5 TEST_RUNNER_PRIVA_SHOTS_STYLES=light \
  xcodebuild test-without-building -xctestrun "$(ls build/audit-ui/Build/Products/*.xctestrun | head -1)" \
  -destination "platform=iOS Simulator,name=iPhone 17e" -resultBundlePath build/audit-ui-results/run.xcresult \
  -only-testing:PrivaTests/ScreenshotTour
```

None of the extra screens touch the network. Purchase is pre-set to "verified", so no App Store or server call is made.
I also tried an in-process VoiceOver tree dump, but it came out empty and I removed it. VoiceOver findings come from
reading the code.
