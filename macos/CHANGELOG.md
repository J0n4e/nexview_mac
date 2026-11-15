# Changelog

What changed in each version of Nexview for Mac. The release on GitHub and the update window show the section for that version.

## 0.1.3

### New
- **Signed updates.** Every release is signed, and the app checks the signature before installing an update. An unsigned or altered download is refused, and the installed app stays as it was.
- A warning appears when a server is added with plain `http://` and isn't on your local network, because passwords would travel unencrypted.

### Changed
- Addresses typed without `http://` or `https://` now default to `https://`.
- Saved sign-ins and the app's connection to the page only work for the exact server address, including `http` vs `https` and the port.
- Links that open outside the app are limited to web and mail links.
- **Open at Login** is now off by default for new installs.
- Updates are only downloaded from this project's GitHub releases.

### Fixed
- Notifications that arrived while the app was in front are no longer marked read on the server at the next launch.
- Notifications and the Dock badge come back by themselves after the server rejects the app's key, instead of needing a reload.
- Clearing a notification no longer sometimes marks others read, and reads are no longer sent to the server several times.
- A manual update check no longer says "You're up to date" when the release's download is missing.
- The update window no longer gets replaced while an update is downloading, and temporary update files are cleaned up.
- The error page shows server addresses and error text safely.

### Build
- Built from a pinned version of Nexview, so the same version always builds the same app.
- Tests run on every change and before each release. The release workflow uses pinned actions and minimal permissions.
- The build number is now a plain number.

## 0.1.2

### New
- **Updates from inside the app.** Nexview for Mac looks for new versions by itself, 10 seconds after it starts and then every 6 hours.
- **Update window** with the release notes and three buttons: **Install and Restart**, **Later** and **Skip This Version**.
- **Check for Updates…** in the Nexview menu and in the menu bar icon's menu.
- When the app runs in the background, a notification says an update is ready. Clicking it opens the update window.

### Changed
- Updates install without the right-click → **Open** step. That step is only needed the first time you install the app by hand.
- Releases now list what changed, taken from this changelog.

### Fixed
- No bug fixes in this version.

### Build
- Built on GitHub Actions (macOS 15 runner) with the Swift command-line compiler, for Apple Silicon only, macOS 14 Sonoma or newer.
- Signed ad hoc.
- Before installing, the app checks that the download is Nexview for Mac at a newer version. If it isn't, or anything fails, the installed app stays as it was.

## 0.1.1

### Fixed
- New notifications no longer disappear from Notification Center right away. The app had mistaken a notification that wasn't listed yet for one you had cleared, and marked it read on the server.
- The Dock badge shows the unread count again (same cause).

### Changed
- The badge counts and the server check use Nexview's stable `/api/v1` addresses, so they keep working when Nexview updates.
- The README says that this is a community app, not an official Nexview project, and where to report problems.

### Build
- Built on GitHub Actions (macOS 15 runner) for Apple Silicon, macOS 14 Sonoma or newer. Signed ad hoc.

## 0.1.0

### New
- First release: Nexview in a native Mac window, with several servers, notifications, a Dock badge, a menu bar icon, Touch ID sign-in, and Settings and About windows.

### Build
- Built on GitHub Actions (macOS 15 runner) for Apple Silicon, macOS 14 Sonoma or newer. Signed ad hoc.
