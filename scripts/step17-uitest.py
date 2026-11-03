#!/usr/bin/env python3
"""Run step 17's XCUITest arms and keep their screenshots.

WHY A WRAPPER AT ALL
--------------------
`xcodebuild test` writes its screenshots into an `.xcresult` bundle, which is not
a directory of PNGs. Step 17's delivery asks for `screenshots/step17/` to contain
the Files app's directory listing, the share sheet, and the iPad popover, so
something has to export the attachments and rename them from
`step17-share-blob_0_<uuid>.png` to `step17-share-blob.png`.

WHY THE DEVICES ARE IN THE DEFAULT SET
--------------------------------------
`xcodebuild` resolves `-destination` against the system's own device list and
cannot see `simctl --set <custom path>`. TASK-17 therefore allows two devices to
be created in the default set for this step only: `dsh-portE-xct-17` (iPhone) and
`dsh-portE-xct-17-ipad`. This script finds them by name, refuses to create them
if absent (creating a device is a deliberate act, not a fallback), and never
touches any other device in that set.

Usage
    scripts/step17-uitest.py iphone [--only NAME]
    scripts/step17-uitest.py ipad
    scripts/step17-uitest.py cleanup
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOGS = ROOT / "logs" / "step17"
SHOTS = ROOT / "screenshots" / "step17"
PROJECT = ROOT / "app/DSHPortC.xcodeproj"
DERIVED = ROOT / "DerivedData"
ENV = {**__import__("os").environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}

DEVICES = {
    "iphone": ("dsh-portE-xct-17", "com.apple.CoreSimulator.SimDeviceType.iPhone-17"),
    "ipad": ("dsh-portE-xct-17-ipad", "com.apple.CoreSimulator.SimDeviceType.iPad-Air-11-inch-M4"),
}
RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
BUNDLE_ID = "local.dshportc.app"


def simctl(*args, check=False, timeout=300):
    return subprocess.run(["xcrun", "simctl", *args], capture_output=True, text=True,
                          env=ENV, check=check, timeout=timeout)


def device_udid(kind: str) -> str:
    name = DEVICES[kind][0]
    listing = simctl("list", "devices").stdout
    found = [
        match.group(1)
        for line in listing.splitlines()
        if (match := re.match(rf"\s*{re.escape(name)} \(([0-9A-F-]+)\)", line))
    ]
    if not found:
        raise SystemExit(
            f"{name} does not exist in the default set. Create it deliberately:\n"
            f"  xcrun simctl create {name} {DEVICES[kind][1]} {RUNTIME}"
        )
    if len(found) > 1:
        print(f"WARNING {name} exists {len(found)} times: {found}; using the first", flush=True)
    return found[0]


def boot(udid: str) -> None:
    listing = simctl("list", "devices").stdout
    if f"{udid}) (Booted)" not in listing:
        simctl("boot", udid)
        simctl("bootstatus", udid, timeout=600)


def export_attachments(result: Path, prefix: str) -> list[str]:
    """Export a run's screenshots into `screenshots/step17/` under stable names.

    The export names files `<attachment-name>_<index>_<uuid>.png`; only the part
    before the first `_0_`/`_1_`/… is the name the test attached, so that is what
    the delivered name uses. Two different tests never attach the same name.
    """
    import tempfile

    if not result.is_dir():
        return []
    with tempfile.TemporaryDirectory() as raw:
        out = Path(raw)
        export = subprocess.run(
            ["xcrun", "xcresulttool", "export", "attachments",
             "--path", str(result), "--output-path", str(out)],
            capture_output=True, text=True, env=ENV, timeout=600,
        )
        if export.returncode != 0:
            print(f"xcresulttool export failed: {export.stderr.strip()[:400]}", flush=True)
            return []
        manifest_path = out / "manifest.json"
        if not manifest_path.exists():
            return []
        manifest = json.loads(manifest_path.read_text())
        SHOTS.mkdir(parents=True, exist_ok=True)
        written: list[str] = []
        for test in manifest:
            for attachment in test.get("attachments", []):
                name = attachment.get("suggestedHumanReadableName") or attachment.get("exportedFileName")
                # ONLY the names the tests attach deliberately. An .xcresult also
                # carries XCUITest's own diagnostics — UI snapshots, synthesized
                # events, screen recordings, hierarchy dumps — and dropping all of
                # them into the delivery directory buries the twelve screenshots
                # that matter under dozens that do not.
                if not name.startswith("step17-"):
                    continue
                source = out / attachment["exportedFileName"]
                if not source.exists():
                    continue
                stem = re.split(r"_\d+_[0-9A-F-]{36}$", Path(name).stem)[0]
                target = SHOTS / f"{prefix}{stem}{source.suffix or '.png'}"
                shutil.copyfile(source, target)
                written.append(target.name)
        return written


def run(kind: str, only: str | None) -> int:
    udid = device_udid(kind)
    boot(udid)
    # NO UNINSTALL. Two of these tests read state that another harness arm put in
    # the container on purpose: the Files-app test asserts that a file the AGENT
    # wrote is visible in the Files app, and that file got there through a real
    # agent turn run by `scripts/step17-acceptance.py files`. Uninstalling here
    # would delete it and make the assertion meaningless rather than false.
    # `terminate` is enough: every launch gets a fresh process.
    simctl("terminate", udid, BUNDLE_ID)

    LOGS.mkdir(parents=True, exist_ok=True)
    result = LOGS / f"xct-{kind}.xcresult"
    if result.exists():
        shutil.rmtree(result)
    command = [
        "xcodebuild", "test",
        "-project", str(PROJECT),
        "-scheme", "DSHPortC",
        "-configuration", "Debug",
        "-sdk", "iphonesimulator",
        "-derivedDataPath", str(DERIVED),
        "-destination", f"platform=iOS Simulator,id={udid}",
        "-resultBundlePath", str(result),
        "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES",
    ]
    if only:
        command.append(f"-only-testing:DSHPortCUITests/Step17UITests/{only}")
    elif kind == "ipad":
        # The iPad arm is the download-and-share arm: TASK-17 says only those two
        # claims need the iPad, and the Files-app test would need an agent turn
        # run on this device first. Named one by one rather than skipping the
        # Files test, so adding a test later cannot silently join this arm.
        # Exactly the two claims TASK-17 asks the iPad about: a download and its
        # share sheet do not crash. Deliberately NOT the dialog test: it is not on
        # the iPad list, and on this device the app takes long enough to boot that
        # a 120 s wait for the alert can expire for reasons that have nothing to do
        # with dialogs — measured once, and a test that fails for the wrong reason
        # is worse than one that is not run.
        for name in ("testBlobDownloadShowsShareSheet",
                     "testDataUrlDownloadShowsShareSheet",
                     "testBigDownloadShowsShareSheet"):
            command.append(f"-only-testing:DSHPortCUITests/Step17UITests/{name}")
    else:
        command.append("-only-testing:DSHPortCUITests/Step17UITests")

    log = LOGS / f"xct-{kind}.log"
    with log.open("w") as handle:
        process = subprocess.run(command, stdout=handle, stderr=subprocess.STDOUT,
                                 env=ENV, timeout=3600)
    text = log.read_text(errors="replace")
    for line in text.splitlines():
        if re.search(r"Test Case .*(passed|failed)|STEP17-|error:|TEST (SUCCEEDED|FAILED)", line):
            print(line.strip())
    # The iPad's screenshots are what TASK-17 asks for as "the iPad popover", and
    # the iPhone's are the phone's. A shared name would make one arm's export
    # silently overwrite the other's, so the prefix is the device.
    shots = export_attachments(result, prefix="" if kind == "iphone" else "ipad-")
    print(json.dumps({"device": udid, "exit": process.returncode,
                      "result": str(result), "screenshots": shots}, indent=2))
    return process.returncode


def cleanup() -> int:
    """Delete the two devices this step was allowed to create.

    Only these two, by exact name and resolved UDID. `shutdown all` is never used
    and no other device is touched: two other checkouts are running their own
    simulators at the same time (TASK-17, constraints).
    """
    removed = []
    for kind in DEVICES:
        name = DEVICES[kind][0]
        listing = simctl("list", "devices").stdout
        udids = [
            match.group(1)
            for line in listing.splitlines()
            if (match := re.match(rf"\s*{re.escape(name)} \(([0-9A-F-]+)\)", line))
        ]
        for udid in udids:
            simctl("shutdown", udid)
            result = simctl("delete", udid)
            removed.append({"name": name, "udid": udid, "ok": result.returncode == 0,
                            "stderr": result.stderr.strip()[:200]})
    print(json.dumps(removed, indent=2))
    return 0 if all(entry["ok"] for entry in removed) else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    for kind in DEVICES:
        arm = sub.add_parser(kind, help=f"run the step 17 suite on the {kind}")
        arm.add_argument("--only", default=None, help="one test method name")
        arm.set_defaults(func=lambda args, k=kind: run(k, args.only))
    clean = sub.add_parser("cleanup", help="delete the two XCUITest devices")
    clean.set_defaults(func=lambda args: cleanup())
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
