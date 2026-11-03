#!/bin/bash
# Step 19B: launch the app with a chosen failure profile and report what the boot
# guard recorded.
#
# The reason this is a script rather than a list of commands in the report: every
# criterion in PLAN-19 §9 is a SEQUENCE of launches, and a sequence has to be
# reproducible for the numbers in the report to mean anything. Each subcommand
# below is one step of one sequence.
#
#   scripts/step19-launch.sh install       install the built app, keep the container
#   scripts/step19-launch.sh fresh         uninstall + install, so the container is new
#   scripts/step19-launch.sh fail N        N launches that fail in prepareAndLaunch
#   scripts/step19-launch.sh ok            one launch allowed to come up
#   scripts/step19-launch.sh guard         boot-guard.json + the safe-mode line
#   scripts/step19-launch.sh park          the profile's user-layer state + overlay
#   scripts/step19-launch.sh outcome       boot-outcome.json, verbatim
#   scripts/step19-launch.sh kill          force-quit the app
#   scripts/step19-launch.sh background    send the app to the background
#
# `-DSHPortEBootFailFast 1` is step 21's switch; it fails inside
# `prepareAndLaunch`, which is failure source C in PLAN-19 §1.4 — the same place a
# broken profile fails, and after `prepareFilesystem()` so the guard files exist.
set -uo pipefail
# `grep -c` returns 1 when it counts zero, and this script asks "how many" often
# enough that the pipefail above would abort a launch sequence on a legitimate 0.
set +o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export DSHPORTE_DEVICE="${DSHPORTE_DEVICE:-phone-bg}"

# shellcheck source=device.sh
. "$HERE/device.sh"

mkdir -p "$ROOT/logs/step19"
UDID="$(device_udid)"
boot_device "$UDID"

ACTION="${1:-guard}"
APP="$ROOT/DerivedData/Build/Products/Debug-iphonesimulator/DSHPortC.app"

container_path() { xcrun simctl --set "$SIMSET" get_app_container "$UDID" "$BUNDLE_ID" data; }
runtime_path() { echo "$(container_path)/Library/Application Support/DSHPortC"; }
dshhome_path() { echo "$(container_path)/Library/Application Support/DSH"; }

# What the guard decided, printed compactly so a sequence reads as one story.
# python3 rather than jq: jq is not installed on this machine, and adding a
# dependency to read a file the app just wrote is not worth it.
guard_summary() {
    local guard py
    guard="$(runtime_path)/boot/boot-guard.json"
    if [ ! -f "$guard" ]; then
        echo "   boot-guard.json: absent"
        return 0
    fi
    py='
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception as exc:
    print("   boot-guard.json: unreadable (%s)" % exc)
    sys.exit(0)
attempt = data.get("attempt") or {}
last = data.get("lastOutcome") or {}
print("   failures=%s threshold=%s safeMode=%s safeModeFailures=%s probeAfterSafeSuccess=%s" % (
    data.get("failures"), data.get("threshold"), data.get("safeMode"),
    data.get("safeModeFailures"), data.get("probeAfterSafeSuccess")))
print("   attempt: id=%s mode=%s phase=%s" % (
    str(attempt.get("id"))[:8], attempt.get("mode"), attempt.get("phase")))
print("   lastOutcome: kind=%s reason=%s phase=%s mode=%s" % (
    last.get("kind"), last.get("reason"), last.get("phase"), last.get("mode")))
print("   history kinds: %s" % [h.get("kind") for h in data.get("history", [])])
'
    python3 -c "$py" "$guard"
    return 0
}

# The safe-mode line from the most recent launch's node log.
safemode_line() {
    local log line
    log="$(runtime_path)/DSHPortC-node.log"
    if [ ! -f "$log" ]; then echo "   node log: absent"; return 0; fi
    line="$(/usr/bin/grep -o 'DSHPORTC_SAFEMODE .*' "$log" | tail -1 || true)"
    echo "   safemode line: ${line:-absent}"
    echo "   safe-mode mentions in log: $(/usr/bin/grep -c 'safe mode\|SAFE MODE' "$log" || true)"
}

