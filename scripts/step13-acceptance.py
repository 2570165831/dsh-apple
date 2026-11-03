#!/usr/bin/env python3
"""Step 13 acceptance: does a running turn keep running while the app is hidden?

WHAT THIS MEASURES, AND WHY IT IS MEASURED THIS WAY
----------------------------------------------------
The claim under test is narrow and has three separate parts, which is why the run
records three separate things rather than one verdict:

  1. THE TURN KEEPS PROGRESSING WHILE BACKGROUNDED. Evidence is the turn's own
     durable event log: `tool/call` and `tool/result` events carry timestamps, so
     a tool that started before backgrounding and finished after it proves work
     continued. Wall-clock alone would not: the app could be resumed, then finish
     instantly, and look identical.

  2. THE APP ASKS iOS FOR CONTINUATION, AND ONLY WHEN THERE IS WORK. Evidence is
     the app's own boot log and status file: the submission line, the identifier,
     and the outcome. An idle background transition must produce NO submission.

  3. THE TURN SURVIVES A RECLAIM. The system can take the task back at any time,
     and the acceptance has to show the app comes back usable rather than dead.
     Since `expirationHandler` cannot be triggered on demand from outside, the
     harness uses the closest honest instrument available and says so.

WHAT THE SIMULATOR CAN AND CANNOT DO (measured, not assumed)
------------------------------------------------------------
Apple's own documentation for `BGTaskScheduler.Error.Code.unavailable` lists "the
app runs on Simulator which doesn't support background processing" as one of the
three reasons that error is returned. So on the simulator the submission is
EXPECTED to fail, and the run records the actual error rather than pretending the
mechanism worked. That is why:

  * the submission path is verified as "it ran, and here is exactly what iOS
    answered" — not as "it succeeded";
  * the continuation itself is verified through its EFFECT (the turn progressed
    while hidden), which is measurable on the simulator because iOS does not
    suspend a simulator app the way it suspends a device app;
  * the parts that can only be answered on a real device are named in the report
    rather than filled in with a guess.

The baseline arm exists precisely because of the above: without it, "the turn
finished after 90 s in the background" could mean the feature works OR that the
simulator never suspends anything. Running the same measurement against a build
with the step-13 code removed is what makes the difference attributable.

Usage
    DSHPORTE_DEVICE=phone-bg MOCK_PORT=19713 scripts/step13-acceptance.py run \
        [--arm impl|baseline] [--name NAME] [--away SECONDS]

    DSHPORTE_DEVICE=phone-bg MOCK_PORT=19713 scripts/step13-acceptance.py idle \
        [--name NAME]

Exit status is 0 only if every criterion of the selected arm passed.
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
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOGS = ROOT / "logs" / "step13"
BUNDLE_ID = "local.dshportc.app"
APP_PATH = ROOT / "DerivedData/Build/Products/Debug-iphonesimulator/DSHPortC.app"
BASELINE_APP = LOGS / "baseline" / "DSHPortC-baseline.app"
SIMSET = ROOT / "simdevices"
ENV = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}
MOCK_PORT = int(os.environ.get("MOCK_PORT", "19713"))
# The three files the app writes for observability live under Library/Application
# Support, not Documents, so they stay out of the Files app.
RUNTIME_DIR = "Library/Application Support/DSHPortC"

sys.path.insert(0, str(Path(__file__).resolve().parent))
import device_pick  # noqa: E402


def simctl(*args, check=False, timeout=240):
    return subprocess.run(["xcrun", "simctl", "--set", str(SIMSET), *args],
                          capture_output=True, text=True, env=ENV, check=check, timeout=timeout)


def host(args, *, check=False, timeout=240):
    return subprocess.run(args, capture_output=True, text=True, env=ENV, check=check, timeout=timeout)


def container(udid: str) -> Path:
    return Path(simctl("get_app_container", udid, BUNDLE_ID, "data", check=True).stdout.strip())


def read_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def read_text(path: Path) -> str:
    try:
        return path.read_text(errors="replace")
    except OSError:
        return ""


def session_events(data: Path) -> list[dict]:
    """Every durable event of every session, oldest first, with its seq and time."""
    events: list[dict] = []
    sessions = data / "Library/Application Support/DSH/sessions"
    if not sessions.is_dir():
        return events
    for path in sorted(sessions.rglob("*.jsonl.zstd")):
        raw = host(["zstd", "-dc", str(path)]).stdout
        for line in raw.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return events


def wait_web_ready(data_dir: Path, timeout: float = 300) -> Path:
    """Wait for the app's own ready phase; return the CURRENT data container.

    The container path is not stable across installs (REPORT-4B, REPORT-10): the
    simulator hands the app a new Data/Application/UUID each time it reinstalls.
    Holding one Path across an install reads a directory that no longer describes
    the running app.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        status = read_json(data_dir / RUNTIME_DIR / "DSHPortC-status.json")
        if status.get("phase") == "webViewReady":
            return data_dir
        if status.get("phase") == "failed":
            raise SystemExit(f"the app reported failure: {status.get('error')}")
        time.sleep(0.4)
    raise SystemExit("the web view never became ready")


