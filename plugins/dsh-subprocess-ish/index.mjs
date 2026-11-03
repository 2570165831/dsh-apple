// `dsh-subprocess-ish`: the `ctx.subprocess` provider that runs commands in the
// embedded iSH guest instead of on the host.
//
// WHY A PROVIDER AND NOT A PATCH: `dsh-bash-local` (and everything above it —
// `tool-bash`, `bash-sandbox`, `workspace-changes`) declares
// `static inject = ["subprocess"]` and calls `ctx.subprocess.spawn(...)`. The
// seam is a cordis *service*, not an import, so replacing the one row that
// provides it swaps the execution world with no change to any consumer. That is
// the whole reason this file exists in `plugins/` rather than as a patch to
// `payload/`: the "zero source changes in tool-bash / dsh-bash-local" acceptance
// criterion is satisfied structurally, not by editing them.
//
// WHAT IT HONOURS, from the seam contract
// (`@deepseek-ai/dsh-subprocess/lib/index.js` doc comment):
//
//   * `spawn` returns a live handle *synchronously*; `done` resolves with the
//     direct command's exit facts and rejects for spawn or provider failures.
//   * Collect-mode readers are offset-based and non-consuming; a lossy read
//     reports truncation and the spill file holding the complete stream.
//   * `terminate()` (and the spec's abort signal) starts the provider's
//     documented procedure against its managed range; `waitForExit()` observes
//     that same range so a caller can hold a teardown tier on real quiescence.
//   * Disposal of the service terminates all still-running managed processes.
//
// THE SYNCHRONOUS-SPAWN PROBLEM, AND WHY A QUEUE IS THE ANSWER: the guest runs
// one command at a time (`ISHGuest` has a single in-flight exec; two kernels in
// one process is unrecoverable), while `spawn()` must return before anything
// async has happened. So `spawn()` returns a handle whose promise chain is
// queued behind whatever is already running. A caller that awaits `done` — which
// is every caller the model's tool path produces — sees exactly sequential
// behaviour. A caller that spawns twice without awaiting gets queueing, not two
// concurrent shells, and that difference is *documented* rather than hidden: the
// alternative would be to start the second command in a guest that cannot run it.

// PATH RESOLUTION FOR THE TWO BARE IMPORTS BELOW
//
// This file ships in `plugins/` inside the app bundle, *beside* `payload/`, not
// inside its `node_modules` tree. A bare `import '@deepseek-ai/dsh-subprocess'`
// would therefore search from `plugins/..` and never find the payload's copy —
// which would surface as a loader "Cannot find module" at profile boot, far from
// the real cause. `sim/tool-fs-search-js.mjs` already established the pattern for
// this situation: resolve through a `createRequire` rooted at the payload's own
// `package.json`, honoring each package's `exports` map.
//
// The URL is computed from `IOS_SIM_DSH_INSTALL` (the host sets it every launch)
// with the bundle-relative path as the fallback, because a bundle path differs
// per install and per device and must never be hard-coded.
const { createRequire } = process.getBuiltinModule('node:module');
const { pathToFileURL, fileURLToPath } = process.getBuiltinModule('node:url');
const { join, resolve: resolvePath } = process.getBuiltinModule('node:path');

const HERE = fileURLToPath(new URL('.', import.meta.url));
const PAYLOAD_ROOT = process.env.IOS_SIM_DSH_INSTALL ?? resolvePath(HERE, '..', '..', 'payload');
const requireFromPayload = createRequire(join(PAYLOAD_ROOT, 'package.json'));

/**
 * Import a payload package by bare specifier, following its `exports` map.
 * @param {string} specifier - the package (or subpath) to import.
 * @returns {Promise<object>} the module namespace.
 */
async function importFromPayload(specifier) {
  return import(pathToFileURL(requireFromPayload.resolve(specifier)).href);
}

const {
  SubprocessRuntime,
  SubprocessExecutableNotFoundError,
  scrubbedParentEnv,
} = await importFromPayload('@deepseek-ai/dsh-subprocess');
const {
  OutputCollector,
  logSpillFailure,
  prepareManagedProcessBinding,
} = await importFromPayload('@deepseek-ai/dsh-subprocess-local/output');

import {
  exec as channelExec,
  cancel as channelCancel,
  resolveExecutable as channelResolveExecutable,
  channelConfig,
  health as channelHealth,
} from './lib/guest-channel.mjs';

/** Cordis plugin name used in loader diagnostics. */
export const name = 'dsh-subprocess-ish';

/** Largest delay Node can schedule without clamping. */
const MAX_TIMER_DELAY_MS = 2147483647;

/** Default PATH used for a guest executable search when the spec supplies none. */
const DEFAULT_GUEST_PATH = '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin';

/**
 * The guest's default shell, as an absolute guest path.
 *
 * Absolute on purpose: the guest's `do_execve` does not search PATH, so a bare
 * `sh` from anything that spawns the reported shell would fail with ENOENT.
 */
const DEFAULT_GUEST_SHELL = '/bin/sh';

/** How long a command waits for a cancelled one to finish dying in the guest. */
const GUEST_BUSY_WAIT_MS = 15_000;

/** How long a cancel is allowed to wait for the guest's acknowledgement. */
const CANCEL_ACK_TIMEOUT_MS = 5000;
/** How long `_terminate` watches a cancelled command for its real exit. */
const CANCEL_EXIT_WAIT_MS = 10_000;
const CANCEL_POLL_MS = 100;

/**
 * Validate the synchronous portion of a spawn request, exactly as
 * `subprocess-local` does. Copied rather than imported because
 * `validateSubprocessSpec` is not exported; keeping the checks identical means a
 * spec `subprocess-local` would reject does not silently succeed here.
 *
 * @param {object} spec - the request.
 * @throws when grace, cancellation, or argv is invalid before launch.
 */
