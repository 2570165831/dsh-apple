#!/bin/bash
# A carried-over DSH_HOME whose stored paths name another container must be
# repaired before Node touches it.
#
# THIS REPLACES step 4B's version of this check, which asserted that sessions were
# MOVED INTO QUARANTINE. That was the old behaviour, and the bug step 6 fixes:
# quarantine kept the bytes and lost the history. The assertion is now the opposite
# — every stored path repaired, every session still in place — and it covers the
# session HEADER too, which the old script never looked at because the header sits
# inside a Zstandard frame.
#
# Two further things the old script could not honestly assert, and this one can:
#   * it wrote a `/private/var/mobile/...` spelling into a simulator container. That
#     path does not exist on this platform, so "the repaired path points at a real
#     directory" was untestable and was left out. This uses a second REAL container
#     path, in this platform's own spelling.
#   * its "session" was `echo x > s.json` — not a session and not a log, so the
#     header rewrite was never exercised at all.
#
# Usage: scripts/sim-stale-container-test.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/device.sh"
# `device.sh` sets `-e` for its own use, and sourcing it turns that on HERE too.
# This script must not run with it: several steps are deliberately allowed to fail
# (`find` finding no session yet, `grep` finding no match) and the verdict is the
# exit code at the end, not the first non-zero command.
set +e
set -uo pipefail
UD=$(device_udid); boot_device "$UD"
S="xcrun simctl --set $SIMSET"
# A container uuid from a previous install generation, in THIS platform's spelling.
OLD_UUID=3A57BFE5-561B-4FA4-A595-75CD5A5C6E52
rc=0

report() { if [ "$2" = 0 ]; then echo "PASS  $1"; else echo "FAIL  $1  [$3]"; rc=1; fi; }

$S terminate $UD "$BUNDLE_ID" >/dev/null 2>&1 || true
$S uninstall $UD "$BUNDLE_ID" >/dev/null 2>&1 || true
$S install $UD "$APP_PATH"
# First launch creates the profile; a session log may or may not exist yet.
#
# The guest is left ON, unlike the step-4B version of this script. With
# `DSHPORTE_GUEST_CHANNEL=0` the subprocess provider never mounts, and DSH then
# reports ten rows as "did not activate ... pending (waiting for service:
# subprocess)" — an expected consequence of a deliberately reduced launch, not a
# migration failure. Counting those as boot warnings would make the final check
# meaningless, so this runs the configuration the app actually ships.
$S launch $UD "$BUNDLE_ID" >/dev/null; sleep 22
$S terminate $UD "$BUNDLE_ID"
sleep 2
C=$($S get_app_container $UD "$BUNDLE_ID" data)
H="$C/Library/Application Support/DSH"
# The status/log/session-url files live under Library/Application Support, not
# Documents, so they stay out of the Files app.
R="$C/Library/Application Support/DSHPortC"
OLD="$HOME/Library/Caches/dsh-ios-port-E/simdevices/F5A8CDB4-EBC2-4E83-B652-9C12283BAF5C/data/Containers/Data/Application/$OLD_UUID"

# A real session log to work with: the one the app wrote, or a minimal real one in
# DSH's own frame layout when the app has not written one yet.
SESS=$(find "$H/sessions" -name "*.jsonl.zstd" 2>/dev/null | head -1)
if [ -z "$SESS" ]; then
    SID=session-3a57bfe5-0000-4000-8000-000000000001
    SD="$H/sessions/--seed--/$SID"
    mkdir -p "$SD"
    printf '%s\n' "{\"type\":\"session\",\"version\":4,\"id\":\"$SID\",\"createdAt\":1793179717698,\"cwd\":\"$C/Documents/workspace/deepseek-harness/default-workspace\",\"isSeeded\":false,\"delegationDepth\":0,\"agentPreset\":\"ios-safe\"}" > /tmp/step6-header.jsonl
    zstd -q -c /tmp/step6-header.jsonl > "$SD/session.v4.jsonl.zstd"
    # The `--seed--` project directory is the session's own parent; it becomes the
    # old project key once step 1 rewrites the header, so it is left in place.
    SESS="$SD/session.v4.jsonl.zstd"
