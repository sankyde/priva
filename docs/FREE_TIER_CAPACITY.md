# How many people the free plans can carry

Priva's servers do three small jobs. Messages, files, calls and group traffic never touch them; they flow over the
direct WebRTC connection.

- **Supabase:** the username directory (a few database calls per user per month) and the purchase → token →
  registration functions (once per username). It also hands out relay passes (one call a month per user).
- **Cloudflare relay** (`rendezvous/`, a Worker plus one Durable Object per topic): carries the small sealed signals
  two iPhones exchange to open a direct connection.

The relay's free-plan limits are the ones that matter.

## Short answer

| Question | Answer |
|---|---|
| How many **daily active users** does the free plan carry? | **≈ 650** typical users. Durable Object requests (100,000 a day) bind first. Heavy users (20 unlocks a day, 30 active friends): ≈ 120. |
| What binds next? | Worker requests (100,000 a day): ≈ 1,200 typical users. The `turn` function (500,000 invocations a month, only with a TURN relay configured): ≈ 3,000. Supabase database (500 MB): ≈ 55,000 registered usernames. |
| How many people can be **online at once**? | No plan cap. Each person holds 2 hibernating WebSockets, which cost nothing while idle. |
| What happens at the limit | The daily request allowance runs out: until 00:00 UTC the relay refuses new connections and signals, so friends can't open new connections (direct connections already open keep working). It is a hard stop, not a bill. |
| When to upgrade | At ≈ 400 daily users, or when Cloudflare → Workers & Pages → priva-rendezvous → Metrics shows 80 % of a day's requests. Workers Paid ($5 a month) includes 10 M Worker requests and 1 M Durable Object requests a month, then $0.30 and $0.15 per million. ≈ 10,000 daily users cost ≈ $16 a month (Supabase Realtime Pro: ≈ $200). |

## What the relay counts

| Action | Worker requests | Durable Object requests |
|---|---|---|
| Opening a socket (`/connect`) | 1 | 1 |
| One `/send` (up to 64 signals) | 1 | 1 per signal |
| A signal for someone who is offline | - | still 1 (the topic wakes up, finds nobody and drops it) |
| Heartbeat every 25 s (WebSocket protocol ping) | 0 | 0 (not billed) |
| An idle socket (hibernated) | 0 | 0, and no duration |

Durable Object duration (13,000 GB-s a day free) isn't a limit here: a topic is awake only for the milliseconds it
takes to hand a signal over (≈ 1 s per user per day).

## Model for a typical daily user

Assumptions, as before:

- 8 unlocks a day and 10 friends active in the last 30 days.
- 1.5 new connections per unlock; each connection is a three-trip handshake plus late candidates, so 4 signals.
- Now and then a wait for an offline friend.

| Per unlock | Worker | Durable Object |
|---|---|---|
| 2 sockets (inbox + friend requests) | 2 | 2 |
| Presence to 10 friends (one batched send) | 1 | 10 |
| 1.5 new connections × 4 signals (each its own send) | 6 | 6 |
| Waiting for offline friends (≈ 1.2 hellos) | 1.2 | 1.2 |
| **Per unlock** | **≈ 10** | **≈ 19** |
| **Per day (× 8)** | **≈ 82** | **≈ 154** |

That gives 100,000 / 154 ≈ **650 daily users** and 100,000 / 82 ≈ 1,200.

Paid plan for 10,000 daily users:

- Durable Object requests: 154 × 10,000 × 30 ≈ 46 M a month, so ≈ $7.
- Worker requests: ≈ 25 M a month, so ≈ $4.
- Plus the $5 minimum.

## What Priva does to stay inside the plan

- **Hibernation:** every topic is its own Durable Object and sleeps between signals. Sockets stay connected while it
  sleeps, so being online costs nothing.
- **Free heartbeats:** keep-alives are WebSocket protocol pings, which Cloudflare doesn't bill (an application "ping"
  message would count as 1/20 of a request).
- **Presence** goes only to friends active in the last 30 days (at most 60), batched 20 to a request, once per unlock
  and at most every 3 minutes on reconnects.
- **Retries** to an offline friend back off to 5 minutes; the friend's presence note brings them back sooner.
- **Three trips, not four:** candidates ride inside the offer and answer, signals are binary and padded in 2 KiB steps,
  and idle connections live 5 minutes.
- **Only buyers:** daily relay passes (at most 160 a month per purchase) and per-IP and per-pass rate limits keep
  strangers and scripts from spending the allowance.

## Other free-plan limits

- **Supabase project pausing:** free projects pause after about a week without database activity. Real use prevents
  it (lookups, lease renewals). Before launch, a daily request keeps it awake (LAUNCH_CHECKLIST step 9).
- **Supabase Realtime:** not used (switched off).
- **Edge functions:** 500,000 invocations a month.
  - `relay-pass`: ≈ 1 per user per month (35 days of passes per call).
  - `turn`: at most one per unlock, and only once a TURN key is configured (credentials cached for 3 hours).
- **Database:** each username's public keys are ≈ 8 KB, so ≈ 55,000 usernames fit in 500 MB.
- **TURN (Cloudflare):** 1,000 GB a month free. Only connections that can't go direct use it.

Sources: [Durable Objects pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/) ·
[Workers pricing and limits](https://developers.cloudflare.com/workers/platform/pricing/) ·
[Project pausing](https://supabase.com/docs/guides/platform/free-project-pausing) ·
[Cloudflare TURN pricing](https://developers.cloudflare.com/realtime/sfu/pricing)
