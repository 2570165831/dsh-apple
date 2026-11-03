// What "reset the runtime environment" moves, given the two choices the user
// makes: keep the conversations, keep the settings.
//
// WHAT THIS MODULE IS
// -------------------
// A planner. It answers one question — "which paths, under this root, does this
// combination of options move?" — and it never moves, deletes or writes anything.
// The executor is the app (Swift, before `node_start`), because the reset has to
// happen before DSH builds its profile and opens the session store; see
// PLAN-19.md for its two-phase, crash-safe form.
//
// WHY THE PLAN IS COMPUTED AND NOT HARD-CODED IN SWIFT
// ----------------------------------------------------
// The paths mean different things depending on the options ("sessions" is
// conversation content; ".credentials.yaml" is settings), and getting that
// mapping wrong is a data-loss bug, not a layout bug. It is written once, here,
// covered by tests, and the app consumes the result as data (`reset-plan.json`,
// written at every launch by the bootstrap and read by the Swift sheet).
//
// WHY EVERY PATH IS CHECKED AGAIN
// -------------------------------
// A plan that names a path outside the root it was given is the one mistake that
// turns a reset into a deletion of something else. `assertRoot()` refuses a root
// that is not a plausible app container (the filesystem root, /private, a
// single-segment directory, a relative path, a file), and every candidate is
// resolved and re-checked against the root after resolution. A symlinked
// directory in the way is refused rather than followed: the link is not ours and
// moving through it would move something outside the root.
//
// WHAT IS NEVER TOUCHED
// ---------------------
// `Documents/workspace` — the user's files. It is on the protected list, and a
// plan entry that lands inside it is a programming error that throws rather than
// a path that quietly gets moved.

import { existsSync, lstatSync, readdirSync, realpathSync, statSync } from 'node:fs';
import {
  basename, dirname, isAbsolute, join, normalize, relative as pathRelative, resolve, sep,
} from 'node:path';

/** A root or a path this module refuses to plan against. */
export class ResetPlanError extends Error {
  constructor(message, code = 'reset-plan') {
    super(message);
    this.name = 'ResetPlanError';
    this.code = code;
  }
}

/** Paths that are never a reset target, whatever the options say. */
export const PROTECTED = Object.freeze([
  { rel: 'Documents/workspace', reason: 'the user\'s files' },
]);

/**
 * The tiers, in the order a report should show them.
 *
 * `at` names which root the path is relative to:
 *   `dshHome`    `Library/Application Support/DSH`
 *   `appSupport` `Library/Application Support/DSHPortC`
 *   `container`  the app data container itself
 */
export const TIERS = Object.freeze({
  always: Object.freeze([
    { at: 'dshHome', rel: 'cache', kind: 'dir', reason: 'rebuildable cache' },
    { at: 'dshHome', rel: 'storages', kind: 'dir', reason: 'DSH state (workspace registry, stored paths); a projection rebuilt from the session logs and the profile' },
    { at: 'dshHome', rel: 'events.jsonl', kind: 'file', reason: 'guest channel event stream' },
    { at: 'dshHome', rel: '.container-root', kind: 'file', reason: 'the container marker; written again on every launch' },
    { at: 'dshHome', rel: 'DSHPortE-session-migrate.json', kind: 'file', reason: 'the last migration summary' },
    { at: 'appSupport', rel: 'DSHPortC-node.log', kind: 'file', reason: 'the boot log' },
    { at: 'appSupport', rel: 'DSHPortC-status.json', kind: 'file', reason: 'the boot status file' },
    { at: 'appSupport', rel: 'DSHPortC-session-url.txt', kind: 'file', reason: 'the previous launch token' },
    { at: 'appSupport', rel: 'boot', kind: 'dir', reason: 'boot guard state, the pending request and the safe mode overlay' },
    { at: 'appSupport', rel: 'diagnostics', kind: 'dir', reason: 'diagnostic bundles from earlier launches' },
    { at: 'container', rel: 'Library/Caches/dsh-compile-cache', kind: 'dir', reason: 'the compile cache' },
  ]),
  conversations: Object.freeze([
    { at: 'dshHome', rel: 'sessions', kind: 'dir', reason: 'conversations' },
    { at: 'dshHome', rel: 'sessions-quarantine', kind: 'dir', reason: 'conversations isolated by an earlier launch' },
    { at: 'dshHome', rel: 'attachments', kind: 'dir', reason: 'images and files attached to those conversations' },
  ]),
  settings: Object.freeze([
    { at: 'dshHome', rel: '.credentials.yaml', kind: 'file', reason: 'API keys: part of the settings, not of the runtime' },
    { at: 'dshHome', rel: 'profiles', kind: 'dir', reason: 'the profile: provider settings and the user layer Settings saves' },
    { at: 'dshHome', rel: 'AGENTS.md', kind: 'file', reason: 'the user\'s own instructions' },
  ]),
  guest: Object.freeze([
    { at: 'container', rel: 'Library/Application Support/ish-root', kind: 'dir', reason: 'the Linux guest image; re-importing it from the bundle takes minutes and loses whatever was installed in it' },
  ]),
});

