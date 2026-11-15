#!/bin/zsh
# Builds build/Nexview.app (arm64 / Apple Silicon only). Copy it to /Applications yourself when you want.
# The UI and all functions come live from your Nexview server; this is the native shell.
set -euo pipefail
ROOT="${0:A:h:h}"
SRC="$ROOT/src"; MAC="$ROOT/macos"; OUT="$ROOT/build"; CACHE="$ROOT/.cache"
[[ "$(uname -m)" == arm64 ]] || { echo "Apple Silicon only"; exit 1; }

# Keep only characters that are safe in sed replacements and plist strings.
sanitize() { print -r -- "$1" | LC_ALL=C tr -cd 'A-Za-z0-9.-'; }

# Nexview itself (only its icon and version are used), pinned to the commit in macos/UPSTREAM_REF.
UPSTREAM_URL=https://github.com/DerKezorm/nexview
UPSTREAM_REF=$(LC_ALL=C tr -cd '0-9a-f' < "$MAC/UPSTREAM_REF")
[[ ${#UPSTREAM_REF} -eq 40 ]] || { echo "macos/UPSTREAM_REF must hold a full 40-char commit SHA"; exit 1; }
if [[ ! -d "$SRC/.git" ]]; then
  git init -q "$SRC"
  git -C "$SRC" remote add origin "$UPSTREAM_URL"
fi
if [[ "$(git -C "$SRC" rev-parse -q --verify HEAD 2>/dev/null || true)" != "$UPSTREAM_REF" ]]; then
  git -C "$SRC" cat-file -e "$UPSTREAM_REF^{commit}" 2>/dev/null \
    || git -C "$SRC" fetch -q --depth 50 --tags origin "$UPSTREAM_REF"
  git -C "$SRC" checkout -q --detach "$UPSTREAM_REF"
fi

VERSION=$(sanitize "$(cd "$SRC" && (git describe --tags --always 2>/dev/null || echo dev))")
VERSION_NUM=$(grep -m1 -oE '^## \[?[0-9]+\.[0-9]+\.[0-9]+' "$SRC/CHANGELOG.md" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo 0.0.0)
VERSION_NUM=$(sanitize "$VERSION_NUM")
APP_VERSION=$(sanitize "$(cat "$MAC/VERSION")")
[[ -n "$APP_VERSION" ]] || { echo "macos/VERSION is empty"; exit 1; }
# CFBundleVersion must be numeric: use the commit count of this repo.
BUILD_NUM=$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 0)
[[ "$BUILD_NUM" == <-> ]] || BUILD_NUM=0
echo "==> Building Nexview $APP_VERSION ($BUILD_NUM) (Nexview $VERSION_NUM, $VERSION)"

# Build into a temp dir; only replace build/Nexview.app once everything succeeded.
mkdir -p "$OUT" "$CACHE"
TMP=$(mktemp -d "$OUT/.build.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
APP="$TMP/Nexview.app"; RES="$APP/Contents/Resources"
mkdir -p "$APP/Contents/MacOS" "$RES"

echo "==> Native shell"
swiftc -O -target arm64-apple-macos14.0 -o "$APP/Contents/MacOS/Nexview" "$MAC/main.swift" "$MAC/Settings.swift" "$MAC/Updater.swift"
cp "$MAC/bridge.js" "$RES/bridge.js"
sed -e "s/__APPVERSION__/$APP_VERSION/g" -e "s/__VERSION__/$VERSION_NUM/g" -e "s/__BUILD__/$BUILD_NUM/g" "$MAC/Info.plist" > "$APP/Contents/Info.plist"

echo "==> Icon (from upstream logo.svg)"
ICONSET="$CACHE/Nexview.iconset"; rm -rf "$ICONSET"; mkdir -p "$ICONSET"
swift "$MAC/render-icon.swift" "$SRC/frontend/public/logo.svg" "$CACHE/icon-1024.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$CACHE/icon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$CACHE/icon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$RES/Nexview.icns"

echo "==> Signing (ad-hoc, hardened runtime)"
codesign --force --options runtime --sign - "$APP/Contents/MacOS/Nexview"
codesign --force --options runtime --sign - "$APP"
codesign --verify --strict "$APP"

rm -rf "$OUT/Nexview.app"
mv "$APP" "$OUT/Nexview.app"
echo "==> Done: $OUT/Nexview.app"
