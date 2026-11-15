#!/bin/bash
# CI only: asserts the app is signed with the Nexview certificate and a pinned designated requirement.
set -euo pipefail
APP=${1:-build/Nexview.app}
LEAF=ed08276c01ee6b11a38901579f29c987f50cdf47
ID=io.github.derkezorm.nexview.macos
codesign --verify --deep --strict --verbose=2 "$APP"
info=$(codesign -dvvv "$APP" 2>&1); echo "$info"
req=$(codesign -d -r- "$APP" 2>&1); echo "$req"
grep -qx 'Authority=Nexview for Mac Code Signing' <<<"$info" || { echo "::error::not signed by 'Nexview for Mac Code Signing'"; exit 1; }
grep -qx "Identifier=$ID" <<<"$info" || { echo "::error::unexpected identifier"; exit 1; }
grep -qi "certificate leaf = H\"$LEAF\"" <<<"$req" || { echo "::error::designated requirement lacks the leaf hash"; exit 1; }
codesign --verify --strict -R="identifier \"$ID\" and certificate leaf = H\"$LEAF\"" "$APP"
echo "OK: signed with the Nexview code-signing certificate"
