#!/bin/bash
# Run the directory_picker acceptance criterion on the phone (no install).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
U="${DSH_DEVICE_UDID:?set DSH_DEVICE_UDID}"; B=local.dshportc.app; O="$ROOT/logs/step4b/${1:-picker}"; mkdir -p "$O"
T0=$(date -u +%Y-%m-%dT%H:%M:%SZ)
xcrun devicectl device process launch --device $U --terminate-existing --environment-variables '{"DSHPORTE_GUEST_CHANNEL":"1","DSHPORTE_SUBPROCESS_ACCEPTANCE":"1","DSHPORTE_ACCEPTANCE_ONLY":"directory_picker"}' $B >/dev/null 2>&1
for i in $(seq 1 25); do sleep 4; rm -f $O/acc.json; xcrun devicectl device copy from --device $U --domain-type appDataContainer --domain-identifier $B --source Documents/DSHPortE-subprocess-acceptance.json --destination $O/acc.json >/dev/null 2>&1; python3 -c "import json,sys;d=json.load(open('$O/acc.json'));sys.exit(0 if 'summary' in d and d.get('startedAt','')>='$T0' else 1)" 2>/dev/null && break; done
python3 - "$O/acc.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))['criteria']['directory_picker']
for k,v in d.items(): print(k,str(v)[:400])
PY
