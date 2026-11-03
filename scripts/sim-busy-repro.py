#!/usr/bin/env python3
"""Reproduce 'agent busy' after a container change (step 4B follow-up).

Assumes scripts/agent-turn.py already ran once (fresh install + one good turn).
Then: pretend the container moved (old UUID in the stored paths, old marker,
session folders named after the old path), relaunch WITHOUT reinstalling, drive a
NEW session + prompt through the real UI, and report whether it was accepted.
"""
import importlib.util, json, re, sys, time, subprocess, os
from pathlib import Path
spec = importlib.util.spec_from_file_location("at", str(Path(__file__).with_name("agent-turn.py")))
at = importlib.util.module_from_spec(spec); spec.loader.exec_module(at)
udid = at.device_udid(); at.boot(udid)
c = at.data_container(udid)
home = c / "Library/Application Support/DSH"
OLD = "/private/var/mobile/Containers/Data/Application/3A57BFE5-561B-4FA4-A595-75CD5A5C6E52"
at.simctl("terminate", udid, at.BUNDLE_ID)
cur = str(c)
n = 0
for f in (home / "storages").rglob("*.json"):
    t = f.read_text()
    if cur in t:
        f.write_text(t.replace(cur, OLD)); n += 1
tag = lambda p: p.lstrip("/").replace("/", "-")
for d in (home / "sessions").iterdir():
    if tag(cur) in d.name:
        d.rename(d.with_name(d.name.replace(tag(cur), tag(OLD))))
(home / ".container-root").write_text(OLD)
print("planted stale state in", n, "storage file(s)")
prompt = Path(sys.argv[1]).read_text()
env = {**at.ENV, "SIMCTL_CHILD_DSHPORT_UITEST_PROMPT": prompt, "SIMCTL_CHILD_DSHPORT_UITEST_KEYWORD": ""}
before = {p.name for p in (home / "sessions").rglob("session-*") if p.is_dir()}
subprocess.run(["xcrun", "simctl", "--set", str(at.SIMSET), "launch", udid, at.BUNDLE_ID, "-DSHPortCTestDrive", "1"],
               capture_output=True, text=True, env=env, timeout=120)
time.sleep(40)
log = (c / at.RUNTIME_DIR / "DSHPortC-node.log").read_text(errors="replace")
ui = c / "Documents/DSHPortC-uidrive.json"
print("--- node log (migration/warnings):")
for l in log.splitlines():
    if re.search(r"container changed|did not activate|corrupt|pending|busy|error|Error", l): print(l[:300])
print("--- uidrive tail:", (ui.read_text()[-700:] if ui.exists() else "none"))
after = {p.name for p in (home / "sessions").rglob("session-*") if p.is_dir()}
print("new session dirs:", sorted(after - before))
ev = at.read_session_events(c)
print("event types:", [e.get("type") for e in ev][-12:])
