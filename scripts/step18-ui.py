#!/usr/bin/env python3
"""Drive the app's own page one step at a time, and record what each step measured.

The sweep has to visit about twenty screens and take the same four measurements on
each. Doing that by hand in a shell is how a sweep ends up measuring different
things on different screens; so a screen is described as a list of ops, the ops run
through the probe's file channel, and the audit is taken at the end of the list.

    python3 scripts/step18-ui.py --name 03-composer-row \
        --op 'click:[aria-label="选择工作区"]' \
        --op 'settle:800' \
        --audit logs/step18/before-03-composer-row.json \
        --shot before-03-composer-row

Opcodes
    click:<selector>     a DOM `click()`. Good enough for React handlers, and NOT
                         claimed to be a real touch: the states that need fingers
                         are re-verified by the XCUITest target.
    type:<text>          insert through the composer's real paste path
    key:<Enter|Escape>   a keydown/keyup pair on the focused element
    scroll:<selector>:<top>  set scrollTop on the scroller (0 or a number)
    eval:<js>            run arbitrary JavaScript, for the odd one-off question
    settle:<ms>          wait

Every op's return value is printed, so a click that silently hit nothing is
visible in the log instead of leaving a screenshot of the wrong screen.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import device_pick as pick  # noqa: E402
import step18_probe  # noqa: E402


CLICK_JS = """
(function (selector) {
  const el = document.querySelector(selector);
  if (el === null) return 'missing:' + selector;
  const rect = el.getBoundingClientRect();
  const style = getComputedStyle(el);
  if (style.display === 'none' || style.visibility === 'hidden' || parseFloat(style.opacity) === 0) {
    return 'invisible:' + selector;
  }
  el.click();
  return 'clicked:' + Math.round(rect.width) + 'x' + Math.round(rect.height)
    + '@' + Math.round(rect.left) + ',' + Math.round(rect.top);
})
"""

TYPE_JS = """
(function (text) {
  const box = document.querySelector('[data-composer-input]')
    || document.querySelector('[contenteditable="true"]');
  if (box === null) return 'no-composer';
  box.focus();
  const selection = window.getSelection();
  const range = document.createRange();
  range.selectNodeContents(box);
  range.collapse(false);
  selection.removeAllRanges();
  selection.addRange(range);
  try {
    const clipboard = new DataTransfer();
    clipboard.setData('text/plain', text);
    const paste = new ClipboardEvent('paste', {
      bubbles: true, cancelable: true, clipboardData: clipboard,
    });
    box.dispatchEvent(paste);
    if (paste.defaultPrevented) return 'paste|len=' + (box.innerText || '').length;
  } catch (error) { /* not constructible */ }
  document.execCommand('insertText', false, text);
  return 'execCommand|len=' + (box.innerText || '').length;
})
"""

KEY_JS = """
(function (key) {
  const el = document.activeElement || document.querySelector('[data-composer-input]') || document.body;
  const code = key === 'Enter' ? 'Enter' : (key === 'Escape' ? 'Escape' : 'Tab');
  const init = { key: key, code: code, bubbles: true, cancelable: true, composed: true };
  el.dispatchEvent(new KeyboardEvent('keydown', init));
  el.dispatchEvent(new KeyboardEvent('keyup', init));
  return 'key:' + key + ' on ' + el.tagName;
})
"""

SCROLL_JS = """
(function (selector, top) {
  const el = document.querySelector(selector);
  if (el === null) return 'missing:' + selector;
  el.scrollTop = Number(top);
  return 'scrollTop=' + Math.round(el.scrollTop) + '/' + Math.round(el.scrollHeight);
})
"""


def op_to_script(op: str) -> tuple[str, bool]:
    """(javascript, is_plain_expression) for one op."""
    if op.startswith("click:"):
        selector = json.dumps(op[len("click:"):])
        return f"({CLICK_JS})({selector})", False
    if op.startswith("type:"):
        text = json.dumps(op[len("type:"):])
        return f"({TYPE_JS})({text})", False
    if op.startswith("key:"):
        key = json.dumps(op[len("key:"):])
        return f"({KEY_JS})({key})", False
    if op.startswith("scroll:"):
        _, selector, top = op.split(":", 2)
        return f"({SCROLL_JS})({json.dumps(selector)}, {json.dumps(top)})", False
    if op.startswith("eval:"):
        return op[len("eval:"):], False
    raise SystemExit(f"unknown op: {op}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--name", required=True)
    parser.add_argument("--op", action="append", default=[])
    parser.add_argument("--audit", default=None, help="write the audit JSON here")
    parser.add_argument("--shot", default=None, help="screenshot name (no extension)")
    parser.add_argument("--device", default="phone-polish")
    parser.add_argument("--timeout", type=float, default=60.0)
    parser.add_argument("--settle", type=float, default=0.0, help="extra wait before the audit, seconds")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    import os
    os.environ["DSHPORTE_DEVICE"] = args.device

    results = []
    for op in args.op:
        if op.startswith("settle:"):
            time.sleep(float(op.split(":", 1)[1]) / 1000.0)
            results.append({"op": op, "value": "waited"})
            continue
        script, _ = op_to_script(op)
        reply = step18_probe.ask(script, timeout=args.timeout)
        value = reply.get("value")
        results.append({"op": op, "ok": reply.get("ok"), "value": value})
        if not args.quiet:
            print(f"  {op[:70]:<72} -> {str(value)[:80]}")

    if args.settle:
        time.sleep(args.settle)

    summary: dict = {"name": args.name, "ops": results}
    if args.audit:
        payload = step18_probe.ask(step18_probe.builtin_audit(), timeout=args.timeout)
        value = payload.get("value")
        parsed = json.loads(value) if isinstance(value, str) else value
        target = Path(args.audit)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(parsed, ensure_ascii=False, indent=2), encoding="utf-8")
        counts = (parsed or {}).get("counts", {})
        summary["counts"] = counts
        print(f"  audit -> {target}  {counts}")

    if args.shot:
        import subprocess
        env = {**pick.ENV}
        shot = subprocess.run(
            [str(Path(__file__).resolve().parent / "step18-shot.sh"), args.shot],
            capture_output=True, text=True, env=env, timeout=120,
        )
        summary["shot"] = (shot.stdout or shot.stderr).strip()
        print(f"  shot -> {summary['shot']}")

    print(json.dumps(summary, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
