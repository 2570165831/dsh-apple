#!/usr/bin/env python3
"""Step 21's DOM measurements, one command per item the task names.

    python3 scripts/step21-probe.py --phase before --shots screenshots/step21
    python3 scripts/step21-probe.py --phase after  --shots screenshots/step21

Each sub-command answers one line of the task and writes `logs/step21/<phase>-<name>.json`:

    model       item 1 — is the composer's model selector showing its name, and
                how wide is everything in the row it lives in
    hint        item 3 — every visible string in the page that mentions a
                keyboard chord, plus the composer placeholder in each state
    touch       items 5 and 7 — the four small targets the task names by size,
                measured where they actually are
    narrow      item 7 — the trajectory layout in the 122 pt column that appears
                with the drawer open, including "收起所有调用"
    launch      item 8 — what the boot screen paints and when the web view
                replaces it

The same script runs before and after, so the report's two columns answer the
same question. Anything the phone cannot reach by a script is left to the
XCUITest target (`app/DSHPortCUITests/Step21TouchTests.swift`).

WHY A FILE CHANNEL: it reuses step 18's probe (`Step18Probe`), which is already
the app's only host↔page seam and is gated on `-DSHPortEStep18 1`. A second
channel would be a second thing to keep working.
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
import step18_probe as probe  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
LOGS = ROOT / "logs" / "step21"

# ---------------------------------------------------------------- page scripts

# ITEM 1. The model selector, and the row it sits in.
#
# Reported: the label is 0 pt wide and only the icon shows. The page's own
# `data-model-compact` switch is what does that, and the report has to say WHY
# it is on, so this records the arithmetic `observeControlRow` uses rather than
# just the outcome.
MODEL = r"""
(function () {
  const row = document.querySelector('[data-composer-card] [class*="_row"]');
  if (row === null) return JSON.stringify({ found: false });
  const box = document.querySelector('[data-composer-card] button[aria-label^="选择模型"]');
  const r = (n) => { const b = n.getBoundingClientRect();
    return { x: Math.round(b.left), right: Math.round(b.right), w: Math.round(b.width), h: Math.round(b.height) }; };
  const style = getComputedStyle(row);
  const widths = Array.from(row.children, (c) => c.getBoundingClientRect().width).filter((w) => w > 0);
  const needed = widths.reduce((a, b) => a + b, 0) + Math.max(0, widths.length - 1) * parseFloat(style.columnGap);
  const label = box === null ? null : box.querySelector('[class*="triggerLabel"]');
  const effort = box === null ? null : box.querySelector('[class*="triggerEffort"]');
  const icon = box === null ? null : box.querySelector('[class*="triggerIcon"]');
  const send = document.querySelector('[data-composer-card] button[class*="primary"]');
  const out = {
    found: true,
    compact: row.hasAttribute('data-model-compact'),
    row: { ...r(row), avail: Math.round(row.getBoundingClientRect().width - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight)),
           needed: Math.round(needed), gap: style.columnGap, wrap: style.flexWrap, height: Math.round(row.getBoundingClientRect().height) },
    box: box === null ? null : r(box),
    aria: box === null ? null : box.getAttribute('aria-label'),
    label: label === null ? null : { ...r(label), text: label.innerText,
      scrollWidth: label.scrollWidth, clientWidth: label.clientWidth,
      clipped: label.scrollWidth > label.clientWidth + 1, display: getComputedStyle(label).display },
    effort: effort === null ? null : { ...r(effort), text: effort.innerText, display: getComputedStyle(effort).display },
    icon: icon === null ? null : { display: getComputedStyle(icon).display, w: Math.round(icon.getBoundingClientRect().width) },
    send: send === null ? null : r(send),
    // The one number the task names: the send button must not be squeezed.
    sendOverlap: (effort === null || send === null) ? null
      : Math.round(effort.getBoundingClientRect().right - send.getBoundingClientRect().left),
    viewportWidth: window.innerWidth,
    children: Array.from(row.children).map((c) => ({
      cls: (c.className || '').toString().slice(0, 28), ...r(c),
    })),
  };
  return JSON.stringify(out);
})()
"""

# ITEM 3. Any string in the page that names a keyboard chord.
#
# Walks text nodes rather than `innerText` of containers, because the hint the
# task reports is painted by a CSS `::after` whose `content` is a custom
# property — that is invisible to innerText, so the property is read too.
HINT = r"""
(function () {
  const found = [];
  const chord = /Cmd|Ctrl|\u2318|\u2303|Enter|Shift|Alt|Opt|\u2325/i;
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  let node;
  while ((node = walker.nextNode()) !== null) {
    const text = (node.nodeValue || '').trim();
    if (text === '' || !chord.test(text)) continue;
    const parent = node.parentElement;
    if (parent === null) continue;
    const style = getComputedStyle(parent);
    if (style.display === 'none' || style.visibility === 'hidden') continue;
    const rect = parent.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) continue;
    found.push({ text: text.slice(0, 120), tag: parent.tagName,
                 cls: (parent.className || '').toString().slice(0, 32),
                 aria: parent.getAttribute('aria-label'),
                 w: Math.round(rect.width), h: Math.round(rect.height),
                 top: Math.round(rect.top) });
  }
  // The hint the editor paints through ::after, which has no text node at all.
  const painted = [];
  for (const el of document.querySelectorAll('[data-composer-input], [aria-label]')) {
    const after = getComputedStyle(el, '::after');
    const content = after.content;
    if (content === 'none' || content === 'normal' || content === '' || content === '""') continue;
    if (!chord.test(content)) continue;
    painted.push({ tag: el.tagName, content: content.slice(0, 120),
                   aria: el.getAttribute('aria-label') });
  }
  const input = document.querySelector('[data-composer-input]');
  return JSON.stringify({
    visibleChordStrings: found,
    paintedChordHints: painted,
    placeholder: input === null ? null : input.getAttribute('data-placeholder'),
    placeholderNode: (document.querySelector('[data-composer-placeholder]') || {}).innerText || null,
    hintVariable: input === null ? null : (getComputedStyle(input).getPropertyValue('--dsh-composer-hint') || null),
  });
})()
"""

# ITEM 5 and the four names it gives. Measured by the label the page itself uses,
# so the numbers are about the same control in both columns.
TOUCH = r"""
(function () {
  const r = (n) => { const b = n.getBoundingClientRect();
    return { w: Math.round(b.width * 10) / 10, h: Math.round(b.height * 10) / 10,
             x: Math.round(b.left), y: Math.round(b.top), visible: b.width > 0 && b.height > 0 }; };
  const byPlaceholder = (needle) => Array.from(document.querySelectorAll('input'))
    .find((i) => ((i.placeholder || '') + (i.getAttribute('aria-label') || '')).indexOf(needle) >= 0) || null;
  const sessionSearch = byPlaceholder('搜索会话');
  const trajectorySearch = byPlaceholder('搜索轨迹');
  const requestBadge = Array.from(document.querySelectorAll('[data-trajectory-scroll] button'))
    .find((b) => ((b.getAttribute('aria-label') || '') + (b.innerText || '')).indexOf('请求') >= 0) || null;
  const targets = {
    sessionSearch: sessionSearch === null ? null
      : { ...r(sessionSearch), placeholder: sessionSearch.placeholder || null,
          aria: sessionSearch.getAttribute('aria-label') },
    trajectorySearch: trajectorySearch === null ? null
      : { ...r(trajectorySearch), placeholder: trajectorySearch.placeholder || null,
          aria: trajectorySearch.getAttribute('aria-label') },
    requestBadge: requestBadge === null ? null
      : { ...r(requestBadge), aria: requestBadge.getAttribute('aria-label'),
          text: (requestBadge.innerText || '').trim().slice(0, 20) },
  };
  for (const el of [sessionSearch, trajectorySearch, requestBadge]) {
    if (el === null) continue;
    // The size a finger gets, which is what the 44 pt rule is about: the painted
    // box plus whatever hit overlay this build adds.
    const after = getComputedStyle(el, '::after');
    const key = el === sessionSearch ? 'sessionSearch' : el === trajectorySearch ? 'trajectorySearch' : 'requestBadge';
    targets[key].hitOverlay = after.content === 'none' || after.content === 'normal' ? null
      : { w: after.width, h: after.height };
  }
  return JSON.stringify(targets);
})()
"""

# ITEM 7. The trajectory at 122 pt: the column that exists only with the drawer
# open.
#
# REPORT-18 recorded "收起所有调用" 34 pt past the right edge in exactly this
# state and then measured its final matrix with the drawer CLOSED, so the number
# could not speak to it. This walks every visible box in the trajectory and
# reports the ones that escape the viewport, which is the same question.
NARROW = r"""
(function () {
  const vw = window.innerWidth;
  const vv = window.visualViewport;
  const top = vv === null ? 0 : Math.round(vv.offsetTop);
  const bottom = top + (vv === null ? window.innerHeight : Math.round(vv.height));
  const r = (n) => { const b = n.getBoundingClientRect();
    return { left: Math.round(b.left * 10) / 10, right: Math.round(b.right * 10) / 10,
             top: Math.round(b.top * 10) / 10, bottom: Math.round(b.bottom * 10) / 10,
             w: Math.round(b.width * 10) / 10, h: Math.round(b.height * 10) / 10 }; };
  const visible = (el) => { const s = getComputedStyle(el);
    if (s.display === 'none' || s.visibility === 'hidden' || parseFloat(s.opacity) === 0) return false;
    const b = el.getBoundingClientRect(); return b.width > 0 && b.height > 0; };
  // The column, from the page's own frame. With the drawer open this is the
  // number that makes the panel narrow.
  const frame = document.querySelector('[class*="_frame"]');
  const center = document.querySelector('[class*="_centerCol"]');
  const scroller = document.querySelector('[data-trajectory-scroll]');
  const overflow = [];
  const named = [];
  const scan = (root) => {
    for (const el of root.querySelectorAll('*')) {
      if (!visible(el)) continue;
      const b = el.getBoundingClientRect();
      const over = Math.round((b.right - vw) * 10) / 10;
      if (over > 0.5) {
        const text = (el.innerText || '').replace(/\s+/g, ' ').trim().slice(0, 40);
        // TWO DIFFERENT FACTS, and REPORT-18 already learned to keep them apart
        // (its audit counts an `overflow: hidden` ancestor as a clipping one, and
        // reports those as clipped text rather than as escaping controls):
        //
        //   clippedBy  — an ancestor with overflow-x hidden/clip cuts this box at
        //                that ancestor's edge. What a finger sees is the ancestor's
        //                width; the box's own rect is simply wider than the screen
        //                because the text inside it does not wrap. This is DSH's
        //                own one-line preview in the trajectory table.
        //   scrollable — an ancestor can be swiped to reach it.
        //
        // Only a box that has NEITHER is a control that has left the screen.
        const ancestry = (() => { let n = el.parentElement, d = 0, clipped = null, scrolls = false;
          while (n !== null && d < 14) {
            const s = getComputedStyle(n);
            if (s.overflowX === 'auto' || s.overflowX === 'scroll') { scrolls = true; }
            if (clipped === null && (s.overflowX === 'hidden' || s.overflowX === 'clip')) {
              clipped = { tag: n.tagName, w: Math.round(n.getBoundingClientRect().width * 10) / 10,
                          right: Math.round(n.getBoundingClientRect().right * 10) / 10 };
            }
            n = n.parentElement; d += 1;
          }
          return { clippedBy: clipped, scrollable: scrolls }; })();
        const row = { el: el.tagName + ((el.className || '').toString() ? '.' + (el.className || '').toString().slice(0, 24) : ''),
                      over: over, ...r(el), text: text,
                      insideScroller: scroller !== null && scroller.contains(el),
                      ...ancestry };
        if (overflow.length < 40) overflow.push(row);
      }
      const label = (el.getAttribute('aria-label') || '') + (el.innerText || '');
      if (/收起所有调用|展开所有调用|请求 #/.test(label) && !named.some((n) => n.label === label.slice(0, 30))) {
        named.push({ label: label.replace(/\s+/g, ' ').trim().slice(0, 30), ...r(el),
                     overRight: Math.round((b.right - vw) * 10) / 10 });
      }
    }
  };
  if (document.body !== null) scan(document.body);
  const panelWidth = (el) => el === null ? null : Math.round(el.getBoundingClientRect().width);
  return JSON.stringify({
    viewport: { innerWidth: vw, innerHeight: window.innerHeight, vvTop: top, vvBottom: bottom },
    columns: {
      frame: frame === null ? null : getComputedStyle(frame).gridTemplateColumns,
      frameWidth: panelWidth(frame), center: panelWidth(center),
      scroller: panelWidth(scroller),
    },
    drawerOpen: document.documentElement.hasAttribute('data-dsh-rail-open')
      || (frame !== null && !frame.hasAttribute('data-sidebar-collapsed')),
    namedControls: named,
    overflowCount: overflow.length,
    // The number that matters: boxes outside the viewport that no ancestor clips
    // and no ancestor lets you scroll to.
    escapingCount: overflow.filter((o) => o.clippedBy === null && o.scrollable === false).length,
    clippedCount: overflow.filter((o) => o.clippedBy !== null).length,
    overflow: overflow,
    docHorizontalOverflow: document.documentElement.scrollWidth > document.documentElement.clientWidth,
  });
})()
"""

# ITEM 8. What the boot screen is, and what replaced it.
LAUNCH = r"""
(function () {
  const boot = document.querySelector('[data-dsh-boot]');
  const root = document.querySelector('#root');
  const body = document.body;
  const ids = ['dsh-mobile-polish', 'dsh-mobile-tuning'];
  const styles = ids.map((id) => ({ id: id, present: document.getElementById(id) !== null }));
  return JSON.stringify({
    hasBootScreen: boot !== null,
    bootText: boot === null ? null : (boot.innerText || '').replace(/\s+/g, ' ').trim().slice(0, 120),
    rootChildren: root === null ? null : root.childElementCount,
    bodyBackground: body === null ? null : getComputedStyle(body).backgroundColor,
    htmlBackground: getComputedStyle(document.documentElement).backgroundColor,
    styles: styles,
    composerPresent: document.querySelector('[data-composer-input]') !== null,
    readyAt: Date.now(),
  });
})()
"""

SCRIPTS = {"model": MODEL, "hint": HINT, "touch": TOUCH, "narrow": NARROW, "launch": LAUNCH}

# This step's own mock port. 19716 belongs to another checkout and 19700/19717/
# 19718 were steps 11/17/18's; reusing one of those would make a green run mean
# somebody else's server answered.
MOCK_PORT = "19721"


def launch(device: str, port: str = MOCK_PORT, extra: list[str] | None = None,
           install: bool = True) -> None:
    """Install and launch with step 18's probe on, so this script can ask questions."""
    os.environ["DSHPORTE_DEVICE"] = device
    udid = pick.device_udid()
    pick.boot(udid)
    if install:
        pick.simctl("install", udid, str(pick.APP_PATH), check=True)
    pick.simctl("terminate", udid, pick.BUNDLE_ID)
    time.sleep(1.0)
    args = ["xcrun", "simctl", *pick.set_arguments(), "launch", udid, pick.BUNDLE_ID,
            "-DSHPortEStep18", "1", "-DSHPortCMockPort", port]
    args += extra or []
    out = subprocess.run(args, capture_output=True, text=True, env=pick.ENV, timeout=120)
    if out.returncode != 0:
        raise SystemExit(f"launch failed: {out.stderr.strip()}")
    print(f"launched {out.stdout.strip()} on {device} (mock {port})")
    deadline = time.time() + 180
    container = pick.data_container(udid)
    while time.time() < deadline:
        if probe_value(container, "document.querySelector('[data-composer-input]') !== null") is True:
            print("composer ready")
            return
        time.sleep(1.0)
    raise SystemExit("the composer never appeared")