# The profile's two user-layer files, and whether they are what safe mode left.
park_state() {
    local profile parked edited overlay
    profile="$(dshhome_path)/profiles/ios-sim/cordis.patch.yml"
    parked="$profile.safe-mode-parked"
    edited="$profile.safe-mode-edited"
    if [ -f "$profile" ]; then
        echo "   cordis.patch.yml: $(wc -c <"$profile" | tr -d ' ') bytes; first line: $(head -1 "$profile")"
    else
        echo "   cordis.patch.yml: absent"
    fi
    if [ -f "$parked" ]; then
        echo "   parked: $(wc -c <"$parked" | tr -d ' ') bytes; first line: $(head -1 "$parked")"
        echo "   parked sha: $(shasum -a 256 "$parked" | cut -d' ' -f1)"
    else
        echo "   parked: absent"
    fi
    if [ -f "$edited" ]; then
        echo "   edited copy: $(wc -c <"$edited" | tr -d ' ') bytes; first line: $(head -1 "$edited")"
    else
        echo "   edited copy: absent"
    fi
    overlay="$(runtime_path)/boot/safe-mode.patch.yml"
    if [ -f "$overlay" ]; then
        echo "   overlay rows: $(/usr/bin/grep -c '^- id: ' "$overlay")"
        /usr/bin/grep '^- id: ' "$overlay" | sed 's/^/     /'
    else
        echo "   overlay: absent"
    fi
    echo "   profile sha: $( [ -f "$profile" ] && shasum -a 256 "$profile" | cut -d' ' -f1 || echo - )"
}

# The probe's verdict, from the container.
probe_report() {
    local file
    file="$(container_path)/Documents/DSHPortE-step19-safe-probe.json"
    if [ ! -f "$file" ]; then
        echo "   probe report: absent"
        return 0
    fi
    python3 - "$file" <<'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
print("   overlay: %s" % data.get("overlay"))
for key in ("boot", "environment", "services", "create-session", "turn"):
    value = data.get("criteria", {}).get(key)
    print("   %s: %s" % (key, json.dumps(value, ensure_ascii=False)))
PYEOF
    return 0
}

# Launch once and wait for the app to settle.
#
# The wait matters: a launch is not over when `simctl launch` returns, and reading
# the guard file before the app has written its outcome reports the PREVIOUS
# launch. The sleeps are deliberately generous — the app's own cold start is
# 4.5–6 s and a failing launch has the same shape up to the throw.
launch_once() {
    local mode="$1" label="$2" wait_s="${3:-14}"
    xcrun simctl --set "$SIMSET" terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    sleep 1
    echo "== launch $label (mode=$mode wait=${wait_s}s)"
    case "$mode" in
      fail)
        xcrun simctl --set "$SIMSET" launch "$UDID" "$BUNDLE_ID" \
            -DSHPortEBootFailFast 1 -DSHPortCMockPort 19719 >/dev/null || { echo "   launch command failed" >&2; return 1; }
        ;;
      ok)
        xcrun simctl --set "$SIMSET" launch "$UDID" "$BUNDLE_ID" \
            -DSHPortCMockPort 19719 >/dev/null || { echo "   launch command failed" >&2; return 1; }
        ;;
      probe)
        # The safe-mode composition, measured by the probe this launch runs instead
        # of DSH. The overlay is not passed here: `ios-app-entry.mjs` appends it
        # itself when the guard decided safe mode, so the probe measures the same
        # argument list a real launch would.
        xcrun simctl --set "$SIMSET" launch "$UDID" "$BUNDLE_ID" \
            -DSHPortCMockPort 19719 -DSHPortEStep19SafeProbe 1 \
            -DSHPortEStep19Prompt "STEP19 safe-mode turn" >/dev/null || { echo "   launch command failed" >&2; return 1; }
        ;;
      probe-bash)
        # The same probe with a prompt that makes the mock emit a `bash` tool call.
        # The mock's own keyword table decides that (`RMTEST`/`BASHTEST`), so this
        # measures the real tool path through the shipped `ctx.subprocess`.
        xcrun simctl --set "$SIMSET" launch "$UDID" "$BUNDLE_ID" \
            -DSHPortCMockPort 19719 -DSHPortEStep19SafeProbe 1 \
            -DSHPortEStep19Prompt "BASHTEST