/** The four combinations the Swift sheet offers, as stable keys. */
export const COMBO_KEYS = Object.freeze([
  'keep-conversations+keep-settings',
  'keep-conversations+drop-settings',
  'drop-conversations+keep-settings',
  'drop-conversations+drop-settings',
]);

const DEFAULT_DSH_HOME = join('Library', 'Application Support', 'DSH');
const DEFAULT_APP_SUPPORT = join('Library', 'Application Support', 'DSHPortC');

/** Where an interrupted reset is finished from, and what it leaves behind. */
export const STAGING = Object.freeze({
  name: 'reset-staging',
  relative: join('Library', 'Application Support', 'DSHPortC', 'reset-staging'),
  inProgress: 'in-progress.json',
  manifest: 'manifest.json',
  complete: 'complete.json',
});

/** Directories that are a plausible boundary on paper but never a container. */
const REFUSED_ROOTS = new Set([
  '/', '/private', '/var', '/tmp', '/etc', '/dev', '/cores', '/home', '/root',
  '/Users', '/Applications', '/Library', '/System', '/Volumes', '/usr', '/opt', '/bin',
  // The macOS spellings of the same directories: `/var` is a symlink to
  // `/private/var`, so checking only the resolved path would miss `/var`.
  '/private/var', '/private/tmp', '/private/etc',
]);

function firstLine(error) {
  const text = error && error.message ? error.message : String(error);
  const newline = text.indexOf('\n');
  return newline === -1 ? text : text.slice(0, newline);
}

/**
 * Validate the root every planned path has to stay inside.
 *
 * @param {string} root an absolute directory, normally the app data container
 * @returns {{root: string, realRoot: string}} the input and its canonical form
 * @throws {ResetPlanError} when the root is not a usable boundary
 */
export function assertRoot(root) {
  if (typeof root !== 'string' || root.length === 0) {
    throw new ResetPlanError('root must be a non-empty absolute path', 'root-invalid');
  }
  if (root.includes('\0')) throw new ResetPlanError('root contains a NUL byte', 'root-invalid');
  if (!isAbsolute(root)) throw new ResetPlanError(`root must be absolute: ${root}`, 'root-invalid');
  if (normalize(root).split(sep).includes('..')) {
    throw new ResetPlanError(`root must not contain "..": ${root}`, 'root-invalid');
  }
  let stat;
  try {
    stat = statSync(root);
  } catch (error) {
    throw new ResetPlanError(`root does not exist: ${root} (${firstLine(error)})`, 'root-missing');
  }
  if (!stat.isDirectory()) throw new ResetPlanError(`root is not a directory: ${root}`, 'root-not-directory');
  let realRoot;
  try {
    realRoot = realpathSync(root);
  } catch (error) {
    throw new ResetPlanError(`root cannot be resolved: ${root} (${firstLine(error)})`, 'root-invalid');
  }
  if (REFUSED_ROOTS.has(realRoot) || REFUSED_ROOTS.has(normalize(root))) {
    throw new ResetPlanError(`root is a system directory: ${realRoot}`, 'root-refused');
  }
  const segments = realRoot.split(sep).filter((part) => part.length > 0);
  if (segments.length < 2) {
    throw new ResetPlanError(`root is too close to the filesystem root: ${realRoot}`, 'root-refused');
  }
  return { root, realRoot };
}

