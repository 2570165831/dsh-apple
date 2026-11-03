// Pure-JS `glob` and `grep` tools for the iOS profile.
//
// WHY THIS EXISTS: the scout report (B7) claimed `dsh-tool-fs-search` is
// "pure JS, no ripgrep binary needed". That is wrong. Reading
// `dsh-tool-fs-search/lib/index.js` shows:
//
//   * `inject = ["tools", "systemPrompt", "subprocess", "workingDirectory"]`
//   * both `glob` and `grep` package `@vscode/ripgrep` and run it through
//     `ctx.subprocess.spawn()` (`:171`, `:526`, `:869`)
//
// So on iOS, where `subprocess` cannot exist, the row stays `pending` forever —
// and because a preset that references a pending plugin fails to mount
// (`agent-preset/invalid: tool-fs-search ... waiting for subprocess`), the whole
// session creation fails. Measured: logs/chat-jitless.json.
//
// This plugin registers the same two model-facing tool names with the same
// argument shapes, implemented over `node:fs` only. It is a deliberate
// functional downgrade, and the report says so:
//   * `grep` compiles the user's pattern with `new RegExp`, so it is JS regex
//     syntax, not ripgrep's dialect (no `--multiline`, no `\p{...}`-specific
//     ripgrep extensions beyond what V8 supports).
//   * `glob` walks the tree itself with a small `*`/`**`/`?` matcher and prunes
//     `.git`-class directories the way ripgrep's default filters do.
//   * Both read whole files, so a very large file is slower than ripgrep's
//     memory-mapped scan.
// Nothing here spawns, so it runs unchanged on iOS.

import { readdir, readFile, stat } from 'node:fs/promises';
import { join, relative, resolve, sep, isAbsolute } from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';

// This file ships inside the App bundle (`sim/`), beside `payload/`, so no path
// may be hard-coded: a bundle path differs per install and per device. Resolve
// the payload root from this module's own location instead, with
// IOS_SIM_DSH_INSTALL as the explicit override the host sets at launch.
//
// The two dependencies are loaded through a `createRequire` rooted at the
// payload's package.json, because the payload is a hoisted node_modules tree and
// this file lives outside it: a bare `import 'x'` here would search `sim/..`
// only. CommonJS `require` also dodges the packages' `exports` maps rejecting
// deep subpaths (`ERR_PACKAGE_PATH_NOT_EXPORTED`) that the A-stage file used to
// bypass with a literal path.
const HERE = fileURLToPath(new URL('.', import.meta.url));
const PAYLOAD_ROOT = process.env.IOS_SIM_DSH_INSTALL ?? resolve(HERE, '..', 'payload');
const requireFromPayload = createRequire(join(PAYLOAD_ROOT, 'package.json'));

/** Import a payload package by its bare specifier, following its `exports` map. */
async function importFromPayload(specifier) {
  const resolved = requireFromPayload.resolve(specifier);
  return import(pathToFileURL(resolved).href);
}

const z = requireFromPayload('@deepseek-ai/schemastery');
const { defineTool } = await importFromPayload('@deepseek-ai/dsh-tools');

/** Cordis plugin name used in loader diagnostics. */
export const name = 'tool-fs-search-js';

/** Services required: the tool registry and the workspace root. */
export const inject = ['tools', 'systemPrompt', 'workingDirectory'];

/** Directory names never descended into, matching ripgrep's default VCS filters. */
const PRUNED_DIRECTORIES = new Set(['.git', '.svn', '.hg', '.bzr', '.jj', '.sl', 'node_modules']);

/** Files larger than this are skipped by `grep` rather than read whole. */
const MAX_GREP_FILE_BYTES = 4 * 1024 * 1024;

const Config = z.object({
  globMaxResults: z.number().default(100),
  grepMaxMatches: z.number().default(250),
});

/**
 * Compile a glob into a RegExp over POSIX-style relative paths.
 * Supports `**` (any depth), `*` (within a segment), `?` (one character),
 * and `{a,b}` alternation. Anchored at both ends.
 * @param {string} pattern - the glob pattern.
 * @returns {RegExp} the compiled matcher.
 */