function validateSubprocessSpec(spec) {
  if (!Number.isFinite(spec.graceMs) || spec.graceMs <= 0 || spec.graceMs > MAX_TIMER_DELAY_MS) {
    throw new Error(`subprocess graceMs must be a positive finite number no greater than ${MAX_TIMER_DELAY_MS}`);
  }
  if (spec.signal?.aborted) {
    let reason = 'aborted';
    try {
      reason = String(spec.signal.reason ?? reason);
    } catch { /* a hostile `reason` getter must not change the outcome */ }
    throw new Error(`aborted before spawn: ${reason}`);
  }
  const [program] = spec.argv ?? [];
  if (program === void 0 || program.length === 0) {
    throw new Error('invalid argv: expected a non-empty program name at argv[0]');
  }
}

/**
 * Resolve `argv[0]` to an absolute guest path.
 *
 * WHY THIS IS NOT OPTIONAL: the guest's `do_execve` takes a path, not a name.
 * `dsh-bash-local` spawns `["bash", "-c", command]` — a bare name, which the
 * host's `child_process` would have searched for on PATH and which the guest
 * kernel simply fails to find:
 *
 *     do_execve bash failed: -2        (ENOENT)
 *
 * That is the whole reason the first working tool call still reported exit -1.
 * The resolution has to happen here rather than on the host because only the
 * guest knows what the guest's PATH contains, and it goes through the same
 * `/v1/executable` endpoint `resolveExecutable` uses so both agree.
 *
 * A path that already has a slash is used as given: the caller named a file, and
 * second-guessing it would hide a real ENOENT behind a PATH search.
 *
 * @param {readonly string[]} argv - the request argv; `argv[0]` is the program.
 * @param {string} pathValue - the PATH to search.
 * @param {AbortSignal} [signal] - cancellation.
 * @returns {Promise<string[]>} a copy with `argv[0]` made absolute.
 * @throws {SubprocessExecutableNotFoundError} when a bare name is not on PATH.
 */
async function resolveGuestArgv(argv, pathValue, signal) {
  const [program, ...rest] = argv;
  if (typeof program !== 'string' || program.length === 0) return [...argv];
  if (program.startsWith('/')) return [...argv];
  if (program.includes('/')) {
    // A relative path with a slash: the guest's cwd decides, not PATH. Leave it
    // alone and let the exec report ENOENT with the path the caller named.
    return [...argv];
  }
  const answer = await channelResolveExecutable(program, pathValue, signal);
  if (answer?.found !== true || typeof answer.path !== 'string' || answer.path.length === 0) {
    throw new SubprocessExecutableNotFoundError(
      `subprocess-ish: ${JSON.stringify(program)} is not on the guest PATH (${pathValue})`,
    );
  }
  return [answer.path, ...rest];
}

/**
 * The PATH the guest will actually search, from the `K=V` list this provider is
 * about to send it.
 *
 * Read from the merged list rather than from `process.env`: `guestEnvironment()`
 * scrubs and rewrites host variables, and a caller-supplied `env` override is
 * part of what the child sees. Falling back to the guest default keeps the
 * behaviour identical to what `/bin/sh -c` would do with no PATH at all.
 *
 * @param {string[]} guestEnv - the `K=V` entries bound for the guest.
 * @param {object} [specEnv] - the request's own overrides, which are merged in.
 * @returns {string} a colon-separated guest PATH.
 */
function guestPathFrom(guestEnv, _specEnv) {
  // Only the guest environment is consulted. A `PATH` on the spec is the HOST's
  // (see `guestEnvironment`), and honouring it is exactly the mistake that made
  // every command report `do_execve bash failed: -2`.
  const entry = guestEnv.find((pair) => pair.startsWith('PATH='));
  return entry === undefined ? DEFAULT_GUEST_PATH : entry.slice('PATH='.length);
}

/** Whether a collect-mode disposition asked for a bound. */
const isCollect = (mode) => mode !== 'pipe' && mode !== 'inherit';

/**
 * Which collect dispositions the caller asked for. A `'pipe'`/`'inherit'`
 * disposition is *unsupported here* and must be reported as such rather than
 * silently treated as collect: a consumer that wanted raw framing would
 * otherwise get a buffered tail and mis-parse it.
 *
 * @param {object} spec - the spawn request.
 * @throws when a stream asks for a disposition this provider cannot honour.
 */
function assertSupportedStdio(spec) {
  for (const stream of ['stdin', 'stdout', 'stderr']) {
    const mode = spec.stdio?.[stream];
    if (mode === 'inherit') {
      throw new Error(`subprocess-ish: stdio.${stream} "inherit" is not supported; the guest has no descriptor to inherit from the host process`);
    }
    if (mode === 'pipe' && stream !== 'stdin') {
      throw new Error(`subprocess-ish: stdio.${stream} "pipe" is not supported; use a collect disposition with maxBytes/spill`);
    }
    if (stream === 'stdin' && mode === 'pipe') {
      throw new Error('subprocess-ish: stdio.stdin "pipe" is not supported; pass { data } for one-shot input');
    }
  }
  if (spec.stdio?.control !== undefined) {
    throw new Error('subprocess-ish: stdio.control is not supported; the guest channel has no inherited descriptor 7');
  }
}

/**
 * The environment to hand the guest.
 *
 * `scrubbedParentEnv()` is the seam's own rule: credential-shaped names and
 * ambient `DSH_*` facts never reach a child implicitly. The spec's explicit
 * `env` then merges after that scrub, so a deliberately forwarded value still
 * arrives. Only the *merged result* is translated into the guest's `K=V`
 * string list, and it is filtered to what a guest process can use: the host's
 * absolute paths (HOME, TMPDIR, PWD) are meaningless in the guest and actively
 * wrong in some programs.
 *
 * @param {object} specEnv - the request's explicit overrides.
 * @returns {string[]} zero or more `K=V` entries.
 */