/**
 * Whether `absolute` is inside `root`, and how.
 *
 * @param {string} root an absolute directory
 * @param {string} absolute a candidate
 * @returns {string|null} the relative path, or null when it escapes
 */
function containedRelative(root, absolute) {
  const rel = pathRelative(root, absolute);
  if (rel.length === 0) return null;
  if (rel.startsWith('..') || isAbsolute(rel)) return null;
  return rel;
}

/**
 * The root as a boundary, in both of the spellings a caller may hold it in.
 *
 * `assertRoot()` returns the caller's string (§`root`) and its canonical form
 * (§`realRoot`). On macOS and on a phone those differ by a symlinked prefix:
 * `os.tmpdir()` and `URL(...).path` answer `/var/...`, `realpath` answers
 * `/private/var/...`. A caller that string-joins a path onto either one holds a
 * path that is inside the root, and a boundary that only knows the other
 * spelling reports it as an escape — `path.relative()` then answers
 * `../../../../../var/...`, which is what made the Node 24 run of
 * `tests/step19/reset-plan.test.mjs` throw `root-escape` for a path the test had
 * just created inside the root.
 *
 * So both are accepted, and the answer is the relative path from the root.
 * Nothing here follows a symlink INSIDE the root: this decides spelling, and
 * `symlinkedAncestor()` is what refuses to walk through a link.
 *
 * @param {string} root the caller's spelling
 * @param {string} realRoot the canonical spelling
 * @returns {{root: string, realRoot: string, relative(absolute: string): string|null}}
 */
function rootBoundary(root, realRoot) {
  const canonicalRoot = resolve(realRoot);
  const callerRoot = resolve(root);
  return {
    root: callerRoot,
    realRoot: canonicalRoot,
    relative(absolute) {
      const candidate = resolve(absolute);
      return containedRelative(canonicalRoot, candidate)
        ?? containedRelative(callerRoot, candidate);
    },
  };
}

/**
 * Refuse a path that would move the user's workspace.
 *
 * @param {string|object} root a root path, or a `rootBoundary()` result
 * @param {string} absolute
 * @throws {ResetPlanError} when `absolute` is inside a protected path
 */
export function assertNotProtected(root, absolute) {
  const boundary = typeof root === 'string' ? rootBoundary(root, root) : root;
  const candidate = resolve(absolute);
  for (const entry of PROTECTED) {
    const protectedPath = join(boundary.realRoot, entry.rel);
    const relative = boundary.relative(candidate);
    // Compare by RELATIVE path, not by string equality of two absolute paths:
    // the same location has two spellings, and an absolute comparison would let
    // `Documents/workspace` through when it arrived spelled the other way.
    if (relative === null) continue;
    if (relative === entry.rel || relative.startsWith(entry.rel + sep)) {
      throw new ResetPlanError(
        `refusing to plan a move of a protected path: ${entry.rel} (${entry.reason})`,
        'protected',
      );
    }
    if (containedRelative(protectedPath, candidate) !== null) {
      throw new ResetPlanError(`refusing to plan a move inside a protected path: ${entry.rel} (${entry.reason})`, 'protected');
    }
  }
}

/**
 * The first symlinked directory between `realRoot` and `absolute`, if any.
 *
 * Only the ancestors are checked: a link at the target itself is handled by the
 * caller (it is left alone, because moving a link moves the link).
 */
function symlinkedAncestor(boundary, absolute) {
  const rel = boundary.relative(absolute);
  if (rel === null) return { escape: true };
  const parts = rel.split(sep);
  // Walk from the CANONICAL root: the caller's spelling of the prefix can itself
  // be a symlink (`/var` -> `/private/var`), and treating that as "the target is
  // behind a link" would leave every plan empty on a Mac and on a phone.
  let current = boundary.realRoot;
  for (const part of parts.slice(0, -1)) {
    current = join(current, part);
    let stat;
    try {
      stat = lstatSync(current);
    } catch {
      return { missing: true };
    }
    if (stat.isSymbolicLink()) return { link: current };
    if (!stat.isDirectory()) return { missing: true };
  }
  return {};
}

