// What zone does the ICU-less Intl see, after step 6?
//
// The question is narrow and the answer must come from inside the app: the shim
// answers a named zone from the transition table the Swift host publishes in
// `DSHPORTE_DEVICE_TZ`, so a host Node would be measuring a different
// environment (and a different libc).
//
// Gated by DSHPORTE_TZ_PROBE=1 from sim/ios-app-entry.mjs.
import { writeFileSync } from 'node:fs';

const home = process.env.DSH_HOME ?? '.';
const out = { at: new Date().toISOString(), node: process.version };

// ---------------------------------------------------------- the resolved zone
const formatter = new Intl.DateTimeFormat('en-US', {
  year: 'numeric', month: '2-digit', day: '2-digit',
  hour: '2-digit', minute: '2-digit', second: '2-digit',
  hourCycle: 'h23', timeZoneName: 'longOffset',
});
out.resolved = {
  // `dsh-time-context` and `dsh-util-time` both round-trip a zone through this
  // and require it to come back byte-identical, so this value is load-bearing.
  timeZone: formatter.resolvedOptions().timeZone,
  // What the host actually published, so a mismatch is visible as data.
  publishedIdentifier: (() => {
    try { return JSON.parse(process.env.DSHPORTE_DEVICE_TZ ?? 'null')?.identifier ?? null; } catch { return 'UNPARSEABLE'; }
  })(),
  publishedTransitions: (() => {
    try { return (JSON.parse(process.env.DSHPORTE_DEVICE_TZ ?? 'null')?.transitions ?? []).length; } catch { return null; }
  })(),
};

// ------------------------------------------------------------ DST comparisons
// Instants chosen on both sides of both 2026 Sydney transitions, plus a plain
// summer and a plain winter instant. Expectations are hand-computed from the
// published rules: AEDT (+11) until 2026-04-04T16:00Z, AEST (+10) until
// 2026-10-03T16:00Z, AEDT after.
const cases = [
  ['2026-01-15T00:00:00Z', 'mid-summer', '2026-01-15 11:00', '+11:00'],
  ['2026-04-04T15:59:59Z', 'second before fall-back', '2026-04-05 02:59', '+11:00'],
  ['2026-04-04T16:00:00Z', 'second after fall-back', '2026-04-05 02:00', '+10:00'],
  ['2026-07-15T00:00:00Z', 'mid-winter', '2026-07-15 10:00', '+10:00'],
  ['2026-10-03T15:59:59Z', 'second before spring-forward', '2026-10-04 01:59', '+10:00'],
  ['2026-10-03T16:00:00Z', 'second after spring-forward', '2026-10-04 03:00', '+11:00'],
  ['2027-01-01T13:00:00Z', 'new year', '2027-01-02 00:00', '+11:00'],
  ['2027-07-01T00:00:00Z', 'next winter', '2027-07-01 10:00', '+10:00'],
];

out.cases = cases.map(([iso, label, wall, offset]) => {
  let got;
  try {
    const parts = Object.fromEntries(formatter.formatToParts(new Date(iso)).map((p) => [p.type, p.value]));
    got = {
      wall: `${parts.year}-${parts.month}-${parts.day} ${parts.hour}:${parts.minute}`,
      offset: (parts.timeZoneName ?? '').replace(/^GMT$/, 'GMT+00:00').replace(/^GMT/, ''),
    };
  } catch (error) {
    got = { error: String(error && error.message) };
  }
  return { iso, label, expected: { wall, offset }, got, matches: got.wall === wall && got.offset === offset };
});

// ------------------------------------------------------------------- Date too
// DSH's shell clock formats through `Date` getters, not through Intl, so the two
// have to agree. If they did not, a single screen would show two times.
const sample = new Date('2026-10-28T09:28:37Z');
out.date = {
  getHours: sample.getHours(),
  getMinutes: sample.getMinutes(),
  getTimezoneOffset: sample.getTimezoneOffset(),
  toString: sample.toString(),
};

// The exact string DSH's time-context puts in front of the model.
const parts = Object.fromEntries(formatter.formatToParts(new Date()).map((p) => [p.type, p.value]));
const zone = formatter.resolvedOptions().timeZone;
out.modelStampShape = `${parts.year}-${parts.month}-${parts.day}T${parts.hour}:${parts.minute}:${parts.second}${(parts.timeZoneName ?? '').replace(/^GMT$/, 'GMT+00:00').slice(3)}[${zone}]`;

writeFileSync(`${home}/DSHPortE-tz-probe.json`, JSON.stringify(out, null, 2));
console.log('DSHPORTE_TZ_PROBE ' + JSON.stringify({
  timeZone: out.resolved.timeZone,
  published: out.resolved.publishedIdentifier,
  transitions: out.resolved.publishedTransitions,
  cases: `${out.cases.filter((c) => c.matches).length}/${out.cases.length}`,
  modelStampShape: out.modelStampShape,
}));
