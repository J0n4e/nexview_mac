#!/bin/bash
# CI only: imports the Nexview code-signing identity (P12_BASE64 / P12_PASSWORD) into a temporary
# keychain and exports CODESIGN_IDENTITY / CODESIGN_KEYCHAIN to $GITHUB_ENV for macos/build.sh.
# Remove it again with: security delete-keychain "$CODESIGN_KEYCHAIN"
set -euo pipefail
SHA1=ED08276C01EE6B11A38901579F29C987F50CDF47
: "${P12_BASE64:?P12_BASE64 is empty}" "${P12_PASSWORD:?P12_PASSWORD is empty}" "${RUNNER_TEMP:?}" "${GITHUB_ENV:?}"
KC="$RUNNER_TEMP/nexview-codesign.keychain-db"
KC_PASS=$(openssl rand -hex 24)
echo "::add-mask::$KC_PASS"
DIR=$(umask 077 && mktemp -d "$RUNNER_TEMP/codesign.XXXXXX")
trap 'rm -rf "$DIR"' EXIT
(umask 077 && printf '%s' "$P12_BASE64" | base64 -D > "$DIR/id.p12")

security create-keychain -p "$KC_PASS" "$KC"
# Export right away so the always() cleanup step finds the keychain even if a later step fails.
echo "CODESIGN_KEYCHAIN=$KC" >> "$GITHUB_ENV"
security set-keychain-settings -lut 21600 "$KC"
security unlock-keychain -p "$KC_PASS" "$KC"
security import "$DIR/id.p12" -k "$KC" -P "$P12_PASSWORD" -f pkcs12 -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KC" >/dev/null
# Put it first in the user search list, keeping the existing ones.
existing=$(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"$//')
# shellcheck disable=SC2086
security list-keychains -d user -s "$KC" $existing

echo "--- identities (self-signed, so it may be listed as not trusted):"
security find-identity -p codesigning "$KC" || true
security find-identity -p codesigning "$KC" | grep -qi "$SHA1" || { echo "::error::identity $SHA1 not found after import"; exit 1; }

# Self-signed: check codesign accepts it; if not, trust the certificate for code signing.
printf 'int main(void){return 0;}\n' > "$DIR/probe.c"
clang -o "$DIR/probe" "$DIR/probe.c"
if ! codesign --force --timestamp=none --keychain "$KC" --sign "$SHA1" "$DIR/probe"; then
  echo "codesign refused the identity; adding the certificate as trusted for code signing"
  security find-certificate -a -p "$KC" > "$DIR/cert.pem"
  security add-trusted-cert -r trustRoot -p codeSign -k "$KC" "$DIR/cert.pem" \
    || sudo security add-trusted-cert -d -r trustRoot -p codeSign -k "$KC" "$DIR/cert.pem"
  codesign --force --timestamp=none --keychain "$KC" --sign "$SHA1" "$DIR/probe"
fi
codesign -dvv "$DIR/probe" 2>&1 | grep Authority

echo "CODESIGN_IDENTITY=$SHA1" >> "$GITHUB_ENV"
echo "Imported the Nexview code-signing identity into $KC"
