// Safe mode for the phone: the composition the app boots with when the normal
// one has failed several launches in a row.
//
// WHAT SAFE MODE IS
// -----------------
// Two changes, and no others:
//
//   1. The app's own plugins that are not needed for the page or for creating a
//      session are switched off, through a `--patch` overlay. `cordis.yml` says
//      the tree is composed "each bundle in package.json's dsh.profile.bundles,
//      then cordis.patch.yml, then any --patch overlays", so an overlay appended
//      to argv is the last word and can override both the app layer and the user
//      layer.
//   2. The user layer (`profiles/ios-sim/cordis.patch.yml`, where Settings
//      saves) is parked. It is the one part of the composition this repository
//      does not control: any valid YAML can arrive there, and an unparsable file
//      takes the whole profile down before a single plugin is mounted. An
//      overlay cannot disable a row it cannot name, so the only honest way to
//      skip the user layer is to not have it — park the file, put `[]` in its
//      place, and put it back on the next normal launch.
//
// WHAT SAFE MODE IS NOT
// ---------------------
// It is not a sandbox and not a reset. Everything the app writes (sessions,
// settings, credentials) is still there; the plugins that survive behave exactly
// as they do in a normal launch. And it cannot rescue damage it does not cover:
// a corrupt `storages/` file or a session log DSH calls corrupt stops the boot
// with or without safe mode — that is what "reset runtime" is for.
//
// WHY THE PARK IS TWO WRITES AND NO MORE
// --------------------------------------
// rename (park) then write `[]`. A crash between them leaves no
// `cordis.patch.yml`, which the Swift host recreates as `[]` on the next launch;
// the parked copy is still there and `restoreUserPatch()` puts it back. There is
// no window in which the user's settings exist only in a half-written file.

import {
  closeSync, existsSync, fsyncSync, lstatSync, mkdirSync, openSync, readFileSync, renameSync,
  unlinkSync, writeSync,
} from 'node:fs';
import { join, isAbsolute, dirname } from 'node:path';

/** File the user layer is parked under, beside the file itself. */
export const PARKED_SUFFIX = '.safe-mode-parked';

/** The row id pattern a patch row can carry unquoted. */
const ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;

/** The file name of `--patch` overlays this module writes. */
export const OVERLAY_FILE_NAME = 'safe-mode.patch.yml';

/**
 * The app-owned rows safe mode switches off.
 *
 * The rule behind the list: everything the app itself contributes is a candidate
 * (it is code this repository ships, so it is the part that can regress between
 * builds), and it stays off unless the page or the session surface needs it. See
 * `REQUIRED` for the ones that are exempt, and `PLAN-19.md` for the row-by-row
 * comparison against `profiles/ios-sim/cordis.patch.yml`.
 */
export const DEFAULT_SKIP = Object.freeze([
  {
    id: 'guest-runtimes',
    reason: 'prompt text about what the guest can run, not behaviour',
  },
  {
    id: 'diag-prompt',
    reason: 'logging only (the real reason behind session/agent-busy); its absence costs one clue, not the boot',
  },
  {
    id: 'busy-ios',
    reason: 'reports busy state to the Swift host so a backgrounded turn can keep going; nothing on the page needs it',
  },
  {
    id: 'notify-ios',
    reason: 'reports session events for local notifications; unrelated to the boot',
  },
  {
    id: 'directory-picker-browse',
    reason: 'the workspace folder picker, host half; workspace-controller.documentsDirectory already registers '
      + 'a default workspace, so a session can be created without it',
  },
  {
    id: 'ui-directory-picker-browse',
    reason: 'the workspace folder picker, client half; disabled together with its host half so the page never '
      + 'offers a button whose backend is missing',
  },
]);

/**
 * The app-owned rows safe mode keeps, with the reason each one is exempt.
 *
 * These are the providers that other rows *inject*. Switching one off does not
 * remove a feature; it leaves the rows that declare `inject` pending, and the
 * profile's own notes record what that costs: with `dsh-permission-presets`
 * pending, `dsh-api-session-controller` never mounts and the web UI cannot
 * create a session at all. A safe mode that opens the page and cannot start a
 * conversation is not worth the risk of a stalled tree, so the providers stay.
 */
