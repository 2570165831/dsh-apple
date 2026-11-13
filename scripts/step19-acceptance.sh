#!/bin/bash
# Step 19B, PLAN-19 §9: the nine acceptance criteria plus the extras TASK-19B
# added, run as one sequence and recorded as one log.
#
# WHY ONE SCRIPT. Every criterion is a SEQUENCE of launches and container edits,
# and running them by hand is how a report ends up quoting a number from a
# different build. This runs them in the order the plan lists them, against ONE
# installed app, and prints a PASS/FAIL line per criterion from evidence a person
# can re-read afterwards.
#
# It leaves its evidence in the container and copies the interesting parts into
# logs/step19/acceptance/. It does not uninstall between criteria unless one
# requires a fresh container, because the point of most of them is what survives.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export DSHPORTE_DEVICE="${DSHPORTE_DEVICE:-phone-bg}"

# shellcheck source=device.sh
. "$HERE/device.sh"

OUT="$ROOT/logs/step19/acceptance"
mkdir -p "$OUT"
UDID="$(device_udid)"
boot_device "$UDID"
APP="$ROOT/DerivedData/Build/Products/Debug-iphonesimulator/DSHPortC.app"

PASS=0
FAIL=0
declare -a LINES=()

# Record one verdict.
#
# The detail is flattened to one line before it is stored: several of the values
# this reports come from JSON the app wrote, and a stray newline in one of them
# would split a `LINES` entry in two and make the summary unreadable. `tr` rather
# than a shell substitution so it also collapses `\r`.
record() {
    local name="$1" ok="$2" detail="$3"
    detail="$(printf '%s' "$detail" | tr -s '\n\r' '  ')"
    if [ "$ok" = "1" ]; then
        PASS=$((PASS + 1))
        LINES+=("PASS  $name  $detail")
        echo "PASS  $name  $detail"
    else
        FAIL=$((FAIL + 1))
        LINES+=("FAIL  $name  $detail")
        echo "FAIL  $name  $detail"
    fi
}

container() { xcrun simctl --set "$SIMSET" get_app_container "$UDID" "$BUNDLE_ID" data; }
runtime() { echo "$(container)/Library/Application Support/DSHPortC"; }
dshhome() { echo "$(container)/Library/Application Support/DSH"; }

install_fresh() {
    xcrun simctl --set "$SIMSET" terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl --set "$SIMSET" uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl --set "$SIMSET" install "$UDID" "$APP" >/dev/null || { echo "install failed" >&2; exit 1; }
}

install_over() {
    xcrun simctl --set "$SIMSET" install "$UDID" "$APP" >/dev/null || { echo "install failed" >&2; exit 1; }
}

launch() {
    local wait_s="$1"; shift
    xcrun simctl --set "$SIMSET" terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    sleep 1
    xcrun simctl --set "$SIMSET" launch "$UDID" "$BUNDLE_ID" "$@" >/dev/null || return 1
    sleep "$wait_s"
}

# One field of boot-guard.json, or empty.
guard() {
    local file
    file="$(runtime)/boot/boot-guard.json"
    [ -f "$file" ] || { echo ""; return 0; }
    python3 -c '
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    print("")
    sys.exit(0)
print(data.get(sys.argv[2], "") if not isinstance(data.get(sys.argv[2]), bool)
      else ("true" if data.get(sys.argv[2]) else "false"))
' "$file" "$1"
}

guard_attempt() {
    local file
    file="$(runtime)/boot/boot-guard.json"
    [ -f "$file" ] || { echo ""; return 0; }
    python3 -c '
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    print("")
    sys.exit(0)
print((data.get("attempt") or {}).get(sys.argv[2]) or "")
' "$file" "$1"
}

guard_last() {
    local file
    file="$(runtime)/boot/boot-guard.json"
    [ -f "$file" ] || { echo ""; return 0; }
    python3 -c '
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    print("")
    sys.exit(0)
print((data.get("lastOutcome") or {}).get(sys.argv[2]) or "")
' "$file" "$1"
}

safemode_active() {
    /usr/bin/grep -o '"active":[a-z]*' "$(runtime)/DSHPortC-node.log" 2>/dev/null | tail -1
}

overlay_rows() {
    local file
    file="$(runtime)/boot/safe-mode.patch.yml"
    [ -f "$file" ] || { echo 0; return 0; }
    /usr/bin/grep -c '^- id: ' "$file" || true
}

