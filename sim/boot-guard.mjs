// Boot accounting for the iOS app: did the last launch come up, and should the
// next one skip its plugins ("safe mode")?
//
// WHY THIS EXISTS
// ---------------
// On the phone the only way out of a launch that fails every time is to delete
// and reinstall the app, which also deletes the user's sessions. The process
// that would remember the failure is the one that failed, so the record has to
// be on disk, written before the risky work starts and read by the NEXT launch.
//
// WHO WRITES WHAT
// ---------------
// Four small files, and each has exactly ONE writer. That is the whole point:
// two writers on one JSON file means a lost update precisely when the app is
// already broken.
//
//   boot-guard.json      this module     the current attempt, the failure
//                                        streak, the mode decision, history
//   boot-outcome.json    Swift host     the terminal answer for one launch id:
//                                        the page painted, or the launch failed
//   boot-background.txt  Swift host     the launch id, written when the app
//                                        enters the background (see below)
//   boot-request.json    Swift host     one command for the next launch
//                                        (`exit-safe-mode`, `clear-guard`, or
//                                        one this module leaves to its caller)
//
// `beginLaunch()` runs at the very top of `sim/ios-app-entry.mjs`, before DSH is
// imported. It settles the previous launch, decides this launch's mode, and
// writes the new attempt. `noteProgress()`, `noteSuccess()` and `noteFailure()`
// close or advance that attempt from Node. On iOS the page-ready signal is
// Swift's (`WKWebView.didFinish`), which is why the success outcome arrives as a
// file rather than as a call; the same transition is available in-process as
// `noteSuccess()` for any caller that does see it.
//
// WHAT COUNTS AS FAILED, AND WHAT ONLY LOOKS LIKE IT
// --------------------------------------------------
// A launch that never closed its attempt and left a background marker was
// terminated while the app was in the background: the user swiped it away, or
// iOS reclaimed it. That is NOT a failure, and counting it would drive a user
// into safe mode for closing an app that was merely slow. A launch that never
// closed its attempt and has no marker died in the foreground, which is a crash
// or a kill for CPU/memory; that IS counted, with the phase it reached as the
// reason.
//
// CORRUPT OR MISSING RECORD
// -------------------------
// A missing, truncated or unparsable state file is treated as "no failures on
// record", never as an error: this mechanism exists to rescue a broken app, and
// a broken counter must not be the thing that stops a boot. Write failures are
// reported in the return value and otherwise ignored.
//
// Writes are atomic: temp file in the same directory, fsync, rename, fsync of
// the directory. A half-written state file is what the "corrupt" path above
// exists to survive, but it should never be produced in the first place.

import {
  closeSync, fsyncSync, mkdirSync, openSync, readFileSync, renameSync, unlinkSync, writeFileSync,
  writeSync,
} from 'node:fs';
import { dirname } from 'node:path';

/** Schema version of `boot-guard.json`; a file from a FUTURE version is ignored. */
export const STATE_VERSION = 1;

/** Consecutive failed launches that make the next launch run in safe mode. */
export const DEFAULT_THRESHOLD = 3;

/**
 * How long a failure streak stays relevant.
 *
 * "Three in a row" is about a broken build, not about three failures across a
 * fortnight. Without a window the counter only ever grows, and a user whose app
 * failed twice last month enters safe mode on their next unrelated failure. Zero
 * disables the decay.
 */
export const DEFAULT_FAILURE_WINDOW_MS = 15 * 60 * 1000;

/** How many closed attempts are kept. Enough to explain the last few boots. */
export const HISTORY_LIMIT = 20;

/**
 * The steps an attempt can report, in order.
 *
 * `entry` is written by `beginLaunch()` itself, `launcher` after the DSH launcher
 * module is imported, `dsh` once `runCli()` has been called. Anything past that
 * is Swift's phase machine, and reaches this module only through the outcome
 * file.
 */
export const ATTEMPT_PHASES = Object.freeze(['entry', 'launcher', 'dsh']);

/** File names inside the app's boot directory; the Swift host uses the same ones. */
export const BOOT_FILES = Object.freeze({
  state: 'boot-guard.json',
  outcome: 'boot-outcome.json',
  request: 'boot-request.json',
  background: 'boot-background.txt',
  overlay: 'safe-mode.patch.yml',
  resetPreview: 'reset-plan.json',
  exportRequest: 'export-request.json',
  exportDone: 'export-done.json',
});

/** The decisions `beginLaunch()` can return as this launch's mode. */
export const MODES = Object.freeze(['normal', 'safe', 'probe']);

/** Requests this module handles itself. Anything else is the caller's job. */
const OWN_REQUESTS = new Set(['exit-safe-mode', 'clear-guard']);

