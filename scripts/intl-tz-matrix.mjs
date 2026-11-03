#!/usr/bin/env node
// The matrix that matters: does the shim answer from the device table, or from
// whatever the process itself happens to think the time is?
//
//   node scripts/intl-tz-matrix.mjs
//
// WHY THIS MATRIX. On the device, `Date` already reports the right local offset
// (measured: `Wed Oct 28 2026 20:28:37 GMT+1100 (AEDT)`), so a shim that merely
// echoes the process offset would look correct in every test run on this phone —
// and would be wrong the moment the process's zone disagreed with the device's
// (a container that inherits a UTC environment, a phone that changes zone while
// the app runs, a future embedding).
//
// So the shim is exercised twice: with the process in Australia/Sydney, and with
// the process in UTC. Only a shim that reads the published table gives the same
// device-local answer in both. The old shim is measured the same way, which is
// what makes the "before" column a fact rather than a story.
//
// The zone rules come from the platform here, but on the device they come from
// `TimeZone.nextDaylightSavingTimeTransition` — the shim cannot tell the
// difference, because the shape is the same.
import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const before = fileURLToPath(new URL('../logs/step6/intl-shim-before.cjs', import.meta.url));
const after = fileURLToPath(new URL('../sim/intl-shim.cjs', import.meta.url));
if (!existsSync(before)) {
  console.error(`missing ${before}\n  create it with: git show HEAD:sim/intl-shim.cjs > logs/step6/intl-shim-before.cjs`);
  process.exit(2);
}