echo "== step 19B acceptance, device $DEVICE_NAME ($UDID)"
echo "== app $APP"
[ -d "$APP" ] || { echo "no app; run scripts/build-app.sh" >&2; exit 1; }

# ------------------------------------------------------------------ criterion 1
# Three failing launches, then a fourth that should come up in safe mode.
echo
echo "== criterion 1: three failures, then safe mode"
install_fresh
for n in 1 2 3; do
    launch 9 -DSHPortEBootFailFast 1 -DSHPortCMockPort 19719
done
launch 24 -DSHPortCMockPort 19719
C1_FAILURES="$(guard failures)"
C1_MODE="$(guard_attempt mode)"
C1_SAFE="$(safemode_active)"
if [ "$C1_FAILURES" = "3" ] && [ "$C1_SAFE" = '"active":true' ]; then
    record "criterion-1" 1 "failures=$C1_FAILURES safemode=$C1_SAFE overlay_rows=$(overlay_rows)"
else
    record "criterion-1" 0 "failures=$C1_FAILURES expected 3; safemode=$C1_SAFE"
fi

# ------------------------------------------------------------------ criterion 2
# A success after two failures resets the streak.
echo
echo "== criterion 2: a success clears the streak"
#
# THE ORDER HERE IS LOAD-BEARING, and the first version of this script got it
# wrong. `-DSHPortEBootFailFast 1` fails inside `prepareAndLaunch`, i.e. BEFORE
# `node_start`, so on a FRESH container Node never runs and `boot-guard.json` is
# never written at all — `failures` reads as empty, not 0 and not 2. The counter
# only exists once a launch has reached Node.
#
# So the streak is built the way a user builds one: one launch that reaches Node
# and comes up (which writes the state file and clears the streak), then two
# failures that get counted from the outcome queue, then a success.
install_fresh
launch 22 -DSHPortCMockPort 19719
C2_SEEDED="$(guard failures)"
launch 9 -DSHPortEBootFailFast 1 -DSHPortCMockPort 19719
launch 9 -DSHPortEBootFailFast 1 -DSHPortCMockPort 19719
# The two failures are SETTLED by the next launch that reaches Node, and that
# launch's own success is settled by the one after it. So the sequence is:
#   launch (reaches Node, settles 2 failures -> failures=2)
#   launch (settles the previous success -> failures=0)
launch 22 -DSHPortCMockPort 19719
C2_BEFORE="$(guard failures)"
launch 22 -DSHPortCMockPort 19719
# A SUCCESS IS SETTLED BY THE NEXT LAUNCH, NOT BY THE ONE THAT SUCCEEDED.
#
# `boot-guard.mjs` owns the counter and runs at the top of a launch; the success
# this launch produced lives in `boot-outcome.json` until the next `beginLaunch()`
# reads it. So reading the counter immediately after a successful launch shows the
# streak BEFORE that success — measured: `failures 0 -> 2`, with the second value
# being the two failures that had just been settled. The plan says the same thing in
# §1.6 ("单次消费，读后删"), and this is what that means in practice.
#
C2_AFTER="$(guard failures)"
C2_KIND="$(guard_last kind)"
if [ "$C2_SEEDED" = "0" ] && [ "$C2_BEFORE" = "2" ] && [ "$C2_AFTER" = "0" ] && [ "$C2_KIND" = "success" ]; then
    record "criterion-2" 1 "seeded=$C2_SEEDED failures $C2_BEFORE -> $C2_AFTER (settled by the next launch), last=$C2_KIND"
else
    record "criterion-2" 0 "seeded=$C2_SEEDED failures $C2_BEFORE -> $C2_AFTER last=$C2_KIND (expected 0, 2 -> 0 after one more launch)"
fi

