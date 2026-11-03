#!/bin/bash
# Build and sign DSHPortC for a physical iPhone (Debug, development signing).
# Builds only; it does not install or launch anything on the device.
#
# Set DSH_TEAM_ID to your Apple developer team. Nothing here imports, exports or generates a
# certificate or key.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
TEAM="${DSH_TEAM_ID:?set DSH_TEAM_ID to your Apple developer team}"

python3 "$ROOT/scripts/patch-payload-i18n.py" | head -3
python3 "$ROOT/scripts/patch-payload-heic-media-type.py" | head -4
python3 "$ROOT/scripts/patch-payload-frozen-timeout.py"
"$ROOT/ish/scripts/build-ish.sh" -p iphoneos
if [ ! -f "$ROOT/build/rootfs/ish-rootfs.tar.gz" ]; then
  "$ROOT/ish/scripts/build-cli.sh"
  "$ROOT/ish/scripts/build-rootfs.sh"
fi
cd "$ROOT"
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
GEM_HOME="$ROOT/tools/gems" GEM_PATH="$ROOT/tools/gems" /usr/bin/ruby scripts/gen-xcode-project.rb

xcodebuild \
  -project "$ROOT/app/DSHPortC.xcodeproj" \
  -scheme DSHPortC \
  -configuration Debug \
  -destination "${DEST:-generic/platform=iOS}" \
  -derivedDataPath "$ROOT/DerivedData" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM="$TEAM" \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY="${SIGN_IDENTITY:-Apple Development}" \
  ${EXTRA_ARGS:-} \
  build
