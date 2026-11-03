#!/bin/bash
# Run step 7's functional acceptance inside the app and keep the evidence.
#
#   scripts/step7-acceptance.sh [--rg-respell 0|1] [--name LABEL] [--keep-data]
#
# The app is launched with -DSHPortCTestStep7Acceptance 1, which makes
# `sim/ios-app-entry.mjs` import `sim/step7-acceptance.mjs` instead of DSH. That
# module mounts the REAL ios-sim profile and drives `ctx.fs`, `ctx.subprocess` and
# the registered search tools, then writes its verdict beside the workspace.
#
# --rg-respell 0 sets DSHPORTE_RG_RESPELL=0, which reproduces the pre-fix
# `ripgrep launch failed` on the SAME build. That is how the report's "before"
# column is measured instead of remembered.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

RESPELL=""
NAME="step7"
KEEP_DATA=0
while [ $# -gt 0 ]; do
    case "$1" in
        --rg-respell) RESPELL="$2"; shift 2 ;;
        --name) NAME="$2"; shift 2 ;;
        --keep-data) KEEP_DATA=1; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

# shellcheck source=device.sh
. "$HERE/device.sh"

mkdir -p "$ROOT/logs/step7"
UDID="$(device_udid)"
boot_device "$UDID"

APP="$ROOT/DerivedData/Build/Products/Debug-iphonesimulator/DSHPortC.app"
[ -d "$APP" ] || { echo "no app at $APP; run scripts/build-app.sh first" >&2; exit 1; }

xcrun simctl --set "$SIMSET" terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
if [ "$KEEP_DATA" = 0 ]; then
    # A fresh container: a previous run's workspace, DSH_HOME and guest state must
    # not be able to make this one pass.
    xcrun simctl --set "$SIMSET" uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
fi
xcrun simctl --set "$SIMSET" install "$UDID" "$APP" >/dev/null || { echo "install failed" >&2; exit 1; }

LAUNCH_ENV=()
[ -n "$RESPELL" ] && LAUNCH_ENV+=("SIMCTL_CHILD_DSHPORTE_RG_RESPELL=$RESPELL")

echo "== launching step7 acceptance (name=$NAME respell=${RESPELL:-default})"
if [ "${#LAUNCH_ENV[@]}" -gt 0 ]; then
    env "${LAUNCH_ENV[@]}" xcrun simctl --set "$SIMSET" launch "$UDID" "$BUNDLE_ID" \
        -DSHPortCTestStep7Acceptance 1 >/dev/null || { echo "launch failed" >&2; exit 1; }
else
    xcrun simctl --set "$SIMSET" launch "$UDID" "$BUNDLE_ID" \
        -DSHPortCTestStep7Acceptance 1 >/dev/null || { echo "launch failed" >&2; exit 1; }
fi

CONTAINER="$(xcrun simctl --set "$SIMSET" get_app_container "$UDID" "$BUNDLE_ID" data)"
# The status/log/session-url files live under Library/Application Support, not
# Documents, so they stay out of the Files app. Probe files stay in Documents.
RUNTIME="$CONTAINER/Library/Application Support/DSHPortC"
OUT="$CONTAINER/Documents/DSHPortE-step7-acceptance.json"
LOG="$RUNTIME/DSHPortC-node.log"

echo "== waiting for $OUT"
for _ in $(seq 1 120); do
    if [ -f "$OUT" ] && grep -q '"summary"' "$OUT" 2>/dev/null; then break; fi
    sleep 2
done

if [ ! -f "$OUT" ]; then
    echo "no report was written" >&2
    tail -40 "$LOG" 2>/dev/null >&2
    exit 1
fi

cp "$OUT" "$ROOT/logs/step7/$NAME.json"
cp "$LOG" "$ROOT/logs/step7/$NAME-node.log" 2>/dev/null || true
if [ -f "$CONTAINER/Documents/DSHPortE-session-migrate.json" ]; then
    cp "$CONTAINER/Documents/DSHPortE-session-migrate.json" "$ROOT/logs/step7/$NAME-migrate.json"
fi

echo "== summary"
python3 - "$ROOT/logs/step7/$NAME.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
summary = data.get("summary", {})
print(f"  passed {summary.get('passed')}/{summary.get('total')}")
for key, ok in summary.get("results", {}).items():
    print(f"  {'PASS' if ok else 'FAIL'}  {key}")
print(f"  report: {sys.argv[1]}")
PY
