#!/usr/bin/env python3
"""Cold-start measurement on the simulator, done so a stale file cannot fake it.

WHY NOT `scripts/e2e.py coldstart`: that script reads the node log looking for the
first `dsh web:` line, but it does not prove the line belongs to THIS launch. On a
consecutive-run machine the log survives the relaunch (the app truncates it in
`begin()`, but the poll can win the race and read the previous run's file before
the truncation lands), which produced two impossible numbers — 0.25 s and 0.26 s,
with the PREVIOUS run's port 3080 — in the step-5 measurement.

So this script:
  * terminates the app and waits for the process to be gone,
  * deletes the two artifacts before every launch, so "the file exists" cannot be
    inherited,
  * launches, and only accepts a URL whose port differs from the last run's,
  * reports the wall clock from `simctl launch` to the first status file that
    says `webViewReady`, plus the app's own `secondsSinceLaunch`.

USAGE: scripts/sim-coldstart-images.py [runs]
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SIMSET = ROOT / "simdevices"
BUNDLE_ID = "local.dshportc.app"
# Which device, from DSHPORTE_DEVICE: `phone` (default) or `ipad`. Centralised so
# a script cannot quietly measure the wrong idiom — see scripts/device_pick.py.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import device_pick  # noqa: E402

DEVICE_NAME = device_pick.name()
APP_PATH = ROOT / "DerivedData/Build/Products/Debug-iphonesimulator/DSHPortC.app"
OUT = ROOT / "logs" / "step5" / "coldstart"
ENV = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}
# The three files the app writes for observability live under Library/Application
# Support, not Documents, so they stay out of the Files app.
RUNTIME_DIR = "Library/Application Support/DSHPortC"


def run(args, *, timeout=120):
    return subprocess.run(args, capture_output=True, text=True, env=ENV, timeout=timeout)


def simctl(*args, timeout=120):
    return run(["xcrun", "simctl", "--set", str(SIMSET), *args], timeout=timeout)


def device_udid() -> str:
    return device_pick.device_udid(create_phone=False)


def container(udid: str) -> Path:
    return Path(simctl("get_app_container", udid, BUNDLE_ID, "data").stdout.strip())


def main() -> int:
    runs = int(sys.argv[1]) if len(sys.argv) > 1 else 3
    OUT.mkdir(parents=True, exist_ok=True)
    udid = device_udid()
    if f"{udid}) (Booted)" not in simctl("list", "devices").stdout:
        simctl("boot", udid)
        simctl("bootstatus", udid, timeout=300)
    simctl("terminate", udid, BUNDLE_ID)
    time.sleep(1.0)
    simctl("install", udid, str(APP_PATH))

    home = container(udid) / RUNTIME_DIR
    status_file = home / "DSHPortC-status.json"
    log_file = home / "DSHPortC-node.log"

    results = []
    last_port = None
    for index in range(1, runs + 1):
        simctl("terminate", udid, BUNDLE_ID)
        time.sleep(1.0)
        # Remove both artifacts: existence must mean "this launch wrote it".
        for path in (status_file, log_file):
            path.unlink(missing_ok=True)
        started = time.time()
        simctl("launch", udid, BUNDLE_ID)
        seconds = None
        url = None
        for _ in range(600):
            if status_file.exists():
                try:
                    data = json.loads(status_file.read_text())
                except (OSError, json.JSONDecodeError):
                    data = {}
                if data.get("phase") == "webViewReady":
                    log = log_file.read_text(errors="replace") if log_file.exists() else ""
                    match = re.search(r"dsh web: (http\S+)", log)
                    if match:
                        candidate = match.group(1)
                        port = re.search(r":(\d+)/", candidate)
                        # A URL from the previous launch would repeat its port.
                        if port and port.group(1) != last_port:
                            url = candidate
                            seconds = round(time.time() - started, 2)
                            last_port = port.group(1)
                    if seconds is not None:
                        break
            if time.time() - started > 300:
                break
            time.sleep(0.1)
        record = {
            "run": index,
            "wall_seconds": seconds,
            "app_reported": (json.loads(status_file.read_text()).get("secondsSinceLaunch")
                             if status_file.exists() else None),
            "port": last_port,
            "accepted": seconds is not None,
        }
        results.append(record)
        print(json.dumps(record, ensure_ascii=False), flush=True)

    good = [r["wall_seconds"] for r in results if r["accepted"]]
    summary = {
        "runs": len(results),
        "accepted": len(good),
        "wall_seconds": good,
        "median": sorted(good)[len(good) // 2] if good else None,
        "results": results,
    }
    (OUT / "coldstart.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps({k: v for k, v in summary.items() if k != "results"}, indent=2))
    return 0 if len(good) == runs else 1


if __name__ == "__main__":
    sys.exit(main())