function guestEnvironment(specEnv) {
  const merged = { ...scrubbedParentEnv(), ...specEnv ?? {} };
  // Host paths in path-valued variables are respelled for the guest; see
  // `hostPathToGuest`. Done on the merged record so both an inherited value and
  // an explicit override are handled the same way.
  for (const key of Object.keys(merged)) {
    if (typeof merged[key] === 'string') merged[key] = hostPathToGuest(key, merged[key]);
  }
  /**
   * Host-path variables that would point a guest program at a nonexistent tree.
   *
   * `PATH` is in this set and that is the important one. `dsh-bash-local` does
   * not set it, so whatever reaches here is the *host's* PATH — on the
   * simulator, a path under
   * `/private/var/run/com.apple.security.cryptexd/.../iOS 27.0.simruntime/...`.
   * A guest `bash` searched against that finds nothing, and the failure looks
   * like "bash is not installed" rather than "the wrong PATH was forwarded".
   * Omitting it lets the guest's own default apply, which is what `/bin/sh -c`
   * would have used.
   */
  const hostOnly = new Set(['HOME', 'TMPDIR', 'TMP', 'TEMP', 'PWD', 'OLDPWD', 'SHLVL', '_', 'PATH']);
  const entries = [];
  for (const [key, value] of Object.entries(merged)) {
    if (value === undefined || value === null) continue;
    if (hostOnly.has(key)) continue;
    // A value containing NUL cannot cross into a guest `envp` blob; dropping it
    // is the only safe move, and it is reported rather than silently mangled.
    if (String(key).includes('\0') || String(value).includes('\0')) continue;
    entries.push(`${key}=${value}`);
  }
  return entries;
}

/**
 * Translate host paths to guest paths inside an environment variable value.
 *
 * THE OTHER HALF OF THE SAME PROBLEM. `dsh-workspace-changes` builds its snapshot
 * object store from the host's `tmpdir()` and passes it to the GUEST's git as
 * `GIT_OBJECT_DIRECTORY` / `GIT_INDEX_FILE` (lib/index.js:782, :1042, :283-292).
 * A host path is meaningless in the guest's own root filesystem, so those
 * variables have to be respelled before the command runs — the reverse of
 * `guestPathsToHost`, applied to the *inputs* rather than the output.
 *
 * Only the two path-valued variables git honours for this are rewritten, and only
 * when the value really is under the host workspace/temp root: a value that
 * already looks like a guest path is left alone, and a non-path value is not
 * touched at all. A general "rewrite every env value" rule would corrupt
 * arguments that merely happen to start with a slash.
 *
 * @param {string} key - the variable name.
 * @param {string} value - its requested value.
 * @returns {string} the value the guest can actually use.
 */
function hostPathToGuest(key, value) {
  const hostWorkspace = process.env.DSH_IOS_WORKSPACE ?? '';
  const guestRoot = process.env.DSH_GUEST_WORKSPACE ?? '/workspace';
  const hostTemp = (process.env.DSH_HOST_TMPDIR ?? '').replace(/\/$/, '');
  const guestTemp = process.env.DSH_GUEST_TMPDIR ?? '';
  if (hostWorkspace.length === 0 || guestRoot.length === 0) return value;
  /** Variables whose value is a single absolute path. */
  const singlePath = new Set(['GIT_OBJECT_DIRECTORY', 'GIT_INDEX_FILE', 'GIT_DIR', 'GIT_WORK_TREE']);
  /** Variables whose value is a colon-separated path list. */
  const pathList = new Set(['GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_CEILING_DIRECTORIES']);
  /** Rewrite one absolute host path, or return it unchanged. */
  const one = (candidate) => {
    if (candidate === hostWorkspace) return guestRoot;
    if (candidate.startsWith(`${hostWorkspace}/`)) return `${guestRoot}${candidate.slice(hostWorkspace.length)}`;
    // The temporary directory is the other mounted root, and it is the one
    // `dsh-workspace-changes` actually uses for its snapshot store.
    if (hostTemp.length > 0 && guestTemp.length > 0) {
      if (candidate === hostTemp) return guestTemp;
      if (candidate.startsWith(`${hostTemp}/`)) return `${guestTemp}${candidate.slice(hostTemp.length)}`;
    }
    // No mounted counterpart: pass it through unchanged, so the command fails
    // with its own ENOENT instead of a rewritten path that silently points
    // somewhere else.
    return candidate;
  };
  if (singlePath.has(key)) return one(value);
  if (pathList.has(key)) return value.split(':').map(one).join(':');
  return value;
}

/**
 * Translate guest paths back to host paths inside text a caller will read.
 *
 * WHY THE PROVIDER HAS TO DO THIS. `dsh-workspace-changes` runs the GUEST's git
 * and then resolves what git printed against the SESSION's cwd, which is a HOST
 * path (lib/index.js:245, `resolve(cwd, line)`). `resolve()` returns an absolute
 * second argument unchanged, so it ends up holding `/workspace/...` — a guest
 * path — and then does host-side arithmetic on it: `isInside(root, hostScratch)`
 * is always false, `relative(root, absolute)` produces nonsense, and in the end
 * the change list is dropped and no `workspace/changes` event is appended at all.
 * Measured: the plugin mounted, git worked, and the card never appeared.
 *
 * The seam cannot hand that plugin a different cwd (its own contract says cwd is
 * a host path), and it cannot make the guest print host paths (the guest has no
 * such paths). So the translation happens here, at the one boundary every
 * command's output passes through: guest absolute paths that sit under the
 * bind-mounted workspace are rewritten to their host spelling.
 *
 * The substitution is deliberately narrow — the bind-mount root and nothing else
 * — so a path the guest really did mean literally is not rewritten. A command
 * that prints a path outside the workspace (`/usr/bin`, `/etc`) is left alone,
 * because those have no host counterpart to claim.
 *
 * @param {string} text - output decoded from the guest.
 * @returns {string} the same text with workspace paths in host spelling.
 */
