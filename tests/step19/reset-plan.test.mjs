// Tests for sim/reset-plan.mjs.
//
// This module never touches the files it names, so the assertions are about the
// plan itself: what is in it, what must never be in it, and what it does when a
// root, a link or an option is not what it expects. Every fixture is a directory
// tree created under the system temp directory.

import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import {
  mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join, sep } from 'node:path';

import {
  COMBO_KEYS, PROTECTED, ResetPlanError, STAGING, TIERS, assertNotProtected, assertRoot,
  computeResetPlan, dedupeNested, describeTiers, previewCombos, relativeCombos, relativeTable,
} from '../../sim/reset-plan.mjs';

let base;

before(() => {
  base = mkdtempSync(join(tmpdir(), 'dsh19-reset-'));
});

after(() => {
  rmSync(base, { recursive: true, force: true });
});

const DSH = join('Library', 'Application Support', 'DSH');
const APPSUPPORT = join('Library', 'Application Support', 'DSHPortC');

function tree() {
  const root = mkdtempSync(join(base, 'container-'));
  const dshHome = join(root, DSH);
  const appSupport = join(root, APPSUPPORT);
  const files = [
    join(root, 'Documents', 'workspace', 'notes.txt'),
    join(dshHome, '.credentials.yaml'),
    join(dshHome, 'AGENTS.md'),
    join(dshHome, 'events.jsonl'),
    join(dshHome, '.container-root'),
    join(dshHome, 'DSHPortE-session-migrate.json'),
    join(dshHome, 'mystery.txt'),
    join(dshHome, 'storages', 'workspace.json'),
    join(dshHome, 'sessions', 'proj', 'session-1', 'session.v1.jsonl.zstd'),
    join(dshHome, 'sessions-quarantine', 'stamp', 'x'),
    join(dshHome, 'attachments', 'a.jpg'),
    join(dshHome, 'cache', 'blob'),
    join(dshHome, 'profiles', 'ios-sim', 'cordis.patch.yml'),
    join(appSupport, 'DSHPortC-node.log'),
    join(appSupport, 'DSHPortC-status.json'),
    join(appSupport, 'DSHPortC-session-url.txt'),
    join(appSupport, 'boot', 'boot-guard.json'),
    join(appSupport, 'diagnostics', '20261101T000000-x', 'SUMMARY.txt'),
    join(root, 'Library', 'Application Support', 'ish-root', '.installed-version'),
    join(root, 'Library', 'Caches', 'dsh-compile-cache', 'x'),
  ];
  for (const file of files) {
    mkdirSync(join(file, '..'), { recursive: true });
    writeFileSync(file, 'x');
  }
  return { root, dshHome, appSupport };
}

function withPath(plan, relative) {
  return plan.move.some((entry) => entry.relative === relative);
}

test('an invalid root is an error, not an empty plan', () => {
  assert.throws(() => assertRoot(undefined), ResetPlanError);
  assert.throws(() => assertRoot(''), ResetPlanError);
  assert.throws(() => assertRoot('relative/path'), ResetPlanError);
  assert.throws(() => assertRoot('/'), ResetPlanError);
  assert.throws(() => assertRoot('/private'), ResetPlanError);
  assert.throws(() => assertRoot('/var'), ResetPlanError);
  assert.throws(() => assertRoot('/tmp'), ResetPlanError);
  assert.throws(() => assertRoot(join(tmpdir(), 'does-not-exist-dsh19')), ResetPlanError);
  const file = join(mkdtempSync(join(base, 'file-')), 'a.txt');
  writeFileSync(file, 'x');
  assert.throws(() => assertRoot(file), ResetPlanError);
  assert.throws(() => assertRoot(`${join(tmpdir(), 'a')}/../b`), ResetPlanError);
  assert.throws(() => assertRoot(`${join(tmpdir(), 'a')}\0`), ResetPlanError);
});

test('a valid root is returned with its canonical spelling', () => {
  const { root } = tree();
  const result = assertRoot(root);
  assert.equal(result.root, root);
  assert.ok(result.realRoot.startsWith(sep));
});

