// Keep sessions alive across an app-data-container change.
//
// WHY THIS EXISTS
// ---------------
// Installing over an existing app moves its data into a NEW container
// (`.../Containers/Data/Application/<uuid>`). DSH_HOME rides along, but two
// things in it still name the old container:
//
//   * `storages/**/*.json` holds the absolute workspace path. The Swift host
//     rewrites those before Node starts (NodeRunner.migrateStaleContainerPaths).
//   * every session log's HEADER records the project's absolute cwd, and that
//     header lives inside a Zstandard frame.
//
// DSH compares a log's header cwd against the folder the log sits in
// (`assertStoredIdentity`: "header id and cwd identify <path>"). A mismatch is
// reported as a corrupt log, and that one error stops the whole workspace
// registry from loading — so step 4B's fix moved every session into
// `sessions-quarantine/` and the user lost their history on every reinstall.
// Safe, but wrong: all the bytes are still there, only one field is stale.
//
// What this module does, before DSH is imported:
//
//   1. For each session log, decompress the FIRST frame (which by DSH's format
//      is exactly the header line), point its `cwd` at this container,
//      recompress that as one checksummed frame, and copy every following frame
//      through untouched. Temp file, fsync, rename over.
//   2. Move the session directory to the project directory its corrected cwd
//      implies, using DSH's own project-key algorithm (`projectKey` below is a
//      copy of that function, not an approximation: a mismatch here is exactly
//      the "corrupt session log" DSH reports).
//   3. On ANY per-session failure, move just that session into
//      `sessions-quarantine/<stamp>/` and say why in the log. One bad log must
//      not cost the others.
//   4. Sweep sessions quarantined by earlier launches: same rewrite, moved back.
//      A stamp folder is swept once (marker inside it), so a session that is
//      genuinely broken is not retried on every boot.
//   5. Prune the session ids that no longer have a log from `workspace.json`, so
//      the sidebar does not offer rows that cannot open.
//
// HOW THE CONTAINER IS FOUND
// --------------------------
// The rewrite does not need the OLD container path. A header cwd has the shape
// `<container>/Documents/workspace/...`, and both the device spelling
// (`/var/mobile/Containers/Data/Application/<uuid>`) and the simulator spelling
// (`/Users/.../CoreSimulator/Devices/<udid>/data/Containers/Data/Application/<uuid>`)
// share the marker `/Containers/Data/Application/<uuid>`. Replace everything up
// to and including that uuid with the current container and the cwd is right for
// any past container — including one from several reinstall generations ago,
// which no single "old prefix" could describe.
//
// WHY NODE AND NOT SWIFT: `node:zlib` in this runtime has `zstdCompressSync` and
// `zstdDecompressSync` (measured inside the iOS simulator: logs/step6/probe/*),
// so no native code and no third-party zstd is needed.
//
// Called from `sim/ios-app-entry.mjs` when DSHPORTE_SESSION_MIGRATE=1.

import {
  closeSync, existsSync, fsyncSync, mkdirSync, openSync, readdirSync, readFileSync,
  realpathSync, renameSync, rmSync, statSync, writeSync,
} from 'node:fs';
import { join } from 'node:path';
import zlib from 'node:zlib';

/** The one canonical spelling of a container path on this platform. */
export const CANONICAL_PREFIX = '/private/var/';

/**
 * The A/B fold direction, read ONCE at module load.
 *
 * `DSHPORTE_PATH_FOLD=friendly` restores the pre-step-9 behaviour
 * (`/private/var` -> `/var`). It exists so the report's "before" column can be
 * measured on the same build as its "after" column instead of being remembered
 * from an older one — the same device P-16's `DSHPORTE_RG_RESPELL` and step 8's
 * `DSHPORTE_RECOVERY_NOTE` use. Normal operation never sets it.
 */
const A_B_FOLD = (process.env.DSHPORTE_PATH_FOLD ?? '').toLowerCase();

/**
 * Give one absolute path the spelling DSH itself stores.
 *
 * WHY THIS IS ONE FUNCTION AND NOT THREE. Before step 9 the port held two
 * opposite opinions about how to write a container path:
 *
 *   * the Swift host publishes `realpath(3)` — `/private/var/mobile/…`
 *     (P-18, step 7) — into the environment and the profile, and
 *     `workspace-controller` string-joins the default workspace onto it, so
 *     every NEW session's `cwd` and every NEW registry record are `/private/var/…`;
 *   * `dedupeWorkspaceRegistry()` here, and `repairWorkspaceRegistry()` in
 *     Swift, folded `/private/var/` back to `/var/`.
 *
 * So the launch-time cleanup rewrote the registry to `/var/…` while the running
 * DSH kept producing `/private/var/…`. The phone shows the result: the same
 * folder listed twice (`deepseek-harness`, `deepseek-harness`), one row per
 * spelling, and selecting the `/var/…` row fails — `dsh-workspace` canonicalises
 * a workspace path and a session cwd through `fs.realpath` (`realpathNormalize`),
 * which answers `/private/var/…`, so no record matches it and
 * `attachSession` refuses ("its cwd resolves to '…'", surfaced to the user as
 * `session/workspace-attach-failed`). Sessions are also split across
 * `--var-…--` and `--private-var-…--` project directories.
 *
 * The fold therefore has to run in the SAME direction as the runtime that reads
 * it. `fs.realpath` is the last word: it is what `dsh-workspace` compares, and
 * Node answers `/private/var/…` on the device and on the simulator alike. So the
 * canonical form is `realpath`, and every other spelling folds INTO it.
 *
 * What this resolves, in order:
 *
 *   1. `/var` and `/var/…` — the device's documented `com.apple.rootless` alias
 *      — prefixed to `/private`. Done as a string rule, not through `realpath`,
 *      because a workspace record may name a folder that no longer exists and
 *      the result must still be the spelling Node would produce for it.
 *   2. anything else — the real `realpath(3)` answer, so other symlinked
 *      ancestors (`/tmp` -> `/private/tmp`, the simulator's own TMPDIR aliases)
 *      collapse to the string DSH compares against.
 *   3. a path that does not exist — survived as its (already de-`/var`ed)
 *      spelling rather than thrown, for the same reason as (1).
 *
 * Only paths under `/var` reach rule (1); `/Users/...` (the simulator's own
 * container root) goes straight to `realpath`, which is what makes the same code
 * correct on both platforms.
 *
 * @param {string} path - an absolute path in any of the spellings seen in the wild.
 * @returns {string} the canonical spelling, or the input when it is not a usable string.
 */
