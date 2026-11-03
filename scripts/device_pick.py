"""Which simulator device a measurement is about, in one place.

Step 10 added a second device to the task's own device set — one iPad — so the
same app can be measured in both idioms. Before that every script carried the
phone's name as a module-level constant, which was fine while there was exactly
one device and became a trap the moment there were two: a script that means to
measure the iPad but silently measures the phone produces a page of numbers that
look like an answer and are not.

So the choice follows `DSHPORTE_DEVICE`, exactly like `scripts/device.sh`:

    phone (default)   dsh-portE-iPhone      iPhone 17
    ipad              dsh-portE-iPad        iPad Air 11-inch (M4)
    phone-bg          dsh-portE-iPhone-bg   iPhone 17

`phone-bg` is step 13's third device. It is a real second phone, not an alias
for `phone`: step 11 drives `dsh-portE-iPhone` from another checkout at the same
time with a different build installed, so sharing one device would make every
number ambiguous about which build it describes.

and an unrecognised value is an error, not a fallback. The fallback direction
matters: silently defaulting to the phone is what every earlier report would
have done, and it is the wrong answer for step 10.
"""

from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SIMSET = ROOT / "simdevices"
BUNDLE_ID = "local.dshportc.app"
APP_PATH = ROOT / "DerivedData/Build/Products/Debug-iphonesimulator/DSHPortC.app"
ENV = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}

DEVICES = {
    "phone": ("dsh-portE-iPhone", "com.apple.CoreSimulator.SimDeviceType.iPhone-17"),
    "iphone": ("dsh-portE-iPhone", "com.apple.CoreSimulator.SimDeviceType.iPhone-17"),
    "ipad": ("dsh-portE-iPad", "com.apple.CoreSimulator.SimDeviceType.iPad-Air-11-inch-M4"),
    "phone-bg": ("dsh-portE-iPhone-bg", "com.apple.CoreSimulator.SimDeviceType.iPhone-17"),
    "iphone-bg": ("dsh-portE-iPhone-bg", "com.apple.CoreSimulator.SimDeviceType.iPhone-17"),
    "phone-files": ("dsh-portE-iPhone-files", "com.apple.CoreSimulator.SimDeviceType.iPhone-17"),
    "iphone-files": ("dsh-portE-iPhone-files", "com.apple.CoreSimulator.SimDeviceType.iPhone-17"),
    "phone-polish": ("dsh-portE-iPhone-polish", "com.apple.CoreSimulator.SimDeviceType.iPhone-17"),
    "iphone-polish": ("dsh-portE-iPhone-polish", "com.apple.CoreSimulator.SimDeviceType.iPhone-17"),
}


def kind() -> str:
    """`phone`, `ipad`, `phone-bg`, `phone-files` or `phone-polish`, from DSHPORTE_DEVICE; anything else is refused."""
    wanted = (os.environ.get("DSHPORTE_DEVICE") or "phone").strip().lower()
    if wanted not in DEVICES:
        raise SystemExit(
            f"DSHPORTE_DEVICE={wanted!r} is not one of {sorted(set(DEVICES))}; "
            "refusing to guess which device a measurement is about"
        )
    return {"iphone": "phone", "iphone-bg": "phone-bg", "iphone-files": "phone-files", "iphone-polish": "phone-polish"}.get(wanted, wanted)


def name() -> str:
    return DEVICES[kind()][0]


def device_type() -> str:
    return DEVICES[kind()][1]


# Backwards-compatible module constants, resolved at import time. Scripts that
# predate step 10 read these; new code should call `name()` so the value cannot
# be captured before the environment is set.
DEVICE_NAME = name()
DEVICE_TYPE = device_type()


def simctl(*args, check=False, timeout=180):
    """Run `simctl` against this task's own device set (or the override device's)."""
    return subprocess.run(
        ["xcrun", "simctl", *set_arguments(), *args],
        capture_output=True, text=True, env=ENV, check=check, timeout=timeout,
    )


def host(args, *, check=False, timeout=180):
    """Run a host command with the task's DEVELOPER_DIR."""
    return subprocess.run(args, capture_output=True, text=True, env=ENV, check=check, timeout=timeout)


def udids(wanted: str | None = None) -> list[str]:
    """Every device in this set with that name, in listing order."""
    wanted = wanted or name()
    listing = simctl("list", "devices").stdout
    return [
        match.group(1)
        for line in listing.splitlines()
        if (match := re.match(rf"\s*{re.escape(wanted)} \(([0-9A-F-]+)\)", line))
    ]


def udid_override() -> str | None:
    """`DSHPORTE_UDID` when set: a device OUTSIDE this task's own set.

    The two XCUITest devices (`dsh-portE-xct-17`, `dsh-portE-xct-17-ipad`) live in
    the DEFAULT set, because `xcodebuild` cannot see a custom `--set`. Step 17's
    tools allow exactly that, and nothing else may use this override: everything
    about the task's own devices (names, creation rules) stays as it is.
    """
    value = (os.environ.get("DSHPORTE_UDID") or "").strip()
    return value or None


def set_arguments() -> list[str]:
    """The `simctl --set` prefix, or none when an override device is in use."""
    return [] if udid_override() else ["--set", str(SIMSET)]


def device_udid(create_phone: bool = True) -> str:
    """The selected device's UDID.

    The phone is created on demand because the earlier steps relied on that. The
    iPad is not: step 10's task says exactly one iPad, created once, so a missing
    iPad is a hard error rather than a reason to make another one. `phone-bg` is
    in the iPad's category for step 13's reason: the task states the device
    already exists, and minting a replacement would silently change the data
    container the background-continuation measurements are about.
    """
    override = udid_override()
    if override:
        return override
    found = udids()
    if not found:
        if not create_phone or kind() != "phone":
            raise SystemExit(
                f"the device {name()} does not exist in {SIMSET}; "
                "this script will not create it (create it deliberately and re-run)"
            )
        return simctl("create", name(), device_type(),
                      "com.apple.CoreSimulator.SimRuntime.iOS-27-0", check=True).stdout.strip()
    if len(found) > 1:
        print(f"WARNING {name()} exists {len(found)} times: {found}; using the first", flush=True)
    return found[0]


def is_booted(udid: str) -> bool:
    return f"{udid}) (Booted)" in simctl("list", "devices").stdout


def boot(udid: str) -> None:
    """Boot the device and wait until it is usable."""
    if not is_booted(udid):
        simctl("boot", udid)
        simctl("bootstatus", udid, timeout=300)


def data_container(udid: str) -> Path:
    """The app's data container on the host filesystem."""
    return Path(simctl("get_app_container", udid, BUNDLE_ID, "data", check=True).stdout.strip())
