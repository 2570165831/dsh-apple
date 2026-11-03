#!/usr/bin/env python3
"""A/B the old and new timezone configuration inside the real app.

The task's claim is "the interface time is fixed to UTC". Before this repo
changes anything else, that claim has to be located: which clock showed UTC, in
which runtime. Guessing here would make the report fiction, and the two candidate
runtimes are genuinely different:

  * the DSH page runs in WKWebView, i.e. WebKit with real ICU and its own `Intl`;
  * the DSH host runs in nodejs-mobile with no ICU, and its `Intl` is
    `sim/intl-shim.cjs`.

So this script installs the CURRENT build twice, changing only the timezone
configuration between runs:

  before   the step-2 state: `timeZone: UTC` pinned in the profile, and the
           step-2 shim (no device table) copied over the bundled one;
  after    this step's state: no pin, and the shipped shim fed by the device
           table the Swift host publishes.

For each run it records, from inside the app and from the model's own request log:

  * the clock text the page actually rendered (`[data-clock]` spans and any
    clock-shaped text node),
  * the page's own zone and offset,
  * the eight DST comparisons,
  * the timestamp `dsh-time-context` put in front of the model.

WHAT THIS A/B CAN AND CANNOT SHOW (measured, and the reason the report leans on
two other scripts for the fix itself)
---------------------------------------------------------------------------------------------------------------
The PAGE column comes out identical on both sides, and that is a true result rather
than a broken measurement: the page's clocks run in WKWebView, which has real ICU
and never consulted the shim or the profile pin. So a page-side clock was never the
thing pinned to UTC. Keep this in mind when reading the comparison output — two
equal columns here do NOT mean the change did nothing.

The clock that WAS pinned to UTC is the HOST-side one, `dsh-time-context`'s stamp
for the model, and it is measured two ways instead:

  * `scripts/intl-shim-compare.mjs` — both shims, eight instants, with and without
    an explicit zone. Before: a formatter with no explicit zone answers UTC and 0/8
    instants are right. After: 8/8.
  * `scripts/intl-callsite-audit.mjs` — the real call sites of
    `dsh-time-context`, `dsh-util-time`, `dsh-storage-json` under both shims, in
    both seasons. Before: the model-visible stamp reads
    `2026-10-28T09:28:37+00:00`. After: `2026-10-28T20:28:37+11:00`.

Both of those run the shim the way the app does, but in a host Node process. The
in-app confirmation is `sim/tz-probe.mjs`, which answers from inside the app's own
Node: `-DSHPortCTestTzProbe 1` writes `DSHPortE-tz-probe.json` with the resolved
zone, the published transition table and the same eight DST instants.


Usage
    scripts/sim-tz-ab.py            both runs, then restore
    scripts/sim-tz-ab.py --keep     leave the last install in place

Only this task's simulator and this task's app are touched. The installed app
bundle is modified for the "before" run (a shim file swap), which is why the
"after" run reinstalls from DerivedData rather than patching back.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOGS = ROOT / "logs" / "step6"
SIMSET = ROOT / "simdevices"
BUNDLE_ID = "local.dshportc.app"
# Which device, from DSHPORTE_DEVICE: `phone` (default) or `ipad`. Centralised so
# a script cannot quietly measure the wrong idiom — see scripts/device_pick.py.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import device_pick  # noqa: E402

DEVICE_NAME = device_pick.name()
APP = ROOT / "DerivedData/Build/Products/Debug-iphonesimulator/DSHPortC.app"
MOCK_REQUESTS = ROOT / "logs" / "mock-requests.jsonl"
BEFORE_SHIM = LOGS / "intl-shim-before.cjs"
PROMPT = ROOT / "prompts" / "02-streaming.txt"
# The zone the task names. A simulator has no Settings.app zone picker reachable
# from `simctl`; the device's `TimeZone.current` follows the TZ the process is
# started with. So the zone is set explicitly and both halves asserted against it.
ZONE = "Australia/Sydney"
ENV = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}


def run(args, *, check=False, timeout=180):
    return subprocess.run(args, capture_output=True, text=True, env=ENV, check=check, timeout=timeout)


def simctl(*args, check=False, timeout=180):
    return run(["xcrun", "simctl", "--set", str(SIMSET), *args], check=check, timeout=timeout)


def udid() -> str:
    return device_pick.device_udid(create_phone=False)


def container(device: str) -> Path:
    return Path(simctl("get_app_container", device, BUNDLE_ID, "data", check=True).stdout.strip())


def app_container(device: str) -> Path:
    return Path(simctl("get_app_container", device, BUNDLE_ID, "app", check=True).stdout.strip())


def read_clocks(c: Path) -> dict:
    """The driver's clock record, if the run produced one."""
    path = c / "Documents/DSHPortC-uidrive.json"
    if not path.exists():
        return {}
    drive = json.loads(path.read_text())
    for event in drive.get("events", []):
        if event.get("event") == "clocks":
            return event
    return {}


