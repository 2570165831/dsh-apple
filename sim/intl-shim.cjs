// A minimal `Intl` for a Node built without ICU.
//
// WHY THIS EXISTS
// ---------------
// nodejs-mobile v24.5.0 ships its iOS slices with `v8_enable_i18n_support: 0`
// (that flag is visible in the framework's own embedded build-configuration
// string). Measured inside the iOS 27 simulator, in logs/spike-probe4-i18n.log:
//
//   typeof Intl            -> "undefined"
//   new Intl.NumberFormat  -> ReferenceError: Intl is not defined
//   /\p{L}/                -> SyntaxError at PARSE time
//   'e\u0301'.normalize('NFKC') -> unchanged (2 code units instead of 1)
//
// DSH uses `Intl.DateTimeFormat` in a few server-side places that sit on the
// session-creation path:
//
//   * dsh-time-context builds a formatter in its plugin `apply()`. Without Intl
//     it throws "time-context: failed to resolve the system time zone", which the
//     UI shows as
//       agent-preset/invalid: time-context (@deepseek-ai/dsh-time-context):
//       time-context: failed to resolve the system time zone
//     and every attempt to create a session fails. This was the last blocker
//     between "the web UI renders" and "a conversation can run".
//   * dsh-util-time resolves a canonical zone label for a value.
//   * dsh-schedule does the same; that row is disabled in the ios-sim profile.
//
// WHAT IS IMPLEMENTED
// -------------------
// `Intl.DateTimeFormat` with the option set those call sites pass:
//   year, month, day, hour, minute, second   (numeric / 2-digit, hourCycle h23)
//   timeZoneName: "longOffset"               (rendered as "GMT+HH:MM")
//   timeZone: "UTC" | fixed offset | IANA name
//
// and the two methods they call: `format(date)` and `formatToParts(date)`, plus
// `resolvedOptions()`.
//
// WHAT IS NOT IMPLEMENTED, ON PURPOSE
// -----------------------------------
// `Intl.NumberFormat`, `Collator`, `PluralRules`, `Segmenter`, `ListFormat`,
// locale-aware month/weekday names, calendar systems, and DST transitions for
// arbitrary IANA zones. They are left undefined rather than faked, so code that
// genuinely needs i18n fails loudly instead of silently producing wrong output.
//
// Time-zone handling is the honest part to be precise about:
//   * "UTC" and explicit offsets ("+05:30") are exact.
//   * A named IANA zone is answered from a transition table the host supplies in
//     `DSHPORTE_DEVICE_TZ` (see `app/DSHPortC/DeviceTimeZone.swift`): the zone id,
//     its offset now, and every DST transition from a year back to two years
//     ahead. Inside that window the offset at any instant is exact, because it is
//     read from a transition the platform itself reported. Outside it, the last
//     known offset is used and `resolvedZoneSource` says `table-stale` rather
//     than pretending. With no table at all, a named zone falls back to the
//     process's own local offset (which IS correct — `Date` reads the platform's
//     `localtime_r` — but carries no DST history) and says `process-local`.
//     DSH's time-context validates a zone by round-tripping it through
//     `resolvedOptions().timeZone`, so the identifier is echoed back unchanged:
//     returning a canonicalised spelling would fail that check.
//
// This replaces the previous behaviour, where a named zone always answered UTC
// because the profile pinned `timeZone: UTC` to keep every call on the exact
// path. Step 6 removed that pin (see profiles/ios-sim/cordis.patch.yml).
//
// INSTALLATION
// ------------
// Loaded by `sim/ios-sim-preload.cjs` via `--require`, i.e. before any DSH
// module is imported, so every plugin sees the same global.

'use strict';

/** Zones whose offset is known exactly without a tz database. */
const FIXED_OFFSETS = new Map([
  ['UTC', 0],
  ['Etc/UTC', 0],
  ['GMT', 0],
  ['Etc/GMT', 0],
  ['Z', 0],
]);

/**
 * Parse an explicit offset zone like "+05:30", "-0800" or "GMT+2".
 * @param {string} zone
 * @returns {number|null} offset in minutes east of UTC, or null.
 */