def mock_health() -> bool:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{MOCK_PORT}/healthz", timeout=3):
            return True
    except OSError:
        return False


def launch(udid: str, app: Path, *, prompt: str, keyword: str, extra: list[str] | None = None) -> None:
    """Install `app`, then launch it with the test driver pointed at one prompt."""
    simctl("terminate", udid, BUNDLE_ID)
    simctl("uninstall", udid, BUNDLE_ID)
    simctl("install", udid, str(app), check=True)

    env = dict(ENV)
    env["SIMCTL_CHILD_DSHPORT_UITEST_PROMPT"] = prompt
    env["SIMCTL_CHILD_DSHPORT_UITEST_KEYWORD"] = keyword
    args = [
        "xcrun", "simctl", "--set", str(SIMSET), "launch", udid, BUNDLE_ID,
        "-DSHPortCTestDrive", "1",
        "-DSHPortCMockPort", str(MOCK_PORT),
    ] + (extra or [])
    subprocess.run(args, capture_output=True, text=True, env=env, timeout=240, check=True)


def background(udid: str) -> None:
    """Hand focus to another app.

    `simctl` has no "press home" verb. Opening an unrelated URL gives the scene to
    another app, which is a real backgrounding as far as `didEnterBackground` is
    concerned — and the run requires that notification to appear, so a transition
    that did not happen fails rather than passing silently.
    """
    simctl("openurl", udid, "https://example.com")


def foreground(udid: str) -> None:
    """Bring the app back WITHOUT restarting it.

    `simctl launch` on a backgrounded app brings it forward and does not start a
    new process (REPORT-10 measured this). That matters: a relaunch would restart
    Node and make "the turn continued" untestable.
    """
    subprocess.run(
        ["xcrun", "simctl", "--set", str(SIMSET), "launch", udid, BUNDLE_ID,
         "-DSHPortCMockPort", str(MOCK_PORT)],
        capture_output=True, text=True, env=ENV, timeout=240,
    )


def turn_ends(events: list[dict]) -> list[dict]:
    return [e for e in events if e.get("type") == "turn/end"]


