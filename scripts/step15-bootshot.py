#!/usr/bin/env python3
"""Cold launch: a burst of screenshots, and the brightness of each one.

WHY NOT A VIDEO. `simctl io recordVideo` is unavailable to this task: it answers
`NSPOSIXErrorDomain code=16 "Host recording is already in progress"` because
another process on this machine (a simulator helper) holds the host
recorder. That process is not this task's to kill, so the measurement uses the
instrument that is free: `simctl io screenshot` in a tight loop.

WHAT THAT COSTS, SAID UP FRONT. A screenshot round-trip takes tens of
milliseconds, so this cannot resolve a single-frame flash the way a 60 fps video
would. It resolves a gap of roughly one screenshot interval or longer, which is
the scale a white launch-screen gap actually has on this app (the boot screen is
up for seconds). The report says this explicitly rather than presenting the
burst as frame-accurate.

    python3 scripts/step15-bootshot.py --tag cold --seconds 16 --appearance light

Writes logs/step15/bootshot-<tag>.json (per-shot luminance + timing) and keeps
the shots under logs/step15/bootshot-<tag>/ so the numbers can be checked against
the pictures.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOGS = ROOT / "logs" / "step15"
ENV = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}
SIMSET = ROOT / "simdevices"
BUNDLE = "local.dshportc.app"

def luminance(path: Path) -> float:
    """Mean luminance of one image, from ffmpeg's own signal statistics.

    Not Pillow: the system python has no Pillow and the only interpreter that does
    lives under the desktop app's runtime directory, which this task does not
    read. `ffmpeg -vf signalstats` answers the same question and is already a
    dependency of the screenshot tooling.
    """
    out = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(path),
         "-vf", "scale=48:96,signalstats,metadata=print:file=-", "-f", "null", "-"],
        capture_output=True, text=True, timeout=120,
    )
    for line in out.stdout.splitlines():
        match = re.search(r"lavfi\.signalstats\.YAVG=(\d+\.?\d*)", line)
        if match:
            return round(float(match.group(1)), 2)
    return -1.0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", default="cold")
    parser.add_argument("--seconds", type=float, default=16.0)
    parser.add_argument("--device", default=None)
    parser.add_argument("--appearance", default=None, choices=["light", "dark"])
    parser.add_argument("--interval", type=float, default=0.08,
                        help="seconds to sleep between screenshots (the real interval is measured)")
    args = parser.parse_args()

    if args.device:
        os.environ["DSHPORTE_DEVICE"] = args.device
    sys.path.insert(0, str(ROOT / "scripts"))
    import device_pick as pick  # noqa: E402

    LOGS.mkdir(parents=True, exist_ok=True)
    udid = pick.device_udid()
    pick.boot(udid)
    pick.simctl("install", udid, str(pick.APP_PATH), check=True)
    pick.simctl("terminate", udid, BUNDLE)
    time.sleep(1.0)
    if args.appearance:
        pick.simctl("ui", udid, "appearance", args.appearance)

    keep = LOGS / f"bootshot-{args.tag}"
    if keep.exists():
        shutil.rmtree(keep)
    keep.mkdir(parents=True)
    staging = Path(tempfile.mkdtemp(prefix="step15-burst-"))

    # A cold start: terminate, wait for the home screen to be the visible thing,
    # then launch and shoot as fast as the tool allows.
    started = time.time()
    pick.simctl("launch", udid, BUNDLE)
    shots: list[dict] = []
    index = 0
    while time.time() - started < args.seconds:
        target = staging / f"f{index:04d}.png"
        at = time.time() - started
        result = pick.simctl("io", udid, "screenshot", str(target), timeout=60)
        if target.exists():
            final = keep / f"f{index:04d}.png"
            shutil.copyfile(target, final)
            shots.append({"index": index, "atSeconds": round(at, 3), "path": final.name})
            index += 1
        else:
            # Recorded, not silently skipped: a failed shot is a hole in the burst.
            shots.append({"index": index, "atSeconds": round(at, 3), "error":
                          (result.stderr or result.stdout or "").strip()[:120]})
            index += 1
        time.sleep(max(0.0, args.interval))

    measured = [shot for shot in shots if shot.get("path")]
    luminances = [luminance(keep / shot["path"]) for shot in measured]
    for shot, luminance in zip(measured, luminances):
        shot["luminance"] = luminance
    intervals = [
        measured[i]["atSeconds"] - measured[i - 1]["atSeconds"]
        for i in range(1, len(measured))
    ]

    # A white gap is a shot much brighter than BOTH neighbours, and the
    # neighbourhood comparison is what keeps the normal bright-to-dark transition
    # from being called a flash.
    spikes = []
    for i in range(1, len(luminances) - 1):
        before, here, after = luminances[i - 1], luminances[i], luminances[i + 1]
        if here - before > 30 and here - after > 30:
            spikes.append({"index": i, "atSeconds": measured[i]["atSeconds"],
                           "luminance": here, "before": before, "after": after})

    summary = {
        "tag": args.tag,
        "device": pick.name(),
        "udid": udid,
        "appearance": args.appearance,
        "shots": shots,
        "shotCount": len(measured),
        "averageIntervalSeconds": round(sum(intervals) / len(intervals), 4) if intervals else None,
        "minIntervalSeconds": round(min(intervals), 4) if intervals else None,
        "maxIntervalSeconds": round(max(intervals), 4) if intervals else None,
        "whiteSpikes": spikes,
        "luminance": luminances,
        "notes": [
            "Instrument: simctl io screenshot in a loop. NOT a video: the host "
            "recorder is held by another process on this machine.",
            f"Interval: measured mean {round(sum(intervals) / len(intervals), 3) if intervals else 'n/a'}s "
            "between shots, so a flash shorter than that can be missed.",
            "Each luminance is the mean grey level of a 48x96 downscale.",
            "A spike is a shot more than 30 levels brighter than BOTH neighbours.",
        ],
    }
    target = LOGS / f"bootshot-{args.tag}.json"
    target.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    shutil.rmtree(staging, ignore_errors=True)
    pick.simctl("terminate", udid, BUNDLE)

    print(json.dumps({k: v for k, v in summary.items() if k not in ("luminance", "shots")},
                     ensure_ascii=False, indent=2))
    print(f"== wrote {target} and {keep}/")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
