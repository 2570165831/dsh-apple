#!/usr/bin/env node
// Unit test for the observation state machine that decides the deleted-file case.
//
// WHY THIS EXISTS, given that `sim/step8-acceptance.mjs` already drives the real
// provider inside the app. Three things are still not measured there:
//
//   * the POLICY's three-way decision (unseen / absent / present) as a state
//     machine, independent of whether a session, a guest or a device happen to be
//     available — so a DSH upgrade that changes the transition fails HERE, in one
//     second, instead of as a confusing runtime refusal;
//   * that the failing `read` actually reaches the gate — the App criterion can
//     only assert that the emit line precedes the throw in the source;
//   * the exact refusal texts, which are what the model is told and therefore what
//     the phone's report quotes.
//
// HOW IT LOADS THE REAL CODE. Both packages are imported from `payload/` (the
// shipped tree), not re-implemented. The policy registers itself on a `ctx` that
// only has to supply `on` and `effect`; the waterfall semantics (`next`, first-wins
// single slot) are the ones its README documents and are reproduced here in ten
// lines rather than mocked away. A `FakeProvider` implements `writeText` with the
// same three branches as `dsh-fs-local/lib/index.js:867-871`, so the test asserts
// against the ORDER of decisions, not against a copy of the filesystem logic.
//
// WHAT IT DOES NOT DO: it does not touch the disk. The file's presence is a
// variable, which is the point — this is a state-machine test, and the on-disk
// half is covered by step 8's `provider_guard` criterion.
//
// Usage
//   node scripts/observation-units.mjs [--verbose]
//
// Exits non-zero on the first failed assertion.

import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '..');
const PAYLOAD = process.env.IOS_SIM_DSH_INSTALL ?? join(ROOT, 'payload');
const VERBOSE = process.argv.includes('--verbose');

const payloadModule = (name) =>
  import(pathToFileURL(join(PAYLOAD, 'node_modules', '@deepseek-ai', name, 'lib', 'index.js')).href);

const { apply: applyPolicy } = await payloadModule('dsh-fs-observation-policy');
const { FsError } = await payloadModule('dsh-fs');

// ------------------------------------------------------------------ assertions
let checks = 0;
const failures = [];

/**
 * Assert one fact.
 * @param {string} id - stable label, echoed on failure.
 * @param {unknown} actual - observed value.
 * @param {unknown} expected - required value.
 */
function check(id, actual, expected) {
  checks += 1;
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  if (!ok) failures.push({ id, actual, expected });
  if (VERBOSE || !ok) {
    console.log(`${ok ? 'PASS' : 'FAIL'}  ${id}${ok ? '' : `  actual=${JSON.stringify(actual)} expected=${JSON.stringify(expected)}`}`);
  }
}

/**
 * Assert that a thunk throws an FsError with a given code and message fragment.
 * @param {string} id - stable label.
 * @param {() => unknown} thunk - the call expected to throw.
 * @param {string} code - required `error.code`.
 * @param {string} fragment - required substring of `error.message`.
 */
async function throwsWith(id, thunk, code, fragment) {
  checks += 1;
  try {
    await thunk();
    failures.push({ id, actual: 'did not throw', expected: `${code} / ${fragment}` });
    if (VERBOSE) console.log(`FAIL  ${id}  did not throw`);
  } catch (error) {
    const gotCode = error?.code ?? null;
    const gotMessage = String(error?.message ?? '');
    const ok = gotCode === code && gotMessage.includes(fragment);
    if (!ok) failures.push({ id, actual: { code: gotCode, message: gotMessage }, expected: { code, fragment } });
    if (VERBOSE || !ok) {
      console.log(`${ok ? 'PASS' : 'FAIL'}  ${id}${ok ? '' : `  actual=${gotCode} "${gotMessage}"`}`);
    }
  }
}

// ------------------------------------------------- the policy, on a fake ctx
//
// `apply()` needs exactly two things: `ctx.on(event, listener)` to register, and
// `ctx.effect(fn)` for the teardown it wraps in a disposal callback. Everything
// else the policy does is its own WeakMap, which is the property under test.
function mountPolicy() {
  const listeners = new Map();
  const ctx = {
    on(event, listener) {
      if (!listeners.has(event)) listeners.set(event, []);
      listeners.get(event).push(listener);
    },
    effect(fn) {
      fn();
    },
  };
  applyPolicy(ctx);

  // The `fs/*`-intent slots are single-slot and FIRST-WINS: the policy fully
  // decides and never calls `next()`. `dsh-tool-fs` dispatches them through a
  // waterfall, which for one listener is just "call it". The fallback `next` is
  // therefore only reachable when the policy is silent, and this harness makes
  // that visible instead of hiding it.
  //
  // AWAIT IS REQUIRED, and this is the trap that made the first version of this
  // file report 21 bogus failures: the policy's listeners are
  // `(target, actor) => Promise.resolve().then(() => gate.writeIntent(...))`, so a
  // synchronous read gets a Promise (which JSON-stringifies as `{}`) and a
  // synchronous `expect throw` sees nothing thrown. Every call site awaits.
  const decide = async (event, target, actor, fallback) => {
    const first = listeners.get(event)?.[0];
    if (first === undefined) return fallback();
    return first(target, actor, () => fallback());
  };
  const emit = (event, ...args) => {
    for (const listener of listeners.get(event) ?? []) listener(...args);
  };
  return { decide, emit, listeners };
}