test('keeping everything moves only the runtime state', () => {
  const fixture = tree();
  const plan = computeResetPlan({ root: fixture.root, keepConversations: true, keepSettings: true });
  const moved = plan.move.map((entry) => entry.relative).sort();
  assert.deepEqual(moved, [
    join(DSH, '.container-root'),
    join(DSH, 'DSHPortE-session-migrate.json'),
    join(DSH, 'cache'),
    join(DSH, 'events.jsonl'),
    join(DSH, 'storages'),
    join(APPSUPPORT, 'DSHPortC-node.log'),
    join(APPSUPPORT, 'DSHPortC-session-url.txt'),
    join(APPSUPPORT, 'DSHPortC-status.json'),
    join(APPSUPPORT, 'boot'),
    join(APPSUPPORT, 'diagnostics'),
    join('Library', 'Caches', 'dsh-compile-cache'),
  ].sort());
  assert.equal(withPath(plan, join(DSH, 'sessions')), false);
  assert.equal(withPath(plan, join(DSH, '.credentials.yaml')), false);
  assert.equal(withPath(plan, join('Documents', 'workspace')), false);
});

test('dropping the conversations moves them, and nothing settings-shaped', () => {
  const fixture = tree();
  const plan = computeResetPlan({ root: fixture.root, keepConversations: false, keepSettings: true });
  assert.equal(withPath(plan, join(DSH, 'sessions')), true);
  assert.equal(withPath(plan, join(DSH, 'sessions-quarantine')), true);
  assert.equal(withPath(plan, join(DSH, 'attachments')), true);
  assert.equal(withPath(plan, join(DSH, '.credentials.yaml')), false);
  assert.equal(withPath(plan, join(DSH, 'profiles')), false);
  const tiers = plan.move.filter((entry) => entry.tier === 'conversations');
  assert.equal(tiers.length, 3);
});

test('dropping the settings moves the credentials, the profile and AGENTS.md', () => {
  const fixture = tree();
  const plan = computeResetPlan({ root: fixture.root, keepConversations: true, keepSettings: false });
  for (const relative of ['.credentials.yaml', 'profiles', 'AGENTS.md']) {
    assert.equal(withPath(plan, join(DSH, relative)), true, relative);
  }
  assert.equal(withPath(plan, join(DSH, 'sessions')), false);
});

test('dropping both moves every tier and still never the workspace', () => {
  const fixture = tree();
  const plan = computeResetPlan({ root: fixture.root, keepConversations: false, keepSettings: false });
  for (const tier of ['always', 'conversations', 'settings']) {
    assert.ok(plan.move.some((entry) => entry.tier === tier), tier);
  }
  assert.equal(plan.move.some((entry) => entry.relative.startsWith('Documents')), false);
  assert.ok(plan.keep.some((entry) => entry.relative === join('Documents', 'workspace')));
});

test('every planned path is inside the root and says how', () => {
  const fixture = tree();
  const { realRoot } = assertRoot(fixture.root);
  const plan = computeResetPlan({ root: fixture.root, keepConversations: false, keepSettings: false });
  for (const entry of plan.move) {
    assert.ok(entry.path.startsWith(realRoot + sep), `${entry.path} is inside`);
    assert.equal(entry.relative.startsWith('..'), false);
    assert.equal(entry.relative.includes('..' + sep), false);
    assert.ok(['dir', 'file'].includes(entry.kind));
    assert.ok(['always', 'conversations', 'settings', 'guest'].includes(entry.tier));
    assert.ok(entry.reason.length > 5);
  }
});

test('the staging directory is described but never planned', () => {
  const fixture = tree();
  const plan = computeResetPlan({ root: fixture.root, keepConversations: false, keepSettings: false });
  assert.equal(plan.staging.path, join(assertRoot(fixture.root).realRoot, STAGING.relative));
  assert.equal(plan.move.some((entry) => entry.path.startsWith(plan.staging.path)), false);
});

test('the guest image is kept unless it is asked for', () => {
  const fixture = tree();
  const kept = computeResetPlan({ root: fixture.root, keepConversations: true, keepSettings: true });
  assert.equal(kept.move.some((entry) => entry.tier === 'guest'), false);
  assert.ok(kept.keep.some((entry) => entry.relative.includes('ish-root')));

  const dropped = computeResetPlan({
    root: fixture.root, keepConversations: true, keepSettings: true, includeGuestImage: true,
  });
  assert.equal(withPath(dropped, join('Library', 'Application Support', 'ish-root')), true);
});

test('an entry that is not there is reported as missing, not as a move', () => {
  const fixture = tree();
  rmSync(join(fixture.dshHome, 'cache'), { recursive: true });
  const plan = computeResetPlan({ root: fixture.root, keepConversations: true, keepSettings: true });
  assert.equal(withPath(plan, join(DSH, 'cache')), false);
  assert.ok(plan.missing.some((entry) => entry.relative === join(DSH, 'cache')));
});

