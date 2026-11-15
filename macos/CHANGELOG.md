# Changelog

What changed in each version of Nexview for Mac. The release on GitHub and the update window show the section for that version.

## 0.1.6

### Fixed
- No more Keychain password prompt at every launch. Servers and keys moved from the Keychain to a file only your user can read; updating asks one last time.

## 0.1.5

### Build
- Signed with a stable Nexview code-signing certificate, so macOS no longer asks for Keychain access after every update (one last time when updating from 0.1.4).

## 0.1.4

### Changed
- Touch ID sign-in and saved passwords removed; you sign in through the page as before, and the session usually keeps you signed in. Saved passwords are deleted on first launch. Servers and keys now live in the macOS Keychain.
- Right before replacing the app, the installer checks the new copy's code signature, bundle ID and version again; if anything is off, the old app is kept and reopened.
- The previous app is kept as a backup until the new one opens; if it fails to open, the previous app is put back and reopened.
- Each update is logged to `~/Library/Logs/Nexview/update.log`.
- The update window shows a progress bar while downloading, and its buttons are disabled during the install. Errors appear in the window.
- **Check for Updates** tells you when GitHub is rate-limiting checks, separately from being offline.
- Servers that can't be reached are checked less often, until they respond again.

### Fixed
- Editing a server's address keeps its read-only key, queued mark-reads and notification state when only the scheme or port changed (same host); a different host counts as a different server, so the old key is deleted there (when possible) and forgotten instead of being sent to the new one.
- The same server can no longer be added twice under a different spelling (case, default port, trailing slash); Settings and the add-server dialog say which server already uses the address. Existing duplicates are merged at launch.
- Signing out in the page, switching accounts, removing a server and **Sign out everywhere** now delete the app's read-only key on the server instead of only forgetting it on this Mac. If the server can't be reached, the key is deleted the next time that account signs in here.

### Build
- Code reorganised into smaller files.

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
