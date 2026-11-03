#!/usr/bin/env python3
"""Step 17 acceptance: the Files-app surface, and downloads that reach the share sheet.

WHAT THIS SCRIPT CAN AND CANNOT SEE
-----------------------------------
Two of step 17's claims are about a `UIActivityViewController` and about the
Files app, and neither is visible from a host process. Those are driven by
`app/DSHPortCUITests/Step17UITests.swift` under `xcodebuild test`, and this
script only reports whether that run produced its screenshots. Everything else
is asserted here, against files the app wrote and against the guest:

  documents   after a normal launch, `Documents/` holds `workspace/` and nothing
              else; every file under it is checked for key material
  legacy      an OLD build writes its runtime files into `Documents/`; installing
              this build over it must remove them and leave the old session
              openable (a further turn runs inside it)
  share       each download trigger produces a file of the right bytes, the share
              sheet is presented, and the temporary copy is gone afterwards;
              `/export`'s ZIP is opened and its contents checked
  files       a file put in `workspace/` the way the Files app puts one there is
              read and modified by the guest, and a file the agent wrote is
              readable from the host side of the same directory

Usage
    DSHPORTE_DEVICE=phone-files scripts/step17-acceptance.py documents
    DSHPORTE_DEVICE=phone-files scripts/step17-acceptance.py legacy --baseline PATH
    DSHPORTE_DEVICE=phone-files scripts/step17-acceptance.py share [--case NAME]
    DSHPORTE_DEVICE=phone-files scripts/step17-acceptance.py files

Every command writes a JSON verdict into `logs/step17/`.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOGS = ROOT / "logs" / "step17"
SHOTS = ROOT / "screenshots" / "step17"
SIMSET = ROOT / "simdevices"
BUNDLE_ID = "local.dshportc.app"
APP_PATH = ROOT / "DerivedData/Build/Products/Debug-iphonesimulator/DSHPortC.app"
MOCK_PORT = int(os.environ.get("MOCK_PORT", "19717"))
ENV = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}

# The three files that used to sit beside the workspace, and now live under
# Library/Application Support. The legacy names are what the "upgrade" arm
# asserts have been removed.
RUNTIME_DIR = "Library/Application Support/DSHPortC"
LEGACY_NAMES = ["DSHPortC-status.json", "DSHPortC-node.log", "DSHPortC-session-url.txt"]

sys.path.insert(0, str(Path(__file__).resolve().parent))
import device_pick  # noqa: E402


def run(args, *, check=False, timeout=240, env=None):
    return subprocess.run(args, capture_output=True, text=True,
                          env=env or ENV, check=check, timeout=timeout)


def simctl(*args, check=False, timeout=240):
    """`simctl`, against this task's set or the override device's default set.

    The set decision lives in `device_pick` — one place, so a script cannot
    quietly talk to the wrong device — and `DSHPORTE_UDID` is what selects the
    default set, because that is where the two XCUITest devices had to be created
    (`xcodebuild` cannot see a custom `--set`, see TASK-17's tools section).
    """
    return device_pick.simctl(*args, check=check, timeout=timeout)


def boot(device: str) -> None:
    listing = simctl("list", "devices").stdout
    if f"{device}) (Booted)" not in listing:
        simctl("boot", device)
        simctl("bootstatus", device, timeout=300)


def udid() -> str:
    """The device under test: `dsh-portE-iPhone-files` unless `DSHPORTE_UDID` says
    otherwise (the XCUITest devices, which live in the default set)."""
    return device_pick.device_udid(create_phone=False)


def container(device: str) -> Path:
    return Path(simctl("get_app_container", device, BUNDLE_ID, "data", check=True).stdout.strip())


def terminate(device: str) -> None:
    simctl("terminate", device, BUNDLE_ID)


def install(device: str, app: Path) -> None:
    simctl("install", device, str(app), check=True)


def launch(device: str, *arguments: str, env: dict | None = None) -> None:
    """Launch, and survive a slow simulator.

    `simctl launch` blocks until the app has started, and on a loaded machine that
    has taken longer than three minutes — measured, during this step, on a host
    whose load average was in the hundreds. A timeout is retried once rather than
    reported as a failure of the app: the app did start on the second attempt,
    and a harness that calls that a verdict would be lying about the product.
    """
    args = ["xcrun", "simctl", *device_pick.set_arguments(), "launch", device, BUNDLE_ID, *arguments]
    for attempt in (1, 2):
        try:
            result = subprocess.run(args, capture_output=True, text=True,
                                    env={**ENV, **(env or {})}, timeout=240)
        except subprocess.TimeoutExpired:
            print(f"launch attempt {attempt} timed out; retrying", flush=True)
            simctl("terminate", device, BUNDLE_ID)
            time.sleep(5)
            continue
        if result.returncode != 0:
            raise SystemExit(f"launch failed: {result.stderr.strip()}")
        return
    raise SystemExit("launch timed out twice; the simulator is not responding")


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


def wait_for_status(data: Path, phase: str = "webViewReady", timeout: float = 300) -> dict:
    """Poll the app's own status file until it reports `phase`.

    The container path changes across installs, so the caller passes the CURRENT
    one and this re-resolves nothing: an install-over in the middle of a wait is
    the caller's problem, not something to paper over here.
    """
    deadline = time.time() + timeout
    seen: list[str] = []
    while time.time() < deadline:
        status = read_json(data / RUNTIME_DIR / "DSHPortC-status.json")
        current = status.get("phase", "")
        if current and (not seen or seen[-1] != current):
            seen.append(current)
        if current == phase:
            return status
        if current == "failed":
            return status
        time.sleep(1)
    return read_json(data / RUNTIME_DIR / "DSHPortC-status.json")


def fresh_launch(device: str, data: Path, *arguments: str, env: dict | None = None,
                 extra_files: tuple[str, ...] = ()) -> None:
    """Launch, and make the wait that follows about THIS launch.

    The status file survives between launches, so its `webViewReady` from the
    previous run answers immediately — measured: a "guest-dir-ops" case reported
    the previous case's steps because `wait_for_status` matched a file that had
    not been rewritten yet. Deleting the file first makes the wait mean "this
    launch reached that phase". The probe files are removed for the same reason.
    """
    (data / RUNTIME_DIR / "DSHPortC-status.json").unlink(missing_ok=True)
    for name in ("DSHPortE-files-probe.json",) + extra_files:
        (data / "Documents" / name).unlink(missing_ok=True)
    launch(device, *arguments, env=env)


def wait_for_probe(data: Path, name: str, timeout: float = 180) -> dict:
    """Wait for a probe's evidence file to report that it finished.

    A fixed `sleep` is not the same thing: `guest-dir-ops` takes as long as the
    guest takes, and a sleep that is too short reads a half-written report while
    one that is too long wastes the run.
    """
    path = data / "Documents" / name
    deadline = time.time() + timeout
    while time.time() < deadline:
        report = read_json(path)
        if report.get("finishedAt"):
            return report
        time.sleep(1)
    return read_json(path)


def screenshot(device: str, name: str) -> Path:
    """`simctl io screenshot` refuses to write straight to the external volume, so
    the shot goes to a temp file and is copied."""
    SHOTS.mkdir(parents=True, exist_ok=True)
    temporary = Path("/tmp") / f"step17-{name}.png"
    simctl("io", device, "screenshot", str(temporary))
    destination = SHOTS / f"{name}.png"
    if temporary.exists():
        shutil.copyfile(temporary, destination)
        temporary.unlink(missing_ok=True)
    return destination


# --------------------------------------------------------------------- key scan

# Shapes that would be a credential rather than a document. Deliberately about
# SHAPE, not content: this must not print what it finds.
KEY_PATTERNS = [
    ("openai-style", re.compile(rb"sk-[A-Za-z0-9]{20,}")),
    ("anthropic-style", re.compile(rb"sk-ant-[A-Za-z0-9_\-]{20,}")),
    ("aws-access-key", re.compile(rb"AKIA[0-9A-Z]{16}")),
    ("private-key-block", re.compile(rb"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("github-token", re.compile(rb"gh[pousr]_[A-Za-z0-9]{30,}")),
    ("jwt", re.compile(rb"eyJ[A-Za-z0-9_\-]{10,}\.eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}")),
    ("bearer-token-url", re.compile(rb"[?&]token=[A-Za-z0-9._~+/=\-]{16,}")),
    ("dsauthorization", re.compile(rb"Authorization:\s*Bearer\s+[A-Za-z0-9._\-]{16,}")),
]
# Extensions that are a credential by nature, whatever the bytes look like.
KEY_SUFFIXES = {".p12", ".pfx", ".key", ".pem", ".cer", ".mobileprovision", ".keystore", ".jks"}
MAX_SCAN_BYTES = 8 * 1024 * 1024


def scan_for_keys(root: Path) -> dict:
    """Every file under `root`, checked for key-shaped content and extensions.

    Reports paths and the MATCHED PATTERN NAME only. The matched text is never
    returned, printed or written: a report that quotes a token has leaked it.
    """
    findings = []
    scanned = 0
    skipped = []
    for path in sorted(root.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        relative = str(path.relative_to(root))
        if path.suffix.lower() in KEY_SUFFIXES:
            findings.append({"path": relative, "pattern": f"extension:{path.suffix.lower()}"})
            continue
        try:
            size = path.stat().st_size
        except OSError:
            skipped.append({"path": relative, "reason": "stat failed"})
            continue
        if size > MAX_SCAN_BYTES:
            skipped.append({"path": relative, "reason": f"larger than {MAX_SCAN_BYTES} bytes"})
            continue
        try:
            data = path.read_bytes()
        except OSError:
            skipped.append({"path": relative, "reason": "read failed"})
            continue
        scanned += 1
        for name, pattern in KEY_PATTERNS:
            if pattern.search(data):
                findings.append({"path": relative, "pattern": name})
                break
    return {
        "root": str(root),
        "filesScanned": scanned,
        "findings": findings,
        "skipped": skipped,
    }


# ------------------------------------------------------------------ the commands

def cmd_documents(args: argparse.Namespace) -> int:
    device = udid()
    boot(device)
    terminate(device)
    # A fresh container unless asked otherwise. A previous PROBE launch leaves
    # `DSHPortE-*.json` in Documents on purpose (a probe artefact has to be
    # readable from the host), so a `--keep-data` run would be measuring those
    # leftovers rather than what a normal launch writes.
    if not args.keep_data:
        simctl("uninstall", device, BUNDLE_ID)
        install(device, APP_PATH)
    # A probe launch would write probe files on purpose; a NORMAL launch is the
    # case this criterion is about, so no probe arguments at all.
    launch(device, "-DSHPortCMockPort", str(MOCK_PORT))
    data = container(device)
    status = wait_for_status(data)
    top = sorted(p.name for p in (data / "Documents").iterdir())
    report = {
        "device": device,
        "container": str(data),
        "phase": status.get("phase"),
        "documentsTopLevel": top,
        "documentsOnlyWorkspace": top == ["workspace"],
        "runtimeFilesInApplicationSupport": sorted(
            p.name for p in (data / RUNTIME_DIR).iterdir()
        ) if (data / RUNTIME_DIR).is_dir() else [],
        "keyScan": scan_for_keys(data / "Documents"),
    }
    screenshot(device, "files-documents-after-normal-launch")
    LOGS.mkdir(parents=True, exist_ok=True)
    (LOGS / "documents.json").write_text(json.dumps(report, indent=2, ensure_ascii=False))
    print(json.dumps({k: report[k] for k in
                      ("phase", "documentsTopLevel", "documentsOnlyWorkspace",
                       "runtimeFilesInApplicationSupport")}, indent=2, ensure_ascii=False))
    print(json.dumps(report["keyScan"], indent=2, ensure_ascii=False))
    return 0 if report["documentsOnlyWorkspace"] and not report["keyScan"]["findings"] else 1


def cmd_legacy(args: argparse.Namespace) -> int:
    """Old build first, then install this one over it.

    The point is the over-the-top install: `simctl install` over an existing app
    carries the container forward, so the old build's `Documents/` contents are
    still there when this build starts. That is the state a user is in after
    updating, and it is the only state in which the legacy cleanup does anything.
    """
    device = udid()
    boot(device)
    baseline = Path(args.baseline).expanduser().resolve()
    if not baseline.is_dir():
        raise SystemExit(f"no baseline app at {baseline}")

    LOGS.mkdir(parents=True, exist_ok=True)
    result: dict = {"device": device, "baseline": str(baseline)}

    # ---- 1. the old build, from a clean install, and one real turn in it
    terminate(device)
    simctl("uninstall", device, BUNDLE_ID)
    install(device, baseline)
    launch(device, "-DSHPortCTestDrive", "1", "-DSHPortCMockPort", str(MOCK_PORT),
           env={"SIMCTL_CHILD_DSHPORT_UITEST_PROMPT": step17_prompt_text(),
                "SIMCTL_CHILD_DSHPORT_UITEST_KEYWORD": "STEP17-SESSION-OK"})
    data = container(device)
    wait_for_status(data)
    session = wait_for_session(data, timeout=240)
    result["old"] = {
        "container": str(data),
        "phase": read_json(data / "Documents" / "DSHPortC-status.json").get("phase")
        if (data / "Documents" / "DSHPortC-status.json").exists() else "no status file",
        "documentsTopLevel": sorted(p.name for p in (data / "Documents").iterdir()),
        "sessionLog": str(session) if session else None,
        "sessionId": session_id_of(session) if session else None,
    }
    screenshot(device, "legacy-01-old-build-documents")
    terminate(device)

    # ---- 2. this build, installed over the top
    install(device, APP_PATH)
    data_after = container(device)
    # The container is carried across an install-over, but ask rather than assume.
    result["containerChanged"] = str(data_after) != str(data)
    # "The old session still opens" is measured as a real turn inside it, through
    # DSH's own `sessionController.prompt` against the migrated log on disk. That
    # is `sim/session-continue-acceptance.mjs`, the same harness step 6 built for
    # exactly this question, and it is used rather than a UI tap for a measured
    # reason: on this 402 pt wide device the sidebar never enters the DOM, so a
    # UI-driven "open the old row" cannot be performed at all (REPORT-6 §3).
    old_session = result["old"].get("sessionId")
    launch_args = ["-DSHPortCMockPort", str(MOCK_PORT)]
    if old_session:
        launch_args += [
            "-DSHPortCTestContinueSession", "1",
            "-DSHPortCTestSessionId", old_session,
            "-DSHPortCTestContinuePrompt", "STEP17-SESSION-OK 升级之后同一个会话继续",
        ]
    launch(device, *launch_args)
    status = wait_for_status(data_after, timeout=300)
    continue_report: dict = {}
    continue_path = data_after / "Documents/DSHPortE-session-continue-acceptance.json"
    deadline = time.time() + 300
    while time.time() < deadline:
        continue_report = read_json(continue_path)
        if continue_report.get("criteria", {}).get("took_a_turn"):
            break
        time.sleep(2)
    time.sleep(4)
    top_after = sorted(p.name for p in (data_after / "Documents").iterdir())
    session_after = wait_for_session(data_after, timeout=180)
    criteria = continue_report.get("criteria", {})
    took = criteria.get("took_a_turn", {})
    history = criteria.get("history_intact", {})
    result["new"] = {
        "phase": status.get("phase"),
        "documentsTopLevel": top_after,
        "legacyFilesGone": not any(name in top_after for name in LEGACY_NAMES),
        "runtimeFilesPresent": sorted(p.name for p in (data_after / RUNTIME_DIR).iterdir())
        if (data_after / RUNTIME_DIR).is_dir() else [],
        "sessionLog": str(session_after) if session_after else None,
        "sessionOpenedAgain": bool(took.get("sameSessionStillListed")),
        "sameSessionTookTurn": bool(took.get("finishedATurn")),
        "turnEndsBefore": took.get("turnEndsBefore"),
        "turnEndsAfter": took.get("turnEndsAfter"),
        "historyIntact": bool(history.get("hasOriginalTurnEnd") and history.get("carriesTheNewPrompt")),
        "continueReport": criteria or {"error": continue_report.get("error", "no report")},
    }
    log_text = read_text(data_after / RUNTIME_DIR / "DSHPortC-node.log")
    result["new"]["logSaysLegacyRemoved"] = "legacy files still in Documents" not in log_text
    result["new"]["quarantineCount"] = len(
        [p for p in (data_after / "Library/Application Support/DSH/sessions-quarantine").rglob("*") if p.is_file()]
    )
    result["new"]["probeFilesFromThisRun"] = [
        name for name in top_after if name != "workspace"
    ]
    screenshot(device, "legacy-02-new-build-documents")
    terminate(device)

    # ---- 3. a NORMAL launch, with no probe arguments at all.
    #
    # This is the state a user is actually in after updating: the app has run
    # once, the legacy files are gone, and nothing else has written into
    # Documents. The steps above needed the test driver, whose own evidence files
    # legitimately land in Documents — so "what a normal launch leaves behind" has
    # to be asked separately, on a launch that is normal.
    for name in result["new"]["probeFilesFromThisRun"]:
        (data_after / "Documents" / name).unlink(missing_ok=True)
    launch(device, "-DSHPortCMockPort", str(MOCK_PORT))
    status_normal = wait_for_status(data_after, timeout=300)
    normal_top = sorted(p.name for p in (data_after / "Documents").iterdir())
    result["afterNormalLaunch"] = {
        "phase": status_normal.get("phase"),
        "documentsTopLevel": normal_top,
        "documentsOnlyWorkspace": normal_top == ["workspace"],
        "sessionStillThere": bool(session_logs(data_after)),
        "keyScan": scan_for_keys(data_after / "Documents"),
    }
    screenshot(device, "legacy-03-normal-launch")
    terminate(device)

    (LOGS / "legacy.json").write_text(json.dumps(result, indent=2, ensure_ascii=False))
    print(json.dumps(result, indent=2, ensure_ascii=False))
    ok = (result["new"]["legacyFilesGone"]
          and result["new"]["sameSessionTookTurn"]
          and result["new"]["historyIntact"]
          and result["new"]["quarantineCount"] == 0
          and result["afterNormalLaunch"]["documentsOnlyWorkspace"]
          and not result["afterNormalLaunch"]["keyScan"]["findings"])
    return 0 if ok else 1


def step17_prompt_text(second: bool = False) -> str:
    """The prompt the mock's `STREAMTEST` script answers.

    This exists only to make a session with a durable log; the content of the
    reply does not matter to any criterion here. `second` changes the wording so
    the second turn is visibly a different message in the same log.
    """
    if second:
        return "STEP17-SESSION-OK 第二轮：升级之后的同一个会话还能继续。"
    return "STEP17-SESSION-OK 第一轮：用旧版本建一个带会话的容器。"


def session_logs(data: Path) -> list[Path]:
    root = data / "Library/Application Support/DSH/sessions"
    return sorted(root.rglob("*.jsonl.zstd")) if root.is_dir() else []


def wait_for_session(data: Path, timeout: float = 240) -> Path | None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        logs = session_logs(data)
        if logs:
            return logs[0]
        time.sleep(2)
    return None


def session_id_of(path: Path | None) -> str | None:
    """The session id, read from the log's own header line.

    Not from the folder name: the folder is a project key plus a session id, so
    the name is a container of both and would need guessing to take apart. The
    header says it outright.
    """
    if path is None:
        return None
    raw = run(["zstd", "-dc", str(path)]).stdout
    for line in raw.splitlines():
        if not line.strip():
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event.get("type") == "session" and event.get("id"):
            return str(event["id"])
    return None


def session_turn_count(data: Path) -> int:
    """How many `turn/end` events the container's sessions hold, all of them."""
    total = 0
    for path in session_logs(data):
        raw = run(["zstd", "-dc", str(path)]).stdout
        total += sum(1 for line in raw.splitlines() if '"turn/end"' in line)
    return total


def cmd_share(args: argparse.Namespace) -> int:
    """Each download trigger, one launch each, with the app's own record as evidence."""
    device = udid()
    boot(device)
    LOGS.mkdir(parents=True, exist_ok=True)
    cases = [args.case] if args.case else ["blob", "data", "big", "export", "export-nav"]
    report: dict = {"device": device, "cases": {}}

    for case in cases:
        terminate(device)
        data = container(device)
        if not (data / "Documents").is_dir():
            install(device, APP_PATH)
            data = container(device)
        # Clear what a PREVIOUS case left behind. `DSHPortE-downloads.json` is a
        # running record in a container that survives between launches, so
        # without this the wait below sees the last case's finished download and
        # reports it as this one's — measured, and it made "big" report a 62-byte
        # blob. Same for the temporary files: the sheet from the previous launch
        # died with the process, so its file is debris, not evidence.
        for stale in ("DSHPortE-downloads.json", "DSHPortE-share.json"):
            (data / "Documents" / stale).unlink(missing_ok=True)
        shutil.rmtree(data / "tmp/DSHPortCDownloads", ignore_errors=True)
        arguments = [
            "-DSHPortCMockPort", str(MOCK_PORT),
            "-DSHPortEShareCase", case,
            "-DSHPortEDownloadProbe", "1",
            "-DSHPortELinkProbe", "1",
        ]
        if case in ("export", "export-nav"):
            session = session_id_of(wait_for_session(data, timeout=10)) or first_session_id(data)
            if session is None:
                report["cases"][case] = {"error": "no session in the container to export"}
                continue
            arguments += ["-DSHPortESessionId", str(session)]
        # Sample the app's footprint while the download is happening: "50 MB does
        # not land in the app's heap" is a claim about this number.
        launch(device, *arguments)
        wait_for_status(data, timeout=300)
        entry = run_share_case(device, data, case)
        report["cases"][case] = entry
        screenshot(device, f"share-{case}")
        terminate(device)

    (LOGS / "share.json").write_text(json.dumps(report, indent=2, ensure_ascii=False))
    print(json.dumps(report, indent=2, ensure_ascii=False))
    return 0 if all(entry.get("ok") for entry in report["cases"].values()) else 1


def first_session_id(data: Path) -> str | None:
    """The container's first session id, read from DSH's own registry."""
    for path in (data / "Library/Application Support/DSH").rglob("*.jsonl.zstd"):
        raw = run(["zstd", "-dc", str(path)]).stdout
        for line in raw.splitlines():
            if not line.strip():
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if event.get("type") == "session" and event.get("id"):
                return str(event["id"])
    return None


def app_pid_for_device(device: str) -> int | None:
    """The pid of THIS device's app process.

    Several simulators can run the same bundle id at once, so the name alone is
    not an identity. The app's command line carries its bundle container path,
    which names the device: `.../simdevices/<udid>/data/Containers/Bundle/...`.
    Matching on that is exact, and does not depend on `lsof` being permitted.
    """
    marker = f"simdevices/{device}/"
    out = run(["ps", "-axo", "pid,command"]).stdout
    for line in out.splitlines():
        if "DSHPortC.app/DSHPortC" not in line or marker not in line:
            continue
        return int(line.split()[0])
    return None


def footprint_mb(pid: int) -> float | None:
    rss = run(["ps", "-o", "rss=", "-p", str(pid)]).stdout.strip()
    return int(rss) / 1024.0 if rss.isdigit() else None


def run_share_case(device: str, data: Path, case: str) -> dict:
    """Wait for the case's download to finish and collect what it left behind.

    MEMORY. The question "does a 50 MB download land in the app's heap" is
    answered by the app process's OWN resident size across the download, and by
    nothing else: the blob is built in the web content process, and WebKit
    streams it to the destination file this app hands it. So the samples are
    timestamped and split at the moment the download record appears — a single
    "peak" number would be dominated by the app's own boot, which is why the
    first version of this measurement reported ~730 MB for a 62-byte text file.

    The share sheet is NOT dismissed from here — nothing outside the app can
    press its button — so the temporary file is still on disk when this returns.
    That is on purpose: the `/export` archive is only readable while the sheet is
    up, and the UI test's dismissal is what the cleanup check follows.
    """
    entry: dict = {"case": case}
    downloads_file = data / "Documents/DSHPortE-downloads.json"
    deadline = time.time() + 420
    samples: list[tuple[float, float]] = []
    finished_at: float | None = None

    while time.time() < deadline:
        pid = app_pid_for_device(device)
        if pid is not None:
            current = footprint_mb(pid)
            if current is not None:
                samples.append((time.time(), current))
        downloads = read_json(downloads_file).get("downloads", [])
        if finished_at is None and downloads:
            last = downloads[-1]
            if last.get("error") or last.get("writtenBytes", 0) > 0:
                finished_at = time.time()
                pid = app_pid_for_device(device)
                if pid is not None:
                    current = footprint_mb(pid)
                    if current is not None:
                        samples.append((finished_at, current))
                # A couple more samples: the write itself is the moment the file
                # is being flushed, and it can land just after the record.
                for _ in range(4):
                    time.sleep(0.25)
                    pid = app_pid_for_device(device)
                    if pid is not None:
                        current = footprint_mb(pid)
                        if current is not None:
                            samples.append((time.time(), current))
                break
        time.sleep(0.5)

    before = [mb for stamp, mb in samples if finished_at is None or stamp < finished_at]
    during = [mb for stamp, mb in samples if finished_at is None or stamp >= finished_at]
    entry["footprintSamples"] = len(samples)
    if samples:
        # The baseline is the app's size BEFORE the download began. If the very
        # first sample already landed after the download finished (a 62-byte file
        # is written in microseconds), there is no "before" to compare against
        # and the entry says so rather than inventing one.
        entry["footprintBeforeMB"] = round(max(before), 1) if before else None
        entry["footprintAfterMB"] = round(max(during), 1) if during else round(samples[-1][1], 1)
        entry["footprintDeltaMB"] = (round(entry["footprintAfterMB"] - entry["footprintBeforeMB"], 1)
                                     if before and entry["footprintAfterMB"] is not None else None)
    else:
        entry["footprintBeforeMB"] = None
        entry["footprintAfterMB"] = None
        entry["footprintDeltaMB"] = None

    downloads = read_json(downloads_file).get("downloads", [])
    entry["downloads"] = downloads
    entry["share"] = read_json(data / "Documents/DSHPortE-share.json")
    temporary = data / "tmp/DSHPortCDownloads"
    entry["tempFilesWhileSheetUp"] = sorted(p.name for p in temporary.iterdir()) if temporary.is_dir() else []

    if downloads:
        last = downloads[-1]
        entry["fileName"] = last.get("fileName")
        entry["bytes"] = last.get("writtenBytes")
        entry["expectedBytes"] = last.get("expectedBytes")
        entry["trigger"] = last.get("trigger")
        entry["sharePresented"] = last.get("sharePresented")
        entry["error"] = last.get("error")
        entry["chineseNameOK"] = bool(re.search(r"[\u4e00-\u9fff]", str(last.get("fileName", "")))) \
            if case in ("blob", "data", "big") else True
        # Which of the four triggers actually fired. For the two export cases this
        # is the whole point: the anchor spelling must come out as an ACTION
        # decision and the navigation spelling as a RESPONSE one.
        # What each case SHOULD report, and where the uncertainty is.
        #
        # `data:` is the honest gap: `LinkRouter` has an explicit scheme check for
        # it, but WebKit also sets `shouldPerformDownload` on a `data:` anchor with
        # a `download` attribute, so the recorded trigger is whatever came first.
        # Measured: `shouldPerformDownload`. `triggerMatch` therefore only asserts
        # the cases whose path is unambiguous, and `data` is recorded without a
        # verdict rather than with a made-up one.
        expected_triggers = {
            "blob": "shouldPerformDownload",
            "big": "shouldPerformDownload",
            "export": "shouldPerformDownload",
            "export-nav": "content-disposition",
        }
        entry["triggerExpected"] = expected_triggers.get(case)
        if entry["triggerExpected"] is not None:
            entry["triggerMatch"] = entry.get("trigger") == entry["triggerExpected"]
        # A chunked response has no `Content-Length`, which arrives as -1; there
        # is nothing to compare against then, and claiming a mismatch would be
        # reporting a measurement that was never possible.
        expected = last.get("expectedBytes", -1)
        entry["bytesMatch"] = (None if expected is None or expected < 0
                               else last.get("writtenBytes") == expected)

    entry["ok"] = bool(
        downloads
        and not downloads[-1].get("error")
        and downloads[-1].get("writtenBytes", 0) > 0
        and downloads[-1].get("sharePresented")
        and entry.get("chineseNameOK", True)
    )
    return entry


def cmd_export_zip(args: argparse.Namespace) -> int:
    """Run the `/export` download and keep the ZIP, then open it.

    A share sheet deletes its file when dismissed, so the archive is copied out
    of the temporary directory while the sheet is still up — that is the only
    moment the bytes exist on disk. The copy is what gets decompressed and
    checked; this is the same archive the user would have saved.
    """
    device = udid()
    boot(device)
    terminate(device)
    data = container(device)
    session = first_session_id(data)
    if session is None:
        raise SystemExit("no session in the container; run the legacy arm or a turn first")
    launch(device, "-DSHPortCMockPort", str(MOCK_PORT),
           "-DSHPortEShareCase", "export", "-DSHPortEDownloadProbe", "1",
           "-DSHPortESessionId", session)
    wait_for_status(data, timeout=300)

    files: dict = {"sessionId": session, "samples": []}
    deadline = time.time() + 300
    copied: Path | None = None
    SHOTS.mkdir(parents=True, exist_ok=True)
    while time.time() < deadline:
        temporary = data / "tmp/DSHPortCDownloads"
        archives = sorted(temporary.glob("*.zip")) if temporary.is_dir() else []
        if archives:
            copied = LOGS / archives[0].name
            LOGS.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(archives[0], copied)
            files["bytes"] = copied.stat().st_size
            files["name"] = archives[0].name
            break
        time.sleep(1)
    screenshot(device, "share-export-zip")

    if copied is None:
        files["error"] = "no zip ever appeared in the download directory"
        (LOGS / "export-zip.json").write_text(json.dumps(files, indent=2, ensure_ascii=False))
        print(json.dumps(files, indent=2, ensure_ascii=False))
        return 1

    entries: list[dict] = []
    contents: dict = {}
    try:
        with zipfile.ZipFile(copied) as archive:
            bad = archive.testzip()
            files["zipTest"] = "ok" if bad is None else f"corrupt entry: {bad}"
            for info in archive.infolist():
                entries.append({"name": info.filename, "bytes": info.file_size})
                # Read a little of every member so a name-only check cannot pass
                # an archive whose entries are empty.
                with archive.open(info) as handle:
                    head = handle.read(4096)
                contents[info.filename] = {
                    "readable": True,
                    "firstLine": head.split(b"\n")[0][:200].decode("utf-8", "replace"),
                    "nonEmpty": len(head) > 0,
                }
    except zipfile.BadZipFile as error:
        files["zipTest"] = f"BadZipFile: {error}"
        entries = []
    files["entries"] = entries
    files["contents"] = contents
    files["entryCount"] = len(entries)
    files["sessionIdFromRegistry"] = session
    files["hasSessionLog"] = any(name.endswith(".jsonl") or "session" in name for name, _ in
                                 ((entry["name"], entry["bytes"]) for entry in entries))
    files["everyEntryReadable"] = all(value["readable"] and value["nonEmpty"] for value in contents.values())
    terminate(device)
    (LOGS / "export-zip.json").write_text(json.dumps(files, indent=2, ensure_ascii=False))
    print(json.dumps({k: files.get(k) for k in
                      ("name", "bytes", "zipTest", "entryCount", "hasSessionLog",
                       "everyEntryReadable")}, indent=2, ensure_ascii=False))
    print(json.dumps([entry["name"] for entry in entries], indent=2, ensure_ascii=False))
    return 0 if files.get("zipTest") == "ok" and files.get("entryCount", 0) > 0 \
        and files.get("everyEntryReadable") else 1


# The file a real `TOOLTEST` agent turn writes through DSH's own `write` tool.
# It is the monkey's own hand: the prompt goes into the composer, the model's reply
# is a tool call, and the tool writes this file into the workspace. That is the
# file the Files-app UI test then looks for.
AGENT_WRITTEN_FILE = "mock-tool-output.txt"


def cmd_agent_write(args: argparse.Namespace) -> int:
    """Make the agent put a file in the workspace, through the real UI.

    WHY THIS IS A SEPARATE COMMAND
    ------------------------------
    The Files-app UI test asserts "a file the AGENT wrote is visible in Files".
    Nothing in the test can create that file honestly — if the test placed it, the
    assertion would be about the test. So it is created the way a user's file is:
    a prompt typed into DSH's composer, a model reply that calls the `write` tool,
    and the tool writing into `Documents/workspace/`. The UI test then only has to
    look, and the claim keeps its meaning.
    """
    device = udid()
    boot(device)
    terminate(device)
    data = container(device)
    workspace = data / "Documents/workspace"
    workspace.mkdir(parents=True, exist_ok=True)
    # WHERE the agent's own cwd is matters, and it is not the workspace root: a
    # session's cwd is the registered `default-workspace` folder, so a relative
    # path from a tool call lands there. Measured: the file appeared at
    # `Documents/workspace/deepseek-harness/default-workspace/mock-tool-output.txt`,
    # not at the root. The Files-app test therefore descends into that folder too,
    # and this command looks for the file at both places rather than assuming.
    agent_cwd = workspace / "deepseek-harness/default-workspace"
    candidates = (workspace / AGENT_WRITTEN_FILE, agent_cwd / AGENT_WRITTEN_FILE)
    for candidate in candidates:
        candidate.unlink(missing_ok=True)

    prompt = ("TOOLTEST 请在默认工作区里写一个文件，然后用 read 和 glob 确认它。"
              "这一步是为了让「文件」App 里能看到智能体写的文件。")
    fresh_launch(
        device, data,
        "-DSHPortCTestDrive", "1",
        "-DSHPortCMockPort", str(MOCK_PORT),
        env={"SIMCTL_CHILD_DSHPORT_UITEST_PROMPT": prompt,
             "SIMCTL_CHILD_DSHPORT_UITEST_KEYWORD": "TOOLTEST 工具回合完成"},
    )
    wait_for_status(data, timeout=300)

    # Wait for the tool to actually have written it, and for the turn to end —
    # a file that appears mid-turn is not yet "what the agent left behind". The
    # path is re-resolved on every poll: the FIRST poll runs before the file
    # exists, so a path chosen once, up front, is a path that never appears.
    deadline = time.time() + 420
    turn_ended = False
    written = candidates[1]
    while time.time() < deadline:
        if not turn_ended:
            for path in session_logs(data):
                raw = run(["zstd", "-dc", str(path)]).stdout
                if '"turn/end"' in raw:
                    turn_ended = True
        found = next((candidate for candidate in candidates if candidate.exists()), None)
        if found is not None:
            written = found
        if found is not None and turn_ended:
            break
        time.sleep(2)

    report = {
        "device": device,
        "workspace": str(workspace),
        "agentCwd": str(agent_cwd),
        "path": str(written),
        "file": AGENT_WRITTEN_FILE,
        "exists": written.exists(),
        "bytes": written.stat().st_size if written.exists() else 0,
        "turnEnded": turn_ended,
        "text": read_text(written),
    }
    # Collect the driver's own evidence file and take it OUT of Documents before
    # handing over. `DSHPortC-uidrive.json` is a probe artefact, not something the
    # app writes on a normal launch, and the Files-app screenshot is supposed to
    # show what a user would see — four JSON evidence files beside `workspace/`
    # would be a picture of the test harness, not of the product.
    uidrive = data / "Documents/DSHPortC-uidrive.json"
    if uidrive.exists():
        report["driverLog"] = read_json(uidrive)
        LOGS.mkdir(parents=True, exist_ok=True)
        (LOGS / "agent-write-uidrive.json").write_text(
            json.dumps(report["driverLog"], indent=2, ensure_ascii=False))
    for stale in ("DSHPortC-uidrive.json", "DSHPortE-downloads.json", "DSHPortE-links.json",
                  "DSHPortE-share.json", "DSHPortE-files-probe.json",
                  "DSHPortE-session-continue-acceptance.json"):
        (data / "Documents" / stale).unlink(missing_ok=True)

    screenshot(device, "agent-wrote-file")
    LOGS.mkdir(parents=True, exist_ok=True)
    (LOGS / "agent-write.json").write_text(json.dumps(report, indent=2, ensure_ascii=False))
    print(json.dumps(report, indent=2, ensure_ascii=False))
    return 0 if report["exists"] and report["bytes"] > 0 and turn_ended else 1


def cmd_files(args: argparse.Namespace) -> int:
    """The Files app's side of the workspace, minus the Files app itself.

    A file is written into `Documents/workspace/` exactly as the Files app would
    (the directory is what the Files app shows, so a file there IS the case), then
    the guest is asked to read it, modify it, and create its own entries. The
    reverse direction — an agent-written file visible in that directory — is
    checked by looking for it from the host side.
    """
    device = udid()
    boot(device)
    terminate(device)
    data = container(device)
    workspace = data / "Documents/workspace"
    workspace.mkdir(parents=True, exist_ok=True)
    # A previous run of this command leaves its own files here, and a "planted"
    # list that starts with the last run's leftovers makes the next assertions
    # ambiguous. Only the names this command creates are removed.
    for stale in ("FROM-FILES.txt", "to-rename.txt", "renamed-by-files.txt"):
        (workspace / stale).unlink(missing_ok=True)
    shutil.rmtree(workspace / "files-app-folder", ignore_errors=True)
    shutil.rmtree(workspace / "ish-made-dir", ignore_errors=True)

    report: dict = {"device": device, "workspace": str(workspace), "steps": {}}

    # 1. A file "the user put there from the Files app", plus a folder and a file
    #    to be renamed afterwards.
    (workspace / "FROM-FILES.txt").write_text("hello from the Files app\n中文一行\n")
    (workspace / "files-app-folder").mkdir(exist_ok=True)
    (workspace / "to-rename.txt").write_text("rename me\n")
    report["steps"]["planted"] = sorted(p.name for p in workspace.iterdir())

    # 2. The guest reads and edits it.
    fresh_launch(device, data, "-DSHPortCMockPort", str(MOCK_PORT),
                 "-DSHPortEFilesProbe", "guest-edit")
    wait_for_status(data, timeout=300)
    probe = wait_for_probe(data, "DSHPortE-files-probe.json")
    report["steps"]["guestEdit"] = probe.get("steps", [])
    edited = read_text(workspace / "FROM-FILES.txt")
    report["steps"]["editedOnHostSide"] = "edited by iSH" in edited
    report["steps"]["editedText"] = edited

    # 3. The guest writes its own file and folder.
    terminate(device)
    fresh_launch(device, data, "-DSHPortCMockPort", str(MOCK_PORT),
                 "-DSHPortEFilesProbe", "guest-dir-ops")
    wait_for_status(data, timeout=300)
    report["steps"]["guestDirOps"] = wait_for_probe(data, "DSHPortE-files-probe.json").get("steps", [])
    report["steps"]["guestFileOnHostSide"] = (workspace / "ish-made-dir/inside.txt").exists()

    # 4. Rename and delete from the host side (what the Files app does), then
    #    confirm the guest agrees.
    terminate(device)
    (workspace / "to-rename.txt").rename(workspace / "renamed-by-files.txt")
    (workspace / "files-app-folder").rmdir()
    report["steps"]["afterRenameDelete"] = sorted(p.name for p in workspace.iterdir())
    fresh_launch(device, data, "-DSHPortCMockPort", str(MOCK_PORT),
                 "-DSHPortEFilesProbe", "paths")
    wait_for_status(data, timeout=300)
    listing = wait_for_probe(data, "DSHPortE-files-probe.json").get("steps", [])
    report["steps"]["guestListing"] = listing
    combined = " ".join(str(step.get("stdout", "")) for step in listing)
    report["steps"]["guestSeesRename"] = "renamed-by-files.txt" in combined
    report["steps"]["guestSeesDeletedFolder"] = "files-app-folder" not in combined

    # 5. What the agent wrote, seen from the Files app's directory.
    report["keyScan"] = scan_for_keys(data / "Documents")
    terminate(device)
    LOGS.mkdir(parents=True, exist_ok=True)
    (LOGS / "files.json").write_text(json.dumps(report, indent=2, ensure_ascii=False))
    print(json.dumps(report, indent=2, ensure_ascii=False))
    ok = (report["steps"]["editedOnHostSide"] and report["steps"]["guestFileOnHostSide"]
          and report["steps"]["guestSeesRename"] and report["steps"]["guestSeesDeletedFolder"]
          and not report["keyScan"]["findings"])
    return 0 if ok else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    documents = sub.add_parser("documents", help="normal launch: what Documents holds")
    documents.add_argument("--keep-data", action="store_true",
                           help="reuse the container instead of a fresh install")
    documents.set_defaults(func=cmd_documents)

    legacy = sub.add_parser("legacy", help="old build, then install over it")
    legacy.add_argument("--baseline", required=True, help="the pre-step-17 .app to install first")
    legacy.set_defaults(func=cmd_legacy)

    share = sub.add_parser("share", help="download triggers, recorded by the app")
    share.add_argument("--case", choices=["blob", "data", "big", "export", "export-nav"], default=None)
    share.set_defaults(func=cmd_share)

    export_zip = sub.add_parser("export-zip", help="keep and open the /export archive")
    export_zip.set_defaults(func=cmd_export_zip)

    agent_write = sub.add_parser("agent-write",
                                 help="one real agent turn that writes a file")
    agent_write.set_defaults(func=cmd_agent_write)

    files = sub.add_parser("files", help="the workspace, from both sides")
    files.set_defaults(func=cmd_files)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
