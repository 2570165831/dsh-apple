#!/bin/bash
# Run the end-to-end acceptance sequence for DSHPortC and keep every raw log.
#
# Sequence:
#   1. mock model server on the host (loopback only)
#   2. build + install the app into the task's simulator device
#   3. three cold starts, timed to the moment DSH prints its URL
#   4. memory sampling while idle, then while a streamed reply runs
#   5. XCUITest: UI loads, streaming reply grows, file tools round-trip
#   6. app bundle size
#
# Every step writes its raw output under logs/. Nothing here paraphrases output;
# the report quotes these files.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$ROOT"

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
MAIN_LOG="$ROOT/logs/e2e-run-$STAMP.log"
exec > >(tee -a "$MAIN_LOG") 2>&1

echo "=============================================================="
echo " ios-port-E end-to-end run"
echo " started $(date -u +%FT%TZ)"
echo " host $(sw_vers -productName) $(sw_vers -productVersion) $(uname -m)"
echo " xcode $(xcodebuild -version | tr '\n' ' ')"
echo "=============================================================="

step() { echo; echo "--- $* ---"; }

# ----------------------------------------------------------------- 1. mock
step "1. mock model server"
if ! curl -sf -m 3 "http://127.0.0.1:${MOCK_PORT:-19700}/healthz" >/dev/null; then
  scripts/mock-start.sh start || { echo "mock failed to start"; exit 1; }
  sleep 1
fi
curl -s "http://127.0.0.1:${MOCK_PORT:-19700}/healthz" | tee "logs/e2e-mock-health.json"
echo

# ------------------------------------------------------- 2. build + install
step "2. build and install"
scripts/build-app.sh || { echo "build failed"; exit 1; }

source scripts/device.sh
UDID=$(device_udid)
echo "device $UDID"
boot_device "$UDID"
xcrun simctl --set "$SIMSET" install "$UDID" "$APP_PATH" || { echo "install failed"; exit 1; }
echo "installed $APP_PATH"

# -------------------------------------------------------- 3. cold starts
step "3. cold starts (launch -> DSH prints its URL)"
: > logs/coldstart-times.txt
for run in 1 2 3; do
  python3 scripts/e2e.py coldstart 1 2>&1 | tee "logs/e2e-coldstart-$run.log" | grep -E '^run|^\{'
  sleep 2
done
grep -h '^run ' logs/e2e-coldstart-*.log | tee logs/coldstart-times.txt

# ------------------------------------------------------------ 4. memory
step "4. memory (idle, then under a streamed reply)"
python3 scripts/e2e.py verify 2>&1 | tee logs/e2e-verify.log | grep -E 'url ready|GET |app pid|node|v8|webassembly|jitless'
PID=$(ps -axo pid,comm | awk '/DSHPortC\.app\/DSHPortC$/{print $1; exit}')
echo "app pid $PID"
scripts/sample-memory.sh idle 30 | tee logs/e2e-memory-idle.txt

# Drive a streamed reply through the HTTP surface to measure the busy case.
URL=$(python3 scripts/e2e.py status | python3 -c 'import json,sys; print(json.load(sys.stdin).get("webURL",""))')
echo "web url (redacted) $URL"
scripts/sample-memory.sh chat 25 | tee logs/e2e-memory-chat.txt

# ------------------------------------------------------------- 5. XCUITest
step "5. XCUITest against the real app"
xcrun simctl --set "$SIMSET" list devices | grep "$UDID" || true
xcodebuild test \
  -project "$ROOT/app/DSHPortC.xcodeproj" \
  -scheme DSHPortC \
  -configuration Debug \
  -sdk iphonesimulator \
  -derivedDataPath "$ROOT/DerivedData" \
  -destination "platform=iOS Simulator,id=$UDID" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  2>&1 | tee logs/e2e-xcuitest.log | grep -E 'Test Case|error:|TEST (SUCCEEDED|FAILED)|STREAM_' || true

# --------------------------------------------------------- 6. bundle size
step "6. app bundle size"
APP="$ROOT/DerivedData/Build/Products/Debug-iphonesimulator/DSHPortC.app"
du -sh "$APP" | tee logs/e2e-app-size.txt
python3 "$ROOT/work/measure-tree.py" "$APP" 2>/dev/null | tee logs/e2e-app-size.json >/dev/null
python3 -c "
import json,sys
d=json.load(open('$ROOT/logs/e2e-app-size.json'))
print('logical bytes', d['bytes'], '=', d['bytes_human'])
print('allocated bytes', d['allocated_bytes'])
print('files', d['files'])
" | tee -a logs/e2e-app-size.txt

# ---------------------------------------------------------------- cleanup
step "cleanup"
xcrun simctl --set "$SIMSET" terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
echo "kept the device $UDID for re-runs; shut down at the end of the task"
echo
echo "finished $(date -u +%FT%TZ)"
echo "main log: $MAIN_LOG"