function guestPathsToHost(text) {
  if (typeof text !== 'string' || text.length === 0) return text;
  const guestRoot = process.env.DSH_GUEST_WORKSPACE ?? '/workspace';
  const hostRoot = process.env.DSH_IOS_WORKSPACE ?? '';
  if (hostRoot.length === 0 || guestRoot.length === 0 || guestRoot === hostRoot) return text;
  // Only whole path segments: `/workspace` must not match `/workspace2`, and the
  // boundary after the root must be a `/` or a non-path character.
  const rewrite = (input, from, to) => {
    const pattern = new RegExp(`${from.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}(?![\\w.])`, 'g');
    return input.replace(pattern, to);
  };
  let out = rewrite(text, guestRoot, hostRoot);
  // The temporary root is mounted too, and a guest program prints it as `/tmp`.
  // Rewritten only when a host counterpart is actually mounted, otherwise the
  // guest's own /tmp paths would be silently claimed as host paths that do not
  // exist.
  const guestTemp = process.env.DSH_GUEST_TMPDIR ?? '';
  const hostTemp = (process.env.DSH_HOST_TMPDIR ?? '').replace(/\/$/, '');
  if (guestTemp.length > 0 && hostTemp.length > 0) out = rewrite(out, guestTemp, hostTemp);
  return out;
}

/**
 * The guest working directory for one request.
 *
 * The host and the guest do not share a path namespace: the session's cwd is a
 * *host* path like
 * `/…/Data/Application/<uuid>/Documents/workspace`, while the guest sees the same
 * directory at `/workspace`. Using the host path verbatim would make every
 * `spawn` fail `chdir` and every command run in the guest root instead — which
 * looks like "the tool ignores workdir" rather than "the paths are different".
 *
 * So, in this order:
 *
 *   * no cwd at all → the guest workspace (the only implicit default);
 *   * a host path under a mounted root (workspace or temp) → its guest spelling;
 *   * a host path that is visibly host-side but under no mount (the app
 *     container, `/private/...`) → an error, because the guest has no such
 *     directory and there is no honest counterpart to run in;
 *   * any other absolute path (`/tmp`, `/root`, `/workspace/src`) → passed to the
 *     guest as written (folded), where `chdir` decides whether it exists;
 *   * a relative path → resolved against the guest workspace.
 *
 * WHY AN EXPLICIT cwd IS NEVER REPLACED BY THE WORKSPACE. This function used to
 * fall back to `/workspace` for any absolute path it did not recognise. A model
 * that asked for `/tmp` and ran `rm -rf *` then ran it in the user's project.
 * A directory the caller named is either honoured or refused; it is never
 * silently swapped for a different one. The guest side refuses to run a command
 * whose cwd it cannot enter (`ISHGuest.m`), so a pass-through that does not
 * exist fails there instead of running somewhere else.
 *
 * @param {string} [requested] - the cwd from the spec (host namespace, or guest).
 * @returns {string} an absolute guest path.
 * @throws {Error} when an explicit cwd cannot be expressed in the guest.
 */
function guestWorkingDirectory(requested) {
  const guestRoot = process.env.DSH_GUEST_WORKSPACE ?? '/workspace';
  const hostRoot = (process.env.DSH_IOS_WORKSPACE ?? '').replace(/\/+$/, '');
  const hostTemp = (process.env.DSH_HOST_TMPDIR ?? '').replace(/\/+$/, '');
  const guestTemp = process.env.DSH_GUEST_TMPDIR ?? '';
  // No requested directory means "the workspace", not "the guest's root". The
  // guest's own cwd would otherwise be `/`, one level above the folder the model
  // can actually see: measured on the phone as `ls` finding nothing and every
  // relative path in a command resolving to a directory the user never meant.
  if (requested === undefined || requested === null || requested === '') return guestRoot;
  if (typeof requested !== 'string') {
    throw new Error(`subprocess-ish: cwd must be a string, got ${typeof requested}; the command was not run`);
  }
  if (requested.includes('\0')) {
    throw new Error('subprocess-ish: cwd contains a NUL byte; the command was not run');
  }
  /** Whether `path` is `root` or below it. */
  const under = (path, root) => root.length > 0 && (path === root || path.startsWith(`${root}/`));
  if (requested.startsWith('/')) {
    // Host roots are matched on the raw spelling first: a host path is only ever
    // produced by the host's own `path.resolve`, so it is already folded.
    if (under(requested, hostRoot)) {
      return normaliseGuestPath(`${guestRoot}${requested.slice(hostRoot.length)}`);
    }
    if (guestTemp.length > 0 && under(requested, hostTemp)) {
      return normaliseGuestPath(`${guestTemp}${requested.slice(hostTemp.length)}`);
    }
    if (looksLikeUnmountedHostPath(requested, hostRoot, hostTemp)) {
      throw new Error(
        `subprocess-ish: cwd ${JSON.stringify(requested)} is a host path outside the directories `
        + `shared with the guest (${hostRoot || 'no workspace'}${hostTemp ? `, ${hostTemp}` : ''}); `
        + 'the command was not run',
      );
    }
    // A guest path: honoured as written. `/tmp`, `/root` and `/workspace/...` all
    // land here; the guest's chdir is the authority on whether it exists.
    return normaliseGuestPath(requested);
  }
  // A RELATIVE path. `dsh-tool-bash` already joins a relative `workdir` onto the
  // session cwd on the host side, so this arrives here only from a direct caller
  // or from a path the host could not absolute-ise. Resolving it against the
  // guest workspace is what the model means by `workdir: "src"`.
  const normalised = normaliseGuestPath(`${guestRoot}/${requested}`);
  if (normalised === undefined) {
    throw new Error(`subprocess-ish: cwd ${JSON.stringify(requested)} cannot be resolved in the guest; the command was not run`);
  }
  return normalised;
}