# ------------------------------------------------------------------ criterion 3
# Closing the app in the background is not a boot failure. Two arms: an app that
# had come up, and one that was still booting.
echo
echo "== criterion 3: a swipe-away is not a failure"
install_fresh
launch 22 -DSHPortCMockPort 19719
xcrun simctl --set "$SIMSET" launch "$UDID" com.apple.Preferences >/dev/null 2>&1 || true
sleep 2
xcrun simctl --set "$SIMSET" terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
launch 22 -DSHPortCMockPort 19719
C3_FAILURES="$(guard failures)"
C3_KIND="$(guard_last kind)"
# The mid-boot arm: terminate two seconds in, after a background transition.
# One second each, not two: a boot takes about four, and a page that makes it before
# the kill is rightly a success, which is not the arm being measured.
launch 1 -DSHPortCMockPort 19719
xcrun simctl --set "$SIMSET" launch "$UDID" com.apple.Preferences >/dev/null 2>&1 || true
sleep 1
xcrun simctl --set "$SIMSET" terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
launch 22 -DSHPortCMockPort 19719
C3_MID_FAILURES="$(guard failures)"
C3_MID_KIND="$(guard_last kind)"
if [ "$C3_FAILURES" = "0" ] && [ "$C3_MID_FAILURES" = "0" ] && [ "$C3_MID_KIND" = "abandoned" ]; then
    record "criterion-3" 1 "after-swipe failures=$C3_FAILURES last=$C3_KIND; mid-boot failures=$C3_MID_FAILURES last=$C3_MID_KIND"
else
    record "criterion-3" 0 "after-swipe failures=$C3_FAILURES last=$C3_KIND; mid-boot failures=$C3_MID_FAILURES last=$C3_MID_KIND (expected abandoned)"
fi

# ------------------------------------------------------------------ criterion 4
# The watchdog. The page loads and never declares itself ready.
echo
echo "== criterion 4: the page-ready watchdog"
install_fresh
launch 90 -DSHPortCMockPort 19719 -DSHPortEStep19HoldReadyMs 240000
# `boot-outcome.json` is a LIST now — one compact JSON object per line — because a
# launch that fails before Node starts never consumes it and an overwrite would
# keep only the last failure. So the last line is the newest conclusion.
C4_REASON="$(python3 -c '
import json, sys
try:
    lines = [l for l in open(sys.argv[1]).read().splitlines() if l.strip()]
except Exception:
    print(""); sys.exit(0)
for line in reversed(lines):
    try:
        print(json.loads(line).get("reason", ""))
        sys.exit(0)
    except Exception:
        continue
print("")
' "$(runtime)/boot/boot-outcome.json")"
# Compared with `[[ ]]` and a plain substring test rather than `case`: the reason
# is Chinese text that may carry a newline if the writer ever pretty-prints it, and
# a `case` whose subject contains a newline is a parse-level trap (measured: the
# branch body was re-split and `record` was invoked as a command named `REASON`).
if [ -z "$C4_REASON" ]; then
    record "criterion-4" 0 "boot-outcome.json has no reason"
elif [[ "$C4_REASON" == *"60"* ]]; then
    record "criterion-4" 1 "outcome reason: $C4_REASON"
else
    record "criterion-4" 0 "outcome reason: $C4_REASON"
fi

# ------------------------------------------------------------------ criterion 5
# Safe mode really loads fewer plugins, parks the user layer, and can still do
# the three things a user needs: open the page, create a session, send a message.
echo
echo "== criterion 5: safe mode's composition and its three jobs"
install_fresh
# A user layer with real content, so "parked" means something.
launch 22 -DSHPortCMockPort 19719
USERLAYER="$(dshhome)/profiles/ios-sim/cordis.patch.yml"
printf '# acceptance user layer\n- id: agent-default-model\n  config:\n    provider: local-mock\n    model: mock-scripted\n' > "$USERLAYER"
USERLAYER_SHA="$(shasum -a 256 "$USERLAYER" | cut -d' ' -f1)"
for n in 1 2 3; do launch 9 -DSHPortEBootFailFast 1 -DSHPortCMockPort 19719; done
launch 24 -DSHPortCMockPort 19719
C5_ROWS="$(overlay_rows)"
C5_CURRENT="$(head -1 "$(dshhome)/profiles/ios-sim/cordis.patch.yml" 2>/dev/null | tr -d '\n')"
C5_PARKED="$(head -1 "$(dshhome)/profiles/ios-sim/cordis.patch.yml.safe-mode-parked" 2>/dev/null | tr -d '\n')"
C5_PARKED_SHA="$(shasum -a 256 "$(dshhome)/profiles/ios-sim/cordis.patch.yml.safe-mode-parked" 2>/dev/null | cut -d' ' -f1)"
# The probe: session + one turn, in the safe-mode composition.
#
# The prompt is ONE line on the command line even though its content is several:
# `simctl launch -DKey value` takes one value per argument, and a literal newline
# inside the quoted value is re-split by the launcher (measured — the second line
# arrived as a separate launch argument). `\n` reaches the app as the two-character
# escape, which the mock's own `parseBashScript` splits on.
launch 60 -DSHPortCMockPort 19719 -DSHPortEStep19SafeProbe 1 \
    -DSHPortEStep19Prompt 'BASHTEST\nSTEP echo STEP19-ACCEPTANCE-BASH\nSTEP id' 
