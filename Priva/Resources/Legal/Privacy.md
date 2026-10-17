# Privacy Policy

Priva is built so that we know as little as possible about you. This policy explains exactly what leaves your iPhone.

## What we never have

- Your messages, photos, videos, files, voice notes or calls. They go directly from your iPhone to your friends' iPhones, end-to-end encrypted.
- Your contacts, friends list, groups, display name, password, recovery phrase or Backup Key.
- Any link between your purchase and your username: usernames are registered with anonymous tokens that can't be traced back to a purchase.
- Analytics, advertising identifiers or tracking of any kind. Priva contains no third-party analytics or advertising code.

## What our server stores

Priva uses Supabase as a server. It stores only:

- **Purchases:** a keyed hash of the App Store transaction ID, the month it was checked and how many connection passes it received this month, so each purchase can register a limited number of usernames and use the relay a limited amount. No Apple ID, name or email.
- **Username directory:** a one-way commitment derived from your username (not the username itself) and your public keys, so friends can find you and verify your keys. The keys are removed when you delete your account.
- **Spent registration tokens:** hashes that stop a token being used twice.

Priva's connection relay (on Cloudflare) stores, for each inbox, one random public key that proves which iPhone may listen to it. The key is different for every inbox, so inboxes can't be linked to each other or to you.

## What passes through our server without being stored

- **Connection signals:** to start a direct connection, your iPhone and your friend's exchange a few small encrypted messages through Priva's relay. They are sealed so that only your friend can open them, and they are not stored.
- **Connection passes:** the relay only accepts iPhones that bought Priva. Your iPhone shows it an anonymous daily pass; passes are signed without the server seeing them, so a pass can't be traced back to your purchase or linked to your other passes.
- **Network information:** like any internet service, our server provider and the Cloudflare servers that help iPhones find a direct path see your IP address when your iPhone connects. Turn on Tor in Settings → Network to hide it.

## What your friends can see

- Direct connections mean a friend's iPhone can see your IP address. Tor mode or a relay you choose avoids this.
- A group's host iPhone relays and stores that group's messages and can read them.
- Your display name, profile updates, read receipts, typing and online status go only to friends, encrypted, and each can be turned off.

## Backups

Backups are encrypted on your iPhone with your Backup Key, your password and a secret kept in your iCloud Keychain. If you store them in iCloud Drive, Apple holds the encrypted file; neither Apple nor we can open it.

## Key files

If you save your recovery phrase or Backup Key as a file, it is encrypted on your iPhone with your password and your App Store purchase ID, and stored wherever you choose. Priva reads the purchase ID on your iPhone only to lock and unlock the file and never sends it anywhere for this.

## Reports

If you report someone, the report and anything you choose to include is sent by email to Priva's team, used only to review the report, and deleted when the review is finished.

## Deleting your data

Delete your account in Settings → Security & account: this removes your public keys from the directory (only the one-way commitment remains, so nobody can take over your username) and erases everything on this iPhone. Uninstalling Priva erases everything on the iPhone.

## Children

Priva is not directed at children under 13.

## Contact

Questions about privacy: {{SUPPORT_EMAIL}}.
