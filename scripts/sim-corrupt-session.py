#!/usr/bin/env python3
"""One damaged session log must isolate itself and nothing else.

The requirement is specific: corrupt a single session's log, and the result must be
that ONE session is set aside, the others still load, and the log says why.
"Others still load" is the part that needs the real app: DSH's registry aborts the
whole listing if any header fails, which is why step 4B quarantined everything.

WHAT THIS DOES
  1. fresh install, two sessions with one completed turn each,
  2. overwrite one log's first frame with bytes that are not a Zstandard frame,
  3. relaunch and read what happened.

USAGE
    scripts/sim-corrupt-session.py [--keep-app]
"""
from __future__ import annotations

import argparse
import json
import os
import re
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
MOCK_PORT = int(os.environ.get("MOCK_PORT", "19700"))
PROMPT = ROOT / "prompts" / "02-streaming.txt"
ENV = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}
# The three files the app writes for observability live under Library/Application
# Support, not Documents, so they stay out of the Files app.
RUNTIME_DIR = "Library/Application Support/DSHPortC"


def run(args, *, check=False, timeout=300):
    return subprocess.run(args, capture_output=True, text=True, env=ENV, check=check, timeout=timeout)


def simctl(*args, check=False, timeout=300):
    return run(["xcrun", "simctl", "--set", str(SIMSET), *args], check=check, timeout=timeout)


def udid() -> str:
    return device_pick.device_udid(create_phone=False)


def boot(device: str) -> None:
    if f"{device}) (Booted)" not in simctl("list", "devices").stdout:
        simctl("boot", device)
        simctl("bootstatus", device, "-b")


def container(device: str) -> Path:
    return Path(simctl("get_app_container", device, BUNDLE_ID, "data", check=True).stdout.strip())


def launch(device: str, *, drive: bool, list_acceptance: bool = False,
           session_id: str | None = None) -> None:
    args = ["xcrun", "simctl", "--set", str(SIMSET), "launch", device, BUNDLE_ID]
    if drive:
        args += ["-DSHPortCTestDrive", "1",
                 "-DSHPortCTestPrompt", PROMPT.read_text(),
                 "-DSHPortCTestKeyword", "STREAMTEST-COMPLETE"]
    if list_acceptance:
        args += ["-DSHPortCTestSessionListAcceptance", "1"]
    if session_id:
        args += ["-DSHPortCTestSessionId", session_id]
    subprocess.run(args, capture_output=True, text=True, env=ENV, timeout=120)


def wait_ready(c: Path, timeout: float = 150, *, newer_than: float | None = None) -> dict:
    deadline = time.time() + timeout
    last: dict = {}
    path = c / RUNTIME_DIR / "DSHPortC-status.json"
    while time.time() < deadline:
        if path.exists() and (newer_than is None or path.stat().st_mtime >= newer_than):
            try:
                last = json.loads(path.read_text())
            except json.JSONDecodeError:
                last = {}
            if last.get("phase") == "webViewReady":
                return last
        time.sleep(2)
    return last


def session_logs(c: Path) -> list[Path]:
    return sorted((c / "Library/Application Support/DSH/sessions").rglob("*.jsonl.zstd"))