function parseExplicitOffset(zone) {
  const text = String(zone).trim();
  const direct = /^([+-])(\d{2}):?(\d{2})$/.exec(text);
  if (direct) {
    const sign = direct[1] === '-' ? -1 : 1;
    return sign * (Number(direct[2]) * 60 + Number(direct[3]));
  }
  const gmt = /^GMT([+-])(\d{1,2})(?::?(\d{2}))?$/.exec(text);
  if (gmt) {
    const sign = gmt[1] === '-' ? -1 : 1;
    return sign * (Number(gmt[2]) * 60 + Number(gmt[3] ?? 0));
  }
  return null;
}

/** Whether a string looks like an IANA "Area/Location" zone name. */
function looksLikeIana(zone) {
  return /^[A-Za-z][A-Za-z0-9_+-]*(\/[A-Za-z0-9_+-]+)*$/.test(String(zone));
}

// ---------------------------------------------------------------- device table
// `process.env.DSHPORTE_DEVICE_TZ` is written by the Swift host on every launch:
//   {"identifier":"Australia/Sydney","offsetSeconds":39600,
//    "transitions":[{"at":<epoch s>,"offsetSeconds":<s>,"name":"AEDT"},…],
//    "capturedAt":"…","horizonSeconds":…}
// It is parsed once, lazily, and never mutated. A malformed value is treated as
// absent (with the reason recorded), because a wrong offset is worse than none.
let deviceTable;
let deviceTableError;

function readDeviceTable() {
  if (deviceTable !== undefined) return deviceTable;
  const raw = process.env.DSHPORTE_DEVICE_TZ;
  if (raw === undefined || raw === '') { deviceTable = null; return deviceTable; }
  try {
    const parsed = JSON.parse(raw);
    if (typeof parsed.identifier !== 'string' || !Array.isArray(parsed.transitions)) {
      throw new Error('missing identifier or transitions');
    }
    const transitions = parsed.transitions
      .filter((t) => t && Number.isFinite(t.at) && Number.isFinite(t.offsetSeconds))
      .map((t) => ({ at: Number(t.at), offsetSeconds: Number(t.offsetSeconds), name: String(t.name ?? '') }))
      .sort((a, b) => a.at - b.at);
    deviceTable = {
      identifier: parsed.identifier,
      offsetSeconds: Number(parsed.offsetSeconds ?? 0),
      transitions,
      horizonSeconds: Number(parsed.horizonSeconds ?? 0),
    };
  } catch (error) {
    deviceTable = null;
    deviceTableError = String((error && error.message) || error);
  }
  return deviceTable;
}

/**
 * Offset in minutes east of UTC for a zone at an instant, plus where the answer
 * came from.
 *
 * UTC and explicit offsets are exact. A named zone matching the device table is
 * answered from the table (exact inside its horizon, last-known beyond it).
 * Anything else falls back to the process's local offset, which `Date` derives
 * from the platform and is therefore correct for "now" but has no DST history.
 *
 * @param {string} zone
 * @param {number} epochMs
 * @returns {{minutes: number, source: string}}
 */
function offsetFor(zone, epochMs) {
  const name = String(zone);
  if (FIXED_OFFSETS.has(name)) return { minutes: FIXED_OFFSETS.get(name), source: 'fixed' };
  const explicit = parseExplicitOffset(name);
  if (explicit !== null) return { minutes: explicit, source: 'explicit' };

  const table = readDeviceTable();
  if (table !== null && table.identifier === name) {
    const seconds = epochMs / 1000;
    const last = table.transitions[table.transitions.length - 1];
    const beyond = last !== undefined && seconds > last.at + table.horizonSeconds;
    let chosen;
    for (const transition of table.transitions) {
      if (transition.at <= seconds) chosen = transition;
      else break;
    }
    if (chosen !== undefined) {
      return { minutes: chosen.offsetSeconds / 60, source: beyond ? 'table-stale' : 'table' };
    }
    // Before the table's first entry: the table's opening offset is the best
    // known value, and it is still a real number from the platform.
    return { minutes: table.offsetSeconds / 60, source: 'table-before-start' };
  }

  // `getTimezoneOffset` reports minutes WEST of UTC, so negate it.
  const local = -new Date(epochMs).getTimezoneOffset();
  return { minutes: local, source: looksLikeIana(name) ? 'process-local' : 'process-local' };
}

