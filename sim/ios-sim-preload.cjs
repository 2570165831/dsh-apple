// ios-sim preload: simulate the iOS runtime restrictions on a macOS Node.
//
// Loaded with `node --require <this file>` (or `--import` for ESM) BEFORE dsh.
// It does NOT try to be a kernel sandbox. It only reproduces the four runtime
// capabilities iOS takes away from an embedded Node:
//
//   1. loading any native `.node` addon                    -> process.dlopen throws
//   2. starting any child process                          -> child_process throws
//   3. writing outside the app sandbox / DSH_HOME          -> warn (and optionally throw)
//   4. no WebAssembly / no JIT                             -> handled by `--jitless`, logged here
//
// Every block is written to $IOS_SIM_LOG (default logs/ios-sim-events.jsonl) as
// one JSON object per line, so the report can cite exactly which attempts the
// profile made. The log is append-only and line-buffered.

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const util = require('node:util');

const WORKSPACE = process.env.IOS_SIM_WORKSPACE
  || path.resolve(__dirname, '..');
const SANDBOX = process.env.IOS_SIM_SANDBOX
  || path.join(WORKSPACE, 'sandbox');
const DSH_HOME = process.env.DSH_HOME || '';
const LOG_PATH = process.env.IOS_SIM_LOG
  || path.join(WORKSPACE, 'logs', 'ios-sim-events.jsonl');

// `module.register()` (used by sim/sim-entry.mjs for the flock redirect) starts a
// SEPARATE hooks thread inside the same process. That thread also runs the
// `--require` preloads, so without this guard every event below is recorded
// twice: once on the main thread, once on the hooks thread. Measured:
// /tmp/t2.jsonl (hook disabled) = 1 boot event; /tmp/t3.jsonl (hook enabled) = 2.
// The restrictions themselves are per-thread state, so both installs are real and
// both must happen; only the LOGGING is deduplicated by thread id.
const THREAD_ID = require('node:worker_threads').threadId;
// IOS_SIM_ENFORCE_WRITES=1 turns the write-outside-sandbox warning into a throw.
const ENFORCE_WRITES = process.env.IOS_SIM_ENFORCE_WRITES === '1';

fs.mkdirSync(path.dirname(LOG_PATH), { recursive: true });
const logFd = fs.openSync(LOG_PATH, 'a');

function note(kind, detail) {
  const record = { t: new Date().toISOString(), pid: process.pid, thread: THREAD_ID, kind, ...detail };
  let line;
  try {
    line = JSON.stringify(record) + '\n';
  } catch {
    line = JSON.stringify({ t: record.t, pid: record.pid, kind, note: 'unserializable' }) + '\n';
  }
  try {
    fs.writeSync(logFd, line);
  } catch {
    // a logging failure must never take the process down
  }
}

// ---------------------------------------------------------------- environment
const sandboxAllowed = [SANDBOX, DSH_HOME].filter((p) => p.length > 0).map((p) => {
  try { return fs.realpathSync(p); } catch { return path.resolve(p); }
});
const sandboxAllowedRaw = [SANDBOX, DSH_HOME].filter((p) => p.length > 0).map((p) => path.resolve(p));

function insideSandbox(target) {
  let resolved = path.resolve(target);
  let real = resolved;
  try { real = fs.realpathSync(resolved); } catch { /* keep lexical path for new files */ }
  for (const root of [...sandboxAllowed, ...sandboxAllowedRaw]) {
    for (const candidate of [resolved, real]) {
      if (candidate === root) return true;
      if (candidate.startsWith(root + path.sep)) return true;
    }
  }
  return false;
}

// ------------------------------------------------------------------ 1. dlopen
const realDlopen = process.dlopen;
process.dlopen = function iosSimDlopen(module, filename, flags) {
  note('dlopen.denied', { filename: String(filename) });
  const error = new Error(
    `ios-sim: native addon loading is disabled (process.dlopen blocked for ${filename})`
  );
  error.code = 'ERR_DLOPEN_FAILED';
  error.simulated = 'ios-no-native-addons';
  throw error;
};

