#!/bin/bash
# One memory/timing probe run on the physical phone (step 4B). Does not install.
#   scripts/device-probe.sh <label>
# Launches with -DSHPortEProbe 1 and the guest OFF at launch, waits for the
# probe to finish, copies Documents/DSHPortE-probe.json and the status file.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
U="${DSH_DEVICE_UDID:?set DSH_DEVICE_UDID}"; B=local.dshportc.app
# The status/log/session-url files live under Library/Application Support, not
# Documents, so they stay out of the Files app on the device.
R="Library/Application Support/DSHPortC"
OUT="$ROOT/logs/step4b/$1"; mkdir -p "$OUT"
cp_from() { xcrun devicectl device copy from --device $U --domain-type appDataContainer --domain-identifier $B --source "Documents/$1" --destination "$OUT/$2" >/dev/null 2>&1; }
cp_runtime() { xcrun devicectl device copy from --device $U --domain-type appDataContainer --domain-identifier $B --source "$R/$1" --destination "$OUT/$2" >/dev/null 2>&1; }
T0=$(date -u +%Y-%m-%dT%H:%M:%SZ)
xcrun devicectl device process launch --device $U --terminate-existing \
  --environment-variables '{"DSHPORTE_PROBE":"1","DSHPORTE_GUEST_CHANNEL":"0","DSHPORTE_PROBE_MODE":"mem"}' \
  $B > "$OUT/launch.log" 2>&1
for i in $(seq 1 60); do
  sleep 3
  rm -f "$OUT/probe.json"; cp_from DSHPortE-probe.json probe.json
  python3 - "$OUT/probe.json" "$T0" <<'PY' && break
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(1)
ok = d.get("startedAt","") >= sys.argv[2] and ("finishedAt" in d or d.get("boot_error") is not None)
sys.exit(0 if ok else 1)
PY
done
cp_runtime DSHPortC-status.json status.json; cp_runtime DSHPortC-node.log node.log
sed -i '' -E 's/token=[A-Za-z0-9_-]+/token=<redacted>/g' "$OUT/node.log" 2>/dev/null
echo done "$1"