/**
 * Offset in minutes east of UTC for a zone at an instant.
 * @param {string} zone
 * @param {number} epochMs
 * @returns {number} minutes east of UTC.
 */
function offsetMinutes(zone, epochMs) {
  return offsetFor(zone, epochMs).minutes;
}

/** Zero-pad to two digits. */
function pad2(value) {
  return String(value).padStart(2, '0');
}

/**
 * Render an hour in the requested cycle.
 *
 * `h23` is what every DSH call site wants (`hour12: false`, or an explicit
 * `hourCycle`), but the option is accepted rather than refused so that an
 * `h12`/`h11` request produces 12-hour text instead of throwing inside a render.
 * @param {number} hour 0–23
 * @param {string} cycle one of h11, h12, h23, h24
 * @returns {string} the hour, two characters for h23/h24/h11
 */
function formatHour(hour, cycle) {
  switch (cycle) {
    case 'h11': return pad2(hour % 12);
    case 'h12': return String(hour % 12 === 0 ? 12 : hour % 12);
    case 'h24': return String(hour === 0 ? 24 : hour);
    default: return pad2(hour);
  }
}

/** Format an offset as "GMT±HH:MM". */
function formatOffsetGmt(minutes) {
  const sign = minutes < 0 ? '-' : '+';
  const abs = Math.abs(minutes);
  return `GMT${sign}${pad2(Math.floor(abs / 60))}:${pad2(abs % 60)}`;
}

/**
 * The zone a formatter uses when the caller named none.
 *
 * A real `Intl.DateTimeFormat()` defaults to the host's zone. This build has no
 * ICU, so there is nothing to ask — but the app's Swift host publishes the
 * device zone, and *that* is what "the host's zone" means here. Reporting `UTC`
 * was the step-2 workaround; it is why the interface showed a UTC clock.
 *
 * @returns {string} the device's zone identifier, or 'UTC' when none is known.
 */
function defaultZone() {
  const table = readDeviceTable();
  return table !== null && typeof table.identifier === 'string' ? table.identifier : 'UTC';
}

/**
 * A subset DateTimeFormat.
 *
 * Only the fields DSH asks for are supported. An unsupported option throws, so a
 * caller cannot silently receive a wrongly formatted string.
 */
class DateTimeFormat {
  /** @param {string|string[]} locales @param {object} [options] */
  constructor(locales, options = {}) {
    this._locale = Array.isArray(locales) ? locales[0] : locales;
    this._options = { ...options };

    const supported = new Set([
      'year', 'month', 'day', 'hour', 'minute', 'second',
      'hourCycle', 'hour12', 'timeZone', 'timeZoneName', 'fractionalSecondDigits',
    ]);
    for (const key of Object.keys(this._options)) {
      if (!supported.has(key)) {
        throw new RangeError(
          `intl-shim: DateTimeFormat option ${JSON.stringify(key)} is not implemented ` +
          `by this ICU-less build; supported: ${[...supported].join(', ')}`
        );
      }
    }
    // `hour12` is the older spelling of `hourCycle`, and DSH's user-questions view
    // asks for `hour12: false`. Refusing it threw a RangeError inside a render,
    // which is worse than the wrong clock: the row did not appear at all. Measured
    // inside the app before this was supported (logs/step6/tz-api-probe.json).
    if (this._options.hour12 !== undefined) {
      this._hourCycle = this._options.hour12 ? 'h12' : 'h23';
    } else if (this._options.hourCycle !== undefined) {
      this._hourCycle = String(this._options.hourCycle);
    } else {
      this._hourCycle = 'h23';
    }
    if (this._options.timeZone !== undefined && offsetMinutes(this._options.timeZone, Date.now()) === undefined) {
      throw new RangeError(`intl-shim: invalid timeZone ${JSON.stringify(this._options.timeZone)}`);
    }
    // Resolved once, at construction, exactly as a real formatter does: the zone
    // does not change under a live formatter even if the clock does.
    this._zone = this._options.timeZone ?? defaultZone();
  }

