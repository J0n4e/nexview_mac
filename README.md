# Nexview for Mac

A native macOS app for [Nexview](https://github.com/DerKezorm/nexview), the self-hosted media
discovery dashboard by DerKezorm. It connects to your own Nexview server and shows it in a proper
Mac window, with native notifications, a menu bar icon and Touch ID sign-in.

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
- **Touch ID sign-in**: sign in once and let Touch ID fill in your password afterwards.
- **Run in background**: closing the window leaves only the menu bar icon; click it to bring
  Nexview back. ⌘Q quits completely.
- **Open at login**.

Server addresses, saved sign-ins and access keys are encrypted with a key held in the Mac's
Secure Enclave and stored in `~/Library/Application Support/Nexview for Mac/`. They never leave
the Mac.

## Install

Download the latest `Nexview-<version>.zip` from
[Releases](https://github.com/J0n4e/nexview_mac/releases), unzip it and move **Nexview** to
Applications. The app is signed ad hoc, so the first time you open it, right-click it and choose
**Open**. Then enter the address of your Nexview server and sign in.

## Build

Requirements: an Apple Silicon Mac with the Xcode command line tools (`xcode-select --install`).

```sh
zsh macos/build.sh
```

This fetches Nexview's code into `src/` on the first run (only its icon and version are used)
and builds `build/Nexview.app`. Copy it to `/Applications` to install it.

```sh
zsh macos/update.sh
```

pulls the latest Nexview and rebuilds.

The app is signed ad hoc, so the first time you open it on a Mac, right-click it and choose
**Open**.

## Notes

- Menu bar managers such as Thaw may only show the menu bar icon when the app runs from
  `/Applications`.
- Utilities that quit apps when their last window closes are ignored while *Run in background*
  is on, so Nexview keeps running for notifications.

## Thanks

All credit for Nexview goes to [DerKezorm](https://github.com/DerKezorm). This app is only a
native window around their work.
