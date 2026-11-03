// The credential fence for `dsh-fs-ios`: which host paths the model-facing file
// tools may never touch, and how a path is canonicalised before it is compared.
//
// WHY THIS EXISTS. The stock provider fences only MUTATIONS, and only by the
// session's sandbox mode; reads pass through untouched ("every mode permits
// reading"). On this port the mode is always `danger-full-access` (the only one
// the phone can deliver, see `dsh-sandbox-ios`), so `read`, `ls` and
// `read_image` could open anything the app container holds. Measured: a `read`
// of `$DSH_HOME/.credentials.yaml` returned the plaintext API keys. DSH_HOME is
// in the same container as the workspace, so "the App sandbox is the boundary"
// does not protect it from the agent at all.
//
// WHAT IS FENCED, AND WHY EACH ONE:
//
//   * `$DSH_HOME/.credentials.*` — the managed credential store
//     (`dsh-credentials-local`), plus its `<file>.lock` and `<file>.<hex>.tmp`
//     siblings from `dsh-atomic-write`, which hold the same bytes mid-write.
//   * `$DSH_HOME/.env` and `$DSH_HOME/.env.*` — the credential provider's last
//     fallback layer; whatever is there is a key by construction.
//   * `$DSH_HOME/storages/` — DSH's own state; provider configuration has been
//     seen there, which is why the diagnostics bundle refuses it as well
//     (`sim/diagnostics.mjs` FORBIDDEN_SEGMENTS).
//   * `<Application Support>/DSHPortC/` — the app's runtime state: the status
//     file, the boot log, `DSHPortC-session-url.txt` (a live bearer token), and
//     `boot/`, `diagnostics/`, `reset-staging/`, `reset-request.json`,
//     `reset-result.json` (RuntimePaths.swift). A model that can write
//     `boot/boot-request.json` or `reset-request.json` can steer the next
//     launch, so this is a write fence as much as a read one.
//   * `$DSHPORTE_BOOT_DIR` — normally inside the directory above; listed on its
//     own so a launch that moves it is still covered.
//
// Everything else — the workspace, `/tmp`, sessions, skills, the profile — is
// left exactly as before. The fence is a deny-list of named secrets, not an
// allow-list, because DSH itself reads profile and skill files through `ctx.fs`.
//
// HOW PATHS ARE COMPARED. Both sides are canonicalised with `realpath` first
// (so a symlink, a `..` through a symlinked directory, or `/var` vs
// `/private/var` all land on one spelling), then folded to NFC and lower case:
// APFS is case-insensitive and normalisation-insensitive by default, so
// `.CREDENTIALS.YAML` opens the same file and must be refused the same way. A
// hard link has no path relationship at all, so protected FILES are also
// compared by (dev, ino).
//
// This module is deliberately free of payload imports so it can be tested with
// plain `node --test`.

const { realpath, stat } = process.getBuiltinModule('node:fs/promises');
const { basename, dirname, isAbsolute, join, resolve, sep } = process.getBuiltinModule('node:path');

/** Errors that mean "this path, or a parent of it, does not exist". */
const MISSING = new Set(['ENOENT', 'ENOTDIR']);

/**
 * Fold one absolute path to the spelling used for comparison.
 * @param {string} path - absolute path.
 * @returns {string} NFC, lower-cased, without a trailing separator.
 */
export function comparable(path) {
  let folded = String(path).normalize('NFC').toLowerCase();
  while (folded.length > 1 && folded.endsWith(sep)) folded = folded.slice(0, -1);
  return folded;
}

/**
 * Canonicalise an absolute path: `realpath` of the path, or of its deepest
 * existing ancestor with the missing suffix appended.
 *
 * The suffix is joined lexically, which is safe: a component that does not
 * exist cannot be a symlink, so `..` inside it can only mean its lexical parent.
 *
 * @param {string} path - an absolute host path.
 * @returns {Promise<string>} the canonical spelling.
 */
export async function canonicalPath(path) {
  const absolute = isAbsolute(path) ? path : resolve(path);
  const missing = [];
  let current = absolute;
  while (true) {
    try {
      const real = await realpath(current);
      return missing.length === 0 ? real : resolve(join(real, ...missing));
    } catch (error) {
      if (!MISSING.has(error?.code)) throw error;
      const parent = dirname(current);
      if (parent === current) return resolve(absolute);
      missing.unshift(basename(current));
      current = parent;
    }
  }
}

/** Canonical spelling when it can be computed, else the lexical one. */
async function canonicalOrLexical(path) {
  try {
    return await canonicalPath(path);
  } catch {
    return resolve(path);
  }
}

/**
 * Whether a file name at the root of DSH_HOME is a credential file.
 * @param {string} name - the leaf name, already folded.
 * @returns {boolean} true for the credential store, its siblings, and `.env`.
 */
function isCredentialName(name) {
  return name === '.credentials' || name.startsWith('.credentials.')
    || name === '.env' || name.startsWith('.env.');
}