def wait_one_session(c: Path, timeout: float = 300) -> list[Path]:
    """One session with a completed turn."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        logs = session_logs(c)
        if logs and run(["zstd", "-dc", str(logs[0])]).stdout.count("turn/end") > 0:
            return logs
        time.sleep(4)
    return session_logs(c)


def duplicate_session(source: Path, new_id: str) -> Path:
    """A second session in the same project directory, built from a real one.

    WHY A FIXTURE AND NOT A SECOND CONVERSATION. DSH reuses a blank session, so a
    relaunch puts the new turn in the SAME session (measured: two launches, still
    one log). Creating a second one through the UI would need a click on the "new
    session" button, and this device's sidebar is a 56 px rail with no rows in the
    DOM. So the second session is a copy of the first with its own id — which is
    exactly the shape two real conversations have: same project directory, same
    container, different ids.
    """
    import shutil

    target_dir = source.parent.parent / new_id
    target_dir.mkdir(parents=True, exist_ok=False)
    target = target_dir / source.name
    raw = run(["zstd", "-dc", str(source)]).stdout
    lines = raw.splitlines(keepends=True)
    header = json.loads(lines[0])
    header["id"] = new_id
    header["createdAt"] = header["createdAt"] + 1000
    # Rebuild the log with the same frame layout DSH uses: header frame first.
    import subprocess as sp
    header_frame = sp.run(["zstd", "-c", "--no-progress"], input=(json.dumps(header).replace("\n", "") + "\n").encode(),
                          capture_output=True, check=True).stdout
    body = "".join(lines[1:]).encode()
    body_frame = sp.run(["zstd", "-c", "--no-progress"], input=body, capture_output=True, check=True).stdout
    target.write_bytes(header_frame + body_frame)
    return target


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--keep-app", action="store_true")
    args = parser.parse_args()

    LOGS.mkdir(parents=True, exist_ok=True)
    device = udid()
    boot(device)
    if run(["curl", "-sf", "-m", "3", f"http://127.0.0.1:{MOCK_PORT}/healthz"]).returncode != 0:
        raise SystemExit(f"mock model server not answering on {MOCK_PORT}; run scripts/mock-start.sh start")

    evidence: dict = {"steps": []}

    def note(name: str, ok: bool, detail: object) -> None:
        evidence["steps"].append({"name": name, "ok": bool(ok), "detail": detail})
        text = detail if isinstance(detail, str) else json.dumps(detail, ensure_ascii=False)
        print(f"{'PASS' if ok else 'FAIL'}  {name}  [{text[:360]}]")

    # ---- 1. two sessions, one turn each ------------------------------------
    simctl("terminate", device, BUNDLE_ID)
    simctl("uninstall", device, BUNDLE_ID)
    simctl("install", device, str(APP), check=True)
    c = container(device)
    stamp = time.time() - 1
    launch(device, drive=True)
    wait_ready(c, newer_than=stamp)
    logs = wait_one_session(c)
    if not logs:
        raise SystemExit("no session was created; the isolation check needs a log to work with")
    simctl("terminate", device, BUNDLE_ID)
    time.sleep(3)
    second = duplicate_session(logs[0], "session-00000000-0000-4000-8000-00000000c0de")
    logs = session_logs(c)
    note("two sessions exist before the damage", len(logs) >= 2, [p.parent.name for p in logs])
    if len(logs) < 2:
        raise SystemExit("the second session fixture was not created")

    simctl("terminate", device, BUNDLE_ID)
    time.sleep(3)

    # ---- 2. damage exactly one log's header frame --------------------------
    logs = session_logs(c)
    healthy, damaged = logs[0], logs[1]
    original = damaged.read_bytes()
    # Not a Zstandard frame at all: the reader's first step must be what fails.
    damaged.write_bytes(b"\xde\xad\xbe\xef" * 8)
    evidence["damaged"] = damaged.parent.name
    evidence["healthy"] = healthy.parent.name
    note("one log's header frame is now unreadable", damaged.read_bytes()[:4] == b"\xde\xad\xbe\xef",
         f"{damaged.parent.name}: {len(original)} -> {damaged.stat().st_size} bytes")

    # ---- 3. relaunch: only the damaged one is set aside ---------------------
    stamp = time.time() - 1
    launch(device, drive=False)
    ready = wait_ready(c, newer_than=stamp)
    note("the app still reaches webViewReady", ready.get("phase") == "webViewReady", ready.get("detail"))

    home = c / "Library/Application Support/DSH"
    summary_path = home / "DSHPortE-session-migrate.json"
    summary = json.loads(summary_path.read_text()) if summary_path.exists() else {}
    evidence["migrateSummary"] = summary
    migrated = summary.get("migrated") or {}
    note("exactly one session was isolated", migrated.get("quarantined") == 1, migrated)
    note("the isolation names the reason",
         any("invalid frame magic" in reason or "header" in reason for reason in (migrated.get("failed") or [])),
         migrated.get("failed"))

    quarantine = home / "sessions-quarantine"
    isolated = [p for p in quarantine.rglob("*") if p.is_dir()] if quarantine.is_dir() else []
    names = [p.name for p in isolated]
    evidence["quarantineDirs"] = names
    note("the damaged session sits in quarantine", damaged.parent.name in names, names)
    note("the healthy session does not", healthy.parent.name not in names, names)

    remaining = {p.parent.name for p in session_logs(c)}
    note("the healthy session's log is still in place", healthy.parent.name in remaining, sorted(remaining))

    node_log = (c / RUNTIME_DIR / "DSHPortC-node.log").read_text(errors="replace")
    isolation_lines = [l for l in node_log.splitlines() if "isolating" in l or "left in quarantine" in l]
    note("the boot log explains the isolation", bool(isolation_lines), isolation_lines[:3])
    warnings = [l for l in node_log.splitlines() if "did not activate" in l or "corrupt" in l]
    note("no activation warning and no corrupt-log error", not warnings, warnings[:4])

    # ---- 4. DSH must still list the healthy one ---------------------------
    simctl("terminate", device, BUNDLE_ID)
    time.sleep(2)
    acceptance = c / "Documents/DSHPortE-session-list-acceptance.json"
    if acceptance.exists():
        acceptance.unlink()
    launch(device, drive=False, list_acceptance=True, session_id=healthy.parent.name)
    for _ in range(45):
        if acceptance.exists():
            break
        time.sleep(2)
    criteria = json.loads(acceptance.read_text())["criteria"] if acceptance.exists() else {}
    evidence["sessionListAcceptance"] = criteria
    ids = criteria.get("session_persistence_lists_sessions", {}).get("sessions", [])
    listed = [row.get("id") for row in ids]
    note("DSH lists the healthy session", healthy.parent.name in listed, listed)
    note("DSH does not list the isolated one", damaged.parent.name not in listed, listed)
    opened = criteria.get("open_session", {})
    note("DSH reads the healthy session's history", opened.get("ok") is True,
         {k: opened.get(k) for k in ("via", "eventCount", "hasTurnEnd", "error")})

    simctl("terminate", device, BUNDLE_ID)
    evidence["ok"] = all(step["ok"] for step in evidence["steps"])
    (LOGS / "corrupt-session.json").write_text(json.dumps(evidence, indent=2, ensure_ascii=False))
    if not args.keep_app:
        simctl("uninstall", device, BUNDLE_ID)
    passed = sum(1 for s in evidence["steps"] if s["ok"])
    print(f"\n{'PASS' if evidence['ok'] else 'FAIL'} {passed}/{len(evidence['steps'])} checks")
    return 0 if evidence["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