export function canonicalPath(path) {
  if (typeof path !== 'string' || path.length === 0) return path;
  if (A_B_FOLD === 'friendly') {
    return path.startsWith('/private/var/') ? path.slice('/private'.length) : path;
  }
  const folded = path === '/var' ? '/private/var'
    : path.startsWith('/var/') ? `/private${path}`
      : path;
  try { return realpathSync(folded); } catch { return folded; }
}

/**
 * Whether `path` already carries the canonical spelling.
 *
 * Separate from {@link canonicalPath} because the callers that only rewrite text
 * need to know whether there is anything to rewrite BEFORE they touch a file: a
 * migration that rewrites a file to the bytes it already had makes the next
 * launch do the same work again for no reason.
 *
 * @param {string} path - an absolute path.
 * @returns {boolean} true when the path needs no folding.
 */
export function isCanonicalPath(path) {
  return typeof path !== 'string' || canonicalPath(path) === path;
}

const ZSTD_MAGIC = 0xfd2fb528;
/** The one path segment every app data container has, on device and simulator. */
const CONTAINER_MARKER = '/Containers/Data/Application/';
// The marker, tolerating JSON-escaped slashes: `JSONSerialization` on the Swift
// side wrote `\/Users\/...\/Containers\/...`, and DSH_HOME on a phone that went
// through step 4B's Swift rewrite still contains that spelling. `JSON.stringify`
// (what DSH and this module write) does not escape, so both forms occur.
const CONTAINER_RE = /\\?\/Containers\\?\/Data\\?\/Application\\?\/[0-9A-Fa-f][0-9A-Fa-f-]{35}/;
// The same pattern as a global regex for whole-document replacement. Separate
// objects because a `g` regex carries `lastIndex` between uses.
const CONTAINER_RE_G = new RegExp(CONTAINER_RE.source, 'g');

/** DSH's own path sanitizer for the per-project directory name. */
// Mirrors `projectKey()` in @deepseek-ai/dsh-session-persistence-jsonl/lib/
// index.js: separators collapse to one `-`, every other unsafe code unit becomes
// `~XXXX`, the result is wrapped in `--` and bounded to 251 characters.
export function projectKey(cwd) {
  if (cwd.length === 0) throw new Error('cannot encode an empty project path');
  let readable = '';
  let separatorRun = false;
  for (let i = 0; i < cwd.length; i += 1) {
    const code = cwd.charCodeAt(i);
    const ch = String.fromCharCode(code);
    if (ch === '/' || ch === '\\' || ch === ':') {
      if (!separatorRun) readable += '-';
      separatorRun = true;
    } else if (ch !== '~' && /^[A-Za-z0-9._-]$/.test(ch)) {
      readable += ch;
      separatorRun = false;
    } else {
      readable += '~' + code.toString(16).toUpperCase().padStart(4, '0');
      separatorRun = false;
    }
  }
  return `--${(readable.replace(/^-+/, '') || 'root').slice(0, 251)}--`;
}

/**
 * The rewrite a session header's `cwd` gets on every launch.
 *
 * `respellContainer` answers only the container question ("does this path name
 * the live app container?"), and a header can be entirely right about the container
 * while being wrong about the SPELLING of a subdirectory inside it. That is not a
 * hypothetical: a folder reached through a symlinked ancestor — the `/var` vs
 * `/private/var` pair on a device, any alias on any platform — yields two
 * `projectKey()` values for one directory, which is the split the phone showed.
 *
 * DSH's identity check is `generationLogPath(root, meta.cwd, meta.id)` compared
 * against the file's real location (`assertStoredIdentity`), i.e. `projectKey(cwd)`
 * has to name the folder the log actually sits in. So the header must end up
 * canonical whether or not the container changed, and the migration pass below
 * then moves the directory to match.
 *
 * @param {string} path - the header's `cwd`.
 * @param {string} current - this launch's container root, in any spelling.
 * @returns {string|undefined} the corrected cwd, or undefined when none is needed.
 */
