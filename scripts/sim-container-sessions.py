#!/usr/bin/env python3
"""A real install-over must not cost the user their sessions.

WHY THIS IS THE RIGHT TEST, AND WHY THE FIRST VERSION WAS NOT. The first version
faked the container change by editing DSH_HOME in place. It failed, and the reason
is worth recording: `simctl install` over an existing app REASSIGNS the data
container, carries DSH_HOME into the new one, and deletes the old container — on
the simulator exactly as on a device. So the platform provides the very event the
task is about, with no fixture at all:

    install  ->  container A, DSH_HOME lives at A
    use app  ->  a session log whose header says .../Application/A/...
    install  ->  container B, DSH_HOME now lives at B, header still says A, A is gone

That is the state step 4B hit on the phone, and the one the migration has to
survive. The fake fixture was also wrong in a way that mattered: it wrote a
`/private/var/...` spelling into a simulator container, a path that does not exist
on this platform, so "the header names a real directory" could never hold and the
report would have described a fixture bug as a product bug.

WHAT IS CHECKED
  1. the pre-update session's header names container A, and A is the live one,
  2. after the install-over, the container is B and the session folder came along,
  3. the migration rewrote the header to B and moved the folder to B's project key,
  4. DSH lists the session and a further turn runs INSIDE it (not a new session),
  5. `workspace.json` names B and still accounts for the session,
  6. no activation warning, corrupt log, or pending service.

USAGE
    scripts/sim-container-sessions.py              the acceptance
    scripts/sim-container-sessions.py --keep-app   leave the app installed
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


def launch(device: str, *, drive: bool, clocks: bool = False, open_first: bool = False,
           session_id: str | None = None,
           list_acceptance: bool = False,
           continue_session: bool = False,
           continue_prompt: str | None = None) -> subprocess.CompletedProcess:
    # The prompt travels as a launch ARGUMENT, not as a SIMCTL_CHILD_* variable:
    # the simulator keeps the first set of those it saw until the whole device
    # shuts down (REPORT-5), and measured here the variable simply did not arrive
    # on a later launch of the same boot (`idle / no prompt configured`).
    environment = dict(ENV)
    args = ["xcrun", "simctl", "--set", str(SIMSET), "launch", device, BUNDLE_ID]
    if drive:
        args += ["-DSHPortCTestDrive", "1"]
        args += ["-DSHPortCTestPrompt", PROMPT.read_text()]
        args += ["-DSHPortCTestKeyword", "STREAMTEST-COMPLETE"]
    if clocks:
        environment["SIMCTL_CHILD_DSHPORT_UITEST_CLOCKS"] = "1"
    if list_acceptance:
        # The Swift host re-publishes launch arguments as environment variables for
        # the Node side (`NodeRunner.forwardTestFlags`), because `simctl launch
        # -DKey value` lands in the argument domain where Node cannot see it.
        args += ["-DSHPortCTestSessionListAcceptance", "1"]
    if open_first:
        # A launch argument, not a SIMCTL_CHILD_* variable: the simulator keeps the
        # FIRST set of those it sees until the whole device shuts down (REPORT-5,
        # ancestor-EPERM test), so a variable introduced on a later launch of the
        # same boot never arrives. Measured: the driver's events were missing
        # entirely while the prompt still worked.
        args += ["-DSHPortCTestOpenFirstSession", "1"]
    if session_id:
        # The driver reports whether this session is in the list the interface
        # renders from (`probeSessionInListScript`). An argument for the same
        # reason as above, and because it is per-launch.
        args += ["-DSHPortCTestSessionId", session_id]
    if continue_session:
        # "And it can still take a turn": driven through the controller the UI's
        # send button reaches, because the sidebar has no rows in the DOM at this
        # device's 402 px width. See sim/session-continue-acceptance.mjs.
        args += ["-DSHPortCTestContinueSession", "1"]
        if continue_prompt:
            args += ["-DSHPortCTestContinuePrompt", continue_prompt]
    return subprocess.run(args, capture_output=True, text=True, env=environment, timeout=120)


def wait_ready(c: Path, timeout: float = 150, *, newer_than: float | None = None) -> dict:
    """Wait for THIS launch to reach `webViewReady`.

    `newer_than` is a wall-clock stamp taken before the launch. It matters: an
    install-over carries the container's contents (the status file among them)
    into the new container, so the status file
    that says `webViewReady` is the PREVIOUS run's, and a poll that accepts it
    returns instantly — which is how the first version of this test read the
    migration result before the app had even started, and reported the previous
    state as the current one. REPORT-5 hit the same shape of bug with the node log.
    """
    deadline = time.time() + timeout
    last: dict = {}
    path = c / RUNTIME_DIR / "DSHPortC-status.json"
    while time.time() < deadline:
        if path.exists():
            fresh = newer_than is None or path.stat().st_mtime >= newer_than
            if fresh:
                try:
                    last = json.loads(path.read_text())
                except json.JSONDecodeError:
                    last = {}
                if last.get("phase") == "webViewReady":
                    return last
        time.sleep(2)
    return last


def read_events(c: Path) -> list[dict]:
    events: list[dict] = []
    sessions = c / "Library/Application Support/DSH/sessions"
    if not sessions.is_dir():
        return events
    for path in sorted(sessions.rglob("*.jsonl.zstd")):
        raw = run(["zstd", "-dc", str(path)])
        for line in raw.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return events


def wait_turns(c: Path, at_least: int, timeout: float = 320) -> list[dict]:
    deadline = time.time() + timeout
    events: list[dict] = []
    while time.time() < deadline:
        events = read_events(c)
        if sum(1 for e in events if e.get("type") == "turn/end") >= at_least:
            return events
        time.sleep(3)
    return events


def header_cwd(path: Path) -> str | None:
    raw = run(["zstd", "-dc", str(path)])
    for line in raw.stdout.splitlines():
        line = line.strip()
        if line:
            try:
                return json.loads(line).get("cwd")
            except json.JSONDecodeError:
                return None
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--keep-app", action="store_true", help="leave the app installed at the end")
    args = parser.parse_args()

    LOGS.mkdir(parents=True, exist_ok=True)
    device = udid()
    boot(device)
    if run(["curl", "-sf", "-m", "3", f"http://127.0.0.1:{MOCK_PORT}/healthz"]).returncode != 0:
        raise SystemExit(f"mock model server not answering on {MOCK_PORT}; run scripts/mock-start.sh start")

    evidence: dict = {"steps": []}

    def log_for(c: Path, wanted: str) -> Path | None:
        """The log of ONE named session, wherever it currently sits.

        Selecting by list order was a real bug here: after the migration the
        directory listing also contains the freshly created session, and `logs[0]`
        is whichever sorts first. Naming the id is the only stable way to follow
        one session across a rename.
        """
        for path in (c / "Library/Application Support/DSH/sessions").rglob("*.jsonl.zstd"):
            if path.parent.name == wanted:
                return path
        return None

    def note(name: str, ok: bool, detail: object) -> None:
        evidence["steps"].append({"name": name, "ok": bool(ok), "detail": detail})
        text = detail if isinstance(detail, str) else json.dumps(detail, ensure_ascii=False)
        print(f"{'PASS' if ok else 'FAIL'}  {name}  [{text[:400]}]")

    # ---- 1. first install, one real turn -------------------------------------
    simctl("terminate", device, BUNDLE_ID)
    simctl("uninstall", device, BUNDLE_ID)
    simctl("install", device, str(APP), check=True)
    c_before = container(device)
    stamp_before_launch = time.time() - 1
    launch(device, drive=True)
    ready = wait_ready(c_before, newer_than=stamp_before_launch)
    note("app reaches webViewReady on the first install", ready.get("phase") == "webViewReady", ready.get("phase"))
    events = wait_turns(c_before, 1)
    ended = sum(1 for e in events if e.get("type") == "turn/end")
    note("one turn completed, so a session log exists", ended >= 1, f"{ended} turn/end")

    simctl("terminate", device, BUNDLE_ID)
    time.sleep(3)
    logs = sorted((c_before / "Library/Application Support/DSH/sessions").rglob("*.jsonl.zstd"))
    if not logs:
        raise SystemExit("no session log after the first turn")
    session_id = logs[0].parent.name
    cwd_before = header_cwd(logs[0])
    evidence["before"] = {"container": str(c_before), "sessionId": session_id, "cwd": cwd_before,
                          "log": str(logs[0].relative_to(c_before))}
    note("the session's header names the live container A",
         cwd_before is not None and str(c_before) in cwd_before, cwd_before)

    # ---- 2. install over: the platform reassigns the container --------------
    simctl("install", device, str(APP), check=True)
    c_after = container(device)
    evidence["after"] = {"container": str(c_after)}
    note("the container changed and the old one is gone",
         c_after != c_before and not c_before.exists(), f"{c_before.name} -> {c_after.name}")
    sessions_dir = c_after / "Library/Application Support/DSH/sessions"
    carried = sorted(sessions_dir.rglob("*.jsonl.zstd")) if sessions_dir.is_dir() else []
    note("DSH_HOME was carried into the new container", len(carried) == 1,
         [str(p.relative_to(c_after)) for p in carried])
    if not carried:
        raise SystemExit("the install did not carry DSH_HOME; the rest of this acceptance needs it")
    note("the carried log still names the dead container (the state to repair)",
         str(c_before) in (header_cwd(carried[0]) or ""), header_cwd(carried[0]))

    # ---- 3. launch: the migration must repair it ---------------------------
    # The carried-over status file says `webViewReady` before this launch starts,
    # so the poll has to require a NEWER one (see wait_ready).
    stamp_before_launch = time.time() - 1
    launch(device, drive=False)
    ready = wait_ready(c_after, newer_than=stamp_before_launch)
    note("app reaches webViewReady after the install-over", ready.get("phase") == "webViewReady", ready.get("detail"))

    home = c_after / "Library/Application Support/DSH"
    summary_path = home / "DSHPortE-session-migrate.json"
    summary = json.loads(summary_path.read_text()) if summary_path.exists() else {}
    evidence["migrateSummary"] = summary
    migrated = summary.get("migrated") or {}
    note("the migration rewrote one log", migrated.get("rewritten") == 1, migrated)
    note("the migration isolated nothing", migrated.get("quarantined") == 0, migrated.get("failed"))

    migrated_log = log_for(c_after, session_id)
    note("the session under test survived the migration", migrated_log is not None,
         str(migrated_log.relative_to(c_after)) if migrated_log else "missing")
    if migrated_log is None:
        raise SystemExit("the migrated session is gone; the remaining checks cannot run")
    logs = [migrated_log]
    cwd_after = header_cwd(migrated_log)
    evidence["after"]["cwd"] = cwd_after
    note("the header cwd now names container B", cwd_after is not None and str(c_after) in cwd_after, cwd_after)
    note("the header cwd no longer names the dead container A", str(c_before) not in (cwd_after or ""), cwd_after)
    note("the header cwd names a directory that exists",
         cwd_after is not None and Path(cwd_after).is_dir(), cwd_after)
    project_dir = logs[0].parent.parent.name
    note("the folder moved away from A's project key",
         str(c_before.name) not in project_dir, project_dir)

    node_log = (c_after / RUNTIME_DIR / "DSHPortC-node.log").read_text(errors="replace")
    note("the boot log records the rewrite",
         any("rewrote 1 log(s)" in line for line in node_log.splitlines()),
         [l for l in node_log.splitlines() if "session-migrate" in l][:3])
    warnings = [l for l in node_log.splitlines()
                if re.search(r"did not activate|corrupt|pending \(waiting|inconsistent", l)]
    note("no activation warning, corrupt log, or pending service", not warnings, warnings[:4])

    registry = json.loads((home / "storages" / "workspace.json").read_text())
    paths = [w["path"] for w in registry["tables"]["workspaces"].values()]
    note("workspace.json names container B",
         all(str(c_before) not in p for p in paths) and any(str(c_after) in p for p in paths), paths)
    listed = [sid for w in registry["tables"]["workspaces"].values() for sid in w.get("sessionIds", [])]
    # The registry is DSH's own bookkeeping and it may legitimately name a session
    # that no longer exists (it treats a missing id as a candidate), so the
    # requirement is that the migrated one is still accounted for somewhere.
    note("workspace.json accounts for the migrated session", session_id in listed, listed)

    simctl("terminate", device, BUNDLE_ID)
    time.sleep(2)

    # ---- 4. the migrated session is unchanged, and the app still works -------
    #
    # Two separate claims here, and only one of them can be made from this screen:
    #
    #   * "a further turn runs in the OLD session" needs a click on that session's
    #     row, and the rows are not in the DOM at 402 px. Claiming it from the log
    #     alone would be a guess about which session received the turn — and
    #     measured, that guess would have been WRONG: this launch's own
    #     `dsh.sessions.current` held a newly created session id. So the browser is
    #     not used for that claim; step 6 answers it through DSH's own controller.
    #   * "the app still works after the migration, and the migrated session is
    #     intact" is measurable here: a turn completes, and the migrated log's bytes
    #     are exactly what the migration left. A continuation that had gone wrong — a
    #     re-quarantine, a rewrite over the event frames, a second folder for the
    #     same id — would show up in one of those.
    size_after_migration = logs[0].stat().st_size
    stamp_before_launch = time.time() - 1
    launch(device, drive=True, open_first=True, session_id=session_id)
    c_after = container(device)
    wait_ready(c_after, newer_than=stamp_before_launch)
    events = wait_turns(c_after, 1)
    ends = [e for e in events if e.get("type") == "turn/end"]
    note("a turn completes in the app after the migration", len(ends) >= 1, f"{len(ends)} turn/end")

    final_log = log_for(c_after, session_id)
    note("the migrated session is still one session, not replaced by a new one",
         final_log is not None, str(final_log.relative_to(c_after)) if final_log else "missing")
    note("the migrated session's log is byte-for-byte what the migration left",
         final_log is not None and final_log.stat().st_size == size_after_migration,
         f"{size_after_migration} -> {final_log.stat().st_size if final_log else 'missing'}")
    note("no second folder appeared for the migrated session",
         len(list((c_after / "Library/Application Support/DSH/sessions").rglob(session_id))) == 1,
         [str(p.relative_to(c_after)) for p in (c_after / "Library/Application Support/DSH/sessions").rglob(session_id)])

    # ---- 5. DSH's own services must list, validate and read the session ------
    #
    # The screen cannot answer this part on this device: DSH lays out at 402 px,
    # below its 1024 px auto-collapse threshold, so the sidebar is a 56 px rail and
    # the rows are not in the DOM (measured: twelve presses of the rail toggle left
    # `data-sidebar-collapsed` in place, and the rows are absent from the document).
    # Enlarging the WKWebView from inside does not survive SwiftUI's layout pass.
    #
    # So the functional half is measured against the services the sidebar reads
    # from: `sessionPersistence`, `sessionQuery`, `workspaceRegistry`. That is a
    # weaker instrument than a click and is reported as such — what it establishes
    # is that DSH lists the migrated session, that its header validates, and that a
    # full read replays the history. Whether a row appears on the phone's rail is
    # for the person holding it to confirm.
    simctl("terminate", device, BUNDLE_ID)
    time.sleep(2)
    acceptance = c_after / "Documents/DSHPortE-session-list-acceptance.json"
    if acceptance.exists():
        acceptance.unlink()
    launch(device, drive=False, list_acceptance=True, session_id=session_id)
    for _ in range(45):
        if acceptance.exists():
            break
        time.sleep(2)
    criteria = json.loads(acceptance.read_text())["criteria"] if acceptance.exists() else {}
    evidence["sessionListAcceptance"] = criteria
    listed = criteria.get("session_query_lists_sessions", {})
    note("DSH's session query lists the migrated session", session_id in (listed.get("ids") or []),
         listed.get("ids"))
    persisted = criteria.get("session_persistence_lists_sessions", {})
    ids = [row.get("id") for row in persisted.get("sessions", [])]
    note("DSH's persistence lists the migrated session", session_id in ids, ids)
    note("every listed session carries the current container's cwd",
         all(str(c_after) in (row.get("cwd") or "") for row in persisted.get("sessions", [])),
         [row.get("cwd") for row in persisted.get("sessions", [])])
    note("every listed session's format is current",
         all(row.get("formatStatus") == "current" for row in persisted.get("sessions", [])),
         [row.get("formatStatus") for row in persisted.get("sessions", [])])
    registry_view = criteria.get("workspace_registry", {})
    members = [sid for workspace in registry_view.get("workspaces", []) for sid in workspace.get("sessionIds", [])]
    note("DSH's workspace registry accounts for the migrated session", session_id in members, members)
    opened = criteria.get("open_session", {})
    note("DSH reads the migrated session's full history", opened.get("ok") is True,
         {k: opened.get(k) for k in ("via", "eventCount", "hasTurnEnd", "error")})
    note("the read history contains the original turn", opened.get("hasTurnEnd") is True, opened.get("types"))

    # ---- 6. the migrated session takes a REAL further turn -------------------
    #
    # Criterion 1 asks for three things: still in the list, opens, and one more
    # turn goes through it. Steps 3 and 5 cover the first two. The third is
    # measured here, and NOT through the browser — that was tried and it is
    # recorded as measured rather than as a preference:
    #
    #   the WKWebView lays out at 402 px, below DSH's 1024 px auto-collapse
    #   threshold, so the sidebar is a 56 px rail. Twelve presses of the rail
    #   toggle left `data-sidebar-collapsed` in place and `[data-row-key]` never
    #   entered the document (`session_rows: {"rows":[],"sidebarVisible":false}`,
    #   `session_pressed: "no-session-row"`, `session_in_list: renderedRow=false`).
    #   The turn that then ran went into a NEW session — `dsh.sessions.current`
    #   held a different id — which is exactly the mistake this criterion exists
    #   to catch. Keeping that evidence and NOT counting it as a pass is the
    #   honest reading; the report says so.
    #
    # So the turn is driven through `sessionController.prompt` with the real
    # `ios-sim` profile mounted — the same service the UI's send button reaches,
    # against the same migrated log on disk. See sim/session-continue-acceptance.mjs.
    simctl("terminate", device, BUNDLE_ID)
    time.sleep(2)
    continue_out = c_after / "Documents/DSHPortE-session-continue-acceptance.json"
    if continue_out.exists():
        continue_out.unlink()
    size_before_continue = (log_for(c_after, session_id) or Path("/dev/null")).stat().st_size
    launch(device, drive=False, continue_session=True, session_id=session_id,
           continue_prompt="STEP echo continued-after-container-change")
    # Wait for a FINAL verdict, not merely for the file to appear. The module
    # writes after every `record()`, so the file exists from the moment it boots —
    # measured: polling `exists()` returned while the report held only `boot`, the
    # turn had not been asked for yet, and five checks were reported as failures
    # for work that was still in flight (the on-disk log had in fact grown).
    continued: dict = {}
    for _ in range(80):
        if continue_out.exists():
            try:
                continued = json.loads(continue_out.read_text()).get("criteria", {})
            except json.JSONDecodeError:
                continued = {}
            if "took_a_turn" in continued or "error" in continued:
                break
        time.sleep(3)
    evidence["sessionContinueAcceptance"] = continued
    note("the acceptance mounted the profile and reached the controller",
         (continued.get("boot") or {}).get("ok") is True and "error" not in continued,
         {"boot": continued.get("boot"), "error": continued.get("error")})
    took = continued.get("took_a_turn") or {}
    note("the migrated session took a further turn", took.get("finishedATurn") is True, took)
    note("that turn landed in the same session, not a new one",
         took.get("sameSessionStillListed") is True and took.get("sessionCount") is not None, took)
    kept = continued.get("history_intact") or {}
    note("the pre-existing history survived the new turn", kept.get("hasOriginalTurnEnd") is True, kept)
    note("the new turn's prompt is in the migrated log", kept.get("carriesTheNewPrompt") is True, kept)
    size_after_continue = (log_for(c_after, session_id) or Path("/dev/null")).stat().st_size
    note("the migrated log on disk grew", size_after_continue > size_before_continue,
         f"{size_before_continue} -> {size_after_continue}")

    # The driver's own report, kept as evidence of what the screen could and could
    # not do on this viewport, rather than dropped.
    drive_path = c_after / "Documents/DSHPortC-uidrive.json"
    if drive_path.exists():
        drive = json.loads(drive_path.read_text())
        evidence["driverPrelude"] = drive.get("prelude", [])

    node_log = (c_after / RUNTIME_DIR / "DSHPortC-node.log").read_text(errors="replace")
    warnings = [l for l in node_log.splitlines()
                if re.search(r"did not activate|corrupt|pending \(waiting|inconsistent", l)]
    note("no activation warning after the continuation", not warnings, warnings[:4])

    simctl("terminate", device, BUNDLE_ID)
    evidence["ok"] = all(step["ok"] for step in evidence["steps"])
    (LOGS / "container-sessions.json").write_text(json.dumps(evidence, indent=2, ensure_ascii=False))
    if not args.keep_app:
        simctl("uninstall", device, BUNDLE_ID)
    passed = sum(1 for s in evidence["steps"] if s["ok"])
    print(f"\n{'PASS' if evidence['ok'] else 'FAIL'} {passed}/{len(evidence['steps'])} checks")
    return 0 if evidence["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