def probe_value(container: Path, script: str) -> object:
    import uuid
    command_id = uuid.uuid4().hex[:12]
    (container / "Documents" / "step18-cmd.json").write_text(
        json.dumps({"id": command_id, "script": script}), encoding="utf-8")
    reply = container / "Documents" / f"step18-out-{command_id}.json"
    deadline = time.time() + 3.0
    while time.time() < deadline:
        if reply.exists():
            try:
                payload = json.loads(reply.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                time.sleep(0.1)
                continue
            reply.unlink(missing_ok=True)
            return payload.get("value")
        time.sleep(0.1)
    return None


def shot(name: str, shots: Path | None) -> None:
    """Screenshot the device, into `shots`.

    Written to `$TMPDIR` first and copied afterwards, because `simctl` cannot
    write to this volume: measured, `simctl io … screenshot <path on the external
    volume>` fails with `NSPOSIXErrorDomain code=1 "Operation not permitted"`
    while the same command into `/tmp` succeeds. The copy is what makes the
    evidence land next to the other steps' screenshots.
    """
    if shots is None:
        return
    shots.mkdir(parents=True, exist_ok=True)
    udid = pick.device_udid()
    staging = Path(os.environ.get("TMPDIR", "/tmp")) / f"step21-{name}.png"
    out = subprocess.run(["xcrun", "simctl", *pick.set_arguments(), "io", udid, "screenshot", str(staging)],
                         capture_output=True, text=True, env=pick.ENV)
    if out.returncode != 0 or not staging.exists():
        print(f"  screenshot failed: {out.stderr.strip()}", file=sys.stderr)
        return
    target = shots / f"{name}.png"
    try:
        target.write_bytes(staging.read_bytes())
    except OSError as error:
        print(f"  screenshot copy failed: {error}", file=sys.stderr)
        return
    finally:
        staging.unlink(missing_ok=True)


def tap(selector: str) -> str:
    """Press a control through the page's own event path."""
    script = """
    (function (selector) {
      const el = document.querySelector(selector);
      if (el === null) return 'missing';
      const r = el.getBoundingClientRect();
      const init = { bubbles: true, cancelable: true, composed: true, button: 0, buttons: 1,
        pointerId: 41, pointerType: 'touch', isPrimary: true,
        clientX: r.left + r.width / 2, clientY: r.top + r.height / 2 };
      for (const [type, Ctor] of [['pointerdown', PointerEvent], ['mousedown', MouseEvent],
                                  ['pointerup', PointerEvent], ['mouseup', MouseEvent],
                                  ['click', MouseEvent]]) {
        el.dispatchEvent(new Ctor(type, init));
      }
      return 'tapped';
    })(%s)
    """ % json.dumps(selector)
    return str(probe.ask(script, timeout=30).get("value"))


def by_text(text: str, role: str = "button") -> str:
    script = """
    (function (text) {
      const el = Array.from(document.querySelectorAll(%s))
        .find((b) => ((b.getAttribute('aria-label') || '') + (b.innerText || '')).indexOf(text) >= 0);
      if (el === undefined) return 'missing';
      const r = el.getBoundingClientRect();
      const init = { bubbles: true, cancelable: true, composed: true, button: 0, buttons: 1,
        pointerId: 42, pointerType: 'touch', isPrimary: true,
        clientX: r.left + r.width / 2, clientY: r.top + r.height / 2 };
      for (const [type, Ctor] of [['pointerdown', PointerEvent], ['mousedown', MouseEvent],
                                  ['pointerup', PointerEvent], ['mouseup', MouseEvent],
                                  ['click', MouseEvent]]) {
        el.dispatchEvent(new Ctor(type, init));
      }
      return 'tapped';
    })(%s)
    """ % (json.dumps(role), json.dumps(text))
    return str(probe.ask(script, timeout=30).get("value"))


def ask(name: str, phase: str) -> dict:
    reply = probe.ask(SCRIPTS[name], timeout=60)
    raw = reply.get("value")
    if isinstance(raw, str):
        try:
            value = json.loads(raw)
        except json.JSONDecodeError:
            value = {"unparsed": raw}
    else:
        value = {"value": raw}
    LOGS.mkdir(parents=True, exist_ok=True)
    target = LOGS / f"{phase}-{name}.json"
    target.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"  {name}: saved {target.relative_to(ROOT)}")
    return value