export function canonicalHeaderCwd(path, current) {
  const respelled = respellContainer(path, current);
  if (typeof respelled === 'string') return respelled;
  if (typeof path !== 'string' || path.length === 0) return undefined;
  const folded = canonicalPath(path);
  return folded === path ? undefined : folded;
}

/**
 * Point one absolute path at `current` AND give it the canonical spelling.
 *
 * Two jobs, deliberately in one function: a session header has to name the live
 * container (or DSH reports a corrupt log) *and* has to spell it the way
 * `fs.realpath` will, because that result is what the directory name
 * (`projectKey(cwd)`) is derived from and what `attachSession` compares against.
 * Doing only the container part is what produced the phone's two sets of project
 * directories, `--var-…--` and `--private-var-…--`, for one folder.
 *
 * `current` is canonicalised here too, not trusted as given: this module's callers
 * pass whatever the Swift host published, and if that ever arrives as `/var/…`
 * (an older build, a hand-run harness) then rewriting headers "to current" would
 * write the wrong spelling back.
 *
 * @param {string} path - an absolute path from a session header.
 * @param {string} current - this launch's container root, in any spelling.
 * @returns {string|undefined} the corrected path, or undefined when it is already
 *   both in this container and canonically spelled.
 */
export function respellContainer(path, current) {
  if (typeof path !== 'string' || path.length === 0) return undefined;
  const root = canonicalPath(current);
  const base = path.startsWith(root + '/') ? path
    : (() => {
      const match = CONTAINER_RE.exec(path);
      // No container marker and not under this container: nothing to point anywhere.
      if (match === null) return undefined;
      return root + path.slice(match.index + match[0].length);
    })();
  if (base === undefined) return undefined;
  const respelled = canonicalPath(base);
  return respelled === path ? undefined : respelled;
}

/**
 * Point every app-container path in `text` at `current`.
 *
 * WHY THIS IS NOT A SIMPLE `String.replace` OF THE MARKER. The marker is
 * `/Containers/Data/Application/<uuid>`, and what must be replaced is the whole
 * path prefix in front of it — the device writes `/var/mobile/Containers/...`
 * while the simulator writes
 * `/Users/<user>/Library/Developer/CoreSimulator/Devices/<udid>/data/Containers/...`.
 * Replacing only the marker leaves the old prefix in place (the first version of
 * this function produced `/a/b/Containers/...`, and after that it replaced its own
 * output on the next run). So: find the marker, walk back to where the path token
 * starts, and substitute `current` for everything up to and including the uuid.
 *
 * A token start is a quote, whitespace, or one of `,:=([{`. Slashes may be
 * JSON-escaped (`\/`), because `JSONSerialization` on the Swift side used to write
 * them that way.
 *
 * The substituted prefix is {@link canonicalPath}`(current)`, not `current`
 * verbatim: see step 9's note on {@link dedupeWorkspaceRegistry}. Hosts that
 * published `/var/…` (anything built before step 7) would otherwise keep writing
 * the spelling the runtime cannot find again.
 *
 * @param {string} text any text containing zero or more container paths
 * @param {string} current this launch's container root
 * @returns {string} the text with every container path rooted at the canonical `current`
 */
export function respellAll(text, current) {
  const root = canonicalPath(current);
  let out = '';
  let cursor = 0;
  CONTAINER_RE_G.lastIndex = 0;
  for (;;) {
    const match = CONTAINER_RE_G.exec(text);
    if (match === null) break;
    const uuidEnd = match.index + match[0].length;
    // Walk back over the prefix: path characters and escaped slashes only.
    let start = match.index;
    while (start > cursor) {
      const ch = text[start - 1];
      // An escaped slash is two characters (`\\` then `/`), so step back over
      // both. JSON written by `JSONSerialization` uses that spelling, and a
      // rewrite that ignores it would leave half a prefix behind.
      if (ch === '/' && start > cursor + 1 && text[start - 2] === '\\') { start -= 2; continue; }
      if (ch === '/' || /[A-Za-z0-9._~+-]/.test(ch)) { start -= 1; continue; }
      break;
    }
    const uuid = match[0].slice(match[0].lastIndexOf('/') + 1).replace(/^\\/, '');
    const alreadyCurrent = text.slice(start, uuidEnd) === `${root}/Containers/Data/Application/${uuid}`;
    if (alreadyCurrent) { out += text.slice(cursor, uuidEnd); cursor = uuidEnd; continue; }
    out += text.slice(cursor, start) + root;
    cursor = uuidEnd;
  }
  out += text.slice(cursor);
  return out;
}

/**
 * The byte ranges of the Zstandard frames in `buffer`, stopping after `max`.
 *
 * A local copy of DSH's `scanZstdFrames` (same field decode, same reserved-bit
 * refusal) because the module that owns it is not importable from here: it is an
 * internal function of the persistence package, not an export. The ~40 lines are
 * the price of not patching DSH. `tornStart` marks an incomplete final frame.
 */
