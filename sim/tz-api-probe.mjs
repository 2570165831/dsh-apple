// What do the page's own time APIs do in this ICU-less build?
//
// The chat row's clock uses `Date` getters, the trajectory timeline uses
// `Date.prototype.toLocaleTimeString`, and the tool view uses
// `Intl.DateTimeFormat`. Those are three different mechanisms, and step 6's
// report has to say which of them existed before the shim could help. In
// particular `toLocaleTimeString` is a V8 `Date` method: whether the shim's
// `Intl` has any influence on it is a fact, not a guess.
//
// Gated by DSHPORTE_TZ_PROBE=1 from sim/ios-app-entry.mjs.
import { writeFileSync } from 'node:fs';

const home = process.env.DSH_HOME ?? '.';
const instant = new Date('2026-10-28T09:28:37Z'); // 20:28 AEDT (+11)
const winter = new Date('2026-07-15T00:00:00Z');  // 10:00 AEST (+10)

const attempt = (label, fn) => {
  try { return { label, ok: true, value: String(fn()) }; }
  catch (error) { return { label, ok: false, value: 'THROWS: ' + (error && error.message ? error.message : error) }; }
};

const out = {
  at: new Date().toISOString(),
  node: process.version,
  deviceTable: process.env.DSHPORTE_DEVICE_TZ ? 'present' : 'absent',
  dateGetters: {
    summerHour: instant.getHours(),
    summerMinute: instant.getMinutes(),
    winterHour: winter.getHours(),
    offsetMinutesNow: new Date().getTimezoneOffset(),
    toStringNow: new Date().toString(),
  },
  // `Date.prototype.toLocaleTimeString` — the timeline tooltip's path.
  toLocaleTimeString: [
    attempt('no options', () => instant.toLocaleTimeString()),
    attempt('hms + fractionalSecondDigits', () => instant.toLocaleTimeString(undefined, {
      hour: '2-digit', minute: '2-digit', second: '2-digit', fractionalSecondDigits: 3,
    })),
    attempt('explicit zone Sydney', () => instant.toLocaleTimeString('en-US', { timeZone: 'Australia/Sydney', hour: '2-digit' })),
  ],
  // `Intl.DateTimeFormat.format` — the tool view's path.
  intlFormat: [
    attempt('tool formatDate option set', () => new Intl.DateTimeFormat('en-US', {
      year: 'numeric', month: 'short', day: 'numeric',
      hour: '2-digit', minute: '2-digit', second: '2-digit', timeZoneName: 'short',
    }).format(instant)),
    attempt('user-questions option set (hour12)', () => new Intl.DateTimeFormat(undefined, {
      hour: '2-digit', minute: '2-digit', hour12: false,
    }).format(instant)),
    attempt('chat row option set', () => new Intl.DateTimeFormat(undefined, {
      hour: '2-digit', minute: '2-digit',
    }).format(instant)),
    attempt('time-context option set', () => new Intl.DateTimeFormat('en-US', {
      year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit',
      second: '2-digit', hourCycle: 'h23', timeZoneName: 'longOffset',
    }).formatToParts(instant).map((p) => `${p.type}=${p.value}`).join(' ')),
  ],
};

writeFileSync(`${home}/DSHPortE-tz-api-probe.json`, JSON.stringify(out, null, 2));
console.log('DSHPORTE_TZ_API ' + JSON.stringify(out));
