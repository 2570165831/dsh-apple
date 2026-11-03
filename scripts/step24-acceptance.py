#!/usr/bin/env python3
"""Step 24 acceptance: the guest's Node, npm and Python, measured in the app.

WHAT THIS SCRIPT IS, AND WHAT IT IS NOT
---------------------------------------
It is the host half. It installs the app, stages the fixtures, launches the app
with the step-24 gate on, waits for the module inside the app to finish writing
its report, and copies the evidence into `logs/step24/`. It does not run any
guest command itself: every measurement happens inside the app, through the
shipped `ctx.subprocess` provider, and this file's job is to make that run
trustworthy and to keep its output.

WHY THE RUN IS SEGMENTED. The full matrix is roughly 200 guest commands and
twenty minutes of an emulated CPU. One launch for all of it means one hang loses
every criterion, and the report cannot say which part was slow. So the module in
the app takes a segment name, and this script launches it once per segment,
keeping each report. A segment that fails or times out is recorded as such and
the next one still runs.

    python3 scripts/step24-acceptance.py                 every segment
    python3 scripts/step24-acceptance.py python          just one
    python3 scripts/step24-acceptance.py --list          what the segments are
    python3 scripts/step24-acceptance.py --keep-data     reuse the container

ENVIRONMENT
    DSHPORTE_DEVICE   phone-polish (this step's device; nothing else is touched)
    MOCK_PORT         the mock model server's port, for the https arm
    DSHPORTE_STEP24_MOCK_URL overrides the URL handed to the guest

Every criterion's exit code, wall time and output are in the report; the summary
this script prints is a convenience over the same JSON.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import device_pick  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
LOGS = ROOT / "logs" / "step24"
BUNDLE_ID = device_pick.BUNDLE_ID
APP_PATH = device_pick.APP_PATH
ENV = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}
RUNTIME_DIR = "Library/Application Support/DSHPortC"
REPORT_NAME = "DSHPortE-step24-acceptance.json"

# The segments the in-app module defines, in the order they run. `cpu` is inside
# `node` and `python` rather than separate, because the CPU loop is only
# meaningful next to the interpreter that ran it.
#
# `isolate` is a diagnostic segment rather than a claim about the product: it runs
# one guest command per step of the Node capability script, so a command that
# wedges can be attributed to a statement instead of to "Node". It is accepted as
# an argument and left out of the default order.
SEGMENTS = ["python", "node", "npm", "project", "pipe"]
DIAGNOSTIC_SEGMENTS = ["isolate"]

# A per-segment wall-clock ceiling. The npm segment is the long one: six clean
# installs of two packages plus a tarball listing each, on an emulated CPU. The
# Python segment runs its whole capability suite twice (workspace and rootfs).
SEGMENT_TIMEOUT = {
    "isolate": 900,
    "python": 1_800,
    "node": 1_800,
    "npm": 3_600,
    "project": 2_400,
    "pipe": 1_800,
}


def simctl(*args, check=False, timeout=300):
    return device_pick.simctl(*args, check=check, timeout=timeout)


def log(message: str) -> None:
    print(f"== {message}", flush=True)


def boot() -> None:
    udid = device_pick.device_udid(create_phone=False)
    log(f"device {device_pick.name()} ({udid})")
    device_pick.boot(udid)


def container() -> Path:
    return device_pick.data_container(device_pick.device_udid(create_phone=False))


def install(udid: str) -> None:
    if not APP_PATH.is_dir():
        raise SystemExit(f"no app at {APP_PATH}; run scripts/build-app.sh first")
    simctl("terminate", udid, BUNDLE_ID)
    simctl("uninstall", udid, BUNDLE_ID)
    simctl("install", udid, str(APP_PATH), check=True)


def stage_fixtures(data: Path) -> str:
    """Copy `tests/fixtures/step24` into the workspace and return the guest path.

    The workspace is the ONLY way into the guest: it is bind-mounted at
    `/workspace`, and the app cannot push a host file any other way. `tests/` is
    not a bundle resource (it is host-side test material), so it is copied here
    rather than read from the app bundle.
    """
    source = ROOT / "tests" / "fixtures" / "step24"
    target = data / "Documents" / "workspace" / "step24-fixtures"
    if target.exists():
        shutil.rmtree(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, target)
    return "/workspace/step24-fixtures"


def launch(udid: str, segment: str, mock_url: str, extra_env: dict[str, str]) -> float:
    """Launch the app with the step-24 gate on, for one segment."""
    started = time.time()
    env = {
        **ENV,
        "SIMCTL_CHILD_DSHPORTE_STEP24_ONLY": segment,
        "SIMCTL_CHILD_DSHPORTE_STEP24_MOCK_URL": mock_url,
        **{f"SIMCTL_CHILD_{key}": value for key, value in extra_env.items()},
    }
    # `simctl launch` blocks until the app has started; on a loaded machine that
    # has taken longer than three minutes. Two attempts, because a timeout here
    # is about the machine, not about the app.
    for attempt in (1, 2):
        try:
            result = subprocess.run(
                ["xcrun", "simctl", *device_pick.set_arguments(), "launch", udid, BUNDLE_ID,
                 "-DSHPortCTestStep24Acceptance", "1"],
                capture_output=True, text=True, env=env, timeout=300,
            )
        except subprocess.TimeoutExpired:
            log(f"launch attempt {attempt} timed out; retrying")
            simctl("terminate", udid, BUNDLE_ID)
            time.sleep(5)
            continue
        if result.returncode != 0:
            raise SystemExit(f"launch failed: {result.stderr.strip()}")
        return started
    raise SystemExit("launch timed out twice; the simulator is not responding")


def wait_for_report(data: Path, report_out: Path, budget: float) -> dict:
    """Poll the app's report until it carries a summary, and copy it out.

    The module writes after every criterion, so the file exists long before it is
    finished. `summary` is the completion marker, and it is checked by parsing
    rather than by grepping: an earlier step in this project learned that a
    substring match over a half-written report reports success.
    """
    source = data / "Documents" / REPORT_NAME
    deadline = time.time() + budget
    last: dict = {}
    while time.time() < deadline:
        if source.exists():
            try:
                last = json.loads(source.read_text())
            except (OSError, json.JSONDecodeError):
                last = {}
            if isinstance(last.get("summary"), dict):
                shutil.copyfile(source, report_out)
                return last
        time.sleep(2)
    if source.exists():
        try:
            last = json.loads(source.read_text())
        except (OSError, json.JSONDecodeError):
            last = {}
        # A partial report is still evidence, and the difference between "timed
        # out with 4 of 7 criteria" and "wrote nothing" is the whole diagnosis.
        shutil.copyfile(source, report_out)
    return last


def copy_diagnostics(data: Path, name: str) -> dict:
    """Keep the app's own log and the status file beside the report."""
    copied = {}
    runtime = data / RUNTIME_DIR
    for source_name, target_name in [
        ("DSHPortC-node.log", f"{name}-node.log"),
        ("DSHPortC-status.json", f"{name}-status.json"),
    ]:
        source = runtime / source_name
        if source.exists():
            target = LOGS / target_name
            try:
                shutil.copyfile(source, target)
                copied[source_name] = str(target.relative_to(ROOT))
            except OSError:
                pass
    return copied


