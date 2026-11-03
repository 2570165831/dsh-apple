#!/bin/bash
# Screenshot this task's simulator into screenshots/step18/ without going through
# the task volume directly.
#
# `simctl io screenshot` writes from a helper process that this machine has not
# granted access to an external volume: the PNG write there fails with
# "You don't have permission … NSPOSIXErrorDomain code=1" while the same command
# into /tmp succeeds and `cp` copies it across. REPORT-11 records the run where
# the whole matrix silently produced zero PNGs for exactly this reason.
#
#   scripts/step18-shot.sh 01-hero
#   DSHPORTE_DEVICE=ipad scripts/step18-shot.sh 90-ipad-portrait
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
NAME="${1:?usage: step18-shot.sh <name>}"
DEVICE="${DSHPORTE_DEVICE:-phone-polish}"

case "$DEVICE" in
  phone-polish|iphone-polish) UDID="7258CB6D-4C1E-42AE-BFF6-7D3AB90BCD29" ;;
  ipad)                       UDID="DB001DDF-3899-4752-BEDC-1DCBADE092CA" ;;
  xct-18|iphone)              UDID="${STEP18_XCT_UDID:?set STEP18_XCT_UDID for the XCUITest device}" ;;
  xct-18-ipad)                UDID="${STEP18_XCT_IPAD_UDID:?set STEP18_XCT_IPAD_UDID}" ;;
  *) echo "step18-shot: unknown DSHPORTE_DEVICE '$DEVICE'" >&2; exit 2 ;;
esac

SET="$ROOT/simdevices"
OUT="$ROOT/screenshots/step18"
mkdir -p "$OUT"
STAGE="$(mktemp -d /tmp/step18-shot.XXXXXX)/shot.png"

xcrun simctl --set "$SET" io "$UDID" screenshot "$STAGE" >/dev/null 2>&1 || true
if [ ! -f "$STAGE" ]; then
  echo "step18-shot: screenshot failed (device $UDID booted?)" >&2
  rm -rf "$(dirname "$STAGE")"
  exit 1
fi
cp "$STAGE" "$OUT/$NAME.png"
rm -rf "$(dirname "$STAGE")"
# The size is recorded because a screenshot that silently came out at the wrong
# scale is worse than no screenshot: it looks like evidence.
python3 -c "
import struct, sys
path = sys.argv[1]
with open(path, 'rb') as handle:
    head = handle.read(33)
width, height = struct.unpack('>II', head[16:24])
print(f'{path} {width}x{height}')
" "$OUT/$NAME.png"