/** The state a launch starts from when there is no usable file. */
export function emptyState(threshold = DEFAULT_THRESHOLD) {
  return {
    version: STATE_VERSION,
    threshold: asThreshold(threshold),
    failures: 0,
    lastFailureAt: null,
    safeMode: false,
    safeModeReason: null,
    safeModeSince: null,
    safeModeFailures: 0,
    probeAfterSafeSuccess: false,
    lastOutcome: null,
    attempt: null,
    history: [],
  };
}

// ---------------------------------------------------------------- tiny readers

function message(error) {
  return error && error.message ? error.message : String(error);
}

function asCount(value, fallback = 0) {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0
    ? Math.floor(value)
    : fallback;
}

function asThreshold(value) {
  const count = asCount(value, DEFAULT_THRESHOLD);
  return count >= 1 ? count : DEFAULT_THRESHOLD;
}

function asString(value) {
  return typeof value === 'string' && value.length > 0 ? value : null;
}

function asIsoString(value) {
  if (typeof value !== 'string' || value.length === 0) return null;
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? new Date(parsed).toISOString() : null;
}

function toIso(value) {
  if (value === undefined || value === null) return new Date().toISOString();
  const date = value instanceof Date ? value : new Date(value);
  if (!Number.isFinite(date.getTime())) throw new TypeError(`not a date: ${String(value)}`);
  return date.toISOString();
}

/**
 * Read one JSON file without throwing.
 *
 * @param {string} file
 * @returns {{value: unknown, status: 'ok'|'missing'|'corrupt'|'unreadable', error?: string}}
 */
function readJsonFile(file) {
  let text;
  try {
    text = readFileSync(file, 'utf8');
  } catch (error) {
    if (error && error.code === 'ENOENT') return { value: undefined, status: 'missing' };
    return { value: undefined, status: 'unreadable', error: message(error) };
  }
  try {
    return { value: JSON.parse(text), status: 'ok' };
  } catch (error) {
    return { value: undefined, status: 'corrupt', error: `not JSON: ${message(error)}` };
  }
}

/** Read one small text file without throwing. Empty means "absent". */
function readTextFile(file) {
  try {
    const text = readFileSync(file, 'utf8');
    const trimmed = text.trim();
    return { value: trimmed.length > 0 ? trimmed : undefined, status: 'ok' };
  } catch (error) {
    if (error && error.code === 'ENOENT') return { value: undefined, status: 'missing' };
    return { value: undefined, status: 'unreadable', error: message(error) };
  }
}

/**
 * Read `boot-outcome.json` as a list of records.
 *
 * WHY THIS IS A LIST AND NOT ONE RECORD
 * -------------------------------------
 * A launch can fail BEFORE Node starts: `prepareAndLaunch` throws on a missing
 * `payload/`, and the fail-fast switch does the same. Node then never runs, so
 * nothing ever consumes the file, and one-record-per-file would mean each new
 * failure OVERWRITES the previous one — the counter would sit at 0 while the app
 * failed every single launch, which is exactly the situation safe mode exists for.
 * Measured on the simulator: three consecutive failures left `boot-guard.json`
 * absent and one outcome line on disk.
 *
 * So this side appends one JSON object per line (the app writes it, this module is
 * the only reader and the only thing that deletes it), and the whole list is
 * settled on the next `beginLaunch()`. A file holding a single pretty-printed
 * object — the format an earlier build wrote, and what the tests below still
 * write — is accepted too, so nothing has to be migrated.
 *
 * @param {string} file
 * @returns {{records: object[], status: string, error?: string}}
 */
function readOutcomeRecords(file) {
  if (typeof file !== 'string' || file.length === 0) return { records: [], status: 'missing' };
  let text;
  try {
    text = readFileSync(file, 'utf8');
  } catch (error) {
    if (error && error.code === 'ENOENT') return { records: [], status: 'missing' };
    return { records: [], status: 'unreadable', error: message(error) };
  }
  if (text.trim().length === 0) return { records: [], status: 'missing' };
  // A single object, possibly pretty-printed: the earlier format, and what the
  // tests and a hand-written fixture produce.
  const trimmed = text.trim();
  if (trimmed.startsWith('{') && !trimmed.includes('\n{')) {
    try {
      return { records: [JSON.parse(trimmed)], status: 'ok' };
    } catch { /* fall through to the line reader */ }
  }
  const records = [];
  const errors = [];
  for (const line of text.split('\n')) {
    const candidate = line.trim();
    if (candidate.length === 0) continue;
    try {
      records.push(JSON.parse(candidate));
    } catch {
      // One bad line costs that line, not the whole file: a half-written append
      // (the process died mid-write) would otherwise discard every earlier
      // failure and drive the counter back to zero.
      errors.push(candidate.slice(0, 40));
    }
  }
  if (records.length === 0 && errors.length > 0) {
    return { records: [], status: 'corrupt', error: `no parsable record (${errors.length} bad line(s))` };
  }
  return errors.length === 0
    ? { records, status: 'ok' }
    : { records, status: 'ok', error: `${errors.length} unparsable line(s) skipped` };
}

