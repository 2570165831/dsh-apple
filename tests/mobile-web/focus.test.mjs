// Exercise the shipped guard. Real keyboard and accessibility delivery still
// need the device checks; these objects only model the events reaching the page.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { runInNewContext } from 'node:vm';

const source = readFileSync(new URL('../../app/DSHPortC/MobileWebTuning.swift', import.meta.url), 'utf8');
const start = source.indexOf('          // ---- 3b.');
const end = source.indexOf('          // ---- 4.', start);
assert.ok(start >= 0 && end > start, 'the shipped focus guard was not found');
const guard = source.slice(start, end);

function page() {
  const listeners = new Map();
  const timers = new Map();
  let clock = 0;
  let nextTimer = 0;
  const document = {
    addEventListener(type, handler) {
      if (!listeners.has(type)) listeners.set(type, []);
      listeners.get(type).push(handler);
    },
    querySelector() { return draft; },
  };
  class Element {
    constructor(parent = null, selectors = []) {
      this.parent = parent;
      this.selectors = new Set(selectors);
      this.textContent = '';
    }
    matches(selector) {
      return selector.split(',').some(part => this.selectors.has(part.trim()));
    }
    closest(selector) {
      for (let node = this; node !== null; node = node.parent) {
        if (node.matches(selector)) return node;
      }
      return null;
    }
    get isContentEditable() { return this.closest('[contenteditable]') !== null; }
    focus() {
      document.activeElement = this;
      dispatch('focusin', { target: this });
    }
    blur() {
      if (document.activeElement !== this) return;
      document.activeElement = body;
      dispatch('focusout', { target: this });
    }
  }
  const body = new Element();
  const card = new Element(body, ['[data-composer-card]']);
  const draft = new Element(card, ['[data-composer-input]', '[contenteditable]']);
  const overlay = new Element(card, ['[data-composer-overlay]']);
  const plus = new Element(card, ['button']);
  const send = new Element(card, ['button', '[data-composer-card] button[class*="primary"]']);
  const portal = new Element(body, ['[role="button"]']);
  const input = new Element(body, ['input']);
  const textarea = new Element(body, ['textarea']);
  const select = new Element(body, ['select']);
  const editable = new Element(body, ['[contenteditable]']);
  document.activeElement = body;
  const nativeFocus = Element.prototype.focus;
  const state = {};
  const window = { innerHeight: 800, addEventListener: document.addEventListener };
  function dispatch(type, fields = {}) {
    for (const handler of listeners.get(type) || []) {
      handler({ target: body, detail: 1, isTrusted: true, touches: [], ...fields });
    }
  }
  function advance(milliseconds) {
    const until = clock + milliseconds;
    while (true) {
      const due = [...timers].filter(([, timer]) => timer.at <= until)
        .sort((a, b) => a[1].at - b[1].at)[0];
      if (due === undefined) break;
      const [id, timer] = due;
      timers.delete(id);
      clock = timer.at;
      timer.callback();
    }
    clock = until;
  }
  runInNewContext(guard, {
    state, window, document, Element, HTMLElement: Element,
    setTimeout(callback, delay = 0) {
      const id = ++nextTimer;
      timers.set(id, { callback, at: clock + delay });
      return id;
    },
    clearTimeout(id) { timers.delete(id); },
  });
  return { body, card, draft, overlay, plus, send, portal, input, textarea, select, editable,
    document, state, window, dispatch, advance, nativeFocus: () => nativeFocus.call(draft) };
}

test('first scripted and native focus need no preceding touch', () => {
  const p = page();
  p.draft.focus();
  assert.equal(p.document.activeElement, p.draft);
  p.draft.blur();
  p.nativeFocus();
  assert.equal(p.document.activeElement, p.draft);
  assert.equal(p.state.draftFocusBlocked, 0);
});

test('focus without a software keyboard never establishes a hardware keyboard', () => {
  const p = page();
  p.draft.focus();
  assert.equal(p.document.activeElement, p.draft);
  p.advance(900);
  assert.equal(p.state.hardwareKeyboard, false);
  p.draft.blur();
  p.dispatch('touchstart', { target: p.plus });
  p.draft.focus();
  assert.equal(p.document.activeElement, p.body);
});

