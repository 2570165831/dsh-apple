#!/usr/bin/env python3
"""Step 24 on the physical phone: the same in-app module as the simulator run.

    python3 scripts/device-step24.py                every segment
    python3 scripts/device-step24.py node npm       just those

Does not install. Evidence goes to logs/step24-phone/. A segment whose app dies
is recorded as such (a jetsam looks like this) and the next one still runs.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOGS = ROOT / "logs" / "step24-phone"
DEVICE = __import__("os").environ["DSH_DEVICE_UDID"]
BUNDLE = "local.dshportc.app"
REPORT = "Documents/DSHPortE-step24-acceptance.json"
RUNTIME = "Library/Application Support/DSHPortC"
ENV = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}
SEGMENTS = ["node", "python", "npm", "project", "pipe"]
BUDGET = {"node": 1800, "python": 1800, "npm": 3600, "project": 2400, "pipe": 1800}


def devicectl(*args, timeout=180):
    return subprocess.run(["xcrun", "devicectl", *args], capture_output=True, text=True,
                          env=ENV, timeout=timeout)


def copy_from(source: str, target: Path) -> bool:
    target.unlink(missing_ok=True)
    result = devicectl("device", "copy", "from", "--device", DEVICE, "--domain-type", "appDataContainer",
                       "--domain-identifier", BUNDLE, "--source", source, "--destination", str(target))
    return result.returncode == 0 and target.exists()


def app_state() -> str:
    """`running`, `gone` or `locked`. A locked phone answers nothing, which must not read as a dead app."""
    result = devicectl("device", "info", "processes", "--device", DEVICE)
    if "locked" in result.stderr + result.stdout and result.returncode != 0:
        return "locked"
    if result.returncode != 0:
        return "unknown"
    return "running" if "DSHPortC.app/DSHPortC" in result.stdout else "gone"


def read_report(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def stage_fixtures() -> None:
    source = ROOT / "tests" / "fixtures" / "step24"
    result = devicectl("device", "copy", "to", "--device", DEVICE, "--domain-type", "appDataContainer",
                       "--domain-identifier", BUNDLE, "--source", str(source),
                       "--destination", "Documents/workspace/step24-fixtures")
    if result.returncode != 0:
        raise SystemExit(f"could not stage fixtures: {result.stderr.strip()}")


def run_segment(segment: str) -> dict:
    out = LOGS / f"{segment}.json"
    with tempfile.TemporaryDirectory() as scratch:
        probe = Path(scratch) / "report.json"
        started_at = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())
        launched = devicectl("device", "process", "launch", "--device", DEVICE, "--terminate-existing", BUNDLE,
                             "--", "-DSHPortCTestStep24Acceptance", "1",
                             "-DSHPortCTestStep24Only", segment,
                             "-DSHPortCTestStep24Fixtures", "/workspace/step24-fixtures")
        if launched.returncode != 0:
            return {"finished": False, "error": launched.stderr.strip()[:400]}
        started = time.time()
        report: dict = {}
        died = 0
        ended = "timeout"
        while time.time() - started < BUDGET[segment]:
            time.sleep(15)
            if copy_from(REPORT, probe):
                fresh = read_report(probe)
                # The previous segment's report must not satisfy this one's wait.
                if fresh.get("startedAt", "") >= started_at:
                    report = fresh
                    out.write_text(json.dumps(report, indent=2, ensure_ascii=False))
                    if isinstance(report.get("summary"), dict):
                        ended = "finished"
                        break
            state = app_state()
            with (LOGS / f"{segment}-poll.log").open("a") as poll:
                poll.write(f"{time.strftime('%H:%M:%S')} {state} criteria={len(report.get('criteria', {}))}\n")
            if state == "locked":
                ended = "phone_locked"
                break
            died = died + 1 if state == "gone" else 0
            if died >= 2:
                ended = "app_died"
                break
        seconds = round(time.time() - started)
    copy_from(f"{RUNTIME}/DSHPortC-node.log", LOGS / f"{segment}-node.log")
    summary = report.get("summary") if isinstance(report.get("summary"), dict) else {}
    done = {key: value.get("pass") for key, value in report.get("criteria", {}).items()
            if isinstance(value, dict) and "pass" in value}
    return {"ended": ended, "seconds": seconds, "passed": summary.get("passed"), "total": summary.get("total"),
            "results": summary.get("results", done)}


def main() -> int:
    LOGS.mkdir(parents=True, exist_ok=True)
    stage_fixtures()
    outcomes = {}
    for segment in sys.argv[1:] or SEGMENTS:
        print(f"== {segment}", flush=True)
        outcomes[segment] = run_segment(segment)
        print(json.dumps(outcomes[segment], ensure_ascii=False), flush=True)
        (LOGS / "run-summary.json").write_text(json.dumps(outcomes, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