export function scanFrames(buffer, max = Number.POSITIVE_INFINITY) {
  const frames = [];
  let offset = 0;
  while (offset < buffer.length) {
    const start = offset;
    if (buffer.length - offset < 4) return { frames, tornStart: start };
    if (buffer.readUInt32LE(offset) !== ZSTD_MAGIC) throw new Error(`invalid frame magic at byte ${offset}`);
    offset += 4;
    if (offset === buffer.length) return { frames, tornStart: start };
    const descriptor = buffer.readUInt8(offset);
    offset += 1;
    if ((descriptor & 24) !== 0) throw new Error(`reserved frame-header bit at byte ${offset - 1}`);
    const contentSizeFlag = descriptor >>> 6;
    const singleSegment = (descriptor & 32) !== 0;
    const checksum = (descriptor & 4) !== 0;
    const dictionaryFlag = descriptor & 3;
    const dictionaryBytes = dictionaryFlag === 3 ? 4 : dictionaryFlag;
    const contentSizeBytes = contentSizeFlag === 0 ? (singleSegment ? 1 : 0) : 1 << contentSizeFlag;
    const remaining = (singleSegment ? 0 : 1) + dictionaryBytes + contentSizeBytes;
    if (buffer.length - offset < remaining) return { frames, tornStart: start };
    offset += remaining;
    for (;;) {
      if (buffer.length - offset < 3) return { frames, tornStart: start };
      const blockHeader = buffer.readUIntLE(offset, 3);
      offset += 3;
      const lastBlock = (blockHeader & 1) !== 0;
      const blockType = (blockHeader >>> 1) & 3;
      const blockSize = blockHeader >>> 3;
      if (blockType === 3) throw new Error(`reserved block type at byte ${offset - 3}`);
      const payload = blockType === 1 ? 1 : blockSize;
      if (buffer.length - offset < payload) return { frames, tornStart: start };
      offset += payload;
      if (lastBlock) break;
    }
    if (checksum) {
      if (buffer.length - offset < 4) return { frames, tornStart: start };
      offset += 4;
    }
    frames.push({ start, end: offset });
    if (frames.length === max) return { frames };
  }
  return { frames };
}

/** One checksummed frame holding the header line, in the shape DSH writes. */
function compressHeaderFrame(text) {
  return zlib.zstdCompressSync(Buffer.from(text, 'utf8'), {
    params: { [zlib.constants.ZSTD_c_checksumFlag]: 1 },
  });
}

/**
 * Rewrite one session log's header cwd in place.
 *
 * @param path absolute path to `session.vN.jsonl.zstd`
 * @param rewrite called with the parsed header; returns the new cwd or undefined
 * @returns {{status:'rewritten'|'unchanged', id?:string, from?:string, to?:string}}
 */
export function rewriteHeaderCwd(path, rewrite) {
  const raw = readFileSync(path);
  const { frames } = scanFrames(raw, 1);
  if (frames.length === 0) throw new Error('empty or header-less session log');
  const first = frames[0];
  const plaintext = zlib.zstdDecompressSync(raw.subarray(first.start, first.end));
  // DSH asserts the same thing (`assertZstdHeaderFrame`): the first frame is
  // exactly one newline-terminated header line. Refuse rather than "repair".
  if (plaintext.length === 0 || plaintext.indexOf(0x0a) !== plaintext.length - 1) {
    throw new Error('first frame is not exactly one header line');
  }
  let header;
  try {
    header = JSON.parse(plaintext.subarray(0, -1).toString('utf8'));
  } catch {
    throw new Error('header line is not valid JSON');
  }
  if (typeof header !== 'object' || header === null || Array.isArray(header)) {
    throw new Error('header line is not a JSON object');
  }
  const next = rewrite(header);
  if (next === undefined || next === header.cwd) {
    return { status: 'unchanged', id: header.id, cwd: header.cwd };
  }
  const text = JSON.stringify({ ...header, cwd: next }) + '\n';
  const frame = compressHeaderFrame(text);

  // Verify before publishing: the frame being prepended must decode to exactly
  // the header intended, and the remainder must still scan as frames.
  if (!zlib.zstdDecompressSync(frame).equals(Buffer.from(text, 'utf8'))) {
    throw new Error('recompressed header frame does not round-trip');
  }
  const rest = raw.subarray(first.end);
  const rebuilt = Buffer.concat([frame, rest]);
  scanFrames(rebuilt);
  if (rest.length > 0 && scanFrames(rest, 1).frames.length === 0) {
    throw new Error('event frames no longer scan after the header');
  }

  const temp = `${path}.step6.${process.pid}.tmp`;
  const fd = openSync(temp, 'w');
  try {
    writeSync(fd, rebuilt);
    fsyncSync(fd);
  } finally {
    closeSync(fd);
  }
  renameSync(temp, path);
  try {
    const dir = openSync(join(path, '..'), 'r');
    try { fsyncSync(dir); } finally { closeSync(dir); }
  } catch { /* best effort: the file itself is already durable */ }

  return { status: 'rewritten', id: header.id, from: header.cwd, to: next, bytes: rebuilt.length };
}

/** The generation log inside one session directory, highest version first. */
function findGenerationLog(dir) {
  const names = readdirSync(dir).filter((name) => /^session(\.v\d+)?\.jsonl(\.zstd)?$/.test(name));
  if (names.length === 0) return undefined;
  const version = (n) => (n.match(/\.v(\d+)\.jsonl/) ? Number(n.match(/\.v(\d+)\.jsonl/)[1]) : 0);
  names.sort((a, b) => version(b) - version(a) || a.localeCompare(b));
  return join(dir, names[0]);
}

