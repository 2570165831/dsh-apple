#!/usr/bin/env python3
"""Run step 18's sweep over a fixed list of screens, before or after.

Every screen is described as a list of ops driven through the probe's file
channel, so the same sequence runs on the polish-on and polish-off builds and the
two columns of the report answer the same question. Screens that need real
fingers are covered separately by the XCUITest target — this matrix is the
DOM-side half.

    python3 scripts/step18-matrix.py --phase before
    python3 scripts/step18-matrix.py --phase after

Each screen writes `logs/step18/<phase>-<name>.json` and
`screenshots/step18/<phase>-<name>.png`.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import device_pick as pick  # noqa: E402
import step18_launch  # noqa: E402
import step18_probe  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
LOGS = ROOT / "logs" / "step18"
SWEEP = (Path(__file__).resolve().parent / "step18-sweep.js").read_text(encoding="utf-8")

TAP = """
(function (selector) {
  const el = document.querySelector(selector);
  if (el === null) return 'missing:' + selector;
  const r = el.getBoundingClientRect();
  const init = {
    bubbles: true, cancelable: true, composed: true, button: 0, buttons: 1,
    pointerId: 41, pointerType: 'touch', isPrimary: true,
    clientX: r.left + r.width / 2, clientY: r.top + r.height / 2,
  };
  for (const [type, Ctor] of [['pointerdown', PointerEvent], ['mousedown', MouseEvent],
                              ['pointerup', PointerEvent], ['mouseup', MouseEvent],
                              ['click', MouseEvent]]) {
    el.dispatchEvent(new Ctor(type, init));
  }
  return 'tapped:' + Math.round(r.width) + 'x' + Math.round(r.height);
})
"""

TAP_BY_TEXT = """
(function (text) {
  const el = Array.from(document.querySelectorAll('button, [role="menuitem"], [role="tab"], [role="option"]'))
    .find((b) => (b.innerText || '').indexOf(text) >= 0);
  if (el === undefined) return 'missing:' + text;
  const r = el.getBoundingClientRect();
  const init = {
    bubbles: true, cancelable: true, composed: true, button: 0, buttons: 1,
    pointerId: 42, pointerType: 'touch', isPrimary: true,
    clientX: r.left + r.width / 2, clientY: r.top + r.height / 2,
  };
  for (const [type, Ctor] of [['pointerdown', PointerEvent], ['mousedown', MouseEvent],
                              ['pointerup', PointerEvent], ['mouseup', MouseEvent],
                              ['click', MouseEvent]]) {
    el.dispatchEvent(new Ctor(type, init));
  }
  return 'tapped-by-text:' + text;
})
"""

CLOSE_ALL = """
(function () {
  // Leave whatever is open before the next screen: a menu, a dialog, the
  // settings overlay. Clicking the first Escape-equivalent DSH has, then any
  // visible close button, then blurring, is enough and is what a person does.
  let closed = 0;
  for (const sel of ['[role="dialog"] button[aria-label="关闭"]',
                     '[data-approval-key] button',
                     '[class*="_close_"]']) {
    const el = document.querySelector(sel);
    if (el !== null && (el.getAttribute('aria-label') || '').indexOf('关闭') >= 0) {
      el.click(); closed += 1; break;
    }
  }
  document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
  document.dispatchEvent(new KeyboardEvent('keyup', { key: 'Escape', bubbles: true }));
  const composer = document.querySelector('[data-composer-input]');
  if (composer !== null) {
    composer.focus();
    document.execCommand('selectAll', false, null);
    document.execCommand('delete', false, null);
  }
  for (const overlay of document.querySelectorAll('[class*="_overlay_"]')) {
    const close = overlay.querySelector('button[aria-label="关闭"]');
    if (close !== null) { close.click(); closed += 1; break; }
  }
  return 'closed:' + closed;
})
"""

TYPE_AND_SEND = """
(function (text) {
  const box = document.querySelector('[data-composer-input]');
  if (box === null) return 'no-composer';
  box.focus();
  try {
    const clipboard = new DataTransfer();
    clipboard.setData('text/plain', text);
    const paste = new ClipboardEvent('paste', { bubbles: true, cancelable: true, clipboardData: clipboard });
    box.dispatchEvent(paste);
    if (!paste.defaultPrevented) document.execCommand('insertText', false, text);
  } catch (error) { document.execCommand('insertText', false, text); }
  const send = Array.from(document.querySelectorAll('button'))
    .find((b) => (b.getAttribute('aria-label') || '').indexOf('发送消息') === 0);
  if (send === undefined) return 'no-send';
  if (send.disabled) return 'send-disabled';
  send.click();
  return 'sent';
})
"""

WAIT_IDLE = """
(function () {
  return JSON.stringify({
    running: document.querySelectorAll('[data-chat-running]').length,
    items: document.querySelectorAll('[data-chat-flow-kind]').length,
  });
})()
"""


def ask(script: str, timeout: float = 90.0) -> object:
    payload = step18_probe.ask(script, timeout=timeout)
    value = payload.get("value")
    if isinstance(value, str):
        try:
            return json.loads(value)
        except json.JSONDecodeError:
            return value
    return value


def tap(selector: str) -> object:
    return ask(f"({TAP})({json.dumps(selector)})")


def tap_text(text: str) -> object:
    return ask(f"({TAP_BY_TEXT})({json.dumps(text)})")


def close_all() -> object:
    return ask(CLOSE_ALL)


def screenshot(name: str) -> str:
    env = {**pick.ENV}
    out = subprocess.run(
        [str(Path(__file__).resolve().parent / "step18-shot.sh"), name],
        capture_output=True, text=True, env=env, timeout=120,
    )
    return (out.stdout or out.stderr).strip().splitlines()[-1] if (out.stdout or out.stderr) else ""


def wait_for_page(timeout: float = 180.0) -> bool:
    deadline = time.time() + timeout
    container = pick.data_container(pick.device_udid())
    while time.time() < deadline:
        value = step18_launch.ask_quietly(container, "document.querySelector('[data-composer-input]') !== null")
        if value is True:
            return True
        time.sleep(1.0)
    return False


def launch(polish: bool) -> None:
    udid = pick.device_udid()
    pick.simctl("install", udid, str(pick.APP_PATH), check=True)
    pick.simctl("terminate", udid, pick.BUNDLE_ID)
    time.sleep(1.0)
    args = [
        "xcrun", "simctl", "--set", str(pick.SIMSET), "launch", udid, pick.BUNDLE_ID,
        "-DSHPortEStep18", "1", "-DSHPortCMockPort", "19718",
    ]
    args += ["-DSHPortEStep18PolishOff", "0" if polish else "1"]
    out = subprocess.run(args, capture_output=True, text=True, env=pick.ENV, timeout=120)
    if out.returncode != 0:
        raise SystemExit(f"launch failed: {out.stderr.strip()}")
    if not wait_for_page():
        raise SystemExit("the composer never appeared")
    if ask("document.getElementById('dsh-mobile-polish') !== null") != polish:
        raise SystemExit("the page injection does not match the requested phase")


def seed_conversation() -> None:
    """Make sure there is a conversation with a finished turn on screen.

    Several screens in the matrix (message actions, the status line, the
    trajectory) only exist after a turn, so every phase starts the same way.
    """
    state = ask(WAIT_IDLE)
    if isinstance(state, dict) and state.get("items", 0) >= 3:
        # Already has a turn; make sure it is not mid-stream.
        for _ in range(30):
            state = ask(WAIT_IDLE)
            if isinstance(state, dict) and state.get("running", 0) == 0:
                return
            time.sleep(1.0)
        return
    ask(f"({TYPE_AND_SEND})('STREAMTEST 逐屏走查')")
    for _ in range(40):
        time.sleep(1.5)
        state = ask(WAIT_IDLE)
        if isinstance(state, dict) and state.get("running", 0) == 0:
            return


def run_matrix(phase: str, tag: str = "") -> list[dict]:
    LOGS.mkdir(parents=True, exist_ok=True)
    results: list[dict] = []
    prefix = phase + ("-" + tag if tag else "")

    def capture(name: str, note: str = "") -> None:
        payload = ask(SWEEP)
        payload["stateWitness"] = ask("JSON.stringify({polish:!!document.getElementById('dsh-mobile-polish'),"
            "sidebar:document.querySelector('[data-sidebar-collapsed]')?.getAttribute('data-sidebar-collapsed'),"
            "dialogs:document.querySelectorAll('[role=dialog]').length,"
            "tabs:Array.from(document.querySelectorAll('[role=tab]')).map(e=>({text:e.innerText,selected:e.getAttribute('aria-selected')})),"
            "menus:Array.from(document.querySelectorAll('[role=menu],[role=listbox]')).map(e=>e.innerText.slice(0,200))})")
        target = LOGS / f"{prefix}-{name}.json"
        target.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        counts = (payload or {}).get("counts", {})
        shot = screenshot(f"{prefix}-{name}")
        results.append({"screen": name, "phase": phase, "counts": counts, "shot": shot, "note": note, "stateWitness": payload.get("stateWitness")})
        print(f"  {phase}-{name:<28} small={counts.get('smallHit')!s:<3} "
              f"off={counts.get('offScreen')!s:<3} cut={counts.get('clipped')!s:<3} "
              f"hoverHidden={counts.get('rowActionsHidden')!s:<3} pills={counts.get('statPillsClipped')}")

    # 01 hero, no conversation chrome open
    capture("01-hero")

    # 02 session list
    close_all(); time.sleep(0.6)
    tap('[aria-label="打开侧边栏"]'); time.sleep(0.9)
    capture("02-sidebar")

    # 03 session search, with the keyboard up
    tap('[aria-label="搜索会话"]'); time.sleep(1.1)
    capture("03-search")
    close_all(); time.sleep(0.5)
    tap('[aria-label="收起侧边栏"]'); time.sleep(0.8)

    # 04 workspace menu
    close_all(); time.sleep(0.6)
    tap('[aria-label="选择工作区"]'); time.sleep(0.9)
    capture("04-menu-workspace")
    close_all(); time.sleep(0.5)

    # 05 permission menu
    tap('[aria-label^="访问模式"]'); time.sleep(0.9)
    capture("05-menu-permission")
    close_all(); time.sleep(0.5)

    # 06 model menu
    tap('[aria-label^="选择模型"]'); time.sleep(0.9)
    capture("06-menu-model")
    close_all(); time.sleep(0.5)

    # 07 the + menu, keyboard up
    ask("(function(){const b=document.querySelector('[data-composer-input]');if(b)b.focus();return 1})()")
    time.sleep(2.0)
    tap('[aria-label="添加文件或调用指令"]'); time.sleep(1.0)
    capture("07-menu-plus-keyboard")
    close_all(); time.sleep(0.5)

    # 08 slash menu
    ask("(function(){const b=document.querySelector('[data-composer-input]');b.focus();"
        "document.execCommand('selectAll',false,null);document.execCommand('delete',false,null);"
        "document.execCommand('insertText',false,'/');return 1})()")
    time.sleep(1.1)
    capture("08-menu-slash")
    close_all(); time.sleep(0.5)

    # 09 @ menu
    ask("(function(){const b=document.querySelector('[data-composer-input]');b.focus();"
        "document.execCommand('selectAll',false,null);document.execCommand('delete',false,null);"
        "document.execCommand('insertText',false,'@');return 1})()")
    time.sleep(1.1)
    capture("09-menu-at")
    close_all(); time.sleep(0.8)

    # 10 the conversation, status line and message actions
    seed_conversation()
    ask("(function(){const b=document.querySelector('[data-composer-input]');if(b)b.blur();return 1})()")
    time.sleep(0.8)
    capture("10-conversation")

    # 11 the trajectory tab
    tap_text("轨迹"); time.sleep(1.2)
    capture("11-trajectory")
    tap_text("对话"); time.sleep(1.0)

    # 12 the right panel
    tap('[data-sidebar-right-expand]'); time.sleep(1.2)
    capture("12-right-panel")
    tap('[data-sidebar-right-toggle]'); time.sleep(0.8)

    # 13-16 the four settings pages
    close_all(); time.sleep(0.6)
    tap('[aria-label="账号菜单"]'); time.sleep(0.9)
    tap_text("设置"); time.sleep(1.4)
    for index, name in enumerate(["13-settings-general", "14-settings-models",
                                 "15-settings-plugins", "16-settings-presets"], start=1):
        ask(f"(function(){{const d=document.querySelector('[role=\"dialog\"]');"
            f"if(d===null)return 0;const bs=Array.from(d.querySelectorAll('nav button'));"
            f"if(bs[{index - 1}])bs[{index - 1}].click();return 1}})()")
        time.sleep(1.1)
        capture(name)
    close_all(); time.sleep(0.8)

    return results


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--phase", required=True, choices=["before", "after"])
    parser.add_argument("--device", choices=["phone-polish"], default="phone-polish")
    parser.add_argument("--tag", default="")
    parser.add_argument("--app-path", type=Path, default=pick.APP_PATH)
    args = parser.parse_args()

    os.environ["DSHPORTE_DEVICE"] = args.device
    pick.APP_PATH = args.app_path.resolve()
    pick.boot(pick.device_udid())

    print(f"== {args.phase}: launching with polish {'on' if args.phase == 'after' else 'off'}")
    launch(polish=args.phase == "after")
    results = run_matrix(args.phase, args.tag)

    out = LOGS / f"{args.phase}{'-' + args.tag if args.tag else ''}-matrix.json"
    out.write_text(json.dumps({
        "phase": args.phase,
        "device": pick.name(),
        "polish": args.phase == "after",
        "screens": results,
    }, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"== wrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
