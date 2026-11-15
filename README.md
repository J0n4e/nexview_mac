# Nexview for Mac

A native macOS app for [Nexview](https://github.com/DerKezorm/nexview), the self-hosted media
discovery dashboard by DerKezorm. It connects to your own Nexview server and shows it in a proper
Mac window, with native notifications, a menu bar icon and automatic updates.

Apple Silicon only, macOS 14 Sonoma or newer.

> **Community app:** this is not an official Nexview project. Please report problems with the
> Mac app [here](https://github.com/J0n4e/nexview_mac/issues), not in the Nexview repository.

## How it works

Every Nexview screen and feature comes live from your server, so the app always matches the
version your server runs. Update your Nexview server and the app has the new features straight
away; there is nothing to rebuild.

Around it, the app adds:

- **Settings and About** in Nexview's look, with a tab bar along the top.
- **Several servers**: add, edit, switch and remove them in Settings → Servers.
- **Notifications**: the app checks every saved server once a minute with its own read-only
  access key, so notifications arrive even with the window closed. Clearing a notification in
  macOS marks it read in Nexview, and reading it in Nexview removes it from Notification Center.
- **Dock and menu bar badge**: unread notifications plus requests waiting for your approval.
- **Run in background**: closing the window leaves only the menu bar icon; click it to bring
  Nexview back. ⌘Q quits completely.
- **Open at login**.
- **Automatic updates** (see below).

## Install

1. Download the latest `Nexview-<version>.zip` from
   [Releases](https://github.com/J0n4e/nexview_mac/releases).
2. Unzip it and move **Nexview** to Applications.
3. The app is signed with its own certificate, not an Apple Developer ID, so the first time you open it,
   right-click it in Finder, choose **Open** and confirm. After that it opens normally.
4. Enter the address of your Nexview server and sign in with your Nexview account.

## Updates

Nexview for Mac looks for a new version 10 seconds after launch and then every 6 hours. You can
also check yourself with **Nexview → Check for Updates…**. When a new version is out, you see
what changed and can install it, skip that version or be reminded later. If the window is
closed, you get a notification instead.

Every release is signed with an Ed25519 key. The app only downloads updates from this
repository's [Releases](https://github.com/J0n4e/nexview_mac/releases) and checks the signature
before installing anything. It also checks that the download really is a newer Nexview for Mac
with an intact code signature.

If any of these checks fails, nothing is installed: you see a message saying why and keep your
current version. You can always install a release by hand as described under *Install*.

## Signing in

You sign in through Nexview's own sign-in page, just like in a browser. The session keeps you
signed in, so you don't have to sign in every time you open the app. Nexview for Mac doesn't
store your password.

Your servers and the read-only notification keys are stored in a file only your macOS user can
read (`~/Library/Application Support/Nexview for Mac/store.json`). No passwords are stored. Keep
FileVault on, and encrypt Time Machine backups.

## Security notes

- Use an `https://` address for your server whenever you can.
- If you enter a plain `http://` address for a server that is not on this Mac or your local
  network, the app warns you: your password and session would travel unencrypted.
- The notification keys are read-only: they can read your notifications but not change anything
  on your server.

## Building from source

Requirements: an Apple Silicon Mac with macOS 14 or newer and the Xcode command line tools
(`xcode-select --install`).

```sh
zsh macos/build.sh
```

This fetches Nexview's code into `src/` (only its icon and version are used) and builds
`build/Nexview.app`. Local builds are signed ad hoc. To sign with a certificate from your
keychain instead, set `CODESIGN_IDENTITY` to its SHA-1 (and optionally `CODESIGN_KEYCHAIN`). Copy it to `/Applications` to install it. The first time you open it,
right-click it and choose **Open**, as above.

The upstream Nexview code is pinned to the commit in `macos/UPSTREAM_REF` (a full 40-character
commit SHA). To move to a newer upstream, put the new commit SHA in that file and run:

```sh
zsh macos/update.sh
```

It checks out the pinned commit, lists what changed upstream and rebuilds. Add `--force` to
rebuild even when nothing changed.

To run the tests the way CI does:

```sh
for t in macos/tests/*-test.swift; do
  swiftc -parse-as-library macos/Updater.swift "$t" -o /tmp/nexview-test && /tmp/nexview-test
done
```

## Compatible Nexview server

The app is built and tested against the upstream Nexview commit in `macos/UPSTREAM_REF`
(currently `ee0242fd378dc4e2b77debc0f86bc1ac04085e7a`); use that version of Nexview or newer.
Besides the normal web interface, the app uses these server endpoints:

- `GET /api/health`: checking a server address
- `POST /api/auth/refresh`, `GET /api/auth/me`: the session
- `GET` and `POST /api/auth/me/schluessel`, `DELETE /api/auth/me/schluessel/<id>`: the
  read-only notification keys
- `POST /api/notifications/<id>/read`: marking notifications read

## Releasing (maintainers)

1. Bump the version in `macos/VERSION`.
2. Add a `## <version>` section with exactly that version to `macos/CHANGELOG.md`. It becomes
   the release notes.
3. Open a pull request, wait for CI to be green, then merge it.

On `main`, the Release workflow notices a version that has not been released yet. It runs the
tests, builds the app, signs the zip with the `NEXVIEW_UPDATE_SIGNING_KEY` secret and publishes
`Nexview-<version>.zip` and `Nexview-<version>.zip.sig` as release `v<version>`.

CI and release builds are signed with a self-signed Nexview code-signing certificate (public
copy in `macos/codesign.crt`, SHA-1 `ED08276C01EE6B11A38901579F29C987F50CDF47`), imported from
the `NEXVIEW_CODESIGN_P12` and `NEXVIEW_CODESIGN_P12_PASSWORD` secrets into a temporary keychain.
The designated requirement pins the bundle id and this certificate. It does not replace Apple
notarization: the first install still needs right-click → **Open**. Its purpose is a stable
identity across updates. Nexview no longer keeps anything in the Keychain: updating from 0.1.5
asks for Keychain access one last time, to move your servers into the file. The updater refuses updates that don't satisfy the running app's designated requirement.

To verify a release by hand (needs OpenSSL 3; the `openssl` that ships with macOS is LibreSSL,
so use `brew install openssl@3`):

```sh
V=0.1.3
curl -LO https://github.com/J0n4e/nexview_mac/releases/download/v$V/Nexview-$V.zip
curl -LO https://github.com/J0n4e/nexview_mac/releases/download/v$V/Nexview-$V.zip.sig

# The app's raw public key behind the Ed25519 DER prefix 302a300506032b6570032100, as PEM.
{ printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'
  printf 'QZNsnKHonvP62BxLWUxBUfej1aqt65ao2TeYBEeZNKk=' | base64 -d
} | openssl pkey -pubin -inform DER -out pub.pem

base64 -d < Nexview-$V.zip.sig > sig.bin
openssl pkeyutl -verify -pubin -inkey pub.pem -rawin -in Nexview-$V.zip -sigfile sig.bin
```

A genuine release prints `Signature Verified Successfully`.

## Notes

- Menu bar managers such as Thaw may only show the menu bar icon when the app runs from
  `/Applications`.
- Utilities that quit apps when their last window closes are ignored while *Run in background*
  is on, so Nexview keeps running for notifications.

## Thanks

All credit for Nexview goes to [DerKezorm](https://github.com/DerKezorm). This app is only a
native window around their work.