function isDirectory(path) {
  try { return statSync(path).isDirectory(); } catch { return false; }
}

function stamp() {
  return new Date().toISOString().replace(/[:.]/g, '');
}

function writeMarker(path, body) {
  try {
    const fd = openSync(path, 'w');
    try { writeSync(fd, body + '\n'); fsyncSync(fd); } finally { closeSync(fd); }
  } catch { /* a marker is an optimisation, not a correctness requirement */ }
}

/**
 * Migrate every session under `sessionsRoot` to `current`.
 *
 * @param {object} options
 * @param {string} options.sessionsRoot absolute `.../DSH/sessions`
 * @param {string} options.quarantineRoot absolute `.../DSH/sessions-quarantine`
 * @param {string} options.current this launch's container root
 * @param {(line:string)=>void} [options.log]
 * @returns {object} counts, for the boot log and the report
 */
export function migrateSessions({ sessionsRoot, quarantineRoot, current, log = () => {} }) {
  const result = { rewritten: 0, moved: 0, quarantined: 0, unchanged: 0, failed: [], errors: [], kept: [] };
  const rewrite = (header) => canonicalHeaderCwd(header.cwd, current);
  // One stamp for the whole run, so every session isolated in this pass lands
  // together and can be swept as one batch later.
  const runStamp = stamp();

  let projects = [];
  try {
    projects = readdirSync(sessionsRoot, { withFileTypes: true }).filter((e) => e.isDirectory()).map((e) => e.name);
  } catch (error) {
    if (error && error.code === 'ENOENT') return result;
    throw error;
  }

  for (const project of projects) {
    const projectDir = join(sessionsRoot, project);
    let sessionDirs = [];
    try {
      sessionDirs = readdirSync(projectDir, { withFileTypes: true }).filter((e) => e.isDirectory()).map((e) => e.name);
    } catch (error) {
      result.errors.push(`listing ${project}: ${error && error.message}`);
      continue;
    }
    for (const session of sessionDirs) {
      const dir = join(projectDir, session);
      try {
        const logPath = findGenerationLog(dir);
        if (logPath === undefined) throw new Error('no session log in the directory');
        const outcome = rewriteHeaderCwd(logPath, rewrite);
        const cwd = outcome.status === 'rewritten' ? outcome.to : outcome.cwd;
        if (typeof cwd !== 'string') throw new Error('header carries no cwd');
        result.rewritten += outcome.status === 'rewritten' ? 1 : 0;
        result.unchanged += outcome.status === 'rewritten' ? 0 : 1;
        // The directory name is the project key of cwd, so it has to follow.
        const wanted = projectKey(cwd);
        if (wanted !== project) {
          const targetParent = join(sessionsRoot, wanted);
          mkdirSync(targetParent, { recursive: true });
          const target = join(targetParent, session);
          if (existsSync(target)) throw new Error(`a session with this id is already at ${target}`);
          renameSync(dir, target);
          result.moved += 1;
        }
      } catch (error) {
        const reason = `${session}: ${error && error.message ? error.message : String(error)}`;
        result.failed.push(reason);
        log(`isolating ${reason}`);
        // Only this one. Everything else in this project directory stays.
        try {
          const destDir = join(quarantineRoot, runStamp, project);
          mkdirSync(destDir, { recursive: true });
          renameSync(dir, join(destDir, session));
          result.quarantined += 1;
        } catch (moveError) {
          result.errors.push(`could not isolate ${session}: ${moveError && moveError.message}`);
        }
      }
    }
    try {
      if (readdirSync(projectDir).length === 0) rmSync(projectDir, { recursive: true, force: true });
    } catch { /* a directory still in use stays */ }
  }
  return result;
}

/**
 * Bring sessions quarantined by an earlier launch back into service.
 *
 * Each stamp directory holds the project directories as they were, so the same
 * header rewrite applies and the session then moves to the project directory its
 * corrected cwd implies. `session_projcache` is DSH's projection cache, not a
 * session: it is rebuilt from the logs, so it is left where it is rather than
 * moved back and risked against a header it does not describe.
 */
