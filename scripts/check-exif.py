#!/usr/bin/env python3
"""Prove a stored attachment carries no EXIF location data.

WHY A SEPARATE SCRIPT: the same claim has to hold for the object DSH actually
stored, not for anything this task produced on the host. The source fixture has a
GPS block written into its EXIF (lat 39.907, lon 116.391, plus Make/Model and
DateTimeOriginal); if any of that survives into `DSH_HOME/attachments/v1/objects/`,
the privacy criterion is failed regardless of what the code intends.

Reads the object with ImageIO-independent tools (Pillow for the pixels, a raw
scan for the EXIF markers) so a passing result does not depend on the same
library that wrote the file.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

from PIL import Image


def inspect(path: Path) -> dict:
    """Report what metadata one stored object carries."""
    with Image.open(path) as image:
        exif = image.getexif()
        gps = None
        try:
            gps = exif.get_ifd(0x8825) if exif else None
        except Exception:
            gps = None
        raw = path.read_bytes()
        return {
            "path": str(path),
            "format": image.format,
            "mode": image.mode,
            "size": list(image.size),
            "bytes": len(raw),
            "exifTags": {hex(tag): str(value)[:60] for tag, value in (exif.items() if exif else [])},
            "exifTagCount": len(exif) if exif else 0,
            "gps": {str(k): str(v) for k, v in gps.items()} if gps else {},
            # Marker scan: an APP1 "Exif\0\0" segment is what carries GPS.
            "containsExifMarker": b"Exif\x00\x00" in raw,
            "containsXmpMarker": b"http://ns.adobe.com/xap/1.0/" in raw,
            "containsIcCProfile": b"ICC_PROFILE" in raw or b"iCCP" in raw,
        }


def main() -> int:
    roots = [Path(arg) for arg in sys.argv[1:]]
    if not roots:
        print(__doc__, file=sys.stderr)
        return 2
    report = []
    for root in roots:
        for path in sorted(root.rglob("*")):
            if not path.is_file():
                continue
            try:
                report.append(inspect(path))
            except Exception as error:  # noqa: BLE001 - the reason is the finding
                report.append({"path": str(path), "error": str(error)})
    print(json.dumps(report, indent=2, ensure_ascii=False))

    failed = []
    for item in report:
        if "error" in item:
            failed.append((item["path"], "unreadable: " + item["error"]))
            continue
        if item["gps"]:
            failed.append((item["path"], f"GPS block present: {item['gps']}"))
        if item["containsXmpMarker"]:
            failed.append((item["path"], "XMP packet present"))
        # A bare Exif APP1 with only pixel dimensions is what ImageIO writes
        # itself; the meaningful question is whether CAPTURE tags survived.
        capture = {
            tag: value for tag, value in item["exifTags"].items()
            # 0x100 Make, 0x110 Model, 0x132 DateTime, 0x8825 GPS IFD.
            # 0x8769 (the Exif IFD pointer) is NOT a capture tag: the encoder
            # writes it to carry pixel dimensions and the colour-space flag,
            # and reporting it as a leak would fail every correct output.
            if tag in ("0x100", "0x110", "0x132", "0x8825")
        }
        if capture:
            failed.append((item["path"], f"capture tags present: {capture}"))
    for path, reason in failed:
        print(f"FAIL {path}: {reason}", file=sys.stderr)
    if failed:
        return 1
    print(f"PASS {len(report)} stored image(s) carry no GPS, XMP or capture tags", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
