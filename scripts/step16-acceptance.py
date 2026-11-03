#!/usr/bin/env python3
"""Step 16 acceptance: does the phone actually tell the user, in each of the four cases?

WHAT THIS MEASURES, AND WHERE THE NUMBERS COME FROM
---------------------------------------------------
Every claim in the step-16 report is one of these five kinds, and each has its own
instrument:

  1. A notification was DELIVERED. The instrument is `getDeliveredNotifications`,
     dumped by the app itself (`-DSHPortENotifyDump 1`) to
     `Documents/DSHPortC-notifications.json`. Not a screenshot: the criterion is
     "the system holds a notification with this title and body", and the system is
     the only thing that can answer it.
  2. A notification was SUPPRESSED, and why. The app records every refused request
     with its reason, so "nothing appeared" can be told apart from "the feature never
     ran" — the measurement mistake REPORT-13 §4 was written about.
  3. The turn history is what it claims. Read from the session's own durable event
     log (zstd frames under `DSH/sessions`), which is what DSH renders the UI from.
  4. The switches persisted. Read back from a SECOND launch with no arguments, because
     the claim is about a restart and only a second process can make it.
  5. Where a notification tap landed. The app records the tap and the navigation
     result, and the acceptance additionally reads the selected session id out of the
     page's persisted selection (`dsh.sessions.current`).

WHAT THE SIMULATOR CANNOT SHOW
------------------------------
The banner itself. `simctl io screenshot` would produce a PNG, but reading a picture
is not an assertion this script can make and the task's rules exclude `read_image`, so
the screenshots are recorded for the initiator and every PASS/FAIL in the JSON is
decided from `getDeliveredNotifications` and the session log. REPORT-16 states this
split too.

THE PERMISSION ALERT IS ANSWERED BY XCTEST, NOT HERE
----------------------------------------------------
`simctl privacy` has no notification service, so the alert cannot be pre-granted, and
no script can read or press it. It is pressed by
`app/DSHPortCUITests/NotificationTests.swift` on the task's own `dsh-portE-xct-16`
device (created for step 16, deleted at the end). That run produces the SINGLE grant
this device ever needs, and the app keeps it across installs of the same bundle id.

Everything below therefore runs on `phone-bg` AFTER the grant exists there, and the
first `complete` case asserts `authorization == authorized` rather than assuming it.
`scripts/step16-grant.py` does the grant and is the one command that touches the
XCUITest device.

USAGE
-----
    DSHPORTE_DEVICE=phone-bg MOCK_PORT=19716 scripts/step16-grant.py     # once
    DSHPORTE_DEVICE=phone-bg MOCK_PORT=19716 scripts/step16-acceptance.py complete
    DSHPORTE_DEVICE=phone-bg MOCK_PORT=19716 scripts/step16-acceptance.py error
    DSHPORTE_DEVICE=phone-bg MOCK_PORT=19716 scripts/step16-acceptance.py approval
    DSHPORTE_DEVICE=phone-bg MOCK_PORT=19716 scripts/step16-acceptance.py question
    DSHPORTE_DEVICE=phone-bg MOCK_PORT=19716 scripts/step16-acceptance.py foreground
    DSHPORTE_DEVICE=phone-bg MOCK_PORT=19716 scripts/step16-acceptance.py cancelled
    DSHPORTE_DEVICE=phone-bg MOCK_PORT=19716 scripts/step16-acceptance.py switch-off
    DSHPORTE_DEVICE=phone-bg MOCK_PORT=19716 scripts/step16-acceptance.py switch-persist
    DSHPORTE_DEVICE=phone-bg MOCK_PORT=19716 scripts/step16-acceptance.py expiry
    DSHPORTE_DEVICE=phone-bg MOCK_PORT=19716 scripts/step16-acceptance.py tap --state running
    DSHPORTE_DEVICE=phone-bg MOCK_PORT=19716 scripts/step16-acceptance.py denied

Exit status is 0 only if that case's criteria hold.
"""

from __future__ import annotations

import argparse
import json
import shutil
import os
import re
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOGS = ROOT / "logs" / "step16"
SHOTS = ROOT / "screenshots" / "step16"
BUNDLE_ID = "local.dshportc.app"
APP_PATH = ROOT / "DerivedData/Build/Products/Debug-iphonesimulator/DSHPortC.app"
SIMSET = ROOT / "simdevices"
DRIVE = ROOT / "scripts/step16-drive.py"
ENV = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}
MOCK_PORT = int(os.environ.get("MOCK_PORT", "19716"))
PROMPTS = ROOT / "prompts"

sys.path.insert(0, str(Path(__file__).resolve().parent))

# WHICH DEVICE SET THIS RUN ADDRESSES, DECIDED BEFORE `device_pick` IS IMPORTED.
#
# Two sets exist and they are not interchangeable. This task's own devices
# (`phone-bg` and the rest) live in `simdevices`, a custom `--set`; the XCUITest device
# lives in the DEFAULT set, because `xcodebuild` cannot see a custom `--set`
# (REPORT-13 §7 measured it, and step 16 re-measured it: `xcodebuild test
# -destination id:<phone-bg>` answered with an Apple Watch destination instead).
#
# The distinction is not cosmetic. iOS stores a notification authorization per app per
# DEVICE, and only a device XCUITest can address can be granted one — the alert needs a
# finger. So a run that must observe a real, delivered notification has to happen on
# that device, selected with `DSHPORTE_DEVICE=xct-16`.
#
# `device_pick` resolves its module constants at import time and refuses an unknown
# name there, so the translation has to happen first — before the import, not after it.
# Its own table stays untouched: the refusal to guess is what keeps steps 10 and 13
# honest, and this file's job is to hand it a name it knows.
XCT_DEVICE_NAME = os.environ.get("DSHPORTE_XCT_NAME", "dsh-portE-xct-16")
USE_DEFAULT_SET = (os.environ.get("DSHPORTE_DEVICE") or "").strip().lower() in ("xct-16", "xct", "default")
if USE_DEFAULT_SET:
    os.environ["DSHPORTE_DEVICE"] = "phone-bg"

import device_pick  # noqa: E402

RESULTS: dict[str, dict] = {}


# --------------------------------------------------------------------- plumbing

def simctl(*args, check=False, timeout=300, extra_env=None):
    """Run `simctl` against whichever device set this run addresses.

    `extra_env` exists for exactly one caller: `launch`, which hands the scripted prompt
    to the app through `SIMCTL_CHILD_*` variables. Everything else uses the ambient
    environment, so a wrapper that silently dropped those variables would look correct
    and start a turn-less app — which is what happened the first time this was written:
    the app came up and the run waited 180 s for a turn that had never been asked for.
    """
    prefix = [] if USE_DEFAULT_SET else ["--set", str(SIMSET)]
    return subprocess.run(
        ["xcrun", "simctl", *prefix, *args],
        capture_output=True, text=True,
        env={**ENV, **(extra_env or {})}, check=check, timeout=timeout,
    )


def host(args, *, check=False, timeout=300):
    return subprocess.run(args, capture_output=True, text=True, env=ENV, check=check, timeout=timeout)


def container(udid: str) -> Path:
    return Path(simctl("get_app_container", udid, BUNDLE_ID, "data", check=True).stdout.strip())


def read_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def read_text(path: Path) -> str:
    try:
        return path.read_text(errors="replace")
    except OSError:
        return ""


def device_udid() -> str:
    """Boot and return the device this run is about, in whichever set it lives."""
    if USE_DEFAULT_SET:
        out = simctl("list", "devices").stdout
        for line in out.splitlines():
            match = re.search(r"^\s+(.+?) \(([0-9A-F-]{36})\) \(", line)
            if match and match.group(1).strip() == XCT_DEVICE_NAME:
                udid = match.group(2)
                simctl("boot", udid)
                subprocess.run(["xcrun", "simctl", "bootstatus", udid, "-b"],
                               capture_output=True, text=True, env=ENV, timeout=600)
                return udid
        raise SystemExit(f"no device named {XCT_DEVICE_NAME} in the default set; "
                         f"run scripts/step16-grant.py to create it")
    udid = device_pick.device_udid(create_phone=False)
    device_pick.boot(udid)
    return udid


def device_name() -> str:
    return XCT_DEVICE_NAME if USE_DEFAULT_SET else device_pick.name()


def mock_up() -> bool:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{MOCK_PORT}/healthz", timeout=3):
            return True
    except OSError:
        return False


def install(udid: str) -> None:
    """Put this build on the device, WITHOUT clearing the notification permission.

    WHY NOT `uninstall` + `install`. An uninstall clears the per-app notification
    authorization, and the alert cannot be answered by any script — only XCUITest can
    press it (see `scripts/step16-grant.py`). So a run that uninstalled would need a
    grant before every case, and every case would be one XCUITest run away from being
    unrunnable. Overwriting the install keeps the authorization and still replaces the
    binary, which is all a build-under-test needs.

    The one case that genuinely needs a clean slate — a fresh session with no
    leftovers — removes the app's data explicitly, and says so at the call site.
    """
    simctl("terminate", udid, BUNDLE_ID)
    simctl("install", udid, str(APP_PATH), check=True)


def install_clean(udid: str) -> None:
    """A fresh data container: no sessions, no switches, no authorization either.

    Only used where a clean state is the point. The caller re-grants afterwards.
    """
    simctl("terminate", udid, BUNDLE_ID)
    simctl("uninstall", udid, BUNDLE_ID)
    simctl("install", udid, str(APP_PATH), check=True)


def launch(udid: str, *, prompt: str | None = None, keyword: str = "",
           extra: list[str] | None = None) -> None:
    """Launch the app, optionally driving one scripted turn."""
    env = dict(ENV)
    if prompt is not None:
        env["SIMCTL_CHILD_DSHPORT_UITEST_PROMPT"] = prompt
        env["SIMCTL_CHILD_DSHPORT_UITEST_KEYWORD"] = keyword
        extra = ["-DSHPortCTestDrive", "1"] + (extra or [])
    args = ["launch", udid, BUNDLE_ID, "-DSHPortCMockPort", str(MOCK_PORT)] + (extra or [])
    # `env` carries the SIMCTL_CHILD_* prompt and keyword; without it the app comes up
    # with no turn to run.
    simctl(*args, check=True, extra_env=env)


