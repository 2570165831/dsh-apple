#!/bin/bash
# Background test on the phone (step 4B item 7). App runs with the guest on and
# a 2 s heartbeat (DSHPORTE_PROBE_MODE=bg). A system app (Settings) is launched
# over it, we wait, then bring the app back and read the heartbeat file.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
U="${DSH_DEVICE_UDID:?set DSH_DEVICE_UDID}"; B=local.dshportc.app
# The status/log/session-url files live under Library/Application Support, not
# Documents, so they stay out of the Files app on the device.
R="Library/Application Support/DSHPortC"
OUT="$ROOT/logs/step4b/bg"; mkdir -p "$OUT"
cp_from() { xcrun devicectl device copy from --device $U --domain-type appDataContainer --domain-identifier $B --source "Documents/$1" --destination "$OUT/$2" >/dev/null 2>&1; }
cp_runtime() { xcrun devicectl device copy from --device $U --domain-type appDataContainer --domain-identifier $B --source "$R/$1" --destination "$OUT/$2" >/dev/null 2>&1; }
xcrun devicectl device process launch --device $U --terminate-existing \
  --environment-variables '{"DSHPORTE_PROBE":"1","DSHPORTE_PROBE_MODE":"bg"}' $B > "$OUT/launch.log" 2>&1
sleep 20
for w in 30 120 300; do
  date -u +%FT%TZ > "$OUT/w$w.away_at"
  xcrun devicectl device process launch --device $U com.apple.Preferences > "$OUT/w$w.settings.log" 2>&1
  sleep $w
  date -u +%FT%TZ > "$OUT/w$w.back_at"
  xcrun devicectl device process launch --device $U $B > "$OUT/w$w.back.log" 2>&1
  sleep 8
  rm -f "$OUT/w$w.probe.json" "$OUT/w$w.node.log"
  cp_from DSHPortE-probe.json w$w.probe.json; cp_runtime DSHPortC-node.log w$w.node.log
  xcrun devicectl device info processes --device $U 2>/dev/null | grep -iE "DSHPortC|Preferences" > "$OUT/w$w.procs.txt"
  echo "== w$w done"
done