// --------------------------------------------------------- 2. child_process
const childProcess = require('node:child_process');
const DENIED = ['spawn', 'spawnSync', 'exec', 'execSync', 'execFile', 'execFileSync', 'fork'];
for (const name of DENIED) {
  const original = childProcess[name];
  childProcess[name] = function iosSimChildProcess(...args) {
    const command = typeof args[0] === 'string' ? args[0] : String(args[0]?.file ?? args[0]);
    note('child_process.denied', { fn: name, command });
    const error = new Error(
      `ios-sim: child processes are disabled (child_process.${name}(${command}) blocked)`
    );
    error.code = 'ERR_CHILD_PROCESS_UNAVAILABLE';
    error.simulated = 'ios-no-subprocess';
    throw error;
  };
  // keep the original around for the report, without changing behaviour
  childProcess[name].__iosSimOriginal = original;
}
// `constructor` bypasses (childProcess.ChildProcess via spawn internals) are out
// of scope: the profile never reaches them, and recording the seven entry points
// is what the report needs.

// ------------------------------------------------------- 3. writes out of box
const WRITE_FLAGS = new Set(['w', 'w+', 'a', 'a+', 'wx', 'ax', 'as', 'r+', 'rs+', 'wx+', 'ax+']);
function flagWrites(flags) {
  if (flags === undefined || flags === null) return false;
  if (typeof flags === 'number') return false; // fd-based, already open
  return WRITE_FLAGS.has(String(flags));
}

function watchWrite(fnName, pathIndex) {
  return function iosSimWriteGuard(...args) {
    const target = args[pathIndex];
    if (typeof target === 'string' || target instanceof URL || Buffer.isBuffer(target)) {
      const asPath = target instanceof URL ? target.pathname : String(target);
      if (asPath.length > 0 && !insideSandbox(asPath)) {
        note('write.outside_sandbox', { fn: fnName, path: asPath, enforced: ENFORCE_WRITES });
        if (ENFORCE_WRITES) {
          const error = new Error(`ios-sim: write outside the app sandbox (${fnName} ${asPath})`);
          error.code = 'ERR_IOS_SIM_WRITE_OUTSIDE_SANDBOX';
          throw error;
        }
      }
    }
    return this;
  };
}

// Patch the fs write surface. Async fns are wrapped so the guard runs before the
// call; the callback/promise plumbing is untouched because we delegate with the
// original receiver and arguments.
const fsSync = fs;
const writeFnsSync = ['writeFileSync', 'appendFileSync', 'mkdirSync', 'rmSync', 'rmdirSync',
  'unlinkSync', 'renameSync', 'copyFileSync', 'truncateSync', 'createWriteStream'];
for (const name of writeFnsSync) {
  if (typeof fsSync[name] !== 'function') continue;
  const original = fsSync[name];
  const guard = watchWrite(name, 0);
  fsSync[name] = function iosSimGuarded(...args) {
    guard.apply(this, args);
    return original.apply(this, args);
  };
}
const writeFnsAsync = ['writeFile', 'appendFile', 'mkdir', 'rm', 'rmdir', 'unlink', 'rename',
  'copyFile', 'truncate', 'open', 'createWriteStream'];
for (const name of writeFnsAsync) {
  if (typeof fsSync[name] !== 'function') continue;
  const original = fsSync[name];
  fsSync[name] = function iosSimGuarded(...args) {
    const target = args[0];
    if (!(name === 'open' && !flagWrites(args[1]))) {
      if (typeof target === 'string' || target instanceof URL || Buffer.isBuffer(target)) {
        const asPath = target instanceof URL ? target.pathname : String(target);
        if (asPath.length > 0 && !insideSandbox(asPath)) {
          note('write.outside_sandbox', { fn: name, path: asPath, enforced: ENFORCE_WRITES });
          if (ENFORCE_WRITES) {
            const error = new Error(`ios-sim: write outside the app sandbox (${name} ${asPath})`);
            error.code = 'ERR_IOS_SIM_WRITE_OUTSIDE_SANDBOX';
            if (typeof args[args.length - 1] === 'function') {
              const callback = args[args.length - 1];
              process.nextTick(callback, error);
              return undefined;
            }
            return Promise.reject(error);
          }
        }
      }
    }
    return original.apply(this, args);
  };
}
// fs.promises is a separate object with its own function identity.
const fsp = fs.promises;
const writeFnsPromises = ['writeFile', 'appendFile', 'mkdir', 'rm', 'rmdir', 'unlink', 'rename',
  'copyFile', 'truncate', 'open'];
