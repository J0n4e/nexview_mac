# Auto update for Nexview for Mac

## Why
New releases (like 0.1.1) should reach the app without downloading the zip from GitHub by hand.

## Behaviour
- The app checks `https://api.github.com/repos/J0n4e/nexview_mac/releases/latest` shortly after launch and then every 6 hours, and when you choose **Check for Updates…** (app menu and menu bar icon menu).
- If the release's version is newer than the running one, a window opens: "Nexview for Mac 0.1.2 is available (you have 0.1.1)", the release notes below it, scrollable, and three buttons: **Install and Restart**, **Later**, **Skip This Version**.
- With the main window closed (running in background), a macOS notification says an update is available; clicking it opens that window.
- Install and Restart: download `Nexview-<version>.zip`, unzip it into a temporary folder, check that it holds `Nexview.app` with the same bundle id and the new version, remove the download marker (quarantine), swap it in place of the running app, relaunch. Any failure shows an error and leaves the installed app untouched.
- Skip This Version: no prompt again until a newer release appears. Later: ask again at the next check.
- A manual check that finds nothing says "You're up to date."

## Release notes
The window shows the GitHub release text, rendered as Markdown. The release workflow takes that text from a new `macos/CHANGELOG.md` (the section for the version being released), followed by the existing install instructions. Each release gets a short list of what changed in plain words.

## Approaches
- **Built-in updater (picked):** small Swift code, fits an ad-hoc signed app built without Xcode.
- Sparkle: needs Xcode and proper code signing for its update checks, not available here.
- Only telling you to download it: misses the point of updating by itself.

## Not included
No silent installs, no beta channel, no downgrades.
