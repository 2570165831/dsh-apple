#!/usr/bin/env python3
"""Launch DSHPortC on this task's own simulator with step 18's probe on.

One launch, then the caller drives the UI with `scripts/step18_probe.py` and
`simctl`/XCUITest. Kept separate from `step11-state.py` because that script's job
is "one launch per measurement" (its states are scripted inside the app), while
this one is "one launch, then the host pokes the UI" — the sweep's screens are
reached by taps, not by launch arguments.

    python3 scripts/step18_launch.py                 # phone-polish, watch on
    python3 scripts/step18_launch.py --device ipad
    python3 scripts/step18_launch.py --no-watch --tag before
    python3 scripts/step18_launch.py --terminate
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import device_pick as pick  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
MOCK_PORT = "19718"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--device", default="phone-polish")
    parser.add_argument("--tag", default="")
    parser.add_argument("--no-watch", action="store_true")
    parser.add_argument("--terminate", action="store_true")
    parser.add_argument("--no-install", action="store_true")
    parser.add_argument("--wait", type=float, default=0.0,
                        help="seconds to wait for the composer before returning")
    args = parser.parse_args()

    os.environ["DSHPORTE_DEVICE"] = args.device
    udid = pick.device_udid()
    pick.boot(udid)

    if args.terminate:
        pick.simctl("terminate", udid, pick.BUNDLE_ID)
        print("terminated")
        return 0

    if not args.no_install:
        pick.simctl("install", udid, str(pick.APP_PATH), check=True)
    # A launch argument is per-launch, unlike SIMCTL_CHILD_* which this simulator
    # keeps from the first launch until the device shuts down (REPORT-5 records
    # the measurement). The probe reads the argument domain for that reason.
    pick.simctl("terminate", udid, pick.BUNDLE_ID)
    time.sleep(1.0)

    launch_args = [
        "-DSHPortEStep18", "1",
        "-DSHPortCMockPort", MOCK_PORT,
    ]
    if args.tag:
        launch_args += ["-DSHPortEStep18Tag", args.tag]
    if not args.no_watch:
        launch_args += ["-DSHPortEStep18Watch", "1"]

    out = subprocess.run(
        ["xcrun", "simctl", "--set", str(pick.SIMSET), "launch", udid, pick.BUNDLE_ID, *launch_args],
        capture_output=True, text=True, env=pick.ENV, timeout=120,
    )
    if out.returncode != 0:
        raise SystemExit(f"launch failed: {out.stderr.strip()}")
    print(f"launched {out.stdout.strip()}")

    if args.wait > 0:
        deadline = time.time() + args.wait
        container = pick.data_container(udid)
        while time.time() < deadline:
            # The probe's own status file is written at registration, which is
            # before the page exists; the composer is the page-side readiness
            # signal, so it has to be asked for.
            reply = ask_quietly(container, "document.querySelector('[data-composer-input]') !== null")
            if reply is True:
                print("composer ready")
                return 0
            time.sleep(1.0)
        print("composer did not appear within the wait window")
        return 1
    return 0


def ask_quietly(container: Path, script: str) -> object:
    import json
    import uuid
    command_id = uuid.uuid4().hex[:12]
    (container / "Documents" / "step18-cmd.json").write_text(
        json.dumps({"id": command_id, "script": script}), encoding="utf-8")
    reply = container / "Documents" / f"step18-out-{command_id}.json"
    deadline = time.time() + 3.0
    while time.time() < deadline:
        if reply.exists():
            try:
                payload = json.loads(reply.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                time.sleep(0.1)
                continue
            reply.unlink(missing_ok=True)
            return payload.get("value")
        time.sleep(0.1)
    return None


if __name__ == "__main__":
    raise SystemExit(main())