fi
mkdir -p "$(dirname "$SESS")"

# 1. the session header points at the old container, in its own spelling
python3 "$HERE/rewrite-session-header.py" --log "$SESS" \
    --cwd "$OLD/Documents/workspace/deepseek-harness/default-workspace" >/dev/null || rc=1
# 2. the workspace registry points at it, and the last-seen container is the old one
mkdir -p "$H/storages"
python3 - "$H/storages/workspace.json" "$C" "$OLD" <<'PY'
import json, pathlib, sys
path, current, old = sys.argv[1], sys.argv[2], sys.argv[3]
data = {"unit": {"name": "workspace", "version": 2},
        "global": {"initialized": True, "workspaceIds": ["w-old"], "archivedSessionIds": [],
                   "pinnedSessionIds": [], "defaultWorkspaceId": "w-old"},
        "tables": {"workspaces": {"w-old": {
            "path": f"{old}/Documents/workspace/deepseek-harness/default-workspace",
            "title": "default-workspace", "sessionIds": [],
            "createdAt": "2026-10-01T00:00:00.000Z", "updatedAt": "2026-10-01T00:00:00.000Z"}}}}
pathlib.Path(path).write_text(json.dumps(data, indent=2))
PY
printf '%s' "$OLD" > "$H/.container-root"

# 3. relaunch and check every stored path was repaired
$S launch $UD "$BUNDLE_ID" >/dev/null; sleep 24
AFTER=$(find "$H/sessions" -name "*.jsonl.zstd" 2>/dev/null | head -1)
echo "--- workspace.json after:"; cat "$H/storages/workspace.json"
echo "--- session log after:"; echo "$AFTER" | sed "s|$H/||"
echo "--- migrate summary:"; sed -n '1,24p' "$H/DSHPortE-session-migrate.json" 2>/dev/null

if grep -q "$OLD_UUID" "$H/storages/workspace.json"; then
    report "workspace.json no longer names the old container" 1 "$(grep -o "$OLD_UUID" "$H/storages/workspace.json" | head -1)"
else
    report "workspace.json no longer names the old container" 0
fi

if [ -n "$AFTER" ]; then
    HEADER_CWD=$(zstd -dc "$AFTER" 2>/dev/null | head -1 | python3 -c 'import json,sys; print(json.load(sys.stdin).get("cwd",""))')
    case "$HEADER_CWD" in
        "$C"/*) report "the session header names the current container" 0 ;;
        *) report "the session header names the current container" 1 "$HEADER_CWD" ;;
    esac
    case "$HEADER_CWD" in
        *"$OLD_UUID"*) report "the session header no longer names the old one" 1 "$HEADER_CWD" ;;
        *) report "the session header no longer names the old one" 0 ;;
    esac
    case "$AFTER" in
        *"$OLD_UUID"*) report "the session folder moved off the old project key" 1 "$(basename "$(dirname "$AFTER")")" ;;
        *) report "the session folder moved off the old project key" 0 ;;
    esac
    Q=$(find "$H/sessions-quarantine" -name "*.jsonl.zstd" 2>/dev/null | wc -l | tr -d ' ')
    report "no session was quarantined" $([ "$Q" = 0 ] && echo 0 || echo 1) "$Q log(s) in quarantine"
else
    report "the session survived the repair" 1 "no session log after the migration"
fi

python3 -c "import json,sys; d=json.load(open('$R/DSHPortC-status.json')); sys.exit(0 if d['phase']=='webViewReady' else 1)" \
    && report "the app reaches webViewReady" 0 || report "the app reaches webViewReady" 1 "phase not ready"
ALERTS=$(grep -c "did not activate\|corrupt\|pending (waiting" "$R/DSHPortC-node.log" || true)
report "no activation warning, corrupt log, or pending service" $([ "$ALERTS" = 0 ] && echo 0 || echo 1) "$ALERTS line(s)"

$S terminate $UD "$BUNDLE_ID" >/dev/null 2>&1 || true
exit $rc
