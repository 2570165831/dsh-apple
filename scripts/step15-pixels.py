#!/usr/bin/env python3
"""Read the colours a screenshot actually shows, in named bands.

WHY PIXELS AND NOT PROPERTIES. The bands around the web view are painted by
SwiftUI's `.background`, and reading a UIKit property is not the same thing:
`window.rootViewController.view` answers the hosting controller's white whatever
the SwiftUI tree drew on top — measured, and it is why the first version of this
check reported "native #ffffff" on a screen that was dark. The screenshot is the
only witness to what a person sees.

WHY ffmpeg AND NOT Pillow. Pillow is not present in the system python on this
machine, and the only interpreter that has it lives under the desktop app's own
runtime directory, which this task must not read. `ffmpeg` is present, is not part
of that directory, and can do both things this needs: crop a band and report its
per-channel statistics (`signalstats`).

    python3 scripts/step15-pixels.py screenshots/step15/36.png \
        --status-bar 0:60 --home-indicator 845:874 --page 300:340

`--scale` converts the CSS points above into pixels (the PNGs are 3x).
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

POINT_SCALE = 3.0


def ffprobe_size(path: Path) -> tuple[int, int]:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0",
         "-show_entries", "stream=width,height", "-of", "csv=p=0", str(path)],
        capture_output=True, text=True, timeout=120,
    )
    try:
        width, height = out.stdout.strip().split(",")[:2]
        return int(width), int(height)
    except ValueError:
        raise SystemExit(f"cannot read the image size of {path}: {out.stderr[:200]}")


def band_stats(path: Path, top: int, bottom: int, scale: float,
               width: int, height: int) -> dict:
    top_px = max(0, min(height - 1, int(top * scale)))
    bottom_px = max(top_px + 1, min(height, int(bottom * scale)))
    height_px = bottom_px - top_px
    out = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(path),
         "-vf", f"crop={width}:{height_px}:0:{top_px},signalstats,metadata=print:file=-",
         "-f", "null", "-"],
        capture_output=True, text=True, timeout=120,
    )
    values = {}
    for line in out.stdout.splitlines():
        match = re.search(r"lavfi\.signalstats\.(\w+)=(\d+\.?\d*)", line)
        if match:
            values[match.group(1)] = float(match.group(2))
    if not values:
        return {"error": (out.stderr or out.stdout or "no signalstats").strip()[:200],
                "band": [top_px, bottom_px]}
    return {
        "band": [top_px, bottom_px],
        "yAverage": round(values.get("YAVG", -1), 2),
        "yMin": values.get("YMIN"),
        "yMax": values.get("YMAX"),
        # Chroma averages: two colours with the same luminance but different hue
        # are still different colours on screen.
        "uAverage": round(values.get("UAVG", -1), 2),
        "vAverage": round(values.get("VAVG", -1), 2),
        "saturationAverage": round(values.get("SATAVG", -1), 2),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("image")
    parser.add_argument("--status-bar", default="0:60")
    parser.add_argument("--home-indicator", default=None)
    parser.add_argument("--page", default=None)
    parser.add_argument("--scale", type=float, default=POINT_SCALE)
    parser.add_argument("--json", action="store_true", help="machine-readable only")
    args = parser.parse_args()

    path = Path(args.image)
    if not path.exists():
        print(f"no such image: {path}", file=sys.stderr)
        return 2
    width, height = ffprobe_size(path)
    out: dict[str, object] = {"image": str(path), "size": [width, height], "scale": args.scale}

    for name, spec in (("statusBar", args.status_bar),
                       ("homeIndicator", args.home_indicator),
                       ("page", args.page)):
        if spec is None:
            continue
        try:
            top_text, bottom_text = spec.split(":", 1)
            out[name] = band_stats(path, float(top_text), float(bottom_text),
                                    args.scale, width, height)
        except ValueError:
            print(f"bad band spec for {name}: {spec!r}", file=sys.stderr)
            return 2

    print(json.dumps(out, ensure_ascii=False) if args.json
          else json.dumps(out, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
