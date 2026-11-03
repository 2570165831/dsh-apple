#!/bin/bash
# Download the prebuilt Node runtime (nodejs-mobile) and check it against the
# pinned hash. See THIRD_PARTY_NOTICES.md for its license and source.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
URL=https://github.com/heylogin/nodejs-mobile/releases/download/v24.5.0-mobile/nodejs-mobile-v24.5.0-ios.zip
SHA256=b3c515c451ed45d3a58915efe426e3cb9ac7debb56f649ddd62d871d97b2da9e
ZIP="$ROOT/vendor/nodejs-mobile-v24.5.0-ios.zip"
DEST="$ROOT/vendor/nodejs-mobile"

[ -d "$DEST/NodeMobile.xcframework" ] && { echo "vendor: already present"; exit 0; }
mkdir -p "$ROOT/vendor"
[ -f "$ZIP" ] || curl -fL --retry 3 -o "$ZIP" "$URL"
echo "$SHA256  $ZIP" | shasum -a 256 -c -
TMP="$(mktemp -d "$ROOT/vendor/.unzip.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
unzip -q "$ZIP" -d "$TMP"
FOUND="$(dirname "$(find "$TMP" -type d -name NodeMobile.xcframework -print -quit)")"
mv "$FOUND" "$DEST"
echo "vendor: ok"
