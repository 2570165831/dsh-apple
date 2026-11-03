#!/usr/bin/env python3
"""The phone's state after step 6: duplicate workspace records + quarantined sessions
+ a container change. Fails before `dedupeWorkspaceRegistry` runs last, passes after.

What it builds (all real except the plant):
  1. fresh install, one real turn -> session S in container A
  2. PLANT: a second workspace record for the SAME folder spelled the device way
     (`/private/var/mobile/Containers/Data/Application/<other>/Documents/...`), and
     S's folder moved into `sessions-quarantine/<stamp>/` (what the step-4B/5
     builds did on every install)
  3. `simctl install` over -> container B (the platform's own container change)
  4. launch: migration + quarantine sweep run in Node. Without the final dedupe the
     respell gives both records one path and DSH refuses the registry.
Checks: no activation warning / inconsistent / pending, S restored and listed, one
workspace record per path, a fresh session can be created and S takes a further turn.

    scripts/sim-dup-registry-test.py [--bundle-module PATH]
      --bundle-module  copy PATH over sim/session-migrate.mjs inside the app bundle
                       before installing (used to run the PRE-fix module)
"""
import argparse, importlib.util, json, re, shutil, sys, time
from pathlib import Path
spec = importlib.util.spec_from_file_location("cs", str(Path(__file__).with_name("sim-container-sessions.py")))
cs = importlib.util.module_from_spec(spec); spec.loader.exec_module(cs)

ap = argparse.ArgumentParser(); ap.add_argument("--bundle-module"); ap.add_argument("--name", default="dup-registry")
args = ap.parse_args()
device = cs.udid(); cs.boot(device)
steps = []
def note(name, ok, detail):
    steps.append({"name": name, "ok": bool(ok), "detail": detail})
    print(f"{'PASS' if ok else 'FAIL'}  {name}  [{(detail if isinstance(detail, str) else json.dumps(detail, ensure_ascii=False))[:300]}]")

if args.bundle_module:
    shutil.copy(args.bundle_module, cs.APP / "sim/session-migrate.mjs")
    print("bundle module replaced with", args.bundle_module)

cs.simctl("terminate", device, cs.BUNDLE_ID); cs.simctl("uninstall", device, cs.BUNDLE_ID)
cs.simctl("install", device, str(cs.APP), check=True)
a = cs.container(device); t0 = time.time() - 1
cs.launch(device, drive=True)
cs.wait_ready(a, newer_than=t0)
ends = [e for e in cs.wait_turns(a, 1) if e.get("type") == "turn/end"]
note("one real turn in container A", len(ends) >= 1, f"{len(ends)} turn/end")
cs.simctl("terminate", device, cs.BUNDLE_ID); time.sleep(3)

home = a / "Library/Application Support/DSH"
logs = sorted((home / "sessions").rglob("*.jsonl.zstd"))
sid = logs[0].parent.name; proj = logs[0].parent.parent
# --- plant ---
reg_path = home / "storages/workspace.json"
reg = json.loads(reg_path.read_text())
rid, rec = next(iter(reg["tables"]["workspaces"].items()))
tail = rec["path"].split("/Documents/", 1)[1]
dup = dict(rec); dup["path"] = f"/private/var/mobile/Containers/Data/Application/3A57BFE5-561B-4FA4-A595-75CD5A5C6E52/Documents/{tail}"
dup["sessionIds"] = []; dup["createdAt"] = "2099-01-01T00:00:00.000Z"; dup["title"] = rec.get("title")
reg["tables"]["workspaces"]["dup-device-spelling"] = dup
reg["global"]["workspaceIds"].append("dup-device-spelling")
rec["sessionIds"] = []
reg_path.write_text(json.dumps(reg, indent=2))
q = home / "sessions-quarantine/2026-10-28T000000Z" / proj.name; q.mkdir(parents=True)
shutil.move(str(logs[0].parent), str(q / sid))
shutil.rmtree(home / "storages/session_projcache", ignore_errors=True)
note("planted: duplicate record (device spelling) + session S in quarantine", True, {"S": sid})

cs.simctl("install", device, str(cs.APP), check=True)
b = cs.container(device)
note("container changed", a != b and not a.exists(), f"{a.name} -> {b.name}")
t0 = time.time() - 1
cs.launch(device, drive=False)
ready = cs.wait_ready(b, newer_than=t0)
note("app reaches webViewReady", ready.get("phase") == "webViewReady", ready.get("detail"))
node_log = (b / cs.RUNTIME_DIR / "DSHPortC-node.log").read_text(errors="replace")
warn = [l[:230] for l in node_log.splitlines() if re.search(r"did not activate|corrupt|pending \(waiting|inconsistent", l)]
note("no 'did not activate' / inconsistent / pending", not warn, warn[:3])
bh = b / "Library/Application Support/DSH"
rg = json.loads((bh / "storages/workspace.json").read_text())
paths = [w["path"] for w in rg["tables"]["workspaces"].values()]
note("one workspace record per path", len(paths) == len(set(paths)), paths)
restored = list((bh / "sessions").rglob(sid))
note("session S restored from quarantine", len(restored) == 1, [str(p.relative_to(b)) for p in restored])
summ = json.loads((bh / "DSHPortE-session-migrate.json").read_text()) if (bh / "DSHPortE-session-migrate.json").exists() else {}
note("migration summary: restored count", True, (summ.get("recovered") or {}))

if not warn:
    # a fresh session can be created and a message accepted
    cs.simctl("terminate", device, cs.BUNDLE_ID); time.sleep(2)
    t0 = time.time() - 1
    cs.launch(device, drive=True, open_first=False)
    cs.wait_ready(b, newer_than=t0)
    ends = [e for e in cs.wait_turns(b, 2) if e.get("type") == "turn/end"]
    note("a new session takes a turn (UI drive)", len(ends) >= 1, f"{len(ends)} turn/end total")
    # S opens and takes a further turn
    cs.simctl("terminate", device, cs.BUNDLE_ID); time.sleep(2)
    out = b / "Documents/DSHPortE-session-continue-acceptance.json"
    out.unlink(missing_ok=True)
    cs.launch(device, drive=False, continue_session=True, session_id=sid, continue_prompt="STEP echo continued-after-dedupe")
    cont = {}
    for _ in range(80):
        if out.exists():
            try: cont = json.loads(out.read_text()).get("criteria", {})
            except json.JSONDecodeError: cont = {}
            if "took_a_turn" in cont or "error" in cont: break
        time.sleep(3)
    took = cont.get("took_a_turn") or {}
    note("restored session S takes a further turn", took.get("finishedATurn") is True, took)
    note("history intact and new prompt recorded", (cont.get("history_intact") or {}).get("carriesTheNewPrompt") is True, cont.get("history_intact"))
cs.simctl("terminate", device, cs.BUNDLE_ID)
ok = all(s["ok"] for s in steps)
(cs.LOGS / f"{args.name}.json").write_text(json.dumps({"ok": ok, "steps": steps, "migrate": summ}, indent=2, ensure_ascii=False))
print(f"\n{'PASS' if ok else 'FAIL'} {sum(s['ok'] for s in steps)}/{len(steps)}")
sys.exit(0 if ok else 1)
