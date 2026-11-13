// The diagnostics bundle the failure screen offers: what the app may share, what
// it must never share, and how far a file is read before it stops.
//
// WHY IT IS A LIST, NOT A DIRECTORY WALK
// --------------------------------------
// `DSH_HOME` holds four things that must never leave the phone: `.credentials.yaml`,
// the conversation logs under `sessions/`, the attachments those conversations
// refer to, and `storages/`, which is DSH's own state and can carry more than
// paths. A walk that collects "everything that looks like a log" is one new file
// name away from shipping a credential, so the opposite is done here: a fixed
// list of known-useful files is read, and everything else is reported by name and
// reason without being opened. `EXCLUDED` is more than documentation — every
// entry in it is asserted to be absent from the bundle by the tests.
//
// REDACTION IS NOT A SUBSTITUTE FOR NOT COLLECTING
// ------------------------------------------------
// Both are done. The exclusion list decides what is read; `redactText()` is the
// belt for the files that are read, because a boot log can quote the line that
// caused the failure and that line can contain a token, an `Authorization`
// header or an API key. The patterns are listed in one place so the report can
// say exactly which rules ran and how many times each fired — "0 redactions" and
// "no redaction rule matched because none exists" look identical otherwise.
//
// SIZE
// ----
// A phone's boot log is small, but an error loop can make it large, and the zip
// has to be shareable. Two limits: per file, and for the whole bundle. Reading is
// bounded too: a cut log keeps only complete, prefixed records. Other files
// need their field context and are omitted if the read window cannot hold them.
// Per-file and bundle limits are applied after redaction.

import {
  closeSync, existsSync, fstatSync, lstatSync, mkdirSync, openSync, readFileSync, readSync,
  readdirSync, renameSync, rmSync, statSync, writeFileSync,
} from 'node:fs';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { BOOT_FILES } from './boot-guard.mjs';

/** Where each collected file comes from. Roots are supplied by the caller. */
export const ROOT_KEYS = Object.freeze(['appSupport', 'dshHome', 'boot', 'documents']);

/** Per-file and whole-bundle budgets, in bytes. */
export const DEFAULT_LIMITS = Object.freeze({
  maxFileBytes: 256 * 1024,
  maxTotalBytes: 2 * 1024 * 1024,
  readWindowBytes: 1024 * 1024,
  maxInventoryEntries: 200,
  maxCountEntries: 2000,
});

/**
 * Directory names that are never opened, anywhere in any root.
 *
 * `storages` is here because DSH keeps its own state there (the workspace
 * registry names absolute paths, and provider configuration has been seen in
 * `storages/**&#47;*.json` on the desktop); its *names* are listed, its contents
 * are not.
 */
export const FORBIDDEN_SEGMENTS = Object.freeze(['sessions', 'sessions-quarantine', 'attachments', 'storages']);

/** File names that are never opened, anywhere in any root. */
export const FORBIDDEN_NAMES = Object.freeze([
  '.credentials.yaml',
  '.credentials.yml',
  'DSHPortC-session-url.txt', // a live launch token, in plaintext, by design of the old build
  'events.jsonl', // the guest channel's event stream: commands and results
  'AGENTS.md', // the user's own instructions
]);

/**
 * Files the bundle wants, in the order they appear in it.
 *
 * The order is the fallback priority: when the total budget runs out, the files
 * later in this list are the ones that get cut.
 */
const SOURCES = Object.freeze([
  { root: 'appSupport', rel: 'DSHPortC-node.log', id: 'app-log', description: 'app boot log (redacted when written)' },
  { root: 'appSupport', rel: 'DSHPortC-status.json', id: 'status', description: 'boot phase, node facts, error text' },
  { root: 'boot', rel: BOOT_FILES.state, id: 'boot-guard', description: 'launch attempts and the safe-mode decision' },
  { root: 'boot', rel: BOOT_FILES.outcome, id: 'boot-outcome', description: 'the terminal answer for the last launch' },
  { root: 'boot', rel: BOOT_FILES.request, id: 'boot-request', description: 'a pending request for the next launch' },
  { root: 'boot', rel: BOOT_FILES.background, id: 'boot-background', description: 'background marker for the last launch' },
  { root: 'boot', rel: BOOT_FILES.overlay, id: 'safe-mode-overlay', description: 'the --patch overlay safe mode used' },
  { root: 'boot', rel: BOOT_FILES.resetPreview, id: 'reset-preview', description: 'what a reset would move' },
  { root: 'dshHome', rel: 'profiles/ios-sim/package.json', id: 'profile-manifest', description: 'which bundles the profile mounts' },
  { root: 'dshHome', rel: 'profiles/ios-sim/cordis.yml', id: 'profile-root', description: 'the profile root entry list' },
  { root: 'dshHome', rel: 'profiles/ios-sim/cordis.patch.yml', id: 'profile-user-patch', description: 'the user layer Settings saves' },
  {
    root: 'dshHome',
    rel: 'profiles/ios-sim/node_modules/dsh-ios-profile/cordis.patch.yml',
    id: 'profile-app-patch',
    description: 'the app layer, rendered for this container',
  },
]);

/** What is deliberately left out, with the reason shown to the reader. */
export const EXCLUDED = Object.freeze([
  { root: 'dshHome', rel: '.credentials.yaml', reason: 'credential store' },
  { root: 'dshHome', rel: 'storages', reason: 'DSH state: workspace registry and stored paths' },
  { root: 'dshHome', rel: 'sessions', reason: 'conversation content' },
  { root: 'dshHome', rel: 'sessions-quarantine', reason: 'conversation content' },
  { root: 'dshHome', rel: 'attachments', reason: 'conversation attachments' },
  { root: 'dshHome', rel: 'events.jsonl', reason: 'guest channel event stream' },
  { root: 'dshHome', rel: 'AGENTS.md', reason: 'personal instructions' },
  { root: 'appSupport', rel: 'DSHPortC-session-url.txt', reason: 'live launch token' },
  { root: 'documents', rel: 'workspace', reason: 'user files' },
]);