export const REQUIRED = Object.freeze([
  { id: 'fs-ios', reason: 'the only ctx.fs provider: the app layer disables the stock fs-sandbox' },
  { id: 'subprocess-ish', reason: 'the only ctx.subprocess provider: the app layer disables the stock subprocess' },
  { id: 'sandbox-ios', reason: 'the only ctx.sandbox provider; bash-sandbox and sandbox-policy inject it' },
  {
    id: 'ish-approval-policy',
    reason: 'the only contributor of an ask decision for destructive bash commands; safe mode is the launch a '
      + 'confused user is most likely to run a destructive command in, so the confirmation has to stay',
  },
  {
    id: 'attachment-ios',
    reason: 'the only ctx.attachments provider, and dsh-api-session-controller INJECTS attachments and '
      + 'fileUploads: skipping it leaves the session RPC surface pending and no session can be created at all '
      + '(measured on the simulator — see REPORT-19 §4). It only refuses to mount when the guest channel is '
      + 'absent, which is not the failure safe mode is rescuing',
  },
]);

function message(error) {
  return error && error.message ? error.message : String(error);
}

function assertId(id) {
  if (typeof id !== 'string' || !ID_PATTERN.test(id)) {
    throw new TypeError(`safe-mode: not a patch row id: ${JSON.stringify(id)}`);
  }
}