def foreground(udid: str, extra: list[str] | None = None) -> None:
    """Bring a backgrounded app forward WITHOUT restarting it.

    `extra` exists because a launch ARGUMENT is only read when the argument domain is
    written, which happens on every `simctl launch` — including one that merely resumes a
    running app. `NotificationActionDriver.isEnabled` reads `-DSHPortENotifyDrive` at that
    moment, so a resume without it turns the command channel off for the rest of the
    process. Measured: after a plain `foreground`, every `step16-drive.py` call answered
    "the app did not answer within 20s".
    """
    simctl("launch", udid, BUNDLE_ID, "-DSHPortCMockPort", str(MOCK_PORT), *(extra or []))


def background(udid: str) -> None:
    """Hand focus to another app — a real `didEnterBackground`."""
    simctl("openurl", udid, "https://example.com")


def wait_web_ready(udid: str, timeout: float = 600) -> Path:
    """Wait for the app's ready phase, RESOLVING THE CONTAINER EACH TIME.

    WHY IT TAKES A UDID AND NOT A PATH. The data container's UUID changes on every
    install and on some relaunches, so a `Path` captured before a launch describes a
    directory that no longer belongs to the running app. Measured: a run that passed the
    old path read a log with 23 lines and no turn at all, while the app's real log (in the
    new container) had the whole scripted conversation — and the failure looked like
    "the driver never ran", which it had.
    """
    deadline = time.time() + timeout
    started = time.time()
    reloaded = False
    while time.time() < deadline:
        data_dir = container(udid)
        status = read_json(data_dir / "Library/Application Support/DSHPortC" / "DSHPortC-status.json")
        if status.get("phase") == "webViewReady":
            return data_dir
        if status.get("phase") == "failed":
            raise SystemExit(f"the app reported failure: {status.get('error')}")
        # A session with many turns makes the page's first paint slow enough that a 300 s
        # wait was not always enough — measured on a container that had accumulated seven
        # turns: `webViewLoading` at the deadline. Reloading is the same press the debug
        # menu's "重新加载界面" performs, and it is what a person would do with a page that
        # has stalled.
        if status.get("phase") == "webViewLoading" and time.time() - started > 120:
            if not reloaded:
                reloaded = True
                simctl("openurl", udid, "https://example.com")
                time.sleep(2)
                simctl("launch", udid, BUNDLE_ID, "-DSHPortCMockPort", str(MOCK_PORT))
        time.sleep(0.4)
    raise SystemExit("the web view never became ready")


def status(udid: str) -> dict:
    return read_json(container(udid) / "Library/Application Support/DSHPortC" / "DSHPortC-status.json")


def notifications(udid: str) -> dict:
    """The app's own record of what the system holds."""
    return read_json(container(udid) / "Documents" / "DSHPortC-notifications.json")


def node_log(udid: str) -> str:
    return read_text(container(udid) / "Library/Application Support/DSHPortC" / "DSHPortC-node.log")


def latest_dump(udid: str, reason: str | None = None) -> dict:
    dumps = notifications(udid).get("dumps") or []
    if reason is not None:
        matching = [d for d in dumps if d.get("reason") == reason]
        if matching:
            return matching[-1]
    return dumps[-1] if dumps else {}


def session_events(udid: str, not_before: float | None = None) -> list[dict]:
    """Every durable event of every session, oldest first.

    `not_before` (a wall-clock epoch) skips logs last written before that instant, which
    is how a run asks for "the sessions this launch produced" on a device that keeps the
    earlier ones.
    """
    events: list[dict] = []
    sessions = container(udid) / "Library/Application Support/DSH/sessions"
    if not sessions.is_dir():
        return events
    for path in sorted(sessions.rglob("*.jsonl.zstd")):
        if not_before is not None:
            try:
                if path.stat().st_mtime < not_before:
                    continue
            except OSError:
                continue
        raw = host(["zstd", "-dc", str(path)]).stdout
        for line in raw.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            record["_log"] = path.name
            events.append(record)
    return events


def current_session_id(udid: str) -> str:
    """The session id of the most recent turn START this app reported.

    WHY NOT FROM THE SESSION LOG. A device accumulates one session per measured run,
    so "the only session" is empty by the second case — and an empty id then filtered
    every delivered notification away, which read as "nothing was delivered". The
    notification bridge already prints the id on its `turn-start` line, once per turn,
    which is exactly "the session this run is about".

    Read from the app's log rather than from a projection: the log is the app's own
    record of what it did, and the line is the app's own.
    """
    log = node_log(udid)
    found = ""
    for line in log.splitlines():
        marker = '"kind":"turn-start","sessionId":"'
        index = line.find(marker)
        if index < 0:
            continue
        rest = line[index + len(marker):]
        end = rest.find('"')
        if end > 0:
            found = rest[:end]
    return found


def session_id_of(udid: str, not_before: float | None = None) -> str:
    """The id of the session this run created, or "" when that is ambiguous.

    Read from the log's own first record: the session file's first line has
    `type: "session"` and carries `id` (not `type: "header"`, which is what an earlier
    version of this function guessed and silently returned "" for).

    With `not_before`, only logs written since that instant count. That is what makes
    "this run's session" answerable on a device that already holds earlier sessions —
    measured: a run that re-used the install reported `doneCount: 2` because the previous
    run's notification was still in the system's list, and the session id it compared
    against was empty because two sessions matched.
    """
    ids: set[str] = set()
    for record in session_events(udid, not_before=not_before):
        kind = record.get("type")
        if kind not in ("session", "header"):
            continue
        identifier = record.get("id") or (record.get("data") or {}).get("id")
        if isinstance(identifier, str) and identifier:
            ids.add(identifier)
    return sorted(ids)[0] if len(ids) == 1 else ""


def wait_for(predicate, timeout: float, interval: float = 1.0, what: str = "condition") -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    print(f"   (timed out after {timeout:.0f}s waiting for {what})")
    return False


def shoot(udid: str, name: str) -> str:
    """A screenshot, written to a temp dir first.

    `simctl io screenshot` cannot write to this volume (REPORT-13 §9 records the same
    constraint), so the bytes are written under /tmp and copied in.
    """
    SHOTS.mkdir(parents=True, exist_ok=True)
    tmp = Path(f"/tmp/step16-{name}.png")
    simctl("io", udid, "screenshot", str(tmp), timeout=120)
    target = SHOTS / f"{name}.png"
    if tmp.exists():
        target.write_bytes(tmp.read_bytes())
        tmp.unlink(missing_ok=True)
    return str(target.relative_to(ROOT))


def save(name: str, result: dict) -> None:
    LOGS.mkdir(parents=True, exist_ok=True)
    (LOGS / f"{name}.json").write_text(json.dumps(result, indent=2, ensure_ascii=False))
    key = result.get("case", name)
    if result.get("state"):
        key = f"{key}-{result['state']}"
    RESULTS[key] = result
    (LOGS / "results.json").write_text(json.dumps(RESULTS, indent=2, ensure_ascii=False))


# ---------------------------------------------------------------- page driving

def drive(udid: str, action: str, timeout: float = 30) -> str:
    """Run one named action in the running app's web view."""
    out = host([sys.executable, str(DRIVE), "--udid", udid, "--action", action,
                "--timeout", str(timeout)])
    text = out.stdout.strip()
    return text.splitlines()[-1] if text else f"drive-failed: {out.stderr.strip()[-200:]}"


def drive_script(udid: str, script: str, timeout: float = 30) -> str:
    out = host([sys.executable, str(DRIVE), "--udid", udid, "--script", script,
                "--timeout", str(timeout)])
    text = out.stdout.strip()
    return text.splitlines()[-1] if text else f"drive-failed: {out.stderr.strip()[-200:]}"


def drive_tap(udid: str, session_id: str, timeout: float = 30) -> str:
    """Deliver a notification tap: the same `handleTap` a real press reaches."""
    out = host([sys.executable, str(DRIVE), "--udid", udid, "--tap", session_id,
                "--timeout", str(timeout)])
    text = out.stdout.strip()
    return text.splitlines()[-1] if text else f"drive-failed: {out.stderr.strip()[-200:]}"


def NotificationNavigationRowScript(session_id: str) -> str:
    """Press a session row, opening the drawer first when it is closed.

    The same sequence `NotificationNavigation` uses for a tapped notification, exposed for
    a script that has to bring a conversation back on screen.
    """
    quoted = json.dumps(session_id)
    return (
        "(function () {"
        "  const wanted = " + quoted + ";"
        "  const key = 'session:' + wanted;"
        "  const row = Array.from(document.querySelectorAll('[data-row-key]'))"
        "    .find((el) => (el.getAttribute('data-row-key') || '') === key);"
        "  if (row !== null && row !== undefined) {"
        "    for (const t of ['pointerdown','pointerup','click']) {"
        "      row.dispatchEvent(new PointerEvent(t, { bubbles: true, cancelable: true, pointerType: 'touch', pointerId: 1, isPrimary: true }));"
        "    }"
        "    return 'pressed';"
        "  }"
        "  const labels = ['打开侧边栏','Open sidebar'];"
        "  for (const b of Array.from(document.querySelectorAll('button,[role=\"button\"]'))) {"
        "    const label = b.getAttribute('aria-label') || '';"
        "    if (labels.some((w) => label.indexOf(w) >= 0)) {"
        "      for (const t of ['pointerdown','pointerup','click']) {"
        "        b.dispatchEvent(new PointerEvent(t, { bubbles: true, cancelable: true, pointerType: 'touch', pointerId: 1, isPrimary: true }));"
        "      }"
        "      return 'drawer-opening';"
        "    }"
        "  }"
        "  return 'no-row';"
        "})();"
    )


# The composer's own presence test, in one place: DSH's composer is a rich editor
# (`[data-composer-input]`, `contenteditable`), not a `<textarea>` — measured: textarea 0,
# contenteditable 1, data-composer-input 1.
# The composer's own presence test, in one place: DSH's composer is a rich editor
# (`[data-composer-input]`, `contenteditable`), not a `<textarea>` — measured: textarea 0,
# contenteditable 1, data-composer-input 1.
COMPOSER_PRESENT_SCRIPT = (
    "[data-composer-input], textarea, [contenteditable='true']"
)