STEP echo STEP19-BASH-OK
STEP id" >/dev/null || { echo "   launch command failed" >&2; return 1; }
        ;;
      guest-tests)
        xcrun simctl --set "$SIMSET" launch "$UDID" "$BUNDLE_ID" \
            -DSHPortCMockPort 19719 -DSHPortEStep19SafeProbe 1 \
            -DSHPortEStep19GuestTests 1 \
            -DSHPortEStep19GuestDir /workspace/step19-guestsrc \
            -DSHPortEStep19Prompt "STEP19 guest node tests" >/dev/null \
            || { echo "   launch command failed" >&2; return 1; }
        ;;
      purge-probe)
        # Ask the app to do what the reset panel's confirmed button does. Only
        # reachable through a launch argument, and only so this criterion has
        # evidence: the panel path is the same `ResetRunner.purgeStaging()`.
        xcrun simctl --set "$SIMSET" launch "$UDID" "$BUNDLE_ID" \
            -DSHPortCMockPort 19719 -DSHPortEStep19PurgeStaging 1 >/dev/null \
            || { echo "   launch command failed" >&2; return 1; }
        ;;
      hold)
        # The page loads and then never declares itself ready. That is the only way
        # to reach the watchdog: a dead port produces a web-view ERROR, which is
        # failure source B's sibling, not the timeout.
        xcrun simctl --set "$SIMSET" launch "$UDID" "$BUNDLE_ID" \
            -DSHPortCMockPort 19719 -DSHPortEStep19HoldReadyMs 240000 >/dev/null \
            || { echo "   launch command failed" >&2; return 1; }
        ;;
      probe-approval)
        # A destructive command under safe mode. `APPROVALTEST` is the mock's script
        # for exactly this: it asks for `rm -rf` on a file it created, then stops.
        # With `ish-approval-policy` kept in REQUIRED this must produce an
        # `approval/asked` event and NOT a `tool/result`; if the plugin had been
        # skipped, the same prompt would run the command (or fail on the pending
        # session surface).
        xcrun simctl --set "$SIMSET" launch "$UDID" "$BUNDLE_ID" \
            -DSHPortCMockPort 19719 -DSHPortEStep19SafeProbe 1 \
            -DSHPortEStep19Prompt "APPROVALTEST rm -rf the file the script created" >/dev/null \
            || { echo "   launch command failed" >&2; return 1; }
        ;;
      probe-normal)
        # The control: the same probe, same build, with the guard in normal mode.
        xcrun simctl --set "$SIMSET" launch "$UDID" "$BUNDLE_ID" \
            -DSHPortCMockPort 19719 -DSHPortEStep19SafeProbe 1 \
            -DSHPortEStep19Prompt "STEP19 normal-mode turn" >/dev/null || { echo "   launch command failed" >&2; return 1; }
        ;;
      *)
        echo "unknown launch mode: $mode" >&2
        return 2
        ;;
    esac
    sleep "$wait_s"
}

case "$ACTION" in
  install)
    [ -d "$APP" ] || { echo "no app at $APP; run scripts/build-app.sh first" >&2; exit 1; }
    xcrun simctl --set "$SIMSET" install "$UDID" "$APP" >/dev/null || { echo "install failed" >&2; exit 1; }
    echo "installed $APP"
    ;;

  fresh)
    [ -d "$APP" ] || { echo "no app at $APP; run scripts/build-app.sh first" >&2; exit 1; }
    xcrun simctl --set "$SIMSET" terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl --set "$SIMSET" uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl --set "$SIMSET" install "$UDID" "$APP" >/dev/null || { echo "install failed" >&2; exit 1; }
    echo "fresh container installed"
    ;;

  fail)
    COUNT="${2:-1}"
    WAIT="${3:-12}"
    [ -d "$APP" ] || { echo "no app at $APP" >&2; exit 1; }
    for n in $(seq 1 "$COUNT"); do
        launch_once fail "fail-$n" "$WAIT"
        guard_summary
        safemode_line
    done
    ;;

  ok)
    WAIT="${2:-16}"
    [ -d "$APP" ] || { echo "no app at $APP" >&2; exit 1; }
    launch_once ok "normal" "$WAIT"
    guard_summary
    safemode_line
    ;;

  probe)
    WAIT="${2:-45}"
    [ -d "$APP" ] || { echo "no app at $APP" >&2; exit 1; }
    launch_once probe "safe-probe" "$WAIT"
    probe_report
    ;;

  probe-bash)
    WAIT="${2:-55}"
    [ -d "$APP" ] || { echo "no app at $APP" >&2; exit 1; }
    launch_once probe-bash "bash-probe" "$WAIT"
    probe_report
    ;;

  guest-tests)
    WAIT="${2:-200}"
    [ -d "$APP" ] || { echo "no app at $APP" >&2; exit 1; }
    launch_once guest-tests "guest-node" "$WAIT"
    F="$(container_path)/Documents/DSHPortE-step19-safe-probe.json"
    if [ -f "$F" ]; then
        python3 - "$F" <<'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