def seed_turn(prompt: str = "STREAMTEST 第21单逐屏走查", timeout: float = 180.0) -> bool:
    """Send one prompt and wait until the turn ends, so a conversation exists.

    Several of the states this step measures only exist after a completed turn
    (message actions, the status line, the trajectory). Driving it the way a
    person does — paste into the draft, press Send — keeps the state honest.
    """
    script = """
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
    })(%s)
    """ % json.dumps(prompt)
    for attempt in range(3):
        first = probe.ask(script, timeout=60).get("value")
        print(f"  seed attempt {attempt + 1}: {first}")
        if first == "sent":
            break
        # "send-disabled" is a race with React's own state update after the paste:
        # the draft is in the DOM one frame before the button re-renders enabled.
        time.sleep(1.5)
    deadline = time.time() + timeout
    while time.time() < deadline:
        raw = probe.ask("JSON.stringify({running: document.querySelectorAll('[data-chat-running]').length,"
                        " items: document.querySelectorAll('[data-chat-flow-kind]').length})",
                        timeout=30).get("value")
        try:
            state = json.loads(raw) if isinstance(raw, str) else {}
        except json.JSONDecodeError:
            state = {}
        if state.get("running") == 0 and state.get("items", 0) > 0:
            return True
        time.sleep(1.5)
    return False


