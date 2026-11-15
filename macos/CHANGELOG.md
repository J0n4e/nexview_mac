# Changelog

What changed in each version of Nexview for Mac. The release on GitHub and the update window show the section for that version.

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
