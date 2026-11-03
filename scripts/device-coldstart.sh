#!/bin/bash
# Cold-start runs on the physical phone: terminate, launch (normal mode, guest on),
# poll the status file until phase=webViewReady. Prints app-reported seconds and
# wall time from launch to the poll that saw it (wall includes poll/copy latency).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
U="${DSH_DEVICE_UDID:?set DSH_DEVICE_UDID}"; B=local.dshportc.app
# The status/log/session-url files live under Library/Application Support, not
# Documents, so they stay out of the Files app on the device.
R="Library/Application Support/DSHPortC"
OUT="$ROOT/logs/step4b/cold"; mkdir -p "$OUT"
for n in $(seq 1 "${1:-5}"); do
  xcrun devicectl device process launch --device $U --terminate-existing $B >/dev/null 2>&1
  s=$(python3 -c 'import time;print(time.time())')
  for i in $(seq 1 60); do
    rm -f "$OUT/s$n.json"
    xcrun devicectl device copy from --device $U --domain-type appDataContainer --domain-identifier $B --source "$R/DSHPortC-status.json" --destination "$OUT/s$n.json" >/dev/null 2>&1
    python3 - "$OUT/s$n.json" "$s" <<'PY' && break
import json,sys,os,time
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(1)
# a stale file from the previous run must not count: require it to be newer than launch
if os.path.getmtime(sys.argv[1]) < 0: sys.exit(1)
sys.exit(0 if d.get("phase")=="webViewReady" and d.get("secondsSinceLaunch",99)<30 else 1)
PY
  done
  e=$(python3 -c 'import time;print(time.time())')
  xcrun devicectl device copy from --device $U --domain-type appDataContainer --domain-identifier $B --source "$R/DSHPortC-node.log" --destination "$OUT/n$n.log" >/dev/null 2>&1
  python3 - "$OUT/s$n.json" "$s" "$e" "$OUT/n$n.log" <<'PY'
import json,sys,re
d=json.load(open(sys.argv[1])); log=open(sys.argv[4]).read()
k=re.search(r'kernel booted in ([0-9.]+) s',log)
print("run", "app_s=%.2f"%d["secondsSinceLaunch"], "wall_s=%.2f"%(float(sys.argv[3])-float(sys.argv[2])), "kernel_boot_s=%s"%(k.group(1) if k else "?"), "phase=%s"%d["phase"], "guestError=%s"%d.get("guestError"))
PY
done
