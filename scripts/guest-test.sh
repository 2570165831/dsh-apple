#!/bin/bash
# Run one guest acceptance step in the simulator and print what the app recorded.
#
#   scripts/guest-test.sh uname        uname -m, exit code
#   scripts/guest-test.sh cptest       cp over an existing file, cp -a a directory
#   scripts/guest-test.sh die          deliberate kernel die(), app must survive
#   scripts/guest-test.sh firstCommand time from launch to the first command
#   scripts/guest-test.sh boot N       run boot N times (kernel boot timing)
#
# Each step is a fresh launch with a fresh container unless --keep-data is
# passed, so numbers are not contaminated by earlier work. The app writes its
# JSON report into its container; this script reads it back and also keeps a
# copy under logs/ so the evidence survives an uninstall.
#
# The app is launched with -DSHPortEGuestTest 1, which is the only thing that
# makes it run any of this.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
STEP="${1:-uname}"
REPEAT="${2:-1}"
KEEP_DATA=0
for arg in "$@"; do
    [ "$arg" = "--keep-data" ] && KEEP_DATA=1
done

# shellcheck source=device.sh
. "$HERE/device.sh"

mkdir -p "$ROOT/logs"
UDID="$(device_udid)"
boot_device "$UDID"

run_once() {
    local step="$1"
    # Keep each run's evidence instead of overwriting the previous one. Step 1's
    # numbers are quoted in REPORT-1.md, so silently replacing logs/guest-uname.json
    # would make that report unreproducible from the repository. Old runs move
    # aside to guest-<step>-previous*.json.
    local out="$ROOT/logs/guest-$step.json"
    local log="$ROOT/logs/guest-$step-console.log"
    if [ -f "$out" ]; then
        local n=1
        while [ -f "$ROOT/logs/guest-$step-previous$n.json" ]; do n=$((n + 1)); done
        mv "$out" "$ROOT/logs/guest-$step-previous$n.json"
    fi
    if [ -f "$log" ]; then
        local m=1
        while [ -f "$ROOT/logs/guest-$step-console-previous$m.log" ]; do m=$((m + 1)); done
        mv "$log" "$ROOT/logs/guest-$step-console-previous$m.log"
    fi

    xcrun simctl --set "$SIMSET" terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    if [ "$KEEP_DATA" = 0 ]; then
        # Uninstall/reinstall so the rootfs import time is measured from a cold
        # container when that is the step, and so a previous step's guest state
        # cannot leak into this one.
        xcrun simctl --set "$SIMSET" uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
        xcrun simctl --set "$SIMSET" install "$UDID" "$APP_PATH" >/dev/null
    fi

    local launch_start
    launch_start=$(python3 -c 'import time;print(time.time())')
    # simctl has no --env flag: environment variables reach the child through
    # SIMCTL_CHILD_ in the caller's environment.
    #
    # Deliberately no --stdout/--stderr: on this Xcode, passing either of them
    # makes simctl return "Application launch ... did not return a process handle
    # nor launch error" and the app never starts. The app writes its own report
    # into its container, which is a better channel anyway — it survives the
    # launch and can be read at leisure.
    SIMCTL_CHILD_DSHPORTE_GUEST_STEP="$step" \
        xcrun simctl --set "$SIMSET" launch "$UDID" "$BUNDLE_ID" \
        -DSHPortEGuestTest 1 >/dev/null 2>&1 || true

    # Poll for the report to finish. The app writes it incrementally, so wait for
    # finishedAt rather than for the file to appear.
    local container="" tries=0 report=""
    while [ $tries -lt 180 ]; do
        # Re-resolve every time: the container UUID is new after a reinstall.
        container=$(app_container_data "$UDID" 2>/dev/null || true)
        report="$container/Documents/DSHPortE-guest-test.json"
        if [ -n "$container" ] && [ -f "$report" ]; then
            if grep -q '"finishedAt"' "$report" 2>/dev/null; then
                python3 - "$report" "$out" "$launch_start" <<'PY'
import json, sys
src, dst, launch_start = sys.argv[1], sys.argv[2], float(sys.argv[3])
import time
data = json.load(open(src))
data["launchToReportSeconds"] = time.time() - launch_start
json.dump(data, open(dst, "w"), indent=2, sort_keys=True)
print(json.dumps(data, indent=2, sort_keys=True))
PY
                return 0
            fi
        fi
        sleep 1
        tries=$((tries + 1))
    done

    echo "timed out waiting for $step; last report:" >&2
    if [ -n "$container" ] && [ -f "$report" ]; then
        cat "$report" >&2
    fi
    tail -30 "$log" >&2 2>/dev/null || true
    return 1
}

case "$STEP" in
    boot)
        # Boot timing needs repeated runs; each reports its own bootSeconds.
        for i in $(seq 1 "$REPEAT"); do
            echo "=== boot run $i"
            run_once "uname" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps({"bootSeconds": d.get("bootSeconds"), "reported": d.get("guestReportedBootSeconds"), "import": d.get("rootfsImportSeconds")}))'
        done
        ;;
    *)
        run_once "$STEP"
        ;;
esac
