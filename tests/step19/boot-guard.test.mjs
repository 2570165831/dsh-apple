// Tests for sim/boot-guard.mjs.
//
// Every test works in a directory it created itself under the system temp
// directory and removes it afterwards; nothing outside that directory is read or
// written. Time is passed in, never read from the wall clock, so a streak that
// has to expire is an argument rather than a sleep.

import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import {
  existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import {
  DEFAULT_THRESHOLD, HISTORY_LIMIT, STATE_VERSION, beginLaunch, clearGuard, describeState,
  noteBackgrounded, noteFailure, noteProgress, noteSuccess, readStateFile,
} from '../../sim/boot-guard.mjs';

let base;

before(() => {
  base = mkdtempSync(join(tmpdir(), 'dsh19-boot-'));
});

after(() => {
  rmSync(base, { recursive: true, force: true });
});

function workspace() {
  const directory = mkdtempSync(join(base, 'case-'));
  return {
    directory,
    stateFile: join(directory, 'boot-guard.json'),
    outcomeFile: join(directory, 'boot-outcome.json'),
    backgroundFile: join(directory, 'boot-background.txt'),
    requestFile: join(directory, 'boot-request.json'),
  };
}

function at(minutes) {
  return new Date(Date.parse('2026-11-02T00:00:00.000Z') + minutes * 60 * 1000);
}

function readRaw(file) {
  return JSON.parse(readFileSync(file, 'utf8'));
}

function writeOutcome(file, record) {
  writeFileSync(file, `${JSON.stringify(record)}\n`);
}

test('a missing state file means "no failures", not an error', () => {
  const paths = workspace();
  const decision = beginLaunch({ ...paths, launchId: 'L1', now: at(0) });
  assert.equal(decision.mode, 'normal');
  assert.equal(decision.failures, 0);
  assert.equal(decision.stateStatus, 'missing');
  assert.equal(decision.writeError, null);
  assert.equal(readRaw(paths.stateFile).attempt.id, 'L1');
});

test('a corrupt state file is treated as no failures and repaired', () => {
  const paths = workspace();
  writeFileSync(paths.stateFile, '{ "failures": 2, "attempt": { "id" ');
  const decision = beginLaunch({ ...paths, launchId: 'L1', now: at(0) });
  assert.equal(decision.mode, 'normal');
  assert.equal(decision.stateStatus, 'corrupt');
  assert.match(decision.warnings.join('\n'), /corrupt/);
  assert.equal(readStateFile(paths.stateFile).status, 'ok');
});

test('a state file that is not an object, or an array, is corrupt', () => {
  const paths = workspace();
  for (const body of ['[]', '"text"', 'null', '42']) {
    writeFileSync(paths.stateFile, body);
    const decision = beginLaunch({ ...paths, launchId: 'L1', now: at(0) });
    assert.equal(decision.stateStatus, 'corrupt', `body ${body}`);
    assert.equal(decision.mode, 'normal');
  }
});

test('a state file from a future version is ignored rather than trusted', () => {
  const paths = workspace();
  writeFileSync(paths.stateFile, JSON.stringify({ version: STATE_VERSION + 1, failures: 9, safeMode: true, attempt: null }));
  const decision = beginLaunch({ ...paths, launchId: 'L1', now: at(0) });
  assert.equal(decision.stateStatus, 'unsupported-version');
  assert.equal(decision.mode, 'normal');
  assert.equal(decision.failures, 0);
});

test('wrong field types cost the field, not the record', () => {
  const paths = workspace();
  writeFileSync(paths.stateFile, JSON.stringify({
    version: 1, failures: '3', safeMode: 'yes', threshold: 'x', attempt: { id: 7 }, history: 'nope',
  }));
  const decision = beginLaunch({ ...paths, launchId: 'L1', now: at(0) });
  assert.equal(decision.mode, 'normal');
  assert.equal(decision.failures, 0);
  assert.equal(readRaw(paths.stateFile).history.length, 0);
});

test('an unreadable state path does not stop the boot', () => {
  const paths = workspace();
  mkdirSync(paths.stateFile);
  const decision = beginLaunch({ ...paths, launchId: 'L1', now: at(0) });
  assert.equal(decision.mode, 'normal');
  assert.equal(decision.stateStatus, 'unreadable');
  assert.notEqual(decision.writeError, null);
});

test('three failed launches make the fourth run in safe mode', () => {
  const paths = workspace();
  const first = beginLaunch({ ...paths, launchId: 'L1', now: at(0) });
  assert.equal(first.mode, 'normal');
  assert.deepEqual(noteFailure({ ...paths, launchId: 'L1', now: at(1), reason: 'node exited' }), {
    applied: true, failures: 1, safeMode: false, mode: 'normal', probeAfterSafeSuccess: false,
  });

  const second = beginLaunch({ ...paths, launchId: 'L2', now: at(2) });
  assert.equal(second.mode, 'normal');
  noteFailure({ ...paths, launchId: 'L2', now: at(3), reason: 'page never ready' });

  const third = beginLaunch({ ...paths, launchId: 'L3', now: at(4) });
  assert.equal(third.mode, 'normal');
  assert.equal(third.failures, 2);
  noteFailure({ ...paths, launchId: 'L3', now: at(5), reason: 'page never ready' });

  const fourth = beginLaunch({ ...paths, launchId: 'L4', now: at(6) });
  assert.equal(fourth.mode, 'safe');
  assert.equal(fourth.safeMode, true);
  assert.equal(fourth.failures, DEFAULT_THRESHOLD);
  assert.equal(fourth.previous, null, 'the third failure closed its own attempt');
});

test('a success resets the streak', () => {
  const paths = workspace();
  beginLaunch({ ...paths, launchId: 'L1', now: at(0) });
  noteFailure({ ...paths, launchId: 'L1', now: at(1), reason: 'boom' });
  beginLaunch({ ...paths, launchId: 'L2', now: at(2) });
  noteFailure({ ...paths, launchId: 'L2', now: at(3), reason: 'boom' });
  beginLaunch({ ...paths, launchId: 'L3', now: at(4) });
  assert.equal(noteSuccess({ ...paths, launchId: 'L3', now: at(5) }).failures, 0);
  const next = beginLaunch({ ...paths, launchId: 'L4', now: at(6) });
  assert.equal(next.mode, 'normal');
  assert.equal(next.failures, 0);
  assert.equal(next.previous, null, 'the success closed its own attempt in-process');
  assert.equal(readRaw(paths.stateFile).history.at(-1).kind, 'success');
});

test('a launch that disappears in the foreground counts as a failure', () => {
  const paths = workspace();
  beginLaunch({ ...paths, launchId: 'L1', now: at(0) });
  noteProgress({ ...paths, launchId: 'L1', phase: 'launcher', now: at(1) });
  const next = beginLaunch({ ...paths, launchId: 'L2', now: at(2) });
  assert.equal(next.previous.kind, 'failure');
  assert.match(next.previous.reason, /last step: launcher/);
  assert.equal(next.failures, 1);
});

test('a launch ended in the background does not count', () => {
  const paths = workspace();
  beginLaunch({ ...paths, launchId: 'L1', now: at(0) });
  writeFileSync(paths.backgroundFile, 'L1\n');
  const next = beginLaunch({ ...paths, launchId: 'L2', now: at(1) });
  assert.equal(next.previous.kind, 'abandoned');
  assert.equal(next.failures, 0);
  assert.equal(existsSync(paths.backgroundFile), false, 'the marker is consumed');
});

test('an early marker for the current launch survives beginLaunch', () => {
  const paths = workspace();
  writeFileSync(paths.backgroundFile, 'L1\n');
  beginLaunch({ ...paths, launchId: 'L1', now: at(0) });
  assert.equal(readFileSync(paths.backgroundFile, 'utf8'), 'L1\n');
  const next = beginLaunch({ ...paths, launchId: 'L2', now: at(1) });
  assert.equal(next.previous.kind, 'abandoned');
  assert.equal(next.failures, 0);
  assert.equal(existsSync(paths.backgroundFile), false);
});

test('clearing a current marker restores foreground crash counting', () => {
  const paths = workspace();
  writeFileSync(paths.backgroundFile, 'L1\n');
  beginLaunch({ ...paths, launchId: 'L1', now: at(0) });
  rmSync(paths.backgroundFile);
  const next = beginLaunch({ ...paths, launchId: 'L2', now: at(1) });
  assert.equal(next.previous.kind, 'failure');
  assert.equal(next.failures, 1);
});

test('the in-state background mark is as good as the marker file', () => {
  const paths = workspace();
  beginLaunch({ ...paths, launchId: 'L1', now: at(0) });
  assert.equal(noteBackgrounded({ ...paths, launchId: 'L1', now: at(1) }).applied, true);
  const next = beginLaunch({ ...paths, launchId: 'L2', now: at(2) });
  assert.equal(next.previous.kind, 'abandoned');
  assert.equal(next.failures, 0);
});

test('a background marker for another launch is not this launch\'s evidence', () => {
  const paths = workspace();
  beginLaunch({ ...paths, launchId: 'L1', now: at(0) });
  writeFileSync(paths.backgroundFile, 'SOMEONE-ELSE\n');
  const next = beginLaunch({ ...paths, launchId: 'L2', now: at(1) });
  assert.equal(next.previous.kind, 'failure');
  assert.equal(next.failures, 1);
});

test('the outcome file closes the attempt without guessing', () => {
  const paths = workspace();
  beginLaunch({ ...paths, launchId: 'L1', now: at(0) });
  writeOutcome(paths.outcomeFile, {
    version: 1, launchId: 'L1', kind: 'success', level: 'page', phase: 'webViewReady', at: at(1).toISOString(),
  });
  const next = beginLaunch({ ...paths, launchId: 'L2', now: at(2) });
  assert.equal(next.previous.kind, 'success');
  assert.equal(next.previous.level, 'page');
  assert.equal(next.failures, 0);
  assert.equal(existsSync(paths.outcomeFile), false, 'the outcome is consumed');

  writeOutcome(paths.outcomeFile, { launchId: 'L2', kind: 'failure', reason: '页面 60 秒内没有就绪', phase: 'serverListening' });
  const third = beginLaunch({ ...paths, launchId: 'L3', now: at(4) });
  assert.equal(third.previous.kind, 'failure');
  assert.equal(third.previous.reason, '页面 60 秒内没有就绪');
  assert.equal(third.failures, 1);
});

test('an outcome with no attempt record still counts', () => {
  const paths = workspace();
  writeOutcome(paths.outcomeFile, { launchId: 'GHOST', kind: 'failure', reason: 'swift failed before node_start' });
  const next = beginLaunch({ ...paths, launchId: 'L1', now: at(0) });
  assert.equal(next.settled.length, 1);
  assert.equal(next.settled[0].id, 'GHOST');
  assert.equal(next.failures, 1);
});

test('an outcome naming this very launch is left for the next launch', () => {
  const paths = workspace();
  // The Swift host can fail before node_start and write the outcome first.
  writeOutcome(paths.outcomeFile, { launchId: 'L1', kind: 'failure', reason: 'missing bundle resource' });
  const decision = beginLaunch({ ...paths, launchId: 'L1', now: at(0) });
  assert.equal(decision.failures, 0, 'this launch is not counted against the previous one');
  assert.equal(decision.settled.length, 0);
  assert.match(decision.warnings.join('\n'), /names this launch/);
  assert.equal(existsSync(paths.outcomeFile), true, 'the file is kept');

  // The next launch reads it as the outcome of the launch that never got going.
  const next = beginLaunch({ ...paths, launchId: 'L2', now: at(1) });
  assert.equal(next.previous.kind, 'failure');
  assert.equal(next.failures, 1);
  assert.equal(existsSync(paths.outcomeFile), false);
});

test('a malformed outcome file is ignored and removed', () => {
  const paths = workspace();
  beginLaunch({ ...paths, launchId: 'L1', now: at(0) });
  writeFileSync(paths.outcomeFile, '{"launchId":"L1","kind":"maybe"}');
  const next = beginLaunch({ ...paths, launchId: 'L2', now: at(1) });
  assert.equal(next.previous.kind, 'failure');
  assert.match(next.warnings.join('\n'), /not a record/);
  assert.equal(existsSync(paths.outcomeFile), false);
});

// The launch that fails BEFORE Node starts. `beginLaunch()` never runs, so nothing
// consumes the outcome file between failures, and the app appends one line per
// failure instead of rewriting one record. Measured on the simulator before this
// was fixed: three consecutive fail-fast launches left `boot-guard.json` absent
// and one outcome on disk, so the counter could never reach the threshold that
// turns safe mode on — for the one failure mode where the user most needs it.
test('several failures that never reached Node are all counted', () => {
  const paths = workspace();
  const ids = ['GHOST1', 'GHOST2', 'GHOST3'];
  for (const [index, id] of ids.entries()) {
    writeFileSync(paths.outcomeFile, `${ids.slice(0, index + 1)
      .map((each) => JSON.stringify({ launchId: each, kind: 'failure', reason: 'missing payload/', phase: 'failed' }))
      .join('\n')}\n`);
  }
  const decision = beginLaunch({ ...paths, launchId: 'L1', now: at(0) });
  assert.equal(decision.failures, 3);
  assert.equal(decision.mode, 'safe');
  assert.equal(decision.settled.length, 3);
  assert.deepEqual(decision.settled.map((verdict) => verdict.id), ids);
  // The last one settled is the most recent failure, which is what the screen
  // explains the mode with.
  assert.equal(decision.previous.reason, 'missing payload/');
  assert.equal(existsSync(paths.outcomeFile), false, 'every record was consumed');
});

test('a record for a launch that has not run yet is kept, not counted', () => {
  const paths = workspace();
  writeOutcome(paths.outcomeFile, { launchId: 'GHOST', kind: 'failure', reason: 'earlier launch' });
  writeOutcome(paths.outcomeFile, { launchId: 'L1', kind: 'failure', reason: 'this launch' });
  // Writing twice with the helper above overwrote; rewrite as the real list form.
  writeFileSync(paths.outcomeFile, [
    JSON.stringify({ launchId: 'GHOST', kind: 'failure', reason: 'earlier launch' }),
    JSON.stringify({ launchId: 'L1', kind: 'failure', reason: 'this launch' }),
    '',
  ].join('\n'));
  const decision = beginLaunch({ ...paths, launchId: 'L1', now: at(0) });
  assert.equal(decision.failures, 1, 'only the earlier launch is counted');
  assert.equal(existsSync(paths.outcomeFile), true, 'this launch\'s record stays');
  assert.match(readFileSync(paths.outcomeFile, 'utf8'), /this launch/);

  const next = beginLaunch({ ...paths, launchId: 'L2', now: at(1) });
  assert.equal(next.failures, 2);
  assert.equal(existsSync(paths.outcomeFile), false);
});

test('one unparsable line costs that line, not the whole file', () => {
  const paths = workspace();
  writeFileSync(paths.outcomeFile, [
    JSON.stringify({ launchId: 'GHOST1', kind: 'failure', reason: 'first' }),
    '{"launchId":"HALF","kind":"failu',
    JSON.stringify({ launchId: 'GHOST2', kind: 'failure', reason: 'second' }),
    '',
  ].join('\n'));
  const decision = beginLaunch({ ...paths, launchId: 'L1', now: at(0) });
  assert.equal(decision.failures, 2, 'the two whole records still count');
  assert.match(decision.warnings.join('\n'), /unparsable line/);
});

// The same failed launch reported twice: `sim/ios-app-entry.mjs` closes the
// attempt with `noteFailure()`, then prints DSHPORTC_FATAL, and the Swift host
// answers that with its own failure outcome for the same launch id. Before the
// fix the next launch settled that outcome again as an orphan: failures 1 -> 2,
// and the history held the id twice.
function swiftOutcomeLine(launchId, kind, reason, when) {
  // What BootGuard.recordOutcome appends: compact JSON, sorted keys, one line.
  return `${JSON.stringify({
    at: when.toISOString(), kind, launchId, level: 'page', phase: 'failed', reason,
  })}\n`;
}

test('a failure Node already closed is not counted again from the Swift outcome', () => {
  const paths = workspace();
  beginLaunch({ ...paths, launchId: 'A', now: at(0) });
  assert.equal(noteFailure({ ...paths, launchId: 'A', now: at(1), reason: 'node threw' }).failures, 1);
  writeFileSync(paths.outcomeFile, swiftOutcomeLine('A', 'failure', 'DSHPORTC_FATAL', at(1)));

  const next = beginLaunch({ ...paths, launchId: 'B', now: at(2) });
  assert.equal(next.failures, 1, 'one failed launch, one count');
  assert.equal(next.settled.length, 0, 'nothing left to settle');
  assert.match(next.warnings.join('\n'), /already settled/);
  const ids = readRaw(paths.stateFile).history.map((entry) => entry.id);
  assert.deepEqual(ids.filter((id) => id === 'A'), ['A']);
  assert.equal(existsSync(paths.outcomeFile), false, 'the duplicate is consumed, not kept');
});

test('a Swift-only failure outcome is still settled exactly once', () => {
  const paths = workspace();
  beginLaunch({ ...paths, launchId: 'A', now: at(0) });
  // Node never got to note anything; only the Swift host saw the failure.
  writeFileSync(paths.outcomeFile, swiftOutcomeLine('A', 'failure', 'page never ready', at(1)));
  const next = beginLaunch({ ...paths, launchId: 'B', now: at(2) });
  assert.equal(next.failures, 1);
  assert.equal(next.settled.length, 1);
  assert.equal(next.previous.id, 'A');
  assert.equal(next.previous.reason, 'page never ready');
  assert.deepEqual(readRaw(paths.stateFile).history.map((entry) => entry.id), ['A']);
});

test('an outcome read by two launches is counted by the first only', () => {
  const paths = workspace();
  // An orphan (no attempt record) and an attempt-matched outcome, both left on
  // disk as if the consuming rewrite after the first launch had failed.
  beginLaunch({ ...paths, launchId: 'A', now: at(0) });
  const lines = swiftOutcomeLine('GHOST', 'failure', 'before node_start', at(0))
    + swiftOutcomeLine('A', 'failure', 'page never ready', at(1));
  writeFileSync(paths.outcomeFile, lines);
  const first = beginLaunch({ ...paths, launchId: 'B', now: at(2) });
  assert.equal(first.failures, 2);
  assert.deepEqual(first.settled.map((verdict) => verdict.id).sort(), ['A', 'GHOST']);

  writeFileSync(paths.outcomeFile, lines); // the same records, read again
  noteFailure({ ...paths, launchId: 'B', now: at(3), reason: 'boom' });
  const second = beginLaunch({ ...paths, launchId: 'C', now: at(4) });
  assert.equal(second.failures, 3, 'only B is new');
  assert.equal(second.settled.length, 0);
  const ids = readRaw(paths.stateFile).history.map((entry) => entry.id);
  assert.deepEqual(ids, ['A', 'GHOST', 'B']);
  assert.equal(existsSync(paths.outcomeFile), false);
});

test('a failure streak older than the window does not drag the app into safe mode', () => {
  const paths = workspace();
  for (const index of [1, 2, 3]) {
    beginLaunch({ ...paths, launchId: `L${index}`, now: at(index * 2) });
    noteFailure({ ...paths, launchId: `L${index}`, now: at(index * 2 + 1), reason: 'boom' });
  }
  // 23 minutes after the last failure: the streak belongs to a different problem.
  const later = beginLaunch({ ...paths, launchId: 'L4', now: at(30) });
  assert.equal(later.decayed, true);
  assert.equal(later.mode, 'normal');
  assert.equal(later.failures, 0);
  assert.equal(later.safeMode, false);
});

test('a success in safe mode makes the next launch a one-shot probe', () => {
  const paths = workspace();
  for (const index of [1, 2, 3]) {
    beginLaunch({ ...paths, launchId: `L${index}`, now: at(index * 2) });
    noteFailure({ ...paths, launchId: `L${index}`, now: at(index * 2 + 1), reason: 'boom' });
  }
  const safe = beginLaunch({ ...paths, launchId: 'L4', now: at(8) });
  assert.equal(safe.mode, 'safe');
  const closed = noteSuccess({ ...paths, launchId: 'L4', now: at(9) });
  assert.equal(closed.probeAfterSafeSuccess, true);

  const probe = beginLaunch({ ...paths, launchId: 'L5', now: at(10) });
  assert.equal(probe.mode, 'probe');
  assert.equal(probe.safeMode, false);

  // The probe failing goes straight back to safe mode, without three more.
  noteFailure({ ...paths, launchId: 'L5', now: at(11), reason: 'still broken' });
  const back = beginLaunch({ ...paths, launchId: 'L6', now: at(12) });
  assert.equal(back.mode, 'safe');
  assert.equal(back.failures, DEFAULT_THRESHOLD);
});

test('a probe that works leaves safe mode behind', () => {
  const paths = workspace();
  for (const index of [1, 2, 3]) {
    beginLaunch({ ...paths, launchId: `L${index}`, now: at(index * 2) });
    noteFailure({ ...paths, launchId: `L${index}`, now: at(index * 2 + 1), reason: 'boom' });
  }
  beginLaunch({ ...paths, launchId: 'L4', now: at(8) });
  noteSuccess({ ...paths, launchId: 'L4', now: at(9) });
  beginLaunch({ ...paths, launchId: 'L5', now: at(10) });
  noteSuccess({ ...paths, launchId: 'L5', now: at(11) });
  const next = beginLaunch({ ...paths, launchId: 'L6', now: at(12) });
  assert.equal(next.mode, 'normal');
  assert.equal(next.failures, 0);
  assert.equal(next.safeMode, false);
});

test('a failure while already in safe mode stays in safe mode', () => {
  const paths = workspace();
  for (const index of [1, 2, 3]) {
    beginLaunch({ ...paths, launchId: `L${index}`, now: at(index * 2) });
    noteFailure({ ...paths, launchId: `L${index}`, now: at(index * 2 + 1), reason: 'boom' });
  }
  const safe = beginLaunch({ ...paths, launchId: 'L4', now: at(8) });
  assert.equal(safe.mode, 'safe');
  noteFailure({ ...paths, launchId: 'L4', now: at(9), reason: 'safe mode failed too' });
  const next = beginLaunch({ ...paths, launchId: 'L5', now: at(10) });
  assert.equal(next.mode, 'safe');
  assert.equal(next.safeModeFailures, 1);
});

test('exit-safe-mode is a request the next launch consumes', () => {
  const paths = workspace();
  for (const index of [1, 2, 3]) {
    beginLaunch({ ...paths, launchId: `L${index}`, now: at(index * 2) });
    noteFailure({ ...paths, launchId: `L${index}`, now: at(index * 2 + 1), reason: 'boom' });
  }
  writeFileSync(paths.requestFile, JSON.stringify({ action: 'exit-safe-mode', id: 'r1' }));
  const decision = beginLaunch({ ...paths, launchId: 'L4', now: at(8) });
  assert.equal(decision.mode, 'normal');
  assert.equal(decision.failures, 0);
  assert.equal(existsSync(paths.requestFile), false);
});

test('clear-guard empties the record but keeps the history', () => {
  const paths = workspace();
  beginLaunch({ ...paths, launchId: 'L1', now: at(0) });
  noteFailure({ ...paths, launchId: 'L1', now: at(1), reason: 'boom' });
  writeFileSync(paths.requestFile, JSON.stringify({ action: 'clear-guard' }));
  const decision = beginLaunch({ ...paths, launchId: 'L2', now: at(2) });
  assert.equal(decision.failures, 0);
  assert.equal(decision.mode, 'normal');
  assert.equal(readRaw(paths.stateFile).history.length, 1);
});

test('a request this module does not own is reported and left alone', () => {
  const paths = workspace();
  writeFileSync(paths.requestFile, JSON.stringify({ action: 'reset-runtime', id: 'r7' }));
  const decision = beginLaunch({ ...paths, launchId: 'L1', now: at(0) });
  assert.deepEqual(decision.pendingRequest, { action: 'reset-runtime', id: 'r7', at: null });
  assert.equal(existsSync(paths.requestFile), true);
});

test('progress only moves forward, and only for the current attempt', () => {
  const paths = workspace();
  beginLaunch({ ...paths, launchId: 'L1', now: at(0) });
  assert.equal(noteProgress({ ...paths, launchId: 'L1', phase: 'launcher', now: at(1) }).applied, true);
  assert.equal(noteProgress({ ...paths, launchId: 'L1', phase: 'entry', now: at(2) }).applied, false);
  assert.equal(noteProgress({ ...paths, launchId: 'OTHER', phase: 'dsh', now: at(3) }).applied, false);
  assert.equal(noteProgress({ ...paths, launchId: 'L1', phase: 'dsh', now: at(4) }).applied, true);
  assert.equal(readRaw(paths.stateFile).attempt.phase, 'dsh');
  assert.throws(() => noteProgress({ ...paths, launchId: 'L1', phase: 'moon' }), TypeError);
});

test('closing the same attempt twice does not move the counter twice', () => {
  const paths = workspace();
  beginLaunch({ ...paths, launchId: 'L1', now: at(0) });
  assert.equal(noteFailure({ ...paths, launchId: 'L1', now: at(1), reason: 'boom' }).applied, true);
  assert.equal(noteFailure({ ...paths, launchId: 'L1', now: at(2), reason: 'boom' }).applied, false);
  assert.equal(noteSuccess({ ...paths, launchId: 'L1', now: at(3) }).applied, false);
  assert.equal(readRaw(paths.stateFile).failures, 1);
});

test('noteSuccess on a corrupt state file reports instead of throwing', () => {
  const paths = workspace();
  writeFileSync(paths.stateFile, 'not json at all');
  const result = noteSuccess({ ...paths, launchId: 'L1', now: at(0) });
  assert.equal(result.applied, false);
  assert.match(result.reason, /corrupt/);
});

test('history is bounded', () => {
  const paths = workspace();
  for (let index = 0; index < HISTORY_LIMIT + 3; index += 1) {
    beginLaunch({ ...paths, launchId: `L${index}`, now: at(index * 2) });
    noteSuccess({ ...paths, launchId: `L${index}`, now: at(index * 2 + 1) });
  }
  const state = readRaw(paths.stateFile);
  assert.equal(state.history.length, HISTORY_LIMIT);
  assert.equal(state.history[state.history.length - 1].kind, 'success');
});

test('the threshold can be lowered and is recorded', () => {
  const paths = workspace();
  beginLaunch({ ...paths, launchId: 'L1', now: at(0), threshold: 2 });
  noteFailure({ ...paths, launchId: 'L1', now: at(1), reason: 'boom' });
  const second = beginLaunch({ ...paths, launchId: 'L2', now: at(2), threshold: 2 });
  assert.equal(second.failures, 1);
  noteFailure({ ...paths, launchId: 'L2', now: at(3), reason: 'boom' });
  const third = beginLaunch({ ...paths, launchId: 'L3', now: at(4), threshold: 2 });
  assert.equal(third.mode, 'safe');
});

test('state is written atomically and leaves no temporary files', () => {
  const paths = workspace();
  beginLaunch({ ...paths, launchId: 'L1', now: at(0) });
  noteProgress({ ...paths, launchId: 'L1', phase: 'launcher', now: at(1) });
  noteSuccess({ ...paths, launchId: 'L1', now: at(2) });
  const leftovers = readdirSync(paths.directory).filter((name) => name.endsWith('.tmp'));
  assert.deepEqual(leftovers, []);
  assert.match(readFileSync(paths.stateFile, 'utf8'), /"version": 1/);
});

test('clearGuard forgets the streak on demand', () => {
  const paths = workspace();
  beginLaunch({ ...paths, launchId: 'L1', now: at(0) });
  noteFailure({ ...paths, launchId: 'L1', now: at(1), reason: 'boom' });
  assert.equal(clearGuard({ stateFile: paths.stateFile, now: at(2) }).cleared, true);
  const decision = beginLaunch({ ...paths, launchId: 'L2', now: at(3) });
  assert.equal(decision.failures, 0);
  assert.equal(decision.mode, 'normal');
});

test('beginLaunch refuses to run without a state file or a launch id', () => {
  assert.throws(() => beginLaunch({}), TypeError);
  assert.throws(() => beginLaunch({ stateFile: '/tmp/x.json' }), TypeError);
  assert.throws(() => beginLaunch({ stateFile: '', launchId: 'L' }), TypeError);
  assert.throws(() => beginLaunch({ stateFile: '/tmp/x.json', launchId: 'L', now: 'not a date' }), TypeError);
});

test('describeState summarizes without leaking the whole record', () => {
  const paths = workspace();
  beginLaunch({ ...paths, launchId: 'L1', now: at(0) });
  const summary = describeState(readRaw(paths.stateFile));
  assert.equal(summary.attempt.id, 'L1');
  assert.equal(summary.failures, 0);
  assert.equal(typeof summary.history, 'number');
});