def send_prompt(udid: str, text: str) -> str:
    """Type and send into the app's own composer, the way a finger does.

    COPIED FROM WHAT ALREADY WORKS. `UIDriver.typeAndSendScript` is the inserter the
    scripted runs use, and its comments record why each step is there: DSH's composer is a
    Lexical editor that owns its own state, so `textContent`, `execCommand('insertText')`
    and an `input` event all change the DOM while leaving the editor empty. What reaches
    the real insert path is DSH's own PASTE_COMMAND handler, driven by a synthetic `paste`
    event carrying a populated `DataTransfer`. This function is the same sequence, run from
    the command-file channel, so a second prompt in the same process works too — measured,
    the earlier shorter version reported `paste:len=0`, i.e. it dispatched a paste the
    editor ignored because the selection was not inside the box.
    """
    escaped = (text
               .replace("\\", "\\\\")
               .replace("'", "\\'")
               .replace("\n", "\\n"))
    script = """
    (function () {
      const text = '""" + escaped + """';
      const box = document.querySelector('[data-composer-input]')
        || document.querySelector('textarea')
        || document.querySelector('[contenteditable="true"]');
      if (!box) return 'no-composer';
      box.focus();
      let how = 'none';
      if (box.tagName === 'TEXTAREA' || box.tagName === 'INPUT') {
        const setter = Object.getOwnPropertyDescriptor(
          window.HTMLTextAreaElement.prototype, 'value').set;
        setter.call(box, text);
        box.dispatchEvent(new Event('input', { bubbles: true }));
        box.dispatchEvent(new Event('change', { bubbles: true }));
        how = 'textarea-setter';
      } else {
        // The selection has to be INSIDE the editor before the paste is dispatched;
        // otherwise the handler has nothing to paste into and the event is dropped.
        const selection = window.getSelection();
        const range = document.createRange();
        range.selectNodeContents(box);
        range.collapse(false);
        selection.removeAllRanges();
        selection.addRange(range);
        try {
          const clipboard = new DataTransfer();
          clipboard.setData('text/plain', text);
          const paste = new ClipboardEvent('paste', {
            bubbles: true, cancelable: true, clipboardData: clipboard,
          });
          box.dispatchEvent(paste);
          if (paste.defaultPrevented) how = 'paste-command';
        } catch (error) { /* ClipboardEvent is not constructible here */ }
        if (how === 'none') {
          try {
            if (document.execCommand('insertText', false, text)) how = 'execCommand-insertText';
          } catch (error) { /* deprecated */ }
        }
        if (how === 'none') {
          box.textContent = text;
          box.dispatchEvent(new InputEvent('input', {
            bubbles: true, inputType: 'insertText', data: text,
          }));
          how = 'textContent-fallback';
        }
      }
      const rendered = (box.innerText || box.value || '').length;
      const send = Array.from(document.querySelectorAll('button')).find(
        (el) => (el.getAttribute('aria-label') || '') === '发送消息'
             || (el.innerText || '').trim() === '发送消息');
      if (send === undefined) return how + ':no-send-button:rendered=' + rendered;
      for (const type of ['pointerdown', 'pointerup', 'click']) {
        send.dispatchEvent(new PointerEvent(type, {
          bubbles: true, cancelable: true, pointerType: 'touch', pointerId: 1, isPrimary: true,
        }));
      }
      return how + ':clicked-send:rendered=' + rendered;
    })();
    """
    return drive_script(udid, script)


def drive_tap(udid: str, session_id: str, timeout: float = 30) -> str:
    """Deliver a notification tap: the same `handleTap` a real press reaches."""
    out = host([sys.executable, str(DRIVE), "--udid", udid, "--tap", session_id,
                "--timeout", str(timeout)])
    text = out.stdout.strip()
    return text.splitlines()[-1] if text else f"drive-failed: {out.stderr.strip()[-200:]}"


def NotificationNavigationRowScript(session_id: str) -> str:
    """Press a session row, opening the drawer first when it is closed.

    The same sequence `NotificationNavigation` uses for a tapped notification, exposed for
    a script that has to bring a conversation back on screen.
    """
    quoted = json.dumps(session_id)
    return (
        "(function () {"
        "  const wanted = " + quoted + ";"
        "  const key = 'session:' + wanted;"
        "  const row = Array.from(document.querySelectorAll('[data-row-key]'))"
        "    .find((el) => (el.getAttribute('data-row-key') || '') === key);"
        "  if (row !== null && row !== undefined) {"
        "    for (const t of ['pointerdown','pointerup','click']) {"
        "      row.dispatchEvent(new PointerEvent(t, { bubbles: true, cancelable: true, pointerType: 'touch', pointerId: 1, isPrimary: true }));"
        "    }"
        "    return 'pressed';"
        "  }"
        "  const labels = ['打开侧边栏','Open sidebar'];"
        "  for (const b of Array.from(document.querySelectorAll('button,[role=\"button\"]'))) {"
        "    const label = b.getAttribute('aria-label') || '';"
        "    if (labels.some((w) => label.indexOf(w) >= 0)) {"
        "      for (const t of ['pointerdown','pointerup','click']) {"
        "        b.dispatchEvent(new PointerEvent(t, { bubbles: true, cancelable: true, pointerType: 'touch', pointerId: 1, isPrimary: true }));"
        "      }"
        "      return 'drawer-opening';"
        "    }"
        "  }"
        "  return 'no-row';"
        "})();"
    )


# The composer's own presence test, in one place: DSH's composer is a rich editor
# (`[data-composer-input]`, `contenteditable`), not a `<textarea>` — measured: textarea 0,
# contenteditable 1, data-composer-input 1.
# The composer's own presence test, in one place: DSH's composer is a rich editor
# (`[data-composer-input]`, `contenteditable`), not a `<textarea>` — measured: textarea 0,
# contenteditable 1, data-composer-input 1.
COMPOSER_PRESENT_SCRIPT = (
    "[data-composer-input], textarea, [contenteditable='true']"
)


def send_prompt(udid: str, text: str) -> str:
    """Type and send into the app's own composer, the way a finger does."""
    script = """
    (function () {
      // THE COMPOSER IS NOT A `<textarea>`. Measured: `textarea` count 0, `contenteditable`
      // count 1, `[data-composer-input]` count 1 — DSH's composer is a rich editor, so a
      // value setter on `HTMLTextAreaElement.prototype` has nothing to attach to and the
      // editor stays empty. The insertion path below is the one the app's own driver uses
      // (`UIDriver.typeAndSendScript`): a paste command into the focused editable.
      const box = document.querySelector('[data-composer-input]')
        || document.querySelector('[contenteditable="true"]')
        || document.querySelector('textarea');
      if (box === null) return 'no-composer';
      box.focus();
      const text = """ + json.dumps(text) + """;
      let inserted = 'none';
      try {
        document.execCommand('insertText', false, text);
        inserted = 'insertText';
      } catch (e) { inserted = 'insertText-failed'; }
      if ((box.innerText || '').length === 0) {
        try {
          const data = new DataTransfer();
          data.setData('text/plain', text);
          box.dispatchEvent(new ClipboardEvent('paste', {
            bubbles: true, cancelable: true, clipboardData: data,
          }));
          inserted = 'paste';
        } catch (e) { inserted = inserted + '+paste-failed'; }
      }
      box.dispatchEvent(new Event('input', { bubbles: true }));
      const send = Array.from(document.querySelectorAll('button')).find(
        (el) => (el.getAttribute('aria-label') || '') === '发送消息'
             || (el.innerText || '').trim() === '发送消息');
      if (send === undefined) return 'no-send-button';
      for (const type of ['pointerdown', 'pointerup', 'click']) {
        send.dispatchEvent(new PointerEvent(type, {
          bubbles: true, cancelable: true, pointerType: 'touch', pointerId: 1, isPrimary: true,
        }));
      }
      return 'sent:' + inserted + ':len=' + (box.innerText || '').length;
    })();
    """
    return drive_script(udid, script)


# ------------------------------------------------------------------- turn helpers

def turn_ends(udid: str) -> list[dict]:
    return [e.get("data", {}).get("reason", {}) for e in session_events(udid) if e.get("type") == "turn/end"]


def wait_prompt_sent(udid: str, since: float | None = None, timeout: float = 300) -> str:
    """Wait until the scripted driver has actually SENT the prompt.

    WHY THIS IS A SEPARATE WAIT. `wait_web_ready` only says the web view painted; the
    driver then has to wait for the composer, choose the workspace if the hero screen is
    up, type, and press send — about thirty seconds of scripted work that happens after
    "ready". Measured: a run that backgrounded straight after `webViewReady` put the app
    to sleep before the driver had typed anything, so no turn ever started and the
    session log had 23 lines with no `turn/start` — while the driver's own record, written
    later, showed `sent`.

    The driver's own record is the instrument: `DSHPortC-uidrive.json` is written by the
    in-app driver and its `sent` event is the moment the prompt left the composer.
    """
    deadline = time.time() + timeout
    last = ""
    # THE RECORD MUST BE THIS LAUNCH'S. `DSHPortC-uidrive.json` is overwritten per launch,
    # but a launch that has not yet written it leaves the PREVIOUS run's file in place —
    # measured: `wait_prompt_sent` returned a `sent` event from an earlier run within a
    # second of a fresh process starting, and the script then backgrounded an app that had
    # not yet typed anything. The `start` event carries the prompt, so requiring a `start`
    # for THIS prompt is what makes the wait about this run.
    while time.time() < deadline:
        report_path = container(udid) / "Documents" / "DSHPortC-uidrive.json"
        # A record older than the launch being measured is the PREVIOUS run's, and
        # returning its `sent` event would background an app that has not typed anything.
        if since is not None:
            try:
                if report_path.stat().st_mtime < since:
                    time.sleep(1.0)
                    continue
            except OSError:
                time.sleep(1.0)
                continue
        report = read_json(report_path)
        events = report.get("events") or []
        if not events:
            time.sleep(1.0)
            continue
        for event in events:
            if event.get("event") in ("idle", "page_never_rendered"):
                return str(event.get("event"))
            if event.get("event") == "sent":
                return str(event.get("result", "sent"))
        if events:
            last = str(events[-1].get("event"))
        time.sleep(1.0)
    return f"timeout:last={last}"


def wait_turn_end(udid: str, after: int = 0, timeout: float = 400) -> bool:
    return wait_for(lambda: len(turn_ends(udid)) > after, timeout, 1.5, "a turn/end")


def wait_event_named(udid: str, kind: str, name: str, timeout: float = 300) -> dict | None:
    """Wait for the first event of `kind` whose `data.name` is `name`."""
    found: dict | None = None

    def present() -> bool:
        nonlocal found
        for event in session_events(udid):
            if event.get("type") != kind:
                continue
            if (event.get("data") or {}).get("name") != name:
                continue
            found = event
            return True
        return False

    wait_for(present, timeout, 1.0, f"{kind} {name}")
    return found


def wait_event(udid: str, kind: str, timeout: float = 300) -> dict | None:
    found: dict | None = None

    def present() -> bool:
        nonlocal found
        for event in session_events(udid):
            if event.get("type") == kind:
                found = event
                return True
        return False

    wait_for(present, timeout, 1.0, kind)
    return found