test('an unrecognised file in DSH_HOME is kept and named', () => {
  const fixture = tree();
  const plan = computeResetPlan({ root: fixture.root, keepConversations: false, keepSettings: false });
  assert.ok(plan.unknown.some((entry) => entry.relative === join(DSH, 'mystery.txt')));
  assert.ok(plan.keep.some((entry) => entry.relative === join(DSH, 'mystery.txt')));
  assert.equal(plan.move.some((entry) => entry.relative === join(DSH, 'mystery.txt')), false);
});

test('a symlinked entry is left alone and explained', () => {
  const fixture = tree();
  const outside = mkdtempSync(join(base, 'outside-'));
  writeFileSync(join(outside, 'precious.txt'), 'x');
  rmSync(join(fixture.dshHome, 'sessions'), { recursive: true });
  symlinkSync(outside, join(fixture.dshHome, 'sessions'));
  const plan = computeResetPlan({ root: fixture.root, keepConversations: false, keepSettings: true });
  assert.equal(withPath(plan, join(DSH, 'sessions')), false);
  assert.match(plan.warnings.join('\n'), /symbolic link/);
});

test('a symlinked parent hides everything below it', () => {
  const fixture = tree();
  const moved = mkdtempSync(join(base, 'moved-dsh-'));
  const outside = mkdtempSync(join(base, 'outside-dsh-'));
  mkdirSync(join(outside, 'sessions'), { recursive: true });
  writeFileSync(join(outside, 'sessions', 'x'), 'x');
  rmSync(join(fixture.root, DSH), { recursive: true });
  mkdirSync(moved, { recursive: true });
  symlinkSync(outside, join(fixture.root, DSH));
  const plan = computeResetPlan({ root: fixture.root, keepConversations: false, keepSettings: false });
  assert.equal(plan.move.some((entry) => entry.relative.startsWith(DSH + sep)), false, 'nothing through a link');
  assert.ok(plan.move.some((entry) => entry.relative.startsWith(APPSUPPORT)), 'unrelated roots are still planned');
  assert.match(plan.warnings.join('\n'), /behind a symbolic link/);
});

test('the plan is deterministic', () => {
  const fixture = tree();
  const a = computeResetPlan({ root: fixture.root, keepConversations: false, keepSettings: false });
  const b = computeResetPlan({ root: fixture.root, keepConversations: false, keepSettings: false });
  assert.equal(JSON.stringify(a.move), JSON.stringify(b.move));
  assert.equal(JSON.stringify(a.keep), JSON.stringify(b.keep));
});

test('the options have to be booleans', () => {
  const fixture = tree();
  assert.throws(() => computeResetPlan({ root: fixture.root }), ResetPlanError);
  assert.throws(() => computeResetPlan({ root: fixture.root, keepConversations: 'yes', keepSettings: true }), ResetPlanError);
});

test('an override outside the root is refused', () => {
  const fixture = tree();
  assert.throws(() => computeResetPlan({
    root: fixture.root, keepConversations: true, keepSettings: true, dshHome: '/etc',
  }), ResetPlanError);
  assert.throws(() => computeResetPlan({
    root: fixture.root, keepConversations: true, keepSettings: true, appSupport: '/tmp',
  }), ResetPlanError);
});

test('an override inside the root is used', () => {
  const fixture = tree();
  const custom = join(fixture.root, 'custom-dsh');
  mkdirSync(join(custom, 'cache'), { recursive: true });
  const plan = computeResetPlan({
    root: fixture.root, keepConversations: true, keepSettings: true, dshHome: custom,
  });
  assert.ok(plan.move.some((entry) => entry.path === join(custom, 'cache')));
});

test('a protected path is refused even if a caller asks for it', () => {
  const fixture = tree();
  const { realRoot } = assertRoot(fixture.root);
  for (const relative of PROTECTED.map((entry) => entry.rel)) {
    assert.throws(() => assertNotProtected(realRoot, join(realRoot, relative)), ResetPlanError);
    assert.throws(() => assertNotProtected(realRoot, join(realRoot, relative, 'deeper', 'x')), ResetPlanError);
  }
  assertNotProtected(realRoot, join(realRoot, DSH, 'sessions'));
});

test('dedupeNested keeps the outermost path only', () => {
  const paths = ['/a/b', '/a/b/c', '/a/bc', '/a/d', '/a/d'];
  assert.deepEqual(dedupeNested(paths), ['/a/b', '/a/bc', '/a/d']);
});

