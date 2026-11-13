// Exercise the shipped edge sampler and Swift decoder on the host. Safe-area
// geometry and actual WebKit painting still need the iPad/iPhone device sweep.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { runInNewContext } from 'node:vm';

const source = readFileSync(new URL('../../app/DSHPortC/MobileWebTuning.swift', import.meta.url), 'utf8');
const content = readFileSync(new URL('../../app/DSHPortC/ContentView.swift', import.meta.url), 'utf8');
const channel = source.match(/static let edgeBandsMessageName = "([^"]+)"/)[1];
const limit = Number(source.match(/static let maximumSegments = (\d+)/)[1]);
const script = source.match(/static let edgeBandsBootstrapScript = """\n([\s\S]*?)\n    """/)[1]
  .replaceAll('\\(edgeBandsMessageName)', channel)
  .replaceAll('\\(EdgeBands.maximumSegments)', String(limit))
  .replaceAll('\\\\', '\\');

function page({ frame = false, host = '127.0.0.1', protocol = 'http:', bridge = true, resize = true } = {}) {
  const events = new Map();
  const timers = new Map();
  const observers = [];
  const messages = [];
  const reads = { hits: 0, styles: 0 };
  let clock = 0;
  let nextTimer = 0;
  const listen = (name, callback) => {
    if (!events.has(name)) events.set(name, []);
    events.get(name).push(callback);
  };
  const root = { background: 'rgba(0, 0, 0, 0)', parentElement: null };
  const body = { background: 'rgb(255, 255, 255)', parentElement: root };
  const document = {
    documentElement: root, body,
    addEventListener: listen,
    elementsFromPoint(x, y) {
      reads.hits++;
      const hit = document.hit(x, y);
      if (Array.isArray(hit)) return hit;
      const stack = [];
      for (let node = hit; node; node = node.parentElement) stack.push(node);
      return stack;
    },
    hit: () => body,
  };
  const window = {
    innerWidth: 1024, innerHeight: 740,
    addEventListener: listen,
    matchMedia: () => ({ addEventListener: listen }),
    webkit: { messageHandlers: bridge ? {
      [channel]: { postMessage: value => messages.push(JSON.parse(JSON.stringify(value))) },
    } : {} },
  };
  window.top = frame ? {} : window;
  class Observer {
    constructor(callback) { this.callback = callback; this.targets = new Set(); observers.push(this); }
    observe(node, options) { this.targets.add(node); this.options = options; }
    unobserve(node) { this.targets.delete(node); }
  }
  const context = {
    window, document, location: { protocol, hostname: host },
    getComputedStyle(node, pseudo) {
      // Pseudo-element reads are not counted: the budget below is about elements.
      if (pseudo) return node[pseudo === '::after' ? 'after' : 'before'] ?? { content: 'none' };
      reads.styles++;
      return { backgroundColor: node.background, opacity: String(node.opacity ?? 1) };
    },
    MutationObserver: Observer, ResizeObserver: resize ? Observer : undefined,
    setTimeout(callback, delay) {
      const id = ++nextTimer;
      timers.set(id, { callback, at: clock + delay });
      return id;
    },
    clearTimeout: id => timers.delete(id),
  };
  const install = () => runInNewContext(script, context);
  install();
  function advance(milliseconds) {
    const until = clock + milliseconds;
    while (true) {
      const due = [...timers].filter(([, timer]) => timer.at <= until)
        .sort((a, b) => a[1].at - b[1].at)[0];
      if (!due) break;
      timers.delete(due[0]);
      clock = due[1].at;
      due[1].callback();
    }
    clock = until;
  }
  return { window, document, body, root, observers, messages, reads, advance, install,
    dispatch: name => { for (const callback of events.get(name) || []) callback(); },
    mutate: () => observers.find(observer => observer.options)?.callback(),
    node: (background, parentElement = body) => ({ background, parentElement }),
  };
}

test('uniform phone edges collapse to one opaque run each', () => {
  const p = page();
  p.window.innerWidth = 402;
  p.advance(79);
  assert.equal(p.messages.length, 0);
  p.advance(1);
  const row = [{ start: 0, end: 1, color: '#ffffff' }];
  assert.deepEqual(p.messages, [{ top: row, bottom: row }]);
});

