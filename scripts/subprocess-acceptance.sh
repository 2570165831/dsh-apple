#!/bin/bash
# Run the step-5 acceptance (the `ctx.subprocess` provider) inside the app.
#
#   scripts/subprocess-acceptance.sh              the full run
#   scripts/subprocess-acceptance.sh --keep-data  reuse the container
#
# WHY THE APP AND NOT THE HOST. Every criterion is about the provider the model's
# `bash` tool calls, running in this process: jitless V8, no WebAssembly, the
# fetch polyfill, the preload's child_process block, and the guest channel this
# Swift host publishes into the environment. A host Node process would be a
# fourth process and would prove nothing about the runtime that ships.
#
# The module is `sim/subprocess-acceptance.mjs`, which mounts the profile through
# `dsh-app-boot`'s own `boot()` and drives `ctx.subprocess` the way
# `dsh-bash-local` does. Launching with `DSHPORTE_SUBPROCESS_ACCEPTANCE=1` makes
# `sim/ios-app-entry.mjs` run it INSTEAD of DSH.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# shellcheck source=device.sh
. "$HERE/device.sh"

KEEP_DATA=0
for arg in "$@"; do
    [ "$arg" = "--keep-data" ] && KEEP_DATA=1
done

mkdir -p "$ROOT/logs/step5"
REPORT_OUT="$ROOT/logs/step5/subprocess-acceptance.json"
CONSOLE_OUT="$ROOT/logs/step5/subprocess-acceptance-console.log"

UDID="$(device_udid)"
boot_device "$UDID"

xcrun simctl --set "$SIMSET" terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
if [ "$KEEP_DATA" = 0 ]; then
    # A fresh container: a previous run's rootfs import and guest state must not
    # be able to make this one look faster or cleaner than it is.
    xcrun simctl --set "$SIMSET" uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl --set "$SIMSET" install "$UDID" "$APP_PATH" >/dev/null
fi

# The acceptance module ships INSIDE the app bundle ($APP_PATH/sim/). Editing
# sim/*.mjs and re-running this script without rebuilding would re-run the OLD
# code and print a verdict that looks current — a trap REPORT-2 §10 records being
# hit once, with the report still claiming success. Compare and refuse.
if [ -d "$APP_PATH/sim" ]; then
    for f in sim/subprocess-acceptance.mjs sim/ios-app-entry.mjs; do
        if ! cmp -s "$ROOT/$f" "$APP_PATH/sim/$(basename "$f")"; then
            echo "error: $APP_PATH/sim/$(basename "$f") is stale relative to $f." >&2
            echo "       Rebuild with scripts/build-app.sh before measuring." >&2
            exit 1
        fi
    done
    echo "== app bundle matches sim/ sources"
fi

echo "== launching the step-5 acceptance run"
rm -f "$CONSOLE_OUT"

# `ONLY=exit_codes,streaming` narrows the run to named criteria. Diagnostic
# only; a report produced that way does not satisfy the whole acceptance, so the
# full run is what the report quotes.
#
# An empty `SIMCTL_CHILD_*` value arrives in the app as an EMPTY STRING rather
# than as unset. Passing it unconditionally therefore made the module see
# `DSHPORTE_ACCEPTANCE_ONLY=""`, treat that as a filter, match nothing, and
# report 0/0 — a run that looks like it did nothing, which is exactly what it
# did. So the variable is only exported when the caller actually set it.
ONLY_ENV=()
if [ -n "${ONLY:-}" ]; then
    ONLY_ENV=(SIMCTL_CHILD_DSHPORTE_ACCEPTANCE_ONLY="$ONLY")
fi

SIMCTL_CHILD_DSHPORTE_GUEST_CHANNEL=1 \
SIMCTL_CHILD_DSHPORTE_SUBPROCESS_ACCEPTANCE=1 \
"${ONLY_ENV[@]+"${ONLY_ENV[@]}"}" \
    xcrun simctl --set "$SIMSET" launch "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true

# The run writes its verdict incrementally; wait for the `summary` key rather
# than for the file to appear, so a partial report is never mistaken for a
# finished one.
#
# The status/log/session-url files live under Library/Application Support, not
# Documents, so they stay out of the Files app. The acceptance report itself is a
# probe file and stays in Documents.
CONTAINER=""
RUNTIME=""
TRIES=0
while [ $TRIES -lt 600 ]; do
    CONTAINER=$(app_container_data "$UDID" 2>/dev/null || true)
    if [ -n "$CONTAINER" ]; then
        RUNTIME="$CONTAINER/Library/Application Support/DSHPortC"
        CANDIDATE="$CONTAINER/Documents/DSHPortE-subprocess-acceptance.json"
        if [ -f "$CANDIDATE" ] && grep -q '"summary"' "$CANDIDATE" 2>/dev/null; then
            cp "$CANDIDATE" "$REPORT_OUT"
            cp "$RUNTIME/DSHPortC-node.log" "$CONSOLE_OUT" 2>/dev/null || true
            python3 - "$REPORT_OUT" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
summary = data.get("summary", {})
print(json.dumps(summary, indent=2, sort_keys=True))
passed = sum(1 for value in summary.values() if value is True)
print(f"\n== {passed}/{len(summary)} criteria passed")
sys.exit(0 if passed == len(summary) else 1)
PY
            echo "== report: $REPORT_OUT"
            echo "== device log: $CONSOLE_OUT"
            exit 0
        fi
    fi
    sleep 1
    TRIES=$((TRIES + 1))
done

echo "timed out waiting for the acceptance report" >&2
if [ -n "$CONTAINER" ]; then
    RUNTIME="$CONTAINER/Library/Application Support/DSHPortC"
    CANDIDATE="$CONTAINER/Documents/DSHPortE-subprocess-acceptance.json"
    [ -f "$CANDIDATE" ] && cat "$CANDIDATE" >&2
    [ -f "$RUNTIME/DSHPortC-node.log" ] && tail -60 "$RUNTIME/DSHPortC-node.log" >&2
fi
exit 1