test('Tab releases a touch guard and establishes a hardware keyboard', () => {
  const p = page();
  p.dispatch('touchstart', { target: p.plus });
  p.dispatch('keydown', { key: 'Tab' });
  p.nativeFocus();
  p.advance(900);
  assert.equal(p.document.activeElement, p.draft);
  assert.equal(p.state.hardwareKeyboard, true);
});

for (const target of ['draft', 'input', 'textarea', 'select', 'editable']) {
  test('typing in ' + target + ' does not establish a hardware keyboard', () => {
    const p = page();
    p.document.activeElement = p[target];
    p.dispatch('keydown', { target: p[target], key: 'a' });
    p.advance(900);
    assert.equal(p.state.hardwareKeyboard, false);
  });
}

for (const pointerType of ['mouse', 'pen']) {
  test(pointerType + ' releases an earlier touch without establishing a keyboard', () => {
    const p = page();
    p.dispatch('touchstart', { target: p.plus });
    p.dispatch('pointerdown', { target: p.draft, pointerType });
    p.nativeFocus();
    p.window.innerHeight = 500;
    p.dispatch('resize');
    p.advance(900);
    assert.equal(p.document.activeElement, p.draft);
    assert.equal(p.state.hardwareKeyboard, false);
  });
}

for (const target of ['draft', 'overlay', 'card']) {
  test('a trusted accessibility click on ' + target + ' releases the guard', () => {
    const p = page();
    p.dispatch('touchstart', { target: p.plus });
    p.dispatch('click', { target: p[target], detail: 0 });
    p.nativeFocus();
    assert.equal(p.document.activeElement, p.draft);
    p.advance(900);
    assert.equal(p.state.hardwareKeyboard, false);
  });
}

for (const event of [
  ['click', { target: 'draft', detail: 0, isTrusted: false }],
  ['click', { target: 'input', detail: 0, isTrusted: false }],
  ['click', { target: 'plus', detail: 0 }],
  ['keydown', { key: 'Tab', isTrusted: false }],
  ['pointerdown', { pointerType: 'mouse', isTrusted: false }],
]) {
  test('an unrelated or scripted ' + event[0] + ' cannot release the guard: ' + JSON.stringify(event[1]), () => {
    const p = page();
    p.dispatch('touchstart', { target: p.plus });
    const fields = { ...event[1] };
    if (fields.target) fields.target = p[fields.target];
    p.dispatch(event[0], fields);
    p.draft.focus();
    assert.equal(p.document.activeElement, p.body);
    assert.equal(p.state.hardwareKeyboard, false);
  });
}

for (const target of ['plus', 'portal', 'body']) {
  test('a touch on ' + target + ' blocks both focus paths, including outside the card', () => {
    const p = page();
    p.dispatch('pointerdown', { target: p[target], pointerType: 'touch' });
    p.dispatch('touchstart', { target: p[target] });
    p.draft.focus();
    assert.equal(p.document.activeElement, p.body);
    p.nativeFocus();
    assert.equal(p.document.activeElement, p.body);
    assert.equal(p.state.draftFocusBlocked, 2);
  });
}

for (const target of ['draft', 'overlay', 'card']) {
  test('a touch on ' + target + ' still allows focus', () => {
    const p = page();
    p.dispatch('touchstart', { target: p[target] });
    p.draft.focus();
    p.window.innerHeight = 500;
    p.dispatch('resize');
    p.advance(900);
    assert.equal(p.document.activeElement, p.draft);
    assert.equal(p.state.hardwareKeyboard, false);
  });
}

test('the touch guard lasts through a long press and expires after release', () => {
  const p = page();
  p.dispatch('touchstart', { target: p.plus });
  p.advance(2000);
  p.draft.focus();
  assert.equal(p.document.activeElement, p.body);
  p.dispatch('touchend', { target: p.plus });
  p.advance(999);
  p.nativeFocus();
  assert.equal(p.document.activeElement, p.body);
  p.advance(1);
  p.nativeFocus();
  assert.equal(p.document.activeElement, p.draft);
});

test('cancelling a touch releases the guard', () => {
  const p = page();
  p.dispatch('touchstart', { target: p.plus });
  p.dispatch('touchcancel');
  p.nativeFocus();
  assert.equal(p.document.activeElement, p.draft);
});

test('a toolbar touch preserves focus already in the draft', () => {
  const p = page();
  p.nativeFocus();
  p.dispatch('touchstart', { target: p.plus });
  p.draft.focus();
  assert.equal(p.document.activeElement, p.draft);
});