  /** @returns {object} the resolved options, with a canonical zone label. */
  resolvedOptions() {
    return {
      locale: this._locale ?? 'en-US',
      calendar: 'gregory',
      numberingSystem: 'latn',
      timeZone: String(this._zone),
      hourCycle: this._hourCycle,
      hour12: this._hourCycle !== 'h23' && this._hourCycle !== 'h24',
      year: this._options.year,
      month: this._options.month,
      day: this._options.day,
      hour: this._options.hour,
      minute: this._options.minute,
      second: this._options.second,
      timeZoneName: this._options.timeZoneName,
    };
  }

  /**
   * @param {Date|number} date
   * @returns {{type: string, value: string}[]} ordered parts.
   */
  formatToParts(date) {
    const epochMs = date instanceof Date ? date.getTime() : Number(date);
    if (!Number.isFinite(epochMs)) throw new RangeError('intl-shim: invalid date');
    const zone = this._zone;
    const shift = offsetMinutes(zone, epochMs) * 60_000;
    // Build the wall-clock fields by shifting the instant, then reading UTC.
    const wall = new Date(epochMs + shift);
    const parts = [];
    if (this._options.year) parts.push({ type: 'year', value: String(wall.getUTCFullYear()) });
    if (this._options.month) parts.push({ type: 'month', value: pad2(wall.getUTCMonth() + 1) });
    if (this._options.day) parts.push({ type: 'day', value: pad2(wall.getUTCDate()) });
    if (this._options.hour) parts.push({ type: 'hour', value: formatHour(wall.getUTCHours(), this._hourCycle) });
    if (this._options.minute) parts.push({ type: 'minute', value: pad2(wall.getUTCMinutes()) });
    if (this._options.second) parts.push({ type: 'second', value: pad2(wall.getUTCSeconds()) });
    // `fractionalSecondDigits: 3` is what the trajectory view's clock asks for
    // (`toLocaleTimeString` with milliseconds); without it the value would be
    // silently absent from the string that function builds.
    if (this._options.fractionalSecondDigits) {
      parts.push({ type: 'fractionalSecond', value: String(wall.getUTCMilliseconds()).padStart(3, '0') });
    }
    if (this._options.timeZoneName === 'longOffset' || this._options.timeZoneName === 'short') {
      parts.push({ type: 'timeZoneName', value: formatOffsetGmt(offsetMinutes(zone, epochMs)) });
    }
    return parts;
  }

  /**
   * @param {Date|number} date
   * @returns {string} the parts joined in a stable order.
   */
  format(date) {
    const parts = this.formatToParts(date);
    // Only the ordering DSH's timestamp formatter rebuilds is meaningful here;
    // the separator text is not consumed. Join with spaces so the result is
    // readable if anything ever logs it directly.
    return parts.map((part) => part.value).join(' ');
  }

  /** @param {Date|number} date @returns {string} */
  formatRange(start, end) {
    return `${this.format(start)} – ${this.format(end)}`;
  }
}

/** Whether `Intl` needs installing at all. */
function installIntl() {
  if (typeof globalThis.Intl !== 'undefined') {
    return { installed: false, reason: 'Intl already present' };
  }
  const IntlShim = {
    DateTimeFormat,
    DateTimeFormatToParts: undefined,
    // Present so feature detection that only checks for the object still works,
    // but deliberately without NumberFormat/Collator/etc: see the header.
    getCanonicalLocales(locales) {
      if (locales === undefined) return [];
      const list = Array.isArray(locales) ? locales : [locales];
      return list.map((value) => String(value));
    },
  };
  Object.defineProperty(globalThis, 'Intl', {
    value: IntlShim,
    writable: true,
    configurable: true,
    enumerable: false,
  });
  return {
    installed: true,
    provided: ['DateTimeFormat', 'getCanonicalLocales'],
    omitted: ['NumberFormat', 'Collator', 'PluralRules', 'Segmenter', 'ListFormat', 'RelativeTimeFormat', 'DisplayNames'],
  };
}

module.exports = { installIntl, DateTimeFormat, offsetMinutes };
