// Tests for sim/safe-mode.mjs.
//
// The interesting cases are the destructive-looking ones: parking the user's
// patch must never lose it, a link where a file belongs must be refused, and an
// overlay that disables nothing must be an error rather than a lie.

import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import {
  existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import {
  DEFAULT_SKIP, EDITED_SUFFIX, PARKED_SUFFIX, REQUIRED, applyToArgv, buildOverlay,
  describeDecision, describeSkip, parkUserPatch, prepare, restoreUserPatch,
} from '../../sim/safe-mode.mjs';

let base;

before(() => {
  base = mkdtempSync(join(tmpdir(), 'dsh19-safe-'));
});

after(() => {
  rmSync(base, { recursive: true, force: true });
});

const USER_PATCH = [
  '# saved by Settings',
  '- id: agent-default-model',
  '  config:',
  '    provider: deepseek-official',
  '',
].join('\n');

function profile({ patch = USER_PATCH } = {}) {
  const directory = mkdtempSync(join(base, 'profile-'));
  mkdirSync(join(directory, 'node_modules', 'dsh-ios-profile'), { recursive: true });
  writeFileSync(join(directory, 'cordis.yml'), '[]\n');
  writeFileSync(join(directory, 'package.json'), '{"name":"ios-sim"}\n');
  writeFileSync(join(directory, 'node_modules', 'dsh-ios-profile', 'cordis.patch.yml'), '# app layer\n');
  if (patch !== null) writeFileSync(join(directory, 'cordis.patch.yml'), patch);
  return directory;
}

function overlayPath() {
  const directory = mkdtempSync(join(base, 'boot-'));
  return join(directory, 'safe-mode.patch.yml');
}

test('the skip and required lists are disjoint, unique and well formed', () => {
  assert.ok(DEFAULT_SKIP.length > 0);
  assert.ok(REQUIRED.length > 0);
  const ids = DEFAULT_SKIP.map((entry) => entry.id);
  assert.equal(new Set(ids).size, ids.length);
  for (const id of ids) assert.match(id, /^[A-Za-z0-9][A-Za-z0-9._-]*$/);
  for (const entry of REQUIRED) assert.equal(ids.includes(entry.id), false, `${entry.id} cannot be both`);
  for (const entry of [...DEFAULT_SKIP, ...REQUIRED]) assert.ok(entry.reason.length > 20, `${entry.id} needs a reason`);
});

// The count is asserted rather than left to the arrays: PLAN-19 §3.3 compares the
// composition row by row, the acceptance criterion counts the overlay's `- id:`
// lines, and the safe-mode banner says "N plugins skipped". All three have to
// agree, so a change to either list fails here instead of quietly changing what
// the report and the screen claim.
test('safe mode skips 6 app plugins and keeps 5', () => {
  assert.equal(DEFAULT_SKIP.length, 6);
  assert.equal(REQUIRED.length, 5);
  assert.deepEqual(DEFAULT_SKIP.map((entry) => entry.id), [
    'guest-runtimes',
    'diag-prompt',
    'busy-ios',
    'notify-ios',
    'directory-picker-browse',
    'ui-directory-picker-browse',
  ]);
});

// The approval policy is the one app plugin a safe-mode launch must NOT drop.
// Safe mode is the launch a user reaches after three failures, which is exactly
// when they are most likely to try a destructive command as a way out; dropping
// the only contributor of an `ask` decision would remove the confirmation
// without removing the need for it.
test('the approval policy survives safe mode', () => {
  assert.ok(REQUIRED.some((entry) => entry.id === 'ish-approval-policy'));
  assert.equal(DEFAULT_SKIP.some((entry) => entry.id === 'ish-approval-policy'), false);
  const text = buildOverlay({ now: '2026-11-02T00:00:00.000Z' });
  assert.equal(text.includes('- id: ish-approval-policy'), false);
});

test('the overlay is one disabled row per id, in the patch dialect the profile uses', () => {
  const text = buildOverlay({ now: '2026-11-02T00:00:00.000Z', reason: '3 launches failed' });
  assert.match(text, /^# Written by sim\/safe-mode\.mjs/);
  assert.match(text, /# reason: 3 launches failed/);
  assert.match(text, /# generated: 2026-11-02T00:00:00\.000Z/);
  for (const entry of DEFAULT_SKIP) {
    assert.ok(text.includes(`- id: ${entry.id}\n  disabled: true`), `row for ${entry.id}`);
  }
  const rows = text.split('\n').filter((line) => line.startsWith('- id: '));
  assert.equal(rows.length, DEFAULT_SKIP.length);
  // No `name:` key: a patch row naming a different plugin is skipped, not applied.
  assert.equal(/^\s+name:/m.test(text), false);
});

test('an overlay that disables nothing is refused', () => {
  assert.throws(() => buildOverlay({ skip: [] }), TypeError);
});

test('an invalid or duplicated id is refused', () => {
  assert.throws(() => buildOverlay({ skip: [{ id: 'bad id' }] }), TypeError);
  assert.throws(() => buildOverlay({ skip: [{ id: '../escape' }] }), TypeError);
  assert.throws(() => buildOverlay({ skip: [{ id: '' }] }), TypeError);
  assert.throws(() => buildOverlay({ skip: [{ id: 'a' }, { id: 'a' }] }), TypeError);
});

test('a row that must be kept cannot be skipped', () => {
  assert.throws(() => buildOverlay({ skip: [{ id: REQUIRED[0].id }] }), /required/);
});

test('parking the user layer keeps its bytes and leaves a valid empty profile', () => {
  const directory = profile();
  const result = parkUserPatch({ profileDir: directory });
  assert.deepEqual(result, { parked: true, created: false, alreadyParked: false });
  assert.equal(readFileSync(join(directory, 'cordis.patch.yml'), 'utf8'), '[]\n');
  assert.equal(readFileSync(join(directory, 'cordis.patch.yml') + PARKED_SUFFIX, 'utf8'), USER_PATCH);
});

test('parking twice is a no-op that does not overwrite the parked copy', () => {
  const directory = profile();
  parkUserPatch({ profileDir: directory });
  const second = parkUserPatch({ profileDir: directory });
  assert.equal(second.parked, false);
  assert.equal(second.alreadyParked, true);
  assert.equal(readFileSync(join(directory, 'cordis.patch.yml') + PARKED_SUFFIX, 'utf8'), USER_PATCH);
});

test('a user layer that changed during safe mode is reported, not destroyed', () => {
  const directory = profile();
  parkUserPatch({ profileDir: directory });
  writeFileSync(join(directory, 'cordis.patch.yml'), '- id: something\n  config: {a: 1}\n');
  const result = parkUserPatch({ profileDir: directory });
  assert.match(result.warning ?? '', /changed during a safe-mode session/);
  assert.match(readFileSync(join(directory, 'cordis.patch.yml'), 'utf8'), /something/);
});

test('a profile without a user layer gets an empty one', () => {
  const directory = profile({ patch: null });
  const result = parkUserPatch({ profileDir: directory });
  assert.deepEqual(result, { parked: false, created: true, alreadyParked: false });
  assert.equal(readFileSync(join(directory, 'cordis.patch.yml'), 'utf8'), '[]\n');
});

test('a symlinked user layer is refused rather than followed', () => {
  const directory = profile({ patch: null });
  const outside = join(mkdtempSync(join(base, 'outside-')), 'real-patch.yml');
  writeFileSync(outside, '- id: x\n');
  symlinkSync(outside, join(directory, 'cordis.patch.yml'));
  assert.throws(() => parkUserPatch({ profileDir: directory }), /symbolic link/);
  assert.equal(readFileSync(outside, 'utf8'), '- id: x\n', 'the target is untouched');
});

test('parking without a profile directory is an error, not a silent success', () => {
  assert.throws(() => parkUserPatch({ profileDir: join(base, 'nope') }), /no profile directory/);
  assert.throws(() => parkUserPatch({ profileDir: 'relative/path' }), TypeError);
});

test('restoring puts the user layer back byte for byte', () => {
  const directory = profile();
  parkUserPatch({ profileDir: directory });
  const result = restoreUserPatch({ profileDir: directory });
  assert.equal(result.restored, true);
  assert.equal(readFileSync(join(directory, 'cordis.patch.yml'), 'utf8'), USER_PATCH);
  assert.equal(existsSync(join(directory, 'cordis.patch.yml') + PARKED_SUFFIX), false);
});

// A safe-mode session can still save settings: parking puts `[]` in the user
// layer's place, the settings page is reachable, and a provider added there is
// written into that `[]`. Restoring the parked copy over it would delete what the
// user just typed, so the edit is moved aside and its path is returned.
test('a user layer edited during safe mode survives the restore, beside it', () => {
  const directory = profile();
  parkUserPatch({ profileDir: directory });
  const edited = '- id: llm-pi-ai\n  config:\n    providers:\n      mine:\n        api: openai-completions\n';
  writeFileSync(join(directory, 'cordis.patch.yml'), edited);
  const result = restoreUserPatch({ profileDir: directory });
  assert.equal(result.restored, true);
  assert.equal(result.editedCopy, join(directory, 'cordis.patch.yml' + EDITED_SUFFIX));
  assert.equal(readFileSync(result.editedCopy, 'utf8'), edited, 'the edit is byte for byte');
  assert.equal(readFileSync(join(directory, 'cordis.patch.yml'), 'utf8'), USER_PATCH, 'and the original came back');
  assert.equal(existsSync(join(directory, 'cordis.patch.yml') + PARKED_SUFFIX), false);
});

test('a second edited restore does not overwrite the first copy', () => {
  const directory = profile();
  parkUserPatch({ profileDir: directory });
  writeFileSync(join(directory, 'cordis.patch.yml'), '- id: first\n');
  const first = restoreUserPatch({ profileDir: directory });
  assert.equal(first.restored, true);

  parkUserPatch({ profileDir: directory });
  writeFileSync(join(directory, 'cordis.patch.yml'), '- id: second\n');
  const second = restoreUserPatch({ profileDir: directory });
  assert.equal(second.restored, true);
  assert.equal(second.editedCopy, join(directory, 'cordis.patch.yml' + EDITED_SUFFIX + '.2'));
  assert.equal(readFileSync(first.editedCopy, 'utf8'), '- id: first\n');
  assert.equal(readFileSync(second.editedCopy, 'utf8'), '- id: second\n');
});

test('an untouched or empty user layer is not "an edit"', () => {
  const directory = profile();
  parkUserPatch({ profileDir: directory });
  // What parking itself leaves behind.
  assert.equal(readFileSync(join(directory, 'cordis.patch.yml'), 'utf8'), '[]\n');
  const untouched = restoreUserPatch({ profileDir: directory });
  assert.deepEqual(untouched, { restored: true });
  assert.equal(existsSync(join(directory, 'cordis.patch.yml') + EDITED_SUFFIX), false);

  parkUserPatch({ profileDir: directory });
  writeFileSync(join(directory, 'cordis.patch.yml'), '');
  const empty = restoreUserPatch({ profileDir: directory });
  assert.deepEqual(empty, { restored: true });
  assert.equal(existsSync(join(directory, 'cordis.patch.yml') + EDITED_SUFFIX), false);
});

test('restoring with nothing parked is a no-op', () => {
  const directory = profile();
  assert.deepEqual(restoreUserPatch({ profileDir: directory }), { restored: false });
});

test('prepare writes the overlay, parks the layer and touches nothing else', () => {
  const directory = profile();
  const overlay = overlayPath();
  mkdirSync(join(directory, '..', 'unrelated'), { recursive: true });
  const before = readdirSync(directory).sort();
  const result = prepare({ profileDir: directory, overlayPath: overlay, now: '2026-11-02T00:00:00.000Z', reason: 'test' });
  assert.equal(result.overlayPath, overlay);
  assert.equal(result.parked.parked, true);
  assert.deepEqual(result.warnings, []);
  assert.ok(existsSync(overlay));
  assert.ok(readFileSync(overlay, 'utf8').includes(`- id: ${DEFAULT_SKIP[0].id}`), 'the overlay has the first row');
  const after = readdirSync(directory).sort();
  assert.deepEqual(after.filter((name) => !name.endsWith(PARKED_SUFFIX)), before);
  assert.equal(readFileSync(join(directory, 'cordis.yml'), 'utf8'), '[]\n');
  assert.equal(readFileSync(join(directory, 'node_modules', 'dsh-ios-profile', 'cordis.patch.yml'), 'utf8'), '# app layer\n');
});

test('prepare is idempotent across two safe-mode launches', () => {
  const directory = profile();
  const overlay = overlayPath();
  prepare({ profileDir: directory, overlayPath: overlay, now: '2026-11-02T00:00:00.000Z' });
  const first = readFileSync(overlay, 'utf8');
  prepare({ profileDir: directory, overlayPath: overlay, now: '2026-11-03T00:00:00.000Z' });
  assert.notEqual(readFileSync(overlay, 'utf8'), first, 'the overlay is regenerated');
  assert.equal(readFileSync(join(directory, 'cordis.patch.yml') + PARKED_SUFFIX, 'utf8'), USER_PATCH);
});

test('prepare refuses a relative overlay path', () => {
  const directory = profile();
  assert.throws(() => prepare({ profileDir: directory, overlayPath: 'safe.yml' }), TypeError);
});

// THE ASSERTION THIS REPLACES WAS WRONG, AND THE DEVICE SAID SO.
//
// It used to require the overlay at the very end of argv, on the reasoning that
// "the last overlay wins". The layering part is right; the position is not. This
// app's argv is `--profile ios-sim --no-open --host 127.0.0.1 --port 0`, and
// `bin.js` declares `passThroughOptions()`, so everything from `--no-open` on goes
// to the booted app. Appending put `--patch` there too and the safe-mode launch
// failed with `error: unknown option '--patch'` (measured; the log line is in
// REPORT-19 §3). The overlay therefore has to land before the first argument that
// belongs to the app, which is what this test now pins down.
test('the overlay goes before the app arguments, after the outer options', () => {
  const argv = ['--profile', 'ios-sim', '--no-open', '--host', '127.0.0.1', '--port', '0'];
  const patch = join(base, 'overlay.yml');
  const out = applyToArgv(argv, { patch });
  assert.notEqual(out, argv);
  assert.equal(argv.length, 7, 'the input is not modified');
  assert.deepEqual(out, [
    '--profile', 'ios-sim',
    '--patch', patch,
    '--no-open', '--host', '127.0.0.1', '--port', '0',
  ]);
  // The two facts that make the position correct rather than merely different:
  // every outer option is still before the overlay, and every app argument is
  // after it.
  const at = out.indexOf('--patch');
  assert.ok(at > out.indexOf('--profile') + 1, '--profile keeps its value');
  assert.ok(at < out.indexOf('--no-open'), 'the app arguments stay after the overlay');
});

test('the overlay lands before an app argument even with no outer options', () => {
  const patch = join(base, 'overlay.yml');
  assert.deepEqual(
    applyToArgv(['--no-open', '--port', '0'], { patch }),
    ['--patch', patch, '--no-open', '--port', '0'],
  );
  // A bare outer flag is not an app argument, so the overlay does NOT go before
  // it: with no app arguments at all the overlay simply goes last, which is the
  // one case the old "append" rule got right.
  assert.deepEqual(
    applyToArgv(['--profile', 'ios-sim', '--dump-config'], { patch }),
    ['--profile', 'ios-sim', '--dump-config', '--patch', patch],
  );
  // An empty list still gets a usable pair.
  assert.deepEqual(applyToArgv([], { patch }), ['--patch', patch]);
});

test('applyToArgv does not add the same overlay twice', () => {
  const patch = join(base, 'overlay.yml');
  const once = applyToArgv(['--profile', 'ios-sim'], { patch });
  assert.deepEqual(applyToArgv(once, { patch }), once);
  assert.deepEqual(applyToArgv(['--profile', 'ios-sim', `--patch=${patch}`], { patch }), ['--profile', 'ios-sim', `--patch=${patch}`]);
});

test('applyToArgv refuses nonsense arguments', () => {
  assert.throws(() => applyToArgv('--profile ios-sim', { patch: '/x.yml' }), TypeError);
  assert.throws(() => applyToArgv([1, 2], { patch: '/x.yml' }), TypeError);
  assert.throws(() => applyToArgv([], { patch: 'relative.yml' }), TypeError);
  assert.throws(() => applyToArgv([], {}), TypeError);
});

test('describeDecision says what safe mode turned off', () => {
  const off = describeDecision({ mode: 'normal' });
  assert.deepEqual(off, { active: false, mode: 'normal', skipped: [], reason: '' });
  const on = describeDecision({ mode: 'safe', safeModeReason: '3 launches failed' });
  assert.equal(on.active, true);
  assert.equal(on.reason, '3 launches failed');
  assert.deepEqual(on.skipped, DEFAULT_SKIP.map((entry) => entry.id));
});

test('describeSkip is plain data for the report', () => {
  const described = describeSkip();
  assert.equal(described.skipped.length, DEFAULT_SKIP.length);
  assert.equal(described.kept.length, REQUIRED.length);
  assert.equal(typeof described.skipped[0].reason, 'string');
});
