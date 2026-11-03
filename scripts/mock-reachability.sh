#!/bin/bash
# Prove that the mock server, bound to 127.0.0.1 on the Mac host, is reachable
# from a process running INSIDE the iOS Simulator — and that the SSE stream
# arrives there incrementally, not as one buffered blob.
#
# Why this is its own script: the mock server lives on the host, the app that
# will call it lives in the simulator, and the two only meet because the
# simulator shares the host's network stack. That is a platform fact the test
# depends on, so it is measured instead of assumed.
#
# The probe (mock/reachability/probe.swift) is a small Swift program built for
# the simulator and launched with `simctl spawn`. Using spawn keeps the check
# independent of the app build: if this fails, the app cannot possibly work, and
# if this passes, a failure in the app is the app's problem, not the network's.
#
# Usage: scripts/mock-reachability.sh [output-json]
#   output-json defaults to logs/mock-reachability-simulator.json
#
# Environment
#   MOCK_PORT   default 19700
#   SIM_SET     default <repo>/simdevices
#   SIM_UDID    pin a device; otherwise one is created in SIM_SET and removed at exit.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
NODE_BIN="${NODE_BIN:-/opt/homebrew/bin/node}"
MOCK_PORT="${MOCK_PORT:-19700}"
OUT="${1:-$REPO_ROOT/logs/mock-reachability-simulator.json}"
LOG_DIR="$REPO_ROOT/logs"
SIM_SET="${SIM_SET:-$REPO_ROOT/simdevices}"
PROBE_DIR="$REPO_ROOT/mock/reachability"
PROBE_BIN="$PROBE_DIR/mockreprobe"
LOG="$LOG_DIR/mock-reachability.log"

mkdir -p "$LOG_DIR"
: >"$LOG"
exec > >(tee -a "$LOG") 2>&1

say() { printf '\n=== %s ===\n' "$*"; }
run() { printf '\n$ %s\n' "$*"; "$@"; echo "[exit $?]"; }

printf 'mock reachability from inside the iOS Simulator\n'
printf 'date        : %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
printf 'host        : %s %s\n' "$(uname -s)" "$(uname -m)"
printf 'mock        : 127.0.0.1:%s\n' "$MOCK_PORT"
printf 'device set  : %s\n' "$SIM_SET"
printf 'output      : %s\n' "$OUT"

say '1. the mock must already be running on the host'
if ! curl -fsS -m 3 "http://127.0.0.1:$MOCK_PORT/healthz" >/dev/null 2>&1; then
  echo "no mock on 127.0.0.1:$MOCK_PORT; starting one for this check"
  MOCK_PORT="$MOCK_PORT" MOCK_LOG_DIR="$LOG_DIR" \
    nohup "$NODE_BIN" "$REPO_ROOT/mock/server.mjs" >>"$LOG_DIR/mock-server.log" 2>&1 &
  STARTED_PID=$!
  for _ in $(seq 1 50); do
    curl -fsS -m 2 "http://127.0.0.1:$MOCK_PORT/healthz" >/dev/null 2>&1 && break
    sleep 0.1
  done
  trap 'kill "$STARTED_PID" 2>/dev/null' EXIT
fi
run curl -sS "http://127.0.0.1:$MOCK_PORT/healthz"

say '2. build the probe for the simulator'
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
echo "SDK: $SDK"
run xcrun swiftc -sdk "$SDK" -target arm64-apple-ios18.0-simulator \
  "$PROBE_DIR/probe.swift" -o "$PROBE_BIN"
if [ ! -x "$PROBE_BIN" ]; then
  echo 'probe did not build; cannot continue' >&2
  exit 1
fi
file "$PROBE_BIN"

say '3. pick or create a simulator device in the task device set'
if [ -n "${SIM_UDID:-}" ]; then
  UDID="$SIM_UDID"
  echo "using pinned device $UDID"
  CLEANUP_DEVICE=0
else
  UDID="$(xcrun simctl --set "$SIM_SET" list devices 2>/dev/null \
    | awk -F '[()]' '/dsh-portC-mockprobe/ {print $2; exit}')"
  if [ -n "$UDID" ]; then
    echo "reusing existing probe device $UDID"
    CLEANUP_DEVICE=0
  else
    UDID="$(xcrun simctl --set "$SIM_SET" create dsh-portC-mockprobe \
      com.apple.CoreSimulator.SimDeviceType.iPhone-17 com.apple.CoreSimulator.SimRuntime.iOS-27-0)"
    echo "created probe device $UDID"
    # This device exists only for this check, so remove it on the way out.
    CLEANUP_DEVICE=1
  fi
