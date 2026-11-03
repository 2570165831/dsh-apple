#!/bin/bash
# Run step 9's functional acceptance inside the app and keep the evidence.
#
#   scripts/step9-acceptance.sh [--fold canonical|friendly] [--name LABEL] [--keep-data]
#
# The app is launched with -DSHPortCTestStep9Acceptance 1, which makes
# `sim/ios-app-entry.mjs` import `sim/step9-acceptance.mjs` instead of DSH. That
# module reconstructs the phone's five workspace records inside the app's own
# DSH_HOME, runs the SHIPPED `dedupeWorkspaceRegistry`, then drives the operation
# that failed on the phone — `sessionController.create({workspaceId})` followed by a
# real prompt — once for every row the registry offers.
#
# --fold friendly sets DSHPORTE_PATH_FOLD=friendly, which restores the pre-step-9
# fold direction (`/private/var` -> `/var`) in the Node migration AND the Swift
# repair. That is how the report's "before" column is measured on this same build
# rather than remembered from an older one.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

NAME="step9"
KEEP_DATA=0
FOLD=""
while [ $# -gt 0 ]; do
    case "$1" in
        --name) NAME="$2"; shift 2 ;;
        --keep-data) KEEP_DATA=1; shift ;;
        --fold) FOLD="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

# shellcheck source=device.sh
. "$HERE/device.sh"

mkdir -p "$ROOT/logs/step9"
UDID="$(device_udid)"
boot_device "$UDID"

APP="$ROOT/DerivedData/Build/Products/Debug-iphonesimulator/DSHPortC.app"
[ -d "$APP" ] || { echo "no app at $APP; run scripts/build-app.sh first" >&2; exit 1; }

xcrun simctl --set "$SIMSET" terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
if [ "$KEEP_DATA" = 0 ]; then
    # A fresh container: a previous run's DSH_HOME must not be able to make this
    # one pass. The fixture is planted by the module itself.
    xcrun simctl --set "$SIMSET" uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
fi
xcrun simctl --set "$SIMSET" install "$UDID" "$APP" >/dev/null || { echo "install failed" >&2; exit 1; }

LAUNCH_ARGS=(-DSHPortCTestStep9Acceptance 1)
[ -n "$FOLD" ] && LAUNCH_ARGS+=(-DSHPortCTestPathFold "$FOLD")

echo "== launching step9 acceptance (name=$NAME fold=${FOLD:-canonical})"
xcrun simctl --set "$SIMSET" launch "$UDID" "$BUNDLE_ID" "${LAUNCH_ARGS[@]}" >/dev/null || {
    echo "launch failed" >&2; exit 1
}

CONTAINER="$(xcrun simctl --set "$SIMSET" get_app_container "$UDID" "$BUNDLE_ID" data)"
# The status/log/session-url files live under Library/Application Support, not
# Documents, so they stay out of the Files app. Probe files stay in Documents.
RUNTIME="$CONTAINER/Library/Application Support/DSHPortC"
OUT="$CONTAINER/Documents/DSHPortE-step9-acceptance.json"
LOG="$RUNTIME/DSHPortC-node.log"

echo "== waiting for $OUT"
# THE COMPLETION MARKER IS A TOP-LEVEL `summary`, checked by PARSING, not by grep.
# Two traps here, both hit on real runs of this script:
#   * the module writes its criteria incrementally, so the file exists long before
#     it is finished — the selection criterion alone drives three real agent turns;
#   * the migration criterion legitimately carries its own `facts.summary` (the
#     module's run summary), so `grep '"summary"'` matched a report that was still
#     mid-run and the runner copied it half-finished, reporting "passed None/None".
complete() {
    [ -f "$OUT" ] || return 1
    python3 -c 'import json,sys
try: data = json.load(open(sys.argv[1]))
except Exception: sys.exit(1)
sys.exit(0 if isinstance(data, dict) and isinstance(data.get("summary"), dict) else 1)' "$OUT"
}
for _ in $(seq 1 300); do
    if complete; then break; fi
    sleep 2
done

if [ ! -f "$OUT" ]; then
    echo "no report was written" >&2
    tail -40 "$LOG" 2>/dev/null >&2
    exit 1
fi

cp "$OUT" "$ROOT/logs/step9/$NAME.json"
cp "$LOG" "$ROOT/logs/step9/$NAME-node.log" 2>/dev/null || true
if [ -f "$CONTAINER/Documents/DSHPortE-session-migrate.json" ]; then
    cp "$CONTAINER/Documents/DSHPortE-session-migrate.json" "$ROOT/logs/step9/$NAME-migrate.json"
fi
# The registry itself, for the report's before/after tables.
HOME_DIR="$CONTAINER/Library/Application Support/DSH"
if [ -f "$HOME_DIR/storages/workspace.json" ]; then
    cp "$HOME_DIR/storages/workspace.json" "$ROOT/logs/step9/$NAME-workspace.json"
fi

echo "== summary"
python3 - "$ROOT/logs/step9/$NAME.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
summary = data.get("summary", {})
print(f"  passed {summary.get('passed')}/{summary.get('total')}")
for key, ok in summary.get("results", {}).items():
    print(f"  {'PASS' if ok else 'FAIL'}  {key}")
print(f"  report: {sys.argv[1]}")
PY
