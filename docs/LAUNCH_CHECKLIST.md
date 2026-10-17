# Launch checklist

`scripts/launch_check.sh` checks everything here that can be checked automatically (it exits non-zero while a
blocker remains). The rest needs a person with the Apple Developer and Supabase accounts. Legal texts are drafts
written for this app's actual data flows: have them reviewed before launch.

## 1. Before submitting

| # | Task | How |
|---|---|---|
| 0 | **Configuration**: your team, servers and pinned keys live in `.env`, not in the source | `cp .env.example .env`, fill it in (the comments say where each value comes from), then `scripts/configure.sh` (app build settings), `scripts/setup_supabase.sh --check` and `scripts/setup_cloudflare.sh --check` (right accounts, everything deployed). |
| 1 | **Support email** (reports, Contact support, legal texts) | `PrivaSupportEmail: "support@yourdomain"` in `project.yml` → `xcodegen generate` → `LANG=en_US.UTF-8 pod install`. Use an address you read daily: reports must be handled within 24 h (docs/MODERATION.md). |
| 2 | **Privacy policy URL** (required by App Store Connect) | Publish `Priva/Resources/Legal/Privacy.md` (same text as in the app) on any public page, e.g. GitHub Pages, and enter the URL. Optionally publish `Terms.md` too. |
| 3 | **Relay (TURN)** so friends behind strict NATs (common on mobile carriers) can connect. Key created 2026-10-05; **moved behind the relay pass 2026-10-06 (audit SEC-05): redo the last three steps** | Cloudflare dashboard → Realtime → TURN → key (1,000 GB/month free). Put the key's ID and API token in `.env` (`CF_TURN_KEY_ID`, `CF_TURN_KEY_API_TOKEN`) and run `scripts/setup_cloudflare.sh`. Then `scripts/setup_supabase.sh` offers to delete the old open function (and run `npx supabase secrets unset CF_TURN_KEY_ID CF_TURN_KEY_API_TOKEN --project-ref $SUPABASE_PROJECT_REF`). `scripts/launch_check.sh` checks both. |
| 4 | **Clean the test data** (last cleaned 2026-10-05; testing since then adds rows again, so run it once more right before step 5) | Pre-launch every row is test data. In the SQL editor: `delete from priva.purchases where environment = 'Dev'; delete from priva.directory; delete from priva.redeemed_tokens; delete from priva.retired_commits;`, **before** step 5. |
| 5 | **Review buddy**: the reviewer has one iPhone and Priva has no server to talk to | On a Mac: `TEST_RUNNER_PRIVA_REVIEW_BUDDY=72 xcodebuild -workspace Priva.xcworkspace -scheme Priva -destination 'platform=iOS Simulator,name=iPhone Air' test -only-testing:PrivaTests/ReviewBuddy/testStayOnlineForAppReview`. The first run registers it and prints `REVIEW BUDDY online as @…`. Keep it running while the app is in review (re-run to extend; the account persists in that simulator). Check it with `TEST_RUNNER_PRIVA_BUDDY_NAME=<name> … -only-testing:PrivaTests/ReviewBuddy/testTheBuddyAnswers`. |
| 6 | **Switch off development purchases** | `PRIVA_ALLOW_DEV_PURCHASES=false` in `.env`, then `scripts/setup_supabase.sh` (or in the SQL editor: `update priva.app_config set value = 'false' where key = 'allow_dev_purchases';`) (after step 5, registering the buddy uses the development path). Real and Sandbox (App Review, TestFlight) purchases are verified with Apple's signature. This also stops development builds getting relay passes; the review buddy keeps the passes it already holds (35 days' worth). |
| 7 | **Two real iPhones** (TestFlight) | Face ID + Secure Enclave, iCloud Drive/Keychain backup and restore, purchase → username, calls on cellular (with and without the relay), camera, audio routes. Simulators can't exercise these. |
| 8 | **Release build** | `xcodebuild -workspace Priva.xcworkspace -scheme Priva -configuration Release -destination 'generic/platform=iOS' -derivedDataPath build/release CODE_SIGNING_ALLOWED=NO build`, then `scripts/launch_check.sh` (checks the binary has no debug hooks). |
| 9 | **Project pausing** | Free Supabase projects pause after about a week without database activity. Real use (username lookups, lease renewals) prevents it; before launch, run `scripts/keepalive.sh` once a day (cron/launchd/CI), or move to Pro (never paused). |
| 11 | **Region** | Connection signals go through the Cloudflare relay (served from the nearest Cloudflare city; a first message took ≈ 0.7 s from India), so the Supabase region (us-east-2, Ohio) only affects registration, username lookups and the monthly relay-pass fetch. Moving it is optional: create the project in the users' region, apply `supabase/migrations`, deploy the functions and update `PrivaConfig`. |
| 10 | **Wake-up notifications** (strongly recommended) | Without them, messages and calls only arrive while both people have Priva open. Design: docs/PUSH_DESIGN.md (needs an APNs key). If you launch without it, say so in the description. |