test('top and bottom sample independently and refine the sidebar boundary', () => {
  const p = page();
  const sidebar = p.node('rgb(247, 247, 248)');
  const footer = p.node('rgb(21, 21, 23)');
  p.document.hit = (x, y) => x < (y === 0 ? 280 : 180) ? sidebar : (y === 0 ? p.body : footer);
  p.advance(80);
  const { top, bottom } = p.messages[0];
  assert.equal(top.length, 2);
  assert.equal(bottom.length, 2);
  assert.ok(Math.abs(top[0].end * p.window.innerWidth - 280) <= 0.5);
  assert.ok(Math.abs(bottom[0].end * p.window.innerWidth - 180) <= 0.5);
  assert.equal(top[0].end, top[1].start);
  assert.equal(top[0].color, '#f7f7f8');
  assert.equal(top[1].color, '#ffffff');
  assert.equal(bottom[1].color, '#151517');
  assert.ok(p.observers[0].targets.has(sidebar), 'the sampled column is resize-observed');
});

test('transparent nodes preserve the opaque backdrop', () => {
  const p = page();
  const ancestor = p.node('rgb(100% 100% 100% / 100%)');
  const overlay = p.node('rgba(10, 20, 30, 0)', ancestor);
  p.document.hit = () => p.node('rgba(0, 0, 0, 0)', overlay);
  p.advance(80);
  assert.equal(p.messages[0].top[0].color, '#ffffff');
});

test('a sibling scrim dims both edges to #999999 and restores white on dismissal', () => {
  const p = page();
  const surface = p.node('rgb(255, 255, 255)');
  const scrim = p.node('rgba(0, 0, 0, 0.4)');
  p.document.hit = () => [scrim, surface, p.body, p.root];
  p.advance(80);
  const row = [{ start: 0, end: 1, color: '#999999' }];
  assert.deepEqual(p.messages[0], { top: row, bottom: row });
  p.mutate();
  p.advance(80);
  assert.equal(p.messages.length, 1, 'an unchanged composite is not reported twice');
  p.document.hit = () => surface;
  p.mutate();
  p.advance(80);
  assert.equal(p.messages[1].top[0].color, '#ffffff');
  assert.equal(p.messages[1].bottom[0].color, '#ffffff');
});

test('a scrim composites with each sidebar and main-area color separately', () => {
  const p = page();
  const sidebar = p.node('rgb(247, 247, 248)');
  const scrim = p.node('rgba(0, 0, 0, 0.4)');
  p.document.hit = x => [scrim, ...(x < 280 ? [sidebar] : []), p.body, p.root];
  p.advance(80);
  for (const row of [p.messages[0].top, p.messages[0].bottom]) {
    assert.equal(row.length, 2);
    assert.equal(row[0].color, '#949495');
    assert.equal(row[1].color, '#999999');
    assert.ok(Math.abs(row[0].end * p.window.innerWidth - 280) <= 0.5);
  }
});

test('multiple translucent siblings composite in paint order without rounding intermediate colors', () => {
  const p = page();
  const red = p.node('rgba(255, 0, 0, 0.5)');
  const blue = p.node('rgba(0, 0, 255, 0.5)');
  p.document.hit = () => [red, blue, p.body, p.root];
  p.advance(80);
  assert.equal(p.messages[0].top[0].color, '#bf4080');
  p.document.hit = () => [blue, red, p.body, p.root];
  p.mutate();
  p.advance(80);
  assert.equal(p.messages[1].top[0].color, '#8040bf');
});

test('an opaque foreground occludes lower siblings without reading their styles', () => {
  const p = page();
  const foreground = p.node('rgb(10, 20, 30)');
  const covered = { get background() { throw new Error('covered layer was read'); } };
  p.document.hit = () => [foreground, covered, p.body, p.root];
  p.advance(80);
  assert.equal(p.messages[0].bottom[0].color, '#0a141e');
});