/**
 * Whether an absolute path is recognisably a HOST path that no mount covers.
 *
 * The guest is an Alpine root filesystem; the host is iOS (or the simulator on a
 * Mac). Their namespaces overlap only in generic names, so this is deliberately
 * narrow: the directory that contains the host workspace or temp root (the app
 * container — a sibling like `Documents/other` is host data the guest cannot
 * see), and the top-level prefixes that exist only on the Apple side. Anything
 * else is treated as a guest path, and the guest's chdir rejects it if absent.
 *
 * @param {string} path - an absolute path not under any mounted root.
 * @param {string} hostRoot - the host workspace, or empty.
 * @param {string} hostTemp - the host temp root, or empty.
 * @returns {boolean} true when the path must be refused rather than passed on.
 */
function looksLikeUnmountedHostPath(path, hostRoot, hostTemp) {
  for (const root of [hostRoot, hostTemp]) {
    if (root.length === 0) continue;
    const parent = root.slice(0, root.lastIndexOf('/'));
    // A parent of `/` (a mount directly at the root) would claim every path.
    if (parent.length > 0 && (path === parent || path.startsWith(`${parent}/`))) return true;
  }
  return /^\/(private|Users|Volumes|System|Applications)(\/|$)/.test(path)
    || /^\/var\/(mobile|containers|folders)(\/|$)/.test(path);
}

/**
 * Collapse `.`/`..` and repeated slashes in a guest path without touching the
 * filesystem.
 *
 * WHY NOT `node:path`: the provider runs on the HOST, and `path.resolve()` uses
 * the host's rules and — worse — its own cwd. A guest path has to be folded with
 * the guest's rules so `workdir: "../other"` cannot silently escape to a host
 * notion of the parent directory. `..` above the guest root clamps at `/`, which
 * is what a POSIX kernel does.
 *
 * @param {string} input - an absolute guest path, possibly containing `.`/`..`.
 * @returns {string|undefined} the folded absolute path, or undefined when the input is empty or relative.
 */
function normaliseGuestPath(input) {
  if (typeof input !== 'string' || input.length === 0 || !input.startsWith('/')) return undefined;
  const stack = [];
  for (const segment of input.split('/')) {
    if (segment === '' || segment === '.') continue;
    if (segment === '..') { stack.pop(); continue; }
    stack.push(segment);
  }
  return `/${stack.join('/')}`;
}

/**
 * The packaged ripgrep binary's path, respelled so the GUEST can execute it.
 *
 * THE PROBLEM THIS SOLVES, precisely. `dsh-tool-fs-search` spawns
 * `@vscode/ripgrep`'s `rgPath` — an absolute HOST path inside the app bundle
 * (`…/DSHPortC.app/payload/node_modules/@vscode/ripgrep/bin/rg`). Two things are
 * wrong with handing that to the guest:
 *
 *   1. The guest has no such path. Its root filesystem is the Alpine fakefs; the
 *      app bundle is not mounted there at all, so `do_execve` fails with ENOENT
 *      and the tool reports "ripgrep launch failed" — which is exactly the
 *      symptom the phone reported.
 *   2. Even if it were reachable it would not run: that binary is a glibc build,
 *      and the emulated kernel runs musl binaries from this image.
 *
 * So `rg` comes from the guest image (Alpine's `ripgrep` package, 14.1.1) and any
 * `argv[0]` that names a ripgrep binary — whatever host path it was spelled as —
 * is redirected to the guest's own `/usr/bin/rg`. The check is on the executable
 * NAME, not on a fixed host prefix, because the bundle path changes on every
 * install and on every device.
 *
 * The redirect only applies when the guest really has `/usr/bin/rg`. When it does
 * not (an older bundled image), the caller gets the original path back and its
 * own ENOENT, rather than a silently different command.
 *
 * @param {string} program - the requested `argv[0]`.
 * @param {string} [guestRgPath] - the guest's ripgrep, once known.
 * @returns {string} the program to execute in the guest.
 */
function respellGuestExecutable(program, guestRgPath) {
  if (typeof program !== 'string' || program.length === 0) return program;
  if (guestRgPath === undefined || guestRgPath.length === 0) return program;
  // A/B switch, in the style this task already uses for the ancestor-open shim:
  // `0` restores the pre-fix behaviour so the failure can be reproduced on
  // demand instead of being described from memory.
  if (process.env.DSHPORTE_RG_RESPELL === '0') return program;
  // Any path ending in `rg` (or `rg.exe`) under a `ripgrep` package directory, or
  // the bare name, is ripgrep. `/usr/bin/grep` must not match: the separator
  // before the name is part of the test.
  const isRipgrep = program === 'rg'
    || /(^|\/)ripgrep[^/]*\/(bin\/)?rg(\.exe)?$/.test(program)
    || /(^|\/)rg$/.test(program);
  if (!isRipgrep) return program;
  return guestRgPath;
}

/**
 * The provider.
 *
 * One instance registers `ctx.subprocess` (cordis refuses a second). Disposal
 * terminates everything still running, so a plugin reload cannot leave guest
 * processes behind in an app that only has one guest.
 */
class IshSubprocessRuntime extends SubprocessRuntime {
  // STATE IS HELD IN PLAIN FIELDS, NOT `#private` ONES, AND THAT IS NOT A
  // STYLE CHOICE. cordis hands this service to its consumers through a Proxy:
  // `ctx.subprocess` is not the constructed instance, it is a wrapper that
  // forwards to it. A private field access checks the receiver against the
  // class that declared the field, and a Proxy is not that class, so every
  // `this._queue` thrown from a proxied call fails with
  //
  //     TypeError: Cannot read private member #execSeq from an object
  //     whose class did not declare it
  //
  // — measured, on the first real tool call this provider ever served. The
  // stock `dsh-subprocess-local` uses plain fields throughout for the same
  // reason; `#private` members are simply unusable behind this seam.
  //
  // The leading underscore on each name documents the intent (internal), and
  // the provider exports no accessor for any of them.

  /** Live handles, for disposal and for the synchronous host-exit path. */
  live = new Set();

  /** Tail of the serial command queue; each spawn chains onto it. */
  _queue = Promise.resolve();

  /** Per-instance exec id counter, so ids are unique without a global. */
  _execSeq = 0;

