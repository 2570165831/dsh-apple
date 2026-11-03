#!/bin/bash
# Build a landscape-only variant of the app so the iPad's landscape layout can be
# measured without a rotation gesture.
#
# WHY THIS EXISTS
# ---------------
# Nothing on this machine can rotate the iPad simulator programmatically, and each
# of the three obvious routes was measured and failed:
#
#   * `simctl` has no rotate verb. `simctl io screenConfig geometry 2360x1640`
#     answers "No mode found that supports size" — the panel has one mode.
#   * `-requestGeometryUpdate:` from inside the app answers
#     "当前窗口模式不允许以编程方式更改界面方向" (the current window mode does
#     not permit changing the interface orientation programmatically). Recorded in
#     logs/step10/padprobe-rot1.json as a `geometry-update-refused` event.
#   * `XCUIDevice.shared.orientation` exists only in a UI test, and `xcodebuild`
#     cannot see this task's custom device set (REPORT-1 §9.3), so a UI test
#     would have to run on a device in the DEFAULT set — which step 10 forbids
#     touching.
#   * Xcode 27 no longer ships Simulator.app at all, so there is no window to drag.
#
# What is left, and what this does: an app that only supports landscape launches
# in landscape. That is not a rotation gesture — it is a different build — but the
# layout it produces is the real one: same viewport, same safe areas, same
# SwiftUI/scene behaviour, because it is the same code with one Info.plist key
# narrowed. The report says which numbers came from which build.
#
# The key is narrowed for the DURATION OF ONE BUILD and restored by a trap, so a
# failed run does not leave the repository holding a landscape-only app.
#
# Usage
#   scripts/build-pad-landscape.sh [--restore]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

PLIST="$ROOT/app/DSHPortC/Info.plist"
BACKUP="$ROOT/logs/step10/Info.plist.portrait-backup"
mkdir -p "$ROOT/logs/step10"

restore() {
    if [ -f "$BACKUP" ]; then
        cp "$BACKUP" "$PLIST"
        echo "== Info.plist restored from $BACKUP"
        rm -f "$BACKUP"
    fi
}

if [ "${1:-}" = "--restore" ]; then
    restore
    exit 0
fi

if [ -f "$BACKUP" ]; then
    echo "a landscape variant is already staged ($BACKUP); run with --restore first" >&2
    exit 1
fi

cp "$PLIST" "$BACKUP"
trap restore EXIT

# Only the iPad idiom key. The iPhone key is left alone: this build is for the
# iPad device, and narrowing the phone's orientations would make the iPhone
# regression measure something different from every earlier report.
plutil -replace 'UISupportedInterfaceOrientations~ipad' -json \
    '["UIInterfaceOrientationLandscapeLeft","UIInterfaceOrientationLandscapeRight"]' "$PLIST" \
    || { echo "plutil failed" >&2; exit 1; }
echo "== UISupportedInterfaceOrientations~ipad narrowed to landscape"

"$ROOT/scripts/build-app.sh"
STATUS=$?
trap - EXIT
restore
exit $STATUS