def tool_timeline(events: list[dict]) -> list[dict]:
    """Pair each `tool/call` with the `tool/result` that answered it, with times.

    The interesting quantity is `gapSeconds`: the wall clock between a call being
    recorded and its result being recorded. For a long command that spans a
    backgrounding, a gap that covers the whole background window is the proof that
    the command kept running rather than being resumed and finished instantly.
    """
    calls: dict[str, dict] = {}
    out: list[dict] = []
    for event in events:
        data = event.get("data") or {}
        kind = event.get("type")
        if kind == "tool/call":
            calls[data.get("callId")] = {
                "name": data.get("name"),
                "arguments": data.get("arguments"),
                "callSeq": event.get("seq"),
                "callTime": event.get("time"),
            }
        elif kind == "tool/result":
            message = data.get("message") or {}
            call_id = message.get("toolCallId") or data.get("toolCallId")
            call = calls.get(call_id, {})
            call_time = call.get("callTime")
            result_time = event.get("time")
            gap = None
            if isinstance(call_time, (int, float)) and isinstance(result_time, (int, float)):
                gap = round((result_time - call_time) / 1000.0, 2)
            content = message.get("content") or []
            text = "".join(b.get("text", "") for b in content if b.get("type") == "text")
            out.append({
                "callId": call_id,
                "name": call.get("name"),
                "arguments": call.get("arguments"),
                "isError": message.get("isError"),
                "closeToCallSeconds": gap,
                "resultSeq": event.get("seq"),
                "text": text[:1500],
            })
    return out


def background_lines(node_log: str) -> list[str]:
    return [line for line in node_log.splitlines() if "dshportc: bg " in line]