// ------------------------------------------------- the provider's three branches
//
// A stand-in for `dsh-fs-local`'s `writeText`, reproducing only what the three
// intent kinds do (see `lib/index.js:864-880`):
//
//   createIfAbsent      -> no-clobber create; fails if the file appeared
//   replaceIfVersion    -> fails FS_STALE_VERSION when the version moved or the
//                          file is gone; that is the phone's message
//   (no intent)         -> unconditional write
class FakeProvider {
  constructor() {
    /** @type {{version: string} | null} */
    this.file = null;
    this.version = 0;
    this.calls = [];
  }

  /** Create or overwrite, bumping the version. @returns {string} the new version. */
  touch() {
    this.version += 1;
    this.file = { version: `v${this.version}` };
    return this.file.version;
  }

  /** Delete the file the way a shell command would: no notification to anyone. */
  delete() {
    this.file = null;
  }

  /**
   * Write with an intent, mirroring the provider's guard order.
   * @param {object|undefined} intent - from the policy's waterfall slot.
   * @returns {{operation: string, version: string}} the outcome.
   */
  writeText(intent) {
    this.calls.push(intent ?? null);
    const existing = this.file;
    if (intent?.kind === 'replaceIfVersion') {
      if (existing === null) throw new FsError('cannot write "/w/x.md": file no longer exists', 'FS_STALE_VERSION');
      if (existing.version !== intent.version) throw new FsError('cannot write "/w/x.md": file changed since it was read', 'FS_STALE_VERSION');
    } else if (intent?.kind === 'createIfAbsent' && existing !== null) {
      throw new FsError('cannot overwrite existing "/w/x.md" without reading it first', 'FS_NOT_OBSERVED');
    }
    const created = existing === null;
    const version = this.touch();
    return { operation: created ? 'create' : 'update', version };
  }
}

// The target identity the policy keys on. `FsTargetKey` is a branded string in
// the real provider; here the value only has to be stable, and using the same
// string twice is what makes two calls "the same file".
const target = { displayPath: '/w/x.md', targetKey: '/w/x.md' };
const other = { displayPath: '/w/other.md', targetKey: '/w/other.md' };
// The policy derives its owner from `actor.agent.session`; any object works, and
// two distinct objects must NOT share observations.
const sessionA = { name: 'A' };
const actorA = { agent: { session: sessionA } };

/**
 * Reproduce `dsh-tool-fs`'s failing read: emit the absence, then throw.
 * @param {{emit: Function}} policy - the mounted policy.
 * @param {object} t - the target to mark absent.
 * @param {object} [actor] - the calling session.
 */
function failingRead(policy, t, actor = actorA) {
  policy.emit('fs/observed', t, { kind: 'absent' }, actor);
  throw new FsError(`cannot read "${t.displayPath}": not found`, 'FS_NOT_FOUND');
}

// --------------------------------------------------------------- scenario runs
console.log('observation-units: driving the shipped policy package\n');

// 1. UNSEEN. No observation at all: a write must be an unguarded create.
{
  const policy = mountPolicy();
  const intent = await policy.decide('fs/write-intent', target, actorA, () => undefined);
  check('unseen/write_intent', intent, { kind: 'createIfAbsent' });
}
{
  const policy = mountPolicy();
  await throwsWith(
    'unseen/edit_intent',
    async () => await policy.decide('fs/edit-intent', target, actorA, () => undefined),
    'FS_NOT_OBSERVED',
    'edit requires reading',
  );
}

// 2. PRESENT, then deleted behind the policy's back. This is the phone's state:
//    the record still says present@v1 and the file is gone.
{
  const policy = mountPolicy();
  const provider = new FakeProvider();

  const firstIntent = await policy.decide('fs/write-intent', target, actorA, () => undefined);
  const first = provider.writeText(firstIntent);
  // `mutationResult` emits present at the version the provider returned.
  policy.emit('fs/observed', target, { kind: 'present', version: first.version }, actorA);
  check('present/first_write_operation', first.operation, 'create');

  const secondIntent = await policy.decide('fs/write-intent', target, actorA, () => undefined);
  check('present/write_intent_is_versioned', secondIntent.kind, 'replaceIfVersion');
  check('present/write_intent_version', secondIntent.version, first.version);

  provider.delete();
  await throwsWith(
    'present/stale_replace_after_delete',
    () => provider.writeText(secondIntent),
    'FS_STALE_VERSION',
    'file no longer exists',
  );
}