C5_PROBE="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("no-report"); sys.exit(0)
c = d.get("criteria", {})
turn = c.get("turn") or {}
print("session=%s turn=%s model=%s tools=%s" % (
    (c.get("create-session") or {}).get("ok"),
    turn.get("ok"), turn.get("modelCalled"),
    "tool/call" in (turn.get("types") or [])))
' "$(container)/Documents/DSHPortE-step19-safe-probe.json")"
if [ "$C5_ROWS" = "6" ] && [ "$C5_CURRENT" = "[]" ] && [ "$C5_PARKED_SHA" = "$USERLAYER_SHA" ] \
   && [ "$C5_PROBE" = "session=True turn=True model=True tools=True" ]; then
    record "criterion-5" 1 "overlay rows=$C5_ROWS current='$C5_CURRENT' parked sha matches; $C5_PROBE"
else
    record "criterion-5" 0 "overlay rows=$C5_ROWS current='$C5_CURRENT' parked_sha=$C5_PARKED_SHA want=$USERLAYER_SHA; $C5_PROBE"
fi

# ------------------------------------------------------------------ criterion 6
# Leaving safe mode puts the user layer back byte for byte.
echo
echo "== criterion 6: leaving safe mode"
printf '{"version":1,"action":"exit-safe-mode","id":"acceptance-exit","at":"2026-11-02T00:00:00Z"}\n' \
    > "$(runtime)/boot/boot-request.json"
launch 24 -DSHPortCMockPort 19719
C6_SHA="$(shasum -a 256 "$(dshhome)/profiles/ios-sim/cordis.patch.yml" 2>/dev/null | cut -d' ' -f1)"
C6_ACTIVE="$(safemode_active)"
C6_PARKED="$( [ -f "$(dshhome)/profiles/ios-sim/cordis.patch.yml.safe-mode-parked" ] && echo present || echo absent )"
if [ "$C6_SHA" = "$USERLAYER_SHA" ] && [ "$C6_ACTIVE" = '"active":false' ] && [ "$C6_PARKED" = "absent" ]; then
    record "criterion-6" 1 "user layer sha restored; $C6_ACTIVE; parked $C6_PARKED"
else
    record "criterion-6" 0 "sha=$C6_SHA want=$USERLAYER_SHA; $C6_ACTIVE; parked $C6_PARKED"
fi

# ------------------------------------------------------------------ criterion 7
# The diagnostics bundle does not carry a planted secret, and the redaction rules
# really fire rather than there being nothing to redact.
echo
echo "== criterion 7: the diagnostics bundle"
# THE PLANTED LINES GO IN AFTER THE LAUNCH, NOT BEFORE IT.
#
# `NodeRunner.begin()` deletes `DSHPortC-node.log` and starts a fresh one, so lines
# appended before a launch are gone by the time the app snapshots anything — the run
# that did it that way reported `redaction lines=0` on a bundle that really did have
# nothing to redact, which is a vacuous PASS waiting to happen. Measured twice.
#
# The snapshot Node takes at boot reads the PREVIOUS launch's log, so the sequence
# that actually exercises the redaction is: launch (log exists), append the planted
# lines, then ask for an export — `exportOnce` re-reads the same file and renders a
# fresh bundle from it.
launch 24 -DSHPortCMockPort 19719
# These go in after the launch too: a malformed credentials file stops DSH starting
# (criterion 10), and the app has to be up to answer the export.
DH="$(dshhome)"
printf 'providers:\n  test:\n    apiKey: sk-STEP19ACCEPTANCEFAKE0123456789\n' > "$DH/.credentials.yaml"
mkdir -p "$DH/sessions/planted" && echo 'STEP19ACCEPTANCESESSION' > "$DH/sessions/planted/session.v1.jsonl"
mkdir -p "$DH/storages" && echo '{"x":"STEP19ACCEPTANCESTORAGE"}' > "$DH/storages/x.json"
printf 'node| Authorization: Bearer STEP19ACCEPTANCEBEARER\nnode| token=STEP19ACCEPTANCETOKEN\n' \
    >> "$(runtime)/DSHPortC-node.log"
