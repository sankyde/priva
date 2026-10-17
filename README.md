# Priva

A private messenger for iPhone. Messages, photos, files, voice and video calls, and groups go straight from one
iPhone to another, end-to-end encrypted. No server ever sees or stores what you send.

## How it works

- **Phone to phone.** Everything you send travels directly between iPhones (WebRTC). Nothing passes through a
  server or is kept on one.
- **Two small servers that know almost nothing.** One keeps the list of usernames, stored only in a scrambled
  form. The other helps two phones find each other and stores nothing. Neither can tell which purchase belongs to which
  username.
- **Strong locks.** Every chat is protected by two kinds of encryption, including post-quantum ones. Opening the app
  needs your password and Face ID.

The full design is in [docs/SYSTEM_DESIGN.md](docs/SYSTEM_DESIGN.md), and the security checks are in
[docs/SECURITY_VERIFICATION.md](docs/SECURITY_VERIFICATION.md) and [docs/audit/](docs/audit/).

## License

The source is here so anyone can read it and check how Priva protects them. It is **source available, not open
source**. Under the [PolyForm Strict License 1.0.0](LICENSE.md) you may read it and run it for noncommercial use,
but you may not change it, share it or build on it. Only the author publishes Priva on the App Store, and it runs
only on the author's servers.

## Build it

You need a Mac with Xcode 26.6 or later, plus XcodeGen and CocoaPods:

```bash
brew install xcodegen cocoapods
```

Then, from this folder:

```bash
cp .env.example .env      # fill it in; the comments say where each value comes from
scripts/configure.sh      # turns .env into the app's build settings
xcodegen generate         # makes the Xcode project and installs the pods
open Priva.xcworkspace
```

`.env` holds your settings and secrets. Git ignores it and the build settings made from it.

## Run the tests

```bash
xcodebuild -workspace Priva.xcworkspace -scheme Priva -destination 'platform=iOS Simulator,name=iPhone Air' test
```

The tests in `PrivaTests` run offline: encryption, backups, key files, restore and attack checks. They don't need
an account or any server.

## Report a security problem

See [SECURITY.md](SECURITY.md). Please don't open a public issue for it.