// 3. THE RECOVERY. The failing read records absence, and the next write must
//    become a guarded create that succeeds on the deleted path.
{
  const policy = mountPolicy();
  const provider = new FakeProvider();

  const first = provider.writeText(await policy.decide('fs/write-intent', target, actorA, () => undefined));
  policy.emit('fs/observed', target, { kind: 'present', version: first.version }, actorA);
  provider.delete();

  // The refusing write the phone saw.
  const staleIntent = await policy.decide('fs/write-intent', target, actorA, () => undefined);
  await throwsWith(
    'recovery/refused_write',
    () => provider.writeText(staleIntent),
    'FS_STALE_VERSION',
    'file no longer exists',
  );

  // The "pointless" remedy: read fails, and records absence while failing.
  await throwsWith('recovery/read_reports_not_found', () => failingRead(policy, target), 'FS_NOT_FOUND', 'not found');

  // And this is the whole question: does that failed read unlock the write?
  const afterRead = await policy.decide('fs/write-intent', target, actorA, () => undefined);
  check('recovery/write_intent_after_failed_read', afterRead, { kind: 'createIfAbsent' });

  const recreated = provider.writeText(afterRead);
  check('recovery/write_operation', recreated.operation, 'create');

  // A second round on the same path, because the phone's report had a second
  // attempt too, and a fix that only worked once would be no fix.
  policy.emit('fs/observed', target, { kind: 'present', version: recreated.version }, actorA);
  provider.delete();
  await throwsWith(
    'recovery/second_refused_write',
    async () => provider.writeText(await policy.decide('fs/write-intent', target, actorA, () => undefined)),
    'FS_STALE_VERSION',
    'file no longer exists',
  );
  await throwsWith('recovery/second_failed_read', () => failingRead(policy, target), 'FS_NOT_FOUND', 'not found');
  const third = provider.writeText(await policy.decide('fs/write-intent', target, actorA, () => undefined));
  check('recovery/second_recreate_operation', third.operation, 'create');
}

// 4. THE EDITOR'S HALF. `str_replace_editor create` stats first, then asks the
//    intent slot. Absence must therefore let it through with the same
//    `createIfAbsent`, and its own pre-stat must not have recorded anything on
//    its own (a stat is not an observation).
{
  const policy = mountPolicy();
  const provider = new FakeProvider();

  const first = provider.writeText(await policy.decide('fs/write-intent', target, actorA, () => undefined));
  policy.emit('fs/observed', target, { kind: 'present', version: first.version }, actorA);
  provider.delete();

  // `createFile` throws "File already exists" only when the stat finds something;
  // here it finds nothing, so it proceeds to the intent slot.
  const createIntent = await policy.decide('fs/write-intent', target, actorA, () => ({ kind: 'createIfAbsent' }));
  check('editor/create_intent_still_versioned_before_read', createIntent.kind, 'replaceIfVersion');

  await throwsWith('editor/refused_create', () => provider.writeText(createIntent), 'FS_STALE_VERSION', 'file no longer exists');

  await throwsWith('editor/failed_view', () => failingRead(policy, target), 'FS_NOT_FOUND', 'not found');
  const afterRead = await policy.decide('fs/write-intent', target, actorA, () => ({ kind: 'createIfAbsent' }));
  check('editor/create_intent_after_failed_read', afterRead, { kind: 'createIfAbsent' });
  check('editor/create_operation', provider.writeText(afterRead).operation, 'create');
}

// 5. CONFIRMED ABSENT WITHOUT EVER EXISTING. Reading a path that was never there
//    must also authorize the create — that is the ordinary "create a new file"
//    flow, and it must not need a prior present observation.
{
  const policy = mountPolicy();
  const provider = new FakeProvider();
  await throwsWith('absent/read_missing', () => failingRead(policy, other), 'FS_NOT_FOUND', 'not found');
  const intent = await policy.decide('fs/write-intent', other, actorA, () => undefined);
  check('absent/write_intent', intent, { kind: 'createIfAbsent' });
  check('absent/create_operation', provider.writeText(intent).operation, 'create');
  await throwsWith(
    'absent/edit_intent_after_absent_read',
    async () => await policy.decide('fs/edit-intent', other, actorA, () => undefined),
    'FS_NOT_FOUND',
    'not found',
  );
}

