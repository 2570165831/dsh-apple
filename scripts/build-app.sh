#!/bin/bash
# Build the DSHPortC app for the iOS simulator.
#
# Everything is explicit: DEVELOPER_DIR, derived data inside this task's
# directory, and the custom simulator device set. No `xcode-select -s`, nothing
# installed globally.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

SCHEME="DSHPortC"
PROJECT="$ROOT/app/DSHPortC.xcodeproj"
DERIVED="$ROOT/DerivedData"

# The payload ships with the upstream Unicode property escapes replaced by
# explicit ranges, because this Node build has no ICU and rejects `\p{...}` at
# parse time. The patcher is idempotent, so running it every build is safe and
# keeps a fresh copy of the payload working without a separate step.
echo "== applying the no-ICU payload patches"
python3 "$ROOT/scripts/patch-payload-i18n.py" | head -3

# HEIC has to be an accepted IMAGE type in the browser bundle too, or an iPhone
# photo is routed to the verbatim file-upload path and never reaches the decoder.
# Idempotent, like the i18n patcher above.
echo "== applying the HEIC media-type payload patch"
python3 "$ROOT/scripts/patch-payload-heic-media-type.py" | head -4

echo "== applying the frozen-timeout payload patch"
python3 "$ROOT/scripts/patch-payload-frozen-timeout.py"

# The app links three static libraries and ships a guest image. Both are build
# products, not checked-in files, so they are built here rather than assumed:
# a stale library or a missing image would otherwise surface as a confusing link
# or boot failure much later.
echo "== building the iSH libraries"
"$ROOT/ish/scripts/build-ish.sh"

echo "== building the guest rootfs image"
if [ ! -f "$ROOT/build/rootfs/ish-rootfs.tar.gz" ]; then
  "$ROOT/ish/scripts/build-rootfs.sh"
else
  echo "   reusing $ROOT/build/rootfs/ish-rootfs.tar.gz (delete it to rebuild)"
fi

echo "== regenerating the Xcode project (resources may have changed)"
cd "$ROOT"
GEM_HOME="$ROOT/tools/gems" GEM_PATH="$ROOT/tools/gems" /usr/bin/ruby scripts/gen-xcode-project.rb

echo "== building $SCHEME for the simulator"
mkdir -p "$DERIVED"
BUILD_LOG="$DERIVED/last-build.log"
build_status=0
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -sdk iphonesimulator \
  -derivedDataPath "$DERIVED" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  build > "$BUILD_LOG" 2>&1 || build_status=$?
grep -E 'error:|warning: .*(script sandbox|deprecated)|BUILD (SUCCEEDED|FAILED)' "$BUILD_LOG" || true
if [ "$build_status" -ne 0 ]; then
  echo "xcodebuild failed with status $build_status; full log: $BUILD_LOG"
  exit "$build_status"
fi

APP="$DERIVED/Build/Products/Debug-iphonesimulator/DSHPortC.app"
[ -d "$APP" ] || { echo "build produced no app bundle at $APP"; exit 1; }
echo "== built $APP"
du -sh "$APP"
