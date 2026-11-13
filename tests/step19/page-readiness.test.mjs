// Exercise the exact document-start script without WebKit or network access.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('../../sim/page-readiness.js', import.meta.url), 'utf8');

function page({ frame = false, host = '127.0.0.1', protocol = 'http:' } = {}) {
  const listeners = new Map();
  const timers = new Map();
  const root = {
    innerText: 'Loading plugins…',
    controls: [],
    querySelectorAll(selector) {
      return this.controls.filter((control) => selector.split(',').map((s) => s.trim()).includes(control.selector));
    },
  };
  const document = {
    readyState: 'complete',
    mounted: true,
    getElementById: (id) => id === 'root' && document.mounted ? root : null,
  };
  const window = {
    addEventListener: (name, fn) => listeners.set(name, fn),
    removeEventListener: (name) => listeners.delete(name),
  };
  window.top = frame ? {} : window;
  vm.runInNewContext(source, {
    window, document,
    location: { protocol, hostname: host },
    getComputedStyle: (element) => ({ visibility: element.visibility }),
    setInterval: (fn) => { timers.set(1, fn); return 1; },
    clearInterval: (id) => timers.delete(id),
  });
  return {
    root, document, window, timers,
    tick: () => { for (const fn of timers.values()) fn(); },
    event: (name, event) => listeners.get(name)?.(event),
    control(selector, { visible = true, visibility = 'visible' } = {}) {
      root.controls.push({ selector, visibility, getClientRects: () => visible ? [{}] : [] });
    },
  };
}

test('blank HTML, a loading screen and plain error text do not declare readiness', () => {
  const p = page();
  for (const text of ['', 'Loading plugins…', 'Plugin import failed '.repeat(100)]) {
    p.root.innerText = text;
    p.tick();
    assert.equal(p.window.__dshBootState.ready, false);
    assert.equal(p.timers.size, 1);
  }
});

for (const [text, selector] of [
  ['Existing session', '[data-composer-input]'],
  ['Empty workspace', '[data-sidebar-collapsed]'],
  ['Safe mode workspace', '[data-rightbar-collapsed]'],
  ['Choisir un espace de travail', 'button'],
  ['初回設定', 'input'],
  ['Welcome', '[role="dialog"]'],
]) {
  test('rendered client surface declares readiness: ' + text, () => {
    const p = page();
    p.document.readyState = 'interactive';
    p.root.innerText = text;
    p.control(selector);
    p.tick();
    assert.equal(p.window.__dshBootState.ready, false);
    p.document.readyState = 'complete';
    p.tick();
    assert.equal(p.window.__dshBootState.ready, true);
    assert.equal(p.timers.size, 0);
    p.event('unhandledrejection', { reason: new Error('later runtime error') });
    assert.equal(p.window.__dshBootState.error, null, 'startup monitoring stopped');
  });
}

test('missing roots and hidden controls do not expose the page', () => {
  const p = page();
  p.root.innerText = 'DSH';
  p.control('button', { visible: false });
  p.control('input', { visibility: 'hidden' });
  p.control('select', { visibility: 'collapse' });
  p.tick();
  assert.equal(p.window.__dshBootState.ready, false);
  p.control('[data-composer-input]');
  p.document.mounted = false;
  p.tick();
  assert.equal(p.window.__dshBootState.ready, false);
});

for (const name of ['error', 'unhandledrejection']) {
  test(name + ' is diagnostic and does not veto a later usable interface', () => {
    const p = page();
    p.event(name, { error: new Error('optional fetch failed'), reason: new Error('optional fetch failed') });
    p.event(name, { error: new Error('second error'), reason: new Error('second error') });
    assert.equal(p.window.__dshBootState.error, 'optional fetch failed', 'retain the first error');
    assert.equal(p.timers.size, 1, 'keep checking readiness');
    p.root.innerText = 'DSH';
    p.control('button');
    p.tick();
    assert.equal(p.window.__dshBootState.ready, true);
    assert.equal(p.timers.size, 0);
  });
}

test('ResizeObserver loop reports are ignored', () => {
  const p = page();
  p.event('error', { message: 'ResizeObserver loop completed with undelivered notifications.' });
  p.event('unhandledrejection', { reason: new Error('ResizeObserver loop limit exceeded') });
  assert.equal(p.window.__dshBootState.error, null);
  p.root.innerText = 'DSH';
  p.control('button');
  p.tick();
  assert.equal(p.window.__dshBootState.ready, true);
});

test('a plugin failure without a rendered interface stays pending with its diagnostic', () => {
  const p = page();
  p.event('unhandledrejection', { reason: new Error('plugin import failed') });
  for (let i = 0; i < 5; i++) p.tick();
  assert.equal(p.window.__dshBootState.ready, false);
  assert.equal(p.window.__dshBootState.error, 'plugin import failed');
  assert.equal(p.timers.size, 1, 'the native watchdog still owns the timeout');
});

test('a new document starts with fresh state', () => {
  const first = page();
  first.root.innerText = 'DSH';
  first.control('button');
  first.tick();
  assert.equal(first.window.__dshBootState.ready, true);
  const reloaded = page();
  assert.equal(reloaded.window.__dshBootState.ready, false);
  assert.equal(reloaded.window.__dshBootState.error, null);
});

test('subframes, external pages and non-HTTP pages install no state', () => {
  assert.equal(page({ frame: true }).window.__dshBootState, undefined);
  assert.equal(page({ host: 'example.com' }).window.__dshBootState, undefined);
  assert.equal(page({ protocol: 'https:' }).window.__dshBootState, undefined);
});

test('the plugin loading screen cannot declare readiness with a partial control', () => {
  const p = page();
  p.control('[data-composer-input]');
  p.tick();
  assert.equal(p.window.__dshBootState.ready, false);
});

test('startup error diagnostics are bounded', () => {
  const p = page();
  p.event('error', { message: 'x'.repeat(2000) });
  assert.equal(p.window.__dshBootState.error.length, 1200);
});
