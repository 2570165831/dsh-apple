#!/usr/bin/env node
// Which clock did step 6 actually change, and is it right now?
//
//   node scripts/intl-callsite-audit.mjs
//
// WHY THIS EXISTS, AND WHY IT IS SCOPED THIS WAY.
//
// The task says "the interface time is fixed to UTC". Before claiming a fix, the
// report has to name WHICH clock that was. Two different runtimes format time
// here, and they need different fixes:
//
//   * The DSH *page* runs in WKWebView, i.e. in WebKit with full ICU and its own
//     `Intl`. Nothing this repo can put in Node touches it. Its clocks read the
//     device directly.
//   * The DSH *host* runs in nodejs-mobile with `v8_enable_i18n_support: 0`. Its
//     `Intl` comes from `sim/intl-shim.cjs`. `dsh-time-context` stamps every
//     model-visible turn from there, and it is validated by round-tripping the
//     zone through `Intl.DateTimeFormat`.
//
// A first version of this script audited the page's bundles too and "found" the
// page showing UTC — which was this script's own artefact: it deleted `Intl` and
// installed the shim in a Node process, then ran the page's option sets through
// it. That measured a runtime the page never executes in. The page's own clocks
// were already correct, and the measured page probe inside the app
// (logs/step6/clocks-app.json) is what says so.
//
// So this audit covers the HOST side only: its call sites, under both shims, at
// two instants (summer and winter) so a call site that is only right in one
// season is caught.
import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const before = fileURLToPath(new URL('../logs/step6/intl-shim-before.cjs', import.meta.url));
const after = fileURLToPath(new URL('../sim/intl-shim.cjs', import.meta.url));
if (!existsSync(before)) {
  console.error(`missing ${before}\n  create it with: git show HEAD:sim/intl-shim.cjs > logs/step6/intl-shim-before.cjs`);
  process.exit(2);
}

// A Sydney transition table computed from the platform's own rules, the way
// DeviceTimeZone.swift builds it. Computed, not typed: the first attempt at this
// fixture used hand-written epochs and was 32 minutes off, which silently turned
// a passing case into a failing one.
export function sydneyTable(nowMs = Date.now()) {
  const zone = 'Australia/Sydney';
  const offsetAt = (ms) => {
    const name = new Intl.DateTimeFormat('en-US', { timeZone: zone, timeZoneName: 'longOffset' })
      .formatToParts(new Date(ms)).find((p) => p.type === 'timeZoneName').value;
    const m = /GMT([+-])(\d{2}):(\d{2})/.exec(name);
    return m === null ? 0 : (m[1] === '-' ? -1 : 1) * (Number(m[2]) * 3600 + Number(m[3]) * 60);
  };
  const transitions = [];
  const start = nowMs - 365 * 24 * 3600 * 1000;
  const end = nowMs + 2 * 365 * 24 * 3600 * 1000;
  transitions.push({ at: Math.floor(start / 1000), offsetSeconds: offsetAt(start), name: '' });
  let cursor = start;
  let previous = offsetAt(start);
  while (cursor < end) {
    const next = cursor + 3600_000;
    const offset = offsetAt(next);
    if (offset !== previous) {
      let lo = cursor;
      let hi = next;
      while (hi - lo > 1000) {
        const mid = lo + Math.floor((hi - lo) / 2 / 1000) * 1000;
        if (offsetAt(mid) === previous) lo = mid; else hi = mid;
      }
      transitions.push({ at: Math.floor(hi / 1000), offsetSeconds: offsetAt(hi), name: '' });
      previous = offset;
    }
    cursor = next;
  }
  return {
    identifier: zone,
    offsetSeconds: offsetAt(nowMs),
    capturedAt: new Date(nowMs).toISOString(),
    horizonSeconds: Math.floor((end - nowMs) / 1000),
    transitions,
  };
}

// The HOST-side call sites: every place in a Node process that asks for a
// formatted time, with the option set copied verbatim from the shipped module.
const CASES = [
  {
    site: 'dsh-time-context  createTimestampFormatter',
    owns: 'lib/index.js:68 — the stamp prepended to every model turn',
    // What the model actually reads: parts joined as the plugin does it.
    kind: 'time-context',
    options: {
      year: 'numeric', month: '2-digit', day: '2-digit',
      hour: '2-digit', minute: '2-digit', second: '2-digit',
      hourCycle: 'h23', timeZoneName: 'longOffset',
    },
  },
  {
    site: 'dsh-time-context  browserTimeZone  canonicalisation',
    owns: 'lib/index.js:17 — resolvedOptions().timeZone, must echo the input',
    kind: 'resolved',
  },
  {
    site: 'dsh-util-time  canonicalClientTimeZone',
    owns: 'lib/index.js:22 — the same round trip at a wire boundary',
    kind: 'resolved',
  },
  {
    site: 'dsh-storage-json  filename timestamp',
    owns: 'lib/index.js:531 — getFullYear/getMonth/... via Date, not Intl',
    kind: 'date-getters',
  },
];