test('previewCombos returns all four combinations', () => {
  const fixture = tree();
  const preview = previewCombos({ root: fixture.root });
  assert.equal(preview.errors, undefined);
  assert.deepEqual(Object.keys(preview.combos).sort(), [...COMBO_KEYS].sort());
  for (const combo of Object.values(preview.combos)) {
    assert.equal(typeof combo.keepConversations, 'boolean');
    assert.ok(combo.move.length > 0);
    assert.ok(combo.move.every((entry) => typeof entry.relative === 'string'));
  }
});

test('describeTiers names what each tier is about', () => {
  const described = describeTiers();
  assert.deepEqual(described.map((entry) => entry.key), Object.keys(TIERS));
  const settings = described.find((entry) => entry.key === 'settings');
  assert.ok(settings.entries.some((entry) => entry.relative === join('DSH', '.credentials.yaml')));
});

test('the plan states which option controls each tier', () => {
  const fixture = tree();
  const plan = computeResetPlan({ root: fixture.root, keepConversations: true, keepSettings: false });
  assert.deepEqual(plan.options, { keepConversations: true, keepSettings: false, includeGuestImage: false });
  assert.equal(plan.summary.move, plan.move.length);
  assert.equal(plan.summary.missing, plan.missing.length);
});

// The app carries a second copy of this table for the launch where Node did not
// write `boot/reset-plan.json` (see PLAN-19 §6 and ResetSheet.swift). These two
// tests keep the copy honest on the JS side; `scripts/reset-plan-parity.py`
// compares it against the Swift source, which no `node --test` run can read.
test('relativeTable names every tier entry against the container', () => {
  const table = relativeTable();
  assert.deepEqual(Object.keys(table).sort(), ['always', 'conversations', 'guest', 'settings']);
  for (const [tier, entries] of Object.entries(TIERS)) {
    assert.equal(table[tier].length, entries.length, tier);
    for (const entry of table[tier]) {
      assert.equal(entry.relative.startsWith('/'), false, `${entry.relative} is container-relative`);
      assert.equal(entry.relative.includes('..'), false, `${entry.relative} cannot climb out`);
      assert.ok(['dir', 'file'].includes(entry.kind), `${entry.relative} has a kind`);
      assert.ok(entry.reason.length > 5, `${entry.relative} has a reason`);
    }
  }
  // The two roots the table spells out, spot-checked: an entry keyed to `dshHome`
  // must come out under `Library/Application Support/DSH`, and one keyed to
  // `container` must not gain that prefix.
  assert.ok(table.always.some((entry) => entry.relative === join('Library', 'Application Support', 'DSH', 'cache')));
  assert.ok(table.always.some((entry) => entry.relative === join('Library', 'Caches', 'dsh-compile-cache')));
  assert.ok(table.guest.some((entry) => entry.relative === join('Library', 'Application Support', 'ish-root')));
});

test('relativeCombos matches computeResetPlan for every combination', () => {
  const fixture = tree();
  const relative = relativeCombos();
  assert.deepEqual(Object.keys(relative).sort(), [...COMBO_KEYS].sort());
  for (const key of COMBO_KEYS) {
    const keepConversations = key.startsWith('keep-conversations');
    const keepSettings = key.endsWith('keep-settings');
    const plan = computeResetPlan({ root: fixture.root, keepConversations, keepSettings });
    // Same set of paths, in the same nesting-resolved form. The absolute plan
    // lists only what EXISTS on disk, so the fixture is a superset by
    // construction; every path it did plan has to be in the relative table.
    const planned = new Set(plan.move.map((entry) => entry.relative));
    for (const path of planned) {
      assert.ok(relative[key].includes(path), `${key}: ${path} is missing from relativeCombos()`);
    }
    // And the table adds nothing the plan would not move: everything it names is
    // either in the plan's move list or reported as missing on this fixture.
    const missing = new Set(plan.missing.map((entry) => entry.relative));
    for (const path of relative[key]) {
      assert.ok(planned.has(path) || missing.has(path), `${key}: ${path} is not a planned or missing path`);
    }
  }
});

test('relativeCombos drops a nested entry covered by its parent', () => {
  const relative = relativeCombos();
  for (const [key, paths] of Object.entries(relative)) {
    for (const path of paths) {
      const parent = paths.find((other) => other !== path && path.startsWith(other + sep));
      assert.equal(parent, undefined, `${key}: ${path} is covered by ${parent}`);
    }
  }
});