/** Keep the outermost of a set of nested paths; drop the rest. */
export function dedupeNested(paths) {
  const sorted = [...new Set(paths)].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  const kept = [];
  for (const path of sorted) {
    const covered = kept.some((parent) => path === parent || path.startsWith(parent + sep));
    if (!covered) kept.push(path);
  }
  return kept;
}

function tierEntries({ keepConversations, keepSettings, includeGuestImage }) {
  const entries = [...TIERS.always];
  if (keepConversations !== true) entries.push(...TIERS.conversations);
  if (keepSettings !== true) entries.push(...TIERS.settings);
  if (includeGuestImage === true) entries.push(...TIERS.guest);
  return entries;
}

function rootFor(at, { realRoot, dshHome, appSupport }) {
  if (at === 'container') return { path: realRoot, rel: '' };
  if (at === 'dshHome') return { path: dshHome, rel: containedRelative(realRoot, dshHome) };
  if (at === 'appSupport') return { path: appSupport, rel: containedRelative(realRoot, appSupport) };
  throw new ResetPlanError(`unknown root key: ${String(at)}`, 'internal');
}

/**
 * Compute the plan for one combination of options.
 *
 * @param {object} options
 * @param {string} options.root the app data container (the boundary)
 * @param {boolean} options.keepConversations
 * @param {boolean} options.keepSettings
 * @param {boolean} [options.includeGuestImage] also drop the Linux guest image
 * @param {string} [options.dshHome] override, must be inside `root`
 * @param {string} [options.appSupport] override, must be inside `root`
 * @param {Date|number|string} [options.now]
 * @returns {object} the plan: `move`, `keep`, `missing`, `unknown`, `warnings`
 * @throws {ResetPlanError} for an unusable root, an override outside it, or a
 *   protected path in the result
 */