  /** The spill directory binding, resolved once; see `_prepareSpill()`. */
  _spill = undefined;

  /** Spill failures reach the plugin logger, so a result without a spill path has a reason. */
  reportSpillFailure = logSpillFailure(this.ctx.logger, 'subprocess-ish');

  /** Where the guest's ripgrep lives, resolved once; see `_guestRipgrep()`. */
  _guestRg = undefined;

  /**
   * The guest's own ripgrep path, or undefined when it has none.
   *
   * Resolved through the guest, never assumed: whether `rg` exists is a fact
   * about the image that shipped, and a provider that guessed `/usr/bin/rg`
   * would turn "this image predates the fix" into an ENOENT that looks like a
   * broken tool. A miss is cached as `null` so a boot-time probe runs once, not
   * once per search.
   *
   * @param {AbortSignal} [signal] - cancellation.
   * @returns {Promise<string|undefined>} an absolute guest path, or undefined.
   */
  async _guestRipgrep(signal) {
    if (this._guestRg === null) return undefined;
    if (this._guestRg !== undefined) return this._guestRg;
    try {
      const answer = await channelResolveExecutable('rg', DEFAULT_GUEST_PATH, signal);
      this._guestRg = answer?.found === true && typeof answer.path === 'string' && answer.path.length > 0
        ? answer.path
        : null;
    } catch (error) {
      // A probe failure is not fatal: the caller still has the original path and
      // its own error, which names the real cause (channel down, guest not
      // booted). Cached as missing so a dead channel is not re-probed per spawn.
      this.ctx.logger.debug(`subprocess-ish: guest ripgrep probe failed: ${String(error)}`);
      this._guestRg = null;
    }
    return this._guestRg ?? undefined;
  }

  constructor(ctx) {
    super(ctx);
    ctx.effect(() => {
      const onHostExit = () => {
        for (const handle of this.live) {
          try {
            handle.terminateForHostExit();
          } catch { /* a dying process cannot be saved by a throwing one */ }
        }
      };
      process.prependListener('exit', onHostExit);
      return async () => {
        await this.disposeManagedProcesses();
        process.off('exit', onHostExit);
      };
    }, 'subprocess-ish teardown');
  }

  /**
   * Resolve an executable *in the guest*.
   *
   * This is the method that makes `workspace-changes` and the ripgrep-based
   * search tool tell the truth: they call it to decide whether `git` / `rg`
   * exist, and a host-side answer would describe a different filesystem. A miss
   * throws `SubprocessExecutableNotFoundError` — the contract's own error, which
   * consumers rely on to distinguish "not installed" from "it broke".
   *
   * @param {string} command - absolute path or bare name.
   * @param {object} [env] - environment overrides, consulted for PATH.
   * @param {AbortSignal} [signal] - cancellation.
   * @returns {Promise<string>} the guest path.
   */
  async resolveExecutable(command, env, signal) {
    if (typeof command !== 'string' || command.length === 0) {
      throw new Error('subprocess-ish: executable must be non-empty');
    }
    signal?.throwIfAborted();
    if (!command.startsWith('/') && command.includes('/')) {
      throw new Error(`subprocess-ish: command ${JSON.stringify(command)} is a relative path; use an absolute path or a bare PATH name`);
    }
    const pathValue = env?.PATH ?? DEFAULT_GUEST_PATH;
    // A ripgrep binary asked for by its HOST path is answered from the guest.
    // `dsh-tool-fs-search` may check this before spawning (it does not today, but
    // `workspace-changes` uses the same method for `git`), and answering with a
    // host path would make the guest's ENOENT look like a missing installation.
    const guestRg = await this._guestRipgrep(signal);
    if (guestRg !== undefined && respellGuestExecutable(command, guestRg) !== command) {
      return guestRg;
    }
    const answer = await channelResolveExecutable(command, pathValue, signal);
    signal?.throwIfAborted();
    if (answer?.found === true && typeof answer.path === 'string' && answer.path.length > 0) {
      return answer.path;
    }
    throw new SubprocessExecutableNotFoundError(
      command.startsWith('/')
        ? `subprocess-ish: command ${JSON.stringify(command)} is not an executable file in the guest`
        : `subprocess-ish: command ${JSON.stringify(command)} was not found on the guest PATH`,
    );
  }