// ---------------------------------------------------------------- state shape

/**
 * Coerce a parsed file into the current schema.
 *
 * Every field is checked and defaulted on its own, because a single bad field
 * (a string where a count belongs, a null attempt) must cost that field, not the
 * whole record. An unknown-but-valid attempt is kept: the point of the attempt
 * is to be settled by the next launch.
 *
 * @param {unknown} raw
 * @param {{threshold?: number}} [options]
 * @returns {object} a state object that is always safe to mutate and write
 */
export function normalizeState(raw, { threshold = DEFAULT_THRESHOLD } = {}) {
  const state = emptyState(threshold);
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) return state;
  if (raw.threshold !== undefined) state.threshold = asThreshold(raw.threshold);
  state.failures = asCount(raw.failures, 0);
  state.lastFailureAt = asIsoString(raw.lastFailureAt);
  state.safeMode = raw.safeMode === true;
  state.safeModeReason = asString(raw.safeModeReason);
  state.safeModeSince = asIsoString(raw.safeModeSince);
  state.safeModeFailures = asCount(raw.safeModeFailures, 0);
  state.probeAfterSafeSuccess = raw.probeAfterSafeSuccess === true;
  state.lastOutcome = isPlainObject(raw.lastOutcome) ? {
    at: asIsoString(raw.lastOutcome.at),
    kind: asString(raw.lastOutcome.kind),
    reason: asString(raw.lastOutcome.reason),
    phase: asString(raw.lastOutcome.phase),
    mode: asString(raw.lastOutcome.mode),
  } : null;
  state.attempt = isAttemptRecord(raw.attempt) ? {
    id: raw.attempt.id,
    startedAt: asIsoString(raw.attempt.startedAt) ?? state.lastOutcome?.at ?? null,
    phase: ATTEMPT_PHASES.includes(raw.attempt.phase) ? raw.attempt.phase : 'entry',
    phaseAt: asIsoString(raw.attempt.phaseAt),
    mode: MODES.includes(raw.attempt.mode) ? raw.attempt.mode : 'normal',
    backgroundedAt: asIsoString(raw.attempt.backgroundedAt),
  } : null;
  state.history = Array.isArray(raw.history)
    ? raw.history.filter(isPlainObject).map((entry) => ({
      id: asString(entry.id) ?? 'unknown',
      startedAt: asIsoString(entry.startedAt),
      endedAt: asIsoString(entry.endedAt),
      kind: asString(entry.kind) ?? 'unknown',
      reason: asString(entry.reason),
      phase: asString(entry.phase),
      mode: asString(entry.mode),
    })).slice(-HISTORY_LIMIT)
    : [];
  return state;
}