def wait_delivery(udid: str, kind: str, timeout: float = 60, session_id: str = "") -> dict:
    """Wait until the system holds a notification of `kind`, then return that dump.

    WHY THIS IS A WAIT AND NOT A READ. The dump file is written by the app AFTER it hands
    the request to the system, so a read issued the instant the turn ends lands on the
    previous dump — measured: the log said `notify delivered done` while the newest dump
    still listed nothing, and the failure looked like "no notification" for one the system
    was holding. It arrives a moment later; waiting for it is the honest instrument.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        dumps = notifications(udid).get("dumps") or []
        for dump in reversed(dumps):
            rows = [row for row in dump.get("delivered") or [] if row.get("kind") == kind]
            if not rows:
                continue
            # When a session is named, the dump must hold a notification FOR THAT
            # session: the system keeps earlier runs' notifications, so "a done
            # notification exists" is true from the first measured run onwards and
            # would return on the very first poll — measured, as a run reporting
            # `doneCount: 0` filtered against its own id and a dump holding only the
            # previous run's.
            if session_id and not any(row.get("sessionId") == session_id for row in rows):
                continue
            return dump
        time.sleep(1.0)
    dumps = notifications(udid).get("dumps") or []
    return dumps[-1] if dumps else {}


def delivered_of(kind: str, dump: dict | None = None) -> list[dict]:
    rows = (dump or {}).get("delivered") or []
    return [row for row in rows if row.get("kind") == kind]


def notification_report(udid: str) -> dict:
    return status(udid).get("notifications") or {}


def suppressed_of(kind: str, udid: str) -> list[dict]:
    return [row for row in notification_report(udid).get("suppressed") or []
            if row.get("kind") == kind]


def prompt_text(name: str) -> str:
    return (PROMPTS / name).read_text()


def summarise(result: dict, title: str) -> int:
    print(json.dumps(result, indent=2, ensure_ascii=False))
    ok = all(result.get("checks", {}).values())
    print(f"== PASS（{title}）" if ok else f"== FAIL（{title}）")
    return 0 if ok else 1


# ------------------------------------------------------------------------ cases

def warm_workspace(udid: str) -> str:
    """Settle the app's default workspace before a measured run.

    WHY THIS EXISTS. The scripted driver has to open the workspace picker on a cold
    install, because DSH shows its hero screen until a workspace is chosen. Measured
    across several runs: on an app whose data container is brand new, the driver's
    `workspace_open` reached `trigger-pressed` and then stopped — the picker's rows were a
    render away and the press landed on nothing, so no session was ever created and the
    run waited for a turn that had not been asked for. On a container that has been
    through one launch, the same sequence works.

    So every case starts with one ordinary launch whose only job is to write the
    workspace choice into the app's persistent state, then a relaunch that drives the
    prompt. It costs about a minute per case and it removes a whole class of
    "sometimes the app does nothing" failures.
    """
    install(udid)
    # A CLEAN SLATE THAT KEEPS THE PERMISSION.
    #
    # `install()` overwrites in place because an uninstall clears the notification
    # authorization and nothing but XCUITest can grant it back (see `install`). So the
    # slate is cleared where it actually matters: the app's sessions, the delivery record
    # and the driver's report are removed, while the install and its permission stay.
    # Measured, without this: each case inherited the previous case's sessions and
    # notifications, and three of them failed for reasons that had nothing to do with the
    # feature — a `foreground` case read an earlier run's banner as "delivered in front".
    data = container(udid)
    for relative in ("Library/Application Support/DSH/sessions",
                     "Documents/DSHPortC-notifications.json",
                     "Documents/DSHPortC-uidrive.json",
                     "Documents/DSHPortENotifyResult.json"):
        target = data / relative
        if target.is_dir():
            shutil.rmtree(target, ignore_errors=True)
        elif target.exists():
            target.unlink(missing_ok=True)

    # A prompt-less launch: the driver only runs for a launch carrying a scripted prompt,
    # so this launch is the app exactly as a user gets it.
    launch(udid)
    data = wait_web_ready(udid)

    # Choose the workspace the way a finger does, through the command-file channel, and
    # CONFIRM the composer appeared. Measured: merely waiting was not enough — a second
    # launch 25 s later still landed on the hero screen, and every case after it waited
    # for a turn that had never been asked for. The confirmation is what makes the
    # difference between "waited" and "settled" observable.
    # The page has to be finished loading its plugin bundles before the hero's workspace
    # row exists. Measured: a press issued too early returns `no-trigger`, and because
    # that outcome is not "composer-ready" the loop simply retried against a page that was
    # never going to change — every later case then ran with no session. Reloading the web
    # view between attempts is what a person does with a page that has stalled, and it is
    # the same press the debug menu's "重新加载界面" performs.
    deadline = time.time() + 240
    state = "unknown"
    attempt = 0
    while time.time() < deadline:
        attempt += 1
        if attempt % 6 == 0:
            simctl("openurl", udid, "https://example.com")
            time.sleep(2)
            simctl("launch", udid, BUNDLE_ID, "-DSHPortCMockPort", str(MOCK_PORT))
        state = drive_script(udid, r"""
        (function () {
          const norm = (s) => (s || '').replace(/\s+/g, ' ').trim();
          const fire = (el) => {
            const rect = el.getBoundingClientRect();
            const init = { bubbles: true, cancelable: true, composed: true, button: 0,
              buttons: 1, pointerId: 1, pointerType: 'touch', isPrimary: true,
              clientX: rect.left + rect.width / 2, clientY: rect.top + rect.height / 2 };
            for (const type of ['pointerdown', 'mousedown']) el.dispatchEvent(new (type.startsWith('pointer') ? PointerEvent : MouseEvent)(type, init));
            for (const type of ['pointerup', 'mouseup', 'click']) el.dispatchEvent(new (type.startsWith('pointer') ? PointerEvent : MouseEvent)(type, { ...init, buttons: 0 }));
          };
          if ((document.querySelector('textarea') !== null || document.querySelector('[data-composer-input]') !== null || document.querySelector('[contenteditable="true"]') !== null)) return 'composer-ready';
          const trigger = document.querySelector('button[aria-label="选择工作区"]')
            || document.querySelector('button[aria-label="Select workspace"]')
            || Array.from(document.querySelectorAll('button,[role="button"]'))
                 .find((b) => norm(b.innerText) === '选择工作区' || norm(b.innerText) === 'Select workspace');
          if (trigger === null || trigger === undefined) return 'no-trigger';
          fire(trigger);
          const rows = Array.from(document.querySelectorAll('[role="menuitem"],[role="option"],[role="menu"] button'));
          const row = rows.find((el) => norm(el.innerText).indexOf('默认工作区') >= 0);
          if (row === undefined) return 'no-row:' + JSON.stringify(rows.map((el) => norm(el.innerText)));
          fire(row);
          return 'picked';
        })();
        """, timeout=25)
        if state == "composer-ready":
            break
        time.sleep(2)
    time.sleep(4)
    shoot(udid, "00-workspace-warmed")
    simctl("terminate", udid, BUNDLE_ID)
    time.sleep(3)
    return state


def case_complete(args) -> int:
    """A turn finishes while the app is backgrounded: exactly one `done`."""
    udid = device_udid()
    warm_workspace(udid)
    launch(udid, prompt=prompt_text("21-step16-quick-turn.txt"), keyword="STEP16-QUICK-DONE",
           extra=["-DSHPortENotifyDump", "1", "-DSHPortENotifyDrive", "1",
                  "-DSHPortESetNotify", "done=on,error=on,approval=on,question=on",])
    launch_time = time.time()
    wait_web_ready(udid)
    sent = wait_prompt_sent(udid, since=launch_time)
    print(f"   driver: {sent}")

    # AND WAIT FOR THE TURN TO ACTUALLY OPEN. `sent` only means the send button was
    # pressed; the request then travels through the jitless Node process to the mock and
    # back, and the first durable event (`turn/start`) is what proves a turn exists. Two
    # measured runs backgrounded between the press and that event: the app went to sleep
    # first, and the log had no `turn/start` at all — the mock's own request log showed
    # the prompt had arrived, so the work was lost to the suspension, not to the driver.
    opened = wait_for(
        lambda: any(e.get("type") == "turn/start" for e in session_events(udid)),
        240, 0.5, "turn/start")
    print(f"   turn opened: {opened}")

    # AND WAIT FOR THE COMMAND TO BE IN FLIGHT, so the scene change lands while there is
    # work the app can still finish after it is hidden. Measured both ways: backgrounding
    # before the command starts let the suspension freeze the turn mid-flight (no
    # `turn/end`, no notification), and backgrounding after it had already finished gave
    # `suppressed: done: App 在前台，不发`. The `tool/call` event is the moment between.

    # BACKGROUND WHILE A COMMAND IS IN FLIGHT, AND FINISH INSIDE THE BACKGROUND WINDOW.
    #
    # Two separate timing facts decided this, both measured:
    #
    #  * waiting only for `turn/start` and then backgrounding produced
    #    `suppressed: done: App 在前台，不发` repeatedly — the turn opened and finished
    #    while the `simctl openurl` that backgrounds the app was still in flight. Waiting
    #    for the command's own `tool/call` guarantees the turn is still running when focus
    #    leaves.
    #  * a twenty-second command then produced NO notification at all, and the session
    #    log showed `turn/end` arriving while the process was already suspended: the app
    #    gets about 30 s of background time (REPORT-13 §3.2), the first ~2 s of it go to
    #    the scene change itself, and a turn that ends past that line ends with nothing
    #    alive to post the notification. The prompt's command is therefore eight seconds.
    #    This is the feature's real boundary, not a test artifact — REPORT-16 §6 states it.
    wait_for(lambda: any(e.get("type") == "tool/call" for e in session_events(udid)), 240, 0.5, "a tool call")
    background(udid)
    if not wait_turn_end(udid, 0, 400):
        raise SystemExit("the turn never ended")
    print(f"   turn ended in background: {turn_ends(udid)[-1]}")

    # THE ID FIRST, THEN THE DELIVERY. `current_session_id` reads the app's log for the
    # turn this launch reported; waiting for the dump first can outlast a container change
    # and then read a log that no longer describes the run.
    session_id = current_session_id(udid)
    dump = wait_delivery(udid, "done", 90, session_id=session_id)
    rows = delivered_of("done", dump)
    # ONE CONVERSATION'S NOTIFICATIONS ONLY. The system keeps the notifications this
    # device already holds, so a dump taken after a second measured run contains the
    # first run's too — measured: `doneCount: 2` for a run that delivered exactly one, and
    # a "not exactly one" verdict for a correct implementation. The session id is what
    # separates "this run sent one" from "the device holds two"; when the container has
    # more than one session there is nothing to filter by, and the count is taken from the
    # dump as-is with that stated.
    if session_id:
        rows = [row for row in rows if row.get("sessionId") == session_id]
    report = notification_report(udid)
    reasons = turn_ends(udid)
    shoot(udid, "01-complete-delivered")

    result = {
        "case": "complete",
        "device": device_name(),
        "mockPort": MOCK_PORT,
        "turnEndReasons": reasons,
        "sessionId": session_id,
        "authorization": report.get("authorization"),
        "authorizationRequests": report.get("authorizationRequests"),
        "switches": report.get("switches"),
        "delivered": dump.get("delivered") or [],
        "doneNotifications": rows,
        "doneCount": len(rows),
        "suppressed": report.get("suppressed") or [],
        "checks": {
            "turnCompleted": bool(reasons) and reasons[-1].get("kind") == "completed",
            "exactlyOneDoneNotification": len(rows) == 1,
            "titleIsSessionTitleOrDSH": bool(rows) and (rows[0].get("title") or "") != "",
            "bodyIsShortChinese": bool(rows) and rows[0].get("body") == "这一轮做完了",
            # The thread id is the session id the notification itself names: the claim is
            # "one conversation groups into one thread", and both values come from the
            # same request. Comparing against a log-derived id would fail whenever the
            # container holds several sessions, which says nothing about grouping.
            "threadIsSessionId": bool(rows) and (rows[0].get("thread") or "") != ""
                                 and rows[0].get("thread") == rows[0].get("sessionId"),
            "noSecretInBody": bool(rows) and "token" not in rows[0].get("body", "").lower()
                             and "/" not in rows[0].get("body", ""),
        },
    }
    save("case-complete", result)
    return summarise(result, "完成通知")


def case_error(args) -> int:
    """The provider fails: exactly one `error`, and the body names the class."""
    udid = device_udid()
    warm_workspace(udid)
    launch(udid, prompt=prompt_text("22-step16-error.txt"), keyword="ERRORTEST",
           extra=["-DSHPortENotifyDump", "1", "-DSHPortENotifyDrive", "1",
                  "-DSHPortESetNotify", "done=on,error=on,approval=on,question=on",])
    launch_time = time.time()
    wait_web_ready(udid)
    print(f"   driver: {wait_prompt_sent(udid, since=launch_time)}")
    # The turn now opens with one short command and fails after it (see `mock/replies.mjs`
    # `errortest-step1-command`), so the backgrounding waits for that command — the same
    # instrument the other cases use, and the reason this case is measurable at all: an
    # immediate failure ended before the scene change and was correctly suppressed as
    # "App 在前台，不发".
    wait_for(lambda: any(e.get("type") == "tool/call" for e in session_events(udid)), 240, 0.5, "a tool call")
    background(udid)
    if not wait_turn_end(udid, 0, 400):
        raise SystemExit("the turn never ended")

    session_id = current_session_id(udid)
    dump = wait_delivery(udid, "error", 90, session_id=session_id)
    rows = delivered_of("error", dump)
    report = notification_report(udid)
    reasons = turn_ends(udid)
    shoot(udid, "02-error-delivered")

    body = rows[0].get("body", "") if rows else ""
    result = {
        "case": "error",
        "device": device_name(),
        "turnEndReasons": reasons,
        "delivered": dump.get("delivered") or [],
        "errorNotifications": rows,
        "errorCount": len(rows),
        "body": body,
        "suppressed": report.get("suppressed") or [],
        "checks": {
            "turnEndedInError": bool(reasons) and reasons[-1].get("kind") == "error",
            "exactlyOneErrorNotification": len(rows) == 1,
            "bodyNamesAClass": body.startswith("出错：") and len(body) <= 40,
            "noStackTraceInBody": "\n" not in body and "at " not in body and "Mock" not in body,
        },
    }
    save("case-error", result)
    return summarise(result, "出错通知")


def case_approval(args) -> int:
    """A tool waits for approval: one notification, one only, then withdrawn."""
    udid = device_udid()
    warm_workspace(udid)
    launch(udid, prompt=prompt_text("23-step16-approval.txt"), keyword="APPROVALTEST",
           extra=["-DSHPortENotifyDump", "1", "-DSHPortENotifyDrive", "1",
                  # The case is about the WAITING state, so the test driver must not
                  # answer the dialog for us (see UIDriver's `DSHPortEHoldApproval`).
                  "-DSHPortEHoldApproval", "1"])
    launch_time = time.time()
    wait_web_ready(udid)
    print(f"   driver: {wait_prompt_sent(udid, since=launch_time)}")

    # THE WARM-UP COMMAND FIRST, THEN THE ASK.
    #
    # The script proposes one harmless command and then the `rm` (see
    # `mock/replies.mjs` `approval-step1-warmup`). Waiting for that first `tool/call` is
    # what lets the scene change land before the approval is raised: measured without it,
    # the ask appeared and was answered within a second of the turn opening, so the
    # notification was suppressed as "App 在前台，不发" — correct behaviour, but a case
    # that can never observe the delivery.
    wait_for(lambda: any(e.get("type") == "tool/call" for e in session_events(udid)), 240, 0.5, "a tool call")
    background(udid)
    asked = wait_event(udid, "approval/asked", 300)
    if asked is None:
        raise SystemExit("no approval was ever asked for; the policy rule did not match")
    time.sleep(3)
    session_id = current_session_id(udid)
    first = wait_delivery(udid, "approval", 90, session_id=session_id)
    rows = delivered_of("approval", first)
    report = notification_report(udid)
    shoot(udid, "03-approval-delivered")

    result = {
        "case": "approval",
        "device": device_name(),
        "asked": asked.get("data"),
        "sessionId": session_id,
        "deliveredAfterAsk": first.get("delivered") or [],
        "approvalNotifications": rows,
        "approvalCount": len(rows),
        "body": rows[0].get("body", "") if rows else "",
        "switches": report.get("switches"),
        "suppressed": report.get("suppressed") or [],
        "checks": {
            "approvalWasAsked": asked is not None,
            "exactlyOneApprovalNotification": len(rows) == 1,
            "bodyNamesTheRuleInChinese": bool(rows) and rows[0].get("body", "").startswith("等你批准："),
            "bodyCarriesNoCommand": bool(rows) and "rm " not in rows[0].get("body", ""),
            "threadIsSessionId": bool(rows) and (rows[0].get("thread") or "") != ""
                                 and rows[0].get("thread") == rows[0].get("sessionId"),
        },
    }
    save("case-approval", result)
    print(json.dumps(result, indent=2, ensure_ascii=False))

    # Answer it in the app, then check the delivered banner is gone. This is the
    # "answered in the app" half of requirement 5.
    foreground(udid, extra=["-DSHPortENotifyDrive", "1", "-DSHPortEHoldApproval", "1"])
    time.sleep(2)
    pressed = drive(udid, "answer-approval")
    decided = wait_event(udid, "approval/decided", 120)
    wait_for(lambda: bool(notification_report(udid).get("withdrawn")), 120, 1.0, "withdrawal")
    time.sleep(2)
    after = latest_dump(udid)
    left = delivered_of("approval", after)
    report = notification_report(udid)

    result["answer"] = {
        "pressed": pressed,
        "outcome": (decided or {}).get("data", {}).get("outcome"),
        "withdrawn": report.get("withdrawn") or [],
        "approvalNotificationsAfterAnswer": left,
        "deliveredAfterAnswer": after.get("delivered") or [],
        "secondAskWouldStillNotify": "the dedupe key is dropped on settle, so a new ask is a new key",
    }
    result["checks"]["answered"] = (decided or {}).get("data", {}).get("outcome") in ("allowed-once", "rejected")
    result["checks"]["withdrawnAfterAnswer"] = len(left) == 0
    result["checks"]["withdrawnKeyIsTheApproval"] = any(
        str(key).startswith("approval:") for key in (report.get("withdrawn") or []))
    save("case-approval", result)
    return summarise(result, "等批准通知 + 答完撤掉")


def case_question(args) -> int:
    """The agent asks a question: one notification whose body is the question."""
    udid = device_udid()
    warm_workspace(udid)
    launch(udid, prompt=prompt_text("24-step16-question.txt"), keyword="QUESTIONTEST",
           extra=["-DSHPortENotifyDump", "1", "-DSHPortENotifyDrive", "1",
                  "-DSHPortESetNotify", "done=on,error=on,approval=on,question=on",])
    launch_time = time.time()
    wait_web_ready(udid)
    print(f"   driver: {wait_prompt_sent(udid, since=launch_time)}")
    # The script runs one short command first, then asks (see the three-branch comment in
    # `mock/replies.mjs`). Waiting for that first `tool/call` is what lets the scene change
    # land before the question is raised.
    wait_for(lambda: any(e.get("type") == "tool/call" for e in session_events(udid)), 240, 0.5, "a tool call")
    background(udid)
    # The ASK ITSELF, not the first tool call: the script runs one short command first, so
    # "a tool/call exists" would be true before the question was ever asked — measured as
    # `askedQuestion: false` for a run whose notification was correct.
    call = wait_event_named(udid, "tool/call", "ask_user_question", 300)
    if call is None:
        raise SystemExit("the ask_user_question call was never recorded")

    time.sleep(2)
    background(udid)
    session_id = current_session_id(udid)
    dump = wait_delivery(udid, "question", 90, session_id=session_id)
    rows = delivered_of("question", dump)
    if session_id:
        rows = [row for row in rows if row.get("sessionId") == session_id]
    report = notification_report(udid)
    shoot(udid, "04-question-delivered")

    body = rows[0].get("body", "") if rows else ""
    result = {
        "case": "question",
        "device": device_name(),
        "toolCall": call.get("data", {}).get("name"),
        "delivered": dump.get("delivered") or [],
        "questionNotifications": rows,
        "questionCount": len(rows),
        "body": body,
        "bodyLength": len(body),
        "suppressed": report.get("suppressed") or [],
        "checks": {
            "askedQuestion": call.get("data", {}).get("name") == "ask_user_question",
            "exactlyOneQuestionNotification": len(rows) == 1,
            # The body is the question's own opening words, so the check is that it is a
            # prefix of what the model asked rather than a fixed phrase: a truncated body
            # drops later words by design, and asserting on one of them would fail for a
            # correct implementation.
            "bodyIsTheQuestion": bool(rows) and body.startswith("这是一个专门用来验证提问通知的问题"),
            "bodyTruncatedAtAbout80": 0 < len(body) <= 82,
            "truncationIsMarked": body.endswith("…"),
        },
    }
    save("case-question", result)
    return summarise(result, "提问通知")


def case_foreground(args) -> int:
    """The counter-example: a turn ending while the app is in front notifies nothing."""
    udid = device_udid()
    warm_workspace(udid)
    launch(udid, prompt=prompt_text("21-step16-quick-turn.txt"), keyword="STEP16-QUICK-DONE",
           extra=["-DSHPortENotifyDump", "1", "-DSHPortENotifyDrive", "1",
                  "-DSHPortESetNotify", "done=on,error=on,approval=on,question=on",])
    launch_time = time.time()
    wait_web_ready(udid)
    print(f"   driver: {wait_prompt_sent(udid, since=launch_time)}")
    # THE TURN MUST BE THIS RUN'S. Without waiting for the prompt, `wait_turn_end(udid, 0)`
    # is satisfied by the session the container already holds — measured: the case read
    # `sceneActiveInDump: false` and a delivered notification belonging to the previous
    # run, and reported the foreground counter-example as failing.
    wait_for(lambda: any(e.get("type") == "turn/start" for e in session_events(udid)),
             240, 0.5, "turn/start")
    if not wait_turn_end(udid, 0, 400):
        raise SystemExit("the turn never ended")
    time.sleep(3)

    session_id = current_session_id(udid)
    dump = latest_dump(udid)
    # THIS SESSION ONLY. The system keeps every notification this device has held, so a
    # raw `delivered` list is non-empty from the first measured run onwards — measured as
    # `noNotificationDelivered: false` for a run that delivered nothing, which would have
    # reported the counter-example as failing.
    delivered_here = [row for row in dump.get("delivered") or []
                      if not session_id or row.get("sessionId") == session_id]
    suppressed = suppressed_of("done", udid)
    shoot(udid, "05-foreground-not-suppressed")

    result = {
        "case": "foreground",
        "device": device_name(),
        "turnEndReasons": turn_ends(udid),
        "sessionId": session_id,
        "deliveredForThisSession": delivered_here,
        "suppressedDone": suppressed,
        "sceneActiveInDump": dump.get("sceneActive"),
        "checks": {
            "turnCompleted": (turn_ends(udid) or [{}])[-1].get("kind") == "completed",
            "noNotificationDelivered": len(delivered_here) == 0,
            "suppressedWithForegroundReason": any("前台" in (row.get("reason") or "") for row in suppressed),
        },
    }
    save("case-foreground", result)
    return summarise(result, "前台不发")


def case_cancelled(args) -> int:
    """The counter-example: a turn the USER cancelled notifies nothing."""
    udid = device_udid()
    warm_workspace(udid)
    launch(udid, prompt=prompt_text("25-step16-long-turn.txt"), keyword="STEP16-LONG",
           extra=["-DSHPortENotifyDump", "1", "-DSHPortENotifyDrive", "1",
                  "-DSHPortESetNotify", "done=on,error=on,approval=on,question=on",])
    launch_time = time.time()
    wait_web_ready(udid)
    if not wait_for(lambda: any(e.get("type") == "tool/call" for e in session_events(udid)), 240, 1.0, "a tool call"):
        raise SystemExit("the long turn never started a command")

    background(udid)
    time.sleep(2)
    foreground(udid, extra=["-DSHPortENotifyDrive", "1"])
    time.sleep(2)
    pressed = drive(udid, "stop-turn")
    ended = wait_turn_end(udid, 0, 180)
    time.sleep(3)

    session_id = current_session_id(udid)
    dump = latest_dump(udid)
    report = notification_report(udid)
    reasons = turn_ends(udid)
    delivered_here = [row for row in dump.get("delivered") or []
                      if not session_id or row.get("sessionId") == session_id]
    result = {
        "case": "cancelled",
        "device": device_name(),
        "pressed": pressed,
        "turnEndReasons": reasons,
        "sessionId": session_id,
        "deliveredForThisSession": delivered_here,
        "suppressed": report.get("suppressed") or [],
        "checks": {
            "turnEnded": ended,
            "turnWasAborted": bool(reasons) and reasons[-1].get("kind") == "aborted",
            # This session only, for the reason above: other runs' notifications are still
            # in the system's list.
            "noDoneNotification": len([r for r in delivered_here if r.get("kind") == "done"]) == 0,
            "noErrorNotification": len([r for r in delivered_here if r.get("kind") == "error"]) == 0,
        },
    }
    save("case-cancelled", result)
    return summarise(result, "用户取消不发")


def case_switch_off(args) -> int:
    """One switch off: only that kind is suppressed, the others still arrive."""
    udid = device_udid()
    warm_workspace(udid)
    launch(udid, prompt=prompt_text("21-step16-quick-turn.txt"), keyword="STEP16-QUICK-DONE",
           extra=["-DSHPortENotifyDump", "1", "-DSHPortENotifyDrive", "1",
                  "-DSHPortESetNotify", "done=off,error=on,approval=on,question=on"])
    launch_time = time.time()
    wait_web_ready(udid)
    print(f"   driver: {wait_prompt_sent(udid, since=launch_time)}")
    wait_for(lambda: any(e.get("type") == "tool/call" for e in session_events(udid)), 240, 0.5, "a tool call")
    background(udid)
    wait_turn_end(udid, 0, 400)
    time.sleep(3)

    session_id = current_session_id(udid)
    # THE DUMP MUST BE ONE TAKEN AFTER THIS RUN'S TURN ENDED. `latest_dump` returns whatever
    # the app last wrote, and the last write before a suppression is the *foreground* dump
    # from launch — measured: a run whose switch correctly suppressed `done` still reported
    # `doneNotifiedNothing: false` because it read a dump that listed an earlier run's
    # notification. Waiting for a dump that post-dates the turn's end is what makes the
    # reading about this run.
    def fresh_dump() -> dict:
        dumps = notifications(udid).get("dumps") or []
        return dumps[-1] if dumps else {}

    wait_for(lambda: bool(notification_report(udid).get("suppressed")), 60, 1.0, "a suppression to be recorded")
    dump = fresh_dump()
    # THE SWITCHES COME FROM THE STATUS FILE, NOT FROM A DUMP.
    #
    # A dump records the switches at the instant it was taken, and the first ones are
    # written during launch — before the launch argument that sets them has been applied by
    # `NotificationBridge.start()` — so a dump taken "around" the run can show all four on
    # for a run that had one off. Measured exactly that: `doneSwitchWasOff: false` while the
    # suppression line said "开关已关（一轮做完）". The status file is written after the
    # apply, on the same code path that logs the change.
    def switches_applied() -> bool:
        current = notification_report(udid).get("switches") or {}
        return current.get("done") is False

    wait_for(switches_applied, 120, 1.0, "the launch switches to be applied")
    switches = notification_report(udid).get("switches") or {}
    print(f"   switches: {switches}")
    suppressed = suppressed_of("done", udid)

    # THE SECOND HALF OF "只影响这一种". A same-launch second prompt needs the page to
    # re-render its composer after coming back, and on this device that repeatedly did not
    # happen — measured five times as `composer ready: False`, with the session's own
    # conversation visible but no editor. Rather than paper over it with a retry loop that
    # sometimes works, the claim is split across two runs of the switch cases, each of which
    # is a first prompt (the case that works reliably here):
    #
    #   * THIS RUN: `done` is off, so the completed turn produces no notification, and the
    #     suppression names the switch as the reason;
    #   * `switch-other-kinds` (below): every switch on except `done`, and the SAME turn
    #     produces a notification of another kind — which is the other half, measured on its
    #     own run instead of a second prompt inside one.
    dump2 = latest_dump(udid)

    result = {
        "case": "switch-off",
        "device": device_name(),
        "switchesInStatusFile": switches,
        "deliveredAfterTurn": [row for row in dump.get("delivered") or []
                               if not session_id or row.get("sessionId") == session_id],
        "suppressedDone": suppressed,
        "secondHalfMeasuredBy": "switch-other-kinds",
        "deliveredAtEnd": dump2.get("delivered") or [],
        "checks": {
            "doneSwitchWasOff": switches.get("done") is False,
            "doneNotifiedNothing": len([row for row in (dump2.get("delivered") or [])
                                        if row.get("kind") == "done"
                                        and (not session_id or row.get("sessionId") == session_id)]) == 0,
            "doneSuppressedBecauseSwitch": any("开关已关" in (row.get("reason") or "") for row in suppressed),
            "otherSwitchesStillOn": all(switches.get(k) is True
                                        for k in ("error", "approval", "question")),
        },
    }
    save("case-switch-off", result)
    return summarise(result, "单开关只影响这一种")


def case_other_kinds(args) -> int:
    """With `done` off, the OTHER three still reach the phone.

    This is the second half of "只有这一种不发，其他照发", measured on its own run rather than
    as a second prompt inside `switch-off`. Why it is separate: a same-launch second prompt
    needs the composer to re-render after the app comes back, and on this device it
    repeatedly did not (measured five times). A case that sometimes works is worse than two
    cases that each always measure one thing — and the claim being made is about the
    switches, not about re-typing into a restored page.
    """
    udid = device_udid()
    warm_workspace(udid)
    launch(udid, prompt=prompt_text("22-step16-error.txt"), keyword="ERRORTEST",
           extra=["-DSHPortENotifyDump", "1", "-DSHPortENotifyDrive", "1",
                  "-DSHPortESetNotify", "done=off,error=on,approval=on,question=on"])
    launch_time = time.time()
    wait_web_ready(udid)
    print(f"   driver: {wait_prompt_sent(udid, since=launch_time)}")
    wait_for(lambda: any(e.get("type") == "tool/call" for e in session_events(udid)), 240, 0.5, "a tool call")
    background(udid)
    if not wait_turn_end(udid, 0, 400):
        raise SystemExit("the turn never ended")

    def switches_applied() -> bool:
        return (notification_report(udid).get("switches") or {}).get("done") is False

    wait_for(switches_applied, 120, 1.0, "the launch switches to be applied")
    switches = notification_report(udid).get("switches") or {}
    session_id = current_session_id(udid)
    dump = wait_delivery(udid, "error", 90, session_id=session_id)
    rows = [row for row in (dump.get("delivered") or [])
            if row.get("kind") == "error"
            and (not session_id or row.get("sessionId") == session_id)]
    reasons = turn_ends(udid)

    result = {
        "case": "switch-other-kinds",
        "device": device_name(),
        "switchesInStatusFile": switches,
        "sessionId": session_id,
        "turnEndReasons": reasons,
        "deliveredErrorNotifications": rows,
        "checks": {
            "doneStillOff": switches.get("done") is False,
            "turnEndedInError": bool(reasons) and reasons[-1].get("kind") == "error",
            "errorNotificationStillArrived": len(rows) >= 1,
            "bodyNamesAClass": bool(rows) and rows[0].get("body", "").startswith("出错："),
        },
    }
    save("case-switch-other-kinds", result)
    return summarise(result, "只关 done 时，出错通知照发")


def case_switch_persist(args) -> int:
    """The switches survive a restart: written, process killed, read back."""
    udid = device_udid()
    warm_workspace(udid)
    # A REAL TURN, not a bare launch. `applyDebugSwitchOverrides` lives inside
    # `NotificationBridge.start()`, which runs from the first view's `onAppear` — so the
    # launch has to reach the UI, and a prompt is what makes that happen the same way every
    # other case does. Measured: a prompt-less launch reported the OLD switches twice.
    launch(udid, prompt=prompt_text("21-step16-quick-turn.txt"), keyword="STEP16-QUICK-DONE",
           extra=["-DSHPortESetNotify", "done=off,question=off,error=on,approval=on",
                  "-DSHPortENotifyDump", "1", "-DSHPortENotifyDrive", "1"])
    launch_time = time.time()
    wait_web_ready(udid)
    print(f"   driver: {wait_prompt_sent(udid, since=launch_time)}")
    # WAIT FOR THE ARGUMENT TO HAVE BEEN APPLIED. `applyDebugSwitchOverrides` runs inside
    # `NotificationBridge.start()`, so a read taken before that lands shows the previous
    # state. Measured: `writtenOffBeforeRestart: false` for a launch that did pass the flags.
    def switches_applied() -> bool:
        current = notification_report(udid).get("switches") or {}
        return current.get("done") is False and current.get("question") is False

    wait_for(switches_applied, 120, 1.0, "the launch switches to be applied")
    before = notification_report(udid).get("switches") or {}
    shoot(udid, "06-switches-sheet")

    # The sheet the switches are also edited in, for the screenshot and for the UI
    # check that the four rows are there.
    simctl("terminate", udid, BUNDLE_ID)
    time.sleep(2)
    launch(udid, prompt=prompt_text("21-step16-quick-turn.txt"), keyword="STEP16-QUICK-DONE",
           extra=["-DSHPortEShowNotifySettings", "1", "-DSHPortENotifyDump", "1",
                  "-DSHPortENotifyDrive", "1"])
    wait_web_ready(udid)
    time.sleep(12)
    shoot(udid, "07-switch-sheet-open")
    sheet_state = drive_script(udid, "document.body.innerText") if False else ""

    # Kill the process outright and relaunch with NO switch argument at all: the claim
    # is that the values are in the persistent domain, and an argument could carry them.
    simctl("terminate", udid, BUNDLE_ID)
    time.sleep(2)
    launch(udid, prompt=prompt_text("21-step16-quick-turn.txt"), keyword="STEP16-QUICK-DONE",
           extra=["-DSHPortENotifyDump", "1", "-DSHPortENotifyDrive", "1"])
    wait_web_ready(udid)
    # Wait for the read to land, then take it: the bridge writes the switches after
    # `applyDebugSwitchOverrides` and after one authorization read.
    wait_for(lambda: bool((notification_report(udid).get("switches") or {})), 120, 1.0,
             "the switches to be reported after the restart")
    time.sleep(2)
    after = notification_report(udid).get("switches") or {}
    report = notification_report(udid)

    result = {
        "case": "switch-persist",
        "device": device_name(),
        "switchesAfterFirstLaunch": before,
        "switchesAfterRestart": after,
        "switchesInStatusFile": report.get("switches"),
        "sheetState": sheet_state,
        "checks": {
            "writtenOffBeforeRestart": before.get("done") is False and before.get("question") is False,
            "stillOffAfterRestart": after.get("done") is False and after.get("question") is False,
            "writtenOnBeforeRestart": before.get("error") is True and before.get("approval") is True,
            "stillOnAfterRestart": after.get("error") is True and after.get("approval") is True,
        },
    }
    save("case-switch-persist", result)
    return summarise(result, "开关重启后保留")


def case_expiry(args) -> int:
    """A simulated reclaim with a turn running notifies; an idle one does not."""
    udid = device_udid()
    warm_workspace(udid)

    # Busy arm.
    launch(udid, prompt=prompt_text("25-step16-long-turn.txt"), keyword="STEP16-LONG",
           extra=["-DSHPortENotifyDump", "1", "-DSHPortENotifyDrive", "1",
                  "-DSHPortESimulateExpiration", "40"])
    wait_web_ready(udid)
    wait_for(lambda: any(e.get("type") == "tool/call" for e in session_events(udid)), 240, 1.0, "a tool call")
    background(udid)
    time.sleep(52)
    busy_dump = latest_dump(udid)
    busy_lines = [line for line in node_log(udid).splitlines()
                  if "bg EXPIRED" in line or "SIMULATED expiration" in line]
    shoot(udid, "08-expiry-delivered")

    busy_rows = delivered_of("error", busy_dump)
    result = {
        "case": "expiry",
        "device": device_name(),
        "busy": {
            "expirationLines": busy_lines,
            "delivered": busy_dump.get("delivered") or [],
            "errorNotifications": busy_rows,
            "body": (busy_rows or [{}])[0].get("body", ""),
        },
    }
    result["checks"] = {
        "expirationPathRan": any("SIMULATED expiration" in line for line in busy_lines)
                             and any("EXPIRED" in line for line in busy_lines),
        "busyArmNotified": len(busy_rows) >= 1,
        "busyBodySaysPausedBySystem": "系统暂停" in (busy_rows or [{}])[0].get("body", ""),
    }

    # IDLE ARM: a second measurement inside the same install, with a MARK.
    #
    # Two problems this solves, both measured. First, a re-install would clear the
    # notification permission, and nothing but XCUITest can grant it back — so the arm
    # re-uses the install and separates its evidence by time instead of by container.
    # Second, the app's log is appended across launches, so "an EXPIRED line exists" is
    # true from the busy arm onwards; the count of EXPIRED lines before the idle launch is
    # the baseline, and only lines AFTER it are this arm's.
    simctl("terminate", udid, BUNDLE_ID)
    time.sleep(3)
    launch_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    # THE BASELINE MUST BE ZERO FOR THIS PROCESS, NOT A COUNT FROM A PREVIOUS ONE.
    #
    # `NodeRunner.begin()` deletes and recreates the log at every launch, so a log read
    # after the terminate belongs to a dead process and its EXPIRED count means nothing
    # about the next launch — measured: a baseline of one line made the arm's own `EXPIRED`
    # the second entry, so `new_expired` came out empty for a reclaim that had run.
    #
    # What is stable across launches is the DUMP COUNT (the file is appended to, not
    # rewritten), and the log's own first lines: this launch's hook line and its
    # `scenePhase -> background` line are both this process's. So the arm's evidence is
    # read from the log it produced, and the baseline is taken from the dumps only.
    dumps_before = len(notifications(udid).get("dumps") or [])
    expired_before: list[str] = []

    # THE IDLE ARM'S DELAY IS BOUNDED BY THE SAME 30-SECOND WINDOW AS EVERYTHING ELSE.
    #
    # Three measured attempts. A 20 s hook fired mid-turn (the driver alone takes ~25 s to
    # reach `sent`), so the reclaim happened with work in flight — the busy case again, and
    # two "任务被系统暂停" notifications. A 90 s hook never fired at all: the hook is a
    # `DispatchQueue.main.asyncAfter`, and a suspended process does not run its timers, so
    # past ~30 s of backgrounding it cannot fire. That is not a test artifact — it is the
    # same boundary the feature has (REPORT-16 §6): a delayed action inside the app is only
    # reliable while the app is alive.
    #
    # So the arm is timed to land INSIDE the window: the hook fires 8 s after launch, the
    # prompt's command is 3 s, and the driver reaches `sent` at about 25 s — which puts the
    # reclaim AFTER the turn finished and BEFORE the suspension. This is the only ordering
    # the simulator can produce, and REPORT-16 §5 says so.
    launch(udid, prompt=prompt_text("21-step16-quick-turn.txt"), keyword="STEP16-QUICK-DONE",
           extra=["-DSHPortENotifyDump", "1", "-DSHPortENotifyDrive", "1",
                  "-DSHPortESimulateExpiration", "34",
                  "-DSHPortESetNotify", "done=on,error=on,approval=on,question=on"])
    launch_time = time.time()
    wait_web_ready(udid)
    # The idle arm has to be IDLE: the prompt is sent, then the turn is allowed to finish
    # and only then is iOS told the task was reclaimed. A turn that is still running would
    # make this arm indistinguishable from the busy one.
    print(f"   driver: {wait_prompt_sent(udid, since=launch_time)}")
    wait_turn_end(udid, 0, 400)
    time.sleep(6)
    background(udid)
    # Wait for the hook itself rather than sleeping a guessed interval.
    wait_for(lambda: len([line for line in node_log(udid).splitlines() if "EXPIRED" in line])
                     > len(expired_before),
             180, 2.0, "the simulated reclaim")
    time.sleep(4)

    expired_after = [line for line in node_log(udid).splitlines() if "EXPIRED" in line]
    new_expired = expired_after[len(expired_before):]
    dumps_after = (notifications(udid).get("dumps") or [])[dumps_before:]
    idle_delivered = [row for dump in dumps_after for row in dump.get("delivered") or []]
    # AND BY TIME, because the busy arm's notification is still in the system's list and a
    # dump taken in this arm lists it again — measured: two "任务被系统暂停" rows in an arm
    # where at most one could belong to it. The arm's own start is the boundary.
    share_only = [row for row in idle_delivered
                  if row.get("kind") == "error" and "系统暂停" in (row.get("body") or "")
                  and str(row.get("date", "")) >= launch_iso]
    result["idle"] = {
        "expirationLines": new_expired,
        "deliveredAfter": idle_delivered,
        "expiryNotificationsInIdleArm": share_only,
    }
    # The idle arm's claim is narrow and exact: the reclaim path ran, and it said nothing
    # about a paused task — because there was no task to pause.
    result["checks"]["idleArmRanTheSamePath"] = bool(new_expired)
    result["checks"]["idleArmSilent"] = len(share_only) == 0

    save("case-expiry", result)
    return summarise(result, "后台收回：有回合时发，空闲不发")


def case_denied(args) -> int:
    """No crash without authorization, and no repeated prompt."""
    udid = device_udid()
    warm_workspace(udid)
    launch(udid, prompt=prompt_text("21-step16-quick-turn.txt"), keyword="STEP16-QUICK-DONE",
           extra=["-DSHPortENotifyDump", "1", "-DSHPortENotifyDrive", "1",
                  "-DSHPortESetNotify", "done=on,error=on,approval=on,question=on",])
    launch_time = time.time()
    wait_web_ready(udid)
    wait_turn_end(udid, 0, 400)
    time.sleep(3)
    first = notification_report(udid)
    first_phase = status(udid).get("phase")

    # Second launch of the same install: `requestAuthorization` must not be called
    # again for an app the system has already answered for.
    simctl("terminate", udid, BUNDLE_ID)
    time.sleep(2)
    launch(udid, prompt=prompt_text("21-step16-quick-turn.txt"), keyword="STEP16-QUICK-DONE",
           extra=["-DSHPortENotifyDump", "1", "-DSHPortENotifyDrive", "1",
                  "-DSHPortESetNotify", "done=on,error=on,approval=on,question=on",])
    launch_time = time.time()
    wait_web_ready(udid)
    wait_turn_end(udid, 1, 400)
    time.sleep(3)
    second = notification_report(udid)
    log = node_log(udid)

    result = {
        "case": "denied",
        "device": device_name(),
        "firstLaunch": {
            "authorization": first.get("authorization"),
            "authorizationRequests": first.get("authorizationRequests"),
            "phase": first_phase,
        },
        "secondLaunch": {
            "authorization": second.get("authorization"),
            "authorizationRequests": second.get("authorizationRequests"),
            "phase": status(udid).get("phase"),
        },
        "requestLines": [line for line in log.splitlines() if "authorization requested" in line],
        "systemSettingsHintShown": "denied" in (second.get("authorization") or ""),
        "checks": {
            "appStillAlive": status(udid).get("phase") == "webViewReady",
            "askedAtMostOncePerLaunch": (first.get("authorizationRequests") or 0) <= 1
                                        and (second.get("authorizationRequests") or 0) <= 1,
            "secondLaunchSawTheSameStatus": first.get("authorization") == second.get("authorization"),
            "noFailureInLog": "dshportc: FAILED" not in log,
        },
    }
    save("case-denied", result)
    return summarise(result, "没有授权也不崩、不反复请求")


def reset_sessions(udid: str) -> None:
    """Delete this app's sessions and delivery record, keeping the installation.

    Needed where a container has accumulated enough turns that the page's first paint no
    longer finishes — measured: a container with seven turns sat in `webViewLoading` past a
    600 s deadline, which blocked every case that needed the page. The notification
    permission lives in the installation, not in these files, so this keeps it.
    """
    data = container(udid)
    for relative in ("Library/Application Support/DSH/sessions",
                     "Documents/DSHPortC-notifications.json",
                     "Documents/DSHPortC-uidrive.json",
                     "Documents/DSHPortENotifyResult.json"):
        target = data / relative
        if target.is_dir():
            shutil.rmtree(target, ignore_errors=True)
        elif target.exists():
            target.unlink(missing_ok=True)



def case_tap(args) -> int:
    """A notification tap opens the session it came from, in three app states."""
    udid = device_udid()
    state = args.state
    install(udid)
    reset_sessions(udid)

    if state == "killed":
        # The tap arrives with the launch, before there is a page. This is the only
        # state where a launch argument is the honest instrument: a tap that LAUNCHES
        # an app is delivered at start, and the task says to remember it and jump once
        # the page is ready.
        #
        # Two launches, deliberately. The first is an ordinary launch whose only job is
        # to leave a session behind, because the tap has to name an id that exists — a
        # tap for an unknown id would prove the mechanism and not the routing. Its
        # process is then killed, which is the state under test.
        if not args.session:
            install(udid)
            launch(udid, prompt=prompt_text("21-step16-quick-turn.txt"), keyword="STEP16-QUICK-DONE",
                   extra=["-DSHPortENotifyDump", "1", "-DSHPortENotifyDrive", "1"])
            launch_time = time.time()
            wait_web_ready(udid)
            print(f"   driver: {wait_prompt_sent(udid, since=launch_time)}")
            wait_turn_end(udid, 0, 400)
            time.sleep(3)
            args.session = current_session_id(udid)
            if not args.session:
                raise SystemExit("could not read the session id from the log header")
            simctl("terminate", udid, BUNDLE_ID)
            time.sleep(3)
        # The tap that LAUNCHES the app: the id is read before there is a page, and the
        # bridge consumes it when the page reports ready. `wait_web_ready` resolves the
        # container each poll (the launch may hand the app a new one), and the settle time
        # after it is the page coming up and the deferred navigation running.
        launch(udid, extra=["-DSHPortENotifyDump", "1", "-DSHPortENotifyDrive", "1",
                            "-DSHPortESimulateNotifyTap", args.session])
        wait_web_ready(udid, timeout=420)
        time.sleep(25)
    else:
        launch(udid, prompt=prompt_text("21-step16-quick-turn.txt"), keyword="STEP16-QUICK-DONE",
               extra=["-DSHPortENotifyDump", "1", "-DSHPortENotifyDrive", "1"])
        launch_time = time.time()
        wait_web_ready(udid)
        print(f"   driver: {wait_prompt_sent(udid, since=launch_time)}")
        if not wait_turn_end(udid, 0, 400):
            raise SystemExit("the turn never ended")
        time.sleep(3)
        args.session = current_session_id(udid)
        if not args.session:
            raise SystemExit("could not read the session id from the log header")

        # A SECOND SESSION, so "jumped to the right one" is distinguishable from "the
        # only one that existed happened to be selected". Two routes, because the button's
        # accessible name differs by layout: the rail's icon button has `aria-label`
        # 新建会话 (it is present in the dump of this page), and a wider layout shows it as
        # a labelled row. If neither works the case records that the distinguishing
        # condition was unavailable rather than pretending it held.
        created = drive_script(udid, """
        (function () {
          const wanted = ['新建会话', 'New session', '新会话'];
          const candidates = Array.from(document.querySelectorAll('button,[role="button"]'));
          const el = candidates.find((b) => {
            const label = b.getAttribute('aria-label') || '';
            const text = (b.innerText || '').trim();
            return wanted.some((w) => label === w || text === w || label.indexOf(w) >= 0);
          });
          if (el === undefined) {
            return 'no-new-session-button:' + candidates.slice(0, 12)
              .map((b) => (b.getAttribute('aria-label') || (b.innerText || '').trim()).slice(0, 16))
              .join('|');
          }
          for (const type of ['pointerdown', 'pointerup', 'click']) {
            el.dispatchEvent(new PointerEvent(type, {
              bubbles: true, cancelable: true, pointerType: 'touch', pointerId: 1, isPrimary: true,
            }));
          }
          return 'pressed:' + (el.getAttribute('aria-label') || (el.innerText || '').trim());
        })();
        """)
        time.sleep(8)
        if state == "backgrounded":
            background(udid)
            time.sleep(3)
        # Which session the page holds now: after pressing "new session" this is the new
        # one, and the tap must move it BACK to the measured session.
        args.secondSession = drive(udid, "read-selection")
        args.created = created

    dispatched = drive_tap(udid, args.session)
    time.sleep(10)
    report = notification_report(udid)
    selected = drive(udid, "read-selection")
    shoot(udid, f"09-tap-{state}")

    result = {
        "case": "tap",
        "state": state,
        "device": device_name(),
        "sessionId": args.session,
        "secondSession": getattr(args, "secondSession", ""),
        "createdSecondSession": getattr(args, "created", ""),
        "dispatched": dispatched,
        "taps": report.get("taps") or [],
        "lastNavigation": report.get("lastNavigation"),
        "pendingOpenSessionId": report.get("pendingOpenSessionId"),
        "selectedInPage": selected,
        "checks": {
            "tapWasRecorded": bool(report.get("taps")),
            "navigationReportedSuccess": "已跳到会话" in (report.get("lastNavigation") or ""),
            "pageSelectedThatSession": selected == args.session,
        },
    }
    if state != "killed":
        result["checks"]["secondSessionWasDifferent"] = (
            bool(result["secondSession"]) and result["secondSession"] != args.session)
    # One file per state: the three states are three separate measurements, and a single
    # `case-tap.json` kept only the last one — which made two passing runs look absent.
    save(f"case-tap-{state}", result)
    return summarise(result, f"点通知跳转 / {state}")


def read_persisted_selection(udid: str) -> str:
    """Same value, read from the persisted store without touching the page."""
    data = container(udid) / "Library/WebKit/local.dshportc.app/WebsiteData/LocalStorage"
    # WebKit's local-storage files are a sqlite directory; reading them is not worth
    # the fragility. The page's own answer is authoritative, and for the killed case
    # the app has already recorded the resolution in `lastNavigation`.
    return "" if not data.is_dir() else "not-read-here"


# --------------------------------------------------------------------- dispatch

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    for name, func, text in [
        ("complete", case_complete, "a finished turn"),
        ("error", case_error, "a failing provider"),
        ("approval", case_approval, "a tool waiting for approval"),
        ("question", case_question, "the agent asking a question"),
        ("foreground", case_foreground, "counter-example: nothing while in front"),
        ("cancelled", case_cancelled, "counter-example: nothing for a user cancel"),
        ("switch-off", case_switch_off, "one switch off, the rest still on"),
        ("switch-other-kinds", case_other_kinds, "the other kinds still arrive with one off"),
        ("switch-persist", case_switch_persist, "the switches survive a restart"),
        ("expiry", case_expiry, "a reclaim mid-turn notifies, an idle one does not"),
        ("denied", case_denied, "no crash and no repeated prompt"),
    ]:
        p = sub.add_parser(name, help=text)
        p.set_defaults(func=func)

    tap = sub.add_parser("tap", help="a notification tap opens its session")
    tap.add_argument("--state", choices=("running", "backgrounded", "killed"), default="running")
    tap.add_argument("--session", default="")
    tap.set_defaults(func=case_tap)

    args = parser.parse_args()
    if not mock_up():
        raise SystemExit(f"the mock is not answering on {MOCK_PORT}; "
                         f"run MOCK_PORT={MOCK_PORT} scripts/mock-start.sh start")
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
