#!/bin/zsh
# Builds build/Nexview.app (arm64 / Apple Silicon only). Copy it to /Applications yourself when you want.
# The UI and all functions come live from your Nexview server; this is the native shell.
set -euo pipefail
ROOT="${0:A:h:h}"
SRC="$ROOT/src"; MAC="$ROOT/macos"; OUT="$ROOT/build"; CACHE="$ROOT/.cache"
[[ "$(uname -m)" == arm64 ]] || { echo "Apple Silicon only"; exit 1; }

# Nexview itself (only its icon and version are used); fetched on first build.
[[ -d "$SRC/.git" ]] || git clone --depth 50 https://github.com/DerKezorm/nexview "$SRC"

VERSION=$(cd "$SRC" && (git describe --tags --always 2>/dev/null || echo dev))
VERSION_NUM=$(grep -m1 -oE '^## \[?[0-9]+\.[0-9]+\.[0-9]+' "$SRC/CHANGELOG.md" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo 0.0.0)
APP_VERSION=$(cat "$MAC/VERSION")
echo "==> Building Nexview $APP_VERSION (Nexview $VERSION_NUM, $VERSION)"

APP="$OUT/Nexview.app"; RES="$APP/Contents/Resources"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$RES" "$CACHE"

echo "==> Native shell"
swiftc -O -target arm64-apple-macos14.0 -o "$APP/Contents/MacOS/Nexview" "$MAC/main.swift" "$MAC/Settings.swift"
cp "$MAC/bridge.js" "$RES/bridge.js"
sed -e "s/__APPVERSION__/$APP_VERSION/g" -e "s/__VERSION__/$VERSION_NUM/g" -e "s/__BUILD__/$VERSION/g" "$MAC/Info.plist" > "$APP/Contents/Info.plist"

echo "==> Icon (from upstream logo.svg)"
ICONSET="$CACHE/Nexview.iconset"; rm -rf "$ICONSET"; mkdir -p "$ICONSET"
swift "$MAC/render-icon.swift" "$SRC/frontend/public/logo.svg" "$CACHE/icon-1024.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$CACHE/icon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$CACHE/icon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$RES/Nexview.icns"

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP"
echo "==> Done: $APP"