const INSTANTS = [
  ['2026-10-28T09:28:37Z', '2026-10-28 20:28 AEDT (+11)'],
  ['2026-07-15T00:00:00Z', '2026-07-15 10:00 AEST (+10)'],
];

const script = (shim, instant) => `
  const cases = ${JSON.stringify(CASES)};
  const instant = ${JSON.stringify(instant)};
  delete globalThis.Intl;
  require(${JSON.stringify(shim)}).installIntl();
  const out = { resolved: null, rows: [] };
  try { out.resolved = new Intl.DateTimeFormat('en-US', { timeZone: 'Australia/Sydney' }).resolvedOptions().timeZone; }
  catch (e) { out.resolved = 'ERROR'; }
  const d = new Date(instant);
  const pad = (n) => String(n).padStart(2, '0');
  for (const c of cases) {
    try {
      if (c.kind === 'date-getters') {
        out.rows.push({ site: c.site, owns: c.owns, ok: true,
          got: d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) + 'T' + pad(d.getHours()) + pad(d.getMinutes()) });
      } else if (c.kind === 'resolved') {
        let canonical;
        try { canonical = new Intl.DateTimeFormat('en-US', { timeZone: 'Australia/Sydney' }).resolvedOptions().timeZone; }
        catch (e) { canonical = 'THROWS'; }
        out.rows.push({ site: c.site, owns: c.owns, ok: canonical === 'Australia/Sydney',
          got: canonical, wanted: 'Australia/Sydney' });
      } else {
        const parts = Object.fromEntries(new Intl.DateTimeFormat('en-US', c.options)
          .formatToParts(d).map((p) => [p.type, p.value]));
        const offset = (parts.timeZoneName || '').replace(/^GMT$/, 'GMT+00:00').slice(3);
        out.rows.push({ site: c.site, owns: c.owns, ok: true,
          got: parts.year + '-' + parts.month + '-' + parts.day + 'T' + parts.hour + ':' + parts.minute + ':' + parts.second + offset });
      }
    } catch (e) {
      out.rows.push({ site: c.site, owns: c.owns, ok: false, got: 'THROWS: ' + e.message });
    }
  }
  process.stdout.write(JSON.stringify(out));
`;

function run(shim, instant, table) {
  return JSON.parse(execFileSync(process.execPath, ['-e', script(shim, instant)], {
    env: { ...process.env, TZ: 'Australia/Sydney', DSHPORTE_DEVICE_TZ: JSON.stringify(table) },
    encoding: 'utf8',
  }));
}

const table = sydneyTable();
// What each kind of row must produce, hand-derived from the device rules:
//   time-context  an ISO-shaped local stamp with the local offset;
//   resolved      the zone identifier echoed back unchanged (DSH requires it);
//   date-getters  the local wall clock as YYYY-MM-DDTHHMM (storage-json's own
//                 concatenation, which reads Date getters, not Intl).
const EXPECT = {
  'time-context': {
    '2026-10-28T09:28:37Z': '2026-10-28T20:28:37+11:00',
    '2026-07-15T00:00:00Z': '2026-07-15T10:00:00+10:00',
  },
  resolved: { '*': 'Australia/Sydney' },
  'date-getters': {
    '2026-10-28T09:28:37Z': '2026-10-28T2028',
    '2026-07-15T00:00:00Z': '2026-07-15T1000',
  },
};
const wanted = (kind, instant) => (EXPECT[kind]['*'] ?? EXPECT[kind][instant]);

console.log('host-side time formatting, device zone Australia/Sydney\n');

let afterBad = 0;
for (const [instant, label] of INSTANTS) {
  const b = run(before, instant, table);
  const a = run(after, instant, table);
  console.log(`instant ${instant}  (${label})`);
  console.log(`  resolvedOptions().timeZone   before=${b.resolved}   after=${a.resolved}`);
  for (let i = 0; i < a.rows.length; i += 1) {
    const rowA = a.rows[i];
    const rowB = b.rows[i];
    const want = wanted(CASES[i].kind, instant);
    const okA = rowA.got === want;
    if (!okA) afterBad += 1;
    console.log(`  ${okA ? 'OK  ' : 'BAD '} ${rowA.site}`);
    console.log(`        before ${JSON.stringify(rowB.got)}`);
    console.log(`        after  ${JSON.stringify(rowA.got)}   want ${JSON.stringify(want)}`);
  }
  console.log('');
}

console.log(afterBad === 0
  ? "PASS every host-side call site reports the device's local time"
  : `FAIL ${afterBad} host-side call site(s) still wrong`);
process.exitCode = afterBad === 0 ? 0 : 1;