/** Synchronous, atomic write of a small text file. */
function writeTextAtomic(file, text) {
  mkdirSync(dirname(file), { recursive: true });
  const temp = `${file}.${process.pid}.${Math.random().toString(16).slice(2)}.tmp`;
  const fd = openSync(temp, 'w');
  try {
    writeSync(fd, text);
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
}

/**
 * The `--patch` overlay that switches the listed rows off.
 *
 * The format is the one `cordis.patch.yml` itself uses: a YAML sequence of rows,
 * a row that carries an `id` and no `name` applies its other keys to the row with
 * that id (the profile explains why naming the plugin would be skipped instead).
 *
 * @param {object} [options]
 * @param {ReadonlyArray<{id: string, reason?: string}>} [options.skip]
 * @param {Date|number|string} [options.now]
 * @param {string} [options.reason] why this launch is in safe mode
 * @returns {string} the overlay text, ready to be written and passed to `--patch`
 */
export function buildOverlay({ skip = DEFAULT_SKIP, now = new Date(), reason = '' } = {}) {
  if (!Array.isArray(skip) || skip.length === 0) {
    // An overlay that disables nothing is a lie: it would report safe mode while
    // booting the composition that just failed.
    throw new TypeError('safe-mode: refusing to build an overlay with no rows');
  }
  const seen = new Set();
  const required = new Set(REQUIRED.map((entry) => entry.id));
  for (const entry of skip) {
    const id = typeof entry === 'string' ? entry : entry?.id;
    assertId(id);
    if (seen.has(id)) throw new TypeError(`safe-mode: duplicate row id ${id}`);
    if (required.has(id)) throw new TypeError(`safe-mode: ${id} is required and cannot be skipped`);
    seen.add(id);
  }
  const stamp = now instanceof Date ? now.toISOString() : new Date(now).toISOString();
  const lines = [
    '# Written by sim/safe-mode.mjs for a safe-mode launch. Do not edit: the app',
    '# rewrites this file on every safe-mode boot.',
    `# generated: ${stamp}`,
    `# reason: ${reason === '' ? 'safe mode was requested' : reason}`,
    `# skipped rows: ${skip.length} (see PLAN-19.md for the row-by-row reasoning)`,
    '',
  ];
  for (const entry of skip) {
    const id = typeof entry === 'string' ? entry : entry.id;
    lines.push(`- id: ${id}`, '  disabled: true', '');
  }
  return lines.join('\n');
}

/**
 * Park the user layer so DSH never reads it during a safe-mode launch.
 *
 * @param {object} options
 * @param {string} options.profileDir absolute `.../DSH/profiles/ios-sim`
 * @returns {{parked: boolean, created: boolean, alreadyParked: boolean, warning?: string}}
 */
export function parkUserPatch({ profileDir } = {}) {
  if (typeof profileDir !== 'string' || !isAbsolute(profileDir)) {
    throw new TypeError('safe-mode: profileDir must be an absolute path');
  }
  const patch = join(profileDir, 'cordis.patch.yml');
  const parked = patch + PARKED_SUFFIX;
  if (!existsSync(profileDir)) {
    throw new Error(`safe-mode: no profile directory at ${profileDir}`);
  }
  const stat = lstatOrNull(patch);
  if (stat !== null && stat.isSymbolicLink()) {
    // Renaming a link would move the link and leave whatever it points at in
    // place; writing `[]` over it would then hide someone else's file. Refuse.
    throw new Error(`safe-mode: ${patch} is a symbolic link; refusing to park it`);
  }
  if (existsSync(parked)) {
    const current = readIfExists(patch);
    if (current === null) {
      writeTextAtomic(patch, '[]\n');
      return { parked: false, created: true, alreadyParked: true };
    }
    if (current.trim() === '[]' || current.trim() === '') {
      return { parked: false, created: false, alreadyParked: true };
    }
    // Someone edited the user layer during a safe-mode session. Overwriting it
    // would be destroying a setting the user typed, so the file is left as it
    // is and the boot log says why safe mode is not fully safe this launch.
    return {
      parked: false,
      created: false,
      alreadyParked: true,
      warning: 'the user layer changed during a safe-mode session; left in place',
    };
  }
  if (stat !== null) {
    renameSync(patch, parked);
    writeTextAtomic(patch, '[]\n');
    return { parked: true, created: false, alreadyParked: false };
  }
  // No user layer at all: give the profile a valid, empty one.
  writeTextAtomic(patch, '[]\n');
  return { parked: false, created: true, alreadyParked: false };
}

/** Suffix for a user layer edited during a safe-mode session (see below). */
export const EDITED_SUFFIX = '.safe-mode-edited';

/**
 * An unused `cordis.patch.yml.safe-mode-edited[.N]` path beside `patch`.
 *
 * Numbered rather than overwritten: two safe-mode sessions in a row would
 * otherwise leave the first edited copy to be destroyed by the second.
 *
 * @param {string} patch absolute `.../cordis.patch.yml`
 * @returns {string} an absolute path that does not exist yet
 */
function editedCopyPath(patch) {
  const base = patch + EDITED_SUFFIX;
  if (!existsSync(base)) return base;
  for (let n = 2; n < 1000; n += 1) {
    const candidate = `${base}.${n}`;
    if (!existsSync(candidate)) return candidate;
  }
  throw new Error(`safe-mode: no free ${EDITED_SUFFIX} name beside ${patch}`);
}

/**
 * Put the user layer back. Called on every launch that is not a safe-mode one,
 * before DSH reads the profile, so a safe-mode session cannot outlive its cause.
 *
 * WHAT HAPPENS TO A LAYER EDITED WHILE SAFE MODE WAS ON
 * -----------------------------------------------------
 * Parking writes `[]` in place of the user's layer, so Settings can still save
 * while safe mode runs — and it does: the settings page is reachable, and a
 * provider added during a safe-mode session is written into that `[]`. A plain
 * `rename(parked, patch)` would then delete what the user just typed, which is
 * the exact opposite of `parkUserPatch()`'s "warn, never overwrite" rule.
 *
 * So before the parked copy is restored, a current file whose content is
 * something other than empty or `[]` is MOVED ASIDE to
 * `cordis.patch.yml.safe-mode-edited` (numbered on collision) and its path is
 * returned, so the app can say where those settings went. Nothing is deleted and
 * the file that is restored is the one the user had before safe mode.
 *
 * `[]` and an empty file are not "edits": they are what parking itself leaves,
 * and what the Swift host writes when the file is missing. Renaming those would
 * fill the profile directory with copies of the word `[]`.
 *
 * @param {object} options
 * @param {string} options.profileDir absolute `.../DSH/profiles/ios-sim`
 * @returns {{restored: boolean, editedCopy?: string, reason?: string}}
 */
export function restoreUserPatch({ profileDir } = {}) {
  if (typeof profileDir !== 'string' || !isAbsolute(profileDir)) {
    throw new TypeError('safe-mode: profileDir must be an absolute path');
  }
  const patch = join(profileDir, 'cordis.patch.yml');
  const parked = patch + PARKED_SUFFIX;
  if (!existsSync(parked)) return { restored: false };

  let editedCopy;
  const current = readIfExists(patch);
  const trimmed = current === null ? '' : current.trim();
  if (trimmed !== '' && trimmed !== '[]') {
    try {
      editedCopy = editedCopyPath(patch);
      renameSync(patch, editedCopy);
    } catch (error) {
      // The settings are more valuable than the restore. Leave both files in
      // place and report it: the next launch tries again.
      return {
        restored: false,
        reason: `could not move the edited user layer aside: ${message(error)}`,
      };
    }
  }

  try {
    renameSync(parked, patch);
  } catch (error) {
    // Put the edited copy back where the user expects it rather than leaving
    // their settings under a name nothing reads.
    if (editedCopy !== undefined) {
      try { renameSync(editedCopy, patch); } catch { /* both files still exist */ }
    }
    return { restored: false, reason: message(error) };
  }
  return editedCopy === undefined ? { restored: true } : { restored: true, editedCopy };
}

/**
 * Everything a safe-mode launch needs on disk, in one call.
 *
 * Order matters and is the crash-safety argument above: park first, then the
 * overlay. A failure to write the overlay is reported, not thrown from the boot
 * path — a safe mode without the overlay is still better than no boot — but the
 * caller must pass the overlay to `applyToArgv` only when it was written.
 *
 * @param {object} options
 * @param {string} options.profileDir absolute `.../DSH/profiles/ios-sim`
 * @param {string} options.overlayPath absolute path to write the overlay to
 * @param {ReadonlyArray<{id: string}>} [options.skip]
 * @param {Date|number|string} [options.now]
 * @param {string} [options.reason]
 * @returns {{overlayPath: string, parked: object, warnings: string[]}}
 */
export function prepare({ profileDir, overlayPath, skip = DEFAULT_SKIP, now = new Date(), reason = '' } = {}) {
  if (typeof overlayPath !== 'string' || !isAbsolute(overlayPath)) {
    throw new TypeError('safe-mode: overlayPath must be an absolute path');
  }
  const warnings = [];
  const parked = parkUserPatch({ profileDir });
  if (parked.warning) warnings.push(parked.warning);
  writeTextAtomic(overlayPath, buildOverlay({ skip, now, reason }));
  return { overlayPath, parked, warnings };
}

/**
 * The dsh flags that take a value and belong to the OUTER `dsh` command.
 *
 * Everything else on the argument list belongs to the booted profile's own app —
 * `--host`, `--port`, `--no-open` in this repository — and `bin.js` declares
 * `passThroughOptions()`, so the outer parser stops at the first positional/app
 * argument and hands the rest through untouched.
 */
const OUTER_VALUE_FLAGS = new Set(['--profile', '--from-default-profile', '--patch']);
const OUTER_BARE_FLAGS = new Set(['--dump-config', '--dump-config-schema', '--dump-default-config']);

/**
 * Where an outer `dsh` option has to go: before the first argument that belongs to
 * the booted app.
 *
 * MEASURED, NOT ASSUMED — AND IT COST A DEVICE RUN
 * -----------------------------------------------
 * PLAN-19 §3.5 said "append the overlay at the end, because overlays are applied
 * in order and the last one wins". The layering part is right; the POSITION is
 * wrong, and appending produced this on the simulator:
 *
 *     node| error: unknown option '--patch'
 *     dshportc: node_start returned 1
 *
 * `--patch` was appended after `--port 0`, which is an argument for the inner app;
 * `passThroughOptions()` had already stopped parsing outer options, so the flag
 * went to DSH's own service and was rejected there. Verified with `--dump-config`
 * on this machine: `--profile ios-sim --patch FILE --dump-config` prints the
 * composed tree, while `--profile ios-sim --no-open --dump-config --patch FILE`
 * hands `--patch` to the app and fails.
 *
 * So the overlay is inserted BEFORE the first non-outer argument. Order among the
 * outer options is preserved and the overlay still comes last among them, which is
 * what "after the profile layer" means: `cordis.yml` composes bundle →
 * `cordis.patch.yml` → `--patch` overlays, and that order is about layer
 * precedence, not about where the flag sits on the command line.
 *
 * @param {string[]} argv the arguments for DSH (`--profile`, `--host`, ...)
 * @param {{patch: string}} options
 * @returns {string[]} a new array; the input is not modified
 */
export function applyToArgv(argv, { patch } = {}) {
  if (!Array.isArray(argv) || argv.some((entry) => typeof entry !== 'string')) {
    throw new TypeError('safe-mode: argv must be an array of strings');
  }
  if (typeof patch !== 'string' || patch.length === 0 || !isAbsolute(patch)) {
    throw new TypeError('safe-mode: patch must be an absolute path');
  }
  const out = [...argv];
  if (out.includes(`--patch=${patch}`) || hasPatchPair(out, patch)) return out;

  const at = firstInnerArgument(out);
  out.splice(at, 0, '--patch', patch);
  return out;
}

/** Whether `--patch patch` already appears anywhere in `argv`. */
function hasPatchPair(argv, patch) {
  for (let i = 0; i < argv.length - 1; i += 1) {
    if (argv[i] === '--patch' && argv[i + 1] === patch) return true;
  }
  return false;
}

/**
 * Index of the first argument that belongs to the booted app.
 *
 * Walks the outer options from the front: a value flag consumes the next entry, a
 * known bare flag consumes itself, `--flag=value` consumes itself, and anything
 * else is either the first app argument or an outer flag this list does not know —
 * in both cases insertion before it is safe, because an unknown outer flag that
 * took no value would leave the overlay one position too early, which changes
 * precedence among overlays but never turns a valid command into an invalid one.
 *
 * @param {string[]} argv
 * @returns {number} an index in `0..argv.length`
 */
function firstInnerArgument(argv) {
  let i = 0;
  while (i < argv.length) {
    const entry = argv[i];
    if (OUTER_VALUE_FLAGS.has(entry)) {
      i += 2;
      continue;
    }
    if (OUTER_BARE_FLAGS.has(entry) || entry.startsWith('--') && entry.includes('=')) {
      i += 1;
      continue;
    }
    return i;
  }
  return argv.length;
}

/**
 * The one line the boot log and the status file carry when safe mode is on.
 *
 * @param {{mode: string, failures?: number, safeModeReason?: string|null}} decision
 * @returns {{active: boolean, mode: string, skipped: string[], reason: string}}
 */
export function describeDecision(decision) {
  const active = decision?.mode === 'safe';
  return {
    active,
    mode: String(decision?.mode ?? 'normal'),
    skipped: active ? DEFAULT_SKIP.map((entry) => entry.id) : [],
    reason: active ? String(decision?.safeModeReason ?? 'safe mode was requested') : '',
  };
}

/**
 * The skip list as plain data, for the report and for a `description.json`.
 *
 * @returns {{skipped: Array<{id: string, reason: string}>, kept: Array<{id: string, reason: string}>}}
 */
export function describeSkip() {
  return {
    skipped: DEFAULT_SKIP.map((entry) => ({ id: entry.id, reason: entry.reason })),
    kept: REQUIRED.map((entry) => ({ id: entry.id, reason: entry.reason })),
  };
}

function lstatOrNull(path) {
  try { return lstatSync(path); } catch { return null; }
}

function readIfExists(path) {
  try { return readFileSync(path, 'utf8'); } catch { return null; }
}