for (const name of writeFnsPromises) {
  if (typeof fsp[name] !== 'function') continue;
  const original = fsp[name];
  fsp[name] = function iosSimGuarded(...args) {
    let writes = true;
    if (name === 'open') writes = flagWrites(args[1]);
    const target = args[0];
    if (writes && (typeof target === 'string' || target instanceof URL || Buffer.isBuffer(target))) {
      const asPath = target instanceof URL ? target.pathname : String(target);
      if (asPath.length > 0 && !insideSandbox(asPath)) {
        note('write.outside_sandbox', { fn: `promises.${name}`, path: asPath, enforced: ENFORCE_WRITES });
        if (ENFORCE_WRITES) {
          const error = new Error(`ios-sim: write outside the app sandbox (promises.${name} ${asPath})`);
          error.code = 'ERR_IOS_SIM_WRITE_OUTSIDE_SANDBOX';
          return Promise.reject(error);
        }
      }
    }
    return original.apply(this, args);
  };
}

// ------------------------------------------------------------ 4. wasm / jitless
const execArgv = process.execArgv || [];
note('boot', {
  node: process.version,
  execArgv,
  jitless: execArgv.some((a) => a === '--jitless'),
  exposeInternals: execArgv.some((a) => a === '--expose-internals'),
  webassembly: typeof WebAssembly,
  sandbox: SANDBOX,
  dshHome: DSH_HOME,
  enforceWrites: ENFORCE_WRITES,
  realDlopenType: typeof realDlopen,
  cwd: process.cwd(),
});

if (typeof WebAssembly === 'undefined') {
  note('webassembly.absent', { reason: 'jitless runs disable WebAssembly entirely' });
}

// Surface the simulated platform to the app under test.
process.env.IOS_SIM_ACTIVE = '1';

// ------------------------------------------------------- 5. jitless polyfills
// `--jitless` removes WebAssembly, which takes Node's built-in `fetch` (undici,
// wasm llhttp) with it. Both polyfills are opt-in so the report can show the
// unfixed failure and the fixed behaviour as two separate measurements.
if (process.env.IOS_SIM_FETCH_POLYFILL !== '0') {
  const fetchPolyfill = require('./fetch-polyfill.cjs');
  const outcome = fetchPolyfill.install();
  note('polyfill.fetch', outcome);
}
if (process.env.IOS_SIM_WASM_POLYFILL !== '0') {
  const wasmPolyfill = require('./wasm-polyfill.cjs');
  const outcome = wasmPolyfill.install();
  note('polyfill.wasm', outcome);
}

// ------------------------------------------------------------- 6. Intl shim
// A Node built WITHOUT ICU (`v8_enable_i18n_support: 0`) has no `Intl` at all.
// DSH needs `Intl.DateTimeFormat` on the session-creation path: without it
// `dsh-time-context` throws "failed to resolve the system time zone" and every
// new session fails with agent-preset/invalid. Installed unconditionally (the
// shim no-ops when a real `Intl` is present), so the same preload works on a
// desktop Node where ICU exists.
if (process.env.IOS_SIM_INTL_SHIM !== '0') {
  const intlShim = require('./intl-shim.cjs');
  const outcome = intlShim.installIntl();
  note('polyfill.intl', outcome);
}

// ------------------------------------------------------- 7. TextDecoder shim
// A Node built without ICU rejects `new TextDecoder('utf-8', { fatal: true })`
// with "\"fatal\" option is not supported on Node.js compiled without ICU"
// (measured: logs/spike-probe5-textdecoder.log). dsh-fs-local uses exactly that
// form to decide whether a file is text, so without this the `read` tool reports
// "invalid UTF-8 text" for ordinary ASCII while `write` and `glob` still work.
if (process.env.IOS_SIM_TEXTDECODER_SHIM !== '0') {
  const textdecoder = require('./textdecoder-shim.cjs');
  note('polyfill.textdecoder', textdecoder.installTextDecoder());
}