# The bundle is rendered by the app: the same request file and poller the button uses.
C7_ID="acceptance-$$"
printf '{"action":"export-diagnostics","id":"%s"}\n' "$C7_ID" > "$(runtime)/boot/export-request.json"
for _ in 1 2 3 4 5 6 7 8 9 10; do
    /usr/bin/grep -q "$C7_ID" "$(runtime)/boot/export-done.json" 2>/dev/null && break
    sleep 1
done
/usr/bin/grep -q "$C7_ID" "$(runtime)/boot/export-done.json" 2>/dev/null \
    && echo "export-done=$C7_ID" > /tmp/step19-c7-render.txt \
    || echo "export-done=absent" > /tmp/step19-c7-render.txt
C7_RENDER="$(cat /tmp/step19-c7-render.txt)"
echo "   render: $C7_RENDER"
# The planted strings are searched for in the bundle directories ONLY, and the
# search is done by python rather than by `grep -r`: a shell loop whose body is a
# pipeline that answers "0 files" was measured to end the whole script silently
# (the run stopped right after the first marker with exit 0 and no summary), and a
# search that cannot be confused with a shell arithmetic error is worth more here
# than one fewer process.
C7_RESULT="$(python3 - "$(runtime)/diagnostics" <<'PYEOF'
import json, os, sys
root = sys.argv[1]
markers = [
    "STEP19ACCEPTANCEFAKE0123456789", "STEP19ACCEPTANCEBEARER", "STEP19ACCEPTANCETOKEN",
    "STEP19ACCEPTANCESESSION", "STEP19ACCEPTANCESTORAGE", "STEP19ACCEPTANCEFAKEKEY",
]
leaks = 0
bundles = 0
files = 0
redactionLines = 0
if os.path.isdir(root):
    for name in sorted(os.listdir(root)):
        bundle = os.path.join(root, name)
        if not os.path.isdir(bundle):
            continue
        bundles += 1
        filesDir = os.path.join(bundle, "files")
        if os.path.isdir(filesDir):
            for entry in os.listdir(filesDir):
                path = os.path.join(filesDir, entry)
                files += 1
                try:
                    text = open(path, "rb").read().decode("utf-8", "replace")
                except Exception:
                    continue
                for marker in markers:
                    if marker in text:
                        leaks += 1
                redactionLines += text.count("Authorization: <redacted>") + text.count("token=<redacted>")
print(json.dumps({"leaks": leaks, "bundles": bundles, "files": files, "redactionLines": redactionLines}))
PYEOF
)"
C7_DONEFILE="$(printf '%s' "$C7_RENDER" | head -1)"
C7_LEAKS="$(printf '%s' "$C7_RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["leaks"])' 2>/dev/null || echo 0)"
C7_BUNDLES="$(printf '%s' "$C7_RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["bundles"])' 2>/dev/null || echo 0)"
C7_FILES="$(printf '%s' "$C7_RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["files"])' 2>/dev/null || echo 0)"
C7_REDACTED="$(printf '%s' "$C7_RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["redactionLines"])' 2>/dev/null || echo 0)"
# The bundle has to EXIST, contain files, be free of the planted strings, AND show
# that the redaction rules ran. The last clause is the one that stops this from
# passing on an empty bundle: "0 hits" from nothing having been read is not
# evidence that a secret was removed.
if [ "$C7_LEAKS" = "0" ] && [ "$C7_BUNDLES" -ge 1 ] && [ "$C7_FILES" -ge 1 ] && [ "$C7_REDACTED" -ge 1 ]; then
    record "criterion-7" 1 "bundles=$C7_BUNDLES files=$C7_FILES planted secrets found=0 redaction lines=$C7_REDACTED render=$C7_DONEFILE"
else
    record "criterion-7" 0 "bundles=$C7_BUNDLES files=$C7_FILES leaks=$C7_LEAKS redaction lines=$C7_REDACTED render=$C7_DONEFILE"
fi