export function sweepQuarantine({ sessionsRoot, quarantineRoot, current, log = () => {} }) {
  const result = { recovered: 0, left: 0, stamps: 0, skippedStamps: 0, failed: [], cwdMissing: [] };
  let stamps = [];
  try {
    stamps = readdirSync(quarantineRoot, { withFileTypes: true })
      .filter((e) => e.isDirectory() && !e.name.startsWith('.'))
      .map((e) => e.name)
      .sort();
  } catch (error) {
    if (error && error.code === 'ENOENT') { mkdirSync(quarantineRoot, { recursive: true }); return result; }
    throw error;
  }
  const rewrite = (header) => canonicalHeaderCwd(header.cwd, current);
  for (const stampName of stamps) {
    const stampDir = join(quarantineRoot, stampName);
    if (existsSync(join(stampDir, '.swept'))) { result.skippedStamps += 1; continue; }
    result.stamps += 1;
    let projects = [];
    try {
      projects = readdirSync(stampDir, { withFileTypes: true }).filter((e) => e.isDirectory()).map((e) => e.name);
    } catch { continue; }
    for (const project of projects) {
      if (project === 'session_projcache') continue;
      const projectDir = join(stampDir, project);
      let sessions = [];
      try {
        sessions = readdirSync(projectDir, { withFileTypes: true }).filter((e) => e.isDirectory()).map((e) => e.name);
      } catch { continue; }
      for (const session of sessions) {
        const dir = join(projectDir, session);
        try {
          const logPath = findGenerationLog(dir);
          if (logPath === undefined) throw new Error('no session log in the quarantined directory');
          const outcome = rewriteHeaderCwd(logPath, rewrite);
          const cwd = outcome.status === 'rewritten' ? outcome.to : outcome.cwd;
          if (typeof cwd !== 'string') throw new Error('quarantined header carries no cwd');
          // A restored session goes back under the project directory its cwd
          // names. When that directory is gone — the workspace was deleted, or the
          // app was reinstalled fresh and recreated it under a new container —
          // recreate it: the header already points there, and a session whose cwd
          // exists is one DSH can open. The alternative (leave it quarantined) is
          // the data loss this module exists to prevent.
          if (!isDirectory(cwd)) {
            mkdirSync(cwd, { recursive: true });
            result.cwdMissing.push(cwd);
            log(`recreated missing project directory for a restored session: ${cwd}`);
          }
          const targetParent = join(sessionsRoot, projectKey(cwd));
          mkdirSync(targetParent, { recursive: true });
          const target = join(targetParent, session);
          if (existsSync(target)) throw new Error(`a session with this id is already at ${target}`);
          renameSync(dir, target);
          result.recovered += 1;
        } catch (error) {
          const reason = `${stampName}/${session}: ${error && error.message ? error.message : String(error)}`;
          result.failed.push(reason);
          result.left += 1;
          log(`left in quarantine — ${reason}`);
        }
      }
      try { if (readdirSync(projectDir).length === 0) rmSync(projectDir, { recursive: true, force: true }); } catch { /* stays */ }
    }
    writeMarker(join(stampDir, '.swept'), new Date().toISOString());
  }
  return result;
}

/** Every session id that still has a generation log under `sessionsRoot`. */
export function liveSessionIds(sessionsRoot) {
  const ids = new Set();
  let projects = [];
  try {
    projects = readdirSync(sessionsRoot, { withFileTypes: true }).filter((e) => e.isDirectory()).map((e) => e.name);
  } catch { return ids; }
  for (const project of projects) {
    let sessions = [];
    try {
      sessions = readdirSync(join(sessionsRoot, project), { withFileTypes: true })
        .filter((e) => e.isDirectory()).map((e) => e.name);
    } catch { continue; }
    for (const session of sessions) {
      try { if (findGenerationLog(join(sessionsRoot, project, session)) !== undefined) ids.add(session); } catch { /* skip */ }
    }
  }
  return ids;
}

/**
 * Point every stored absolute path in `storages/**\/*.json` at `current`.
 *
 * The same rule as a session header's cwd (`respellContainer`), applied to the
 * JSON files DSH keeps its own state in. This lives here rather than in Swift for
 * a specific reason: the first version of step 6 did it in Swift with
 * `/(?:private/)?var/mobile/Containers/Data/Application/<uuid>/` — the device
 * spelling only — so on the simulator it matched nothing and reported success,
 * and the acceptance then read a registry that still named the dead container.
 * One rule, one implementation, exercised on both platforms.
 *
 * A file is rewritten only when its text actually changes, through temp+rename,
 * and the result must still parse: DSH refuses to boot on unparsable state, so a
 * rewrite that broke a file would be worse than the stale path it repaired.
 *
 * @param {object} options
 * @param {string} options.storagesRoot absolute `.../DSH/storages`
 * @param {string} options.current this launch's container root
 * @param {(line:string)=>void} [options.log]
 * @returns {{rewritten:number, files:string[], errors:string[]}}
 */
export function rewriteStoragePaths({ storagesRoot, current, log = () => {} }) {
  const result = { rewritten: 0, files: [], errors: [] };
  const walk = (dir) => {
    let entries = [];
    try { entries = readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const entry of entries) {
      const full = join(dir, entry.name);
      if (entry.isDirectory()) { walk(full); continue; }
      if (!entry.name.endsWith('.json')) continue;
      let text;
      try { text = readFileSync(full, 'utf8'); } catch { continue; }
      const updated = respellAll(text, current);
      if (updated === text) continue;
      try {
        JSON.parse(updated);
      } catch (error) {
        result.errors.push(`${entry.name}: rewrite produced invalid JSON (${error && error.message})`);
        continue;
      }
      const temp = `${full}.step6.${process.pid}.tmp`;
      const fd = openSync(temp, 'w');
      try { writeSync(fd, updated); fsyncSync(fd); } finally { closeSync(fd); }
      renameSync(temp, full);
      result.rewritten += 1;
      result.files.push(entry.name);
      log(`rewrote container paths in ${entry.name}`);
    }
  };
  walk(storagesRoot);
  return result;
}

/**
 * Drop ids that no longer have a log from `storages/workspace.json`.
 *
 * A quarantined session leaves its id in the workspace record, and the sidebar
 * would then offer a row that cannot open. DSH tolerates a missing id (it counts
 * it as a candidate), so this is about not showing a dead row, not about
 * correctness. Only the three id lists change; every other field is preserved,
 * and a file with nothing to prune is not rewritten at all.
 */