def open_drawer() -> str:
    """Open the session drawer through the control the phone actually has."""
    return tap('[data-dsh-rail-edge]')


def close_drawer() -> str:
    return tap('[data-dsh-rail-edge]')


def reach_item_states(phase: str, shots: Path | None) -> None:
    """Walk to the state each item is about, and record what it looks like.

    One walk, not one launch per item: these states are reached by tapping, and
    relaunching between them would change which session is on screen. Every stop
    writes its own `logs/step21/<phase>-<label>-<item>.json`, so the report's two
    columns are two files with the same shape.
    """
    print(f"{phase}: walking to the states")

    def stop(label: str, items: list[str]) -> None:
        for name in items:
            summarize(name, ask(name, f"{phase}-{label}"))
        shot(f"{phase}-{label}", shots)

    # 01 the hero, empty draft: item 1 and item 3's default state.
    stop("01-hero", ["model", "hint"])

    # 02 the session list and its search field: item 5's first target.
    open_drawer()
    time.sleep(0.8)
    tap('button[aria-label="搜索会话"]')
    time.sleep(0.9)
    stop("02-session-search", ["touch"])

    # 03 a completed turn, so the trajectory and the message actions exist.
    print("  -> one turn")
    close_drawer()
    time.sleep(0.6)
    seed_turn()
    stop("03-conversation", ["model"])

    # 04/05 the trajectory: first in the 122 pt column (drawer open), then at the
    # full width (drawer closed). Item 7 is the first of those; item 5's other two
    # targets are on the same page.
    tab = by_text("\u8f68\u8ff9", '[role="tab"]')
    print(f"  trajectory tab: {tab}")
    time.sleep(1.6)
    open_drawer()
    time.sleep(1.0)
    stop("04-trajectory-narrow", ["narrow", "touch"])
    close_drawer()
    time.sleep(0.8)
    stop("05-trajectory-wide", ["narrow", "touch"])
    print("  conversation tab:", by_text("\u5bf9\u8bdd", '[role="tab"]'))
    time.sleep(1.0)

    # 06/07 a turn left running: this is the state whose placeholder names a key
    # chord, which is item 3. The queued draft is the other place a chord shows.
    print("  -> a turn left running, for the composer hint")
    script = """
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
        .find((b) => (b.getAttribute('aria-label') || '').indexOf('\u53d1\u9001\u6d88\u606f') === 0);
      if (send === undefined || send.disabled) return 'not-sent';
      send.click();
      return 'sent';
    })('BASHTEST \u957f\u56de\u5408\nSTEP 1: sleep 60')
    """
    print("  running turn:", probe.ask(script, timeout=60).get("value"))
    time.sleep(8)
    stop("06-running", ["hint"])
    probe.ask("""
    (function (text) {
      const box = document.querySelector('[data-composer-input]');
      if (box === null) return 'no-composer';
      box.focus();
      document.execCommand('insertText', false, text);
      return 'typed';
    })('\u6392\u961f\u4e00\u6761')
    """, timeout=30)
    time.sleep(1.0)
    stop("07-queued", ["hint"])
    # Leave the device idle for whatever runs next.
    probe.ask("(function(){const b=Array.from(document.querySelectorAll('button'))"
              ".find((x)=>(x.getAttribute('aria-label')||'').indexOf('\u505c\u6b62\u751f\u6210')===0);"
              " if(b)b.click(); return 'stopped';})()", timeout=30)
    time.sleep(1.5)
    probe.ask("""
    (function () {
      const box = document.querySelector('[data-composer-input]');
      if (box !== null) { box.focus(); document.execCommand('selectAll', false, null);
                          document.execCommand('delete', false, null); }
      return 'cleared';
    })()
    """, timeout=30)


