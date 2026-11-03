#!/bin/bash
# Measure the iPad's DSH layout in every window state that matters, one launch
# per state, and keep both the numbers and the picture.
#
#   scripts/pad-measure.sh                 the whole plan
#   scripts/pad-measure.sh --only 01,02    some of it
#
# THE TWO VARIABLES
# -----------------
# DSH's layout store decides narrow (a 56 pt rail) or wide (an expanded sidebar)
# by comparing the frame element's measured width against SIDEBAR_AUTO_COLLAPSE =
# 1024. On the iPad that width is set by orientation and by window width, and this
# task can drive both:
#
#   orientation  `-DSHPortEPadRotate landscape|portrait` asks the scene for a new
#                interface orientation. It works once the scene is active and has
#                a key window — an early call is refused, which is why PadProbe
#                waits for the page first. Same binary for both orientations.
#
#   width        `-DSHPortEPadLayoutFraction` constrains the web view to that
#                fraction of the window, so DSH sees the narrower frame a real
#                Split View pane would give it. This is the Split View
#                STAND-IN: iPadOS is not resizing the scene, so keyboard insets,
#                safe areas and multitasking affordances stay full-screen. The
#                report says so wherever it quotes these numbers.
#
# One launch per state, because a single launch walking a plan needed the outside
# world to synchronise with a marker file and the first attempt at that recorded
# widths from two states at once (see PadProbe's note).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

ONLY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --only) ONLY="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

# shellcheck source=device.sh
. "$HERE/device.sh"

APP="$ROOT/DerivedData/Build/Products/Debug-iphonesimulator/DSHPortC.app"
[ -d "$APP" ] || { echo "no app at $APP; run scripts/build-app.sh first" >&2; exit 1; }
# ONE binary for the whole plan. Orientation comes from the app's own rotation
# call, not from a second build, so a landscape number and a portrait number are
# the same code in the same frame — which is what makes them comparable at all.
# (scripts/build-pad-landscape.sh is the fallback if a rotation is ever refused;
#  it is not used here.)

UDID="$(device_udid)"
boot_device "$UDID"

# tag  rotation  fraction  press
PLAN=(
    "01-portrait-full        portrait  -        no"
    "02-landscape-full       landscape -        yes"
    "03-landscape-two-thirds landscape 0.6667   no"
    "04-landscape-half       landscape 0.5      no"
    "05-landscape-third      landscape 0.3333   no"
    "06-portrait-half        portrait  0.5      no"
    "07-portrait-third       portrait  0.3333   no"
)

FAILED=0
for row in "${PLAN[@]}"; do
    read -r tag rotation fraction press <<< "$row"
    if [ -n "$ONLY" ] && [[ ",$ONLY," != *",${tag%%-*},"* ]]; then
        continue
    fi

    echo "== $tag ($rotation${fraction:+, fraction $fraction})"
    # One install for the whole plan now: the same binary produces both
    # orientations, so reinstalling per state would only blur what changed.
    xcrun simctl --set "$SIMSET" terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl --set "$SIMSET" uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl --set "$SIMSET" install "$UDID" "$APP" >/dev/null || { echo "  install failed" >&2; FAILED=1; continue; }

    ARGS=(--rotate "$rotation")
    [ "$fraction" != "-" ] && ARGS+=(--fraction "$fraction")
    [ "$press" = "yes" ] && ARGS+=(--press-session)
    DSHPORTE_DEVICE=ipad python3 "$HERE/pad-state.py" --tag "$tag" "${ARGS[@]}" \
        > "$ROOT/logs/step10/state-$tag.stdout" 2>&1
    status=$?
    if [ $status -ne 0 ]; then
        echo "  FAILED (see logs/step10/state-$tag.stdout)" >&2
        FAILED=1
        continue
    fi
    python3 - "$ROOT/logs/step10/state-$tag.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(f"   orientation {d['orientation']:<14} window {d['window'][0]}x{d['window'][1]}  "
      f"inner {d['innerWidth']}x{d['innerHeight']}")
print(f"   sidebar collapsed={d['sidebarCollapsed']} width={d['sidebarWidth']} "
      f"grid={d['gridTemplateColumns']} rows={d['sessionRowCount']} "
      f"overflow={d['horizontalOverflow']} clipped={d.get('clippedCount')}")
for p in (d.get("sessionRowPress") or []):
    before = p.get("before") or {}
    print(f"   row press: rows={before.get('rows')} inViewport={before.get('inViewport')} "
          f"hit={before.get('hitIsSelfOrChild')} pressed={before.get('pressed')}")
PY
done

echo
echo "== summary"
python3 - "$ROOT" <<'PY'
import json, sys
from pathlib import Path
root = Path(sys.argv[1])
rows = [json.loads(p.read_text()) for p in sorted((root / "logs/step10").glob("state-*.json"))]
if not rows:
    print("no states measured")
    sys.exit(0)
head = ("state", "orient", "window", "inner", "collapsed", "sidebar", "rows",
        "overflow", "clipped", "send", "rowPress")
print("{:<26} {:<16} {:>10} {:>11} {:>9} {:>7} {:>4} {:>8} {:>7} {:>5} {:>8}".format(*head))
for d in rows:
    send = d.get("sendButton") or {}
    presses = d.get("sessionRowPress") or []
    press = ("yes" if (presses and (presses[0].get("before") or {}).get("pressed")) else
             ("none" if presses else "-"))
    print("{:<26} {:<16} {:>10} {:>11} {:>9} {:>7} {:>4} {:>8} {:>7} {:>5} {:>8}".format(
        d["tag"], str(d["orientation"]),
        f"{d['window'][0]}x{d['window'][1]}", f"{d['innerWidth']}x{d['innerHeight']}",
        str(d["sidebarCollapsed"]), str(d["sidebarWidth"]), str(d["sessionRowCount"]),
        str(d["horizontalOverflow"]), str(d.get("clippedCount")),
        str(send.get("hitIsSelfOrChild")), press,
    ))
PY

exit $FAILED
