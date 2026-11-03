#!/usr/bin/env python3
"""Drive one scripted agent turn through the real app and keep the evidence.

This is the harness the task asks for: a real `bash` tool call, made by a real
agent turn in the real app, with the local mock model server standing in for a
provider so no credential is involved. Everything it asserts is something the
model would have seen — it reads the session's own durable event log, which is
what the app wrote, not a paraphrase.

Usage
    scripts/agent-turn.py run --prompt-file FILE --keyword TEXT --name NAME
    scripts/agent-turn.py show --name NAME

The prompt is a text file because a `BASHTEST` script is multi-line and shell
quoting a heredoc-in-a-heredoc is exactly the kind of thing that silently
mangles the command under test.

Environment
    MOCK_PORT     default 19700
    TURN_TIMEOUT  default 300 seconds
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
LOGS = ROOT / "logs" / "step5"
SHOTS = ROOT / "screenshots"
SIMSET = ROOT / "simdevices"
BUNDLE_ID = "local.dshportc.app"
# Which device, from DSHPORTE_DEVICE: `phone` (default) or `ipad`. Centralised so
# a script cannot quietly measure the wrong idiom — see scripts/device_pick.py.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import device_pick  # noqa: E402

DEVICE_NAME = device_pick.name()
APP_PATH = ROOT / "DerivedData/Build/Products/Debug-iphonesimulator/DSHPortC.app"
ENV = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}
# The three files the app writes for observability live under Library/Application
# Support, not Documents, so they stay out of the Files app.
RUNTIME_DIR = "Library/Application Support/DSHPortC"


def run(args, *, check=False, timeout=180):
    """Run a host command with the task's DEVELOPER_DIR."""
    return subprocess.run(args, capture_output=True, text=True, env=ENV, check=check, timeout=timeout)


def simctl(*args, check=False, timeout=180):
    """Run `simctl` against this task's own device set."""
    return run(["xcrun", "simctl", "--set", str(SIMSET), *args], check=check, timeout=timeout)


def device_udid() -> str:
    return device_pick.device_udid(create_phone=True)


def boot(udid: str) -> None:
    """Boot the device and wait until it is usable."""
    if f"{udid}) (Booted)" not in simctl("list", "devices").stdout:
        simctl("boot", udid)
        simctl("bootstatus", udid, timeout=300)


def data_container(udid: str) -> Path:
    """The app's data container on the host filesystem."""
    return Path(simctl("get_app_container", udid, BUNDLE_ID, "data", check=True).stdout.strip())


def read_session_events(container: Path) -> list[dict]:
    """Every durable event of every session in this container, oldest first."""
    events: list[dict] = []
    sessions = container / "Library/Application Support/DSH/sessions"
    if not sessions.is_dir():
        return events
    for path in sorted(sessions.rglob("*.jsonl.zstd")):
        raw = run(["zstd", "-dc", str(path)]).stdout
        for line in raw.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return events