def run_arm(args: argparse.Namespace) -> int:
    LOGS.mkdir(parents=True, exist_ok=True)
    udid = device_pick.device_udid(create_phone=False)
    device_pick.boot(udid)

    if not mock_health():
        raise SystemExit(f"the mock model server is not answering on {MOCK_PORT}; "
                         f"run MOCK_PORT={MOCK_PORT} scripts/mock-start.sh start")

    app = BASELINE_APP if args.arm == "baseline" else APP_PATH
    if not app.is_dir():
        raise SystemExit(f"no app bundle at {app}")
    prompt = (ROOT / "prompts" / "19-step13-bg-turn.txt").read_text()
    keyword = "bg-loop-done"

    # A marker the second step's md5sum hashes, so the result text is checkable.
    marker = (LOGS / "bg-13-marker.txt")
    marker.parent.mkdir(parents=True, exist_ok=True)
    marker.write_text(f"step13 {args.arm}\n")

    started = time.time()
    launch(udid, app, prompt=prompt, keyword=keyword)
    data_dir = container(udid)
    data_dir = wait_web_ready(data_dir)

    # Wait until the FIRST tool call is recorded, so the backgrounding happens
    # while a command is genuinely in flight. Backgrounding before the turn starts
    # would test nothing.
    deadline = time.time() + 240
    first_call = None
    while time.time() < deadline:
        events = session_events(data_dir)
        calls = [e for e in events if e.get("type") == "tool/call"]
        if calls:
            first_call = calls[0]
            break
        time.sleep(1.0)
    if first_call is None:
        raise SystemExit("the turn never produced a tool call; the mock or the driver is not working")

    in_flight_at = time.time()
    background(udid)
    print(f"[{args.arm}] backgrounded while tool 1 is in flight, staying away {args.away:.0f}s")

    # Sample the turn's progress WHILE hidden.
    #
    # WHAT THIS CAN AND CANNOT SHOW. A `tool/call` is only recorded when the call
    # is appended, and a long command's result is appended when it finishes — so
    # a single in-flight command produces NO new durable event while it runs, no
    # matter how healthy the process is. Counting events during the window would
    # therefore report "no progress" for a turn that was progressing fine, which
    # is exactly the kind of measurement mistake this project keeps paying for.
    #
    # The honest instrument is the command's OWN output. The scripted command
    # prints an epoch timestamp every few seconds; the ones that appear in the
    # final result text were printed while the app was hidden. That is a direct
    # observation of work happening during the window, not an inference from
    # event counts.
    #
    # Event counts are still sampled, because they answer a different question:
    # whether the turn advanced to a NEW step while hidden (which would show up as
    # a second tool/call). Both are recorded.
    mid_samples: list[dict] = []
    window_end = time.time() + args.away
    while time.time() < window_end:
        time.sleep(min(10.0, max(1.0, window_end - time.time())))
        events = session_events(data_dir)
        mid_samples.append({
            "atSeconds": round(time.time() - in_flight_at, 1),
            "events": len(events),
            "tools": len([e for e in events if e.get("type") == "tool/call"]),
            "results": len([e for e in events if e.get("type") == "tool/result"]),
            "turnEnds": len(turn_ends(events)),
        })

    resumed_at = time.time()
    foreground(udid)
    print(f"[{args.arm}] back after {args.away:.0f}s away")

    # Wait for the turn to finish after returning, or note that it already had.
    deadline = time.time() + 360
    while time.time() < deadline:
        events = session_events(data_dir)
        if turn_ends(events):
            break
        time.sleep(2.0)

    data_dir = container(udid)
    events = session_events(data_dir)
    ends = turn_ends(events)
    timeline = tool_timeline(events)
    status = read_json(data_dir / RUNTIME_DIR / "DSHPortC-status.json")
    node_log = read_text(data_dir / RUNTIME_DIR / "DSHPortC-node.log")
    bg = status.get("background") or {}

    # ---------------------------------------------------------------- the proof
    #
    # The scripted command prints `bg-step-<n> <epoch>` every few seconds. Any
    # such line whose epoch falls INSIDE the hidden window was printed by a
    # process that was still running while the app was hidden. That is the
    # measurement; everything else in this file is bookkeeping.
    hidden_window = (in_flight_at, resumed_at)
    stamped: list[dict] = []
    for item in timeline:
        for match in re.finditer(r"bg-step-(\d+)\s+(\d{9,})", item.get("text") or ""):
            epoch = int(match.group(2))
            stamped.append({
                "step": int(match.group(1)),
                "epoch": epoch,
                "duringHiddenWindow": hidden_window[0] <= epoch <= hidden_window[1],
                "toolCallId": item.get("callId"),
            })
    stamped.sort(key=lambda entry: entry["epoch"])
    during = [s for s in stamped if s["duringHiddenWindow"]]

    # A STAMP INSIDE THE WINDOW IS NOT ENOUGH. The command prints one every 7 s,
    # so a run that was suspended 28 s after backgrounding still has several
    # stamps inside a 180 s window — the ones from before the suspension. Scoring
    # that as "kept working" is the measurement mistake this file exists to avoid.
    #
    # What actually distinguishes "continued" from "suspended" is a HOLE: a gap
    # between consecutive stamps that is much longer than the command's own
    # interval. The interval is 7 s, so a hole wider than 20 s is not the command
    # being slow, it is the process not running.
    stamps_sorted = sorted(stamped, key=lambda entry: entry["epoch"])
    holes: list[dict] = []
    for before, after in zip(stamps_sorted, stamps_sorted[1:]):
        gap = after["epoch"] - before["epoch"]
        if gap > 20:
            holes.append({
                "fromStep": before["step"],
                "toStep": after["step"],
                "seconds": gap,
                "holeStartsSecondsAfterBackgrounding": round(before["epoch"] - hidden_window[0], 1),
                "holeEndsSecondsAfterBackgrounding": round(after["epoch"] - hidden_window[0], 1),
            })

    suspension_hole_seconds = max((h["seconds"] for h in holes), default=0)
    # The measure that matters: how long after backgrounding the process stopped,
    # and how long the stop lasted. `None` when there was no hole at all.
    stopped_after = holes[0]["holeStartsSecondsAfterBackgrounding"] if holes else None

    progressed_hidden = len(during) > 0 and suspension_hole_seconds == 0

    # A second, independent signal: did a NEW tool call get appended while hidden?
    # Same caveat as above (a long command blocks its own result), so this is
    # recorded as supporting evidence rather than as the primary criterion.
    first_sample = mid_samples[0] if mid_samples else {}
    last_sample = mid_samples[-1] if mid_samples else {}
    advanced_while_hidden = bool(
        mid_samples and (
            last_sample.get("tools", 0) > first_sample.get("tools", 0)
            or last_sample.get("turnEnds", 0) > first_sample.get("turnEnds", 0)
        )
    )

    result = {
        "arm": args.arm,
        "device": device_pick.name(),
        "udid": udid,
        "app": str(app),
        "mockPort": MOCK_PORT,
        "prompt": prompt,
        "keyword": keyword,
        "awaySeconds": args.away,
        "startedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(started)),
        "containerAfter": data_dir.name,
        "turnCompleted": len(ends) > 0,
        "turnEnds": len(ends),
        "toolCalls": timeline,
        "toolCallCount": len(timeline),
        "hiddenSamples": mid_samples,
        "hiddenWindowEpoch": [round(hidden_window[0], 3), round(hidden_window[1], 3)],
        "stampedLines": stamped,
        "stampedDuringHiddenWindow": during,
        "holes": holes,
        "longestHoleSeconds": suspension_hole_seconds,
        "suspendedAfterSeconds": stopped_after,
        "progressedWhileHidden": progressed_hidden,
        "advancedWhileHidden": advanced_while_hidden,
        "backgroundSection": bg,
        "backgroundLogLines": background_lines(node_log),
        "nodeLogTail": node_log.splitlines()[-40:],
        "status": {
            "phase": status.get("phase"),
            "detail": status.get("detail"),
            "webURL": status.get("webURL"),
        },
    }

    out = LOGS / f"{args.name}.json"
    out.write_text(json.dumps(result, indent=2, ensure_ascii=False))
    shutil.copy(LOGS / "bg-13-marker.txt", LOGS / f"{args.name}-marker.txt")

    print(json.dumps({
        "arm": args.arm,
        "turnCompleted": result["turnCompleted"],
        "toolCallCount": result["toolCallCount"],
        "progressedWhileHidden": progressed_hidden,
        "stampedDuringHiddenWindow": len(during),
        "longestHoleSeconds": suspension_hole_seconds,
        "suspendedAfterSeconds": stopped_after,
        "holes": holes,
        "advancedWhileHidden": advanced_while_hidden,
        "background": bg,
        "backgroundLogLines": result["backgroundLogLines"],
        "out": str(out),
    }, indent=2, ensure_ascii=False))

    # Criteria, stated per arm. The baseline arm is EXPECTED to fail the
    # progression criterion — that is the point of running it — so it is scored by
    # "it behaved as the unmodified build does", not by passing the impl test.
    gaps = [t["closeToCallSeconds"] for t in timeline if t["closeToCallSeconds"] is not None]
    long_gap = max(gaps) if gaps else 0.0

    if args.arm == "impl":
        ok_turn = len(ends) > 0
        ok_tools = len(timeline) >= 2
        print(f"== criteria: turn completed={ok_turn} both tools ran={ok_tools} "
              f"stamps inside the hidden window={len(during)} "
              f"longest suspension hole={suspension_hole_seconds}s "
              f"(process stopped {stopped_after}s after backgrounding) "
              f"advanced to a new step while hidden={advanced_while_hidden} "
              f"longest tool gap={long_gap}s")
        ok = ok_turn and ok_tools
        if not ok:
            print("== FAIL（回合没有正常跑完）")
            return 1
        if progressed_hidden:
            print("== PASS（后台期间没有中断，命令持续输出）")
            return 0
        print("== 结果：回合完成了，但后台期间被挂起 "
              f"{suspension_hole_seconds}s（切后台后 {stopped_after}s 停住）")
        print("== 这不是本单代码失败：模拟器上 BGTaskScheduler 不可用，见报告第一节与第三节")
        return 2

    # baseline: report what it did, and require only that the measurement is valid
    # (the turn ran at all), not that the feature worked.
    print(f"== baseline criteria: turn completed={len(ends) > 0} "
          f"stamps inside the hidden window={len(during)} "
          f"longest suspension hole={suspension_hole_seconds}s "
          f"(process stopped {stopped_after}s after backgrounding) "
          f"advanced to a new step while hidden={advanced_while_hidden} "
          f"longest gap={long_gap}s")
    print("== BASELINE RECORDED")
    return 0 if timeline else 1


