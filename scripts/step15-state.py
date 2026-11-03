#!/usr/bin/env python3
"""Run one Step 15 probe state on a simulator and collect the probe file.

One launch per state, same reason as step 11: the container survives between
launches, so a state that reused the previous process's page would be measuring
whatever the last state left behind.

    python3 scripts/step15-state.py --action dump --tag 01-dump
    python3 scripts/step15-state.py --action ime  --tag 02-ime --hold 6

States that need the software keyboard set it first (the simulator ships with
"simulate hardware keyboard" ON, in which case no soft keyboard appears at all
and the keyboard states measure nothing).

Screenshots go through a staging directory: `simctl io screenshot` cannot write
straight to an external volume from this machine (`NSPOSIXErrorDomain code=1`), a
fact step 11 recorded and this script keeps.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import device_pick as pick  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
LOGS = ROOT / "logs" / "step15"
SHOTS = ROOT / "screenshots" / "step15"

ACTIONS = ["dump", "safearea", "ime", "sidebar", "dark", "code",
           "resume", "rail", "send", "tap", "eval", "mismatch", "boot", "steer"]


def launch(udid: str, args: list[str]) -> dict:
    out = subprocess.run(
        ["xcrun", "simctl", "--set", str(pick.SIMSET), "launch", udid, pick.BUNDLE_ID, *args],
        capture_output=True, text=True, env=pick.ENV, timeout=180,
    )
    if out.returncode != 0:
        raise SystemExit(f"launch failed: {out.stderr.strip()}")
    return {"stdout": out.stdout.strip(), "stderr": out.stderr.strip()}


def container(udid: str) -> Path:
    return Path(pick.simctl("get_app_container", udid, pick.BUNDLE_ID, "data", check=True).stdout.strip())


def probe_path(udid: str, tag: str) -> Path:
    name = "DSHPortE-step15.json" if not tag else f"DSHPortE-step15-{tag}.json"
    return container(udid) / "Documents" / name


def wait_for_done(path: Path, timeout: float) -> dict:
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


def shot(udid: str, target: Path) -> tuple[str | None, str | None]:
    staging = Path(tempfile.mkdtemp(prefix="step15-shot-")) / "shot.png"
    result = pick.simctl("io", udid, "screenshot", str(staging))
    try:
        if staging.exists():
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(staging, target)
            return str(target), None
        return None, (result.stderr or result.stdout or "").strip()[:200]
    finally:
        shutil.rmtree(staging.parent, ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--action", default="dump", choices=ACTIONS)
    parser.add_argument("--tag", default="")
    parser.add_argument("--device", default=None, help="phone, ipad, or a name from device_pick")
    parser.add_argument("--timeout", type=float, default=300.0)
    parser.add_argument("--hold", type=float, default=None,
                        help="seconds to hold where the state is time-shaped")
    parser.add_argument("--appearance", default=None, choices=["light", "dark", "system"])
    parser.add_argument("--rotate", default=None, choices=["portrait", "landscape"])
    parser.add_argument("--marker", default=None,
                        help="for --action steer: a unique marker put in the steered text")
    parser.add_argument("--page-theme", default=None, choices=["light", "dark", "system"],
                        help="for --action mismatch: the theme the page is forced into")
    parser.add_argument("--script", default=None,
                        help="for --action eval: a JavaScript file run first")
    parser.add_argument("--script2", default=None,
                        help="for --action eval: a JavaScript file run after --hold seconds")
    parser.add_argument("--script3", default=None,
                        help="for --action eval: a third JavaScript file run after a second --hold")
    parser.add_argument("--script4", default=None,
                        help="for --action eval: a fourth JavaScript file")
    parser.add_argument("--script5", default=None,
                        help="for --action eval: a fifth JavaScript file")
    parser.add_argument("--no-screenshot", action="store_true")
    parser.add_argument("--no-softkeyboard", action="store_true")
    parser.add_argument("--keep-running", action="store_true",
                        help="leave the app running afterwards (for a following shot)")
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

    if not args.no_softkeyboard:
        subprocess.run([str(ROOT / "tools/kbd/softkeyboard"), str(pick.SIMSET), udid, "soft"],
                       capture_output=True, text=True, env=pick.ENV, timeout=120)

    target = probe_path(udid, args.tag)
    target.unlink(missing_ok=True)

    # EVERY eval script file is removed first, not just this run's.
    #
    # The probe runs script1…script5 in order if they exist, so a file left by a
    # previous run would be executed again and its output would look like this
    # run's evidence. That happened once and produced a phase-3 record from an
    # experiment that was no longer on screen; every subsequent run clears the
    # whole set before writing.
    documents = container(udid) / "Documents"
    for index in range(1, 6):
        name = ("DSHPortE-step15-script.js" if index == 1
                else f"DSHPortE-step15-script{index}.js")
        (documents / name).unlink(missing_ok=True)

    if args.script:
        script_path = container(udid) / "Documents" / "DSHPortE-step15-script.js"
        script_path.parent.mkdir(parents=True, exist_ok=True)
        script_path.write_text(Path(args.script).read_text(encoding="utf-8"), encoding="utf-8")
    if args.script2:
        second_path = container(udid) / "Documents" / "DSHPortE-step15-script2.js"
        second_path.write_text(Path(args.script2).read_text(encoding="utf-8"), encoding="utf-8")
    if args.script3:
        third_path = container(udid) / "Documents" / "DSHPortE-step15-script3.js"
        third_path.write_text(Path(args.script3).read_text(encoding="utf-8"), encoding="utf-8")
    if args.script4:
        fourth = container(udid) / "Documents" / "DSHPortE-step15-script4.js"
        fourth.write_text(Path(args.script4).read_text(encoding="utf-8"), encoding="utf-8")
    if args.script5:
        fifth = container(udid) / "Documents" / "DSHPortE-step15-script5.js"
        fifth.write_text(Path(args.script5).read_text(encoding="utf-8"), encoding="utf-8")

    launch_args = ["-DSHPortEStep15", "1", "-DSHPortEStep15Action", args.action]
    if args.tag:
        launch_args += ["-DSHPortEStep15Tag", args.tag]
    if args.hold:
        launch_args += ["-DSHPortEStep15Hold", str(args.hold)]
    if args.appearance:
        launch_args += ["-DSHPortEStep15Appearance", args.appearance]
    if args.rotate:
        launch_args += ["-DSHPortEStep15Rotate", args.rotate]
    if args.page_theme:
        launch_args += ["-DSHPortEStep15PageTheme", args.page_theme]
    if args.marker:
        launch_args += ["-DSHPortEStep15Marker", args.marker]

    started = time.time()
    info = launch(udid, launch_args)
    probe = wait_for_done(target, args.timeout)
    elapsed = round(time.time() - started, 2)

    shot_path = None
    shot_error = None
    if not args.no_screenshot:
        shot_path, shot_error = shot(udid, SHOTS / f"{args.tag or args.action}.png")

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
        "events": [record.get("event") or record.get("label") for record in records],
        "done": any(record.get("event") == "done" for record in records),
        "probeFile": str(copy) if copy.exists() else None,
        "screenshot": shot_path,
        "screenshotError": shot_error,
        "launch": info,
    }
    if not args.keep_running:
        pick.simctl("terminate", udid, pick.BUNDLE_ID)
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0 if summary["done"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
