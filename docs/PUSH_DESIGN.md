# Wake-up notifications (design, not built yet)

**The gap (launch blocker L2):** iOS suspends Priva shortly after it leaves the screen, which closes its rendezvous
socket. Messages and calls move only while *both* iPhones have Priva open (groups: while the host's is). A friend
whose Priva is closed never hears a call ring and only gets messages the next time both happen to be open.

Priva's rule, *no message content through the server*, rules out the usual fix (store-and-forward on a server).
What remains is a **content-free wake-up**: the server learns only "wake the device behind topic T now".

## Recommended design

1. **Registration.** Priva registers for remote notifications and gets an APNs device token. It creates a random
   32-byte *push secret per friend* and sends each friend theirs inside the encrypted channel (`Wire.profile`).
   It registers `SHA-256(secret) → APNs token` with a new `push` edge function (table `priva.push_topics`,
   rows expire after 30 days unless refreshed).
2. **Waking a friend.** When something is queued for a friend and they don't answer a connection attempt (no presence,
   `hello` timed out), the sender calls `push { secret }` (at most once per friend per 10 minutes; calls: immediately).
   The server looks up the token and sends:
   - messages: a plain alert, "New message" (`apns-push-type: alert`, no sender, no text). The user opens Priva, both
     are online, the queued message arrives in about a second;
   - calls: a VoIP push (`apns-push-type: voip`) → PushKit launches Priva in the background → it must report the call
     to CallKit immediately (iOS requirement) → the phone rings natively → Priva connects over WebRTC as today.
3. **Blocking / removing** a friend deletes their push secret (a `push-revoke` call), so a blocked person can't wake you.
4. **Rate limits** per topic in the table (token bucket) so a friend can't spam wake-ups.

What the server learns: that *some* friend of the device behind a topic wants to reach it, and when, not who, and
nothing about content. Apple learns that Priva sent a push to a device (it knows the device's Apple Account). Per-friend
topics keep the server from counting how many friends a device has only if tokens are also rotated; with a single
APNs token it can see how many topics map to one device (≈ number of friends). That trade-off is the same one every
push-based messenger makes, and it's much smaller than a mailbox holding ciphertext.

A Notification Service Extension can't fetch the message itself: it gets ~24 MB of memory and 30 seconds, not enough
for WebRTC + ML-KEM handshakes, and it would need the vault key while the phone is locked.

## What's needed before building it

- Apple Developer account: an APNs auth key (`.p8`), Key ID and Team ID → Supabase project secrets.
- Capabilities: Push Notifications (`aps-environment`), Background Modes → Voice over IP; CallKit integration in
  `CallCenter` (report incoming calls, answer/decline from the lock screen).
- The `push` edge function (APNs HTTP/2 with a JWT signed by the `.p8` key) and the `push_topics` migration.
- Free-tier cost: one edge-function invocation per wake-up (500,000 a month are free) and one small row per device
  per friend.

Rejected alternatives: background app refresh (runs rarely and unpredictably; both phones still need to be online at
the same moment) and a server mailbox of encrypted messages (breaks "nothing through Supabase").