/**
 * Key names whose value is a secret wherever they appear, with any identifier
 * prefix (`openaiApiKey`, `DEEPSEEK_API_KEY`, `client_secret`).
 *
 * Bare `token`/`auth` are not here: as a suffix they also end ordinary names
 * (`max_token`, `oauth`), so they are matched as whole keys only, in a position
 * where a YAML or JSON key can start — see `WEAK_KEYS`.
 */
const STRONG_KEYS = '(?:api[_-]?key|api[_-]?token|access[_-]?token|refresh[_-]?token|id[_-]?token|auth[_-]?token'
  + '|session[_-]?token|bearer[_-]?token|[_-]token|access[_-]?key|secret[_-]?key|private[_-]?key'
  + '|client[_-]?secret|secret|password|passwd|passphrase|credentials?|(?:set[_-]?)?cookies?)';
const WEAK_KEYS = '(?:token|auth|authorization|bearer|pwd)';
/** A field value: a JSON/YAML quoted string, or the rest of the line. */
const FIELD_VALUE = `("(?:[^"\\\\\\n]|\\\\.)*"|'(?:[^'\\n]|'')*'|[^\\s"',}\\]][^\\n]*?(?=[ \\t\\r]*$))`;
/** Skip a value an earlier rule already replaced, so it is not counted twice. */
const NOT_REDACTED = '(?!["\']?<redacted)';

/**
 * Replace the value of a `key: value` field, keeping the key and the quotes.
 *
 * A bare value inside a JSON object or a YAML flow mapping (`{a: x, b: y}`) ends
 * at the next `,`/`}`/`]`; on a YAML block line it runs to the end of the line,
 * because a password may contain a comma and the tail of it would otherwise be
 * left behind.
 */
function redactField(match, context, quote, key, separator, value) {
  let rest = '';
  const quoted = value.startsWith('"') || value.startsWith("'");
  if (!quoted && (quote !== '' || /[{,[]/.test(context))) {
    const cut = value.search(/[ \t]*[,}\]]/);
    if (cut > 0) rest = value.slice(cut);
  }
  const shown = value.startsWith('"') ? '"<redacted>"' : value.startsWith("'") ? "'<redacted>'" : '<redacted>';
  return `${context}${quote}${key}${quote}${separator}${shown}${rest}`;
}

function redactAssignment(match, context, key, value) {
  const shown = value.startsWith('"') ? '"<redacted>"' : value.startsWith("'") ? "'<redacted>'" : '<redacted>';
  return `${context}${key}=${shown}`;
}

/** Check field starts, using the same strong/weak key contexts as the rules. */
const SENSITIVE_FIELDS = [
  new RegExp('(^[ \\t]*(?:-[ \\t]+)?|[^A-Za-z0-9_-])(["\']?)([A-Za-z0-9_-]*?' + STRONG_KEYS + ')\\2[ \\t]*:[ \\t]*', 'gi'),
  new RegExp('(^[ \\t]*(?:-[ \\t]+)?|[|>{,\\[][ \\t]*)(["\']?)(' + WEAK_KEYS + ')\\2[ \\t]*:[ \\t]*', 'gi'),
];

