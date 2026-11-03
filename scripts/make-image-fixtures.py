#!/usr/bin/env python3
"""Regenerate the step-5 image fixtures.

WHY A SCRIPT AND NOT COMMITTED FILES: the fixtures total ~61 MB, almost all of it
incompressible random pixels needed to push a JPEG past 50 MiB. They prove
nothing a hash in REPORT-5.md does not, so the repository keeps the generator and
the hashes instead of the bytes.

WHAT EACH FIXTURE IS FOR — every one answers a specific acceptance question:

  photo.heic        a real HEIC container (made with `sips`, the platform's own
                    encoder) carrying EXIF GPS. Criterion 2 (a HEIC can be sent)
                    and criterion 5 (the location data is gone afterwards).
  big-4608.jpg      4608x3456 (>4000 px) with a GPS block, Make/Model and
                    DateTimeOriginal. Criterion 2's "large JPEG" and criterion 5's
                    control: the SOURCE provably has the data the stored copy must
                    not have.
  alpha-2600.png    2600x1800 with a real alpha channel. Criterion 2's PNG, and
                    the check that normalisation keeps transparency (it must come
                    back as PNG, not JPEG).
  pic.webp          1200x900. The fourth type DSH's schema names; proves WebP
                    decodes on iOS even though ImageIO cannot ENCODE it.
  anim.gif          600x400, three frames. The animated case: DSH's normalisation
                    reduces it to one frame, so the stored type becomes JPEG.
  corrupt.jpg       a valid JPEG SOI followed by garbage: a header that looks
                    fine and pixels that do not decode. Criterion 4.
  huge-50mb.jpg     6200x6200 random noise at quality 97, just over 50 MiB.
                    Criterion 4's oversized input. Random pixels are deliberate:
                    a smooth gradient compresses to a few MB and would not test
                    the byte limit at all.
  overpixels.jpg    8100x8100 (65.61 MP) but only ~6 MiB, so the PIXEL limit
                    rejects it rather than the byte limit. Also criterion 4.

USAGE
    scripts/make-image-fixtures.py [output-dir]

Requires Pillow and `sips` (macOS). Prints every file's size and SHA-256 so the
report can cite exactly what was generated.
"""
from __future__ import annotations

import hashlib
import os
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUT = ROOT / "logs" / "step5" / "imgtest" / "fixtures"

# The GPS block every "privacy" fixture carries. Coordinates are a real place, on
# purpose: a fabricated 0,0 would not prove the stripper works on plausible input.
GPS = {1: "N", 2: (39.0, 54.0, 26.0), 3: "E", 4: (116.0, 23.0, 29.0)}


def exif_with_gps() -> bytes:
    """EXIF carrying a GPS IFD, a capture date and a camera make/model."""
    exif = Image.Exif()
    exif[0x010F] = "TestMaker"
    exif[0x0110] = "TestModel"
    exif[0x0112] = 1
    exif[0x0132] = "2026:10:27 12:00:00"
    exif[0x8769] = {0x9003: "2026:10:27 12:00:00", 0x829A: (1, 200), 0x8827: 200}
    exif[0x8825] = GPS
    return exif.tobytes()


def large_jpeg(path: Path) -> None:
    """4608x3456 with visible structure plus a GPS block."""
    width, height = 4608, 3456
    image = Image.new("RGB", (width, height))
    draw = ImageDraw.Draw(image)
    for y in range(0, height, 12):
        draw.line([(0, y), (width, y)], fill=((y * 3) % 256, (y * 7) % 256, (y * 11) % 256), width=2)
    draw.ellipse([width // 4, height // 4, width * 3 // 4, height * 3 // 4], fill=(240, 30, 90))
    image.save(path, quality=90, exif=exif_with_gps())


def alpha_png(path: Path) -> None:
    """2600x1800 with a real transparency gradient-ish shape."""
    image = Image.new("RGBA", (2600, 1800), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw.ellipse([200, 150, 2400, 1650], fill=(30, 120, 240, 160))
    image.save(path)


def webp(path: Path) -> None:
    """1200x900, the type ImageIO decodes but cannot encode."""
    image = Image.new("RGB", (1200, 900), (20, 140, 220))
    ImageDraw.Draw(image).ellipse([100, 100, 1100, 800], fill=(250, 60, 60))
    image.save(path, "WEBP", quality=90)


def animated_gif(path: Path) -> None:
    """Three frames, so `animated` is a real fact rather than a claim."""
    frames = []
    for index in range(3):
        frame = Image.new("P", (600, 400), index * 40)
        ImageDraw.Draw(frame).ellipse([50 + index * 60, 50, 350 + index * 60, 350], fill=200 - index * 50)
        frames.append(frame)
    frames[0].save(path, save_all=True, append_images=frames[1:], duration=200, loop=0)


def corrupt_jpeg(path: Path) -> None:
    """A JPEG start-of-image, then bytes that are not a JPEG."""
    path.write_bytes(b"\xff\xd8\xff\xe0\x00\x10JFIF\x00" + b"garbage-not-image" * 2000)


def huge_jpeg(path: Path) -> None:
    """Just over 50 MiB. Random pixels, because a gradient would compress away."""
    rng = np.random.default_rng(11)
    pixels = rng.integers(0, 256, size=(6200, 6200, 3), dtype=np.uint8)
    Image.fromarray(pixels, "RGB").save(path, quality=97)


def over_pixel_jpeg(path: Path) -> None:
    """65.61 MP (over the 64 MP limit) but only ~6 MiB, so PIXELS are the reject."""
    rng = np.random.default_rng(5)
    pixels = rng.integers(0, 256, size=(8100, 8100, 3), dtype=np.uint8)
    Image.fromarray(pixels, "RGB").save(path, quality=8)


def heic(source: Path, path: Path) -> None:
    """A genuine HEIC container, produced by the platform's own encoder."""
    result = subprocess.run(
        ["sips", "-s", "format", "heic", str(source), "--out", str(path)],
        capture_output=True, text=True,
    )
    if result.returncode != 0 or not path.exists():
        print(f"warning: sips could not produce HEIC: {(result.stderr or '').strip()[:200]}", file=sys.stderr)


def main() -> int:
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_OUT
    out.mkdir(parents=True, exist_ok=True)

    large_jpeg(out / "big-4608.jpg")
    alpha_png(out / "alpha-2600.png")
    webp(out / "pic.webp")
    animated_gif(out / "anim.gif")
    corrupt_jpeg(out / "corrupt.jpg")
    huge_jpeg(out / "huge-50mb.jpg")
    over_pixel_jpeg(out / "overpixels.jpg")
    heic(out / "big-4608.jpg", out / "photo.heic")

    total = 0
    for path in sorted(out.iterdir()):
        if not path.is_file():
            continue
        size = path.stat().st_size
        total += size
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        print(f"{size:>10}  {digest}  {path.name}")
    print(f"{total:>10}  total bytes in {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