def run_reclaim(args: argparse.Namespace) -> int:
    """Reclaim the continuing task mid-turn and show the app comes back usable.

    WHAT IS AND IS NOT REAL HERE. The expiration is SIMULATED: iOS offers no way
    to make the system reclaim a task on demand, and on the simulator the
    scheduler is unavailable altogether. The simulated call goes through the same
    `handleExpiration()` the framework calls, so what it proves is that the
    cleanup path runs, does not crash, and leaves Node and the session working.
    It does NOT prove the system reaches that handler with a device's timing; the
    report names that as a device-only question.

    The proof of "usable afterwards" is a SECOND turn in the SAME session after
    the expiration, which is the same standard the earlier resume tests used.
    """
    LOGS.mkdir(parents=True, exist_ok=True)
    udid = device_pick.device_udid(create_phone=False)
    device_pick.boot(udid)
    if not mock_health():
        raise SystemExit(f"the mock is not answering on {MOCK_PORT}")

    prompt = (ROOT / "prompts" / "19-step13-bg-turn.txt").read_text()
    keyword = "second-step-marker"

    launch(udid, APP_PATH, prompt=prompt, keyword=keyword,
           extra=["-DSHPortESimulateExpiration", "20"])
    data_dir = container(udid)
    data_dir = wait_web_ready(data_dir)

    # Wait until a tool call is in flight, so the expiration lands mid-turn.
    deadline = time.time() + 240
    while time.time() < deadline:
        events = session_events(data_dir)
        if any(e.get("type") == "tool/call" for e in events):
            break
        time.sleep(1.0)

    background(udid)
    # The hook fires 20 s after launch regardless of backgrounding; sleep past it.
    time.sleep(args.away)
    data_dir = container(udid)
    status_while_hidden = read_json(data_dir / RUNTIME_DIR / "DSHPortC-status.json")
    foreground(udid)

    # After the expiration, the session must still take a turn.
    time.sleep(2)
    second_prompt = "STREAMTEST 回收之后还能用吗"
    env = dict(ENV)
    env["SIMCTL_CHILD_DSHPORT_UITEST_PROMPT"] = second_prompt
    env["SIMCTL_CHILD_DSHPORT_UITEST_KEYWORD"] = "MOCK 服务在线"
    subprocess.run(
        ["xcrun", "simctl", "--set", str(SIMSET), "launch", udid, BUNDLE_ID,
         "-DSHPortCTestDrive", "1", "-DSHPortCMockPort", str(MOCK_PORT)],
        capture_output=True, text=True, env=env, timeout=240,
    )
    after_launch = time.time()
    deadline = time.time() + 300
    second_turn = False
    while time.time() < deadline:
        events = session_events(data_dir)
        fresh = [e for e in turn_ends(events)
                 if (e.get("time", 0) / 1000.0) >= after_launch]
        if fresh:
            second_turn = True
            break
        time.sleep(2.0)

    data_dir = container(udid)
    status = read_json(data_dir / RUNTIME_DIR / "DSHPortC-status.json")
    node_log = read_text(data_dir / RUNTIME_DIR / "DSHPortC-node.log")
    bg = status.get("background") or {}
    lines = background_lines(node_log)
    events = session_events(data_dir)

    result = {
        "arm": "reclaim",
        "device": device_pick.name(),
        "mockPort": MOCK_PORT,
        "simulatedExpiration": True,
        "backgroundSection": bg,
        "backgroundLogLines": lines,
        "expirationObserved": any("EXPIRED" in line for line in lines),
        "expirations": bg.get("expirations", 0),
        "appStillRunning": status.get("phase") == "webViewReady",
        "secondTurnCompleted": second_turn,
        "turnEnds": len(turn_ends(events)),
        "statusWhileHidden": status_while_hidden.get("background"),
        "nodeLogTail": node_log.splitlines()[-15:],
    }
    out = LOGS / f"{args.name}.json"
    out.write_text(json.dumps(result, indent=2, ensure_ascii=False))
    print(json.dumps({k: v for k, v in result.items() if k != "nodeLogTail"},
                     indent=2, ensure_ascii=False))

    ok = result["expirationObserved"] and result["appStillRunning"] and second_turn
    print("== PASS（收回路径走到了，App 没死，同一会话还能再发一轮）" if ok
          else "== FAIL（收回后不可用）")
    return 0 if ok else 1