test('a late refocus after Send cannot disable the next touch guard', () => {
  const p = page();
  p.nativeFocus();
  p.draft.textContent = 'draft';
  p.dispatch('touchstart', { target: p.send });
  p.dispatch('touchend', { target: p.send });
  p.dispatch('click', { target: p.send });
  p.advance(0);
  assert.equal(p.document.activeElement, p.body);
  p.advance(1000);
  p.draft.focus();
  p.advance(900);
  assert.equal(p.document.activeElement, p.draft);
  assert.equal(p.state.hardwareKeyboard, false);
  p.draft.blur();
  p.dispatch('touchstart', { target: p.plus });
  p.draft.focus();
  assert.equal(p.document.activeElement, p.body);
});

test('a keyboard-entry hint is cleared when the viewport shrinks', () => {
  const p = page();
  p.dispatch('keydown', { key: 'Tab' });
  p.nativeFocus();
  assert.equal(p.state.hardwareKeyboard, true);
  p.window.innerHeight = 500;
  p.dispatch('resize');
  assert.equal(p.state.hardwareKeyboard, false);
});

for (const fields of [{ detail: 0 }, { isTrusted: false }]) {
  test('a keyboard or scripted Send click keeps focus: ' + JSON.stringify(fields), () => {
    const p = page();
    p.nativeFocus();
    p.draft.textContent = 'draft';
    p.dispatch('click', { target: p.send, ...fields });
    p.advance(0);
    assert.equal(p.document.activeElement, p.draft);
  });
}

test('the empty Send button is Stop and preserves focus', () => {
  const p = page();
  p.nativeFocus();
  p.dispatch('click', { target: p.send });
  p.advance(0);
  assert.equal(p.document.activeElement, p.draft);
});

test('Send preserves focus after keyboard entry', () => {
  const p = page();
  p.dispatch('keydown', { key: 'Tab' });
  p.nativeFocus();
  p.draft.textContent = 'draft';
  p.dispatch('touchstart', { target: p.send });
  p.dispatch('click', { target: p.send });
  p.advance(0);
  assert.equal(p.document.activeElement, p.draft);
});

test('a shortcut-bar resize cannot block the next keyboard focus', () => {
  const p = page();
  p.dispatch('keydown', { key: 'Tab' });
  p.nativeFocus();
  p.window.innerHeight = 750;
  p.dispatch('resize');
  p.draft.blur();
  p.dispatch('keydown', { key: 'Tab' });
  p.nativeFocus();
  assert.equal(p.document.activeElement, p.draft);
});

for (const [type, fields, release] of [
  ['touchstart', {}, 'touchend'],
  ['pointerdown', { pointerType: 'mouse' }, 'pointerup'],
  ['pointerdown', { pointerType: 'pen' }, 'pointerup'],
]) {
  const name = fields.pointerType || 'touch';
  test('a direct ' + name + ' draft press detects a keyboard and preserves Send focus', () => {
    const p = page();
    p.dispatch(type, { target: p.draft, ...fields });
    p.nativeFocus();
    p.dispatch(release, { target: p.draft, ...fields });
    p.advance(899);
    assert.equal(p.state.hardwareKeyboard, false);
    p.advance(1);
    assert.equal(p.state.hardwareKeyboard, true);
    p.draft.textContent = 'draft';
    p.dispatch(type, { target: p.send, ...fields });
    p.dispatch(release, { target: p.send, ...fields });
    p.dispatch('click', { target: p.send });
    p.advance(0);
    assert.equal(p.document.activeElement, p.draft);
  });

  test('a software keyboard after a ' + name + ' draft press still blurs on Send', () => {
    const p = page();
    p.dispatch(type, { target: p.draft, ...fields });
    p.nativeFocus();
    p.dispatch(release, { target: p.draft, ...fields });
    p.window.innerHeight = 500;
    p.dispatch('resize');
    p.advance(900);
    assert.equal(p.state.hardwareKeyboard, false);
    p.draft.textContent = 'draft';
    p.dispatch(type, { target: p.send, ...fields });
    p.dispatch(release, { target: p.send, ...fields });
    p.dispatch('click', { target: p.send });
    p.advance(0);
    assert.equal(p.document.activeElement, p.body);
  });
}

