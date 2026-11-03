#!/usr/bin/env python3
"""Drive the real app's composer with real image files and record what happened.

WHAT THIS IS FOR
----------------
The step-5 criteria about images are not "the code compiles". They are:

  2. a HEIC, a >=4000 px JPEG and a PNG can be attached in the DSH UI and sent,
     and the model request really carries them, downscaled per DSH's rules;
  3. `read_image` returns content for an image in the workspace;
  4. a corrupt image and a ~50 MB image produce clear errors rather than a hang
     or a crash;
  5. the transcoded copy carries no EXIF location data.

Every one of them is evidenced from outside the app, by things a user could also
see:

  * the mock model server's request log — what the model actually received,
    including each image's MIME type, byte count and measured pixel dimensions;
  * the app's own node log and status JSON;
  * the durable session events (decompressed from the session log);
  * a screenshot of the finished turn.

Nothing here asserts on internal state that only the implementation could know.

USAGE
    scripts/image-acceptance.py run --name img-main --prompt-file P \\
        --keyword IMAGETEST --attachments photo.heic,big-4608.jpg,alpha-2600.png
    scripts/image-acceptance.py turn --name read-image --prompt-file P --keyword READIMAGE
    scripts/image-acceptance.py show --name img-main

`run` uses the attachment driver; `turn` is the plain text driver (used for the
`read_image` case, where the agent reads a file already in the workspace).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
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
FIXTURES = LOGS / "imgtest" / "fixtures"
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
    return device_pick.device_udid(create_phone=False)


def boot(udid: str) -> None:
    """Boot the device and wait until it is usable."""
    if f"{udid}) (Booted)" not in simctl("list", "devices").stdout:
        simctl("boot", udid)
        simctl("bootstatus", udid, timeout=300)


def data_container(udid: str) -> Path:
    """The app's data container on the host filesystem."""
    out = simctl("get_app_container", udid, BUNDLE_ID, "data", check=True).stdout.strip()
    return Path(out)


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