/**
 * Read the fence's roots from the environment the app publishes.
 *
 * Read on every call rather than once at import: the values are fixed for a
 * launch, but tests and the step acceptance harnesses import the same module
 * with different environments.
 *
 * @param {Record<string, string|undefined>} [env] - environment to read.
 * @returns {{dshHome: string, directories: string[], identityFiles: string[]}}
 *   the protected directories and the files compared by identity; all empty
 *   when DSH_HOME is not set (a desktop harness with no app around it).
 */
export function fenceRoots(env = process.env) {
  const dshHome = (env.DSH_HOME ?? '').trim();
  if (dshHome.length === 0 || !isAbsolute(dshHome)) return { dshHome: '', directories: [], identityFiles: [] };
  const home = resolve(dshHome);
  // RuntimePaths.supportDirectory is `Application Support/DSHPortC`, DSH_HOME is
  // `Application Support/DSH`: siblings, which is also how `sim/ios-app-entry.mjs`
  // derives it.
  const appSupport = join(dirname(home), 'DSHPortC');
  const directories = [appSupport, join(home, 'storages')];
  const bootDir = (env.DSHPORTE_BOOT_DIR ?? '').trim();
  if (bootDir.length > 0 && isAbsolute(bootDir)) directories.push(resolve(bootDir));
  const identityFiles = [
    join(home, '.credentials.yaml'),
    join(home, '.credentials.yml'),
    join(home, '.env'),
    join(appSupport, 'DSHPortC-session-url.txt'),
  ];
  return { dshHome: home, directories, identityFiles };
}

/**
 * Resolve the roots to every spelling a target may be compared against.
 * @param {ReturnType<typeof fenceRoots>} roots - the lexical roots.
 * @returns {Promise<{homes: string[], directories: string[], identities: Set<string>}>}
 *   folded lexical + canonical spellings, and `dev:ino` of the files that exist.
 */
async function preparedRoots(roots) {
  const both = async (path) => [...new Set([comparable(path), comparable(await canonicalOrLexical(path))])];
  const homes = roots.dshHome.length > 0 ? await both(roots.dshHome) : [];
  const directories = (await Promise.all(roots.directories.map(both))).flat();
  const identities = new Set();
  for (const file of roots.identityFiles) {
    try {
      const info = await stat(file);
      if (info.isFile()) identities.add(`${info.dev}:${info.ino}`);
    } catch {
      // Absent is the normal case for most of them; nothing to compare against.
    }
  }
  return { homes, directories, identities };
}

/** Whether a folded path is `root` or below it. */
function under(path, root) {
  return path === root || path.startsWith(root + sep);
}

/**
 * Decide whether one folded, canonical path is fenced.
 * @param {string} key - a `comparable()` spelling.
 * @param {{homes: string[], directories: string[]}} prepared - the folded roots.
 * @returns {boolean} true when the path is protected.
 */
function isFencedKey(key, prepared) {
  for (const root of prepared.directories) if (under(key, root)) return true;
  // A credential file is fenced at the root of DSH_HOME and anything below it
  // (`.credentials.yaml/` is not a directory, but a path *through* it must still
  // be refused rather than reported as ENOTDIR with the name confirmed).
  for (const home of prepared.homes) {
    if (!key.startsWith(home + sep)) continue;
    const first = key.slice(home.length + 1).split(sep)[0];
    if (isCredentialName(first)) return true;
  }
  return false;
}

/**
 * Build a checker for one call. Preparing the roots costs a few `realpath` and
 * `stat` calls, so a listing prepares once and checks every child with it.
 *
 * @param {Record<string, string|undefined>} [env] - environment to read.
 * @returns {Promise<(path: string, opts?: {fresh?: boolean}) => Promise<boolean>>}
 *   resolves true when `path` is fenced. With `fresh: false` the path is taken as
 *   already canonical (a `targetKey` the provider just produced) and only folded.
 */
export async function createFenceChecker(env = process.env) {
  const roots = fenceRoots(env);
  if (roots.dshHome.length === 0) return async () => false;
  const prepared = await preparedRoots(roots);
  return async (path, opts = {}) => {
    if (typeof path !== 'string' || path.length === 0) return false;
    const lexical = comparable(resolve(path));
    if (isFencedKey(lexical, prepared)) return true;
    if (opts.fresh !== false) {
      const canonical = comparable(await canonicalOrLexical(path));
      if (canonical !== lexical && isFencedKey(canonical, prepared)) return true;
    }
    if (prepared.identities.size > 0) {
      try {
        const info = await stat(path);
        if (info.isFile() && prepared.identities.has(`${info.dev}:${info.ino}`)) return true;
      } catch {
        // Missing or unreadable: no identity to compare, and the path checks above
        // already decided the spelling.
      }
    }
    return false;
  };
}

/**
 * The refusal text the model sees.
 *
 * It names the rule and says it is fixed, so the model neither retries with
 * another spelling nor asks for an approval that cannot change the answer.
 *
 * @param {string} displayPath - the path as the caller spelled it.
 * @returns {string} the error message.
 */
export function fenceMessage(displayPath) {
  return `cannot access "${displayPath}": access denied — this path is in the app's protected area`
    + ' (the DSH credential store and key files, or the app\'s own runtime state).'
    + ' File tools cannot read, write, list or search it under any mode, and an approval does not change that.'
    + ' 受保护路径：凭据、密钥或 App 运行状态文件，文件工具不允许访问。';
}