function compileGlob(pattern) {
  let out = '';
  let index = 0;
  while (index < pattern.length) {
    const char = pattern[index];
    if (char === '*') {
      if (pattern[index + 1] === '*') {
        // `**/` may match zero segments, so swallow a following slash.
        if (pattern[index + 2] === '/') {
          out += '(?:.*/)?';
          index += 3;
          continue;
        }
        out += '.*';
        index += 2;
        continue;
      }
      out += '[^/]*';
      index += 1;
      continue;
    }
    if (char === '?') {
      out += '[^/]';
      index += 1;
      continue;
    }
    if (char === '{') {
      const close = pattern.indexOf('}', index);
      if (close !== -1) {
        const alternatives = pattern.slice(index + 1, close).split(',').map((part) => part.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
        out += `(?:${alternatives.join('|')})`;
        index = close + 1;
        continue;
      }
    }
    out += char.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    index += 1;
  }
  return new RegExp(`^${out}$`);
}

/**
 * Walk a directory tree, invoking a visitor per file.
 * @param {string} root - absolute directory to start from.
 * @param {(absPath: string, relPath: string) => Promise<boolean>} visit - return false to stop.
 * @returns {Promise<void>}
 */
async function walk(root, visit) {
  /** @type {string[]} */
  const queue = [root];
  while (queue.length > 0) {
    const current = queue.pop();
    let entries;
    try {
      entries = await readdir(current, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of entries) {
      const abs = join(current, entry.name);
      if (entry.isDirectory()) {
        if (PRUNED_DIRECTORIES.has(entry.name)) continue;
        queue.push(abs);
        continue;
      }
      if (!entry.isFile()) continue;
      const keepGoing = await visit(abs, relative(root, abs).split(sep).join('/'));
      if (keepGoing === false) return;
    }
  }
}

/**
 * Register the two tools.
 * @param {object} ctx - plugin context.
 * @param {object} config - resolved plugin config.
 */
export function apply(ctx, config) {
  const caps = config ?? { globMaxResults: 100, grepMaxMatches: 250 };

  ctx.systemPrompt.section({
    name: 'tool:fs-search-js',
    order: ctx.systemPrompt.getSectionOrder('TOOL_GLOB') ?? 600,
    text: ({ scope }) => (ctx.tools.get('glob', scope) === void 0
      ? ''
      : 'The `glob` and `grep` tools here are pure-JavaScript implementations of the usual file search. `grep` patterns use JavaScript regular-expression syntax.'),
  });

  ctx.tools.register(defineTool({
    name: 'glob',
    description: 'Find files whose paths match a glob pattern, newest first.',
    parameters: {
      pattern: { type: 'string', required: true, description: 'Glob pattern, e.g. "src/**/*.ts". Matches POSIX-style paths relative to the search root.' },
      path: { type: 'string', description: 'Directory to search. Defaults to the workspace root.' },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          root: { type: 'string', required: true },
          count: { type: 'number', required: true },
          files: { type: 'array', required: true, items: { type: 'object', additionalProperties: false, properties: { path: { type: 'string', required: true }, mtimeMs: { type: 'number', required: true } } } },
          truncated: { type: 'boolean', required: true },
        },
      },
      render: (_args, value) => [{
        type: 'text',
        text: value.files.length === 0
          ? `No files matched in ${value.root}`
          : `${String(value.count)}${value.truncated ? `+ (capped at ${String(caps.globMaxResults)})` : ''} file(s) under ${value.root}:\n${
            value.files.map((file) => file.path).join('\n')}`,
      }],
    },
    async execute(args, exec) {
      const pattern = typeof args?.pattern === 'string' ? args.pattern.trim() : '';
      if (pattern === '') throw new Error('glob: pattern must be a non-empty string');
      const root = await resolveRoot(ctx, args?.path, exec);
      const matcher = compileGlob(pattern);
      /** @type {{ path: string, mtimeMs: number }[]} */
      const found = [];
      let truncated = false;
      await walk(root, async (abs, rel) => {
        if (!matcher.test(rel)) return true;
        let info;
        try {
          info = await stat(abs);
        } catch {
          return true;
        }
        found.push({ path: rel, mtimeMs: info.mtimeMs });
        if (found.length > caps.globMaxResults) {
          truncated = true;
          found.pop();
          return false;
        }
        return true;
      });
      found.sort((a, b) => b.mtimeMs - a.mtimeMs);
      return { root, count: found.length, files: found, truncated };
    },
    presentCall: (args) => ({ card: 'generic', title: `Glob ${String(args?.pattern ?? '')}` }),
  }));

  ctx.tools.register(defineTool({
    name: 'grep',
    description: 'Search file contents with a JavaScript regular expression. Returns matching lines with line numbers, grouped by file.',
    parameters: {
      pattern: { type: 'string', required: true, description: 'JavaScript regular-expression source (not ripgrep syntax).' },
      path: { type: 'string', description: 'Directory or file to search. Defaults to the workspace root.' },
      include: { type: 'string', description: 'One glob filter for which files to search (e.g. "*.ts").' },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          root: { type: 'string', required: true },
          totalMatches: { type: 'number', required: true },
          files: { type: 'array', required: true, items: { type: 'object', additionalProperties: false, properties: { path: { type: 'string', required: true }, matches: { type: 'array', required: true, items: { type: 'object', additionalProperties: false, properties: { line: { type: 'number', required: true }, text: { type: 'string', required: true } } } } } } },
          truncated: { type: 'boolean', required: true },
        },
      },
      render: (_args, value) => [{
        type: 'text',
        text: value.files.length === 0
          ? `No matches in ${value.root}`
          : value.files.map((file) => `${file.path}\n${file.matches.map((match) => `  ${String(match.line)}: ${match.text}`).join('\n')}`).join('\n\n'),
      }],
    },
    async execute(args, exec) {
      const source = typeof args?.pattern === 'string' ? args.pattern : '';
      if (source === '') throw new Error('grep: pattern must be a non-empty string');
      /** @type {RegExp} */
      let matcher;
      try {
        matcher = new RegExp(source);
      } catch (error) {
        throw new Error(`grep: invalid regular expression: ${error.message}`);
      }
      const root = await resolveRoot(ctx, args?.path, exec);
      const include = typeof args?.include === 'string' && args.include.trim() !== '' ? compileGlob(args.include.trim()) : undefined;
      /** @type {{ path: string, matches: { line: number, text: string }[] }[]} */
      const files = [];
      let totalMatches = 0;
      let truncated = false;

      const scanFile = async (abs, rel) => {
        if (include !== undefined && !include.test(rel)) return true;
        let info;
        try {
          info = await stat(abs);
        } catch {
          return true;
        }
        if (info.size > MAX_GREP_FILE_BYTES) return true;
        let text;
        try {
          text = await readFile(abs, 'utf8');
        } catch {
          return true;
        }
        if (text.includes('\u0000')) return true; // binary
        const matches = [];
        const lines = text.split('\n');
        for (let index = 0; index < lines.length; index += 1) {
          if (!matcher.test(lines[index])) continue;
          matches.push({ line: index + 1, text: lines[index].slice(0, 500) });
          totalMatches += 1;
          if (totalMatches >= caps.grepMaxMatches) {
            truncated = true;
            break;
          }
        }
        if (matches.length > 0) files.push({ path: rel, matches });
        return !truncated;
      };

      const rootInfo = await stat(root);
      if (rootInfo.isFile()) await scanFile(root, root);
      else await walk(root, scanFile);

      return { root, totalMatches, files, truncated };
    },
    presentCall: (args) => ({ card: 'generic', title: `Grep ${String(args?.pattern ?? '')}` }),
  }));
}

