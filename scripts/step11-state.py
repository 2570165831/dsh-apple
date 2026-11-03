#!/usr/bin/env python3
"""Run one Step 11 interaction state on a simulator and collect the probe file.

One launch per state. The container survives between launches, so each state
writes `DSHPortE-step11-<tag>.json` instead of a shared file; a shared file would
be overwritten by whatever ran last and the report would quote the wrong state.

    python3 scripts/step11-state.py --action focus --tag 01-focus-before
    python3 scripts/step11-state.py --action type  --tag 02-type-before --device ipad

The sequence is deliberately the same one a person performs: press Home (so the
launch is a cold start), launch with the probe flags, wait for the probe file to
say `done`, pull the file, screenshot, terminate. Waiting for `done` rather than
sleeping a fixed time is what keeps a slow launch from being recorded as a page
with no measurements in it.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import tempfile
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import device_pick as pick  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
LOGS = ROOT / "logs" / "step11"
SHOTS = ROOT / "screenshots" / "step11"


def launch(udid: str, args: list[str], env: dict[str, str] | None = None) -> dict:
    full_env = {**pick.ENV}
    if env:
        full_env.update({f"SIMCTL_CHILD_{k}": v for k, v in env.items()})
    out = subprocess.run(
        ["xcrun", "simctl", "--set", str(pick.SIMSET), "launch", udid, pick.BUNDLE_ID, *args],
        capture_output=True, text=True, env=full_env, timeout=120,
    )
    if out.returncode != 0:
        raise SystemExit(f"launch failed: {out.stderr.strip()}")
    return {"stdout": out.stdout.strip(), "stderr": out.stderr.strip()}


def container(udid: str) -> Path:
    return Path(pick.simctl("get_app_container", udid, pick.BUNDLE_ID, "data", check=True).stdout.strip())


def probe_path(udid: str, tag: str) -> Path:
    name = "DSHPortE-step11.json" if not tag else f"DSHPortE-step11-{tag}.json"
    return container(udid) / "Documents" / name


def wait_for_done(path: Path, timeout: float) -> dict:
    """Poll the probe file until it records `done`, then return its contents."""
    deadline = time.time() + timeout
    last: dict = {}
    while time.time() < deadline:
        try:
            last = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            time.sleep(0.5)
            continue
        events = last.get("records") or []
        if any(record.get("event") == "done" for record in events):
            return last
        time.sleep(0.5)
    return last


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--action", default="idle",
                        choices=["idle", "focus", "type", "send", "long", "zoom"])
    parser.add_argument("--tag", default="")
    parser.add_argument("--device", default=None, help="phone or ipad")
    parser.add_argument("--timeout", type=float, default=180.0)
    parser.add_argument("--orientation", default=None, choices=["portrait", "landscape"])
    parser.add_argument("--pre-script", default=None,
                        help="run a host script before launching (e.g. seed a long conversation)")
    parser.add_argument("--no-screenshot", action="store_true")
    args = parser.parse_args()

    if args.device:
        os.environ["DSHPORTE_DEVICE"] = args.device

    LOGS.mkdir(parents=True, exist_ok=True)
    SHOTS.mkdir(parents=True, exist_ok=True)

    udid = pick.device_udid()
    pick.boot(udid)
    pick.simctl("install", udid, str(pick.APP_PATH), check=True)
    pick.simctl("terminate", udid, pick.BUNDLE_ID)
    time.sleep(1.0)

    target = probe_path(udid, args.tag)
    target.unlink(missing_ok=True)

    if args.pre_script:
        subprocess.run([args.pre_script], check=True, env={**pick.ENV, "DSHPORTE_DEVICE": pick.kind()})

    launch_args = [
        "-DSHPortEStep11", "1",
        "-DSHPortEStep11Action", args.action,
    ]
    if args.tag:
        launch_args += ["-DSHPortEStep11Tag", args.tag]
    if args.orientation:
        launch_args += ["-DSHPortEStep11Rotate", args.orientation]

    started = time.time()
    info = launch(udid, launch_args)

    probe = wait_for_done(target, args.timeout)
    elapsed = round(time.time() - started, 2)

    shot_path = None
    shot_error = None
    if not args.no_screenshot:
        shot = SHOTS / f"{args.tag or args.action}.png"
        # THROUGH /tmp, NOT STRAIGHT TO THE TASK VOLUME.
        #
        # `simctl io screenshot` writes as a helper process that this machine has
        # not granted access to an external volume: writing the PNG there fails with
        # "You don't have permission … NSPOSIXErrorDomain code=1" while the same
        # command into /tmp succeeds and `cp` then copies it across. Measured, not
        # guessed — the first full matrix silently produced zero PNGs for exactly
        # this reason, and the failure was only visible because this script now
        # records it.
        staging = Path(tempfile.mkdtemp(prefix="step11-shot-")) / "shot.png"
        shot_result = pick.simctl("io", udid, "screenshot", str(staging))
        if staging.exists():
            shutil.copyfile(staging, shot)
            shot_path = str(shot)
        else:
            shot_error = (shot_result.stderr or shot_result.stdout or "").strip()[:200]
        shutil.rmtree(staging.parent, ignore_errors=True)

    copy = LOGS / f"{args.tag or args.action}.json"
    if target.exists():
        shutil.copyfile(target, copy)

    records = probe.get("records") or []
    summary = {
        "tag": args.tag or args.action,
        "action": args.action,
        "device": pick.name(),
        "udid": udid,
        "elapsedSeconds": elapsed,
        "recordCount": len(records),
        "labels": [record.get("label") for record in records if record.get("label")],
        "done": any(record.get("event") == "done" for record in records),
        "probeFile": str(copy) if copy.exists() else None,
        "screenshot": shot_path,
        "screenshotError": shot_error,
        "launch": info,
    }
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0 if summary["done"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
