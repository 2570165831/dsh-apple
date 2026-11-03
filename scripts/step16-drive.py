#!/usr/bin/env python3
"""Evaluate one JavaScript expression in the running app's own web view.

WHY THIS EXISTS, AND WHY IT IS NOT A TEST HOOK ON THE FEATURE
-------------------------------------------------------------
Three of step 16's acceptance steps have to act on an app that is ALREADY RUNNING and
already mid-turn: answer an approval after the ask has been observed, press stop in
the middle of a turn, and read back which session the page has selected. None of them
has an external trigger, and none can be driven by a launch argument — the argument is
read once at start, and relaunching to deliver it would destroy the state being
measured.

`xcodebuild test` could tap them, but it cannot see this task's custom simulator
device set (REPORT-13 §7 measured that), and step 16's criteria are about the device
this task owns. So the press is driven through the app's own web view, the same
`evaluateJavaScript` that `InteractionProbe` (step 11) and `PadProbe` (step 10) already
use for their own measurements. The channel is a command file inside the app's
Documents directory, and the app only polls it when launched with
`-DSHPortENotifyDrive 1`.

WHAT IT PROVES AND WHAT IT DOES NOT
-----------------------------------
It proves the app's reaction to a press: answering an approval withdraws the delivered
notification, stopping a turn produces no notification, a navigation lands on the
right session. It does NOT prove the press is reachable by a finger. That is the
XCUITest run's job, and REPORT-16 keeps the two apart.

Usage
    scripts/step16-drive.py --udid UDID --script '(function(){ return "hi"; })()'
    scripts/step16-drive.py --udid UDID --action answer-approval
    scripts/step16-drive.py --udid UDID --action stop-turn
    scripts/step16-drive.py --udid UDID --action press-row:SESSION_ID
    scripts/step16-drive.py --udid UDID --action read-selection

Exit status 0 when a result arrived; 1 on timeout or a missing app container.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUNDLE_ID = "local.dshportc.app"
SIMSET = ROOT / "simdevices"
ENV = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}

# The action names must match what the app accepts: the app evaluates the script it
# is handed, so these three are built here rather than being an enum on both sides.
# That keeps the app's channel one thing (evaluate this) and puts the knowledge of
# what to press where the assertion is.
ACTIONS = {
    # `允许一次` is the approval dialog's own label (`dsh-client-ui-approval`'s
    # dictionary, `allowOnce`). Pressing it is exactly what a finger does.
    "answer-approval": r"""
    (function () {
      const labels = ['允许一次', 'Allow once'];
      for (const el of Array.from(document.querySelectorAll('button,[role="button"]'))) {
        const text = (el.innerText || '').trim();
        const label = el.getAttribute('aria-label') || '';
        if (labels.some((w) => text === w || label === w)) {
          for (const type of ['pointerdown', 'pointerup', 'click']) {
            el.dispatchEvent(new PointerEvent(type, {
              bubbles: true, cancelable: true, pointerType: 'touch', pointerId: 1, isPrimary: true,
            }));
          }
          return 'pressed:' + (text || label);
        }
      }
      return 'not-found';
    })();
    """,
    # `停止生成` is the composer's own label for the stop control
    # (`dsh-client-ui-conversation`'s dictionary, `input.stop`).
    "stop-turn": r"""
    (function () {
      const labels = ['停止生成', 'Stop generating'];
      for (const el of Array.from(document.querySelectorAll('button,[role="button"]'))) {
        const text = (el.innerText || '').trim();
        const label = el.getAttribute('aria-label') || '';
        if (labels.some((w) => text === w || label === w || label.indexOf(w) >= 0)) {
          for (const type of ['pointerdown', 'pointerup', 'click']) {
            el.dispatchEvent(new PointerEvent(type, {
              bubbles: true, cancelable: true, pointerType: 'touch', pointerId: 1, isPrimary: true,
            }));
          }
          return 'pressed:' + (text || label);
        }
      }
      return 'not-found';
    })();
    """,
    # The selection the workspace service persists, which is the page's own answer to
    # "which session is open".
    # The exact error text `NotificationNavigation` returns, used to tell "the page said
    # no" from "the page answered something unexpected".
    "read-selection": r"""
    (function () {
      try {
        const raw = localStorage.getItem('dsh.sessions.current');
        if (raw === null) return '';
        const parsed = JSON.parse(raw);
        return typeof parsed.sessionId === 'string' ? parsed.sessionId : '';
      } catch (e) { return ''; }
    })();
    """,

}

# A `press-row:` action presses the sidebar row, opening the drawer first if the row
# is not in the DOM. The same sequence `NotificationNavigation` uses, so a tap and this
# path cannot disagree about what "opening a session" means.
PRESS_ROW = r"""
(function () {
  const wanted = __SESSION__;
  const key = 'session:' + wanted;
  const row = Array.from(document.querySelectorAll('[data-row-key]'))
    .find((el) => (el.getAttribute('data-row-key') || '') === key);
  if (row !== null && row !== undefined) {
    if (row.getAttribute('aria-selected') === 'true') return 'already-selected';
    row.scrollIntoView({ block: 'nearest' });
    for (const type of ['pointerdown', 'pointerup', 'click']) {
      row.dispatchEvent(new PointerEvent(type, {
        bubbles: true, cancelable: true, pointerType: 'touch', pointerId: 1, isPrimary: true,
      }));
    }
    return 'pressed';
  }
  const labels = ['打开侧边栏', 'Open sidebar'];
  for (const button of Array.from(document.querySelectorAll('button,[role="button"]'))) {
    const label = button.getAttribute('aria-label') || '';
    const text = (button.innerText || '').trim();
    if (labels.some((w) => label.indexOf(w) >= 0 || text === w)) {
      for (const type of ['pointerdown', 'pointerup', 'click']) {
        button.dispatchEvent(new PointerEvent(type, {
          bubbles: true, cancelable: true, pointerType: 'touch', pointerId: 1, isPrimary: true,
        }));
      }
      return 'drawer-opening';
    }
  }
  return 'no-row';
})();
"""


# WHICH DEVICE SET, decided per UDID rather than by a flag: this script is called with
# a device id from either set, and asking `simctl` which set knows the id is cheaper and
# less error-prone than making every caller pass the same choice through twice.
def simctl(*args, **kwargs):
    return subprocess.run(
        ["xcrun", "simctl", "--set", str(SIMSET), *args],
        capture_output=True, text=True, env=ENV, **kwargs,
    )


def simctl_any(udid: str, *args, **kwargs):
    """`simctl` in whichever set owns `udid`."""
    custom = simctl("list", "devices")
    if udid not in custom.stdout:
        return subprocess.run(
            ["xcrun", "simctl", *args], capture_output=True, text=True, env=ENV, **kwargs)
    return subprocess.run(
        ["xcrun", "simctl", "--set", str(SIMSET), *args],
        capture_output=True, text=True, env=ENV, **kwargs)


def container(udid: str) -> Path:
    out = simctl_any(udid, "get_app_container", udid, BUNDLE_ID, "data")
    if out.returncode != 0:
        raise SystemExit(f"no app container for {BUNDLE_ID} on {udid}: {out.stderr.strip()}")
    return Path(out.stdout.strip())


def scripts_for(action: str) -> list[str]:
    """One action can be several attempts: a drawer takes a moment to open."""
    if action.startswith("press-row:"):
        session = action.split(":", 1)[1]
        quoted = json.dumps(session)
        return [PRESS_ROW.replace("__SESSION__", quoted)] * 10
    if action in ACTIONS:
        # Repeating is how a transient DOM state is tolerated; the app returns
        # `not-found` and the next attempt tries again.
        return [ACTIONS[action]] * 10
    raise SystemExit(f"unknown action {action!r}; known: {sorted(ACTIONS)} or press-row:<id>")


def run(udid: str, script: str | None, timeout: float, tap: str | None = None) -> str:
    documents = container(udid) / "Documents"
    command = documents / "DSHPortENotifyCommand.json"
    result = documents / "DSHPortENotifyResult.json"
    identifier = uuid.uuid4().hex
    # A stale result from an earlier call must not be mistaken for this one's, which is
    # why the id is compared rather than the file merely existing.
    try:
        result.unlink()
    except OSError:
        pass
    payload: dict = {"id": identifier}
    if tap is not None:
        payload["tap"] = tap
    if script is not None:
        payload["script"] = script
    command.write_text(json.dumps(payload))

    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            payload = json.loads(result.read_text())
        except (OSError, json.JSONDecodeError):
            payload = {}
        if payload.get("id") == identifier:
            return str(payload.get("result", ""))
        time.sleep(0.2)
    raise SystemExit(f"the app did not answer within {timeout:.0f}s; "
                     f"is it running with -DSHPortENotifyDrive 1?")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--udid", required=True)
    parser.add_argument("--script", default="")
    parser.add_argument("--action", default="")
    parser.add_argument("--tap", default="", help="session id to route a simulated notification tap to")
    parser.add_argument("--timeout", type=float, default=25.0)
    parser.add_argument("--attempts", type=int, default=0,
                        help="repeat until the result is not not-found/no-row")
    args = parser.parse_args()

    if args.script:
        print(run(args.udid, args.script, args.timeout))
        return 0
    if args.tap:
        print(run(args.udid, None, args.timeout, tap=args.tap))
        return 0
    if not args.action:
        raise SystemExit("one of --script, --action or --tap is required")

    attempts = args.attempts or 1
    last = ""
    for attempt in range(1, attempts + 1):
        for script in scripts_for(args.action):
            last = run(args.udid, script, args.timeout)
            if last not in ("not-found", "no-row", "drawer-opening"):
                print(last)
                return 0
        if attempt < attempts:
            time.sleep(1.0)
    print(last)
    return 0 if last not in ("not-found", "no-row") else 1


if __name__ == "__main__":
    sys.exit(main())
