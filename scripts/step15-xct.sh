#!/bin/bash
# Run step 15's real-touch UI tests on the device created for them.
#
# `xcodebuild` cannot see the task's custom device set (REPORT-1 §9.3: it lists
# only the default set's devices). Step 11's UI tests were therefore written and
# never run. Step 15's brief allows exactly one new device in the DEFAULT set
# (`dsh-portE-xct-15`) for this purpose, and this script is the only thing that
# touches it.
#
#   scripts/step15-xct.sh                      # every Step15 test
#   scripts/step15-xct.sh ComposerKeyboardTests # step 11's five, re-run here
#
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
DEVICE_NAME="${DSHPORTE_XCT_DEVICE:-dsh-portE-xct-15}"
ONLY="${1:-Step15TouchTests}"
SHOTS="$ROOT/logs/step15/xct-shots"
mkdir -p "$SHOTS"

UDID=$(xcrun simctl list devices | grep -F "$DEVICE_NAME (" | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/' | head -n 1)
if [ -z "$UDID" ]; then
  echo "step15-xct: no device named $DEVICE_NAME; create it with:" >&2
  echo "  xcrun simctl create $DEVICE_NAME com.apple.CoreSimulator.SimDeviceType.iPhone-17 com.apple.CoreSimulator.SimRuntime.iOS-27-0" >&2
  exit 2
fi
echo "== device $DEVICE_NAME $UDID"
xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$UDID" >/dev/null 2>&1 || true
# The soft keyboard has to be on, or nothing in these tests can type.
#
# The tool takes a DEVICE SET PATH, and the empty string aborts inside
# CoreSimulator (`deviceSetWithPath:` with "" is not "the default set"). This
# device lives in the DEFAULT set, whose path is the one CoreSimulator owns.
DEFAULT_SET="$HOME/Library/Developer/CoreSimulator/Devices"
if [ -x "$ROOT/tools/kbd/softkeyboard" ]; then
  "$ROOT/tools/kbd/softkeyboard" "$DEFAULT_SET" "$UDID" soft >/dev/null 2>&1 \
    || echo "step15-xct: WARNING could not turn the software keyboard on" >&2
else
  echo "step15-xct: WARNING tools/kbd/softkeyboard is not built" >&2
fi

# The mock has to be listening: the tests send prompts.
if ! curl -sS -m 2 "http://127.0.0.1:${MOCK_PORT:-19700}/healthz" >/dev/null 2>&1; then
  echo "step15-xct: no mock on ${MOCK_PORT:-19700}; start it with scripts/mock-start.sh start" >&2
  exit 2
fi

LOG="$ROOT/logs/step15/xct-$ONLY.log"
# A result bundle path must not exist; a previous run's is stale evidence, and
# xcodebuild refuses rather than overwriting it.
rm -rf "$ROOT/logs/step15/xct-$ONLY.xcresult"
xcodebuild test \
  -project "$ROOT/app/DSHPortC.xcodeproj" \
  -scheme DSHPortC \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$ROOT/DerivedData" \
  -only-testing:"DSHPortCUITests/$ONLY" \
  -resultBundlePath "$ROOT/logs/step15/xct-$ONLY.xcresult" \
  TEST_RUNNER_DSHPORTE_XCT_SHOTS="$SHOTS" \
  >"$LOG" 2>&1
STATUS=$?
grep -E "Test Case .* (passed|failed)|Testing failed|TEST (SUCCEEDED|FAILED)|error:" "$LOG" | tail -30
echo "== exit $STATUS, log $LOG"
exit $STATUS