def wait_for_turn(container: Path, timeout: float) -> list[dict]:
    """Poll the session log until a `turn/end` appears."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        events = read_session_events(container)
        if any(event.get("type") == "turn/end" for event in events):
            return events
        time.sleep(2)
    return read_session_events(container)


def tool_pairs(events: list[dict]) -> list[dict]:
    """Pair every `tool/call` with the `tool/result` that answered it."""
    calls: dict[str, dict] = {}
    pairs: list[dict] = []
    for event in events:
        if event.get("type") == "tool/call":
            data = event.get("data", {})
            calls[data.get("callId")] = {
                "name": data.get("name"),
                "arguments": data.get("arguments"),
            }
        elif event.get("type") == "tool/result":
            data = event.get("data", {})
            # The id is on the nested message, not on the event's own data: a
            # `tool/result` wraps a whole tool message, and reading only
            # `data.toolCallId` yields None for every result — which then pairs
            # each result with no call and reports `name: null`.
            message = data.get("message", {})
            call_id = data.get("toolCallId") or message.get("toolCallId")
            call = calls.get(call_id, {})
            message = data.get("message", {})
            content = message.get("content", [])
            text = "".join(block.get("text", "") for block in content if block.get("type") == "text")
            pairs.append({
                "callId": call_id,
                "name": call.get("name"),
                "arguments": call.get("arguments"),
                "isError": message.get("isError"),
                "text": text,
            })
    return pairs


def cmd_run(args: argparse.Namespace) -> int:
    """Launch the app, drive one prompt, and write the transcript."""
    LOGS.mkdir(parents=True, exist_ok=True)
    prompt = Path(args.prompt_file).read_text()
    udid = device_udid()
    boot(udid)

    # Fresh container every run: a previous run's workspace and guest state must
    # not be able to make this one pass.
    simctl("terminate", udid, BUNDLE_ID)
    simctl("uninstall", udid, BUNDLE_ID)
    simctl("install", udid, str(APP_PATH), check=True)

    # The mock server has to be up: the agent's only model route points at it.
    health = run(["curl", "-sf", "-m", "3", f"http://127.0.0.1:{args.mock_port}/healthz"])
    if health.returncode != 0:
        raise SystemExit(f"the mock model server is not answering on port {args.mock_port}; run scripts/mock-start.sh start")

    launch_env = {
        "SIMCTL_CHILD_DSHPORT_UITEST_PROMPT": prompt,
        # The marker the driver waits for in the rendered page. Defaults to the
        # mock's own final sentence, which every scripted sequence ends with.
        "SIMCTL_CHILD_DSHPORT_UITEST_KEYWORD": args.keyword,
    }
    env = {**ENV, **launch_env}
    started = time.time()
    subprocess.run(
        ["xcrun", "simctl", "--set", str(SIMSET), "launch", udid, BUNDLE_ID, "-DSHPortCTestDrive", "1"],
        capture_output=True, text=True, env=env, timeout=120,
    )

    container = data_container(udid)
    events = wait_for_turn(container, args.turn_timeout)
    elapsed = time.time() - started

    pairs = tool_pairs(events)
    turn_ends = [event for event in events if event.get("type") == "turn/end"]
    uidrive_path = container / "Documents/DSHPortC-uidrive.json"
    uidrive = json.loads(uidrive_path.read_text()) if uidrive_path.exists() else {"events": []}

    record = {
        "name": args.name,
        "prompt": prompt,
        "keyword": args.keyword,
        "startedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(started)),
        "elapsedSeconds": round(elapsed, 2),
        "turnEnds": turn_ends,
        "toolCalls": pairs,
        "uidrive": uidrive,
        "nodeLog": (container / RUNTIME_DIR / "DSHPortC-node.log").read_text(errors="replace"),
        "status": json.loads((container / RUNTIME_DIR / "DSHPortC-status.json").read_text())
        if (container / RUNTIME_DIR / "DSHPortC-status.json").exists() else {},
    }

    out = LOGS / f"{args.name}.json"
    out.write_text(json.dumps(record, indent=2, ensure_ascii=False))

    # A screenshot is the only evidence that the interface showed what the log
    # says it did; taken last so it depicts the finished turn.
    SHOTS.mkdir(parents=True, exist_ok=True)
    simctl("io", udid, "screenshot", str(SHOTS / f"{args.name}.png"))

    print(json.dumps({
        "name": args.name,
        "elapsedSeconds": record["elapsedSeconds"],
        "turns": len(turn_ends),
        "toolCalls": [
            {
                "name": pair["name"],
                "arguments": pair["arguments"],
                "isError": pair["isError"],
                "text": pair["text"][:400],
            }
            for pair in pairs
        ],
        "out": str(out),
    }, indent=2, ensure_ascii=False))
    return 0


def cmd_show(args: argparse.Namespace) -> int:
    """Print a previously recorded transcript."""
    path = LOGS / f"{args.name}.json"
    if not path.exists():
        raise SystemExit(f"no record at {path}")
    record = json.loads(path.read_text())
    print(json.dumps(record["toolCalls"], indent=2, ensure_ascii=False))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    run_parser = sub.add_parser("run", help="drive one scripted turn")
    run_parser.add_argument("--prompt-file", required=True)
    run_parser.add_argument("--keyword", required=True)
    run_parser.add_argument("--name", required=True)
    run_parser.add_argument("--mock-port", type=int, default=int(os.environ.get("MOCK_PORT", "19700")))
    run_parser.add_argument("--turn-timeout", type=float, default=float(os.environ.get("TURN_TIMEOUT", "300")))
    run_parser.set_defaults(func=cmd_run)

    show_parser = sub.add_parser("show", help="print a recorded transcript")
    show_parser.add_argument("--name", required=True)
    show_parser.set_defaults(func=cmd_show)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