for (const type of ['touchend', 'mousedown', 'click']) {
  test('a direct draft focus delivered at ' + type + ' can measure the keyboard', () => {
    const p = page();
    p.dispatch('touchstart', { target: p.draft });
    p.advance(0);
    p.dispatch('touchend', { target: p.draft });
    if (type !== 'touchend') {
      p.advance(0);
      p.dispatch(type, { target: p.draft });
    }
    p.nativeFocus();
    p.advance(900);
    assert.equal(p.state.hardwareKeyboard, true);
  });
}

for (const type of ['touchstart', 'touchend', 'mousedown', 'click']) {
  test('a draft ' + type + ' without focus cannot arm a later scripted measurement', () => {
    const p = page();
    p.dispatch(type, { target: p.draft });
    p.advance(0);
    p.nativeFocus();
    p.advance(900);
    assert.equal(p.document.activeElement, p.draft);
    assert.equal(p.state.hardwareKeyboard, false);
  });
}

test('an untrusted draft click cannot arm a keyboard measurement', () => {
  const p = page();
  p.dispatch('click', { target: p.draft, isTrusted: false });
  p.nativeFocus();
  p.advance(900);
  assert.equal(p.state.hardwareKeyboard, false);
});

test('blur cancels a measurement before an unrelated refocus', () => {
  const p = page();
  p.dispatch('touchstart', { target: p.draft });
  p.nativeFocus();
  p.advance(450);
  p.draft.blur();
  p.nativeFocus();
  p.advance(900);
  assert.equal(p.document.activeElement, p.draft);
  assert.equal(p.state.hardwareKeyboard, false);
});

test('pressing an already focused draft cannot establish a hardware keyboard', () => {
  const p = page();
  p.nativeFocus();
  p.dispatch('touchstart', { target: p.draft });
  p.dispatch('touchend', { target: p.draft });
  p.dispatch('click', { target: p.draft });
  p.advance(900);
  assert.equal(p.state.hardwareKeyboard, false);
});

for (const pointerType of ['mouse', 'pen']) {
  for (const target of ['plus', 'send', 'portal', 'body']) {
    test(pointerType + ' on ' + target + ' blocks incidental focus until after release', () => {
      const p = page();
      p.dispatch('pointerdown', { target: p[target], pointerType });
      p.draft.focus();
      p.nativeFocus();
      assert.equal(p.document.activeElement, p.body);
      assert.equal(p.state.draftFocusBlocked, 2);
      p.advance(2000);
      p.draft.focus();
      assert.equal(p.document.activeElement, p.body);
      p.dispatch('pointerup', { target: p[target], pointerType });
      p.dispatch('click', { target: p[target] });
      p.advance(999);
      p.nativeFocus();
      assert.equal(p.document.activeElement, p.body);
      p.advance(1);
      p.nativeFocus();
      p.advance(900);
      assert.equal(p.document.activeElement, p.draft);
      assert.equal(p.state.hardwareKeyboard, false);
    });
  }

  test(pointerType + ' cancellation releases the focus guard', () => {
    const p = page();
    p.dispatch('pointerdown', { target: p.plus, pointerType });
    p.dispatch('pointercancel', { target: p.plus, pointerType });
    p.nativeFocus();
    p.advance(900);
    assert.equal(p.document.activeElement, p.draft);
    assert.equal(p.state.hardwareKeyboard, false);
  });
}

for (const height of [500, 1100]) {
  test('unguarded focus refreshes a viewport baseline of ' + height, () => {
    const p = page();
    p.dispatch('keydown', { key: 'Tab' });
    p.nativeFocus();
    p.draft.blur();
    p.window.innerHeight = height;
    p.nativeFocus();
    p.dispatch('resize');
    assert.equal(p.state.hardwareKeyboard, true);
    p.window.innerHeight = height - 10;
    p.dispatch('resize');
    assert.equal(p.state.hardwareKeyboard, false);
  });
}

test('a direct draft press keeps the height from before keyboard animation', () => {
  const p = page();
  p.dispatch('touchstart', { target: p.draft });
  p.window.innerHeight = 500;
  p.nativeFocus();
  p.advance(900);
  assert.equal(p.state.hardwareKeyboard, false);
});

test('a zero-detail mousedown cannot arm a keyboard measurement', () => {
  const p = page();
  p.dispatch('mousedown', { target: p.draft, detail: 0 });
  p.nativeFocus();
  p.advance(900);
  assert.equal(p.document.activeElement, p.draft);
  assert.equal(p.state.hardwareKeyboard, false);
});
