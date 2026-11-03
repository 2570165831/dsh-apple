#!/usr/bin/env python3
"""Plant a duplicate workspace record (same folder, second id) in the sim
container, relaunch, and require: registry repaired, no activation warnings, a new
prompt accepted. Run after scripts/agent-turn.py (it needs an installed container)."""
import importlib.util, json, re, sys, time, subprocess
from pathlib import Path
spec = importlib.util.spec_from_file_location("at", str(Path(__file__).with_name("agent-turn.py")))
at = importlib.util.module_from_spec(spec); spec.loader.exec_module(at)
udid = at.device_udid(); at.boot(udid)
c = at.data_container(udid)
reg = c / "Library/Application Support/DSH/storages/workspace.json"
at.simctl("terminate", udid, at.BUNDLE_ID)
d = json.loads(reg.read_text())
wid, w = next(iter(d["tables"]["workspaces"].items()))
dup = dict(w); dup["sessionIds"] = ["session-00000000-0000-0000-0000-000000000000"]; dup["createdAt"] = "2099-01-01T00:00:00.000Z"
d["tables"]["workspaces"]["dup-0001"] = dup
d["global"]["workspaceIds"].append("dup-0001")
reg.write_text(json.dumps(d, indent=1))
prompt = Path(sys.argv[1]).read_text()
env = {**at.ENV, "SIMCTL_CHILD_DSHPORT_UITEST_PROMPT": prompt, "SIMCTL_CHILD_DSHPORT_UITEST_KEYWORD": ""}
subprocess.run(["xcrun", "simctl", "--set", str(at.SIMSET), "launch", udid, at.BUNDLE_ID, "-DSHPortCTestDrive", "1"], capture_output=True, text=True, env=env, timeout=120)
time.sleep(40)
log = (c / at.RUNTIME_DIR / "DSHPortC-node.log").read_text(errors="replace")
for l in log.splitlines():
    if re.search(r"repaired|did not activate|inconsistent|pending|diag-prompt", l): print(l[:240])
after = json.loads(reg.read_text())
print("workspaces after:", len(after["tables"]["workspaces"]), "ids:", after["global"]["workspaceIds"])
ev = at.read_session_events(c)
print("last events:", [e.get("type") for e in ev][-6:])
ok = "diag-prompt: accepted" in log and "did not activate" not in log
print("PASS" if ok else "FAIL")