/**
 * Resolve the search root: an explicit path, else the workspace root.
 * @param {object} ctx - plugin context.
 * @param {unknown} requested - the model's `path` argument.
 * @param {object} exec - the tool execution identity.
 * @returns {Promise<string>} an absolute path.
 */
async function resolveRoot(ctx, requested, exec) {
  if (typeof requested === 'string' && requested.trim() !== '') {
    const base = await workspaceRoot(ctx, exec);
    return isAbsolute(requested) ? resolve(requested) : resolve(base, requested);
  }
  return workspaceRoot(ctx, exec);
}

/**
 * The session's workspace root, falling back to the process cwd.
 * `dsh-working-directory` exposes `ensure(agent, signal)` (validated + recovery)
 * and `get(session)` (no I/O); the upstream search tool uses `ensure`.
 * @param {object} ctx - plugin context.
 * @param {object} exec - the tool execution identity.
 * @returns {Promise<string>} an absolute path.
 */
async function workspaceRoot(ctx, exec) {
  if (exec?.agent === undefined) return process.cwd();
  try {
    const ensured = await ctx.workingDirectory.ensure(exec.agent, exec.signal);
    if (typeof ensured === 'string' && ensured !== '') return ensured;
  } catch { /* fall through to cwd */ }
  try {
    const current = ctx.workingDirectory.get(exec.agent.session);
    if (typeof current === 'string' && current !== '') return current;
  } catch { /* fall through to cwd */ }
  return process.cwd();
}