// 6. OWNERSHIP. Observations are per session: another session must not inherit
//    this one's `present`, or a resumed second agent could clobber a file it
//    never read.
{
  const policy = mountPolicy();
  const provider = new FakeProvider();
  const first = provider.writeText(await policy.decide('fs/write-intent', target, actorA, () => undefined));
  policy.emit('fs/observed', target, { kind: 'present', version: first.version }, actorA);

  const actorB = { agent: { session: { name: 'B' } } };
  const foreign = await policy.decide('fs/write-intent', target, actorB, () => undefined);
  check('ownership/other_session_sees_unseen', foreign, { kind: 'createIfAbsent' });
  await throwsWith(
    'ownership/other_session_cannot_edit',
    async () => await policy.decide('fs/edit-intent', target, actorB, () => undefined),
    'FS_NOT_OBSERVED',
    'edit requires reading',
  );

  // No owner at all (a direct tool call with no agent) reads freely but cannot
  // satisfy the write policy: `writeIntent` answers `createIfAbsent`, which the
  // provider refuses against an existing file. That refusal is the correct
  // answer, not a bug — recorded here so an upgrade that "fixes" it is noticed.
  const anonymous = await policy.decide('fs/write-intent', target, undefined, () => undefined);
  check('ownership/no_owner_is_unseen', anonymous, { kind: 'createIfAbsent' });
  await throwsWith(
    'ownership/no_owner_write_refused_on_existing',
    () => provider.writeText(anonymous),
    'FS_NOT_OBSERVED',
    'without reading it first',
  );
}

// 7. FIRST-WINS. The slot has exactly one decider and the policy never calls
//    `next()`. That is what lets `dsh-workspace-changes` PREPEND a capture
//    listener (it calls `next()` itself and forwards the answer), and it is why a
//    second decider registered after the policy is never consulted.
//
//    The earlier version of this scenario was wrong in a way worth recording: it
//    mounted a SECOND policy instance and expected `replaceIfVersion`, but a fresh
//    instance has no observations, so `createIfAbsent` was the correct answer and
//    the "failure" was in the test. The decisive fact is the ORDER of registration,
//    so the scenario now observes one instance and appends a decider to its slot.
{
  const policy = mountPolicy();
  const provider = new FakeProvider();
  const first = provider.writeText(await policy.decide('fs/write-intent', target, actorA, () => undefined));
  policy.emit('fs/observed', target, { kind: 'present', version: first.version }, actorA);

  let secondRan = false;
  const slot = policy.listeners.get('fs/write-intent');
  check('first_wins/slot_has_one_decider', slot.length, 1);
  slot.push(() => {
    secondRan = true;
    return { kind: 'createIfAbsent' };
  });
  // The waterfall takes slot[0]; the appended decider must stay unconsulted.
  const decided = await slot[0](target, actorA, () => undefined);
  check('first_wins/second_decider_did_not_run', secondRan, false);
  check('first_wins/decision_is_the_policys', decided.kind, 'replaceIfVersion');

  // And the prepend case `dsh-workspace-changes` actually uses: a listener that
  // calls `next()` and returns its answer must produce the SAME decision.
  const forwarded = mountPolicy();
  const provider2 = new FakeProvider();
  const second = provider2.writeText(await forwarded.decide('fs/write-intent', target, actorA, () => undefined));
  forwarded.emit('fs/observed', target, { kind: 'present', version: second.version }, actorA);
  const slot2 = forwarded.listeners.get('fs/write-intent');
  const policyDecider = slot2[0];
  slot2.unshift(async (t, actor, next) => policyDecider(t, actor, next));
  const viaCapture = await slot2[0](target, actorA, () => undefined);
  check('first_wins/prepended_capture_forwards_the_same_decision', viaCapture.kind, 'replaceIfVersion');
  check('first_wins/prepended_capture_forwards_the_version', viaCapture.version, second.version);
}

// ------------------------------------------------------------------- verdict
console.log(`\nobservation-units: ${checks - failures.length}/${checks} passed`);
if (failures.length > 0) {
  console.log('\nfailures:');
  for (const failure of failures) console.log(`  ${failure.id}: got ${JSON.stringify(failure.actual)}, want ${JSON.stringify(failure.expected)}`);
  process.exit(1);
}

// The report quotes these two lines as the shipped refusal texts; printing them
// from the packages keeps the quote honest if either is reworded.
const localSource = readFileSync(join(PAYLOAD, 'node_modules', '@deepseek-ai', 'dsh-fs-local', 'lib', 'index.js'), 'utf8');
const line = localSource.split('\n').findIndex((text) => text.includes('file no longer exists')) + 1;
console.log(`dsh-fs-local refusal line: ${line}`);
process.exit(0);
