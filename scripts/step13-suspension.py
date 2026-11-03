#!/usr/bin/env python3
"""Measure how long a backgrounded app keeps being scheduled, in CPU seconds.

WHY THIS AND NOT A HEARTBEAT FILE. Every earlier step measured background
behaviour with a 2-second heartbeat written from the app, and REPORT-4B read a
gap in that file as "the process was suspended". That works on a device but it has
a blind spot on the simulator: the heartbeat is written by a timer, and a
simulator app that is still being scheduled but has nothing to do looks the same
as one that was suspended if the timer is the only clock you have.

`ps -o cputime` is a different and harder number: it is the CPU time the kernel
has actually charged to the process. It only grows while the process is being
scheduled. So the question "did iOS stop scheduling us, and if so when?" becomes
a direct reading:

  * CPU time keeps climbing  -> the process is still running;
  * CPU time frozen          -> it is not.

`stat` is useless for this: a backgrounded-but-awake process and a suspended one
both report `Ss` on Darwin.

WHAT THE RUN DOES
-----------------
  1. Install a fresh copy and start a turn whose first command prints a
     timestamp every 7 s (so the turn is genuinely busy, and so the turn's own
     log gives a second, independent clock).
  2. Wait until that command is in flight.
  3. Hand focus to another app (`simctl openurl`; there is no "press home" on
     `simctl`) and sample cumulative CPU every 5 s.
  4. Stop at the first sample where CPU stopped moving, and report that instant.

The output states the measured window, not a conclusion: `cpuFrozenAfterSeconds`
is what was observed. Whether that is "about 30 s" or "immediately" is left to the
number.

Usage
    DSHPORTE_DEVICE=phone-bg MOCK_PORT=19713 scripts/step13-suspension.py \
        [--name NAME] [--samples N] [--interval SECONDS]
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOGS = ROOT / "logs" / "step13"
BUNDLE_ID = "local.dshportc.app"
APP = ROOT / "DerivedData/Build/Products/Debug-iphonesimulator/DSHPortC.app"
SIMSET = ROOT / "simdevices"
ENV = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}
MOCK_PORT = int(os.environ.get("MOCK_PORT", "19713"))
# The three files the app writes for observability live under Library/Application
# Support, not Documents, so they stay out of the Files app.
RUNTIME_DIR = "Library/Application Support/DSHPortC"

sys.path.insert(0, str(Path(__file__).resolve().parent))
import device_pick  # noqa: E402


def simctl(*args, check=False, timeout=240):
    return subprocess.run(["xcrun", "simctl", "--set", str(SIMSET), *args],
                          capture_output=True, text=True, env=ENV, check=check, timeout=timeout)


def read_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def container(udid: str) -> Path:
    return Path(simctl("get_app_container", udid, BUNDLE_ID, "data", check=True).stdout.strip())


def pid_of_this_device(udid: str) -> int | None:
    """The app process belonging to THIS simulator.

    Filtering on the UDID inside the process's own command line matters: several
    simulators can be running the same bundle id at once (step 11 uses one, this
    step uses another), and `ps` lists them all. Matching on the executable name
    alone picked up a different device's process during development, which made a
    CPU measurement report `None` and look like the app had died.
    """
    # Match the executable inside an app bundle rather than the literal
    # `DSHPortC.app/DSHPortC`: the baseline control arm is installed from
    # `DSHPortC-baseline.app`, whose executable path ends differently. Requiring
    # the pattern `.app/DSHPortC` covers both and cannot match a helper.
    out = subprocess.run(["ps", "-axo", "pid,command"], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if ".app/DSHPortC " not in line + " " and not line.rstrip().endswith(".app/DSHPortC"):
            continue
        if udid in line:
            return int(line.split()[0])
    return None


def cpu_seconds(pid: int) -> float | None:
    """Cumulative CPU time the kernel has charged to `pid`, in seconds."""
    out = subprocess.run(["ps", "-o", "cputime=", "-p", str(pid)],
                         capture_output=True, text=True).stdout.strip()
    if not out:
        return None
    parts = out.split(":")
    try:
        if len(parts) == 3:
            return round(int(parts[0]) * 3600 + int(parts[1]) * 60 + float(parts[2]), 2)
        if len(parts) == 2:
            return round(int(parts[0]) * 60 + float(parts[1]), 2)
        return round(float(parts[0]), 2)
    except ValueError:
        return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--name", default="suspension")
    parser.add_argument("--samples", type=int, default=20)
    parser.add_argument("--interval", type=float, default=5.0)
    parser.add_argument("--arm", choices=("impl", "baseline"), default="impl",
                        help="which build to measure; the baseline copy is the pre-step-13 app")
    args = parser.parse_args()

    LOGS.mkdir(parents=True, exist_ok=True)
    udid = device_pick.device_udid(create_phone=False)
    device_pick.boot(udid)

    health = subprocess.run(["curl", "-sf", "-m", "3", f"http://127.0.0.1:{MOCK_PORT}/healthz"],
                            capture_output=True, text=True)
    if health.returncode != 0:
        raise SystemExit(f"the mock is not answering on {MOCK_PORT}")

    prompt = (ROOT / "prompts" / "19-step13-bg-turn.txt").read_text()
    app = APP
    if args.arm == "baseline":
        # The pre-step-13 copy, whose profile is pinned to this step's mock port so
        # the control run cannot talk to another checkout's server.
        app = LOGS / "baseline" / "DSHPortC-baseline.app"
    if not app.is_dir():
        raise SystemExit(f"no app bundle at {app}")
    simctl("terminate", udid, BUNDLE_ID)
    simctl("uninstall", udid, BUNDLE_ID)
    simctl("install", udid, str(app), check=True)

    env = dict(ENV)
    env["SIMCTL_CHILD_DSHPORT_UITEST_PROMPT"] = prompt
    env["SIMCTL_CHILD_DSHPORT_UITEST_KEYWORD"] = "bg-loop-done"
    subprocess.run(
        ["xcrun", "simctl", "--set", str(SIMSET), "launch", udid, BUNDLE_ID,
         "-DSHPortCTestDrive", "1", "-DSHPortCMockPort", str(MOCK_PORT)],
        capture_output=True, text=True, env=env, timeout=240,
    )

    data = container(udid)
    deadline = time.time() + 240
    while time.time() < deadline:
        if read_json(data / RUNTIME_DIR / "DSHPortC-status.json").get("phase") == "webViewReady":
            break
        time.sleep(1.0)
    # Let the turn reach its first tool call, so the process has real work.
    time.sleep(8)

    pid = pid_of_this_device(udid)
    if pid is None:
        raise SystemExit("the app process for this device was not found")
    baseline = cpu_seconds(pid)
    print(f"pid {pid}, cumulative CPU before backgrounding {baseline}s")

    simctl("openurl", udid, "https://example.com")
    backgrounded_at = time.time()
    print("backgrounded (focus handed to another app)\n")

    samples: list[dict] = []
    frozen_at: float | None = None
    for index in range(args.samples):
        time.sleep(args.interval)
        value = cpu_seconds(pid)
        elapsed = round(time.time() - backgrounded_at, 1)
        samples.append({"secondsAfterBackgrounding": elapsed, "cpuSeconds": value,
                        "alive": value is not None})
        delta = "" if index == 0 else f"  Δ={value - samples[index - 1]['cpuSeconds']:+.2f}s" \
            if value is not None and samples[index - 1]["cpuSeconds"] is not None else ""
        print(f"  t+{elapsed:>5}s  cpu={value}s{delta}")
        # Two consecutive flat samples: one flat reading can be a rounding
        # boundary on `ps`'s centisecond output, two cannot.
        if (index >= 1
                and samples[-1]["cpuSeconds"] is not None
                and samples[-2]["cpuSeconds"] is not None
                and samples[-1]["cpuSeconds"] == samples[-2]["cpuSeconds"]):
            if frozen_at is None:
                frozen_at = samples[-2]["secondsAfterBackgrounding"]
            if index >= 2 and samples[-3]["cpuSeconds"] == samples[-1]["cpuSeconds"]:
                break
        else:
            frozen_at = None

    result = {
        "name": args.name,
        "arm": args.arm,
        "app": str(app),
        "device": device_pick.name(),
        "udid": udid,
        "mockPort": MOCK_PORT,
        "pid": pid,
        "baselineCpuSeconds": baseline,
        "samples": samples,
        "cpuFrozenAfterSeconds": frozen_at,
        "cpuGrewWhileBackgrounded": bool(
            samples and samples[-1]["cpuSeconds"] is not None and baseline is not None
            and samples[-1]["cpuSeconds"] > baseline
        ),
        "totalGrowthSeconds": round(
            (samples[-1]["cpuSeconds"] or 0) - (baseline or 0), 2
        ) if samples else None,
        "intervalSeconds": args.interval,
    }
    out = LOGS / f"{args.name}.json"
    out.write_text(json.dumps(result, indent=2, ensure_ascii=False))
    print()
    print(json.dumps({k: v for k, v in result.items() if k != "samples"},
                     indent=2, ensure_ascii=False))
    print(f"== report: {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