function hasMultilineSecret(text) {
  const lines = text.split('\n').map((line) => line.replace(/\r$/, ''));
  for (let index = 0; index < lines.length; index += 1) {
    for (const pattern of SENSITIVE_FIELDS) {
      for (const field of lines[index].matchAll(pattern)) {
        const atStart = field.index === 0 && /^[ \t]*(?:-[ \t]+)?$/.test(field[1]);
        const indent = atStart ? field[1].length : lines[index].match(/^[ \t]*/)[0].length;
        const value = lines[index].slice(field.index + field[0].length)
          .replace(/^(?:!\S+[ \t]+)+/, '').trim();
        if (/^[|>][+-]?\d*[+-]?(?:[ \t]+#.*)?$/.test(value)
          || /^"(?:[^"\\]|\\.)*\\?$|^'(?:[^']|'')*$/.test(value)) return true;
        if (value.startsWith('"') || value.startsWith("'")) continue;
        // Only a key position can own an indented continuation, not an error sentence.
        const before = lines[index].slice(0, field.index + field[1].length);
        if (!atStart && !/[|>{,\[][ \t]*$/.test(before)) continue;
        let next = index + 1;
        while (next < lines.length && /^[ \t]*(?:#.*)?$/.test(lines[next])) next += 1;
        if (next === lines.length) continue;
        const following = lines[next];
        const depth = following.match(/^[ \t]*/)[0].length;
        const trimmed = following.replace(/^[ \t]*/, '');
        // Empty auth mappings are settings namespaces; check their child keys in turn.
        if (field[3].toLowerCase() === 'auth' && /^(?:#.*)?$/.test(value)
          && /^["']?[^"' \t:]+["']?[ \t]*:(?:[ \t]|$)/.test(trimmed)) continue;
        if (depth > indent || (depth === indent && /^-[ \t]+/.test(trimmed))) return true;
      }
    }
  }
  return false;
}

/**
 * Redaction rules, in order. Each one is named, so the manifest can say which
 * rule fired how many times without quoting what it replaced.
 */
export const REDACTIONS = Object.freeze([
  {
    // Old delivery messages interpolated unescaped, possibly multiline content.
    // There is no reliable end marker, so omit the remainder of the text.
    name: 'legacy-notification-log',
    pattern: /^.*\bdshportc: notify delivered\b[^\n]*[ \t]title=[\s\S]*$/gim,
    replacement: '[omitted: legacy notification content]\n',
  },
  {
    name: 'bridge-payload',
    pattern: /^.*\bDSHPORTC_(?:NOTIFY|BUSY)\b[^\n]*$/gm,
    replacement: '[omitted: bridge payload]',
  },
  {
    // Also covers the status JSON embedded in old snapshot summaries.
    name: 'notification-content',
    pattern: /("(?:title|body)"\s*:\s*)(?!"<redacted>")"(?:[^"\\]|\\[\s\S])*"/gi,
    replacement: '$1"<redacted>"',
  },
  {
    name: 'cookie-values',
    pattern: /((["']?)(?:set[_-]?)?cookies?\2[ \t]*:[ \t]*)\[(?:"(?:[^"\\]|\\[\s\S])*"|'(?:[^']|'')*'|[^\]"'])*\]/gi,
    replacement: '$1"<redacted>"',
  },
  {
    name: 'cookie-pair',
    pattern: /(["'](?:set[_-]?)?cookies?["']\s*,\s*)("(?:[^"\\]|\\[\s\S])*"|'(?:[^']|'')*')/gi,
    replacement: '$1"<redacted>"',
  },
  {
    name: 'authorization-header',
    // The prefix group keeps a log prefix (`node| `) and matches the header
    // wherever it starts.
    pattern: /(^|[|>\s])authorization[ \t]*:[^\n]*$/gim,
    replacement: '$1Authorization: <redacted>',
  },
  {
    name: 'cookie-header',
    pattern: /(^|[|>\s])(?:set-)?cookie[ \t]*:[^\n]*$/gim,
    replacement: '$1Cookie: <redacted>',
  },
  {
    name: 'bearer-value',
    pattern: /\b(Bearer|Basic)[ \t]+[A-Za-z0-9._~+/=-]{8,}/gi,
    replacement: '$1 <redacted>',
  },
  {
    // `scheme://user:password@host`, and a bare long token used as the user
    // (`https://<token>@git.host`). A short user-only form (`ssh://git@host`)
    // names nobody and is left as it is.
    name: 'url-credentials',
    pattern: /\b([a-z][a-z0-9+.-]*:\/\/)(?:[^\s/?#@:'"<>]*:[^\s/?#@'"<>]*|[^\s/?#@:'"<>]{16,})@/gi,
    replacement: '$1<redacted>@',
  },
  {
    // `token=...` anywhere a URL or a query string can put it, plus the other
    // parameter names a provider client uses.
    name: 'token-parameter',
    pattern: /(^|[?&;\s"'(=])(token|access_token|refresh_token|id_token|auth|password|passwd|secret|api[_-]?key|apikey|client[_-]?secret)=([^&\s"'#]+)/gim,
    replacement: '$1$2=<redacted>',
  },
  {
    name: 'dsh-auth-cookie',
    pattern: /\bdsh-auth-[A-Za-z0-9._~+/=-]{8,}/g,
    replacement: 'dsh-auth-<redacted>',
  },
  {
    name: 'sk-key',
    pattern: /\bsk-[A-Za-z0-9][A-Za-z0-9_-]{7,}/g,
    replacement: 'sk-<redacted>',
  },
  {
    name: 'provider-key',
    pattern: /\b(gh[pousr]_[A-Za-z0-9]{16,}|xox[abp]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,})/g,
    replacement: '<redacted-key>',
  },
  {
    name: 'jwt',
    pattern: /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}/g,
    replacement: '<redacted-jwt>',
  },
  {
    name: 'private-key-block',
    pattern: /-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/g,
    replacement: '<redacted-private-key>',
  },
  {
    // `apiKey: ...`, `"client_secret": "..."` — the shapes of the profile YAML
    // and of any JSON a log line quotes. Any position: these names do not end
    // an ordinary word.
    name: 'secret-field',
    pattern: new RegExp(`(^|[^A-Za-z0-9_-])(["']?)([A-Za-z0-9_-]*?${STRONG_KEYS})\\2([ \\t]*:[ \\t]*)${NOT_REDACTED}${FIELD_VALUE}`, 'gim'),
    replacement: redactField,
  },
  {
    // `token: ...`, `auth: ...`: only where a key can start (line start, list
    // item, after a log prefix, inside `{...}`), so "invalid token: retry" in a
    // sentence keeps its words.
    name: 'token-field',
    pattern: new RegExp(`(^[ \\t]*(?:-[ \\t]+)?|[|>{,\\[][ \\t]*)(["']?)(${WEAK_KEYS})\\2([ \\t]*:[ \\t]*)${NOT_REDACTED}${FIELD_VALUE}`, 'gim'),
    replacement: redactField,
  },
  {
    // `DEEPSEEK_API_KEY=...`, `export MY_SECRET="..."`: the environment form,
    // whose prefixed names the `token-parameter` rule does not reach.
    name: 'secret-assignment',
    pattern: new RegExp(`(^|[^A-Za-z0-9_-])([A-Za-z0-9_-]*?${STRONG_KEYS})=${NOT_REDACTED}("(?:[^"\\\\\\n]|\\\\.)*"|'[^'\\n]*'|[^\\s&"'#;=][^\\s&"'#;]*)`, 'gim'),
    replacement: redactAssignment,
  },
]);

/**
 * Replace every container path with one placeholder.
 *
 * The container UUID changes on every install and names nothing outside this
 * phone; keeping it in a bundle that is about to be handed to someone else buys
 * no diagnosis and is the only device identifier most of these files carry.
 */
const CONTAINER_PATTERN = /\\?\/Containers\\?\/(Data|Shared|Bundle)\\?\/(Application|AppGroup|PluginKitPlugin)\\?\/[0-9A-Fa-f][0-9A-Fa-f-]{35}/g;

/**
 * A simulator's device directory: its UUID identifies the Mac's simulator, not
 * anything the reader needs.
 */
const SIMULATOR_DEVICE_PATTERN = /\\?\/CoreSimulator\\?\/Devices\\?\/[0-9A-Fa-f][0-9A-Fa-f-]{35}/g;

/**
 * A home directory (`/Users/<name>`, `/home/<name>`): on the simulator every
 * container path starts with the developer's account name. `/Users/Shared` names
 * nobody and stays.
 */
const HOME_PATTERN = /(\\?\/(?:Users|home)\\?\/)(?!<user>|Shared(?![^\\/\s"'<>:]))[^\\/\s"'<>:]+/g;

function message(error) {
  return error && error.message ? error.message : String(error);
}

/**
 * Whether a path relative to a root may be opened at all.
 *
 * Two independent answers, because a caller can pass either form: a path with a
 * forbidden segment anywhere, or a path whose own name is forbidden.
 *
 * @param {string} rel a relative path, forward or native separators
 * @returns {boolean} true when the path must not be read
 */
export function isForbiddenPath(rel) {
  if (typeof rel !== 'string' || rel.length === 0) return true;
  const parts = rel.split(/[\\/]+/).filter((part) => part.length > 0 && part !== '.');
  if (parts.some((part) => part === '..')) return true;
  if (parts.some((part) => FORBIDDEN_SEGMENTS.includes(part))) return true;
  return FORBIDDEN_NAMES.includes(parts[parts.length - 1]);
}

/**
 * Resolve `rel` under `root` and refuse anything that leaves it.
 *
 * @param {string} root an absolute directory
 * @param {string} rel a relative path
 * @returns {string|null} the absolute path, or null when it escapes or is unusable
 */
export function safeResolve(root, rel) {
  if (typeof root !== 'string' || !isAbsolute(root)) return null;
  if (typeof rel !== 'string' || rel.length === 0 || rel.includes('\0')) return null;
  if (isAbsolute(rel)) return null;
  const joined = resolve(root, rel);
  const check = relative(resolve(root), joined);
  if (check.length === 0 || check.startsWith('..') || isAbsolute(check)) return null;
  return joined;
}

/**
 * The first symlinked directory between `root` and `absolute`, if any.
 *
 * A fixed list of file names is not enough on its own: `boot/` could be replaced
 * by a link to somewhere else, and then every file "in" it would be read from
 * outside the root. The final component is not checked here — a link where a file
 * belongs is refused by the caller with its own message.
 *
 * @param {string} root an absolute directory
 * @param {string} absolute a candidate inside it
 * @returns {string|null} the offending link, or null
 */
function ancestorLink(root, absolute) {
  const rel = relative(resolve(root), absolute);
  if (rel.length === 0 || rel.startsWith('..') || isAbsolute(rel)) return null;
  const parts = rel.split(sep);
  let current = resolve(root);
  for (const part of parts.slice(0, -1)) {
    current = join(current, part);
    try {
      if (lstatSync(current).isSymbolicLink()) return current;
    } catch {
      return null;
    }
  }
  return null;
}

/**
 * Apply every redaction rule to `text`.
 *
 * @param {string} text
 * @returns {{text: string, counts: Record<string, number>}}
 */
export function redactText(text) {
  let out = typeof text === 'string' ? text : String(text ?? '');
  if (hasMultilineSecret(out)) {
    return { text: '[omitted: multiline sensitive field]\n', counts: { 'multiline-secret': 1 } };
  }
  const counts = {};
  for (const rule of REDACTIONS) {
    let hits = 0;
    out = out.replace(rule.pattern, (...args) => {
      hits += 1;
      if (typeof rule.replacement === 'function') return rule.replacement(...args);
      // A functional replacement returns literal text, so `$1` in the template
      // has to be expanded here rather than by String.replace.
      return rule.replacement.replace(/\$(\d)/g, (_, digit) => args[Number(digit)] ?? '');
    });
    if (hits > 0) counts[rule.name] = (counts[rule.name] ?? 0) + hits;
  }
  return { text: out, counts };
}

function redactPathsIn(text) {
  return text
    .replace(CONTAINER_PATTERN, (_, kind, group) => `/Containers/${kind}/${group}/<container>`)
    .replace(SIMULATOR_DEVICE_PATTERN, '/CoreSimulator/Devices/<device>')
    .replace(HOME_PATTERN, (_, prefix) => `${prefix.replace(/\\/g, '')}<user>`);
}

function escapeRegExp(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/**
 * Rewrite every absolute path in the report's metadata (not the file contents)
 * relative to the root it lives in, then apply `redactPathsIn` to what is left.
 *
 * The manifest is shared together with the files, so a path in it is as exposed
 * as a path in a log: `files[].path`, the inventory's root paths, a symlink named
 * in an exclusion reason and an `ENOENT` message all used to carry the container
 * UUID and, on the simulator, the account name.
 */
function pathScrubber(roots) {
  const known = Object.entries(roots)
    .filter(([key, value]) => ROOT_KEYS.includes(key) && typeof value === 'string' && isAbsolute(value))
    .map(([key, value]) => [key, resolve(value)])
    .filter(([, value]) => value !== sep)
    // Longest first: `boot` lives inside `appSupport`.
    .sort((left, right) => right[1].length - left[1].length)
    .map(([key, value]) => [key, new RegExp(`${escapeRegExp(value)}(?=$|[\\\\/\\s'"):,\\]])`, 'g')]);
  return (text) => {
    let out = text;
    for (const [key, pattern] of known) out = out.replace(pattern, key);
    return redactPathsIn(out);
  };
}

function scrubDeep(value, scrub) {
  if (typeof value === 'string') return scrub(value);
  if (Array.isArray(value)) return value.map((item) => scrubDeep(item, scrub));
  if (value !== null && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, scrubDeep(item, scrub)]));
  }
  return value;
}

/** Read at most `windowBytes` from the end of a regular file. */
function readTail(path, windowBytes) {
  const fd = openSync(path, 'r');
  try {
    const size = fstatSync(fd).size;
    const window = Math.min(size, Math.max(0, windowBytes));
    const start = size - window;
    const buffer = Buffer.alloc(window);
    let read = 0;
    while (read < window) {
      const chunk = readSync(fd, buffer, read, window - read, start + read);
      if (chunk <= 0) break;
      read += chunk;
    }
    return { buffer: buffer.subarray(0, read), size, windowStart: start };
  } finally {
    closeSync(fd);
  }
}

function looksBinary(buffer) {
  const limit = Math.min(buffer.length, 8192);
  for (let index = 0; index < limit; index += 1) {
    if (buffer[index] === 0) return true;
  }
  return false;
}

/** Cut a string to at most `maxBytes` UTF-8 bytes, keeping the END. */
function tailByBytes(text, maxBytes) {
  const bytes = Buffer.byteLength(text, 'utf8');
  if (bytes <= maxBytes) return { text, truncated: false, bytes };
  const buffer = Buffer.from(text, 'utf8');
  let sliced = buffer.subarray(buffer.length - Math.max(0, maxBytes));
  // Do not start in the middle of a multi-byte character.
  let text2 = sliced.toString('utf8');
  text2 = text2.replace(/^\uFFFD+/, '');
  return { text: text2, truncated: true, bytes: Buffer.byteLength(text2, 'utf8') };
}

function countEntries(dir, cap) {
  try {
    const names = readdirSync(dir);
    return { entries: names.length, capped: names.length > cap };
  } catch {
    return { entries: null, capped: false };
  }
}

function describeEntry(root, name) {
  const full = join(root, name);
  let stat;
  try {
    stat = lstatSync(full);
  } catch {
    return null;
  }
  const forbiddenDir = stat.isDirectory() && FORBIDDEN_SEGMENTS.includes(name);
  const forbiddenFile = FORBIDDEN_NAMES.includes(name);
  if (stat.isSymbolicLink()) {
    return { name, kind: 'link', contentsIncluded: false, note: 'symbolic link; not followed' };
  }
  if (stat.isDirectory()) {
    const counted = countEntries(full, DEFAULT_LIMITS.maxCountEntries);
    return {
      name,
      kind: 'dir',
      entries: counted.entries,
      contentsIncluded: false,
      note: forbiddenDir ? 'contents excluded' : 'names only',
    };
  }
  if (!stat.isFile()) return { name, kind: 'other', contentsIncluded: false };
  return {
    name,
    kind: 'file',
    bytes: stat.size,
    contentsIncluded: !forbiddenFile,
    note: forbiddenFile ? 'contents excluded' : undefined,
  };
}

function inventoryOf(rootPath, key, limits) {
  const entries = [];
  let names;
  try {
    names = readdirSync(rootPath).sort();
  } catch (error) {
    return { root: key, path: rootPath, error: message(error), entries };
  }
  for (const name of names) {
    if (entries.length >= limits.maxInventoryEntries) break;
    const entry = describeEntry(rootPath, name);
    if (entry !== null) entries.push(entry);
  }
  return { root: key, path: rootPath, entries };
}

function readOneSource(source, roots, limits, options) {
  const rootPath = roots[source.root];
  if (typeof rootPath !== 'string' || !isAbsolute(rootPath)) {
    return { kind: 'error', id: source.id, path: `${source.root}/${source.rel}`, error: `root ${source.root} is not configured` };
  }
  if (options.linkedRoots !== undefined && options.linkedRoots.has(source.root)) {
    return { kind: 'excluded', path: `${source.root}/${source.rel}`, reason: `root ${source.root} is itself a symbolic link; not followed` };
  }
  if (isForbiddenPath(source.rel)) {
    return { kind: 'excluded', path: `${source.root}/${source.rel}`, reason: 'forbidden path (see FORBIDDEN_NAMES/FORBIDDEN_SEGMENTS)' };
  }
  const absolute = safeResolve(rootPath, source.rel);
  if (absolute === null) {
    return { kind: 'error', id: source.id, path: `${source.root}/${source.rel}`, error: 'path escapes its root' };
  }
  const link = ancestorLink(rootPath, absolute);
  if (link !== null) {
    return { kind: 'excluded', path: `${source.root}/${source.rel}`, reason: `behind a symbolic link (${link}); not followed` };
  }
  let stat;
  try {
    stat = lstatSync(absolute);
  } catch (error) {
    if (error && error.code === 'ENOENT') return { kind: 'absent', path: `${source.root}/${source.rel}` };
    return { kind: 'error', id: source.id, path: `${source.root}/${source.rel}`, error: message(error) };
  }
  if (stat.isSymbolicLink()) {
    // A log that is a link is either an accident or an attempt to make the
    // bundle read something else. Either way it is not what this file should be.
    return { kind: 'excluded', path: `${source.root}/${source.rel}`, reason: 'symbolic link; not followed' };
  }
  if (!stat.isFile()) {
    return { kind: 'excluded', path: `${source.root}/${source.rel}`, reason: 'not a regular file' };
  }

  let tail;
  try {
    tail = readTail(absolute, limits.readWindowBytes);
  } catch (error) {
    return { kind: 'error', id: source.id, path: `${source.root}/${source.rel}`, error: message(error) };
  }
  if (looksBinary(tail.buffer)) {
    return {
      kind: 'file',
      id: source.id,
      description: source.description,
      path: absolute,
      displayPath: `${source.root}/${source.rel}`,
      bytes: tail.size,
      keptBytes: 0,
      truncated: 'binary',
      binary: true,
      redactions: {},
      content: null,
    };
  }
  let text = tail.buffer.toString('utf8');
  const markers = [];
  let truncated = null;
  if (tail.windowStart > 0) {
    if (source.id !== 'app-log') {
      return {
        kind: 'excluded', path: `${source.root}/${source.rel}`,
        reason: 'read window omits field context; content not included',
      };
    }
    const newline = text.indexOf('\n');
    // Unprefixed lines may continue an old notification whose header was cut.
    text = (newline === -1 ? '' : text.slice(newline + 1))
      .split('\n').filter((line) => /^(?:node\| |dshportc: )/.test(line)).join('\n');
    truncated = 'window';
    markers.push(`[truncated: only the last ${tail.buffer.length} of ${tail.size} bytes were examined]`);
  }
  const redacted = redactText(text);
  let content = redacted.text;
  const perFile = tailByBytes(content, limits.maxFileBytes);
  content = perFile.text;
  if (perFile.truncated) {
    truncated ??= 'file';
    markers.push(`[truncated: kept the last ${perFile.bytes} of ${tail.size} bytes]`);
  }
  if (options.redactPaths) content = redactPathsIn(content);
  for (const marker of markers) content = `${marker}\n${content}`;
  return {
    kind: 'file',
    id: source.id,
    description: source.description,
    path: absolute,
    displayPath: `${source.root}/${source.rel}`,
    bytes: tail.size,
    keptBytes: Buffer.byteLength(content, 'utf8'),
    truncated,
    binary: false,
    redactions: redacted.counts,
    content,
  };
}

function loadLimits(limits = {}) {
  const merged = { ...DEFAULT_LIMITS };
  for (const key of Object.keys(DEFAULT_LIMITS)) {
    const value = limits[key];
    if (typeof value === 'number' && Number.isFinite(value) && value >= 0) merged[key] = Math.floor(value);
  }
  return merged;
}

/**
 * Collect the bundle: inventory, file contents (redacted, truncated), exclusions.
 *
 * Never throws for a missing root, a missing file or an unreadable one: every
 * such case becomes an entry in the report, because a diagnostics bundle that
 * fails to build is worse than one that says what it could not read.
 *
 * @param {object} options
 * @param {Record<string, string>} options.roots absolute paths by root key
 * @param {object} [options.limits]
 * @param {Date|number|string} [options.now]
 * @param {boolean} [options.redactPaths] replace the container UUID (default true)
 * @returns {object} the report
 */
export function collect({ roots = {}, limits: rawLimits = {}, now = new Date(), redactPaths = true } = {}) {
  const limits = loadLimits(rawLimits);
  // The boot directory always lives inside the app's support directory, and a
  // caller that names one of them should not have to name both.
  const allRoots = { ...roots };
  if (typeof allRoots.boot !== 'string' && typeof allRoots.appSupport === 'string' && isAbsolute(allRoots.appSupport)) {
    allRoots.boot = join(allRoots.appSupport, 'boot');
  }
  const at = now instanceof Date ? now.toISOString() : new Date(now).toISOString();
  const errors = [];
  const excluded = [];
  const absent = [];
  const files = [];
  // A root that is itself a link would let every file "inside" it come from
  // somewhere else; refuse the whole root rather than follow it.
  const linkedRoots = new Set();
  for (const [key, value] of Object.entries(allRoots)) {
    if (typeof value !== 'string' || !isAbsolute(value)) continue;
    try {
      if (lstatSync(value).isSymbolicLink()) linkedRoots.add(key);
    } catch { /* a missing root is reported per file */ }
  }
  let budget = limits.maxTotalBytes;

  for (const source of SOURCES) {
    const result = readOneSource(source, allRoots, limits, { redactPaths, linkedRoots });
    if (result.kind === 'file') {
      if (result.content !== null) {
        if (budget <= 0) {
          // No room at all: the entry stays in the manifest (so the reader knows
          // the file exists) but nothing of it is copied. A marker line per file
          // would quietly add up to more than the budget it is explaining.
          result.truncated = 'total';
          result.content = null;
          result.keptBytes = 0;
        } else if (result.keptBytes > budget) {
          const cut = tailByBytes(result.content, budget);
          result.content = `[truncated: the bundle reached its ${limits.maxTotalBytes}-byte budget; kept the last ${cut.bytes} bytes]\n${cut.text}`;
          result.truncated = 'total';
          result.keptBytes = Buffer.byteLength(result.content, 'utf8');
        }
        budget -= result.keptBytes;
      }
      delete result.kind;
      files.push(result);
      continue;
    }
    if (result.kind === 'absent') absent.push({ path: result.path });
    else if (result.kind === 'excluded') excluded.push({ path: result.path, reason: result.reason });
    else if (result.kind === 'error') errors.push({ id: result.id, path: result.path, error: result.error });
  }

  const inventory = [];
  for (const key of ['dshHome', 'appSupport', 'boot']) {
    const rootPath = allRoots[key];
    if (typeof rootPath !== 'string' || !isAbsolute(rootPath)) continue;
    inventory.push(inventoryOf(rootPath, key, limits));
  }

  for (const entry of EXCLUDED) {
    const rootPath = allRoots[entry.root];
    if (typeof rootPath !== 'string' || !isAbsolute(rootPath)) continue;
    const absolute = safeResolve(rootPath, entry.rel);
    if (absolute === null) continue;
    if (!existsSync(absolute)) continue;
    excluded.push({ path: `${entry.root}/${entry.rel}`, reason: entry.reason });
  }

  const redactions = {};
  for (const file of files) {
    for (const [rule, count] of Object.entries(file.redactions ?? {})) {
      redactions[rule] = (redactions[rule] ?? 0) + count;
    }
  }
  const keptBytes = files.reduce((sum, file) => sum + file.keptBytes, 0);
  const totalBytes = files.reduce((sum, file) => sum + file.bytes, 0);

  if (redactPaths) {
    // Contents were redacted when read; everything else in the report is
    // metadata that goes into the manifest and SUMMARY verbatim.
    const scrub = pathScrubber(allRoots);
    files.forEach((file, index) => {
      const { content, ...rest } = file;
      files[index] = { ...scrubDeep(rest, scrub), content };
    });
    for (const list of [inventory, excluded, absent, errors]) {
      list.forEach((entry, index) => { list[index] = scrubDeep(entry, scrub); });
    }
  }

  return {
    version: 1,
    generator: 'dshportc-diagnostics/1',
    generatedAt: at,
    limits,
    redactPaths: redactPaths === true,
    roots: Object.fromEntries(Object.entries(allRoots)
      .filter(([key, value]) => ROOT_KEYS.includes(key) && typeof value === 'string')
      .map(([key, value]) => [key, redactPaths ? redactPathsIn(value) : value])),
    inventory,
    files,
    excluded,
    absent,
    errors,
    totals: {
      files: files.length,
      binary: files.filter((file) => file.binary).length,
      truncated: files.filter((file) => file.truncated !== null).length,
      bytes: totalBytes,
      keptBytes,
      redactions,
    },
  };
}

/**
 * One text file holding the whole bundle, for the share sheet.
 *
 * @param {object} report the result of {@link collect}
 * @returns {string}
 */
export function renderBundleText(report) {
  const lines = [
    '# DSHPortC diagnostics bundle',
    '',
    `generated: ${report?.generatedAt ?? 'unknown'}`,
    `generator: ${report?.generator ?? 'unknown'}`,
    `limits: ${JSON.stringify(report?.limits ?? {})}`,
    `totals: ${JSON.stringify(report?.totals ?? {})}`,
    '',
    '## What this bundle does not contain',
    '',
  ];
  for (const entry of report?.excluded ?? []) lines.push(`- ${entry.path}: ${entry.reason}`);
  if ((report?.excluded ?? []).length === 0) lines.push('- (nothing was excluded)');
  lines.push('', '## Roots', '');
  for (const [key, value] of Object.entries(report?.roots ?? {})) lines.push(`- ${key}: ${value}`);
  lines.push('', '## Inventory (names only; excluded contents are never opened)', '');
  for (const root of report?.inventory ?? []) {
    lines.push(`### ${root.root} ${root.error ? `(error: ${root.error})` : ''}`.trimEnd());
    for (const entry of root.entries ?? []) {
      const detail = entry.kind === 'dir'
        ? `${entry.entries} entries, ${entry.note ?? ''}`.trim()
        : entry.bytes !== undefined ? `${entry.bytes} bytes` : entry.note ?? '';
      lines.push(`- ${entry.name} [${entry.kind}] ${detail}`.trimEnd());
    }
    lines.push('');
  }
  if ((report?.errors ?? []).length > 0) {
    lines.push('## Read errors', '');
    for (const entry of report.errors) lines.push(`- ${entry.path}: ${entry.error}`);
    lines.push('');
  }
  if ((report?.absent ?? []).length > 0) {
    lines.push('## Not present', '');
    for (const entry of report.absent) lines.push(`- ${entry.path}`);
    lines.push('');
  }
  for (const file of report?.files ?? []) {
    lines.push(`## ${file.displayPath}`);
    lines.push(`id: ${file.id}${file.description ? ` — ${file.description}` : ''}`);
    lines.push(`kept ${file.keptBytes} of ${file.bytes} bytes`
      + `${file.truncated ? `, truncated: ${file.truncated}` : ''}`
      + `${Object.keys(file.redactions ?? {}).length > 0 ? `, redacted: ${JSON.stringify(file.redactions)}` : ''}`);
    lines.push('');
    lines.push(file.content === null ? '(content not included)' : file.content);
    lines.push('');
  }
  return lines.join('\n');
}

function safeName(displayPath) {
  return displayPath.replace(/[^A-Za-z0-9._-]+/g, '_').replace(/^_+|_+$/g, '').slice(0, 80) || 'file';
}

function writeAtomicText(file, text) {
  mkdirSync(dirname(file), { recursive: true });
  const temp = `${file}.${process.pid}.${Math.random().toString(16).slice(2)}.tmp`;
  writeFileSync(temp, text);
  renameSync(temp, file);
}

/**
 * Write the bundle to a directory: one file per collected entry, a manifest with
 * the metadata and a single readable summary.
 *
 * @param {object} options
 * @param {object} options.report the result of {@link collect}
 * @param {string} options.outDir an absolute directory (created if needed)
 * @returns {{dir: string, summaryPath: string, manifestPath: string, files: string[]}}
 */
export function materialize({ report, outDir } = {}) {
  if (typeof outDir !== 'string' || !isAbsolute(outDir)) {
    throw new TypeError('diagnostics: outDir must be an absolute path');
  }
  if (report === undefined || report === null || !Array.isArray(report.files)) {
    throw new TypeError('diagnostics: report is required');
  }
  mkdirSync(outDir, { recursive: true });
  const written = [];
  const manifest = { ...report, files: report.files.map(({ content, ...rest }) => ({ ...rest, file: null })) };
  report.files.forEach((file, index) => {
    if (file.content === null) return;
    const name = `${String(index).padStart(2, '0')}-${safeName(file.displayPath)}`;
    const target = join(outDir, 'files', name);
    mkdirSync(dirname(target), { recursive: true });
    writeAtomicText(target, file.content);
    const entry = manifest.files[index];
    entry.file = `files/${name}`;
    written.push(target);
  });
  const summaryPath = join(outDir, 'SUMMARY.txt');
  writeAtomicText(summaryPath, renderBundleText(report));
  const manifestPath = join(outDir, 'manifest.json');
  writeAtomicText(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
  return { dir: outDir, summaryPath, manifestPath, files: written };
}

function readJsonQuiet(file) {
  try {
    return { value: JSON.parse(readFileSync(file, 'utf8')), status: 'ok' };
  } catch (error) {
    if (error && error.code === 'ENOENT') return { value: undefined, status: 'missing' };
    return { value: undefined, status: 'corrupt' };
  }
}

/**
 * Write one bundle without being asked.
 *
 * Called at boot, right after the boot guard has run and before DSH is imported:
 * that is the only moment Node is guaranteed to be alive and the profile is
 * final. When the failure later kills Node, the "export diagnostics" button has
 * this snapshot to offer; when Node survives, the button asks for a fresh one
 * through {@link exportOnce}.
 *
 * @param {object} options
 * @param {string} options.outDir absolute directory for the bundle
 * @param {Record<string, string>} [options.roots]
 * @param {object} [options.limits]
 * @param {Date|number|string} [options.now]
 * @param {number} [options.keep] how many bundles to keep in `outDir` (0 = no pruning)
 * @returns {{dir: string, summaryPath: string, manifestPath: string, totals: object}}
 */
export function snapshot({ outDir, roots = {}, limits = {}, now = new Date(), keep = 3 } = {}) {
  if (typeof outDir !== 'string' || !isAbsolute(outDir)) {
    throw new TypeError('diagnostics: outDir must be an absolute path');
  }
  const report = collect({ roots, limits, now });
  const dir = join(outDir, `${stampFor(now)}-boot`);
  const written = materialize({ report, outDir: dir });
  const pruned = typeof keep === 'number' && keep > 0 ? pruneExports({ outDir, keep }) : { kept: [], removed: [] };
  return {
    dir,
    summaryPath: written.summaryPath,
    manifestPath: written.manifestPath,
    totals: report.totals,
    pruned,
  };
}

/**
 * A directory name that sorts chronologically and that `pruneExports` can
 * recognise: `YYYYMMDDTHHMMSSZ`.
 */
function stampFor(now) {
  const date = now instanceof Date ? now : new Date(now);
  return date.toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z');
}

/**
 * Answer one export request, if there is one.
 *
 * The app writes `export-request.json` (`{"action":"export-diagnostics","id":...}`)
 * and polls `export-done.json`, which this function writes when the bundle is
 * complete. The id is echoed so a stale file cannot be mistaken for an answer
 * to the current tap.
 *
 * @param {object} options
 * @param {string} options.requestFile
 * @param {string} options.doneFile
 * @param {string} options.outDir absolute directory for bundle subdirectories
 * @param {Record<string, string>} options.roots
 * @param {object} [options.limits]
 * @param {Date|number|string} [options.now]
 * @param {number} [options.pruneKeep] keep this many bundle directories
 * @returns {object} `{status}` plus what was written
 */
export function exportOnce({
  requestFile, doneFile, outDir, roots = {}, limits = {}, now = new Date(), pruneKeep,
} = {}) {
  if (typeof requestFile !== 'string' || requestFile.length === 0) {
    throw new TypeError('diagnostics: requestFile is required');
  }
  if (typeof doneFile !== 'string' || doneFile.length === 0) {
    throw new TypeError('diagnostics: doneFile is required');
  }
  if (typeof outDir !== 'string' || !isAbsolute(outDir)) {
    throw new TypeError('diagnostics: outDir must be an absolute path');
  }
  const request = readJsonQuiet(requestFile);
  if (request.status !== 'ok') return { status: request.status === 'missing' ? 'idle' : 'invalid-request' };
  const action = request.value?.action;
  const id = typeof request.value?.id === 'string' ? request.value.id : '';
  if (action !== 'export-diagnostics') return { status: 'ignored', action: String(action) };
  if (id === '') return { status: 'invalid-request', reason: 'request carries no id' };

  const done = readJsonQuiet(doneFile);
  if (done.status === 'ok' && done.value?.id === id && typeof done.value?.dir === 'string') {
    return { status: 'already-done', id, dir: done.value.dir, summary: done.value.summary ?? null };
  }

  const report = collect({ roots, limits, now });
  const dir = join(outDir, `${stampFor(now)}-${safeName(id)}`);
  const written = materialize({ report, outDir: dir });
  const answer = { id, at: new Date(now instanceof Date ? now.getTime() : Date.parse(now)).toISOString(), dir, summary: written.summaryPath };
  try {
    writeAtomicText(doneFile, `${JSON.stringify(answer, null, 2)}\n`);
  } catch (error) {
    return { status: 'write-failed', id, reason: message(error) };
  }
  if (typeof pruneKeep === 'number' && pruneKeep > 0) pruneExports({ outDir, keep: pruneKeep, now });
  return { status: 'exported', ...answer, files: written.files.length, totals: report.totals };
}

/**
 * Remove all but the newest `keep` bundle directories under `outDir`.
 *
 * Only directories created by {@link exportOnce} (whose names start with an
 * ISO-ish stamp) are candidates; anything else is left alone.
 *
 * @param {object} options
 * @param {string} options.outDir
 * @param {number} options.keep
 * @returns {{kept: string[], removed: string[]}}
 */
export function pruneExports({ outDir, keep } = {}) {
  if (typeof outDir !== 'string' || !isAbsolute(outDir)) {
    throw new TypeError('diagnostics: outDir must be an absolute path');
  }
  if (typeof keep !== 'number' || !Number.isFinite(keep) || keep < 1) {
    throw new TypeError('diagnostics: keep must be a positive number');
  }
  let names;
  try {
    names = readdirSync(outDir, { withFileTypes: true })
      .filter((entry) => entry.isDirectory() && /^\d{8}T\d{6}/.test(entry.name))
      .map((entry) => entry.name)
      .sort();
  } catch {
    return { kept: [], removed: [] };
  }
  const removed = [];
  while (names.length > keep) {
    const name = names.shift();
    try {
      rmSync(join(outDir, name), { recursive: true, force: true });
      removed.push(name);
    } catch { /* a directory still in use stays, and is reported by its absence */ }
  }
  return { kept: names, removed };
}

/** Exported for the tests and for the app: the fixed list the bundle reads. */
export function sourceList() {
  return SOURCES.map(({ root, rel, id, description }) => ({ root, rel, id, description }));
}

/** The size of a file, or null. Used by the plan's previews. */
export function fileSize(path) {
  try { return statSync(path).size; } catch { return null; }
}
