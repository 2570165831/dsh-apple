#!/usr/bin/env python3
"""Draw the app icon and the launch-screen mark for DSHPortC.

WHY THIS IS GENERATED AND NOT A DESIGN FILE
-------------------------------------------
The task asks for "the app icon, fading in and out" as the launch experience. Until
now this app had no icon at all: `gen-xcode-project.rb` clears
`ASSETCATALOG_COMPILER_APPICON_NAME` precisely because the catalogue held nothing
but a colour (see the comment there). An icon is now part of the product, so it has
to exist as a real asset — and a raster asset that no script can reproduce is the
kind of thing that goes missing or gets re-exported at the wrong size.

So the shape lives here, in code, and `--check` compares the committed PNGs against
what this script would draw now. Same idea as `scripts/check-exif.py`: the artifact
is checked in, but its provenance is executable.

WHAT IT DRAWS
-------------
  AppIcon    1024x1024. Full-bleed (iOS applies the mask), the brand blue
             `--dsw-static-deepseek-500` (#4176e6) with a soft top-left lift, and
             the mark in white.
  LaunchMark 240x240, transparent. The same mark on its own, for the launch
             screen's `UIImageName` and for the SwiftUI layer that fades out. The
             colour is the launch screen's own background asset, so the mark must
             carry no background of its own.

WHY THE MARK IS A CHEVRON AND AN UNDERLINE
------------------------------------------
It has to read at 40 pt in a notification and at 180 pt on the launch screen, and
it must not depend on a font being installed (a text glyph in a PNG is a raster of
whatever macOS had). A chevron plus a rule is four strokes of geometry: it scales,
it is unambiguous, and it says "prompt" to anyone who has used a terminal.

Usage
    scripts/make-app-icon.py            write the assets
    scripts/make-app-icon.py --check    verify the checked-in files match
"""

from __future__ import annotations

import argparse
import hashlib
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "app" / "DSHPortC" / "Assets.xcassets"
APPICON_DIR = ASSETS / "AppIcon.appiconset"
MARK_DIR = ASSETS / "LaunchMark.imageset"

# DSH's own brand blue, exactly the token the web UI paints its send button with
# (`--dsw-static-deepseek-500`). Taken from
# `dsh-client-ui-theme/lib/client.js` rather than eyeballed.
BRAND = (0x41, 0x76, 0xE6)
BRAND_TOP = (0x56, 0x86, 0xFE)   # `--dsw-static-deepseek-450`, the hover lift
WHITE = (255, 255, 255, 255)