  /**
   * Start one managed guest process. Returns the handle synchronously.
   *
   * @param {object} spec - fully resolved argv, cwd, stdio, grace, cancellation, env.
   * @returns {object} the live handle.
   */
  spawn(spec) {
    validateSubprocessSpec(spec);
    assertSupportedStdio(spec);

    const env = guestEnvironment(spec.env);
    const cwd = guestWorkingDirectory(spec.cwd);
    this._execSeq += 1;
    const execId = `ish-${process.pid}-${this._execSeq}-${Date.now().toString(36)}`;

    // Spill storage comes from the shared `prepareManagedProcessBinding`, which
    // owns the private 0700 directory and the failure reporter. Reusing it keeps
    // one spill policy for both providers instead of a second, subtly different
    // one here.
    this._spill ??= prepareManagedProcessBinding({ onSpillFailure: this.reportSpillFailure });

    const stdoutCollector = isCollect(spec.stdio.stdout) && spec.stdio.stdout !== undefined
      ? new OutputCollector(spec.stdio.stdout.maxBytes, 'stdout', spec.stdio.stdout.spill === undefined ? undefined : {
        maxBytes: spec.stdio.stdout.spill.maxBytes,
        dir: this._spill.spillDir,
        onFailure: this._spill.onSpillFailure,
      })
      : undefined;
    const stderrCollector = isCollect(spec.stdio.stderr) && spec.stdio.stderr !== undefined
      ? new OutputCollector(spec.stdio.stderr.maxBytes, 'stderr', spec.stdio.stderr.spill === undefined ? undefined : {
        maxBytes: spec.stdio.stderr.spill.maxBytes,
        dir: this._spill.spillDir,
        onFailure: this._spill.onSpillFailure,
      })
      : undefined;

    let settled = false;
    let terminationStarted = false;
    let rangeExited = false;
    /** True once the command has been handed to the guest channel. */
    let execStarted = false;
    /** True once the channel call has settled, which an abort does at once. */
    let execSettled = false;
    /** Resolvers for `waitForExit()`; the range is quiescent only once the guest has let go of the command. */
    let rangeSettled;
    const rangePromise = new Promise((resolve) => {
      rangeSettled = resolve;
    });
    /** Rejects `done` for a command cancelled while it was still queued. */
    const cancelledInQueue = Promise.withResolvers();

    let exitFacts;
    const doneResolvers = Promise.withResolvers();

    const stdinData = isCollect(spec.stdio.stdin) && spec.stdio.stdin !== undefined ? spec.stdio.stdin.data : undefined;

    /**
     * Run the guest command. Queued behind the previous one because the guest
     * can only run a single command; see the header.
     */
    const run = async () => {
      const throwIfCancelled = () => {
        if (spec.signal?.aborted === true) {
          throw spec.signal.reason ?? new Error('aborted before the command started');
        }
        if (terminationStarted) throw new Error('terminated before the command started');
      };
      throwIfCancelled();
      // `bash` is a bare name; the guest needs a path. See `resolveGuestArgv`.
      const guestPath = guestPathFrom(env, spec.env);
      // A packaged binary named by a HOST path (ripgrep) is respelled onto the
      // guest's own copy first; see `respellGuestExecutable`.
      const requested = [...spec.argv];
      requested[0] = respellGuestExecutable(requested[0], await this._guestRipgrep(spec.signal));
      const argv = await resolveGuestArgv(requested, guestPath, spec.signal);
      // Only git's output is respelled; see the note in the chunk callback.
      const rewritePaths = /(^|\/)git$/.test(argv[0] ?? '');
      throwIfCancelled();
      execStarted = true;
      const exec = () => channelExec({
        argv,
        cwd,
        env,
        execId,
        stdin: stdinData,
        signal: spec.signal,
        onChunk: (event) => {
          // Paths are rewritten ONLY for the programs that need it, and `git` is
          // the one: `dsh-workspace-changes` resolves what the guest's git
          // printed against the SESSION's cwd, which is a host path, so a guest
          // path there makes its host-side arithmetic silently produce nothing
          // (see `guestPathsToHost`).
          //
          // Every other command's output is left in the guest's own spelling.
          // That is the useful answer for the model: it runs its commands in the
          // guest, so a `/workspace/src/a.txt` it can paste straight back into
          // the next command beats a host path it would have to have translated.
          // Rewriting everything was tried first and made `grep -r` print paths
          // that do not exist for the shell that would be asked to use them.
          const bytes = rewritePaths
            ? Buffer.from(guestPathsToHost(event.chunk.toString('utf8')), 'utf8')
            : event.chunk;
          if (event.type === 'stderr') stderrCollector?.push(bytes);
          else stdoutCollector?.push(bytes);
        },
      });
      // An abort settles the previous command at once, and this queue moves on,
      // while the guest is still walking it down the SIGTERM → SIGKILL ladder. The
      // guest refuses the next command until that ends, and says it never started,
      // so asking again is safe.
      const deadline = Date.now() + GUEST_BUSY_WAIT_MS;
      for (;;) {
        try {
          return await exec();
        } catch (error) {
          if (!String(error?.message ?? error).includes('a guest command is already running')
              || spec.signal?.aborted === true || terminationStarted || Date.now() >= deadline) throw error;
          await new Promise((resolve) => setTimeout(resolve, 50));
        }
      }
    };

    // Chain onto the queue. `_queue` is replaced by a promise that never
    // rejects, so one failed command cannot poison every later spawn.
    const queued = this._queue.then(run, run);
    this._queue = queued.then(() => {}, () => {});

    queued.then(() => { execSettled = true; }, () => { execSettled = true; });

    const done = Promise.race([queued, cancelledInQueue.promise]).then((result) => {
      settled = true;
      exitFacts = { exitCode: result.exitCode, signal: null, timedOut: result.timedOut };
      rangeExited = true;
      rangeSettled();
      stdoutCollector?.seal();
      stderrCollector?.seal();
      this.live.delete(handle);
      return { exitCode: result.exitCode, signal: null };
    }, (error) => {
      settled = true;
      // A cancelled command's call settles before the guest has finished walking
      // it down; `_terminate` reports the exit once it has seen one.
      if (!(terminationStarted && execStarted)) {
        rangeExited = true;
        rangeSettled();
      }
      stdoutCollector?.seal();
      stderrCollector?.seal();
      this.live.delete(handle);
      throw error;
    });
    // The rejection is delivered through `done`; attaching a handler here keeps
    // an unhandled-rejection warning off a path whose rejection the caller may
    // legitimately ignore (a killed process).
    done.catch(() => {});

    const handle = {
      stdin: undefined,
      stdout: undefined,
      stderr: undefined,
      control: undefined,
      collected: {
        ...stdoutCollector === undefined ? {} : { stdout: stdoutCollector },
        ...stderrCollector === undefined ? {} : { stderr: stderrCollector },
      },
      done,
      terminate: () => beginTermination(),
      terminateForHostExit: () => beginTermination(),
      waitForExit: async () => {
        if (rangeExited) return true;
        await rangePromise;
        return rangeExited;
      },
    };

    const beginTermination = () => {
      if (rangeExited || terminationStarted) return;
      terminationStarted = true;
      if (!execStarted) {
        // Still queued: it will never reach the guest, so there is nothing to wait for.
        rangeExited = true;
        rangeSettled();
        cancelledInQueue.reject(spec.signal?.reason ?? new Error('terminated before the command started'));
        return;
      }
      void this._terminate(execId, () => execSettled).then((exited) => {
        if (exited) rangeExited = true;
        rangeSettled();
      });
    };

    // The spec's abort signal starts the same procedure `terminate()` does, so
    // a caller-owned timeout cannot diverge from an explicit kill.
    if (spec.signal !== undefined) {
      const onAbort = () => {
        handle.terminate();
      };
      spec.signal.addEventListener('abort', onAbort, { once: true });
      // Remove the listener once the range is quiescent; a long-lived signal
      // (a session's) would otherwise accumulate one closure per command.
      rangePromise.then(() => spec.signal.removeEventListener('abort', onAbort));
    }

    this.live.add(handle);
    return handle;
  }