test('element opacity makes an opaque black scrim translucent', () => {
  const p = page();
  const scrim = p.node('rgb(0, 0, 0)');
  scrim.opacity = 0.4;
  p.document.hit = () => [scrim, p.body, p.root];
  p.advance(80);
  assert.equal(p.messages[0].top[0].color, '#999999');
  scrim.opacity = 0;
  p.mutate();
  p.advance(80);
  assert.equal(p.messages[1].top[0].color, '#ffffff');
});

test('a scrim painted by a full-cover pseudo-element dims the bands', () => {
  const p = page();
  const cover = { content: '""', position: 'absolute', top: '0px', right: '0px', bottom: '0px', left: '0px',
    backgroundColor: 'rgba(0, 0, 0, 0.5)', opacity: '1' };
  const mask = p.node('rgba(0, 0, 0, 0)');
  mask.after = cover;
  p.document.hit = () => [mask, p.body, p.root];
  p.advance(80);
  assert.equal(p.messages[0].top[0].color, '#808080');
  // Mid-animation the generated box is still fading in.
  mask.after = { ...cover, opacity: '0.5' };
  p.mutate();
  p.advance(80);
  assert.equal(p.messages[1].top[0].color, '#bfbfbf');
});

test('a fading pseudo-element scrim is followed without any DOM event', () => {
  const p = page();
  const cover = { content: '""', position: 'absolute', top: '0px', right: '0px', bottom: '0px', left: '0px',
    backgroundColor: 'rgba(0, 0, 0, 0.5)', opacity: '0' };
  const mask = p.node('rgba(0, 0, 0, 0)');
  mask.after = cover;
  p.document.hit = () => [mask, p.body, p.root];
  p.advance(80);
  assert.equal(p.messages[0].top[0].color, '#ffffff');
  mask.after = { ...cover, opacity: '1' };
  p.advance(120);
  assert.equal(p.messages[1].top[0].color, '#808080');
  // Settled: no further polling.
  const hits = p.reads.hits;
  p.advance(5000);
  assert.equal(p.reads.hits, hits);
});

test('a scrim resting below full opacity stops being polled', () => {
  const p = page();
  const mask = p.node('rgba(0, 0, 0, 0)');
  mask.after = { content: '""', position: 'absolute', top: '0px', right: '0px', bottom: '0px', left: '0px',
    backgroundColor: 'rgb(0, 0, 0)', opacity: '0.5' };
  p.document.hit = () => [mask, p.body, p.root];
  p.advance(80);
  p.advance(60000);
  const hits = p.reads.hits;
  p.advance(60000);
  assert.equal(p.reads.hits, hits);
});

test('a pseudo-element that does not cover its box is ignored', () => {
  const p = page();
  const badge = p.node('rgba(0, 0, 0, 0)');
  badge.after = { content: '""', position: 'absolute', top: '4px', right: '0px', bottom: '0px', left: '0px',
    backgroundColor: 'rgb(255, 0, 0)', opacity: '1' };
  badge.before = { content: '""', position: 'static', top: '0px', right: '0px', bottom: '0px', left: '0px',
    backgroundColor: 'rgb(255, 0, 0)', opacity: '1' };
  p.document.hit = () => [badge, p.body, p.root];
  p.advance(80);
  assert.equal(p.messages[0].top[0].color, '#ffffff');
});

test('background alpha multiplies both the element and ancestor opacity', () => {
  const p = page();
  const group = p.node('rgba(0, 0, 0, 0)');
  group.opacity = 0.5;
  const scrim = p.node('rgb(0 0 0 / 80%)', group);
  scrim.opacity = 0.5;
  p.document.hit = () => [scrim, group, p.body, p.root];
  p.advance(80);
  assert.equal(p.messages[0].top[0].color, '#cccccc');
});

test('a translucent stack without an opaque backdrop keeps the native fallback', () => {
  const p = page();
  p.body.background = 'transparent';
  const scrim = p.node('rgba(0, 0, 0, 0.4)');
  p.document.hit = () => [scrim, p.body, p.root];
  p.advance(80);
  assert.deepEqual(p.messages[0], { top: [], bottom: [] });
});

