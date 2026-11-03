#!/usr/bin/env python3
"""Send one real turn, background the app, bring it back, and send another.

Step 10 asks what happens after the iPad app is backgrounded and resumed. The
interesting part is not that the process survives — iOS keeps it for a while —
but whether the web UI is still usable and the session still takes a turn, because
a WKWebView that lost its content process comes back as a blank page and would look
identical in a lifecycle log.

So this drives two real turns on the mock model server and requires both to
complete, with a background/foreground cycle in between:

  1. launch, wait for the web UI, send a prompt, wait for the reply's last line
  2. leave the app (open a URL that is not ours), wait, come back
  3. send a second prompt in the SAME session and wait for its reply

WHAT "BACKGROUND" IS HERE, AND IS NOT. `simctl` has no "press home" verb. Opening
an unrelated URL hands focus to another app, which is a real backgrounding as far
as our scene is concerned — `did-enter-background` and `will-enter-foreground` are
recorded by PadProbe, and this script requires them to appear, so a run where the
transition did not actually happen fails rather than passing silently.

Usage
    DSHPORTE_DEVICE=ipad scripts/pad-resume.py [--name LABEL]
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SIMSET = ROOT / "simdevices"
LOGS = ROOT / "logs" / "step10"
BUNDLE_ID = "local.dshportc.app"
APP = ROOT / "DerivedData/Build/Products/Debug-iphonesimulator/DSHPortC.app"
ENV = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}
MOCK_PORT = int(os.environ.get("MOCK_PORT", "19700"))
# The three files the app writes for observability live under Library/Application
# Support, not Documents, so they stay out of the Files app.
RUNTIME_DIR = "Library/Application Support/DSHPortC"

sys.path.insert(0, str(Path(__file__).resolve().parent))
import device_pick  # noqa: E402


def simctl(*args, check=False, timeout=180):
    return subprocess.run(["xcrun", "simctl", "--set", str(SIMSET), *args],
                          capture_output=True, text=True, env=ENV, check=check, timeout=timeout)


def container() -> Path:
    udid = device_pick.device_udid(create_phone=False)
    return Path(simctl("get_app_container", udid, BUNDLE_ID, "data", check=True).stdout.strip())


def read_probe(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def session_events(data: Path) -> list[dict]:
    """Every durable event of every session in this container, oldest first."""
    events: list[dict] = []
    sessions = data / "Library/Application Support/DSH/sessions"
    if not sessions.is_dir():
        return events
    for path in sorted(sessions.rglob("*.jsonl.zstd")):
        raw = subprocess.run(["zstd", "-dc", str(path)], capture_output=True, text=True,
                             env=ENV).stdout
        for line in raw.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return events


def wait_web_ready(data: Path, timeout: float = 300) -> Path:
    """Wait for the app's own ready phase and return the CURRENT data container.

    The container path is not stable across launches: the simulator gives the app
    a new Data/Application/UUID each time it reinstalls, and it did so between the
    two turns of the first attempt at this script. Holding one Path across a
    relaunch therefore reads a directory that no longer describes the running app —
    which is how the first run reported "turn 2 did not complete" for a turn that
    had completed.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            status = json.loads((data / RUNTIME_DIR / "DSHPortC-status.json").read_text())
        except (OSError, json.JSONDecodeError):
            status = {}
        if status.get("phase") == "webViewReady":
            return container()
        if status.get("phase") == "failed":
            raise SystemExit(f"the app reported failure: {status.get('error')}")
        time.sleep(0.4)
    raise SystemExit("the web view never became ready")


