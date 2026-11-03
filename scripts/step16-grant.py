#!/usr/bin/env python3
"""Grant the notification permission once, on the task's own XCUITest device.

WHY A PERMISSION NEEDS A SCRIPT OF ITS OWN
------------------------------------------
`simctl privacy` has no notification service: unlike photos or location, the
notification authorization is not in its list, so it cannot be pre-granted the way
step 10 pre-granted the photo library. And no script can press the alert either — it
belongs to SpringBoard and only a UI-driving test can see it.

So the grant is produced by the one tool that can drive the alert: `xcodebuild test`
running `NotificationTests`, on a device from the DEFAULT device set (a custom `--set`
is invisible to `xcodebuild`; REPORT-13 §7 measured that). The task allows exactly one
such device for step 16: `dsh-portE-xct-16`. This script creates it, runs the grant
test on it, records the result, and shuts the device down. `--delete` removes it at
the end of the step.

WHAT IT PROVES, AND WHY THAT IS ENOUGH FOR THE REST OF THE RUN
--------------------------------------------------------------
iOS stores a notification authorization per app per device, and it survives
reinstalls of the same bundle id — measured: an install after a refusal stayed
`denied`, and an install after a grant stayed `authorized`. So ONE grant on the XCUITest
device is what makes the alert never appear again on this device, which is what lets
`step16-acceptance.py` drive `phone-bg` with plain `simctl` launches.

The other device is NOT touched: `phone-bg` is the acceptance device, and its
authorization is granted the same way, by running this test on it — which is why the
script takes `--device` and defaults to the XCUITest device.

Usage
    scripts/step16-grant.py                  # grant on dsh-portE-xct-16
    scripts/step16-grant.py --device 8A0AB0DA-...   # grant on a specific device
    scripts/step16-grant.py --delete         # remove the XCUITest device afterwards
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOGS = ROOT / "logs" / "step16"
DEVICE_NAME = os.environ.get("DSHPORTE_XCT_NAME", "dsh-portE-xct-16")
DEVICE_TYPE = "com.apple.CoreSimulator.SimDeviceType.iPhone-17"
RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
BUNDLE_ID = "local.dshportc.app"
ENV = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}
# The grant test is the one that presses the alert. It also asserts things about the
# banner afterwards, and those can fail for reasons unrelated to the grant (a banner that
# retracted before the poll saw it, a timing change in the prompt). What THIS script needs
# is the grant, so the exit code is recorded but the verdict is read from the device:
# `authorization == authorized` after the run. Measured: a run that failed its banner
# assertion had still granted the permission, and treating the exit code as the answer
# would have re-run the test forever.
GRANT_TEST = "DSHPortCUITests/NotificationTests/testGrantNotificationPermission"

# Same loopback port the rest of step 16 uses, so the app inside the test talks to this
# task's mock and not to the main checkout's.
MOCK_PORT = os.environ.get("MOCK_PORT", "19716")


def simctl(*args, check=False, timeout=300):
    return subprocess.run(["xcrun", "simctl", *args], capture_output=True, text=True,
                          env=ENV, check=check, timeout=timeout)


def simctl_set(*args, check=False, timeout=300):
    """`simctl` against this task's own device set, where the acceptance device lives.

    Two device sets are in play and they are not interchangeable: the XCUITest device is
    in the DEFAULT set because `xcodebuild` cannot see a custom `--set` (REPORT-13 §7),
    while `dsh-portE-iPhone-bg` is in this task's custom set. A bare `simctl` call cannot
    even find the second one — measured: `Invalid device or device pair` for a UDID that
    `simctl --set …/simdevices list` reports as present.
    """
    return subprocess.run(
        ["xcrun", "simctl", "--set", str(ROOT / "simdevices"), *args],
        capture_output=True, text=True, env=ENV, check=check, timeout=timeout)


def find(name: str, custom: bool = False) -> str:
    out = (simctl_set if custom else simctl)("list", "devices").stdout
    for line in out.splitlines():
        match = re.search(r"^\s+(.+?) \(([0-9A-F-]{36})\) \(", line)
        if match and match.group(1).strip() == name:
            return match.group(2)
    return ""


def ensure_device() -> str:
    udid = find(DEVICE_NAME)
    if udid:
        return udid
    created = simctl("create", DEVICE_NAME, DEVICE_TYPE, RUNTIME)
    udid = created.stdout.strip().splitlines()[-1] if created.stdout.strip() else ""
    if not udid:
        raise SystemExit(f"could not create {DEVICE_NAME}: {created.stderr.strip()}")
    print(f"created {DEVICE_NAME} ({udid})")
    return udid


def authorization_of(udid: str, custom: bool = False) -> str:
    out = (simctl_set if custom else simctl)("get_app_container", udid, BUNDLE_ID, "data")
    if out.returncode != 0:
        return "no-install"
    status = Path(out.stdout.strip()) / "Library/Application Support/DSHPortC" / "DSHPortC-status.json"
    try:
        data = json.loads(status.read_text())
    except (OSError, json.JSONDecodeError):
        return "no-status"
    return (data.get("notifications") or {}).get("authorization", "absent")


def run_grant_test(udid: str) -> tuple[int, str]:
    LOGS.mkdir(parents=True, exist_ok=True)
    log = LOGS / "grant.log"
    started = time.time()
    proc = subprocess.run(
        [
            "xcodebuild", "test",
            "-project", str(ROOT / "app/DSHPortC.xcodeproj"),
            "-scheme", "DSHPortC",
            "-configuration", "Debug",
            "-sdk", "iphonesimulator",
            "-derivedDataPath", str(ROOT / "DerivedData"),
            "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES",
            "-destination", f"platform=iOS Simulator,id={udid}",
            "-only-testing:" + GRANT_TEST,
        ],
        capture_output=True, text=True, cwd=str(ROOT),
        env={**ENV, "MOCK_PORT": MOCK_PORT,
             "SIMCTL_CHILD_DSHPORT_MOCK_PORT": MOCK_PORT},
        timeout=1800,
    )
    log.write_text(proc.stdout + "\n== stderr ==\n" + proc.stderr)
    failure = ""
    for line in (proc.stdout + proc.stderr).splitlines():
        if "error:" in line or "XCTAssert" in line:
            failure = line.strip()
    elapsed = round(time.time() - started, 1)
    return proc.returncode, f"{elapsed}s; {failure}" if failure else f"{elapsed}s; no failure line"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--device", default="", help="UDID to grant on; default is the XCUITest device")
    parser.add_argument("--delete", action="store_true", help="delete the XCUITest device afterwards")
    parser.add_argument("--keep-booted", action="store_true")
    args = parser.parse_args()

    if args.delete:
        udid = find(DEVICE_NAME)
        if not udid:
            print(f"{DEVICE_NAME} does not exist; nothing to delete")
            return 0
        simctl("shutdown", udid)
        time.sleep(2)
        simctl("delete", udid)
        print(f"deleted {DEVICE_NAME} ({udid})")
        return 0

    udid = args.device or ensure_device()
    # Which set the device belongs to decides which `simctl` can address it at all.
    custom = bool(args.device) and simctl_set("list", "devices").stdout.find(udid) >= 0
    booted = (simctl_set if custom else simctl)("boot", udid)
    if booted.returncode != 0 and "Unable to boot device in current state: Booted" not in booted.stderr:
        raise SystemExit(f"could not boot {udid}: {booted.stderr.strip()}")
    # `bootstatus` waits for SpringBoard, which the alert needs.
    subprocess.run(["xcrun", "simctl", "bootstatus", udid, "-b"],
                   capture_output=True, text=True, env=ENV, timeout=600)

    before = authorization_of(udid, custom=custom)

    # The permission alert only appears once per app per device. A previous grant makes
    # it absent, and the test's "the alert appeared" assertion would then fail for a
    # correct state — so an existing grant short-circuits instead of re-running.
    if before in ("authorized", "provisional", "ephemeral"):
        result = {"device": udid, "before": before, "granted": True,
                  "reason": "already authorized; the alert does not appear again"}
    else:
        # Uninstall first: an install whose permission is `denied` cannot be re-asked,
        # so a half-run state has to be cleared to get a fresh alert.
        (simctl_set if custom else simctl)("uninstall", udid, BUNDLE_ID)
        time.sleep(2)
        code, detail = run_grant_test(udid)
        after = authorization_of(udid, custom=custom)
        result = {
            "device": udid,
            "before": before,
            "testExit": code,
            "testDetail": detail,
            "after": after,
            "granted": after in ("authorized", "provisional", "ephemeral"),
        }

    LOGS.mkdir(parents=True, exist_ok=True)
    (LOGS / "grant.json").write_text(json.dumps(result, indent=2, ensure_ascii=False))
    print(json.dumps(result, indent=2, ensure_ascii=False))

    if not args.keep_booted:
        (simctl_set if custom else simctl)("shutdown", udid)
    return 0 if result["granted"] else 1


if __name__ == "__main__":
    sys.exit(main())