def run_idle(args: argparse.Namespace) -> int:
    """Background the app with NO turn running; nothing should be submitted."""
    LOGS.mkdir(parents=True, exist_ok=True)
    udid = device_pick.device_udid(create_phone=False)
    device_pick.boot(udid)
    if not mock_health():
        raise SystemExit(f"the mock is not answering on {MOCK_PORT}")

    simctl("terminate", udid, BUNDLE_ID)
    simctl("uninstall", udid, BUNDLE_ID)
    simctl("install", udid, str(APP_PATH), check=True)
    # No prompt at all: the app boots to the idle UI and starts no turn.
    subprocess.run(
        ["xcrun", "simctl", "--set", str(SIMSET), "launch", udid, BUNDLE_ID,
         "-DSHPortCMockPort", str(MOCK_PORT)],
        capture_output=True, text=True, env=ENV, timeout=240,
    )
    data_dir = container(udid)
    data_dir = wait_web_ready(data_dir)
    time.sleep(3)

    background(udid)
    time.sleep(12)
    data_dir = container(udid)
    status = read_json(data_dir / RUNTIME_DIR / "DSHPortC-status.json")
    node_log = read_text(data_dir / RUNTIME_DIR / "DSHPortC-node.log")
    bg = status.get("background") or {}
    lines = background_lines(node_log)

    result = {
        "arm": "idle",
        "device": device_pick.name(),
        "mockPort": MOCK_PORT,
        "backgroundSection": bg,
        "backgroundLogLines": lines,
        "submissions": bg.get("submissions", 0),
        "busy": bg.get("busy"),
        # `"submitted" in line` would also match "no … request was submitted",
        # which is the sentence that proves the OPPOSITE. Match the submission
        # line's own shape instead.
        "submitted": any("bg submitted " in line for line in lines),
        "declinedReason": next(
            (line.split("bg ", 1)[1] for line in lines if "request was submitted" in line), ""),
    }
    out = LOGS / f"{args.name}.json"
    out.write_text(json.dumps(result, indent=2, ensure_ascii=False))
    print(json.dumps(result, indent=2, ensure_ascii=False))
    ok = result["submissions"] == 0 and not result["submitted"]
    print("== PASS（空闲时没有申请）" if ok else "== FAIL（空闲时不该申请）")
    return 0 if ok else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    run_parser = sub.add_parser("run", help="one turn, backgrounded mid-flight")
    run_parser.add_argument("--arm", choices=("impl", "baseline"), default="impl")
    run_parser.add_argument("--name", default="")
    run_parser.add_argument("--away", type=float, default=60.0)
    run_parser.set_defaults(func=run_arm)

    idle_parser = sub.add_parser("idle", help="background with nothing running")
    idle_parser.add_argument("--name", default="idle")
    idle_parser.set_defaults(func=run_idle)

    reclaim_parser = sub.add_parser("reclaim", help="simulate a system reclaim mid-turn")
    reclaim_parser.add_argument("--name", default="reclaim")
    reclaim_parser.add_argument("--away", type=float, default=30.0)
    reclaim_parser.set_defaults(func=run_reclaim)

    args = parser.parse_args()
    if getattr(args, "name", "") == "":
        args.name = f"{args.arm}-away{int(args.away)}"
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