export function computeResetPlan(options = {}) {
  const {
    root, keepConversations, keepSettings, includeGuestImage = false, now = new Date(),
  } = options;
  const { realRoot } = assertRoot(root);
  if (typeof keepConversations !== 'boolean' || typeof keepSettings !== 'boolean') {
    throw new ResetPlanError('keepConversations and keepSettings must be booleans', 'options-invalid');
  }
  // An override keeps the caller's own spelling — `URL(...).path` and
  // `os.tmpdir()` both answer `/var/...` on a Mac and a phone, where the real
  // location is `/private/var/...` — so the absolute paths this plan hands back
  // stay comparable with the path the caller already holds. Whether that
  // spelling is inside the root is decided by `rootBoundary()`, which accepts
  // either namespace; see its header.
  const boundary = rootBoundary(root, realRoot);
  const overrides = {};
  for (const [name, override] of [['dshHome', options.dshHome], ['appSupport', options.appSupport]]) {
    if (override === undefined) continue;
    const absolute = resolve(override);
    if (!isAbsolute(absolute) || boundary.relative(absolute) === null) {
      throw new ResetPlanError(`${name} must be an absolute path inside the root: ${override}`, 'root-escape');
    }
    overrides[name] = absolute;
  }
  const dshHome = overrides.dshHome ?? join(realRoot, DEFAULT_DSH_HOME);
  const appSupport = overrides.appSupport ?? join(realRoot, DEFAULT_APP_SUPPORT);

  const warnings = [];
  const move = [];
  const missing = [];
  const covered = new Set();

  for (const entry of tierEntries({ keepConversations, keepSettings, includeGuestImage })) {
    const base = rootFor(entry.at, { realRoot, dshHome, appSupport });
    const absolute = resolve(base.path, entry.rel);
    const relFromRoot = boundary.relative(absolute);
    if (relFromRoot === null) {
      throw new ResetPlanError(`planned path escapes the root: ${absolute}`, 'root-escape');
    }
    assertNotProtected(boundary, absolute);
    covered.add(relFromRoot);
    const ancestor = symlinkedAncestor(boundary, absolute);
    if (ancestor.escape === true) {
      throw new ResetPlanError(`planned path escapes the root: ${absolute}`, 'root-escape');
    }
    if (ancestor.link !== undefined) {
      warnings.push(`left alone: ${relFromRoot} is behind a symbolic link (${ancestor.link})`);
      continue;
    }
    const stat = lstatOrNull(absolute);
    if (stat === null) {
      missing.push({ path: absolute, relative: relFromRoot, tier: entry.tierKey ?? tierOf(entry), reason: entry.reason });
      continue;
    }
    if (stat.isSymbolicLink()) {
      warnings.push(`left alone: ${relFromRoot} is a symbolic link`);
      continue;
    }
    move.push({
      path: absolute,
      relative: relFromRoot,
      kind: stat.isDirectory() ? 'dir' : 'file',
      tier: tierOf(entry),
      reason: entry.reason,
      bytes: stat.isDirectory() ? null : stat.size,
    });
  }

  const deduped = dedupeNested(move.map((entry) => entry.path));
  const dropped = move.filter((entry) => !deduped.includes(entry.path));
  const finalMove = move.filter((entry) => deduped.includes(entry.path));
  if (dropped.length > 0) {
    warnings.push(`dropped ${dropped.length} nested entr(ies) covered by a parent`);
  }

  const keep = [];
  for (const entry of PROTECTED) {
    const absolute = join(realRoot, entry.rel);
    if (existsSync(absolute)) keep.push({ path: absolute, relative: entry.rel, reason: entry.reason });
  }
  if (keepConversations === true) {
    for (const entry of TIERS.conversations) {
      const base = rootFor(entry.at, { realRoot, dshHome, appSupport });
      const absolute = resolve(base.path, entry.rel);
      const rel = boundary.relative(absolute);
      if (rel !== null) keep.push({ path: absolute, relative: rel, reason: `kept because conversations are kept: ${entry.reason}` });
    }
  }
  if (keepSettings === true) {
    for (const entry of TIERS.settings) {
      const base = rootFor(entry.at, { realRoot, dshHome, appSupport });
      const absolute = resolve(base.path, entry.rel);
      const rel = boundary.relative(absolute);
      if (rel !== null) keep.push({ path: absolute, relative: rel, reason: `kept because settings are kept: ${entry.reason}` });
    }
  }
  if (includeGuestImage === false) {
    for (const entry of TIERS.guest) {
      const absolute = resolve(realRoot, entry.rel);
      const rel = boundary.relative(absolute);
      if (rel !== null && existsSync(absolute)) {
        keep.push({ path: absolute, relative: rel, reason: `kept: ${entry.reason}` });
      }
    }
  }

  // Anything else in DSH_HOME is reported, never planned. A reset that removes a
  // directory it does not recognise is one build away from removing something
  // the user needs.
  const unknown = [];
  let names = [];
  try {
    names = readdirSync(dshHome, { withFileTypes: true }).map((entry) => entry.name).sort();
  } catch { /* a missing DSH_HOME is normal before the first launch */ }
  for (const name of names) {
    const absolute = join(dshHome, name);
    const rel = boundary.relative(absolute);
    if (rel === null || covered.has(rel)) continue;
    unknown.push({ path: absolute, relative: rel, reason: 'not recognised by this plan; left alone' });
    keep.push({ path: absolute, relative: rel, reason: 'not recognised by this plan; left alone' });
  }

  const plan = {
    version: 1,
    generatedAt: new Date(now).toISOString(),
    root,
    realRoot,
    dshHome,
    appSupport,
    options: { keepConversations, keepSettings, includeGuestImage },
    staging: {
      name: STAGING.name,
      path: join(realRoot, STAGING.relative),
      inProgress: STAGING.inProgress,
      manifest: STAGING.manifest,
      complete: STAGING.complete,
    },
    move: finalMove,
    keep,
    missing,
    unknown,
    warnings,
    summary: {
      move: finalMove.length,
      missing: missing.length,
      keep: keep.length,
      unknown: unknown.length,
    },
  };
  return plan;
}

function tierOf(entry) {
  for (const [name, list] of Object.entries(TIERS)) {
    if (list.includes(entry)) return name;
  }
  return 'unknown';
}