function isPlainObject(value) {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function isAttemptRecord(value) {
  return isPlainObject(value) && asString(value.id) !== null;
}

function isOutcomeRecord(value) {
  return isPlainObject(value)
    && asString(value.launchId) !== null
    && (value.kind === 'success' || value.kind === 'failure');
}

function isRequestRecord(value) {
  return isPlainObject(value) && asString(value.action) !== null;
}

/**
 * Read `boot-guard.json`, tolerating every failure mode.
 *
 * @param {string} file
 * @returns {{state: object, status: 'ok'|'missing'|'corrupt'|'unreadable'|'unsupported-version',
 *            error?: string}}
 */
export function readStateFile(file) {
  if (typeof file !== 'string' || file.length === 0) {
    return { state: emptyState(), status: 'missing', error: 'no state file configured' };
  }
  let text;
  try {
    text = readFileSync(file, 'utf8');
  } catch (error) {
    if (error && error.code === 'ENOENT') return { state: emptyState(), status: 'missing' };
    return { state: emptyState(), status: 'unreadable', error: message(error) };
  }
  let raw;
  try {
    raw = JSON.parse(text);
  } catch (error) {
    return { state: emptyState(), status: 'corrupt', error: `not JSON: ${message(error)}` };
  }
  if (!isPlainObject(raw)) {
    return { state: emptyState(), status: 'corrupt', error: 'not a JSON object' };
  }
  const version = asCount(raw.version, STATE_VERSION);
  if (version > STATE_VERSION) {
    // Written by a newer build. Its fields cannot be trusted here, and guessing
    // at them is worse than starting from "no failures on record".
    return { state: emptyState(), status: 'unsupported-version', error: `state version ${version}` };
  }
  return { state: normalizeState(raw), status: 'ok' };
}

/** Write one JSON file atomically (temp + fsync + rename + directory fsync). */
export function writeJsonAtomic(file, value) {
  const directory = dirname(file);
  mkdirSync(directory, { recursive: true });
  const temp = `${file}.${process.pid}.${Math.random().toString(16).slice(2)}.tmp`;
  const fd = openSync(temp, 'w');
  try {
    writeSync(fd, `${JSON.stringify(value, null, 2)}\n`);
    fsyncSync(fd);
  } catch (error) {
    closeSync(fd);
    try { unlinkSync(temp); } catch { /* the original file is untouched */ }
    throw error;
  }
  closeSync(fd);
  try {
    renameSync(temp, file);
  } catch (error) {
    try { unlinkSync(temp); } catch { /* best effort */ }
    throw error;
  }
  // The rename is durable only once the directory entry is. Best effort: some
  // platforms refuse to open a directory, and the file itself is already written.
  try {
    const handle = openSync(directory, 'r');
    try { fsyncSync(handle); } finally { closeSync(handle); }
  } catch { /* not fatal */ }
}

/**
 * Rewrite `boot-outcome.json` keeping only the records this launch did not settle.
 *
 * What is kept and why: records naming THIS launch (written by Swift before Node
 * started, and settled by the next launch) and records that are not records this
 * version understands (deleted rather than kept, because nothing will ever read
 * them). Everything that was settled is gone, so a failure cannot be counted
 * twice.
 *
 * A file that ends up with no kept records is deleted outright rather than
 * rewritten as an empty file: an empty file and a missing one mean the same thing
 * to `readOutcomeRecords`, and deleting is one fewer state to reason about.
 *
 * @param {string} file
 * @param {object[]} records what the file held before this launch settled anything
 * @param {string} launchId
 */
function consumeOutcomes(file, records, launchId) {
  if (records.length === 0) {
    unlinkQuiet(file);
    return;
  }
  const keep = records.filter((record) => isPlainObject(record) && record.launchId === launchId);
  if (keep.length === records.length) return; // nothing was consumed
  if (keep.length === 0) {
    unlinkQuiet(file);
    return;
  }
  try {
    writeFileSync(file, `${keep.map((record) => JSON.stringify(record)).join('\n')}\n`);
  } catch {
    // Left in place: the next launch settles the same records again, which is
    // wrong by one count in one direction, and that is the safe direction — it
    // can only ever make the counter more likely to reach the threshold, never
    // less, and the alternative (a delete that fails half way) loses failures.
  }
}

function unlinkQuiet(file) {
  if (typeof file !== 'string' || file.length === 0) return false;
  try { unlinkSync(file); return true; } catch { return false; }
}

// ------------------------------------------------------------------- verdicts

/**
 * Turn one closed attempt into the counter's input.
 *
 * `mode` is what the attempt ran in: a failure in `probe` mode (a normal-mode
 * trial launched from safe mode) goes straight back to safe mode instead of
 * asking the user for three more failures.
 */
function applyVerdict(state, verdict, { at, windowMs, threshold }) {
  const mode = verdict.mode ?? 'normal';
  if (verdict.kind === 'success') {
    state.failures = 0;
    state.lastFailureAt = null;
    state.safeModeFailures = 0;
    if (mode === 'safe') {
      // Safe mode came up, which says the app can still run, but says nothing
      // about the composition that failed. The next launch tries it once.
      state.probeAfterSafeSuccess = true;
      state.safeMode = true;
      state.safeModeReason = state.safeModeReason ?? 'safe mode came up';
    } else {
      state.probeAfterSafeSuccess = false;
      state.safeMode = false;
      state.safeModeReason = null;
      state.safeModeSince = null;
    }
  } else if (verdict.kind === 'failure') {
    state.failures += 1;
    state.lastFailureAt = at;
    if (mode === 'safe') state.safeModeFailures += 1;
    if (mode === 'probe') {
      // The trial failed: back to safe mode now, not after two more bad launches.
      state.safeMode = true;
      state.safeModeReason = verdict.reason ?? 'the normal composition failed after safe mode';
      state.safeModeSince = state.safeModeSince ?? at;
      state.failures = Math.max(state.failures, threshold);
      state.probeAfterSafeSuccess = false;
    } else if (state.failures >= threshold) {
      state.safeMode = true;
      state.safeModeReason = verdict.reason ?? `${state.failures} launches in a row failed`;
      state.safeModeSince = state.safeModeSince ?? at;
    }
  }
  // 'abandoned' changes nothing: it is neither evidence for nor against the app.
  state.lastOutcome = {
    at,
    kind: verdict.kind,
    reason: verdict.reason ?? null,
    phase: verdict.phase ?? null,
    mode,
  };
}

function fromOutcome(outcome) {
  return {
    kind: outcome.kind === 'success' ? 'success' : 'failure',
    level: asString(outcome.level) ?? 'page',
    reason: asString(outcome.reason) ?? (outcome.kind === 'success' ? 'the page came up' : 'the launch failed'),
    phase: asString(outcome.phase) ?? null,
  };
}

/**
 * Decide what a launch that never wrote an outcome means.
 *
 * The background marker is the only evidence available, and it is decisive in
 * one direction only: with it, the app was not in the foreground when it ended,
 * so it was not the boot that failed. Without it, the process disappeared while
 * the user was looking at it, which is a crash or a foreground kill.
 */
function classifySilentEnd(attempt, markerLaunchId) {
  if (attempt.backgroundedAt !== null && attempt.backgroundedAt !== undefined) {
    return {
      kind: 'abandoned',
      reason: 'the app was in the background when this launch ended',
      phase: attempt.phase ?? null,
    };
  }
  if (typeof markerLaunchId === 'string' && markerLaunchId === attempt.id) {
    return {
      kind: 'abandoned',
      reason: 'the app was in the background when this launch ended',
      phase: attempt.phase ?? null,
    };
  }
  return {
    kind: 'failure',
    reason: `the process ended during boot (last step: ${attempt.phase ?? 'unknown'})`,
    phase: attempt.phase ?? null,
  };
}

function historyEntry(verdict) {
  return {
    id: verdict.id ?? 'unknown',
    startedAt: verdict.startedAt ?? null,
    endedAt: verdict.endedAt ?? null,
    kind: verdict.kind,
    reason: verdict.reason ?? null,
    phase: verdict.phase ?? null,
    mode: verdict.mode ?? null,
  };
}

// ----------------------------------------------------------------- public API

/**
 * Start of a launch: settle the previous one, decide this one's mode.
 *
 * @param {object} options
 * @param {string} options.stateFile absolute `boot-guard.json`
 * @param {string} options.launchId this launch's id (the Swift host mints it)
 * @param {string} [options.outcomeFile] absolute `boot-outcome.json`
 * @param {string} [options.backgroundFile] absolute `boot-background.txt`
 * @param {string} [options.requestFile] absolute `boot-request.json`
 * @param {Date|number|string} [options.now] for tests
 * @param {number} [options.threshold] overrides the recorded threshold
 * @param {number} [options.failureWindowMs] 0 disables the streak decay
 * @returns {object} the decision, plus everything the boot log should say
 */
export function beginLaunch(options = {}) {
  const stateFile = asString(options.stateFile);
  const launchId = asString(options.launchId);
  if (stateFile === null) throw new TypeError('beginLaunch: stateFile is required');
  if (launchId === null) throw new TypeError('beginLaunch: launchId is required');
  const threshold = asThreshold(options.threshold ?? DEFAULT_THRESHOLD);
  const windowMs = asCount(options.failureWindowMs ?? DEFAULT_FAILURE_WINDOW_MS, DEFAULT_FAILURE_WINDOW_MS);
  const at = toIso(options.now);

  const read = readStateFile(stateFile);
  const state = read.state;
  state.threshold = threshold;

  const warnings = [];
  if (read.status !== 'ok' && read.status !== 'missing') {
    warnings.push(`boot guard state ${read.status}: ${read.error ?? 'no detail'}; treating as no failures`);
  }

  const outcomeRead = readOutcomeRecords(options.outcomeFile);
  const markerRead = options.backgroundFile ? readTextFile(options.backgroundFile) : { value: undefined, status: 'missing' };
  const requestRead = options.requestFile ? readJsonFile(options.requestFile) : { value: undefined, status: 'missing' };

  if (outcomeRead.status === 'corrupt' || outcomeRead.status === 'unreadable') {
    warnings.push(`boot outcome ${outcomeRead.status}: ${outcomeRead.error ?? 'no detail'}`);
  } else if (outcomeRead.error) {
    warnings.push(`boot outcome: ${outcomeRead.error}`);
  }
  if (requestRead.status === 'corrupt' || requestRead.status === 'unreadable') {
    warnings.push(`boot request ${requestRead.status}: ${requestRead.error ?? 'no detail'}`);
  }

  // Every record the file holds, keyed by the launch it names. Records that are
  // not records this version understands are reported and dropped: the alternative
  // is refusing to read a file whose whole job is to survive being broken.
  //
  // A launch is settled at most once. The history is the record of what has
  // already been settled, and an outcome for an id it holds is a second report
  // of the same launch, not a new failure: Node's `noteFailure()` closes the
  // attempt and Swift then writes its own outcome for the same id when it sees
  // DSHPORTC_FATAL, and a consuming rewrite that failed leaves records for the
  // next launch to read again. Counting either one twice pushes a user towards
  // safe mode for failures that did not happen. The first conclusion stands.
  const settledIds = new Set(state.history.map((entry) => entry.id).filter((id) => id !== 'unknown'));
  const outcomes = new Map();
  for (const record of outcomeRead.records) {
    if (!isOutcomeRecord(record)) {
      warnings.push('boot outcome is not a record this version understands; ignored');
      continue;
    }
    // An outcome that names THIS launch belongs to this launch, not to the
    // previous one: the Swift host can fail before `node_start` and write it
    // first. It stays in the file for the next launch, which is the one that has
    // to count it.
    if (record.launchId === launchId) {
      warnings.push('boot outcome names this launch; left for the next one to read');
      continue;
    }
    if (settledIds.has(record.launchId)) {
      warnings.push(`boot outcome for ${record.launchId} already settled; not counted again`);
      continue;
    }
    // Later records win for a repeated id: one launch writes one conclusion, and
    // a duplicate can only come from a retry of the same write.
    outcomes.set(record.launchId, record);
  }

  const settled = [];
  const attempt = isAttemptRecord(state.attempt) ? state.attempt : null;
  if (attempt !== null) {
    const outcome = outcomes.get(attempt.id);
    let verdict;
    if (outcome !== undefined) {
      verdict = fromOutcome(outcome);
      outcomes.delete(attempt.id);
    } else {
      verdict = classifySilentEnd(attempt, markerRead.value);
    }
    verdict.id = attempt.id;
    verdict.mode = attempt.mode;
    verdict.startedAt = attempt.startedAt;
    verdict.endedAt = at;
    settled.push(verdict);
    applyVerdict(state, verdict, { at, windowMs, threshold });
    state.attempt = null;
  }

  // Outcomes with no attempt record: launches that died before Node could write
  // one — the Swift host fails before `node_start`, so there is no attempt, but
  // each outcome is real. This is the path a repeatedly failing `payload/` or a
  // profile that will not mount takes, and it is why the file is a list.
  //
  // Oldest first, so `lastOutcome` ends up describing the most recent one.
  const orphanIds = [...outcomes.keys()].sort((a, b) => {
    const left = Date.parse(outcomes.get(a)?.at ?? '') || 0;
    const right = Date.parse(outcomes.get(b)?.at ?? '') || 0;
    return left - right;
  });
  for (const id of orphanIds) {
    const outcome = outcomes.get(id);
    const verdict = fromOutcome(outcome);
    verdict.id = outcome.launchId;
    verdict.mode = 'unknown';
    verdict.startedAt = asIsoString(outcome.startedAt);
    verdict.endedAt = asIsoString(outcome.at) ?? at;
    settled.push(verdict);
    applyVerdict(state, verdict, { at, windowMs, threshold });
  }

  // The request file. Two of the three actions belong to this module; the rest
  // (`reset-runtime`, `export-diagnostics`) belong to the caller, which sees
  // them in `pendingRequest` and still owns the file.
  const request = isRequestRecord(requestRead.value) ? requestRead.value : undefined;
  let consumedRequest = false;
  let forcedNormal = false;
  let pendingRequest = null;
  if (request !== undefined && OWN_REQUESTS.has(request.action)) {
    consumedRequest = true;
    forcedNormal = true;
    if (request.action === 'clear-guard') {
      const history = state.history;
      Object.assign(state, emptyState(threshold));
      state.history = history;
      warnings.push('guard state cleared on request');
    } else {
      warnings.push('safe mode left on request');
    }
    state.failures = 0;
    state.safeMode = false;
    state.safeModeReason = null;
    state.safeModeSince = null;
    state.safeModeFailures = 0;
    state.probeAfterSafeSuccess = false;
  } else if (request !== undefined) {
    pendingRequest = { action: request.action, id: asString(request.id), at: asIsoString(request.at) };
  }

  // A streak older than the window belongs to a different problem.
  let decayed = false;
  if (state.failures > 0 && state.lastFailureAt !== null && windowMs > 0) {
    const last = Date.parse(state.lastFailureAt);
    if (Number.isFinite(last) && Date.parse(at) - last > windowMs) {
      state.failures = 0;
      state.lastFailureAt = null;
      // The streak is what put the app in safe mode, so the mode goes with it.
      // A safe-mode launch that keeps failing refreshes `lastFailureAt` and never
      // reaches this branch.
      state.safeMode = false;
      state.safeModeReason = null;
      state.safeModeSince = null;
      decayed = true;
      warnings.push(`failure streak expired (no failure in ${Math.round(windowMs / 60000)} min)`);
    }
  }

  if (state.failures >= state.threshold) {
    state.safeMode = true;
    state.safeModeReason = state.safeModeReason ?? `${state.failures} launches in a row failed`;
    state.safeModeSince = state.safeModeSince ?? at;
  }

  let mode;
  if (forcedNormal) {
    mode = 'normal';
  } else if (state.probeAfterSafeSuccess) {
    mode = 'probe';
    state.probeAfterSafeSuccess = false;
  } else {
    mode = state.safeMode ? 'safe' : 'normal';
  }

  state.attempt = {
    id: launchId,
    startedAt: at,
    phase: 'entry',
    phaseAt: at,
    mode,
    backgroundedAt: null,
  };
  if (settled.length > 0) {
    state.history = [...state.history, ...settled.map(historyEntry)].slice(-HISTORY_LIMIT);
  }

  let writeError;
  try {
    writeJsonAtomic(stateFile, state);
  } catch (error) {
    writeError = message(error);
  }

  // One-shot files: whatever was read above describes the PREVIOUS launch and is
  // consumed. Removing it here keeps the directory readable and stops an old
  // outcome from being counted twice.
  if (options.outcomeFile) consumeOutcomes(options.outcomeFile, outcomeRead.records, launchId);
  if (options.backgroundFile) unlinkQuiet(options.backgroundFile);
  if (consumedRequest && options.requestFile) unlinkQuiet(options.requestFile);

  return {
    launchId,
    mode,
    safeMode: mode === 'safe',
    probe: mode === 'probe',
    threshold: state.threshold,
    failures: state.failures,
    safeModeFailures: state.safeModeFailures,
    safeModeReason: state.safeModeReason,
    previous: settled.length > 0 ? settled[settled.length - 1] : null,
    settled,
    decayed,
    pendingRequest,
    stateStatus: read.status,
    stateError: read.error ?? null,
    writeError: writeError ?? null,
    warnings,
  };
}

/**
 * Record that this launch got one step further.
 *
 * Writes only when the phase advances, so the boot path costs at most a couple
 * of small atomic writes.
 *
 * @param {object} options
 * @param {string} options.stateFile
 * @param {string} options.launchId
 * @param {'entry'|'launcher'|'dsh'} options.phase
 * @returns {{applied: boolean, reason?: string, phase?: string}}
 */
export function noteProgress({ stateFile, launchId, phase, now } = {}) {
  if (asString(stateFile) === null || asString(launchId) === null) {
    throw new TypeError('noteProgress: stateFile and launchId are required');
  }
  if (!ATTEMPT_PHASES.includes(phase)) throw new TypeError(`noteProgress: unknown phase ${String(phase)}`);
  const read = readStateFile(stateFile);
  if (read.status !== 'ok') return { applied: false, reason: `state ${read.status}` };
  const state = read.state;
  const attempt = isAttemptRecord(state.attempt) ? state.attempt : null;
  if (attempt === null || attempt.id !== launchId) return { applied: false, reason: 'no matching attempt' };
  const from = ATTEMPT_PHASES.indexOf(attempt.phase);
  const to = ATTEMPT_PHASES.indexOf(phase);
  if (to <= from) return { applied: false, reason: 'phase already passed', phase: attempt.phase };
  attempt.phase = phase;
  attempt.phaseAt = toIso(now);
  state.attempt = attempt;
  try {
    writeJsonAtomic(stateFile, state);
  } catch (error) {
    return { applied: false, reason: message(error) };
  }
  return { applied: true, phase };
}

/**
 * Close this launch as a success.
 *
 * On iOS this is normally reached at the NEXT launch, through the outcome file
 * Swift writes when the web view finishes; the in-process form exists for any
 * caller that observes the page itself, and for tests.
 *
 * @param {object} options
 * @param {string} options.stateFile
 * @param {string} options.launchId
 * @param {'page'|'server'} [options.level]
 * @returns {{applied: boolean, reason?: string, failures?: number, safeMode?: boolean, mode?: string}}
 */
export function noteSuccess({ stateFile, launchId, now, level = 'page', detail } = {}) {
  return closeAttempt({ stateFile, launchId, now, kind: 'success', level, reason: detail });
}

/**
 * Close this launch as a failure.
 *
 * @param {object} options
 * @param {string} options.stateFile
 * @param {string} options.launchId
 * @param {string} options.reason what the boot log should say
 * @param {string} [options.phase] the step it reached
 * @returns {{applied: boolean, reason?: string, failures?: number, safeMode?: boolean, mode?: string}}
 */
export function noteFailure({ stateFile, launchId, now, reason, phase } = {}) {
  return closeAttempt({ stateFile, launchId, now, kind: 'failure', reason, phase });
}

function closeAttempt({ stateFile, launchId, now, kind, reason, phase, level } = {}) {
  if (asString(stateFile) === null || asString(launchId) === null) {
    throw new TypeError('noteSuccess/noteFailure: stateFile and launchId are required');
  }
  const at = toIso(now);
  const read = readStateFile(stateFile);
  if (read.status !== 'ok') return { applied: false, reason: `state ${read.status}` };
  const state = read.state;
  const attempt = isAttemptRecord(state.attempt) ? state.attempt : null;
  if (attempt === null || attempt.id !== launchId) {
    // Nothing to close. This is what a second call looks like, and it must not
    // move the counter again.
    return { applied: false, reason: 'no matching attempt' };
  }
  const verdict = {
    kind,
    level: level ?? 'page',
    reason: asString(reason) ?? (kind === 'success' ? 'the page came up' : 'the launch failed'),
    phase: asString(phase) ?? attempt.phase,
    id: attempt.id,
    mode: attempt.mode,
    startedAt: attempt.startedAt,
    endedAt: at,
  };
  applyVerdict(state, verdict, {
    at,
    windowMs: DEFAULT_FAILURE_WINDOW_MS,
    threshold: state.threshold ?? DEFAULT_THRESHOLD,
  });
  state.attempt = null;
  state.history = [...state.history, historyEntry(verdict)].slice(-HISTORY_LIMIT);
  try {
    writeJsonAtomic(stateFile, state);
  } catch (error) {
    return { applied: false, reason: message(error) };
  }
  return {
    applied: true,
    failures: state.failures,
    safeMode: state.safeMode,
    mode: verdict.mode,
    probeAfterSafeSuccess: state.probeAfterSafeSuccess,
  };
}

/**
 * Note that the app went to the background during this launch.
 *
 * On iOS the Swift host writes `boot-background.txt` instead (it is the one that
 * sees the scene transition, and one writer per file is the rule), but the same
 * fact belongs in the state file when a caller can report it in-process.
 *
 * @returns {{applied: boolean, reason?: string}}
 */
export function noteBackgrounded({ stateFile, launchId, now } = {}) {
  if (asString(stateFile) === null || asString(launchId) === null) {
    throw new TypeError('noteBackgrounded: stateFile and launchId are required');
  }
  const read = readStateFile(stateFile);
  if (read.status !== 'ok') return { applied: false, reason: `state ${read.status}` };
  const state = read.state;
  const attempt = isAttemptRecord(state.attempt) ? state.attempt : null;
  if (attempt === null || attempt.id !== launchId) return { applied: false, reason: 'no matching attempt' };
  if (attempt.backgroundedAt !== null) return { applied: false, reason: 'already marked' };
  attempt.backgroundedAt = toIso(now);
  state.attempt = attempt;
  try {
    writeJsonAtomic(stateFile, state);
  } catch (error) {
    return { applied: false, reason: message(error) };
  }
  return { applied: true };
}

/**
 * Forget every failure and leave safe mode. Used by the reset flow, which clears
 * the whole runtime and must not inherit a streak from the state it deleted.
 *
 * @returns {{cleared: boolean, reason?: string}}
 */
export function clearGuard({ stateFile, now } = {}) {
  if (asString(stateFile) === null) throw new TypeError('clearGuard: stateFile is required');
  const read = readStateFile(stateFile);
  const state = emptyState(read.state.threshold ?? DEFAULT_THRESHOLD);
  state.lastOutcome = {
    at: toIso(now),
    kind: 'cleared',
    reason: 'guard state cleared',
    phase: null,
    mode: null,
  };
  try {
    writeJsonAtomic(stateFile, state);
  } catch (error) {
    return { cleared: false, reason: message(error) };
  }
  return { cleared: true, previousStatus: read.status };
}

/**
 * The short form of a state, for the app's status file and the boot log.
 *
 * @param {object} state
 * @returns {object}
 */
export function describeState(state) {
  const safe = normalizeState(state);
  return {
    failures: safe.failures,
    threshold: safe.threshold,
    safeMode: safe.safeMode,
    safeModeReason: safe.safeModeReason,
    safeModeFailures: safe.safeModeFailures,
    probeAfterSafeSuccess: safe.probeAfterSafeSuccess,
    attempt: safe.attempt === null ? null : {
      id: safe.attempt.id, startedAt: safe.attempt.startedAt, phase: safe.attempt.phase, mode: safe.attempt.mode,
    },
    lastOutcome: safe.lastOutcome,
    history: safe.history.length,
  };
}