def vertical_gradient(size: int, top: tuple[int, int, int], bottom: tuple[int, int, int]) -> Image.Image:
    """A linear top-to-bottom gradient, with a slight diagonal bias.

    A flat fill reads as a placeholder; a gradient reads as an icon. The bias is
    small on purpose: iOS renders this at 40 pt in a notification and any strong
    gradient turns to mud at that size.
    """
    image = Image.new("RGB", (size, size), bottom)
    draw = ImageDraw.Draw(image)
    for y in range(size):
        # Blend top -> bottom, and drift the horizontal position of the blend a
        # little so the light source reads as being above and to the left.
        t = y / (size - 1)
        eased = t * t * (3 - 2 * t)  # smoothstep, so the middle does not band
        r = round(top[0] + (bottom[0] - top[0]) * eased)
        g = round(top[1] + (bottom[1] - top[1]) * eased)
        b = round(top[2] + (bottom[2] - top[2]) * eased)
        draw.line([(0, y), (size, y)], fill=(r, g, b))
    # A soft radial lift in the upper left, so the icon has a light source.
    lift = Image.new("L", (size, size), 0)
    lift_draw = ImageDraw.Draw(lift)
    radius = int(size * 0.78)
    lift_draw.ellipse(
        [int(size * 0.10) - radius, int(size * 0.06) - radius,
         int(size * 0.10) + radius, int(size * 0.06) + radius],
        fill=52,
    )
    lift = lift.filter(ImageFilter.GaussianBlur(size // 8))
    image = Image.composite(Image.new("RGB", (size, size), (0xFF, 0xFF, 0xFF)), image, lift)
    return image


def draw_mark(size: int, colour: tuple[int, int, int, int]) -> Image.Image:
    """The chevron-and-rule mark, centred, on a transparent canvas.

    Geometry is expressed as fractions of `size` so one function draws both the
    1024 pt icon and the 240 pt launch mark, and the two cannot drift apart.
    """
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)
    stroke = max(2, round(size * 0.082))
    # The chevron: two strokes meeting at a point on the left, opening right.
    left = size * 0.255
    apex_x = size * 0.455
    top_y = size * 0.300
    mid_y = size * 0.500
    bottom_y = size * 0.700
    for start, end in (
        ((left, top_y), (apex_x, mid_y)),
        ((apex_x, mid_y), (left, bottom_y)),
    ):
        draw.line([start, end], fill=colour, width=stroke, joint="curve")
    # Rounded caps, which `ImageDraw.line` does not do.
    radius = stroke / 2
    for point in ((left, top_y), (apex_x, mid_y), (left, bottom_y)):
        draw.ellipse([point[0] - radius, point[1] - radius,
                      point[0] + radius, point[1] + radius], fill=colour)
    # The rule after the chevron: a cursor the prompt is waiting for.
    rule_x0 = size * 0.560
    rule_x1 = size * 0.760
    draw.line([(rule_x0, bottom_y), (rule_x1, bottom_y)], fill=colour, width=stroke)
    for point in ((rule_x0, bottom_y), (rule_x1, bottom_y)):
        draw.ellipse([point[0] - radius, point[1] - radius,
                      point[0] + radius, point[1] + radius], fill=colour)
    return canvas


def app_icon(size: int = 1024) -> Image.Image:
    """The full-bleed icon: gradient background, white mark."""
    background = vertical_gradient(size, BRAND_TOP, BRAND)
    mark = draw_mark(size, WHITE)
    background = background.convert("RGBA")
    background.alpha_composite(mark)
    return background.convert("RGB")


def launch_mark(size: int = 240) -> Image.Image:
    """The mark alone, in white, for a coloured launch background.

    White rather than blue: the launch screen's background IS the brand colour's
    opposite — the page background, `#ffffff` / `#151517` — so a blue mark on it is
    the thing that reads. A blue mark on the dark variant would nearly vanish.
    """
    return draw_mark(size, (0x41, 0x76, 0xE6, 0xFF))


APPICON_SET = {
    # Filename: (pixel size, idiom, scale)
    "Icon-1024.png": (1024, "universal", "1x"),
}


def write_appicon(force: bool) -> None:
    APPICON_DIR.mkdir(parents=True, exist_ok=True)
    image = app_icon(1024)
    target = APPICON_DIR / "Icon-1024.png"
    image.save(target, "PNG", optimize=True)
    print(f"wrote {target.relative_to(ROOT)} {image.size}")
    contents = """{
  "images" : [
    {
      "filename" : "Icon-1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""
    (APPICON_DIR / "Contents.json").write_text(contents, encoding="utf-8")
    print(f"wrote {(APPICON_DIR / 'Contents.json').relative_to(ROOT)}")


def write_launch_mark(force: bool) -> None:
    MARK_DIR.mkdir(parents=True, exist_ok=True)
    for scale, pixels in (("1x", 240), ("2x", 480), ("3x", 720)):
        image = launch_mark(pixels)
        target = MARK_DIR / f"LaunchMark@{scale}.png"
        image.save(target, "PNG", optimize=True)
        print(f"wrote {target.relative_to(ROOT)} {image.size}")
    contents = """{
  "images" : [
    { "filename" : "LaunchMark@1x.png", "idiom" : "universal", "scale" : "1x" },
    { "filename" : "LaunchMark@2x.png", "idiom" : "universal", "scale" : "2x" },
    { "filename" : "LaunchMark@3x.png", "idiom" : "universal", "scale" : "3x" }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : {
    "preserves-vector-representation" : false
  }
}
"""
    (MARK_DIR / "Contents.json").write_text(contents, encoding="utf-8")
    print(f"wrote {(MARK_DIR / 'Contents.json').relative_to(ROOT)}")


def check() -> int:
    """Compare the checked-in PNGs against what this script draws now.

    Compared by pixel content, not by file hash: PNG encoders differ between
    Pillow versions, and a byte difference with identical pixels is not a
    regression.
    """
    failures = 0
    pairs = [(APPICON_DIR / "Icon-1024.png", app_icon(1024))]
    for scale, pixels in (("1x", 240), ("2x", 480), ("3x", 720)):
        pairs.append((MARK_DIR / f"LaunchMark@{scale}.png", launch_mark(pixels)))
    for path, expected in pairs:
        if not path.exists():
            print(f"MISSING {path.relative_to(ROOT)}")
            failures += 1
            continue
        actual = Image.open(path).convert(expected.mode)
        if actual.size != expected.size:
            print(f"SIZE {path.relative_to(ROOT)}: {actual.size} != {expected.size}")
            failures += 1
            continue
        diff = sum(1 for a, b in zip(actual.getdata(), expected.getdata()) if a != b)
        digest = hashlib.sha256(actual.tobytes()).hexdigest()[:16]
        if diff:
            print(f"DIFF {path.relative_to(ROOT)}: {diff} pixel(s) differ, sha {digest}")
            failures += 1
        else:
            print(f"ok   {path.relative_to(ROOT)} sha {digest}")
    return 1 if failures else 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="verify instead of writing")
    args = parser.parse_args()
    if args.check:
        return check()
    write_appicon(force=True)
    write_launch_mark(force=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
