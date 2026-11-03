#!/usr/bin/env python3
"""Measure cold start: simctl launch -> status.phase == webViewReady.

The same metric REPORT-1 and REPORT-2 used, so the numbers are comparable. The
step-2 report asked step 5 for one specific thing: measure the GUEST-ON path
separately, because the earlier 4.45 s was taken with the guest off and step 5
makes it the default.

Usage
    scripts/coldstart.py [--runs N] [--guest on|off] [--label NAME]
"""

from __future__ import annotations

import argparse
import json
import os
import statistics
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOGS = ROOT / "logs"
SIMSET = ROOT / "simdevices"
BUNDLE_ID = "local.dshportc.app"
APP_PATH = ROOT / "DerivedData/Build/Products/Debug-iphonesimulator/DSHPortC.app"
ENV = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}
# The three files the app writes for observability live under Library/Application
# Support, not Documents, so they stay out of the Files app.
RUNTIME_DIR = "Library/Application Support/DSHPortC"

# Which device, from DSHPORTE_DEVICE: `phone` (default) or `ipad`. Centralised so
# a script cannot quietly measure the wrong idiom — see scripts/device_pick.py.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import device_pick  # noqa: E402

DEVICE_NAME = device_pick.name()


def simctl(*args, check=False, timeout=180):
    return subprocess.run(["xcrun", "simctl", "--set", str(SIMSET), *args],
                          capture_output=True, text=True, env=ENV, check=check, timeout=timeout)


def device_udid() -> str:
    return device_pick.device_udid()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--guest", choices=["on", "off"], default="on")
    parser.add_argument("--label", default=None)
    args = parser.parse_args()

    udid = device_udid()
    if f"{udid}) (Booted)" not in simctl("list", "devices").stdout:
        simctl("boot", udid)
        simctl("bootstatus", udid, timeout=300)

    simctl("terminate", udid, BUNDLE_ID)
    simctl("uninstall", udid, BUNDLE_ID)
    simctl("install", udid, str(APP_PATH), check=True)

    env = dict(ENV)
    env["SIMCTL_CHILD_DSHPORTE_GUEST_CHANNEL"] = "1" if args.guest == "on" else "0"

    runs = []
    for index in range(args.runs):
        simctl("terminate", udid, BUNDLE_ID)
        time.sleep(1.5)
        # REMOVE THE PREVIOUS RUN'S STATUS FILE FIRST. It survives the process and
        # the container, so a poll that starts after launch can read the PREVIOUS
        # run's `webViewReady` and report a fraction of a second. Measured: one
        # run reported 0.25 s, which is the file, not the boot.
        container = simctl("get_app_container", udid, BUNDLE_ID, "data").stdout.strip()
        if container:
            stale = Path(container) / RUNTIME_DIR / "DSHPortC-status.json"
            try:
                stale.unlink()
            except OSError:
                pass
        started = time.time()
        subprocess.run(["xcrun", "simctl", "--set", str(SIMSET), "launch", udid, BUNDLE_ID],
                       capture_output=True, text=True, env=env, timeout=120)
        # Poll the status file the app writes; that is the metric.
        deadline = time.time() + 300
        elapsed = None
        while time.time() < deadline:
            container = simctl("get_app_container", udid, BUNDLE_ID, "data").stdout.strip()
            if container:
                status_path = Path(container) / RUNTIME_DIR / "DSHPortC-status.json"
                try:
                    status = json.loads(status_path.read_text())
                except (OSError, json.JSONDecodeError):
                    status = {}
                if status.get("phase") == "webViewReady":
                    elapsed = time.time() - started
                    break
                if status.get("phase") == "failed":
                    print(f"run {index + 1}: FAILED {status.get('error')}", file=sys.stderr)
                    break
            time.sleep(0.1)
        if elapsed is None:
            print(f"run {index + 1}: timed out", file=sys.stderr)
            continue
        runs.append(round(elapsed, 2))
        print(f"run {index + 1}: {elapsed:.2f}s")
        time.sleep(2)

    summary = {
        "metric": f"simctl launch -> {RUNTIME_DIR}/DSHPortC-status.json phase == webViewReady",
        "guest_channel": args.guest,
        "runs": runs,
        "median": round(statistics.median(runs), 2) if runs else None,
        "min": min(runs) if runs else None,
        "max": max(runs) if runs else None,
        "reference": {
            "step1": 4.89,
            "step2_guest_off": 4.45,
            "_note": "both measured on this device with this metric; see REPORT-1 §8.1 and REPORT-2 §10.2",
        },
    }
    label = args.label or f"coldstart-guest-{args.guest}"
    out = LOGS / f"{label}.json"
    out.write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
