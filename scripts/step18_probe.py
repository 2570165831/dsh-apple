#!/usr/bin/env python3
"""Ask the running DSHPortC app a question about whatever is on screen.

Step 18's sweep has to look at roughly twenty screens. This is the host half of
the probe in `app/DSHPortC/Step18Probe.swift`: it writes a command file into the
app's Documents directory, waits for the reply file, and prints the value.

    python3 scripts/step18_probe.py --script 'document.title'
    python3 scripts/step18_probe.py --audit                  # the standard audit
    python3 scripts/step18_probe.py --audit --save logs/step18/after-01-session-list.json

Why a file channel and not a port: the app is a WKWebView over a loopback server
this task must not disturb, and adding a listener would be a new attack surface
on a page that already carries an auth token. A file in the app's own container
needs nothing new and is trivially inspectable afterwards.

Every command is given a fresh id, so a stale reply from a previous question can
never be read as the answer to this one.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import device_pick as pick  # noqa: E402


def container() -> Path:
    """The container the running app is actually writing into.

    `simctl get_app_container` is the documented answer and it is not sufficient
    here: the iPad carries several data containers left behind by session
    migration (measured: four `Documents` directories under one device), and
    after a reinstall the command can name one the app has already moved away
    from. The probe writes `step18-probe-status.json` at registration and then
    keeps answering in that same directory, so the freshest such file is the
    honest answer, and the reported path is used only when there is none.
    """
    out = pick.simctl("get_app_container", pick.device_udid(), pick.BUNDLE_ID, "data")
    reported = Path(out.stdout.strip()) if out.returncode == 0 else None
    root = (Path.home() / "Library/Caches/dsh-ios-port-E/simdevices") / pick.device_udid() / "data/Containers/Data/Application"
    candidates: list[tuple[float, Path]] = []
    if root.is_dir():
        for entry in root.iterdir():
            status = entry / "Documents" / "step18-probe-status.json"
            if status.is_file():
                candidates.append((status.stat().st_mtime, entry))
    if candidates:
        candidates.sort(reverse=True)
        fresh = candidates[0][1]
        # A container whose status file is older than a minute while the app is
        # running is a leftover; the probe writes on every launch.
        if time.time() - candidates[0][0] < 600:
            return fresh
    if reported is None:
        raise SystemExit(f"no app container (is the app installed?): {out.stderr.strip()}")
    return reported


def builtin_audit() -> str:
    """The audit script, extracted from the Swift source.

    Not a copy: the sweep must measure exactly what the app would measure, and a
    hand-maintained duplicate in Python is the classic way for the host and the
    app to drift until the numbers mean two different things. The Swift literal is
    a plain `\"\"\"…\"\"\"` block, so taking it out is a slice, not a parse.
    """
    source = (Path(__file__).resolve().parent.parent
              / "app" / "DSHPortC" / "Step18Probe.swift").read_text(encoding="utf-8")
    marker = "static func auditScript() -> String {"
    start = source.index(marker)
    body_open = source.index('"""', start)
    body_close = source.index('"""', body_open + 3)
    body = source[body_open + 3:body_close]
    # The Swift source escapes backslashes for its own string literal.
    return body.replace("\\\\", "\\")


def ask(script: str, timeout: float = 60.0) -> dict:
    root = container()
    command_id = uuid.uuid4().hex[:12]
    command = root / "Documents" / "step18-cmd.json"
    reply = root / "Documents" / f"step18-out-{command_id}.json"
    reply.unlink(missing_ok=True)
    command.write_text(json.dumps({"id": command_id, "script": script}), encoding="utf-8")

    deadline = time.time() + timeout
    while time.time() < deadline:
        if reply.exists():
            try:
                payload = json.loads(reply.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                time.sleep(0.2)
                continue
            reply.unlink(missing_ok=True)
            return payload
        time.sleep(0.15)
    raise SystemExit(f"probe did not answer within {timeout:.0f}s (is the app running with -DSHPortEStep18 1?)")


def main() -> int:
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--script", help="JavaScript to evaluate in the app's web view")
    group.add_argument("--audit", action="store_true", help="run the standard per-screen audit")
    group.add_argument("--audit-file", help="run the audit from a file on the host")
    parser.add_argument("--save", help="write the parsed result to this path")
    parser.add_argument("--raw", action="store_true", help="print the raw reply, not the parsed value")
    parser.add_argument("--timeout", type=float, default=60.0)
    # Defaulting to the phone is what step 11's scripts do, and here it is a
    # real hazard: step 15 is running its own build on `dsh-portE-iPhone` at the
    # same time, so a probe that defaulted to the phone would poke ANOTHER task's
    # simulator container. This task's device is the only safe default.
    parser.add_argument("--device", default=os.environ.get("DSHPORTE_DEVICE", "phone-polish"),
                        help="phone-polish (default) or ipad")
    args = parser.parse_args()

    if args.device:
        os.environ["DSHPORTE_DEVICE"] = args.device

    if args.script:
        script = args.script
    elif args.audit_file:
        script = Path(args.audit_file).read_text(encoding="utf-8")
    else:
        script = builtin_audit()

    payload = ask(script, timeout=args.timeout)
    if args.raw:
        json.dump(payload, sys.stdout, ensure_ascii=False, indent=2)
        print()
        return 0

    value = payload.get("value")
    if isinstance(value, str):
        try:
            parsed = json.loads(value)
        except json.JSONDecodeError:
            parsed = value
    else:
        parsed = value
    if args.save:
        target = Path(args.save)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(parsed, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"saved {target}")
    else:
        json.dump(parsed, sys.stdout, ensure_ascii=False, indent=2)
        print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