note('preload.installed', { denyFns: DENIED });

// ------------------------------------------------ directories above the container
// DSH's attachment store makes a new file durable by `fsync`-ing every ancestor
// directory up to the filesystem root (`dsh-attachment-local`, `ensureDurableHome`
// -> `ensureDurableDirectory(home, parse(home).root)` -> `syncDirectory`, which
// does `fs.promises.open(dir, O_RDONLY)`). On a phone the ancestors above the app
// container (`/var/mobile/Containers/Data/Application`, `/var/mobile/Containers`,
// ...) belong to the OS: the sandbox answers EPERM to opening them, and the whole
// image admission fails as `session/agent-busy "prompt rejected"` (step 4B,
// "EPERM: operation not permitted, open '/var/mobile/Containers/Data/Application'").
// The simulator can open them, which is why this never showed there.
//
// The fix lives here rather than in DSH: for a directory that is a strict ancestor
// of this app's container, a read-only open that the OS refuses (EPERM/EACCES)
// resolves to a no-op handle. Nothing is lost: those directories are not ours, the
// entries below the container root are still synced for real, and every other
// open (or any other error) is untouched. See PATCHES.md P-11.
//
// IOS_SIM_ANCESTOR_SHIM=0 turns the fix off; IOS_SIM_FAULT_ANCESTOR_OPEN=1 makes
// opening such an ancestor fail with EPERM the way the device does, so the
// simulator can reproduce the failure (scripts/sim-ancestor-eperm-test.py).
(function installAncestorOpenShim() {
  const fsp = require('node:fs/promises');
  const containerRoot = WORKSPACE ? path.resolve(WORKSPACE, '..', '..') : '';
  if (!containerRoot) return;
  const canon = (p) => {
    let value = path.resolve(p);
    try { value = fs.realpathSync(value); } catch { /* may not exist */ }
    // `/var` resolves to `/private/var`; fold both spellings, the bare directory included.
    if (value === '/private/var') return '/var';
    return value.startsWith('/private/var/') ? value.slice('/private'.length) : value;
  };
  const root = canon(containerRoot);
  const isForeignAncestor = (p) => {
    if (typeof p !== 'string' && !(p instanceof URL)) return false;
    const target = canon(p instanceof URL ? p.pathname : p);
    // `/private` is the real parent of `/var` on device, so it is an ancestor too.
    if (target === '/private' && root.startsWith('/var/')) return true;
    return target !== root && (target === path.sep || root.startsWith(target + path.sep));
  };
  const readOnly = (flags) => flags === undefined || flags === 'r' || flags === 0 || flags === fs.constants.O_RDONLY;
  const original = fsp.open;
  const fault = process.env.IOS_SIM_FAULT_ANCESTOR_OPEN === '1';
  const fix = process.env.IOS_SIM_ANCESTOR_SHIM !== '0';
  const noop = { sync: async () => {}, close: async () => {}, [Symbol.asyncDispose]: async () => {} };
  note('ancestor_open.installed', { root, fault, fix, shimEnv: process.env.IOS_SIM_ANCESTOR_SHIM ?? null });
  fsp.open = async function open(target, flags, mode) {
    if (isForeignAncestor(target)) note('ancestor_open.seen', { path: String(target), flags: String(flags), fault, fix });
    if (!readOnly(flags) || !isForeignAncestor(target)) return original.call(this, target, flags, mode);
    try {
      if (fault) {
        const error = new Error(`EPERM: operation not permitted, open '${target}'`);
        error.code = 'EPERM'; error.errno = -1; error.syscall = 'open'; error.path = String(target);
        throw error;
      }
      return await original.call(this, target, flags, mode);
    } catch (error) {
      if (fix && (error?.code === 'EPERM' || error?.code === 'EACCES')) {
        note('ancestor_open.skipped', { path: String(target), code: error.code });
        return noop;
      }
      throw error;
    }
  };
  try { require('node:module').syncBuiltinESMExports(); } catch { /* best effort */ }
})();