/** The table DeviceTimeZone.swift publishes, built from the platform's rules. */
function sydneyTable(nowMs = Date.now()) {
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

const PROBE = `
  const shim = process.env.SHIM;
  const withTable = process.env.TBL === 'present';
  delete globalThis.Intl;
  require(shim).installIntl();
  const q = (iso, opts = {}) => {
    try {
      const f = new Intl.DateTimeFormat('en-US', {
        year: 'numeric', month: '2-digit', day: '2-digit',
        hour: '2-digit', minute: '2-digit', hourCycle: 'h23', timeZoneName: 'longOffset', ...opts,
      });
      const p = Object.fromEntries(f.formatToParts(new Date(iso)).map((x) => [x.type, x.value]));
      return p.year + '-' + p.month + '-' + p.day + ' ' + p.hour + ':' + p.minute
        + (p.timeZoneName || '').replace(/^GMT/, '');
    } catch (error) { return 'THROWS: ' + error.message; }
  };
  const resolved = (opts) => {
    try { return new Intl.DateTimeFormat('en-US', opts).resolvedOptions().timeZone; }
    catch (error) { return 'THROWS'; }
  };
  process.stdout.write(JSON.stringify({
    processOffsetMinutes: new Date().getTimezoneOffset(),
    processToString: new Date('2026-10-28T09:28:37Z').toString(),
    namedZoneResolved: resolved({ timeZone: 'Australia/Sydney' }),
    noZoneResolved: resolved({}),
    summerNamed: q('2026-01-15T00:00:00Z', { timeZone: 'Australia/Sydney' }),
    winterNamed: q('2026-07-15T00:00:00Z', { timeZone: 'Australia/Sydney' }),
    summerNoZone: q('2026-01-15T00:00:00Z'),
    winterNoZone: q('2026-07-15T00:00:00Z'),
    beforeFallBack: q('2026-04-04T15:59:59Z', { timeZone: 'Australia/Sydney' }),
    afterFallBack: q('2026-04-04T16:00:00Z', { timeZone: 'Australia/Sydney' }),
    beforeSpringForward: q('2026-10-03T15:59:59Z', { timeZone: 'Australia/Sydney' }),
    afterSpringForward: q('2026-10-03T16:00:00Z', { timeZone: 'Australia/Sydney' }),
  }));
`;

function probe(shim, processZone, withTable, table) {
  // `node -e` does not put the extra argument on argv, so the shim path travels
  // in the environment like the table does.
  const env = { ...process.env, TZ: processZone, TBL: withTable ? 'present' : 'absent', SHIM: shim };
  delete env.DSHPORTE_DEVICE_TZ;
  if (withTable) env.DSHPORTE_DEVICE_TZ = JSON.stringify(table);
  return JSON.parse(execFileSync(process.execPath, ['-e', PROBE], { env, encoding: 'utf8' }));
}

const table = sydneyTable();
const EXPECT = {
  namedZoneResolved: 'Australia/Sydney',
  summerNamed: '2026-01-15 11:00+11:00',
  winterNamed: '2026-07-15 10:00+10:00',
  beforeFallBack: '2026-04-05 02:59+11:00',
  afterFallBack: '2026-04-05 02:00+10:00',
  beforeSpringForward: '2026-10-04 01:59+10:00',
  afterSpringForward: '2026-10-04 03:00+11:00',
};

const rows = [
  ['before shim, process in Sydney, no table', before, 'Australia/Sydney', false],
  ['before shim, process in UTC,    no table', before, 'UTC', false],
  ['after  shim, process in Sydney, table   ', after, 'Australia/Sydney', true],
  ['after  shim, process in UTC,    table   ', after, 'UTC', true],
  ['after  shim, process in UTC,    no table', after, 'UTC', false],
];

console.log('device zone Australia/Sydney. Each row is a separate Node process.\n');
const results = [];
for (const [label, shim, zone, withTable] of rows) {
  const got = probe(shim, zone, withTable, table);
  const correctNamed = Object.keys(EXPECT).filter((k) => k !== 'namedZoneResolved' && got[k] === EXPECT[k]).length;
  const correctNoZone = ['summerNoZone', 'winterNoZone'].filter((k) => got[k] === EXPECT[k.replace('NoZone', 'Named')]).length;
  results.push({ label, got, correctNamed, correctNoZone });
  console.log(`${label}`);
  console.log(`   process: offset=${got.processOffsetMinutes}min  ${got.processToString}`);
  console.log(`   resolved: named=${got.namedZoneResolved}  no-zone=${got.noZoneResolved}`);
  console.log(`   named-zone cases correct ${correctNamed}/6, no-zone cases correct ${correctNoZone}/2`);
  console.log(`   summer ${got.summerNamed}   winter ${got.winterNamed}`);
  console.log('');
}

// The load-bearing claim: an app whose process zone is UTC still shows Sydney
// time, because the answer comes from the table and not from the process.
const utcWithTable = results.find((r) => r.label.includes('after  shim, process in UTC,    table'));
const utcWithoutTable = results.find((r) => r.label.includes('after  shim, process in UTC,    no table'));
const checks = [
  ['with the table, a UTC process still reports Sydney time',
    utcWithTable.correctNamed === 6 && utcWithTable.correctNoZone === 2,
    `${utcWithTable.correctNamed}/6 named, ${utcWithTable.correctNoZone}/2 no-zone`],
  ['without the table, the shim falls back to the process zone and says so',
    utcWithoutTable.correctNamed === 0 || utcWithTable.got.namedZoneResolved !== utcWithoutTable.got.namedZoneResolved,
    `no-zone resolved ${utcWithoutTable.got.noZoneResolved}, summer ${utcWithoutTable.got.summerNamed}`],
  ['the device table is what makes the no-zone answer correct',
    utcWithTable.got.noZoneResolved === 'Australia/Sydney' && utcWithoutTable.got.noZoneResolved === 'UTC',
    `${utcWithTable.got.noZoneResolved} vs ${utcWithoutTable.got.noZoneResolved}`],
];

console.log('claims:');
let failed = 0;
for (const [name, ok, detail] of checks) {
  if (!ok) failed += 1;
  console.log(`  ${ok ? 'PASS' : 'FAIL'} ${name}  [${detail}]`);
}
console.log(failed === 0 ? '\nPASS all claims hold' : `\nFAIL ${failed} claim(s) do not hold`);
process.exitCode = failed === 0 ? 0 : 1;