def wait_turn_end(data: Path, *, after: float, timeout: float = 300) -> dict | None:
    """Wait for a `turn/end` whose wall clock is later than `after`.

    The event's own `time` is milliseconds since the epoch; comparing against the
    launch instant is what makes the second turn distinguishable from the first,
    which is the whole point of the exercise.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        ends = [e for e in session_events(data) if e.get("type") == "turn/end"]
        fresh = [e for e in ends if (e.get("time", 0) / 1000.0) >= after]
        if fresh:
            return fresh[-1]
        time.sleep(2)
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--name", default="pad-resume")
    parser.add_argument("--away", type=float, default=25.0,
                        help="seconds to stay away from the app")
    args = parser.parse_args()

    if device_pick.kind() != "ipad":
        raise SystemExit("this script is about the iPad; set DSHPORTE_DEVICE=ipad")

    LOGS.mkdir(parents=True, exist_ok=True)
    udid = device_pick.device_udid(create_phone=False)
    device_pick.boot(udid)

    health = subprocess.run(["curl", "-sf", "-m", "3", f"http://127.0.0.1:{MOCK_PORT}/healthz"],
                            capture_output=True, text=True)
    if health.returncode != 0:
        raise SystemExit("the mock model server is not answering; run scripts/mock-start.sh start")

    simctl("terminate", udid, BUNDLE_ID)
    simctl("uninstall", udid, BUNDLE_ID)
    simctl("install", udid, str(APP), check=True)
    data = container()

    probe_name = f"DSHPortE-padprobe-{args.name}.json"
    for stale in (data / "Documents" / probe_name, data / RUNTIME_DIR / "DSHPortC-status.json"):
        try:
            stale.unlink()
        except OSError:
            pass

    prompt = (ROOT / "prompts" / "18-step10-pad-prompt.txt").read_text().strip()
    keyword = "STREAMTEST-COMPLETE"

    def launch(*, first_turn: bool, resume_turn: bool) -> None:
        """Launch, and say which turns this launch is allowed to send.

        The two are separate launch arguments on purpose. The first turn hangs off
        the web view's `onReady`; the resume turn hangs off `didBecomeActive`,
        because calling `simctl launch` on a backgrounded app brings it forward
        without restarting it and `onReady` never fires again. Making that explicit
        keeps a run from reporting a resume that a relaunch actually did.
        """
        env = dict(ENV)
        args_list = ["-DSHPortEPadProbe", "1", "-DSHPortEPadProbeTag", args.name,
                     "-DSHPortCTestDrive", "1",
                     # ALWAYS, from the FIRST launch. The process is not restarted
                     # when a backgrounded app is brought forward, so launch
                     # arguments supplied only on the second call never reach a
                     # running process — measured twice: the probe file recorded the
                     # hook as absent while the transitions were all there. The gate
                     # that keeps this honest is inside the app (it waits for an
                     # observed backgrounding), not in when the argument is passed.
                     "-DSHPortEPadResumeTurn", "1",
                     "-DSHPortEPadResumePrompt", prompt]
        if first_turn:
            env["SIMCTL_CHILD_DSHPORT_UITEST_PROMPT"] = prompt
            env["SIMCTL_CHILD_DSHPORT_UITEST_KEYWORD"] = keyword
        subprocess.run(["xcrun", "simctl", "--set", str(SIMSET), "launch", udid, BUNDLE_ID,
                        *args_list], capture_output=True, text=True, env=env, timeout=180,
                       check=True)

    # ---- turn 1
    first_launch = time.time()
    launch(first_turn=True, resume_turn=False)
    data = wait_web_ready(data)
    end1 = wait_turn_end(data, after=first_launch, timeout=420)
    print(f"turn 1: {'completed' if end1 else 'DID NOT COMPLETE'}")

    # ---- background, stay away, come back
    simctl("openurl", udid, "https://example.com")
    time.sleep(args.away)
    resumed_at = time.time()
    launch(first_turn=False, resume_turn=True)
    # No wait_web_ready here: the app is being brought forward, not booted, so its
    # status file already says webViewReady and waiting on it would prove nothing.
    data = container()
    print(f"resumed after {args.away:.0f}s away; container now {data.name}")

    # ---- turn 2, in the session the app restores
    end2 = wait_turn_end(data, after=resumed_at, timeout=420)
    print(f"turn 2: {'completed' if end2 else 'DID NOT COMPLETE'}")

    probe = read_probe(data / "Documents" / probe_name)
    labels = [s.get("label") for s in probe.get("sweeps", []) if s.get("label")]
    lifecycle = [s for s in probe.get("sweeps", [])
                 if s.get("event") in ("did-enter-background", "will-enter-foreground")
                 or str(s.get("label", "")).startswith(("did-enter-background", "will-enter-foreground"))]
    transitions = [s.get("event") or s.get("label") for s in lifecycle]

    sessions = sorted({p.name for p in (data / "Library/Application Support/DSH/sessions").rglob("*.jsonl.zstd")})
    result = {
        "name": args.name,
        "prompt": prompt,
        "keyword": keyword,
        "turn1Completed": end1 is not None,
        "turn2Completed": end2 is not None,
        "awaySeconds": args.away,
        "lifecycleTransitions": transitions,
        "backgroundObserved": any("did-enter-background" in str(t) for t in transitions),
        "foregroundObserved": any("will-enter-foreground" in str(t) or "did-become-active" in str(t)
                                  for t in transitions),
        "sessionLogs": len(sessions),
        "sweepLabels": labels,
        "nodeLogTail": (data / RUNTIME_DIR / "DSHPortC-node.log").read_text(errors="replace").splitlines()[-25:]
        if (data / RUNTIME_DIR / "DSHPortC-node.log").exists() else [],
    }
    shutil.copy(data / "Documents" / probe_name, LOGS / f"padprobe-{args.name}.json")
    out = LOGS / f"{args.name}.json"
    out.write_text(json.dumps(result, indent=2, ensure_ascii=False))
    print(json.dumps({k: v for k, v in result.items() if k != "sweepLabels"},
                     indent=2, ensure_ascii=False))
    print(f"== report: {out}")
    ok = result["turn1Completed"] and result["turn2Completed"] \
        and result["backgroundObserved"] and result["foregroundObserved"]
    print("== PASS" if ok else "== FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