test('stack sampling keeps the point budget and caches styles across both rows', () => {
  const p = page();
  const surface = p.node('rgb(255, 255, 255)');
  const scrim = p.node('rgba(0, 0, 0, 0.4)');
  p.document.hit = () => [scrim, surface, p.body, p.root];
  p.advance(80);
  assert.equal(p.reads.hits, 2 * (Math.ceil(p.window.innerWidth / 16) + 1));
  assert.equal(p.reads.styles, 4, 'each element and ancestor is styled once per sample');
});

for (const color of ['rgb(NaN, 0, 0)', 'rgb(256, 0, 0)', 'rgba(0, 0, 0, 1.1)',
  'rgba(0, 0, 0, -0.1)', 'url(bad)', 'color(display-p3 1 0 0)']) {
  test('unsupported or invalid computed color keeps the underlying surface: ' + color, () => {
    const p = page();
    const child = p.node(color);
    p.document.hit = () => child;
    p.advance(80);
    assert.equal(p.messages[0].top[0].color, '#ffffff');
  });
}

test('missing edge hits or opaque colors request the native theme fallback', () => {
  const p = page();
  p.document.hit = () => null;
  p.advance(80);
  assert.deepEqual(p.messages, [{ top: [], bottom: [] }]);
  p.document.hit = () => p.body;
  p.body.background = 'transparent';
  p.mutate();
  p.advance(80);
  assert.equal(p.messages.length, 1);
});

test('complex edges cannot exceed the segment limit', () => {
  const p = page();
  const dark = p.node('rgb(21, 21, 23)');
  p.document.hit = x => Math.floor(x / 32) % 2 ? dark : p.body;
  p.advance(80);
  assert.deepEqual(p.messages[0], { top: [], bottom: [] });
  p.document.hit = x => Math.floor(x / (p.window.innerWidth / limit)) % 2 ? dark : p.body;
  p.mutate();
  p.advance(80);
  assert.equal(p.messages[1].top.length, limit);
  assert.equal(p.messages[1].top[0].start, 0);
  assert.equal(p.messages[1].top.at(-1).end, 1);
});

test('sidebar collapse, replacement and resize update samples without duplicate reports', () => {
  const p = page();
  const sidebar = p.node('rgb(247, 247, 248)');
  p.document.hit = x => x < 280 ? sidebar : p.body;
  p.advance(80);
  p.observers[0].callback();
  p.mutate();
  p.dispatch('transitionend');
  p.advance(80);
  assert.equal(p.messages.length, 1);
  p.document.hit = () => p.body;
  p.mutate();
  p.advance(80);
  assert.equal(p.messages.length, 2);
  assert.equal(p.messages[1].top.length, 1);
  assert.ok(!p.observers[0].targets.has(sidebar), 'detached columns are unobserved');
});

for (const event of ['resize', 'orientationchange', 'change', 'animationend', 'pageshow', 'load', 'scroll', 'visibilitychange']) {
  test(event + ' resamples the current viewport and theme', () => {
    const p = page();
    const sidebar = p.node('rgb(247, 247, 248)');
    p.document.hit = x => x < 280 ? sidebar : p.body;
    p.advance(80);
    p.window.innerWidth = 512;
    p.body.background = 'rgb(21, 21, 23)';
    p.dispatch(event);
    p.advance(80);
    assert.equal(p.messages.length, 2);
    assert.ok(Math.abs(p.messages[1].top[0].end * 512 - 280) <= 0.5);
    assert.equal(p.messages[1].top[1].color, '#151517');
  });
}

test('theme mutations debounce and continuous mutations still deliver within the cap', () => {
  const p = page();
  for (let i = 0; i < 4; i++) {
    p.advance(50);
    p.mutate();
  }
  assert.equal(p.messages.length, 0);
  p.advance(40);
  assert.equal(p.messages.length, 1);
  p.body.background = 'rgb(21, 21, 23)';
  p.mutate();
  p.advance(50);
  p.mutate();
  p.advance(79);
  assert.equal(p.messages.length, 1);
  p.advance(1);
  assert.equal(p.messages[1].top[0].color, '#151517');
});

test('mutation and resize events still work without ResizeObserver', () => {
  const p = page({ resize: false });
  p.advance(80);
  p.body.background = 'rgb(21, 21, 23)';
  p.mutate();
  p.advance(80);
  assert.equal(p.messages[1].bottom[0].color, '#151517');
});

