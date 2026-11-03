#!/usr/bin/env python3
"""Drive the DSHPortC app in the iOS simulator and record what actually happens.

This is the acceptance harness. It does not inspect the app's internals; it only
uses channels a user could also use:

  * `simctl launch` / `terminate` for lifecycle,
  * the loopback HTTP port DSH serves for the web UI,
  * `Library/Application Support/DSHPortC/DSHPortC-status.json`, which the app
    writes for observability,
  * `ps` for the in-process RSS,
  * `simctl io screenshot` for visual evidence.

Everything it prints goes into logs/e2e-*.log so the report can cite raw output.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

# Resolved from this file, not hardcoded: a copied script that still
# points at the original task directory reads and writes the wrong tree.
ROOT = Path(__file__).resolve().parent.parent
LOGS = ROOT / "logs"
SHOTS = ROOT / "screenshots"
SIMSET = ROOT / "simdevices"
BUNDLE_ID = "local.dshportc.app"
APP_PATH = ROOT / "DerivedData/Build/Products/Debug-iphonesimulator/DSHPortC.app"
DEVICE_NAME = "dsh-portE-iPhone"
DEVICE_TYPE = "com.apple.CoreSimulator.SimDeviceType.iPhone-17"
RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
MOCK_PORT = int(os.environ.get("MOCK_PORT", "19700"))

ENV = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}
# The three files the app writes for observability live under Library/Application
# Support, not Documents, so they stay out of the Files app.
RUNTIME_DIR = "Library/Application Support/DSHPortC"


def run(args: list[str], *, check: bool = False, timeout: float = 120) -> subprocess.CompletedProcess:
    return subprocess.run(args, capture_output=True, text=True, env=ENV, check=check, timeout=timeout)


def simctl(*args: str, check: bool = False, timeout: float = 120) -> subprocess.CompletedProcess:
    return run(["xcrun", "simctl", "--set", str(SIMSET), *args], check=check, timeout=timeout)


def device_udid() -> str:
    listing = simctl("list", "devices").stdout
    found = [
        match.group(1)
        for line in listing.splitlines()
        if (match := re.match(rf"\s*{re.escape(DEVICE_NAME)} \(([0-9A-F-]+)\)", line))
    ]
    if len(found) > 1:
        print(f"WARNING {DEVICE_NAME} exists {len(found)} times: {found}; using the first", flush=True)
    if found:
        return found[0]
    return simctl("create", DEVICE_NAME, DEVICE_TYPE, RUNTIME, check=True).stdout.strip()


def boot(udid: str) -> None:
    state = simctl("list", "devices").stdout
    if f"{udid}) (Booted)" not in state:
        simctl("boot", udid)
        simctl("bootstatus", udid, timeout=300)


def install(udid: str) -> None:
    simctl("install", udid, str(APP_PATH), check=True)


def terminate(udid: str) -> None:
    simctl("terminate", udid, BUNDLE_ID)


def data_container(udid: str) -> Path:
    out = simctl("get_app_container", udid, BUNDLE_ID, "data", check=True).stdout.strip()
    return Path(out)


def read_status(udid: str) -> dict:
    status_path = data_container(udid) / RUNTIME_DIR / "DSHPortC-status.json"
    try:
        return json.loads(status_path.read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def read_node_log(udid: str) -> str:
    log_path = data_container(udid) / RUNTIME_DIR / "DSHPortC-node.log"
    try:
        return log_path.read_text()
    except OSError:
        return ""


def app_pid() -> int | None:
    out = run(["ps", "-axo", "pid,comm"]).stdout
    for line in out.splitlines():
        if line.rstrip().endswith("DSHPortC.app/DSHPortC"):
            return int(line.split()[0])
    return None


def rss_mb(pid: int) -> float | None:
    out = run(["ps", "-o", "rss=", "-p", str(pid)]).stdout.strip()
    if not out:
        return None
    return round(int(out) / 1024.0, 1)


def http_get(url: str, timeout: float = 5) -> tuple[int, str]:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            return response.status, response.read(2048).decode("utf-8", "replace")
    except urllib.error.HTTPError as error:
        return error.code, ""
    except Exception as error:  # noqa: BLE001 - the message is the interesting part
        return -1, str(error)


def screenshot(udid: str, name: str) -> Path:
    SHOTS.mkdir(parents=True, exist_ok=True)
    path = SHOTS / f"{name}.png"
    simctl("io", udid, "screenshot", str(path), check=True)
    return path


def wait_for(predicate, *, timeout: float, interval: float = 0.2, describe: str = "condition"):
    start = time.time()
    while time.time() - start < timeout:
        value = predicate()
        if value:
            return value, time.time() - start
        time.sleep(interval)
    raise TimeoutError(f"timed out after {timeout}s waiting for {describe}")


# --------------------------------------------------------------------------- launch

@dataclass
class LaunchResult:
    seconds: float
    url: str
    log: str
    status: dict = field(default_factory=dict)


def cold_start(udid: str, *, mock_ready: bool = True) -> LaunchResult:
    """Terminate, wait for the port to die, launch, and time until the URL exists."""
    terminate(udid)
    time.sleep(1.5)

    start = time.time()
    simctl("launch", udid, BUNDLE_ID)

    def printed_url() -> str | None:
        log = read_node_log(udid)
        match = re.search(r"dsh web: (http\S+)", log)
        if match:
            return match.group(1)
        status = read_status(udid)
        if status.get("phase") == "failed":
            raise RuntimeError(f"app reported failure: {status.get('error')}")
        return None

    try:
        url, _ = wait_for(printed_url, timeout=300, describe="dsh web url in the node log")
    except RuntimeError:
        raise
    elapsed = time.time() - start
    return LaunchResult(seconds=round(elapsed, 2), url=url, log=read_node_log(udid), status=read_status(udid))


def wait_webview_ready(udid: str, *, timeout: float = 120) -> float:
    start = time.time()

    def ready() -> bool:
        return read_status(udid).get("phase") == "webViewReady"

    _, _ = wait_for(ready, timeout=timeout, describe="webViewReady phase")
    # webViewReady is the WKWebView's didFinish; report the wall clock from launch.
    return round(time.time() - start, 2)


def main() -> int:
    LOGS.mkdir(parents=True, exist_ok=True)
    command = sys.argv[1] if len(sys.argv) > 1 else "status"
    udid = device_udid()
    print(f"device {udid}")

    if command == "install":
        boot(udid)
        install(udid)
        print("installed")
        return 0

    if command == "status":
        print(json.dumps(read_status(udid), indent=2, ensure_ascii=False))
        return 0

    if command == "log":
        print(read_node_log(udid))
        return 0

    if command == "coldstart":
        count = int(sys.argv[2]) if len(sys.argv) > 2 else 1
        boot(udid)
        install(udid)
        results = []
        for index in range(count):
            result = cold_start(udid)
            print(f"run {index + 1}: {result.seconds}s  url={redact_url(result.url)}")
            results.append(result.seconds)
            time.sleep(2)
        print(json.dumps({"cold_start_seconds": results}))
        return 0

    if command == "verify":
        boot(udid)
        install(udid)
        result = cold_start(udid)
        print(f"url ready in {result.seconds}s")
        print("runtime facts:")
        node = result.status.get("node", {})
        print(json.dumps(node, indent=2, ensure_ascii=False))

        code, body = http_get(result.url)
        print(f"GET {redact_url(result.url)} -> {code} ({len(body)} bytes)")

        pid = app_pid()
        print(f"app pid {pid}, rss {rss_mb(pid) if pid else '?'} MB")
        screenshot(udid, "verify-01-boot")
        return 0

    print(f"unknown command {command}")
    return 2


def redact_url(url: str) -> str:
    return re.sub(r"token=[A-Za-z0-9._~+/=-]+", "token=<redacted>", url)


if __name__ == "__main__":
    sys.exit(main())
