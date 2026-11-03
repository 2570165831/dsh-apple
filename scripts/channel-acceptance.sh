#!/bin/bash
# Run the step-3 / step-4 acceptance inside the app and print what it recorded.
#
#   scripts/channel-acceptance.sh                 the full run
#   scripts/channel-acceptance.sh --keep-data     reuse the container (keeps the rootfs)
#
# Why the app and not the host: the criteria are about the embedded Node talking
# to the embedded Swift over the loopback channel. A host process would be a
# fourth process and would prove nothing about the runtime that ships. So the app
# is launched with DSHPORTE_GUEST_CHANNEL=1 (boot the guest, bind the workspace,
# start the channel) and DSHPORTE_CHANNEL_ACCEPTANCE=1 (run sim/channel-
# acceptance.mjs instead of DSH), and it writes its verdict into the container.
#
# The one thing this script itself must prove is criterion 3 (port retry), which
# needs a port to be occupied from OUTSIDE the app before it starts. That is done
# here, with a listener the app cannot see.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# shellcheck source=device.sh
. "$HERE/device.sh"

KEEP_DATA=0
for arg in "$@"; do
    [ "$arg" = "--keep-data" ] && KEEP_DATA=1
done

mkdir -p "$ROOT/logs"
REPORT_OUT="$ROOT/logs/channel-acceptance.json"
CONSOLE_OUT="$ROOT/logs/channel-acceptance-console.log"

# --------------------------------------------------------------- port retry
# Criterion 3: when the preferred port is taken, the app must come up on another
# one. Two things are needed: something must occupy the port, and the app must be
# told to want it. Both happen here.
#
# The occupant is a Python listener on a port picked from the ephemeral range.
# Using a fixed, well-known port would collide with whatever else this machine is
# running; picking one and holding it is the honest way to create the condition.
PREFERRED_PORT=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)
echo "== occupying 127.0.0.1:$PREFERRED_PORT before launch (port-retry criterion)"
python3 - "$PREFERRED_PORT" <<'PY' &
import socket, sys, time
port = int(sys.argv[1])
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
s.listen(8)
# Hold it until the app has had time to try and fail over.
time.sleep(240)
PY
OCCUPIER_PID=$!
trap 'kill $OCCUPIER_PID 2>/dev/null || true' EXIT
# Make sure the occupier is actually listening before the app starts, otherwise
# the app might win the race and the criterion would pass for the wrong reason.
for _ in $(seq 1 50); do
    if lsof -nP -iTCP:"$PREFERRED_PORT" -sTCP:LISTEN >/dev/null 2>&1; then break; fi
    sleep 0.1
done
if ! lsof -nP -iTCP:"$PREFERRED_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "error: could not occupy port $PREFERRED_PORT; the retry criterion cannot be tested" >&2
    exit 1
fi

UDID="$(device_udid)"
boot_device "$UDID"

xcrun simctl --set "$SIMSET" terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
if [ "$KEEP_DATA" = 0 ]; then
    xcrun simctl --set "$SIMSET" uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl --set "$SIMSET" install "$UDID" "$APP_PATH" >/dev/null
fi

echo "== launching the acceptance run"
rm -f "$CONSOLE_OUT"

# The acceptance module and the channel client ship INSIDE the app bundle
# ($APP_PATH/sim/), not read from this checkout at run time. Editing sim/*.mjs
# and re-running this script without rebuilding therefore re-runs the OLD code
# and prints a verdict that looks current. Measured once: a run after adding two
# criteria reported the old ten, with no error. Compare the bundle's copy
# against the checkout and refuse to run when they differ.
if [ -d "$APP_PATH/sim" ]; then
    for f in sim/channel-acceptance.mjs sim/guest-channel-client.mjs; do
        if ! cmp -s "$ROOT/$f" "$APP_PATH/sim/$(basename "$f")"; then
            echo "error: $APP_PATH/sim/$(basename "$f") is stale relative to $f." >&2
            echo "       Rebuild with scripts/build-app.sh before measuring, or the" >&2
            echo "       run below would exercise the previous code and still pass." >&2
            exit 1
        fi
    done
    echo "== app bundle matches sim/ sources"
fi

LAUNCH_START=$(python3 -c 'import time; print(time.time())')
SIMCTL_CHILD_DSHPORTE_GUEST_CHANNEL=1 \
SIMCTL_CHILD_DSHPORTE_CHANNEL_ACCEPTANCE=1 \
SIMCTL_CHILD_DSH_GUEST_CHANNEL_PREFERRED_PORT="$PREFERRED_PORT" \
    xcrun simctl --set "$SIMSET" launch "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true

# Poll for the report. The acceptance writes it incrementally, so wait for the
# `acceptance` key rather than for the file to appear.
#
# The status/log/session-url files live under Library/Application Support, not
# Documents, so they stay out of the Files app. The acceptance report itself is a
# probe file and stays in Documents.
CONTAINER=""
RUNTIME=""
TRIES=0
while [ $TRIES -lt 420 ]; do
    CONTAINER=$(app_container_data "$UDID" 2>/dev/null || true)
    if [ -n "$CONTAINER" ]; then
        RUNTIME="$CONTAINER/Library/Application Support/DSHPortC"
        CANDIDATE="$CONTAINER/Documents/DSHPortE-channel-acceptance.json"
        if [ -f "$CANDIDATE" ] && grep -q '"acceptance"' "$CANDIDATE" 2>/dev/null; then
            python3 - "$CANDIDATE" "$REPORT_OUT" "$LAUNCH_START" <<'PY'
import json, sys, time
src, dst, launch_start = sys.argv[1], sys.argv[2], float(sys.argv[3])
data = json.load(open(src))
data["launchToReportSeconds"] = time.time() - launch_start
json.dump(data, open(dst, "w"), indent=2, sort_keys=True)
print(json.dumps(data.get("acceptance", {}), indent=2, sort_keys=True))
PY
            echo "== report: $REPORT_OUT"
            echo "== device log: $RUNTIME/DSHPortC-node.log"
            # Keep a copy of the app's own log beside the report: criterion 2c
            # (token not logged) is checked in-run, but the copy is what a reader
            # can grep independently.
            cp "$RUNTIME/DSHPortC-node.log" "$CONSOLE_OUT" 2>/dev/null || true
            exit 0
        fi
    fi
    sleep 1
    TRIES=$((TRIES + 1))
done

echo "timed out waiting for the acceptance report" >&2
if [ -n "$CONTAINER" ]; then
    RUNTIME="$CONTAINER/Library/Application Support/DSHPortC"
    CANDIDATE="$CONTAINER/Documents/DSHPortE-channel-acceptance.json"
    [ -f "$CANDIDATE" ] && cat "$CANDIDATE" >&2
    [ -f "$RUNTIME/DSHPortC-node.log" ] && tail -60 "$RUNTIME/DSHPortC-node.log" >&2
fi
exit 1