for (const options of [{ frame: true }, { host: 'example.com' }, { protocol: 'https:' }, { bridge: false }]) {
  test('the sampler does not install outside the main local page: ' + JSON.stringify(options), () => {
    const p = page(options);
    p.advance(1000);
    assert.equal(p.messages.length, 0);
    assert.equal(p.observers.length, 0);
  });
}

test('a second installation does not duplicate observers or messages', () => {
  const p = page();
  p.install();
  p.advance(80);
  assert.equal(p.observers.length, 2);
  assert.equal(p.messages.length, 1);
});

test('the shipped Swift decoder and origin check reject hostile messages and URLs', () => {
  const start = source.indexOf('    struct EdgeBands: Equatable {');
  const end = source.indexOf('    static let edgeBandsMessageName', start);
  assert.ok(start > 0 && end > start);
  const trustStart = content.indexOf('        private func isTrustedPageURL(');
  const trustEnd = content.indexOf('        private func pollReadiness(', trustStart);
  assert.ok(trustStart > 0 && trustEnd > trustStart);
  const directory = mkdtempSync(join(tmpdir(), 'dsh-edge-bands-'));
  const swift = join(directory, 'decoder.swift');
  writeFileSync(swift, `import Foundation
enum MobileWebTuning {
${source.slice(start, end)}
}
struct PageTrust {
    let currentURL: URL
${content.slice(trustStart, trustEnd).replace('private func', 'func')}
}
let trust = PageTrust(currentURL: URL(string: "http://127.0.0.1:23456/?token=fake")!)
precondition(trust.isTrustedPageURL(URL(string: "http://127.0.0.1:23456/session")!))
for url in ["http://127.0.0.1:23457/", "http://127.0.0.1/", "http://localhost:23456/",
            "https://127.0.0.1:23456/", "http://example.com:23456/", "file:///private/tmp/page"] {
    precondition(!trust.isTrustedPageURL(URL(string: url)!), url)
}
typealias Bands = MobileWebTuning.EdgeBands
func segment(_ start: Any = 0.0, _ end: Any = 1.0, _ color: Any = "#f7f7f8") -> [String: Any] {
    ["start": start, "end": end, "color": color]
}
func accepts(_ row: Any) -> Bool { Bands(message: ["top": row, "bottom": []]) != nil }
precondition(accepts([]))
precondition(accepts([segment()]))
precondition(accepts([segment(0, 0.28), segment(0.28, 1, "#FFFFFF")]))
precondition(accepts((0..<Bands.maximumSegments).map {
    segment(Double($0) / Double(Bands.maximumSegments), Double($0 + 1) / Double(Bands.maximumSegments))
}))
let bands = Bands(message: ["top": [segment()], "bottom": [segment(0, 1, "#151517")]])!
precondition(bands.top[0].rgb == 0xf7f7f8 && bands.bottom[0].rgb == 0x151517)
for color in ["red", "#fff", "#12345678", "#-12345", "#+12345", "#gggggg", "#12345é", "#ffffff\\n", "url(file:///private)"] {
    precondition(!accepts([segment(0, 1, color)]), color)
}
for row: Any in [
    [segment(-0.1, 1)], [segment(0.1, 1)], [segment(0, 1.1)], [segment(0, 0.9)],
    [segment(0, 0)], [segment(0, 0.6), segment(0.5, 1)],
    [segment(0, 0.4), segment(0.5, 1)], [segment(0, Double.nan)],
    [segment(0, Double.infinity)], [segment(false, 1)], [segment(0, true)],
    [segment("0", 1)], [segment(0, 1, 123)], [[:]], "invalid", NSNull(),
    Array(repeating: segment(), count: Bands.maximumSegments + 1)
] { precondition(!accepts(row), String(describing: row)) }
precondition(Bands(message: ["top": []]) == nil)
precondition(Bands(message: []) == nil)
print("Swift edge-band decoder checks passed")
`);
  const output = execFileSync('/usr/bin/swift', ['-module-cache-path', join(directory, 'ModuleCache'), swift], {
    encoding: 'utf8', timeout: 60000,
  });
  assert.match(output, /Swift edge-band decoder checks passed/);
});