## 2. App Store Connect answers

**App Review notes** (paste and fill in):

> Priva is a peer-to-peer messenger: messages and calls go directly between two iPhones, end-to-end encrypted, and
> nothing is stored on a server. To try it with one device, add our test friend **@BUDDY_NAME** (Friends → + → type the
> username → Send request). It accepts within seconds, replies to messages, answers voice calls and joins groups you
> invite it to. Creating an account requires the in-app purchase check (Sandbox works) and Face ID. Users can block
> and report from a friend's profile, a friend request (⋯) or a group's member list; reports go to our support team
> and are handled within 24 hours.

**Age rating questionnaire:** answer yes to messaging/chat and user-to-user communication; say that users can block
and report, and that contact only happens after both sides accept a friend request (strangers can't message you).
No parental controls, no public content, no advertising. Expect 13+ or 16+ depending on the answers.

**App Privacy ("nutrition label")**: suggested answers, based on docs/PRODUCTION_AUDIT.md's data inventory:

| Data type | Collected? | Why |
|---|---|---|
| Identifiers → User ID | Yes · linked to the user · App Functionality · not tracking | The directory holds a commitment of the username and its public keys (that's the account). |
| Purchases → Purchase History | Yes · **not** linked · App Functionality | A keyed hash of the App Store transaction id limits usernames per purchase; unlinkable to the username by design (blind tokens). |
| Messages, photos, contacts, location, usage, diagnostics | **No** | Never leave the phone except end-to-end encrypted to friends. |
| Reports | Optional disclosure | Sent only when the user chooses to report, by email. |

No tracking; no third-party SDKs that collect data. (IP addresses are seen transiently by Supabase and Cloudflare as by
any network service; see the Privacy Policy.)

**Export compliance** (`ITSAppUsesNonExemptEncryption = true`): Priva implements its own end-to-end encryption with
standard algorithms (AES-GCM, X25519/ML-KEM, Ed25519/ML-DSA, HKDF, scrypt). That's classified as mass-market
encryption software (ECCN 5D992.c) under License Exception ENC §740.17(b)(1): answer App Store Connect's questions
accordingly and file the **annual self-classification report** with BIS by 1 February for the previous calendar year.
App Store Connect may also ask for a French encryption declaration to distribute in France: file it, or leave France
out of availability until you do. (Confirm with export counsel; this is guidance, not legal advice.)

**Pricing:** a paid app ($9.99–$19.99 tier). There are no in-app purchases or subscriptions.

## 3. After launch

- Watch Cloudflare → Workers & Pages → priva-rendezvous → Metrics (Worker and Durable Object requests a day) against
  docs/FREE_TIER_CAPACITY.md; move to Workers Paid ($5/month) before 80 %: the free plan stops at its daily limit.
  Supabase → Usage covers the directory and functions.
- Reports: handle within 24 h (docs/MODERATION.md).
- Each 1 February: BIS self-classification report.
- Leaked test accounts: `scripts/moderate.py remove <name>` removes any username.
