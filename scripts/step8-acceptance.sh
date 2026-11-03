#!/bin/bash
# Run step 8's functional acceptance inside the app and keep the evidence.
#
#   scripts/step8-acceptance.sh [--name LABEL] [--keep-data]
#
# The app is launched with -DSHPortCTestStep8Acceptance 1, which makes
# `sim/ios-app-entry.mjs` import `sim/step8-acceptance.mjs` instead of DSH. That
# module mounts the REAL ios-sim profile and checks four things:
#
#   provider_guard   the deleted-file refusal comes from the provider's versioned
#                    replace, and the guarded-create branch succeeds after it
#   policy_wiring    the line that emits the absent observation before the read
#                    throws, the line that maps absence to createIfAbsent, and the
#                    editor's stat-then-intent order
#   prompt_section   the recovery sentence is in the ASSEMBLED system prompt, after
#                    the edit guidance it completes
#   turn_harness     the prompt file and the mock script that produce the real-turn
#                    transcript exist and are consistent
#
# WHY THE TWO FILES ARE COPIED IN. `prompts/` and `mock/` are host-side test
# material — the prompt is read by `scripts/agent-turn.py` and the mock is a
# host-side server — so neither is a bundle resource. The criterion has to compare
# against the same bytes the real turn used, so this script copies them into the
# app container's Documents directory and passes the container paths in through
# launch arguments (NodeRunner.forwardTestFlags republishes them as environment).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

NAME="step8"
KEEP_DATA=0
NOTE="1"
while [ $# -gt 0 ]; do
    case "$1" in
        --name) NAME="$2"; shift 2 ;;
        --keep-data) KEEP_DATA=1; shift ;;
        # Remove the recovery sentence from the assembled prompt, for the same
        # reason P-16 has `--rg-respell 0`: a criterion that only ever sees the
        # fixed build cannot show that the fix is what made the difference. With
        # the note off, `prompt_section` must report the section as ABSENT and
        # still pass — that is the control.
        --note) NOTE="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

# shellcheck source=device.sh
. "$HERE/device.sh"

mkdir -p "$ROOT/logs/step8"
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

CONTAINER="$(xcrun simctl --set "$SIMSET" get_app_container "$UDID" "$BUNDLE_ID" data)"
DOCS="$CONTAINER/Documents"
mkdir -p "$DOCS"

# The two files the harness criterion compares against, delivered as data rather
# than assumed to be reachable from inside the app bundle.
PROMPT_DEST="$DOCS/step8-prompt.txt"
REPLIES_DEST="$DOCS/step8-replies.mjs"
cp "$ROOT/prompts/17-step8-rmtest.txt" "$PROMPT_DEST" || exit 1
cp "$ROOT/mock/replies.mjs" "$REPLIES_DEST" || exit 1

OUT="$DOCS/DSHPortE-step8-acceptance.json"
# The status/log/session-url files live under Library/Application Support, not
# Documents, so they stay out of the Files app. The staged prompt/replies and the
# probe file stay in Documents.
RUNTIME="$CONTAINER/Library/Application Support/DSHPortC"
LOG="$RUNTIME/DSHPortC-node.log"
rm -f "$OUT"

echo "== launching step8 acceptance (name=$NAME note=$NOTE)"
LAUNCH_ARGS=(
    -DSHPortCTestStep8Acceptance 1
    -DSHPortCTestStep8PromptFile "$PROMPT_DEST"
    -DSHPortCTestStep8MockReplies "$REPLIES_DEST"
)
[ "$NOTE" = "0" ] && LAUNCH_ARGS+=(-DSHPortCTestStep8Note 0)
xcrun simctl --set "$SIMSET" launch "$UDID" "$BUNDLE_ID" "${LAUNCH_ARGS[@]}" >/dev/null \
    || { echo "launch failed" >&2; exit 1; }

echo "== waiting for $OUT"
for _ in $(seq 1 90); do
    if [ -f "$OUT" ] && grep -q '"summary"' "$OUT" 2>/dev/null; then break; fi
    sleep 2
done

if [ ! -f "$OUT" ]; then
    echo "no report was written" >&2
    tail -40 "$LOG" 2>/dev/null >&2
    exit 1
fi

cp "$OUT" "$ROOT/logs/step8/$NAME.json"
cp "$LOG" "$ROOT/logs/step8/$NAME-node.log" 2>/dev/null || true

echo "== summary"
python3 - "$ROOT/logs/step8/$NAME.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
summary = data.get("summary", {})
print(f"  passed {summary.get('passed')}/{summary.get('total')}")
for key, ok in summary.get("results", {}).items():
    print(f"  {'PASS' if ok else 'FAIL'}  {key}")
print(f"  report: {sys.argv[1]}")
PY
