#!/usr/bin/env python3
"""Pull the screenshots a UI test attached out of a result bundle.

WHY THIS EXISTS. `XCTAttachment`s live inside the `.xcresult` and are not files
in the workspace, so a report cannot link them and nobody can look at what the
failure actually looked like. The test driver writes PNGs to a directory when
`DSHPORTE_XCT_SHOTS` is set, but that environment only reaches the runner when the
setting is passed in the form Xcode forwards — and when it is not, the bundle is
the only copy.

    python3 scripts/step15-xcresult-shots.py logs/step15/xct-Step15TouchTests.xcresult

Every attachment whose name matches one of the step-15 prefixes is written to
`screenshots/step15/` (and copied into `logs/step15/xct-shots/` for the record),
so the pictures the tests took are reviewable.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SHOTS = ROOT / "screenshots" / "step15"
XCT_SHOTS = ROOT / "logs" / "step15" / "xct-shots"
ENV = {"DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}


def export(bundle: Path, out: Path) -> list[dict]:
    out.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(
        ["xcrun", "xcresulttool", "export", "attachments",
         "--path", str(bundle), "--output-path", str(out)],
        capture_output=True, text=True, env=ENV, timeout=600,
    )
    return [{"ok": result.returncode == 0,
             "stdout": result.stdout,
             "stderr": result.stderr.strip()[:800]}]


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: step15-xcresult-shots.py <bundle.xcresult>", file=sys.stderr)
        return 2
    bundle = Path(sys.argv[1])
    if not bundle.exists():
        print(f"no such bundle: {bundle}", file=sys.stderr)
        return 2

    staging = ROOT / "logs" / "step15" / "xcresult-attachments"
    if staging.exists():
        shutil.rmtree(staging)
    report = export(bundle, staging)
    print(json.dumps(report, ensure_ascii=False, indent=2))

    XCT_SHOTS.mkdir(parents=True, exist_ok=True)
    SHOTS.mkdir(parents=True, exist_ok=True)
    moved = []
    # The exporter names files by UUID and prints the human name in its stdout
    # ("suggested name: \"bg-1-draft-typed_0_…png\""), so the mapping has to be
    # read from that output rather than guessed from the file name. Measured:
    # matching on the file name alone copied nothing.
    mapping: dict[str, str] = {}
    for line in report[0]["stdout"].splitlines():
        line = line.strip()
        if not line.startswith("File: "):
            continue
        try:
            file_part, rest = line[len("File: "):].split(",", 1)
            suggested = rest.split('suggested name: "', 1)[1].rstrip('"')
        except (IndexError, ValueError):
            continue
        stem = suggested.split("_0_")[0]
        mapping[file_part.strip()] = stem

    for path in sorted(staging.rglob("*")):
        if not path.is_file():
            continue
        stem = mapping.get(path.name)
        if stem is None:
            continue
        if not any(stem.startswith(prefix) for prefix in
                   ("longpress-", "quicktaps-", "doubletap-", "rail-", "bg-")):
            continue
        target = SHOTS / f"{stem}.png"
        shutil.copyfile(path, target)
        shutil.copyfile(path, XCT_SHOTS / f"{stem}.png")
        moved.append(str(target))
    print(json.dumps({"copied": moved}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