def model_stamp(c: Path, since: float) -> dict:
    """The newest time-context stamp the host sent to the model, and its zone."""
    if not MOCK_REQUESTS.exists():
        return {}
    newest = {}
    for line in MOCK_REQUESTS.open(errors="replace"):
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        # The request log stamps each record with an ISO `t`; `receivedAt` does
        # not exist, and comparing against it silently matched nothing.
        stamp_iso = record.get("t")
        if not isinstance(stamp_iso, str):
            continue
        try:
            when = time.mktime(time.strptime(stamp_iso, "%Y-%m-%dT%H:%M:%S.%fZ")) - time.timezone
        except ValueError:
            continue
        if when < since:
            continue
        text = json.dumps(record)
        stamp = re.search(r"Time sampled while preparing turn[^\\\"]*", text)
        zone = re.search(r"Browser time zone for this request[^\\\"]*", text)
        if stamp:
            newest = {"stamp": stamp.group(0), "browserZone": zone.group(0) if zone else None}
    return newest


def boot(device: str) -> None:
    if f"{device}) (Booted)" not in simctl("list", "devices").stdout:
        simctl("boot", device)
        simctl("bootstatus", device, "-b")


def install_fresh(device: str) -> None:
    simctl("terminate", device, BUNDLE_ID)
    simctl("uninstall", device, BUNDLE_ID)
    simctl("install", device, str(APP), check=True)


def launch_and_wait(device: str, *, clocks: bool, zone: str = ZONE) -> None:
    """Launch with the driver enabled, and the prompt as a LAUNCH ARGUMENT.

    Not `SIMCTL_CHILD_*` for the prompt: the simulator keeps the first set of those
    it saw until the whole device shuts down (REPORT-5, and this step hit it
    repeatedly), so a variable introduced on a later launch never arrives — the run
    then completes with no clock record and looks like a measurement that found
    nothing.

    `SIMCTL_CHILD_TZ` IS passed, and that is deliberate rather than contradictory.
    The task's criterion is "the simulator's time zone is Australia/Sydney", and a
    simulator has no Settings.app zone picker reachable from `simctl`: the device's
    `TimeZone.current` follows the TZ this process is started with (measured — with
    `TZ=UTC` the app's own `TimeZone.current.identifier` reports `GMT` and its DST
    table collapses to one entry). So the zone is SET here, explicitly, and both
    halves of the app (Swift `TimeZone.current` and the Node shim) are asserted
    against it. It is a fresh boot per A/B side, so the "first value wins" trap does
    not apply: nothing else has set TZ on this device.
    """
    environment = {**ENV, "SIMCTL_CHILD_TZ": zone}
    args = ["xcrun", "simctl", "--set", str(SIMSET), "launch", device, BUNDLE_ID,
            "-DSHPortCTestDrive", "1",
            "-DSHPortCTestPrompt", PROMPT.read_text(),
            "-DSHPortCTestKeyword", "STREAMTEST-COMPLETE"]
    if clocks:
        args += ["-DSHPortCTestClocks", "1"]
    subprocess.run(args, capture_output=True, text=True, env=environment, timeout=120)