for run in data.get("criteria", {}).get("guest-node") or []:
    print("   %s: exit=%s ms=%s" % (run.get("id"), run.get("exitCode"), run.get("ms")))
    for line in (run.get("stdoutTail") or "").splitlines()[-8:]:
        print("     |", line[:160])
    if run.get("thrown"):
        print("     ! thrown:", run["thrown"][:200])
PYEOF
    else
        echo "   no probe report"
    fi
    ;;

  purge-probe)
    WAIT="${2:-22}"
    [ -d "$APP" ] || { echo "no app at $APP" >&2; exit 1; }
    launch_once purge-probe "purge" "$WAIT"
    R="$(runtime_path)"
    /usr/bin/grep -o "staging holds .*\|已清除上次重置留下的.*\|已清除 [0-9]* 项.*" "$R/DSHPortC-node.log" | tail -4
    echo "   staging entries now: $(ls -1 "$R/reset-staging" 2>/dev/null | wc -l | tr -d ' ')"
    ;;

  hold)
    WAIT="${2:-90}"
    [ -d "$APP" ] || { echo "no app at $APP" >&2; exit 1; }
    launch_once hold "watchdog" "$WAIT"
    guard_summary
    echo "=== boot-outcome.json ==="
    cat "$(runtime_path)/boot/boot-outcome.json" 2>/dev/null || echo absent
    ;;

  probe-approval)
    WAIT="${2:-55}"
    [ -d "$APP" ] || { echo "no app at $APP" >&2; exit 1; }
    launch_once probe-approval "approval-probe" "$WAIT"
    probe_report
    ;;

  probe-normal)
    WAIT="${2:-45}"
    [ -d "$APP" ] || { echo "no app at $APP" >&2; exit 1; }
    launch_once probe-normal "normal-probe" "$WAIT"
    probe_report
    ;;

  guard)
    guard_summary
    safemode_line
    ;;

  park)
    park_state
    ;;

  outcome)
    OUTCOME="$(runtime_path)/boot/boot-outcome.json"
    if [ -f "$OUTCOME" ]; then cat "$OUTCOME"; else echo "boot-outcome.json: absent"; fi
    ;;

  kill)
    xcrun simctl --set "$SIMSET" terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    echo "terminated"
    ;;

  background)
    # `simctl` has no "send to background" verb. Launching another bundle on the
    # same device is the equivalent, and it is what scripts/device-background.sh
    # does too.
    xcrun simctl --set "$SIMSET" launch "$UDID" com.apple.Preferences >/dev/null 2>&1 || true
    sleep 2
    echo "backgrounded (Preferences is in front)"
    ;;

  status)
    STATUS="$(runtime_path)/DSHPortC-status.json"
    if [ -f "$STATUS" ]; then cat "$STATUS"; else echo "status file: absent"; fi
    ;;

  *)
    echo "usage: $0 {install|fresh|fail N [wait]|ok [wait]|probe [wait]|probe-bash [wait]|hold [wait]|purge-probe [wait]|guest-tests [wait]|probe-approval [wait]|probe-normal [wait]|guard|park|outcome|kill|background|status}" >&2
    exit 2
    ;;
esac
