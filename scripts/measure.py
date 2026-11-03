#!/usr/bin/env python3
"""Measure cold start and memory for DSHPortC, writing raw logs the report quotes.

Cold start is defined as: `simctl launch` returns ->
`Library/Application Support/DSHPortC/DSHPortC-status.json` reports
`phase == "webViewReady"`, i.e. the embedded Node has printed its URL, the web view
has navigated, and the first paint has finished. That is the moment the interface
becomes usable, which is the number the task asks for.

Memory is `ps -o rss=` against the app process once per second, averaged, in the
same way the B-stage report measured dsh-ios so the two are comparable.
"""

from __future__ import annotations

import json
import os
import statistics
import subprocess
import sys
import time
from pathlib import Path

# Resolved from this file, not hardcoded: a copied script that still
# points at the original task directory reads and writes the wrong tree.
ROOT = Path(__file__).resolve().parent.parent
LOGS = ROOT / "logs"
BUNDLE_ID = "local.dshportc.app"
SIMSET = ROOT / "simdevices"
APP = ROOT / "DerivedData/Build/Products/Debug-iphonesimulator/DSHPortC.app"
ENV = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}
# The three files the app writes for observability live under Library/Application
# Support, not Documents, so they stay out of the Files app.
RUNTIME_DIR = "Library/Application Support/DSHPortC"


def simctl(*args: str, timeout: float = 180) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["xcrun", "simctl", "--set", str(SIMSET), *args],
        capture_output=True, text=True, env=ENV, timeout=timeout,
    )


def udid() -> str:
    listing = simctl("list", "devices").stdout
    for line in listing.splitlines():
        if "dsh-portE-iPhone (" in line and "(Booted)" in line:
            return line.split("(")[1].split(")")[0]
    raise SystemExit("no booted dsh-portE-iPhone")


def data_container(device: str) -> Path | None:
    result = simctl("get_app_container", device, BUNDLE_ID, "data")
    if result.returncode != 0:
        return None
    return Path(result.stdout.strip())


def status(device: str) -> dict:
    container = data_container(device)
    if container is None:
        return {}
    path = container / RUNTIME_DIR / "DSHPortC-status.json"
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def app_pid() -> int | None:
    out = subprocess.run(
        ["ps", "-axo", "pid,comm"], capture_output=True, text=True
    ).stdout
    for line in out.splitlines():
        if line.rstrip().endswith("DSHPortC.app/DSHPortC"):
            return int(line.split()[0])
    return None


def rss_kb(pid: int) -> int | None:
    out = subprocess.run(
        ["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True
    ).stdout.strip()
    return int(out) if out else None


def cold_start(device: str, run: int, timeout: float = 300) -> float:
    simctl("terminate", device, BUNDLE_ID)
    # Remove the previous run's status and log. Without this the loop below reads
    # a stale "webViewReady" the instant it starts and reports a fraction of a
    # second — a mistake this script made on its first attempt.
    container = data_container(device)
    if container is not None:
        for name in ("DSHPortC-status.json", "DSHPortC-node.log",
                     "DSHPortC-session-url.txt"):
            try:
                (container / RUNTIME_DIR / name).unlink()
            except OSError:
                pass
    time.sleep(2.5)
    start = time.time()
    simctl("launch", device, BUNDLE_ID)
    while time.time() - start < timeout:
        phase = status(device).get("phase")
        if phase == "webViewReady":
            elapsed = round(time.time() - start, 2)
            (LOGS / "coldstart-times.txt").open("a").write(f"{elapsed}\n")
            print(f"run {run}: {elapsed}s")
            return elapsed
        if phase == "failed":
            raise SystemExit(f"run {run} failed: {status(device).get('error')}")
        time.sleep(0.1)
    raise SystemExit(f"run {run}: timed out after {timeout}s")


def sample(label: str, seconds: int) -> dict:
    pid = app_pid()
    if pid is None:
        raise SystemExit("app is not running")
    rows = []
    for _ in range(seconds):
        rss = rss_kb(pid)
        if rss is not None:
            rows.append(rss)
        time.sleep(1)
    if not rows:
        raise SystemExit("no samples")
    mb = [value / 1024.0 for value in rows]
    summary = {
        "label": label,
        "pid": pid,
        "samples": len(rows),
        "avg_mb": round(statistics.mean(mb), 1),
        "min_mb": round(min(mb), 1),
        "max_mb": round(max(mb), 1),
        "median_mb": round(statistics.median(mb), 1),
    }
    (LOGS / f"memory-{label}.json").write_text(
        json.dumps({"summary": summary, "rss_kb": rows}, indent=2)
    )
    print(json.dumps(summary))
    return summary


def main() -> int:
    LOGS.mkdir(parents=True, exist_ok=True)
    device = udid()
    command = sys.argv[1] if len(sys.argv) > 1 else "coldstart"
    print(f"device {device}")

    if command == "coldstart":
        count = int(sys.argv[2]) if len(sys.argv) > 2 else 3
        times = [cold_start(device, index + 1) for index in range(count)]
        summary = {
            "runs": times,
            "median": round(statistics.median(times), 2),
            "min": min(times),
            "max": max(times),
        }
        (LOGS / "coldstart-summary.json").write_text(json.dumps(summary, indent=2))
        print(json.dumps(summary))
        return 0

    if command == "memory":
        seconds = int(sys.argv[2]) if len(sys.argv) > 2 else 30
        sample(sys.argv[3] if len(sys.argv) > 3 else "idle", seconds)
        return 0

    print(f"unknown command {command}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