export function pruneWorkspaceRegistry({ storagesRoot, liveIds, log = () => {} }) {
  const path = join(storagesRoot, 'workspace.json');
  let text;
  try { text = readFileSync(path, 'utf8'); } catch { return { pruned: 0, changed: false }; }
  let root;
  try { root = JSON.parse(text); } catch { return { pruned: 0, changed: false, error: 'workspace.json is not valid JSON' }; }
  const keep = (id) => liveIds.has(id);
  let pruned = 0;
  const filter = (list) => {
    if (!Array.isArray(list)) return list;
    const kept = list.filter(keep);
    pruned += list.length - kept.length;
    return kept;
  };
  if (root.global !== undefined) {
    root.global.archivedSessionIds = filter(root.global.archivedSessionIds);
    root.global.pinnedSessionIds = filter(root.global.pinnedSessionIds);
  }
  if (root.tables !== undefined && root.tables.workspaces !== undefined) {
    for (const id of Object.keys(root.tables.workspaces)) {
      const entry = root.tables.workspaces[id];
      if (entry && Array.isArray(entry.sessionIds)) entry.sessionIds = filter(entry.sessionIds);
    }
  }
  if (pruned === 0) return { pruned: 0, changed: false };
  const out = JSON.stringify(root, null, 2);
  const temp = `${path}.step6.${process.pid}.tmp`;
  const fd = openSync(temp, 'w');
  try { writeSync(fd, out); fsyncSync(fd); } finally { closeSync(fd); }
  renameSync(temp, path);
  log(`pruned ${pruned} session id(s) with no log from workspace.json`);
  return { pruned, changed: true };
}

/**
 * Merge workspace records that name the same folder, under the ONE canonical
 * spelling the runtime itself uses.
 *
 * Runs LAST, after every path rewrite and after the quarantine sweep, because
 * those are what create the collision: the same folder is `/var/mobile/...` in
 * one record and `/private/var/mobile/...` in another (the second is the real
 * path behind the first), and once the rewrite gives them one spelling DSH sees
 * two workspaces claiming one path and refuses the whole registry
 * ("workspace domain is inconsistent"), which leaves the session and workspace
 * controllers pending. Step 4B hit this after its own migration; step 6's
 * migration + restore hit it again because the Swift-side repair
 * (`repairWorkspaceRegistry`, P-10b) runs BEFORE this module and so never sees
 * what this module writes.
 *
 * THE DIRECTION CHANGED IN STEP 9, AND THAT IS THE WHOLE FIX. This function used
 * to fold `/private/var/` to `/var/` — the OPPOSITE of what `dsh-workspace`
 * produces, because it canonicalises through `fs.realpath` (and step 7 made the
 * Swift host publish `realpath(3)` for the same reason). The consequence on the
 * phone: launch 1 rewrote the records to `/var/…`, the running DSH then created
 * new records and new session cwds as `/private/var/…`, and the dropdown showed
 * both spellings of one folder. Selecting the `/var/…` row failed with
 * `session/workspace-attach-failed`, because `attachSession` realpaths the
 * session cwd, gets `/private/var/…`, and compares it to the stored `/var/…`
 * path. Every record is now folded to {@link canonicalPath}, so a launch can
 * never hand the runtime a path it will immediately disagree with.
 *
 * The merge itself: for each canonical path keep the oldest record (createdAt,
 * then id), union the session ids into it, drop the others, and fix
 * `global.workspaceIds` / `defaultWorkspaceId`. A dropped record that was the
 * default hands that role to its keeper, so the dropdown keeps a default entry
 * instead of silently losing one.
 *
 * @param {object} options
 * @param {string} options.storagesRoot - absolute `.../DSH/storages`.
 * @param {(line: string) => void} [options.log] - one line per notable decision.
 * @returns {{merged: number, folded: number, changed: boolean}} counts.
 */
