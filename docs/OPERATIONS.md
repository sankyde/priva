# Running Priva's servers

What the operator does to keep Priva's two servers healthy: the Supabase project (directory, tokens, relay passes)
and the Cloudflare Worker (the rendezvous relay). Messages, media and calls never touch either; they go phone to
phone. Everything here uses `.env` and the scripts in `scripts/`; nothing needs the source to change.

## Backups

The free Supabase plan keeps **no backups**. The database holds Priva's signing keys and purchase-hash secret
(`priva.server_secrets`), and they exist nowhere else. If the database is lost:
- the keys go with it, and new ones are made on first use;
- every installed app refuses the new keys (it trusts only the keys it was built with);
- sign-ups and relay passes stop until everyone installs an app update.

```bash
scripts/backup_server.sh
```

This writes every `priva` table, as JSON, into an encrypted file in `~/Priva-server-backups/`, under a passphrase you
choose. Run it after setting up, then weekly, and daily once there are users. Keep a copy offline: a password manager
or a USB stick, never this repository. Supabase Pro adds daily backups of its own.

To restore, decrypt (the script prints the command), recreate the project with `scripts/setup_supabase.sh`, then
insert `server_secrets` and `app_config` first, before anything else runs: otherwise the functions make fresh keys.
In the JSON, binary columns (`server_secrets.value`) are hex with a `\x` prefix:
`decode(substr('<value>', 3), 'hex')`.

## Switching signing keys

The app and the relay trust a list of signing keys: the active one and a **standby**, kept offline. That lets the
server switch keys, one lost or leaked, without an app update.

**Once, before release:**

```bash
scripts/standby_keys.sh
```

It makes the standby registration and relay-pass keys exactly as the server makes its own. It encrypts their private
halves into `~/Priva-server-backups/` (keep a copy offline) and adds their ids to `.env` after the active ones. Then
`scripts/configure.sh`, build the app you submit, and `scripts/setup_cloudflare.sh`, so the relay accepts both.

**To switch** (a key leaked, or the database was lost without a backup):
1. Decrypt the standby file: `openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -in <file>`.
2. In the SQL editor, put the private halves in under their own names:
   `insert into priva.server_secrets (name, value) values ('blind_sk_v2', decode('<blind_sk_v2>', 'base64')), ('relay_sk_v2', decode('<relay_sk_v2>', 'base64'));`
3. Make them active: `insert into priva.app_config (key, value) values ('token_key_name', '"blind_sk_v2"'), ('pass_key_name', '"relay_sk_v2"') on conflict (key) do update set value = excluded.value;`
4. Redeploy the functions (`scripts/setup_supabase.sh`), so every instance picks the new keys up.
5. Make the next standby (`scripts/standby_keys.sh`) and ship it in the next app update.

A switched-to key that isn't in `server_secrets` is never made up on the spot: the functions fail ("key_missing")
instead of issuing tokens no app would trust. A leaked key keeps working for passes already issued until they
expire (at most 35 days); registration tokens signed with it stop at once, because only the active key verifies them.

## Capacity (free plans)

| What runs out first | Limit | About |
|---|---|---|
| Cloudflare Worker requests | 100,000 a day | 1,200 typical users. Workers Paid ($5 a month) gives 10 million a month. |
| Supabase database | 500 MB | Each username's post-quantum public keys take about 15 KB with indexes: 33,000 users. |
| Supabase egress | 5 GB a month | Directory lookups return a username's keys (about 10 KB). They're public and unthrottled, so heavy traffic, or someone abusing them, uses this up. Pro adds a spend cap. |
| Supabase function calls | 500,000 a month | A few per user a month. |

Details are in [FREE_TIER_CAPACITY.md](FREE_TIER_CAPACITY.md). Before launch, decide on Workers Paid and Supabase
Pro; Pro also brings the daily backups.

## Monitoring

Nothing in Priva reports to its operator: no analytics, no crash reporting. Watch the providers instead:
- **Supabase:** Organization › Usage, with email alerts at 80% of the database size and egress.
- **Cloudflare:** Workers & Pages › priva-rendezvous › Metrics (requests and errors), plus a notification for the
  daily request limit.
- **App Store Connect:** crash reports from people who share analytics with developers.
- `scripts/setup_supabase.sh --check` and `scripts/setup_cloudflare.sh --check`: both read-only, safe to run any time.

## When something is down

Tested by `OutageTests`:
- **Supabase down:** friends keep messaging and calling. New friends can't be found, and new accounts can't be made.
- **Relay down:** open connections keep working. New connections wait, and everything waiting arrives once the relay
  is back.

Nothing is lost either way: phones retry by themselves.

## Before release

1. Make the standby keys (above).
2. Run `scripts/backup_server.sh`.
3. Follow [LAUNCH_CHECKLIST.md](LAUNCH_CHECKLIST.md): clean the test data, register the review buddy, switch off
   development purchases, then run `scripts/launch_check.sh`.
