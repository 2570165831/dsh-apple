#!/usr/bin/env python3
"""Check that step 18's page-side layer leaves the iPad layout alone.

The layer's media queries are meant to fire only at phone widths: `max-width:
499px` for the settings dialog and `pointer: coarse` for the touch-size rules.
The iPad reports `pointer: coarse` too (it is a touch device), so the rules that
are NOT width-gated are the ones that could reshape it. This script measures the
iPad's own layout in portrait and landscape, on the same build, with the layer on
and off, and reports the differences.

    python3 scripts/step18-ipad.py            # portrait + landscape, both phases
    python3 scripts/step18-ipad.py --phase after

Each run writes `logs/step18/ipad-<phase>-<state>.json` and a screenshot beside
the step's other pictures. It uses the step's own probe file channel, so the
measurement is the same instrumentation the phone's matrix used.

Only the task-owned `dsh-portE-xct-18-ipad` in the default device set is
allowed. Rotation uses the existing PadProbe scene request and is accepted only
when the page's measured width and height confirm the requested orientation.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
UDID = "C7D328E1-92B3-43DE-A2DA-F05620CC2523"
LOGS = ROOT / "logs" / "step18"
SHOTS = ROOT / "screenshots" / "step18"
BUNDLE_ID = "local.dshportc.app"
APP = ROOT / "DerivedData-xct18/Build/Products/Debug-iphonesimulator/DSHPortC.app"
ENV = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}

sys.path.insert(0, str(Path(__file__).resolve().parent))

# What "the layout is not broken" means, as a measurement rather than an opinion.
# Same questions the phone's sweep asks, minus the ones that are about a phone
# (44 pt tap targets on a 1024 pt tablet are not this step's business, and the
# iPad's own HIG wants smaller).
AUDIT = r"""
(function () {
  const vv = window.visualViewport;
  const vw = window.innerWidth;
  const vh = vv ? Math.round(vv.height) : window.innerHeight;
  const shown = (el) => {
    const s = getComputedStyle(el);
    if (s.display === 'none' || s.visibility === 'hidden' || parseFloat(s.opacity) === 0) return false;
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  };
  const off = [];
  const scrollers = (el) => {
    let n = el.parentElement, x = false, y = false, d = 0;
    while (n && d < 20) {
      const s = getComputedStyle(n);
      if (s.overflowX === 'auto' || s.overflowX === 'scroll') x = true;
      if (s.overflowY === 'auto' || s.overflowY === 'scroll') y = true;
      n = n.parentElement; d += 1;
    }
    return { x: x, y: y };
  };
  for (const el of document.querySelectorAll('button,input,select,textarea,[role=button],[role=tab],[role=menuitem],[role=option],[data-row-key]')) {
    if (!shown(el)) continue;
    const r = el.getBoundingClientRect();
    if (r.bottom <= 0 || r.top >= vh || r.right <= 0 || r.left >= vw) continue;
    if (r.left < -0.5 || r.right > vw + 0.5 || r.top < -0.5 || r.bottom > vh + 0.5) {
      const sc = scrollers(el);
      const outX = r.left < -0.5 || r.right > vw + 0.5;
      const outY = r.top < -0.5 || r.bottom > vh + 0.5;
      if ((outX && !sc.x) || (outY && !sc.y)) {
        off.push((el.getAttribute('aria-label') || el.innerText || el.tagName).slice(0, 40)
          + ' L' + Math.round(r.left) + ' R' + Math.round(r.right)
          + ' T' + Math.round(r.top) + ' B' + Math.round(r.bottom));
      }
    }
  }
  const cut = [];
  for (const el of document.querySelectorAll('*')) {
    if (el.children.length > 0 || !shown(el)) continue;
    if (el.scrollWidth <= el.clientWidth + 1) continue;
    if (el.clientWidth < 40 || el.clientHeight <= 1) continue;
    const t = (el.innerText || '').replace(/\s+/g, ' ').trim();
    if (!t) continue;
    let n = el.parentElement, scrollable = false, d = 0;
    while (n && d < 8) {
      const s = getComputedStyle(n);
      if (s.overflowX === 'auto' || s.overflowX === 'scroll' || s.overflowX === 'hidden') { scrollable = true; break; }
      n = n.parentElement; d += 1;
    }
    if (scrollable) continue;
    cut.push('"' + t.slice(0, 40) + '" ' + el.clientWidth + '/' + el.scrollWidth);
  }
  const dialogs = Array.from(document.querySelectorAll('[role=dialog]')).map((d) => {
    const r = d.getBoundingClientRect();
    const nav = d.querySelector(':scope > nav');
    const navRect = nav ? nav.getBoundingClientRect() : null;
    // A two-column dialog on the iPad is CORRECT. The phone rule turns it into a
    // column below 500 pt; this records which shape the tablet actually got.
    return {
      w: Math.round(r.width), h: Math.round(r.height),
      flexDirection: getComputedStyle(d).flexDirection,
      navWidth: navRect ? Math.round(navRect.width) : null,
      navHeight: navRect ? Math.round(navRect.height) : null,
    };
  });
  const sidebar = document.querySelector('[data-sidebar-collapsed]');
  return JSON.stringify({
    viewport: { vw: vw, vh: vh },
    pointerCoarse: matchMedia('(pointer: coarse)').matches,
    wideQuery: matchMedia('(max-width: 499px)').matches,
    sidebarCollapsed: sidebar ? sidebar.getAttribute('data-sidebar-collapsed') : null,
    counts: { offScreen: off.length, clipped: cut.length, dialogs: dialogs.length },
    offScreen: off,
    clipped: cut,
    dialogs: dialogs,
    polishInstalled: document.getElementById('dsh-mobile-polish') !== null,
  }, null, 1);
})()
"""


def simctl(*args, check=False, timeout=180):
    return subprocess.run(["xcrun", "simctl", *args],
                          capture_output=True, text=True, env=ENV, check=check, timeout=timeout)


def screenshot(udid: str, target: Path) -> str:
    """Photograph the device into `target`.

    `simctl io screenshot` cannot write to this volume directly (it runs in a
    helper without the removable-volume grant, NSFileWriteNoPermissionError), so
    the file is written to /tmp and moved — the same workaround step 10 measured
    and scripts/pad-state.py documents.
    """
    tmp = Path("/tmp") / ("dshportc-step18-" + target.name)
    simctl("io", udid, "screenshot", str(tmp), check=True)
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(tmp), str(target))
    out = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(target)],
                         capture_output=True, text=True)
    dims = " ".join(line.split()[-1] for line in out.stdout.splitlines() if "pixel" in line)
    return f"{target.relative_to(ROOT)} {dims}".strip()


def ask(script: str, timeout: float = 60.0):
    import uuid
    container = Path(simctl("get_app_container", UDID, BUNDLE_ID, "data", check=True).stdout.strip())
    command_id = uuid.uuid4().hex
    command = container / "Documents/step18-cmd.json"
    reply = container / "Documents" / f"step18-out-{command_id}.json"
    command.write_text(json.dumps({"id": command_id, "script": script}), encoding="utf-8")
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if reply.exists():
            payload = json.loads(reply.read_text(encoding="utf-8"))
            if not payload.get("ok"):
                raise RuntimeError("page probe evaluation failed")
            value = payload.get("value")
            if isinstance(value, str):
                try:
                    return json.loads(value)
                except json.JSONDecodeError:
                    pass
            return value
        time.sleep(0.2)
    raise RuntimeError("iPad page probe timed out")


def wait_for_page(timeout: float = 240.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if ask("document.querySelector('[data-composer-input]') !== null", timeout=10) is True:
                return True
        except (RuntimeError, FileNotFoundError):
            pass
        time.sleep(1)
    return False


def measure(stage: dict) -> dict:
    phase, rotation = stage["phase"], stage["rotation"]
    if not wait_for_page(timeout=30):
        raise RuntimeError("iPad composer did not appear")
    initial = ask(AUDIT)
    vw, vh = initial["viewport"]["vw"], initial["viewport"]["vh"]
    if (vw > vh) != (rotation == "landscape"):
        raise RuntimeError(f"wrong DOM orientation {vw}x{vh}")
    if initial["polishInstalled"] != (phase == "after"):
        raise RuntimeError("polish flag did not produce the requested page injection")
    ask("document.querySelector('[aria-label=\"账号菜单\"]').click(); true")
    time.sleep(1)
    ask("Array.from(document.querySelectorAll('button')).find(b => b.innerText.startsWith('设置')).click(); true")
    time.sleep(2)
    payload = ask(AUDIT)
    if len(payload["dialogs"]) != 1 or payload["dialogs"][0]["flexDirection"] != "row":
        raise RuntimeError("iPad settings no longer has a two-column layout")
    shot = screenshot(UDID, SHOTS / f"ipad-{phase}-{rotation}.png")
    result = {**stage, "shot": shot, **payload}
    (LOGS / f"ipad-{phase}-{rotation}.json").write_text(
        json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"{phase} {rotation}: viewport={payload['viewport']} counts={payload['counts']} "
          f"dialog={payload['dialogs']} polish={payload['polishInstalled']}", flush=True)
    return result


def main() -> int:
    listing = json.loads(simctl("list", "devices", "--json", check=True).stdout)
    selected = next(d for group in listing["devices"].values() for d in group if d["udid"] == UDID)
    if selected["name"] != "dsh-portE-xct-18-ipad":
        raise SystemExit("refusing non-task iPad")
    root = (Path.home() / "Library/Developer/CoreSimulator/Devices") / UDID / "data/Containers/Data/Application"
    args = ["xcodebuild", "test", "-project", str(ROOT / "app/DSHPortC.xcodeproj"),
            "-scheme", "DSHPortC", "-configuration", "Debug", "-sdk", "iphonesimulator",
            "-derivedDataPath", str(ROOT / "DerivedData-xct18"),
            "-destination", f"platform=iOS Simulator,id={UDID}", "-parallel-testing-enabled", "NO",
            "-only-testing:DSHPortCUITests/Step18TouchTests/testIPadLayoutInPortraitAndLandscape",
            "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES", "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO"]
    states, seen = [], set()
    started = time.monotonic()
    with (LOGS / "ipad-xct-final.log").open("w") as output:
        process = subprocess.Popen(args, stdout=output, stderr=subprocess.STDOUT, env=ENV)
        try:
            while process.poll() is None:
                if time.monotonic() - started > 900:
                    raise TimeoutError("iPad XCTest exceeded 900 seconds")
                for marker in root.glob("*/tmp/step18-pad-stage.json"):
                    stage = json.loads(marker.read_text())
                    if stage["id"] in seen or marker.stat().st_mtime < time.time() - (time.monotonic() - started):
                        continue
                    seen.add(stage["id"])
                    ok = False
                    try:
                        states.append(measure(stage))
                        ok = True
                    except Exception as error:
                        print(f"measurement failed: {error}", flush=True)
                    marker.with_name("step18-pad-ack.json").write_text(json.dumps({"id": stage["id"], "ok": ok}))
                time.sleep(0.5)
        except BaseException:
            process.terminate()
            process.wait(timeout=30)
            raise
    summary = {"states": states, "exit": process.returncode, "command": args,
               "complete": process.returncode == 0 and len(states) == 4}
    (LOGS / "ipad-summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0 if summary["complete"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