export function dedupeWorkspaceRegistry({ storagesRoot, log = () => {} }) {
  const path = join(storagesRoot, 'workspace.json');
  let root;
  try { root = JSON.parse(readFileSync(path, 'utf8')); } catch { return { merged: 0, folded: 0, changed: false }; }
  const workspaces = root?.tables?.workspaces;
  if (workspaces === undefined || workspaces === null) return { merged: 0, folded: 0, changed: false };
  let changed = false;
  let folded = 0;
  const order = Object.keys(workspaces).sort((a, b) => {
    const ca = String(workspaces[a]?.createdAt ?? ''); const cb = String(workspaces[b]?.createdAt ?? '');
    return ca === cb ? (a < b ? -1 : 1) : (ca < cb ? -1 : 1);
  });
  const keeperFor = new Map();
  const dropped = new Map();
  for (const id of order) {
    const entry = workspaces[id];
    if (!entry || typeof entry.path !== 'string') continue;
    const normal = canonicalPath(entry.path);
    if (normal !== entry.path) { entry.path = normal; changed = true; folded += 1; }
    const keeper = keeperFor.get(normal);
    if (keeper === undefined) { keeperFor.set(normal, id); continue; }
    const kept = workspaces[keeper];
    const ids = Array.isArray(kept.sessionIds) ? kept.sessionIds : [];
    for (const sid of Array.isArray(entry.sessionIds) ? entry.sessionIds : []) if (!ids.includes(sid)) ids.push(sid);
    kept.sessionIds = ids;
    // The oldest record keeps its own createdAt/updatedAt/title; the survivor of a
    // merge is the one whose identity the user already knows. Only the session
    // list and the default role are transferred.
    delete workspaces[id];
    dropped.set(id, keeper);
    changed = true;
  }
  if (!changed) return { merged: 0, folded: 0, changed: false };
  if (root.global !== undefined && root.global !== null) {
    if (Array.isArray(root.global.workspaceIds)) {
      const seen = new Set();
      root.global.workspaceIds = root.global.workspaceIds.map((id) => dropped.get(id) ?? id).filter((id) => !seen.has(id) && seen.add(id));
    }
    if (dropped.has(root.global.defaultWorkspaceId)) root.global.defaultWorkspaceId = dropped.get(root.global.defaultWorkspaceId);
  }
  const out = JSON.stringify(root, null, 2);
  const temp = `${path}.step6.${process.pid}.tmp`;
  const fd = openSync(temp, 'w');
  try { writeSync(fd, out); fsyncSync(fd); } finally { closeSync(fd); }
  renameSync(temp, path);
  log(`workspace registry: folded ${folded} path(s), merged ${dropped.size} duplicate record(s)`);
  return { merged: dropped.size, folded, changed: true };
}

/**
 * Entry point used by `ios-app-entry.mjs`.
 *
 * DSHPORTE_SESSION_MIGRATE carries the current container root. Any failure here
 * is reported and swallowed: a migration that cannot run must leave DSH in the
 * state it was in, not stop it booting. The Swift host has already rewritten the
 * storage paths, so the app is no worse off than before this module existed.
 */
export function runFromEnvironment() {
  const current = process.env.DSHPORTE_SESSION_MIGRATE;
  if (!current || current === '') return;
  const home = process.env.DSH_HOME;
  if (!home) { console.log('session-migrate: SKIP no DSH_HOME'); return; }
  const sessionsRoot = join(home, 'sessions');
  const quarantineRoot = join(home, 'sessions-quarantine');
  const emit = (line) => console.log(`session-migrate: ${line}`);
  const summary = {};
  // Record what the migration actually saw before touching anything. A run that
  // finds nothing is indistinguishable from a run whose root was wrong, and this
  // is the only place that can tell those apart after the fact.
  try {
    summary.observed = {
      sessionsRoot,
      dshHome: home,
      projectDirs: readdirSync(sessionsRoot).filter((n) => !n.startsWith('.')),
    };
    emit(`inspecting ${sessionsRoot}: ${summary.observed.projectDirs.length} project dir(s)`);
  } catch (error) {
    summary.observed = { sessionsRoot, dshHome: home, error: String(error && error.message) };
    emit(`could not inspect ${sessionsRoot}: ${error && error.message}`);
  }
  try {
    // Storage paths first: DSH walks the workspace path during import, so the
    // session pass below is not the only thing that has to be right before Node
    // touches the tree.
    summary.storages = rewriteStoragePaths({ storagesRoot: join(home, 'storages'), current, log: emit });

    summary.migrated = migrateSessions({ sessionsRoot, quarantineRoot, current, log: emit });
    emit(`container ${current}: rewrote ${summary.migrated.rewritten} log(s), moved ${summary.migrated.moved} folder(s), `
      + `${summary.migrated.unchanged} already current, isolated ${summary.migrated.quarantined}`
      + (summary.migrated.failed.length > 0 ? ` [${summary.migrated.failed.join('; ')}]` : ''));

    summary.recovered = sweepQuarantine({ sessionsRoot, quarantineRoot, current, log: emit });
    emit(`quarantine sweep: ${summary.recovered.recovered} restored, ${summary.recovered.left} left in place, `
      + `${summary.recovered.stamps} stamp folder(s) swept, ${summary.recovered.skippedStamps} already swept`);

    summary.pruned = pruneWorkspaceRegistry({
      storagesRoot: join(home, 'storages'), liveIds: liveSessionIds(sessionsRoot), log: emit,
    });

    summary.deduped = dedupeWorkspaceRegistry({ storagesRoot: join(home, 'storages'), log: emit });

    const fd = openSync(join(home, 'DSHPortE-session-migrate.json'), 'w');
    try { writeSync(fd, JSON.stringify(summary, null, 2)); fsyncSync(fd); } finally { closeSync(fd); }
  } catch (error) {
    const message = error && error.message ? error.message : String(error);
    console.log(`session-migrate: FAILED ${message} — sessions left exactly as they were`);
    // Even a failed migration must not leave two records for one folder behind.
    try { dedupeWorkspaceRegistry({ storagesRoot: join(home, 'storages'), log: emit }); } catch { /* reported above */ }
    try {
      const fd = openSync(join(home, 'DSHPortE-session-migrate.json'), 'w');
      try { writeSync(fd, JSON.stringify({ ...summary, failed: message }, null, 2)); fsyncSync(fd); } finally { closeSync(fd); }
    } catch { /* the log line above is the durable record */ }
  }
}
