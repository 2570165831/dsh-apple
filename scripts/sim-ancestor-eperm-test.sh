#!/bin/bash
# Reproduce "EPERM: open '/var/mobile/Containers/Data/Application'" on the simulator and
# prove the preload fix. Needs the mock (scripts/mock-start.sh start) and a build.
#   case 1  fault ON,  fix OFF  -> image prompt REJECTED with EPERM   (the phone's failure)
#   case 2  fault ON,  fix ON   -> accepted, turn completes
#   case 3  fault OFF, fix ON   -> accepted (no regression)
# The simulator keeps the FIRST SIMCTL_CHILD_* values it sees until it is shut down,
# so every case shuts it down first.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
printf 'IMAGETEST describe the attached picture\n' > /tmp/anc-prompt.txt
rc=0
for spec in "anc-fault-nofix 1 0 REJECTED" "anc-fault-fix 1 1 accepted" "anc-nofault-fix 0 1 accepted"; do
  set -- $spec
  xcrun simctl --set simdevices shutdown all; sleep 3
  env SIMCTL_CHILD_IOS_SIM_FAULT_ANCESTOR_OPEN=$2 SIMCTL_CHILD_IOS_SIM_ANCESTOR_SHIM=$3 TURN_TIMEOUT=100 \
    python3 scripts/image-acceptance.py run --name $1 --prompt-file /tmp/anc-prompt.txt --keyword IMAGETEST \
    --attachments photo.heic --stage photo.heic > "logs/$1.out" 2>&1
  if python3 - "$1" "$4" <<'PY'
import json,sys
d=json.load(open(f'logs/step5/{sys.argv[1]}.json'))
lines=[l for l in d['nodeLog'].splitlines() if 'diag-prompt: ' in l and 'installed' not in l]
sys.exit(0 if any(sys.argv[2] in l for l in lines) else 1)
PY
  then echo "PASS $1 (expected $4)"; else echo "FAIL $1 (expected $4)"; rc=1; fi
done
exit $rc