# ------------------------------------------------------------------ criterion 8
# Reset, both arms: keep the conversations (settings go), and the reverse.
echo
echo "== criterion 8: reset, both arms"
reset_arm() {
    local keep_conv="$1" keep_set="$2" label="$3"
    install_fresh
    launch 22 -DSHPortCMockPort 19719
    local dh; dh="$(dshhome)"
    mkdir -p "$dh/sessions/arm" && echo "SESSION-$label" > "$dh/sessions/arm/session.v1.jsonl"
    mkdir -p "$dh/storages" && echo "{}" > "$dh/storages/ws.json"
    printf 'key: SETTINGS-%s\n' "$label" > "$dh/.credentials.yaml"
    mkdir -p "$dh/profiles/ios-sim" && printf '# PROFILE-%s\n' "$label" > "$dh/profiles/ios-sim/cordis.patch.yml"
    printf '{"version":1,"keepConversations":%s,"keepSettings":%s,"requestedAt":"2026-11-02T00:00:00Z"}\n' \
        "$keep_conv" "$keep_set" > "$(runtime)/reset-request.json"
    launch 24 -DSHPortCMockPort 19719
    local staging; staging="$(runtime)/reset-staging"
    # Counted and reported by one python process: the shell pipeline form of this
    # (`find ... | wc -l`) is what ended criterion 7's loop silently on an earlier
    # run, and a criterion whose evidence is a count is not worth that risk twice.
    python3 - "$label" "$keep_conv" "$keep_set" "$staging" <<'PY'
import json, os, re, sys
label, keep_conv, keep_set, staging = sys.argv[1:5]
with open(os.path.join(staging, "complete.json")) as record:
    stamp = json.load(record)["stamp"]
if not isinstance(stamp, str) or not re.fullmatch(r"[0-9]{8}T[0-9]{6}Z", stamp):
    raise SystemExit("invalid completed reset stamp")
staging = os.path.join(staging, stamp)
if not os.path.isdir(staging):
    raise SystemExit("completed reset directory is missing")
conversations = 0
for base, _dirs, files in os.walk(staging):
    conversations += sum(1 for name in files if name == "session.v1.jsonl")
credentials = 1 if os.path.isfile(
    os.path.join(staging, "Library/Application Support/DSH/.credentials.yaml")) else 0
want_conv = 0 if keep_conv == "true" else 1
want_settings = 0 if keep_set == "true" else 1
ok = conversations == want_conv and credentials == want_settings
print("%s conversations_moved=%s (want %s) settings_moved=%s (want %s)" % (
    "OK" if ok else "BAD", conversations, want_conv, credentials, want_settings))
PY
}
C8A="$(reset_arm true false keepconv)"
C8B="$(reset_arm false true keepset)"
case "$C8A$C8B" in
    OK*OK*) record "criterion-8" 1 "keep-conversations: $C8A | keep-settings: $C8B" ;;
    *) record "criterion-8" 0 "keep-conversations: $C8A | keep-settings: $C8B" ;;
esac

# ------------------------------------------------------------------ criterion 9
# A reset killed half way is finished by the next launch, and nothing ends up in
# neither place.
echo
echo "== criterion 9: an interrupted reset"
install_fresh
launch 22 -DSHPortCMockPort 19719
R9="$(runtime)/reset-staging"
STAMP9=20261101T235900Z
mkdir -p "$R9/$STAMP9/Library/Application Support/DSH"
mkdir -p "$(dshhome)/cache" && echo nine > "$(dshhome)/cache/nine"
mkdir -p "$(dshhome)/diagnostics-unused" 2>/dev/null || true
printf '{"version":1,"stamp":"%s","entries":["Library/Application Support/DSH/cache","Library/Application Support/DSH/events.jsonl"],"keepConversations":true,"keepSettings":true,"startedAt":"2026-11-02T00:00:00Z","moved":0}\n' \
    "$STAMP9" > "$R9/in-progress.json"
launch 24 -DSHPortCMockPort 19719
launch 24 -DSHPortCMockPort 19719
C9_CACHE_IN_STAGING=$( [ -e "$R9/$STAMP9/Library/Application Support/DSH/cache" ] && echo 1 || echo 0 )
C9_EVENTS_IN_STAGING=$( [ -e "$R9/$STAMP9/Library/Application Support/DSH/events.jsonl" ] && echo 1 || echo 0 )
C9_INPROGRESS=$( [ -f "$R9/in-progress.json" ] && echo present || echo absent )
C9_COMPLETE=$( [ -f "$R9/complete.json" ] && echo present || echo absent )
# "In neither place" is the failure this criterion is about.
C9_ORPHANS=0
for rel in "Library/Application Support/DSH/cache" "Library/Application Support/DSH/events.jsonl"; do
    [ -e "$(container)/$rel" ] && continue
    [ -e "$R9/$STAMP9/$rel" ] && continue
    C9_ORPHANS=$((C9_ORPHANS + 1))
