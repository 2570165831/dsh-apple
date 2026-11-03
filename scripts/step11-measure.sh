#!/bin/bash
# Measure every Step 11 state on one device, in one pass.
#
#   scripts/step11-measure.sh before      # the pre-fix build
#   scripts/step11-measure.sh after       # the post-fix build
#   DSHPORTE_DEVICE=ipad scripts/step11-measure.sh after-ipad
#
# One launch per state, because the container survives between launches and a
# state that reuses the previous launch's page would be measuring the page the
# last state left behind. Every state's raw numbers land in
# logs/step11/<prefix>-<state>.json; the report quotes those files.
#
# The keyboard states need the on-screen keyboard, which a simulator does not
# show by default, so this sets it first (tools/kbd/softkeyboard soft).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
PREFIX="${1:-run}"
DEVICE_KIND="${DSHPORTE_DEVICE:-phone}"

mkdir -p "$ROOT/logs/step11" "$ROOT/screenshots/step11"

source "$ROOT/scripts/device.sh"
UDID=$(device_udid)
boot_device "$UDID"

echo "== device $DEVICE_NAME ($DEVICE_KIND) $UDID"
"$ROOT/tools/kbd/softkeyboard" "$SIMCACHE" "$UDID" soft 2>&1 | grep -v Throttling

run() {
  local action="$1" tag="$2"; shift 2
  echo "--- $tag ($action)"
  python3 "$ROOT/scripts/step11-state.py" \
    --action "$action" --tag "${PREFIX}-${tag}" --timeout ${STATE_TIMEOUT:-240} "$@" \
    > "$ROOT/logs/step11/${PREFIX}-${tag}.launch.json" 2>&1
  local status=$?

  # A second screenshot taken here, from outside the app, at the moment the state
  # finished. The state script takes one too, but a screenshot is the only
  # evidence that does not depend on the app's own reporting, so it is worth
  # having two independent ones. `simctl io screenshot` from outside can catch a
  # different screen than the app's own frame, which is exactly why the pair is
  # kept.
  "$ROOT/scripts/device.sh" >/dev/null 2>&1 || true
  xcrun simctl --set "$SIMSET" io "$UDID" screenshot \
    "$ROOT/screenshots/step11/${PREFIX}-${tag}.png" >/dev/null 2>&1 || true
  python3 - "$ROOT/logs/step11/${PREFIX}-${tag}.launch.json" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception as error:
    print("   launch record unreadable:", error); raise SystemExit(0)
print(f"   done={data.get('done')} records={data.get('recordCount')} elapsed={data.get('elapsedSeconds')}s")
PY
  return $status
}

# 1. Baseline: nothing focused, keyboard down. Gives the chrome height.
run idle  01-idle

# 2. Focus: the auto-zoom question. `before-focus` vs `focus-*` vs `after-blur`
#    is the whole arc — a scale that rises and never comes back is the bug.
run focus 02-focus

# 3. Type five lines with the keyboard up.
run type  03-multiline

# 4. Send a turn with the keyboard up, so "the newest message is visible" is a
#    claim about a conversation with content in it.
run send  04-send

# 5. A long conversation: scroll to the bottom, then focus.
run long  05-long

# 6. Double-tap, for the double-tap-zoom question.
run zoom  06-doubletap

# 7. Landscape, keyboard up. The task asks for it by name, and a landscape
#    phone has only 402 pt of height, so the keyboard leaves 164 pt — the
#    tightest case the layout has to survive.
run focus 07-landscape-focus --orientation landscape

echo "== states written under logs/step11/${PREFIX}-*.json"
ls -1 "$ROOT"/logs/step11/"${PREFIX}"-*.json 2>/dev/null | sed 's/^/   /'
