#!/usr/bin/env python3
"""Run step 21's XCUITest class on the task's UI-test device, then collect frames.

    python3 scripts/step21-xct.py Step21TouchTests
    python3 scripts/step21-xct.py ComposerKeyboardTests      # a regression run
    python3 scripts/step21-xct.py Step21TouchTests --test testLaunchShowsTheIconAndNotADiagnosticPanel

WHY A WRAPPER. Three things have to be true before `xcodebuild test` means
anything, and each one has bitten an earlier step:

  * the device is in the DEFAULT set (`xcodebuild` cannot see a custom `--set`),
    so it is addressed by UDID and by name, not through `scripts/device_pick.py`;
  * the mock the tests talk to is actually listening — a test that cannot reach a
    model reports a page failure, not a missing server;
  * the result bundle must not already exist, because `xcodebuild` refuses rather
    than overwriting, and a stale bundle is evidence of a different build.

SCREENSHOTS. `XCUIScreen.main.screenshot` inside the test writes PNGs into the
SIMULATOR's tmp (the test process cannot write to this checkout's volume). Step 18
taught this the hard way: `simctl io screenshot` on this machine returns a grey
buffer, because there is no Simulator.app to render into — `xcodebuild` still runs
the app and `XCUIScreen` still captures the real frames, so the test's own
screenshots are the only ones that show anything. This script copies them out
after the run.
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
LOGS = ROOT / "logs" / "step21"
SHOTS = ROOT / "screenshots" / "step21"
ENV = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}
DEVICE_NAME = "dsh-portE-xct-16"
DEVICE_UDID = "86A3987B-EE1A-487E-8CCD-09E62B1493C5"
BUNDLE_ID = "local.dshportc.app"
MOCK_PORT = "19721"
# Where the test process writes its PNGs.
#
# NOT the device's own `data/tmp`: a UI test bundle is a separate app, so
# `FileManager.default.temporaryDirectory` inside it is the TEST RUNNER's data
# container, not the app under test's and not the device's. Measured: the frames
# from a passing run were under `data/Containers/Data/Application/<uuid>/tmp/
# dshportc-step21`, where `<uuid>` changes on every install. So the search is by
# name under the device's Containers directory, taking the freshest match.
DEVICE_CONTAINERS = ((Path.home() / "Library/Developer/CoreSimulator/Devices")
                     / DEVICE_UDID / "data/Containers/Data/Application")


def run(args: list[str], *, timeout: float = 180, check: bool = False) -> subprocess.CompletedProcess:
    return subprocess.run(args, capture_output=True, text=True, env=ENV, timeout=timeout, check=check)


def boot() -> None:
    run(["xcrun", "simctl", "boot", DEVICE_UDID])
    run(["xcrun", "simctl", "bootstatus", DEVICE_UDID], timeout=300)


def mock_is_up() -> bool:
    out = run(["curl", "-sS", "-m", "2", f"http://127.0.0.1:{MOCK_PORT}/healthz"], timeout=10)
    return out.returncode == 0 and '"ok":true' in (out.stdout or "")


def sim_tmp() -> Path | None:
    """The freshest `dshportc-step21` directory any container wrote."""
    candidates = sorted(DEVICE_CONTAINERS.glob("*/tmp/dshportc-step21"), key=lambda p: p.stat().st_mtime)
    return candidates[-1] if candidates else None


def collect_shots() -> list[str]:
    """Copy the run's frames out of the simulator and into screenshots/step21/."""
    SHOTS.mkdir(parents=True, exist_ok=True)
    copied: list[str] = []
    source_dir = sim_tmp()
    if source_dir is None:
        print("  no dshportc-step21 directory: the test captured no frames", file=sys.stderr)
        return copied
    for source in sorted(source_dir.glob("*.png")):
        target = SHOTS / source.name
        try:
            target.write_bytes(source.read_bytes())
            copied.append(source.name)
        except OSError as error:
            print(f"  copy failed for {source.name}: {error}", file=sys.stderr)
    return copied


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("klass", help="test class to run, e.g. Step21TouchTests")
    parser.add_argument("--test", default=None, help="one method of that class")
    parser.add_argument("--timeout", type=float, default=3600.0)
    args = parser.parse_args()

    LOGS.mkdir(parents=True, exist_ok=True)
    SHOTS.mkdir(parents=True, exist_ok=True)
    boot()

    if not mock_is_up():
        print(f"step21-xct: no mock on {MOCK_PORT}. Start it with:", file=sys.stderr)
        print(f"  MOCK_PORT={MOCK_PORT} MOCK_LOG_DIR={LOGS} bash scripts/mock-start.sh start", file=sys.stderr)
        return 2

    # The on-screen keyboard has to be ON, or a test that taps a field sees no
    # keyboard at all and its assertion about the keyboard is vacuous. This is the
    # same switch step 15's runner uses, for the same reason: `Xcode 27 ships no
    # Simulator.app`, so there is no Hardware Keyboard menu item, and `simctl` has
    # no verb for it — `tools/kbd/softkeyboard` invokes the CoreSimulator selector
    # the DeviceHub checkbox uses.
    keyboard_tool = ROOT / "tools/kbd/softkeyboard"
    if keyboard_tool.is_file() and os.access(keyboard_tool, os.X_OK):
        default_set = str(Path.home() / "Library/Developer/CoreSimulator/Devices")
        out = run([str(keyboard_tool), default_set, DEVICE_UDID, "soft"], timeout=120)
        print(f"== software keyboard: {(out.stdout or out.stderr).strip().splitlines()[-1] if (out.stdout or out.stderr).strip() else 'no output'}")
    else:
        print("== WARNING tools/kbd/softkeyboard is not built; keyboard assertions may be vacuous",
              file=sys.stderr)

    # The app must be installed on this device before the test runner looks for it.
    app_path = ROOT / "DerivedData/Build/Products/Debug-iphonesimulator/DSHPortC.app"
    if not app_path.is_dir():
        print(f"step21-xct: no app at {app_path}; run scripts/build-app.sh", file=sys.stderr)
        return 2
    run(["xcrun", "simctl", "install", DEVICE_UDID, str(app_path)], timeout=300)

    only = f"DSHPortCUITests/{args.klass}"
    if args.test:
        only += f"/{args.test}"
    label = args.klass + (f"-{args.test}" if args.test else "")
    log = LOGS / f"xct-{label}.log"
    bundle = LOGS / f"xct-{label}.xcresult"
    if bundle.exists():
        shutil.rmtree(bundle)
    # Stale frames from a previous class would be indistinguishable from this
    # run's, and the report cites them by name.
    stale_dir = sim_tmp()
    if stale_dir is not None:
        for stale in stale_dir.glob("*.png"):
            stale.unlink(missing_ok=True)

    # The UI test needs to write into the APP's Documents directory to use step 18's
    # probe channel (the app's pasteboard is only readable from the app's process).
    # A test runs in its own container, so the path is passed in.
    app_documents = app_data_documents()
    command = [
        "xcodebuild", "test",
        "-project", str(ROOT / "app/DSHPortC.xcodeproj"),
        "-scheme", "DSHPortC",
        "-configuration", "Debug",
        "-sdk", "iphonesimulator",
        "-derivedDataPath", str(ROOT / "DerivedData"),
        "-destination", f"platform=iOS Simulator,id={DEVICE_UDID}",
        "-parallel-testing-enabled", "NO",
        f"-only-testing:{only}",
        "-resultBundlePath", str(bundle),
        "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES",
        "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO",
        f"TEST_RUNNER_DSHPORTE_APP_DOCUMENTS={app_documents}",
    ]
    print(f"== {label}: {only}")
    started = time.time()
    with log.open("w") as output:
        process = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, env=ENV,
                                 timeout=args.timeout)
    elapsed = round(time.time() - started, 1)

    text = log.read_text(errors="replace")
    succeeded = "** TEST SUCCEEDED **" in text
    failed = "** TEST FAILED **" in text
    shots = collect_shots()
    summary = {
        "class": args.klass,
        "test": args.test,
        "onlyTesting": only,
        "device": DEVICE_NAME,
        "udid": DEVICE_UDID,
        "mockPort": MOCK_PORT,
        "command": command,
        "exit": process.returncode,
        "elapsedSeconds": elapsed,
        "testSucceeded": succeeded,
        "testFailed": failed,
        "log": str(log.relative_to(ROOT)),
        "resultBundle": str(bundle.relative_to(ROOT)),
        "screenshots": shots,
        "appSha256": app_binary_sha(),
    }
    out = LOGS / f"xct-{label}.json"
    out.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({k: summary[k] for k in
                      ("exit", "testSucceeded", "testFailed", "elapsedSeconds", "screenshots")},
                     ensure_ascii=False, indent=2))
    print(f"log {log.relative_to(ROOT)}")
    return 0 if succeeded else 1


def app_data_documents() -> str:
    """The app's Documents directory on the host filesystem, for the probe channel."""
    out = run(["xcrun", "simctl", "get_app_container", DEVICE_UDID, BUNDLE_ID, "data"], timeout=120)
    if out.returncode != 0:
        return ""
    return str(Path(out.stdout.strip()) / "Documents")


def app_binary_sha() -> str:
    """The dynamic library's hash, which is what identifies this build.

    REPORT-18 established that the bundle's `DSHPortC` executable is a thin stub
    and the code lives in `DSHPortC.debug.dylib`, so the dylib is the artifact a
    run has to be attributed to.
    """
    dylib = ROOT / "DerivedData/Build/Products/Debug-iphonesimulator/DSHPortC.app/DSHPortC.debug.dylib"
    if not dylib.is_file():
        return "missing"
    out = run(["shasum", "-a", "256", str(dylib)], timeout=120)
    return (out.stdout or "").split(" ")[0] or "unknown"


if __name__ == "__main__":
    sys.exit(main())
