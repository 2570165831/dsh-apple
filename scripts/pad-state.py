#!/usr/bin/env python3
"""Measure one iPad window state: launch, wait for the page, photograph, record.

One launch per state, on purpose. The app can narrow its own content (that is
PadProbe's split-view stand-in) but it cannot rotate itself on this SDK, so the
orientation comes from which variant is installed:

  scripts/pad-measure.sh portrait   the normal build (all four orientations)
  scripts/pad-measure.sh landscape  the landscape-only build

and the width comes from `-DSHPortEPadLayoutFraction`. Each run writes its own
probe file, named by the tag, so a later run cannot overwrite an earlier one.

Usage
    scripts/pad-state.py --tag 03-landscape-two-thirds --fraction 0.6667
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import time
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SIMSET = ROOT / "simdevices"
SHOTS = ROOT / "screenshots" / "ipad"
LOGS = ROOT / "logs" / "step10"
BUNDLE_ID = "local.dshportc.app"
APP = ROOT / "DerivedData/Build/Products/Debug-iphonesimulator/DSHPortC.app"
ENV = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}
# The three files the app writes for observability live under Library/Application
# Support, not Documents, so they stay out of the Files app.
RUNTIME_DIR = "Library/Application Support/DSHPortC"

sys.path.insert(0, str(Path(__file__).resolve().parent))
import device_pick  # noqa: E402


def simctl(*args, check=False, timeout=180):
    return subprocess.run(["xcrun", "simctl", "--set", str(SIMSET), *args],
                          capture_output=True, text=True, env=ENV, check=check, timeout=timeout)


def screenshot(udid: str, target: Path) -> None:
    """Photograph the device into `target`.

    NOT straight into the task directory: `simctl io screenshot` runs in a helper
    without the removable-volume grant for this disk, and writing under
    /Volumes/... is refused with NSFileWriteNoPermissionError while the same call
    writing /tmp succeeds. Measured before this comment was written.
    """
    tmp = Path("/tmp") / ("dshportc-" + target.name)
    simctl("io", udid, "screenshot", str(tmp), check=True)
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(tmp), str(target))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--fraction", type=float, default=None)
    parser.add_argument("--wait", type=float, default=30.0,
                        help="seconds to let the page settle after the web view reports ready")
    parser.add_argument("--press-session", action="store_true",
                        help="also press the first session row and record what happened")
    parser.add_argument("--rotate", choices=["landscape", "portrait"], default=None,
                        help="ask the app to rotate the scene (works; see PadProbe)")
    args = parser.parse_args()

    if device_pick.kind() != "ipad":
        raise SystemExit("this script is about the iPad; set DSHPORTE_DEVICE=ipad")

    udid = device_pick.device_udid(create_phone=False)
    device_pick.boot(udid)

    data = Path(simctl("get_app_container", udid, BUNDLE_ID, "data", check=True).stdout.strip())
    probe = data / f"Documents/DSHPortE-padprobe-{args.tag}.json"
    for stale in (probe, data / RUNTIME_DIR / "DSHPortC-status.json"):
        try:
            stale.unlink()
        except OSError:
            pass

    simctl("terminate", udid, BUNDLE_ID)
    launch = ["-DSHPortEPadProbe", "1", "-DSHPortEPadProbeTag", args.tag,
              # Selecting the default workspace is what makes the sidebar render
              # session rows: before a workspace is chosen the page is the hero
              # screen and a row count of zero says nothing about the layout.
              "-DSHPortCTestDrive", "1"]
    if args.fraction is not None:
        launch += ["-DSHPortEPadLayoutFraction", str(args.fraction)]
    if args.press_session:
        launch += ["-DSHPortEPadPressSession", "1"]
    if args.rotate:
        launch += ["-DSHPortEPadRotate", args.rotate]
    env = {**ENV, "SIMCTL_CHILD_DSHPORTE_GUEST_CHANNEL": "1"}
    subprocess.run(["xcrun", "simctl", "--set", str(SIMSET), "launch", udid, BUNDLE_ID, *launch],
                   capture_output=True, text=True, env=env, timeout=180, check=True)

    # Wait for the app's own phase, not for a fixed delay: the probe cannot say
    # anything about a page that has not painted yet.
    deadline = time.time() + 300
    while time.time() < deadline:
        try:
            status = json.loads((data / RUNTIME_DIR / "DSHPortC-status.json").read_text())
        except (OSError, json.JSONDecodeError):
            status = {}
        if status.get("phase") == "webViewReady":
            break
        if status.get("phase") == "failed":
            raise SystemExit(f"the app reported failure: {status.get('error')}")
        time.sleep(0.5)
    else:
        raise SystemExit("the web view never became ready")

    # Then let the plugin bundles and the workspace selection finish, and let the
    # probe's own heartbeat take a settled sample.
    #
    # A session-row press is not instantaneous either: the probe polls up to 60 s
    # for a row to exist, presses it, and then samples again 2.5 s later. The wait
    # here is a floor, not a race — the numbers are read from the probe file
    # afterwards, so a slow press shows up as a late sweep rather than as a
    # missing one.
    time.sleep(args.wait)
    if args.press_session:
        time.sleep(25)

    shots = SHOTS / f"{args.tag}.png"
    screenshot(udid, shots)
    shutil.copy(probe, LOGS / f"padprobe-{args.tag}.json")
    node_log = data / RUNTIME_DIR / "DSHPortC-node.log"
    if node_log.exists():
        shutil.copy(node_log, LOGS / f"padprobe-{args.tag}-node.log")

    recorded = json.loads(probe.read_text())
    settled = [s for s in recorded.get("sweeps", []) if isinstance(s.get("dom"), dict)]
    if not settled:
        raise SystemExit("the probe recorded no sweep with a DOM snapshot")
    last = settled[-1]
    app_facts, dom = last["app"], last["dom"]
    summary = {
        "tag": args.tag,
        "fraction": args.fraction,
        "screenshot": str(shots.relative_to(ROOT)),
        "probe": str((LOGS / f"padprobe-{args.tag}.json").relative_to(ROOT)),
        "orientation": app_facts.get("interfaceOrientation"),
        "deviceOrientation": app_facts.get("deviceOrientation"),
        "window": [app_facts.get("windowWidth"), app_facts.get("windowHeight")],
        "safeArea": [app_facts.get("safeAreaTop"), app_facts.get("safeAreaBottom"),
                     app_facts.get("safeAreaLeft"), app_facts.get("safeAreaRight")],
        "innerWidth": dom.get("innerWidth"),
        "innerHeight": dom.get("innerHeight"),
        "webView": last.get("webView"),
        "sidebarCollapsed": dom.get("sidebarCollapsedAttr"),
        "gridTemplateColumns": dom.get("gridTemplateColumns"),
        "sidebarWidth": dom.get("sidebarWidth"),
        "sessionRowCount": dom.get("sessionRowCount"),
        "sessionRowTitles": dom.get("sessionRowTitles"),
        "horizontalOverflow": dom.get("horizontalOverflow"),
        "docScrollWidth": dom.get("docScrollWidth"),
        "spillCount": len(dom.get("spill") or []),
        "spill": dom.get("spill"),
        # Elements PARTLY inside the viewport: the ones whose text is clipped or
        # whose tap target is half unreachable. `spill` alone counts panes parked
        # off to the right, which this UI does on purpose.
        "clippedCount": len(dom.get("clipped") or []),
        "clipped": dom.get("clipped"),
        "composerPresent": dom.get("composerPresent"),
        "sendButton": dom.get("sendButton"),
        "supportsMultipleScenes": app_facts.get("supportsMultipleScenes"),
        "connectedScenes": app_facts.get("connectedScenes"),
        "resizes": dom.get("resizes"),
    }
    # The session-row press, if one was asked for. Kept separate from the layout
    # numbers because it answers a different question: whether a row that exists
    # can actually be opened.
    presses = [s for s in recorded.get("sweeps", [])
               if s.get("event") == "session-row-press"]
    summary["sessionRowPress"] = presses
    out = LOGS / f"state-{args.tag}.json"
    out.write_text(json.dumps(summary, indent=2, ensure_ascii=False))
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