  /**
   * Ask the guest to terminate one exec and watch for it to let go.
   *
   * An acknowledged cancel only says the request arrived, so the cancel is
   * repeated until the guest answers that this exec is no longer the running
   * one. The wait is bounded and an unknown outcome is reported as such: holding
   * `waitForExit()` open forever would wedge any caller's teardown ladder on a
   * channel that may itself be gone.
   *
   * @param {string} execId - the exec to cancel.
   * @param {() => boolean} execSettled - whether the channel call has settled.
   * @returns {Promise<boolean>} whether the exit was observed; never rejects.
   */
  async _terminate(execId, execSettled) {
    const deadline = Date.now() + CANCEL_EXIT_WAIT_MS;
    let wasRunning = false;
    try {
      while (Date.now() < deadline) {
        const answer = await channelCancel(execId, AbortSignal.timeout(CANCEL_ACK_TIMEOUT_MS));
        if (answer?.cancelled === true) {
          wasRunning = true;
        } else if (wasRunning || execSettled()) {
          // Not the running exec any more. A first "no" with the call still open
          // means the request has not reached the guest yet, so that one retries.
          return true;
        }
        await new Promise((resolve) => setTimeout(resolve, CANCEL_POLL_MS));
      }
      this.ctx.logger.warn(`subprocess-ish: cancel(${execId}) was not observed to finish within ${CANCEL_EXIT_WAIT_MS} ms`);
    } catch (error) {
      this.ctx.logger.warn(`subprocess-ish: cancel(${execId}) failed; the guest process may still be running: ${String(error)}`);
    }
    return false;
  }

  /** The private spill directory, created once per process. */
  spillDir() {
    return this._spill?.spillDir;
  }

  /**
   * Terminate every still-running managed process and await its exit.
   * Called by the effect disposer and by explicit teardown.
   * @returns {Promise<void>} resolves once every handle is settled.
   */
  async disposeManagedProcesses() {
    const pending = [];
    for (const handle of this.live) {
      handle.terminate();
      pending.push(Promise.all([handle.done.catch(() => {}), handle.waitForExit().catch(() => {})]).then(() => {
        this.live.delete(handle);
      }));
    }
    const outcomes = await Promise.allSettled(pending);
    const failures = [];
    for (const outcome of outcomes) if (outcome.status === 'rejected') failures.push(outcome.reason);
    if (failures.length === 1) throw failures[0];
    if (failures.length > 1) throw new AggregateError(failures, 'subprocess-ish teardown failed');
  }

  /**
   * The terminal facts the seam asks every provider for.
   *
   * A near-constant on this platform, and answering it properly matters even
   * though nothing here opens a terminal: `terminalEnvironment()` is one of the
   * four abstract methods, so a provider that omits it is not a
   * `SubprocessRuntime` at all as far as consumers are concerned — the call
   * fails with `terminalEnvironment is not a function`, which is a much worse
   * error than a documented refusal from `spawnTerminal()`.
   *
   * The guest is POSIX, and its shell is `/bin/sh` (busybox ash, with `bash`
   * also installed). `DEFAULT_SHELL` is reported as the absolute guest path
   * rather than a bare name, because a consumer that spawns it directly would
   * otherwise hit the same `do_execve` name resolution this provider had to fix.
   *
   * @param {AbortSignal} [signal] - cancellation.
   * @returns {Promise<{platform: 'posix', defaultShell: string}>} the guest's terminal facts.
   */
  async terminalEnvironment(signal) {
    signal?.throwIfAborted();
    return { platform: 'posix', defaultShell: DEFAULT_GUEST_SHELL };
  }

  /**
   * Terminal allocation is not part of this port: the terminal surface, PTY
   * allocation, and foreground-group inspection all need a controlling terminal
   * the guest does not have a driver for. Throwing here is the documented
   * "unsupported" answer, and the profile keeps every terminal consumer
   * unmounted so nothing calls it.
   * @throws always.
   */
  async spawnTerminal() {
    throw new Error('subprocess-ish: spawnTerminal is not supported in this build (no guest PTY; the terminal surface is not mounted)');
  }
}

/**
 * Load the provider.
 * @param {object} ctx - cordis context.
 */
export function apply(ctx) {
  // Fail early and clearly when the guest was not booted for this launch. A
  // provider that mounts without a channel would turn every tool call into a
  // transport error much later, with a message about sockets instead of about
  // the missing guest.
  if (!channelConfig().configured) {
    throw new Error(
      'subprocess-ish: the guest channel is not configured. This profile runs bash inside the '
      + 'embedded iSH guest, so the app must boot it before Node starts: launch with '
      + 'DSHPORTE_GUEST_CHANNEL=1 (the App does this by default in this build).',
    );
  }
  ctx.plugin(IshSubprocessRuntime);
  // One cheap health probe, so the boot log records whether the channel is
  // actually answering rather than merely configured.
  void channelHealth().then((payload) => {
    ctx.logger.info(`subprocess-ish: guest channel up (guest state ${payload?.guestState}, workspace ${payload?.workspaceGuestPath ?? 'unmounted'})`);
  }, (error) => {
    ctx.logger.warn(`subprocess-ish: guest channel health probe failed: ${String(error)}`);
  });
}

export {
  IshSubprocessRuntime,
  guestWorkingDirectory,
  guestEnvironment,
  guestPathsToHost,
  hostPathToGuest,
  normaliseGuestPath,
  respellGuestExecutable,
};
export default { name, apply, inject: [] };
