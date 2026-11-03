#!/usr/bin/env node
// Before/after for the ICU-less `Intl` substitute, measured the same way.
//
//   node scripts/intl-shim-compare.mjs
//
// "Before" is `git show HEAD:sim/intl-shim.cjs` — the shim as step 2 left it.
// "After" is the working tree. Both are installed into a process with no `Intl`
// at all (that is the only condition under which they install), and both are
// asked the same eight instants around the two 2026 Sydney transitions.
//
// This is a host-side measurement of the shim, deliberately separate from the
// in-app run: a host Node has ICU, so the shim only installs after `Intl` is
// deleted, and the comparison then isolates the shim's own arithmetic. The in-app
// run (sim/tz-probe.mjs) is what proves the shim is what the app uses.
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';

// The table DeviceTimeZone.swift publishes for an Australia/Sydney device: one
// entry per DST transition, computed here from the platform's own zone database
// rather than typed in. A hand-written epoch is exactly the kind of number that
// looks right and is 32 minutes off, which is what the first version of this
// script did.
const DEVICE_TZ = (() => {
  const transitions = [];
  const zone = 'Australia/Sydney';
  const offsetAt = (ms) => {
    // Intl carries the platform tz database on the host; the app's Swift side
    // reads the same rules through TimeZone.nextDaylightSavingTimeTransition.
    const fmt = new Intl.DateTimeFormat('en-US', { timeZone: zone, timeZoneName: 'longOffset' });
    const name = fmt.formatToParts(new Date(ms)).find((p) => p.type === 'timeZoneName').value;
    const m = /GMT([+-])(\d{2}):(\d{2})/.exec(name);
    return m === null ? 0 : (m[1] === '-' ? -1 : 1) * (Number(m[2]) * 3600 + Number(m[3]) * 60);
  };
  // Scan hour by hour from a year back to two years ahead; a change in the
  // reported offset is a transition, and the exact second is then found by
  // bisection so the entry lands on the real boundary.
  const start = Date.parse('2025-10-01T00:00:00Z');
  const end = Date.parse('2028-10-01T00:00:00Z');
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
    offsetSeconds: offsetAt(Date.now()),
    capturedAt: new Date().toISOString(),
    horizonSeconds: Math.floor((end - Date.now()) / 1000),
    transitions,
  };
})();

const CASES = [
  ['2026-01-15T00:00:00Z', '2026-01-15 11:00', '+11:00'],
  ['2026-04-04T15:59:59Z', '2026-04-05 02:59', '+11:00'],
  ['2026-04-04T16:00:00Z', '2026-04-05 02:00', '+10:00'],
  ['2026-07-15T00:00:00Z', '2026-07-15 10:00', '+10:00'],
  ['2026-10-03T15:59:59Z', '2026-10-04 01:59', '+10:00'],
  ['2026-10-03T16:00:00Z', '2026-10-04 03:00', '+11:00'],
  ['2026-12-31T13:00:00Z', '2027-01-01 00:00', '+11:00'],
  ['2027-07-01T00:00:00Z', '2027-07-01 10:00', '+10:00'],
];

/** A child that deletes Intl, installs one shim, and reports its answers. */
function measure(shimPath /* null = "process local only", no shim */, zone /* explicit option or null */) {
  const script = `
    const cases = ${JSON.stringify(CASES)};
    const withZone = ${JSON.stringify(zone)};
    delete globalThis.Intl;
    if (${JSON.stringify(shimPath)}) require(${JSON.stringify(shimPath)}).installIntl();
    const out = { resolved: null, cases: [] };
    const opts = {
      year: '2-digit', month: '2-digit', day: '2-digit',
      hour: '2-digit', minute: '2-digit', second: '2-digit',
      hourCycle: 'h23', timeZoneName: 'longOffset',
      ...(withZone === null ? {} : { timeZone: withZone }),
    };
    try { out.resolved = new Intl.DateTimeFormat('en-US', opts).resolvedOptions().timeZone; }
    catch (e) { out.resolved = 'ERROR: ' + e.message; }
    for (const [iso, wall, offset] of cases) {
      try {
        const fmt = new Intl.DateTimeFormat('en-US', opts);
        const p = Object.fromEntries(fmt.formatToParts(new Date(iso)).map((x) => [x.type, x.value]));
        out.cases.push({
          iso, expected: { wall, offset },
          got: { wall: p.year + '-' + p.month + '-' + p.day + ' ' + p.hour + ':' + p.minute,
                 offset: (p.timeZoneName || '').replace(/^GMT/, '') },
        });
      } catch (e) { out.cases.push({ iso, error: String(e && e.message) }); }
    }
    process.stdout.write(JSON.stringify(out));
  `;
  const stdout = execFileSync(process.execPath, ['-e', script], {
    env: { ...process.env, DSHPORTE_DEVICE_TZ: JSON.stringify(DEVICE_TZ),
           // The host's own zone, so the "process local" column is a real value.
           TZ: 'Australia/Sydney' },
    encoding: 'utf8',
  });
  return JSON.parse(stdout);
}

// The shim as the previous commit left it, extracted once with
//   git show HEAD:sim/intl-shim.cjs > logs/step6/intl-shim-before.cjs
// rather than shelling out to git here: the command environment does not
// reliably carry git on PATH, and a measurement script that fails on that is a
// measurement script that lies about what it checked.
const beforePath = fileURLToPath(new URL('../logs/step6/intl-shim-before.cjs', import.meta.url));
const afterPath = fileURLToPath(new URL('../sim/intl-shim.cjs', import.meta.url));
if (!existsSync(beforePath)) {
  console.error(`missing ${beforePath}\n  create it with: git show HEAD:sim/intl-shim.cjs > logs/step6/intl-shim-before.cjs`);
  process.exit(2);
}
{
  const before = measure(beforePath, 'Australia/Sydney');
  const beforeNoZone = measure(beforePath, null);
  const after = measure(afterPath, 'Australia/Sydney');
  const afterNoZone = measure(afterPath, null);

  const matched = (result) => result.cases.filter((c) => c.got && c.got.wall === c.expected.wall && c.got.offset === c.expected.offset).length;

  console.log('shim comparison, Australia/Sydney, 8 instants around both 2026 transitions\n');
  console.log(`before, explicit timeZone  resolvedOptions=${before.resolved}  correct=${matched(before)}/8`);
  console.log(`before, no timeZone       resolvedOptions=${beforeNoZone.resolved}  correct=${matched(beforeNoZone)}/8`);
  console.log(`after,  explicit timeZone  resolvedOptions=${after.resolved}  correct=${matched(after)}/8`);
  console.log(`after,  no timeZone       resolvedOptions=${afterNoZone.resolved}  correct=${matched(afterNoZone)}/8`);
  console.log('\nper-instant detail (after, no timeZone — the path a formatter with no\n' +
              'explicit zone takes, which is what the profile now leaves it to):');
  for (const c of afterNoZone.cases) {
    const ok = c.got && c.got.wall === c.expected.wall && c.got.offset === c.expected.offset;
    console.log(`  ${ok ? 'OK  ' : 'BAD '} ${c.iso}  want ${c.expected.wall} ${c.expected.offset}  got ${c.got ? c.got.wall + ' ' + c.got.offset : c.error}`);
  }
  const ok = matched(after) === 8 && matched(afterNoZone) === 8;
  console.log(`\n${ok ? 'PASS' : 'FAIL'} after-shim is exact on all cases with and without an explicit zone`);
  process.exitCode = ok ? 0 : 1;
}