fi
echo "UDID: $UDID"

cleanup_device() {
  if [ "${CLEANUP_DEVICE:-0}" = "1" ]; then
    xcrun simctl --set "$SIM_SET" shutdown "$UDID" >/dev/null 2>&1 || true
    xcrun simctl --set "$SIM_SET" delete "$UDID" >/dev/null 2>&1 || true
    echo "deleted probe device $UDID"
  else
    echo "left device $UDID in place (not created by this script)"
  fi
}
trap cleanup_device EXIT

say '4. boot it'
STATE="$(xcrun simctl --set "$SIM_SET" list devices | awk -v u="$UDID" '$0 ~ u {print $3}')"
if [ "$STATE" != "Booted" ]; then
  run xcrun simctl --set "$SIM_SET" boot "$UDID"
  run xcrun simctl --set "$SIM_SET" bootstatus "$UDID" -b
else
  echo 'already booted'
fi
xcrun simctl --set "$SIM_SET" list devices | grep -- "$UDID" || true

say '5. run the probe INSIDE the simulator, pointed at the host loopback'
echo 'PROBE_URL=http://127.0.0.1:'"$MOCK_PORT"'/v1/chat/completions'
echo '(127.0.0.1 here is the host loopback because the simulator shares the host network stack)'
PROBE_URL="http://127.0.0.1:$MOCK_PORT/v1/chat/completions" \
  xcrun simctl --set "$SIM_SET" spawn "$UDID" "$PROBE_BIN" >"$OUT" 2>"$LOG_DIR/mock-reachability-simulator.err"
PROBE_EXIT=$?
echo "[probe exit $PROBE_EXIT]"
if [ -s "$LOG_DIR/mock-reachability-simulator.err" ]; then
  echo '--- stderr ---'; cat "$LOG_DIR/mock-reachability-simulator.err"
fi

say '6. what the probe observed'
"$NODE_BIN" -e '
const fs = require("node:fs");
const result = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
console.log(`ok                 : ${result.ok}`);
console.log(`url                : ${result.url}`);
console.log(`HTTP status        : ${result.status}`);
console.log(`delegate data callbacks : ${result.delegateBatchCount}`);
console.log(`content delta events    : ${result.contentEventCount}`);
console.log(`total bytes        : ${result.totalBytes}`);
console.log(`elapsed            : ${result.elapsedMs}ms`);
console.log(`inter-event gap    : min ${result.minGapMs}ms, max ${result.maxGapMs}ms`);
if (result.error) console.log(`error              : ${result.error}`);
console.log("text reassembled   : " + JSON.stringify(result.text));
console.log("");
console.log("arrival timeline (one line per URLSession delegate callback):");
for (const batch of result.batches) {
  const marker = batch.bytes <= 20 ? "  <- [DONE]" : "";
  console.log(`  batch ${String(batch.ordinal).padStart(2)}  +${String(batch.arrivalMs).padStart(4)}ms  ${String(batch.bytes).padStart(4)}B  events so far ${batch.completedEvents}${marker}`);
}
const arrivals = result.batches.map((b) => b.arrivalMs);
const gaps = arrivals.slice(1).map((value, index) => value - arrivals[index]).filter((gap) => gap > 0);
if (gaps.length > 0) {
  console.log(`\ngaps between callbacks (ms): ${gaps.join(", ")}`);
}
' "$OUT"

say '7. verdict'
"$NODE_BIN" -e '
const fs = require("node:fs");
const result = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const checks = [
  ["the simulator reached the host loopback", result.status === 200],
  ["no transport error", !result.error],
  ["the reply arrived in multiple callbacks, not one blob", result.delegateBatchCount >= 6],
  ["at least 6 content delta events parsed", result.contentEventCount >= 6],
  ["callbacks were spaced over time (>=50ms apart)", result.minGapMs >= 50],
  ["the streamed text reassembled completely", (result.text || "").includes("STREAMTEST-COMPLETE")],
];
for (const [label, ok] of checks) console.log(`${label.padEnd(52)}: ${ok ? "PASS" : "FAIL"}`);
const allOk = checks.every(([, ok]) => ok);
console.log(allOk ? "VERDICT: PASS" : "VERDICT: FAIL");
process.exitCode = allOk ? 0 : 1;
' "$OUT"
VERDICT=$?
echo "[verdict exit $VERDICT]"

say 'done'
echo "result json: $OUT"
echo "log        : $LOG"
exit "$VERDICT"