def wait_for_turn(container: Path, timeout: float, *, expect_tool: bool = False) -> list[dict]:
    """Poll the session log until a `turn/end` appears (or a tool result, if asked)."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        events = read_session_events(container)
        if expect_tool:
            if any(event.get("type") == "tool/result" for event in events):
                # Give the turn a moment to close after the tool result lands.
                time.sleep(6)
                return read_session_events(container)
        elif any(event.get("type") == "turn/end" for event in events):
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
            calls[data.get("callId")] = {"name": data.get("name"), "arguments": data.get("arguments")}
        elif event.get("type") == "tool/result":
            data = event.get("data", {})
            # A `tool/result` wraps the tool message under `message`; a
            # `user/message` does not. Both spellings are tolerated so a future
            # shape change degrades to a miss rather than an exception.
            message = data.get("message", data)
            call_id = data.get("toolCallId") or message.get("toolCallId")
            call = calls.get(call_id, {})
            content = message.get("content", [])
            text = "".join(block.get("text", "") for block in content if block.get("type") == "text")
            images = [
                {
                    "attachmentId": block.get("attachment", {}).get("attachmentId"),
                    "mediaType": block.get("attachment", {}).get("mediaType"),
                    "width": block.get("attachment", {}).get("width"),
                    "height": block.get("attachment", {}).get("height"),
                    "bytes": block.get("attachment", {}).get("bytes"),
                }
                for block in content
                if block.get("type") == "image"
            ]
            pairs.append({
                "callId": call_id,
                "name": call.get("name"),
                "arguments": call.get("arguments"),
                "isError": message.get("isError"),
                "text": text,
                "images": images,
            })
    return pairs


def user_image_parts(events: list[dict]) -> list[dict]:
    """The image blocks the durable log recorded on the user's own message.

    The event's `data` IS the message (`{content, role, id, source}`), not a
    wrapper with a `message` key — the earlier version looked one level too deep
    and reported zero images for a turn that had three.
    """
    parts: list[dict] = []
    for event in events:
        if event.get("type") != "user/message":
            continue
        for block in event.get("data", {}).get("content", []):
            if block.get("type") != "image":
                continue
            attachment = block.get("attachment", {})
            parts.append({
                "attachmentId": attachment.get("attachmentId"),
                "mediaType": attachment.get("mediaType"),
                "width": attachment.get("width"),
                "height": attachment.get("height"),
                "bytes": attachment.get("bytes"),
                "originalDimensions": attachment.get("originalDimensions"),
                "name": attachment.get("name"),
            })
    return parts


def mock_requests(mock_port: int) -> list[dict]:
    """Read the mock server's request log, newest last."""
    path = ROOT / "logs" / "mock-requests.jsonl"
    if not path.is_file():
        return []
    records = []
    for line in path.read_text(errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return [record for record in records if int(record.get("port", mock_port)) == mock_port or True]


def cmd_run(args: argparse.Namespace) -> int:
    """Launch the app, attach files, send one prompt, and record everything."""
    LOGS.mkdir(parents=True, exist_ok=True)
    prompt = Path(args.prompt_file).read_text()
    udid = device_udid()
    boot(udid)

    # A fresh container every run: a previous run's workspace, session list and
    # guest state must not be able to make this one pass.
    simctl("terminate", udid, BUNDLE_ID)
    simctl("uninstall", udid, BUNDLE_ID)
    simctl("install", udid, str(APP_PATH), check=True)

    health = run(["curl", "-sf", "-m", "3", f"http://127.0.0.1:{args.mock_port}/healthz"])
    if health.returncode != 0:
        raise SystemExit("the mock model server is not answering; run scripts/mock-start.sh start")

    # Stage the fixtures INSIDE the app workspace before launch, so the driver can
    # read them and so `read_image` has something to open. The workspace lives in
    # the container, which is recreated by the uninstall above, so this has to
    # happen after the install.
    container = data_container(udid)
    # The agent's cwd is `Documents/workspace/deepseek-harness/default-workspace`,
    # NOT `Documents/workspace`: that parent holds the harness tree, and a file
    # staged at the parent is invisible to `read_image` because the tool resolves
    # relative to the session's own working directory. Staging happened at the
    # wrong level on the first attempt and the tool answered "not found".
    workspace = container / "Documents" / "workspace" / "deepseek-harness" / "default-workspace"
    workspace.mkdir(parents=True, exist_ok=True)
    staged = []
    for name in args.stage or []:
        source = FIXTURES / name if (FIXTURES / name).is_file() else Path(name)
        if not source.is_file():
            raise SystemExit(f"staged file not found: {name} (looked at {source})")
        destination = workspace / source.name
        destination.write_bytes(source.read_bytes())
        staged.append({"name": source.name, "bytes": destination.stat().st_size})

    launch_env = {
        "SIMCTL_CHILD_DSHPORT_UITEST_PROMPT": prompt,
        "SIMCTL_CHILD_DSHPORT_UITEST_KEYWORD": args.keyword,
    }
    if args.attachments:
        launch_env["SIMCTL_CHILD_DSHPORT_UITEST_ATTACHMENTS"] = args.attachments
    env = {**ENV, **launch_env}

    # Record the mock log's line count so only this run's requests are examined.
    request_log = ROOT / "logs" / "mock-requests.jsonl"
    before = len(request_log.read_text(errors="replace").splitlines()) if request_log.is_file() else 0

    started = time.time()
    # THE PORT HAS TO BE PASSED, not defaulted. The app's profile falls back to
    # 19700 when `DSHPORTC_MOCK_PORT` is absent, and 19700 is the MAIN checkout's
    # mock — so a run from this checkout that forgot to say which port would send
    # its prompts to another task's server and read that server's replies as its
    # own evidence. Measured here: with the flag missing, this run's four requests
    # appeared in the other checkout's log and none in this one.
    subprocess.run(
        ["xcrun", "simctl", "--set", str(SIMSET), "launch", udid, BUNDLE_ID,
         "-DSHPortCTestDrive", "1",
         "-DSHPortCMockPort", str(args.mock_port)],
        capture_output=True, text=True, env=env, timeout=180,
    )

    events = wait_for_turn(container, args.turn_timeout, expect_tool=args.expect_tool)
    elapsed = time.time() - started

    pairs = tool_pairs(events)
    uidrive_path = container / "Documents/DSHPortC-uidrive.json"
    uidrive = json.loads(uidrive_path.read_text()) if uidrive_path.exists() else {"events": []}
    status_path = container / RUNTIME_DIR / "DSHPortC-status.json"
    status = json.loads(status_path.read_text()) if status_path.exists() else {}
    node_log = (container / RUNTIME_DIR / "DSHPortC-node.log").read_text(errors="replace")

    after_records = request_log.read_text(errors="replace").splitlines() if request_log.is_file() else []
    this_run = []
    for line in after_records[before:]:
        line = line.strip()
        if not line:
            continue
        try:
            this_run.append(json.loads(line))
        except json.JSONDecodeError:
            continue

    record = {
        "name": args.name,
        "mode": "attachments" if args.attachments else "text",
        "prompt": prompt,
        "keyword": args.keyword,
        "attachments": args.attachments,
        "staged": staged,
        "startedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(started)),
        "elapsedSeconds": round(elapsed, 2),
        "turnEnds": [event for event in events if event.get("type") == "turn/end"],
        "userImages": user_image_parts(events),
        "toolCalls": pairs,
        "uidrive": uidrive,
        "mockRequests": this_run,
        "nodeLog": node_log,
        "status": status,
    }

    out = LOGS / f"{args.name}.json"
    out.write_text(json.dumps(record, indent=2, ensure_ascii=False))

    SHOTS.mkdir(parents=True, exist_ok=True)
    # `simctl io screenshot` refuses to write straight onto this external volume
    # ("Operation not permitted", NSPOSIXErrorDomain 1) while succeeding into
    # /tmp. Writing to a temporary location and copying keeps the evidence inside
    # the task directory without needing any permission change.
    staged_shot = Path(tempfile.gettempdir()) / f"{args.name}.png"
    shot = simctl("io", udid, "screenshot", str(staged_shot))
    if staged_shot.exists():
        shutil.copyfile(staged_shot, SHOTS / f"{args.name}.png")
    else:
        print(f"warning: screenshot failed: {(shot.stderr or '').strip()[:200]}", file=sys.stderr)

    print(json.dumps({
        "name": args.name,
        "elapsedSeconds": record["elapsedSeconds"],
        "turns": len(record["turnEnds"]),
        "phase": status.get("phase"),
        "staged": staged,
        "userImages": record["userImages"],
        "mockImageCounts": [
            {"request": request.get("request"), "images": request.get("images")}
            for request in this_run
        ],
        "toolCalls": [
            {"name": pair["name"], "isError": pair["isError"], "text": pair["text"][:300], "images": pair["images"]}
            for pair in pairs
        ],
        "attachEvents": [event for event in uidrive.get("events", []) if str(event.get("event", "")).startswith(("attach", "rail", "toast"))],
        "out": str(out),
    }, indent=2, ensure_ascii=False))
    return 0


def cmd_show(args: argparse.Namespace) -> int:
    """Print a previously recorded acceptance run."""
    path = LOGS / f"{args.name}.json"
    if not path.exists():
        raise SystemExit(f"no record at {path}")
    record = json.loads(path.read_text())
    print(json.dumps({
        "userImages": record.get("userImages"),
        "toolCalls": record.get("toolCalls"),
        "mockImageCounts": [
            {"request": request.get("request"), "images": request.get("images")}
            for request in record.get("mockRequests", [])
        ],
    }, indent=2, ensure_ascii=False))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    for command, help_text in (("run", "attach files and send one prompt"), ("turn", "send one text prompt")):
        node = sub.add_parser(command, help=help_text)
        node.add_argument("--prompt-file", required=True)
        node.add_argument("--keyword", required=True)
        node.add_argument("--name", required=True)
        node.add_argument("--attachments", default="", help="comma-separated workspace file names")
        node.add_argument("--stage", action="append", default=[], help="fixture to copy into the workspace (repeatable)")
        node.add_argument("--expect-tool", action="store_true", help="wait for a tool result instead of turn/end")
        node.add_argument("--mock-port", type=int, default=int(os.environ.get("MOCK_PORT", "19700")))
        node.add_argument("--turn-timeout", type=float, default=float(os.environ.get("TURN_TIMEOUT", "300")))
        node.set_defaults(func=cmd_run)

    show_parser = sub.add_parser("show", help="print a recorded run")
    show_parser.add_argument("--name", required=True)
    show_parser.set_defaults(func=cmd_show)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