def wait_for_clocks(c: Path, timeout: float) -> None:
    """Wait until the driver has written its clock record (or given up)."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if read_clocks(c):
            return
        time.sleep(3)


def summarise(label: str, clocks: dict, stamp: dict) -> dict:
    observed = clocks.get("observed") or {}
    page = observed.get("page") or {}
    cases = observed.get("cases") or []
    matched = 0
    for case in cases:
        want = case.get("expectedWall")
        got = case.get("got") or ""
        # `got` is ISO + offset + [zone]; compare the ISO and offset only.
        if want and got.startswith(want):
            matched += 1
    return {
        "label": label,
        "pageZone": page.get("zone"),
        "pageOffsetMinutes": page.get("offsetMinutes"),
        "pageLocalWall": page.get("localWall"),
        "pageNowStamp": page.get("nowStamp"),
        "clockSpans": observed.get("clockSpans"),
        "clockTexts": observed.get("clockTexts"),
        "dstCases": len(cases),
        "dstCasesCorrect": matched,
        "modelStamp": stamp.get("stamp"),
        "modelBrowserZone": stamp.get("browserZone"),
        "hostZone": clocks.get("hostZone"),
        "hostOffsetMinutes": clocks.get("hostOffsetMinutes"),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--keep", action="store_true", help="do not reinstall after the before run")
    parser.add_argument("--only", choices=["before", "after"], help="run just one side")
    args = parser.parse_args()

    LOGS.mkdir(parents=True, exist_ok=True)
    if not BEFORE_SHIM.exists():
        raise SystemExit(f"missing {BEFORE_SHIM}; create it with:\n"
                         f"  git show HEAD:sim/intl-shim.cjs > {BEFORE_SHIM}")
    device = udid()
    boot(device)
    results = []

    if args.only in (None, "before"):
        # ---- before: the step-2 configuration -------------------------------
        install_fresh(device)
        app = app_container(device)
        shutil.copy2(BEFORE_SHIM, app / "sim" / "intl-shim.cjs")
        # The UTC pin has to go into the BUNDLE's profile template, not the
        # container's copy. `NodeRunner.prepareDSHHome` re-renders
        # `profiles/ios-sim/cordis.patch.yml` from the bundle into the container on
        # EVERY launch ("the patch layer is rewritten every launch"), so patching
        # the container copy and relaunching silently discarded the pin. Measured:
        # the first version of this script did exactly that and the "before" run
        # came back with `pageZone: Australia/Sydney` — i.e. it measured the NEW
        # configuration twice and would have "shown" that the fix changed nothing.
        bundle_patch = app / "profiles" / "ios-sim" / "cordis.patch.yml"
        text = bundle_patch.read_text()
        if "    timeZone: UTC" not in text:
            pinned = text.replace("- id: time-context\n  config:\n    refreshIntervalMs: 600000",
                                  "- id: time-context\n  config:\n    timeZone: UTC\n    refreshIntervalMs: 600000")
            if pinned == text:
                raise SystemExit("could not find the time-context row to pin; the profile changed shape")
            bundle_patch.write_text(pinned)
        started = time.time()
        launch_and_wait(device, clocks=True)
        wait_for_clocks(container(device), 260)
        summary = summarise("before (timeZone: UTC pinned in the bundle, step-2 shim)",
                            read_clocks(container(device)),
                            model_stamp(container(device), started))
        results.append(summary)
        (LOGS / "tz-ab-before.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False))
        print(json.dumps(summary, indent=2, ensure_ascii=False))

    if args.only in (None, "after") or not args.keep:
        # ---- after: this step's configuration --------------------------------
        install_fresh(device)
        started = time.time()
        launch_and_wait(device, clocks=True)
        wait_for_clocks(container(device), 260)
        summary = summarise("after (device zone, device table)", read_clocks(container(device)),
                            model_stamp(container(device), started))
        results.append(summary)
        (LOGS / "tz-ab-after.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False))
        print(json.dumps(summary, indent=2, ensure_ascii=False))

    simctl("terminate", device, BUNDLE_ID)
    (LOGS / "tz-ab-combined.json").write_text(json.dumps(results, indent=2, ensure_ascii=False))

    if len(results) == 2:
        before, after = results
        print("\n--- comparison")
        for key in ("pageZone", "clockSpans", "modelStamp", "dstCasesCorrect"):
            print(f"  {key}: before={before.get(key)!r}  after={after.get(key)!r}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