/**
 * Every combination in one object, for the Swift sheet.
 *
 * Written to `reset-plan.json` at boot: the sheet has to show what the user is
 * about to lose before the app can restart, and after a failed boot there is no
 * Node to ask. The relative paths are the same on every install, so the file is
 * small.
 *
 * @param {object} options see {@link computeResetPlan}, without the two booleans
 * @returns {{combos: Record<string, object>, error?: string}}
 */
export function previewCombos(options = {}) {
  const combos = {};
  const errors = [];
  for (const keepConversations of [true, false]) {
    for (const keepSettings of [true, false]) {
      const key = `${keepConversations ? 'keep' : 'drop'}-conversations+${keepSettings ? 'keep' : 'drop'}-settings`;
      try {
        const plan = computeResetPlan({ ...options, keepConversations, keepSettings });
        combos[key] = {
          keepConversations,
          keepSettings,
          move: plan.move.map((entry) => ({ relative: entry.relative, tier: entry.tier, reason: entry.reason })),
          keep: plan.keep.map((entry) => ({ relative: entry.relative, reason: entry.reason })),
          missing: plan.missing.length,
          warnings: plan.warnings,
        };
      } catch (error) {
        errors.push({ key, error: firstLine(error) });
      }
    }
  }
  return errors.length > 0 ? { combos, errors } : { combos };
}

/**
 * The tiers as container-relative paths, for the app's built-in fallback.
 *
 * WHY THE APP NEEDS A COPY OF THIS TABLE
 * --------------------------------------
 * `computeResetPlan()` runs in Node, and the sheet reads its answer from
 * `boot/reset-plan.json`. That file is written by Node at launch — and the
 * failure page is exactly the screen where there is no healthy Node: a launch
 * that never succeeded never wrote it. The sheet must still be able to say what
 * it would move before the user confirms, so the app carries the same paths.
 *
 * Two copies of one table is how a data-loss bug starts, so the copy is
 * CHECKED rather than trusted: `tests/step19/reset-plan.test.mjs` compares this
 * function against `TIERS`, and `scripts/reset-plan-parity.py` compares the
 * Swift source's table against this function's output. Both fail if the three
 * drift.
 *
 * The paths are relative to the app data container and name no install, so the
 * same strings are correct on every device and after a reinstall.
 *
 * @returns {{always: object[], conversations: object[], settings: object[], guest: object[]}}
 *   for each tier, `{relative, kind, reason}` with `relative` container-relative
 */
export function relativeTable() {
  const table = {};
  for (const [tier, entries] of Object.entries(TIERS)) {
    table[tier] = entries.map((entry) => ({
      relative: entry.at === 'container'
        ? entry.rel
        : join(entry.at === 'dshHome' ? DEFAULT_DSH_HOME : DEFAULT_APP_SUPPORT, entry.rel),
      kind: entry.kind,
      reason: entry.reason,
    }));
  }
  return table;
}

/**
 * The four combinations as container-relative move lists.
 *
 * The shape the app's fallback needs: one entry per combination key, already
 * deduplicated the way `computeResetPlan()` deduplicates (a parent covers its
 * children), so the sheet can show the same list whether Node answered or not.
 *
 * @returns {Record<string, string[]>}
 */
export function relativeCombos() {
  const table = relativeTable();
  const out = {};
  for (const key of COMBO_KEYS) {
    const keepConversations = key.startsWith('keep-conversations');
    const keepSettings = key.endsWith('keep-settings');
    const list = [...table.always];
    if (!keepConversations) list.push(...table.conversations);
    if (!keepSettings) list.push(...table.settings);
    out[key] = dedupeNested(list.map((entry) => entry.relative));
  }
  return out;
}

/**
 * The tiers as the sheet explains them.
 *
 * @returns {{key: string, entries: {relative: string, reason: string}[]}[]}
 */
export function describeTiers() {
  return Object.entries(TIERS).map(([key, list]) => ({
    key,
    entries: list.map((entry) => ({
      relative: entry.at === 'container'
        ? entry.rel
        : entry.at === 'dshHome' ? `DSH/${entry.rel}` : `DSHPortC/${entry.rel}`,
      reason: entry.reason,
    })),
  }));
}



function lstatOrNull(path) {
  try { return lstatSync(path); } catch { return null; }
}