done
if [ "$C9_CACHE_IN_STAGING" = "1" ] && [ "$C9_EVENTS_IN_STAGING" = "1" ] \
   && [ "$C9_INPROGRESS" = "absent" ] && [ "$C9_COMPLETE" = "present" ] && [ "$C9_ORPHANS" = "0" ]; then
    record "criterion-9" 1 "entries moved=$C9_CACHE_IN_STAGING/$C9_EVENTS_IN_STAGING in-progress=$C9_INPROGRESS complete=$C9_COMPLETE orphans=$C9_ORPHANS"
else
    record "criterion-9" 0 "entries moved=$C9_CACHE_IN_STAGING/$C9_EVENTS_IN_STAGING in-progress=$C9_INPROGRESS complete=$C9_COMPLETE orphans=$C9_ORPHANS"
fi

# ------------------------------------------------------- extras (TASK-19B §验收)
echo
echo "== criterion 10: a startup failure keeps the app open, and a reset gets out of it"
install_fresh
launch 22 -DSHPortCMockPort 19719
printf 'not: [valid\n' > "$(dshhome)/.credentials.yaml"
launch 16 -DSHPortCMockPort 19719
C10_STATE="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("phase"), "|", d.get("error"))' "$(runtime)/DSHPortC-status.json")"
C10_ALIVE="$(xcrun simctl --set "$SIMSET" spawn "$UDID" launchctl list | /usr/bin/grep -c "$BUNDLE_ID" || true)"
printf '{"version":1,"keepConversations":true,"keepSettings":false,"requestedAt":"2026-11-02T00:00:00Z"}\n' \
    > "$(runtime)/reset-request.json"
launch 24 -DSHPortCMockPort 19719
C10_AFTER="$(/usr/bin/grep -c "webview ready" "$(runtime)/DSHPortC-node.log" || true)"
case "$C10_STATE" in
    failed*"startup failed"*)
        if [ "$C10_ALIVE" -ge 1 ] && [ "$C10_AFTER" -ge 1 ]; then
            record "criterion-10" 1 "state=$C10_STATE alive=$C10_ALIVE page after reset=$C10_AFTER"
        else
            record "criterion-10" 0 "state=$C10_STATE alive=$C10_ALIVE page after reset=$C10_AFTER"
        fi ;;
    *) record "criterion-10" 0 "state=$C10_STATE alive=$C10_ALIVE page after reset=$C10_AFTER" ;;
esac

echo
echo "== criterion 11: safe mode died twice, so the next launch stops at the failure screen"
install_fresh
launch 22 -DSHPortCMockPort 19719
python3 - "$(runtime)/boot/boot-guard.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d.update(safeMode=True, safeModeFailures=2, failures=5,
         safeModeSince="2026-11-02T00:00:00Z", lastFailureAt="2099-01-01T00:00:00.000Z")
json.dump(d, open(sys.argv[1], "w"))
PY
launch 10 -DSHPortCMockPort 19719
C11_STATE="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("phase"))' "$(runtime)/DSHPortC-status.json")"
C11_NODE="$(/usr/bin/grep -c "node_start entered\|node argv" "$(runtime)/DSHPortC-node.log" || true)"
launch 22 -DSHPortCMockPort 19719
C11_AFTER="$(/usr/bin/grep -c "webview ready" "$(runtime)/DSHPortC-node.log" || true)"
if [ "$C11_STATE" = "failed" ] && [ "$C11_NODE" = "0" ] && [ "$C11_AFTER" -ge 1 ]; then
    record "criterion-11" 1 "stopped=$C11_STATE node_lines=$C11_NODE next launch page=$C11_AFTER"
else
    record "criterion-11" 0 "stopped=$C11_STATE node_lines=$C11_NODE next launch page=$C11_AFTER"
fi