def summarise(report: dict, segment: str) -> None:
    summary = report.get("summary") if isinstance(report, dict) else None
    if not isinstance(summary, dict):
        criteria = report.get("criteria", {}) if isinstance(report, dict) else {}
        done = [key for key, value in criteria.items()
                if isinstance(value, dict) and "pass" in value]
        print(f"  [{segment}] no summary; {len(done)} criteria recorded before it stopped")
        for key in done:
            print(f"    {'PASS' if criteria[key].get('pass') else 'FAIL'}  {key}")
        return
    print(f"  [{segment}] passed {summary.get('passed')}/{summary.get('total')}")
    for key, ok in summary.get("results", {}).items():
        print(f"    {'PASS' if ok else 'FAIL'}  {key}")


def mock_url_from_environment() -> str:
    """The mock's health URL, when one is running.

    The https arm uses it as the "local mock" target the task allows. An unset or
    unreachable mock is not an error: the registry arm still runs, and the report
    records which targets were tried.
    """
    explicit = os.environ.get("DSHPORTE_STEP24_MOCK_URL")
    if explicit:
        return explicit
    port = os.environ.get("MOCK_PORT", "")
    if not port:
        return ""
    url = f"http://127.0.0.1:{port}/healthz"
    try:
        result = subprocess.run(["curl", "-fsS", "-m", "3", url], capture_output=True, text=True, timeout=10)
        return url if result.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired):
        return ""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("segments", nargs="*", choices=SEGMENTS + DIAGNOSTIC_SEGMENTS,
                        metavar="SEGMENT",
                        help=f"one or more of {SEGMENTS + DIAGNOSTIC_SEGMENTS}; default is the matrix")
    parser.add_argument("--list", action="store_true", help="print the segment names and exit")
    parser.add_argument("--keep-data", action="store_true",
                        help="reuse the app container (and so the imported rootfs)")
    parser.add_argument("--name", default="", help="label for the run; default is the segment name")
    args = parser.parse_args()

    if args.list:
        for name in SEGMENTS:
            print(name)
        for name in DIAGNOSTIC_SEGMENTS:
            print(f"{name}  (diagnostic, not in the default run)")
        return 0

    if (os.environ.get("DSHPORTE_DEVICE") or "").strip().lower() not in {"phone-polish", "iphone-polish", "phone-bg", "iphone-bg"}:
        print("step24: DSHPORTE_DEVICE must be phone-polish for this step "
              f"(got {os.environ.get('DSHPORTE_DEVICE')!r}); it is this step's own device "
              "and the task says the others are not to be touched", file=sys.stderr)
        return 2

    LOGS.mkdir(parents=True, exist_ok=True)
    segments = args.segments or SEGMENTS
    mock_url = mock_url_from_environment()
    if mock_url:
        log(f"https arm will also call the local mock at {mock_url}")
    else:
        log("no mock reachable; the https arm reports the registry only")

    boot()
    udid = device_pick.device_udid(create_phone=False)
    if not args.keep_data:
        install(udid)
    else:
        simctl("install", udid, str(APP_PATH), check=True)

    data = container()
    fixtures_guest = stage_fixtures(data)
    log(f"fixtures staged at {fixtures_guest}")

    outcomes = {}
    for segment in segments:
        name = args.name or segment
        report_out = LOGS / f"{name}.json"
        log(f"segment {segment} (budget {SEGMENT_TIMEOUT[segment]} s)")
        simctl("terminate", udid, BUNDLE_ID)
        # The previous segment's report must not satisfy this one's wait.
        (data / "Documents" / REPORT_NAME).unlink(missing_ok=True)
        launch(udid, segment, mock_url, {"DSHPORTE_STEP24_FIXTURES": fixtures_guest})
        report = wait_for_report(data, report_out, SEGMENT_TIMEOUT[segment])
        copied = copy_diagnostics(data, name)
        if copied:
            log(f"diagnostics: {', '.join(copied.values())}")
        summarise(report, segment)
        summary = report.get("summary") if isinstance(report, dict) else None
        outcomes[segment] = {
            "finished": isinstance(summary, dict),
            "passed": (summary or {}).get("passed"),
            "total": (summary or {}).get("total"),
            "report": str(report_out.relative_to(ROOT)),
        }
        simctl("terminate", udid, BUNDLE_ID)

    (LOGS / "run-summary.json").write_text(json.dumps({
        "device": device_pick.name(),
        "mock_url": mock_url,
        "app": str(APP_PATH),
        "segments": outcomes,
        "finishedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }, indent=2, sort_keys=True))
    log(f"wrote {LOGS / 'run-summary.json'}")

    failed = [name for name, value in outcomes.items() if not value["finished"]
              or value["passed"] != value["total"]]
    if failed:
        print(f"\nsegments not fully passing: {', '.join(failed)}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
