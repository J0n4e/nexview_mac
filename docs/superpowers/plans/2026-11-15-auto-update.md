# Auto Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Nexview for Mac finds new GitHub releases, shows their notes, and on request installs them and restarts.

**Architecture:** A new `macos/Updater.swift` (singleton `Updater`) checks the GitHub releases API, shows an AppKit update window, and installs by unzipping next to the app and handing the swap to a short shell script that runs after the app quits. The release workflow fills the release text from `macos/CHANGELOG.md`.

**Tech Stack:** Swift (swiftc, no Xcode), AppKit, UserNotifications, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-11-15-auto-update-design.md`

## Global Constraints
- Releases: `https://api.github.com/repos/J0n4e/nexview_mac/releases/latest`, asset `Nexview-<version>.zip`, tag `v<version>`.
- Check 10 s after launch, then every 6 h; manual "Check for Updates…" in the app menu and the menu bar icon menu.
- Buttons: "Install and Restart", "Later", "Skip This Version". Skipped version in UserDefaults `SkippedUpdate`.
- Bundle id must stay `io.github.derkezorm.nexview.macos`; never install an equal or older version.
- No mention of Claude/AI in notes, commits or docs.

## Review Focus
- Version compare with differing lengths (`0.1.10` vs `0.1.9`, `0.2` vs `0.1.9`) and a `v` prefix: numeric compare per part.
- No network / GitHub rate limit (HTTP 403): automatic checks stay silent; a manual check says it could not check.
- Release without the zip asset: treated as "no update".
- Zip holding the wrong app (other bundle id or not newer): install refused, installed app untouched.
- App running from a folder it cannot write to: error shown, nothing removed.

---

### Task 1: Version compare
**Files:** Create `macos/Updater.swift`; Test `macos/tests/version-test.swift`
**Produces:** `Updater.isNewer(_ candidate: String, than current: String) -> Bool`

- [ ] Write `version-test.swift` asserting: `isNewer("0.1.10", than: "0.1.9")`, `isNewer("v0.2", than: "0.1.9")`, `!isNewer("0.1.1", than: "0.1.1")`, `!isNewer("0.1.0", than: "0.1.1")`, `!isNewer("junk", than: "0.1.1")`.
- [ ] Run `swiftc macos/Updater.swift macos/tests/version-test.swift -o /tmp/vt && /tmp/vt`; expect failure, then implement, expect `ok`.

### Task 2: Check, window, install
**Files:** Modify `macos/Updater.swift`, `macos/main.swift` (menus, launch, notification response), `macos/build.sh` (compile Updater.swift)
**Produces:** `Updater.shared.start()`, `@objc Updater.shared.checkNow()`, notification userInfo key `"update"` handled by `Updater.shared.showPending()`.

- [ ] `start()`: first check after 10 s, then a 6 h timer; automatic checks skip `SkippedUpdate` and stay silent on errors.
- [ ] Window: title, "you have …" line, notes rendered as Markdown in a scrollable text view, three buttons. If the main window is not visible, post a notification (category `update`) instead; clicking it opens the window.
- [ ] Install: download the zip, `ditto -x -k` into a temp folder, check bundle id and newer version via `Bundle(url:)`, remove quarantine (`xattr -dr com.apple.quarantine`), start a detached zsh script that waits for this PID, replaces `Bundle.main.bundleURL`, and reopens it; then quit. Failures show an alert.
- [ ] Build with `zsh macos/build.sh`; expect `==> Done`.

### Task 3: Release notes
**Files:** Create `macos/CHANGELOG.md`; Modify `.github/workflows/release.yml`
- [ ] CHANGELOG with sections `## 0.1.1` and `## 0.1.0`, plain-word lists.
- [ ] Workflow: prepend the `## $VERSION` section's body (awk) to the existing install text.
- [ ] Bump `macos/VERSION` to 0.1.2 and add its CHANGELOG entry when releasing.