echo
echo "== extras: safe mode's three jobs, the approval dialog, and the staging purge"
install_fresh
for n in 1 2 3; do launch 9 -DSHPortEBootFailFast 1 -DSHPortCMockPort 19719; done
launch 24 -DSHPortCMockPort 19719
# The bash tool, in the guest, under safe mode.
launch 65 -DSHPortCMockPort 19719 -DSHPortEStep19SafeProbe 1 -DSHPortEStep19Prompt "BASHTEST
STEP echo STEP19-ACCEPTANCE-BASH
STEP id"
EXTRA_BASH="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("no-report"); sys.exit(0)
c = d.get("criteria", {})
turn = c.get("turn") or {}
tools = "tool/call" in (turn.get("types") or [])
print("session=%s turn=%s model=%s tools=%s types=%d" % (
    (c.get("create-session") or {}).get("ok"), turn.get("ok"),
    turn.get("modelCalled"), tools, len(turn.get("types") or [])))
' "$(container)/Documents/DSHPortE-step19-safe-probe.json")"
# The approval dialog for a destructive command, still asked in safe mode.
launch 65 -DSHPortCMockPort 19719 -DSHPortEStep19SafeProbe 1 \
    -DSHPortEStep19Prompt "APPROVALTEST rm -rf the file the script created"
EXTRA_APPROVAL="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("no-report"); sys.exit(0)
turn = d.get("criteria", {}).get("turn") or {}
print("approvalAsked=%s types=%s" % (turn.get("approvalAsked"), ",".join(turn.get("types") or [])))
' "$(container)/Documents/DSHPortE-step19-safe-probe.json")"
# A failed launch that offers the two buttons is a UI fact; the identifiers are
# checked by the UI test, so here only the state is recorded.
launch 9 -DSHPortEBootFailFast 1 -DSHPortCMockPort 19719
EXTRA_FAILSTATE="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("absent"); sys.exit(0)
print("%s/%s" % (d.get("phase"), (d.get("error") or "")[:40]))
' "$(runtime)/DSHPortC-status.json")"
# The staging purge, through the panel's own function.
STAGING_BEFORE=$(du -sk "$(runtime)/reset-staging" 2>/dev/null | cut -f1)
launch 22 -DSHPortCMockPort 19719 -DSHPortEStep19PurgeStaging 1
STAGING_AFTER=$(du -sk "$(runtime)/reset-staging" 2>/dev/null | cut -f1)
EXTRA_PURGE_LOG="$(/usr/bin/grep -o '已清除上次重置留下的 [0-9]* 项数据\|已清除 [0-9]* 项' "$(runtime)/DSHPortC-node.log" | tail -1)"

case "$EXTRA_BASH" in
    *"turn=True"*"model=True"*"tools=True"*) record "extra-safe-mode-bash" 1 "$EXTRA_BASH" ;;
    *) record "extra-safe-mode-bash" 0 "$EXTRA_BASH" ;;
esac
case "$EXTRA_APPROVAL" in
    *approvalAsked=True*) record "extra-approval-in-safe-mode" 1 "$EXTRA_APPROVAL" ;;
    *) record "extra-approval-in-safe-mode" 0 "$EXTRA_APPROVAL" ;;
esac
if [ "${STAGING_AFTER:-1}" = "0" ] && [ -n "$EXTRA_PURGE_LOG" ]; then
    record "extra-staging-purge" 1 "staging ${STAGING_BEFORE}K -> ${STAGING_AFTER}K; $EXTRA_PURGE_LOG"
else
    record "extra-staging-purge" 0 "staging ${STAGING_BEFORE}K -> ${STAGING_AFTER}K; '${EXTRA_PURGE_LOG}'"
fi
echo "   failure screen state: $EXTRA_FAILSTATE"

# ----------------------------------------------------------------------- verdict
echo
echo "== $PASS passed, $FAIL failed"
{
    echo "step 19B acceptance on $DEVICE_NAME ($UDID)"
    echo "app: $APP"
    echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    printf '%s\n' "${LINES[@]}"
    echo
    echo "$PASS passed, $FAIL failed"
} > "$OUT/summary.txt"
cp "$(runtime)/boot/boot-guard.json" "$OUT/boot-guard-final.json" 2>/dev/null || true
cp "$(runtime)/DSHPortC-node.log" "$OUT/node-final.log" 2>/dev/null || true
echo "== wrote $OUT/summary.txt"
[ "$FAIL" = "0" ] || exit 1
exit 0