def ask_raw(script: str) -> dict:
    """Run one page script and parse it, without writing an evidence file."""
    raw = probe.ask(script, timeout=60).get("value")
    if isinstance(raw, str):
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            return {"unparsed": raw}
    return {"value": raw}


def summarize(name: str, value: dict) -> None:
    if name == "model":
        if not value.get("found"):
            print("  model: composer row not found")
            return
        label = value.get("label") or {}
        print(f"  model: compact={value['compact']} labelWidth={label.get('w')} "
              f"labelDisplay={label.get('display')} text={(label.get('text') or '')[:34]!r} "
              f"box={value['box']['w']}px rowHeight={value['row']['height']} "
              f"sendOverlap={value.get('sendOverlap')} viewport={value['viewportWidth']}")
    elif name == "hint":
        print(f"  hint: visibleChordStrings={len(value.get('visibleChordStrings') or [])} "
              f"paintedChordHints={len(value.get('paintedChordHints') or [])} "
              f"placeholder={(value.get('placeholder') or '')[:40]!r}")
    elif name == "touch":
        for key in ("sessionSearch", "trajectorySearch", "requestBadge"):
            item = value.get(key)
            print(f"  touch: {key:18s} {item}" if item is None else
                  f"  touch: {key:18s} {item['w']}x{item['h']} at {item['x']},{item['y']}")
    elif name == "narrow":
        print(f"  narrow: frame={value['columns']['frame']} center={value['columns']['center']} "
              f"drawer={value['drawerOpen']} over={value['overflowCount']} "
              f"clipped={value.get('clippedCount')} escaping={value.get('escapingCount')} "
              f"docOverflow={value['docHorizontalOverflow']}")
        for item in (value.get("namedControls") or [])[:6]:
            print(f"           {item['label']!r} {item['w']}x{item['h']} overRight={item['overRight']}")
    elif name == "launch":
        print(f"  launch: boot={value['hasBootScreen']} composer={value['composerPresent']} "
              f"body={value['bodyBackground']} html={value['htmlBackground']}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--phase", required=True, help="before or after; names the output files")
    parser.add_argument("--item", action="append", choices=sorted(SCRIPTS) + ["all"], default=None)
    parser.add_argument("--shots", default=None, help="directory for screenshots")
    parser.add_argument("--device", default=os.environ.get("DSHPORTE_DEVICE", "phone-polish"))
    parser.add_argument("--reuse", action="store_true",
                        help="ask the app that is already running instead of reinstalling and relaunching")
    args = parser.parse_args()

    os.environ["DSHPORTE_DEVICE"] = args.device
    shots = Path(args.shots) if args.shots else None
    items = args.item or ["all"]
    if "all" in items:
        items = sorted(SCRIPTS)

    if not args.reuse:
        launch(args.device)
        # The measurements below are about states a person reaches by tapping, so
        # the script walks to them rather than assuming the launch state.
        reach_item_states(args.phase, shots)

    for name in items:
        print(f"{args.phase}: {name}")
        try:
            value = ask(name, args.phase)
        except SystemExit as error:
            print(f"  {error}", file=sys.stderr)
            continue
        summarize(name, value)
        shot(f"{args.phase}-{name}", shots)
        time.sleep(0.4)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
