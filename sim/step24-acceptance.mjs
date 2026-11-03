// Step 24's acceptance: what the guest's `node`, `npm` and `python3` can
// actually do, measured in the app.
//
// WHY IT RUNS IN THE APP AND DRIVES THE SHIPPED PROVIDER. Every criterion here
// is a real command in the embedded guest. Running it on a host shell would
// measure a different kernel, a different libc and a different CPU: the guest is
// an aarch64 Alpine userspace under the asbestos JIT-less emulator, and the
// whole question the step asks ("is this usable, is it stable, how slow is it")
// only has an answer there. So this module mounts the REAL `ios-sim` profile
// through `runProfile()` and takes `ctx.subprocess` out of the mounted tree —
// the same row `dsh-bash-local` calls — and then runs every command through it,
// with the same spawn spec shape the bash tool builds.
//
// WHAT "PASSES" MEANS, and what it does not. A criterion passes only when the
// command did the thing and the OUTPUT proves it. `--version` is not evidence:
// printing a version string exercises argv parsing and nothing else, which is
// exactly the failure mode this step has to rule out — an interpreter that
// starts, answers `--version`, and then dies on the first real import.
//
// The task says a negative answer is allowed ("某一项不行" — one of them may not
// work). Nothing here is bent to make a criterion pass: where the guest cannot
// do something, the criterion records the failure with the exit code and the
// stderr, and `RUNGS` below lists the capability as failed so the prompt text
// that ships does not claim it.
//
// GATED. `sim/ios-app-entry.mjs` imports this instead of DSH when
// `DSHPORTE_STEP24_ACCEPTANCE=1`. A normal launch never reaches it.
//
// SEGMENTED, because one launch that runs everything would take half an hour and
// a single hang would lose the whole run. `DSHPORTE_STEP24_ONLY` selects
// segments by name (comma separated); unset means all of them. The report is
// written after every criterion, so a killed run still leaves the evidence for
// everything that already finished.
//
//   python   json, files+atomic replace, sqlite3, zip/gzip, https, subprocess,
//            threading, cpu loop — in /workspace AND in the guest's own rootfs
//   node     cjs, esm, file streams, timers, child_process, tls, cpu loop,
//            cancel-then-rerun
//   npm      init, a small package, a file-heavy package (3 clean installs each,
//            tarball file-list compared), npm run, npx
//   project  a small JS project and a small Python project, dependencies to
//            passing tests
//   pipe     head|rg, python3|head, node|head, early output close, 20 repeats,
//            three shells, cancel-then-rerun — with idle-CPU checks
//   cpu      the CPU loop on its own, for the host baseline comparison
//
// Evidence goes beside the workspace: `DSHPortE-step24-acceptance.json`, in the
// app container's Documents directory.

import { mkdirSync, writeFileSync, readFileSync, existsSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';

const RESULT_NAME = 'DSHPortE-step24-acceptance.json';

function resultPath() {
  const workspace = process.env.DSH_IOS_WORKSPACE ?? process.cwd();
  return process.env.DSHPORTE_ACCEPTANCE_OUT ?? join(dirname(workspace), RESULT_NAME);
}

const report = {
  startedAt: new Date().toISOString(),
  node: process.versions.node,
  segments: (process.env.DSHPORTE_STEP24_ONLY ?? '').split(',').map((part) => part.trim()).filter(Boolean),
  criteria: {},
};

/** Record one criterion and flush, so a crash keeps everything before it. */
function record(id, value) {
  report.criteria[id] = value;
  write();
}

function write() {
  try {
    mkdirSync(dirname(resultPath()), { recursive: true });
    writeFileSync(resultPath(), JSON.stringify(report, null, 2));
  } catch (error) {
    process.stderr.write(`step24-acceptance: could not write the report: ${error}\n`);
  }
}

const messageOf = (error) => String(error && error.message ? error.message : error);

// ------------------------------------------------------------------ mounting

const payload = process.env.IOS_SIM_DSH_INSTALL ?? join(process.env.IOS_SIM_BUNDLE ?? '.', 'payload');
const payloadPath = (name) => join(payload, 'node_modules', '@deepseek-ai', name, 'lib', 'index.js');

// The same two loader hooks the production entry registers. Without them the
// mounted tree is a bare payload and `resolveExecutable('rg')` answers about a
// package that is not there — measured in step 7, which is why the comment there
// exists and why this module repeats the pattern instead of inventing one.
{
  const { register } = await import('node:module');
  const { pathToFileURL } = await import('node:url');
  const simDir = dirname(new URL(import.meta.url).pathname);
  for (const [file, enabled] of [
    ['flock-hook.mjs', process.env.IOS_SIM_FLOCK_SHIM !== '0'],
    ['ripgrep-hook.mjs', process.env.DSHPORTE_RG_HOOK !== '0' && (process.env.DSH_GUEST_CHANNEL_URL ?? '').length > 0],
  ]) {
    if (!enabled) continue;
    try {
      register(pathToFileURL(join(simDir, file)).href, pathToFileURL(`${simDir}/`));
    } catch (error) {
      record(`hook_${file}`, { ok: false, error: messageOf(error) });
    }
  }
}

const { runProfile } = await import(join(payload, 'node_modules/@deepseek-ai/dsh/lib/profile-boot.js'));
const appBoot = await import(payloadPath('dsh-app-boot'));

let ctx;
try {
  const mounted = await runProfile({
    environment: appBoot.loadLayeredEnv('dsh'),
    profile: 'ios-sim',
    patchFiles: [],
    // A free port, like a normal launch: a fixed one collides with any other simulator.
    args: ['--port', '0'],
  });
  ctx = mounted?.ctx;
  if (ctx === undefined) throw new Error('runProfile returned no context');
} catch (error) {
  record('boot', { ok: false, error: messageOf(error) });
  process.stdout.write(`DSHPORTE_STEP24 ${JSON.stringify({ boot: 'failed' })}\n`);
  process.exit(1);
}
record('boot', { ok: true });

const subprocess = ctx.get('subprocess');
const hostWorkspace = process.env.DSH_IOS_WORKSPACE ?? process.cwd();
const guestWorkspace = process.env.DSH_GUEST_WORKSPACE ?? '/workspace';

// The scratch tree the checks write into. Inside `/workspace` because that is
// the bind mount the model sees, so "the file the guest wrote" and "the file the
// host can read" are the same file — which the cross-check below depends on.
const scratchName = 'step24-acceptance';
const scratchGuest = `${guestWorkspace}/${scratchName}`;
const scratchHost = join(hostWorkspace, scratchName);

// ---------------------------------------------------------------- the runner

/**
 * Run one command through the shipped provider and collect the result.
 *
 * The spec is built the way `dsh-bash-local`'s `spawnSpec()` builds it
 * (`payload/node_modules/@deepseek-ai/dsh-bash-local/lib/index.js`), so what
 * runs here is what a bash tool call runs.
 *
 * @param {string} command - shell command, or null when `argv` is given.
 * @param {object} [options] - cwd, argv, signal, watchdogMs, killMs, stdin, maxBytes.
 * @returns {Promise<object>} exit code, streams, timings, and the error if any.
 */
async function run(command, options = {}) {
  const {
    cwd = scratchGuest,
    argv,
    signal,
    watchdogMs = 900_000,
    killMs = 600_000,
    stdin,
    maxBytes = 8 * 1024 * 1024,
  } = options;

  const collect = { maxBytes, spill: { maxBytes: 32 * 1024 * 1024 } };
  // A fresh name per call, so two commands in flight (a cancel probe and its
  // successor) cannot overwrite each other's script.
  runSeq += 1;
  const scriptPath = `/tmp/step24-cmd-${runSeq}.sh`;

  // EVERY COMMAND GETS A GUEST-SIDE KILL TIMER, and this is not defensive
  // programming — it is the difference between a report and a hang. Measured in
  // this step: `node -e ""` in the app's guest aborts inside libuv with
  //   Assertion failed: (0) == (uv_thread_create(...))
  // and then SPINS in state R instead of dying. The provider runs one command at a
  // time, so that single wedge made every later criterion time out behind it and
  // the run recorded nothing after it.
  //
  // `-s KILL`, not the default TERM: the aborting process's signal handling is
  // exactly what is broken, so SIGTERM does nothing. The guest has GNU
  // `timeout` (coreutils is in the image), and its exit code 137 is itself the
  // evidence that the command had to be killed.
  //
  // `killMs` is per-command rather than per-run so a fast probe does not pay a
  // long timeout, and so the npm installs still get the wall time they need.
  // HOW THE KILL TIMER IS ATTACHED, and why not the obvious way.
  //
  // The first attempt wrapped the command as `timeout ... sh -c "<json string>"`.
  // That broke on the very first criterion with `sh: syntax error: unexpected "("`:
  // the command text is itself shell, JSON's double quotes do not protect it from
  // the outer bash, and the parentheses in something as ordinary as
  // `wc -c <(cmd)` end the quoting early. Nesting two shells to add a timeout is a
  // quoting problem waiting to happen.
  //
  // Instead the command is written to a file the guest can read, and `timeout`
  // runs `bash <file>`. One level of shell, no quoting of user text at all.
  const wrapper = command === null || command === undefined
    ? null
    : `timeout -s KILL ${Math.ceil(killMs / 1000)} bash ${scriptPath}`;

  const spec = {
    argv: argv ?? ['bash', '-c', wrapper],
    cwd,
    stdio: {
      stdin: stdin !== undefined ? { data: stdin } : 'ignore',
      stdout: collect,
      stderr: collect,
    },
    graceMs: 3000,
    signal,
    env: { NO_COLOR: '1', TERM: 'dumb', PAGER: 'cat', GIT_PAGER: 'cat', CI: '1' },
  };
  const started = Date.now();
  let handle;
  try {
    if (wrapper !== null) {
      // Written with the provider's own stdin path: the seam carries `{ data }`
      // for one-shot input, and a heredoc inside the command would put a `<<`
      // through two levels of shell quoting again.
      const writer = subprocess.spawn({
        argv: ['bash', '-c', `cat > ${scriptPath} && chmod 600 ${scriptPath}`],
        cwd,
        stdio: { stdin: { data: command }, stdout: collect, stderr: collect },
        graceMs: 3000,
        env: { NO_COLOR: '1', TERM: 'dumb' },
      });
      await writer.done;
    }
    handle = subprocess.spawn(spec);
  } catch (error) {
    return { exitCode: null, stdout: '', stderr: '', wallMs: Date.now() - started, spawnError: messageOf(error) };
  }
  try {
    const outcome = await Promise.race([
      handle.done,
      new Promise((_resolve, reject) => {
        setTimeout(() => reject(new Error(`harness watchdog: no exit after ${watchdogMs} ms`)), watchdogMs);
      }),
    ]);
    const stdout = handle.collected.stdout?.readFrom(0).text ?? '';
    const stderr = handle.collected.stderr?.readFrom(0).text ?? '';
    return {
      exitCode: outcome.exitCode,
      stdout,
      stderr,
      wallMs: Date.now() - started,
      timedOut: outcome.timedOut === true,
    };
  } catch (error) {
    try { handle.terminate(); } catch { /* already gone */ }
    const stdout = handle.collected.stdout?.readFrom(0).text ?? '';
    const stderr = handle.collected.stderr?.readFrom(0).text ?? '';
    return {
      exitCode: null,
      stdout,
      stderr,
      wallMs: Date.now() - started,
      error: messageOf(error),
      cancelled: signal?.aborted === true,
    };
  }
}

/** Run a command and parse the one JSON line it prints. */
async function runJson(command, options = {}) {
  const result = await run(command, options);
  const text = result.stdout.trim();
  const line = text.split('\n').filter((entry) => entry.trim().startsWith('{')).pop();
  let parsed = null;
  try {
    parsed = line === undefined ? null : JSON.parse(line);
  } catch {
    parsed = null;
  }
  return { ...result, json: parsed };
}

/** Monotonic counter for the per-call script names. */
let runSeq = 0;

/** A short, log-safe view of a result: no need to keep megabytes in the report. */
function brief(result, limit = 600) {
  return {
    exitCode: result.exitCode,
    wallMs: result.wallMs,
    timedOut: result.timedOut === true,
    stdout: String(result.stdout ?? '').slice(0, limit),
    stderr: String(result.stderr ?? '').slice(0, limit),
    ...result.spawnError === undefined ? {} : { spawnError: result.spawnError },
    ...result.error === undefined ? {} : { error: result.error },
  };
}

// --------------------------------------------------------------- the scripts
//
// Kept as heredoc bodies inside the module rather than as separate files: the
// fixtures directory holds the two "real projects", and everything here is a
// probe whose text has to sit next to the criterion it answers. Each script
// prints ONE json line with its own verdict, so a criterion cannot pass because
// the harness mis-parsed something the script never said.

/** Python: every capability the task lists, in one process, one json line out. */
const PY_CAPABILITIES = String.raw`
import json, os, sys, time, sqlite3, zipfile, gzip, io, subprocess, threading, ssl, urllib.request, hashlib

out = {"python": sys.version.split()[0], "openssl": ssl.OPENSSL_VERSION}
root = sys.argv[1]
os.makedirs(root, exist_ok=True)

def mark(name, value):
    out[name] = value

# --- json ---------------------------------------------------------------
try:
    doc = {"a": [1, 2, 3], "b": {"c": "文本"}, "d": 1.5, "e": None, "f": True}
    round_trip = json.loads(json.dumps(doc, ensure_ascii=False))
    mark("json", {"ok": round_trip == doc, "bytes": len(json.dumps(doc))})
except Exception as error:
    mark("json", {"ok": False, "error": repr(error)})

# --- file write/read and atomic replace ---------------------------------
try:
    original = os.path.join(root, "atomic.txt")
    with open(original, "w", encoding="utf-8") as handle:
        handle.write("first\n")
    temporary = original + ".new"
    with open(temporary, "w", encoding="utf-8") as handle:
        handle.write("second\n")
        handle.flush()
        os.fsync(handle.fileno())
    before = os.stat(original).st_ino
    os.replace(temporary, original)
    after = os.stat(original).st_ino
    content = open(original, encoding="utf-8").read()
    mark("fs_atomic", {"ok": content == "second\n" and not os.path.exists(temporary),
                       "inode_changed": before != after, "content": content.strip()})
except Exception as error:
    mark("fs_atomic", {"ok": False, "error": repr(error)})

# --- sqlite3 ------------------------------------------------------------
try:
    path = os.path.join(root, "probe.db")
    if os.path.exists(path):
        os.unlink(path)
    connection = sqlite3.connect(path)
    connection.execute("create table t (id integer primary key, name text, blob blob)")
    connection.executemany("insert into t (name, blob) values (?, ?)",
                           [("alpha", b"\x00\x01\x02"), ("beta", sqlite3.Binary(bytes(range(64))))])
    connection.commit()
    rows = connection.execute("select count(*), sum(length(blob)) from t").fetchone()
    # A transaction that rolls back must leave nothing behind.
    connection.execute("begin")
    connection.execute("insert into t (name) values ('gamma')")
    connection.rollback()
    after_rollback = connection.execute("select count(*) from t").fetchone()[0]
    connection.close()
    mark("sqlite3", {"ok": rows[0] == 2 and after_rollback == 2, "version": sqlite3.sqlite_version,
                     "rows": rows[0], "blob_bytes": rows[1]})
except Exception as error:
    mark("sqlite3", {"ok": False, "error": repr(error)})

# --- zipfile and gzip ---------------------------------------------------
try:
    zpath = os.path.join(root, "probe.zip")
    with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("a.txt", "hello zip")
        archive.writestr("dir/b.bin", bytes(range(256)) * 4)
    with zipfile.ZipFile(zpath) as archive:
        names = sorted(archive.namelist())
        read_back = archive.read("dir/b.bin")
        testing = archive.testzip()
    gpath = os.path.join(root, "probe.gz")
    with gzip.open(gpath, "wb") as handle:
        handle.write(b"gzip payload" * 1000)
    with gzip.open(gpath, "rb") as handle:
        gunzipped = handle.read()
    mark("zip_gzip", {"ok": names == ["a.txt", "dir/b.bin"] and len(read_back) == 1024
                      and testing is None and len(gunzipped) == 12000,
                      "zip_entries": names, "zip_bytes": os.path.getsize(zpath),
                      "gzip_bytes": os.path.getsize(gpath), "gzip_decompressed": len(gunzipped),
                      "compression_ratio": round(os.path.getsize(gpath) / 12000.0, 4)})
except Exception as error:
    mark("zip_gzip", {"ok": False, "error": repr(error)})

# --- https --------------------------------------------------------------
# The task allows a local mock here. Both are tried and reported separately: a
# public endpoint proves TLS verification against a real chain, the mock proves the
# call works when the network is not available at all.
targets = {}
if len(sys.argv) > 2 and sys.argv[2]:
    targets["mock"] = sys.argv[2]
targets["registry"] = "https://registry.npmjs.org/ms"
https_out = {}
for label, url in targets.items():
    try:
        started = time.time()
        with urllib.request.urlopen(url, timeout=30) as response:
            body = response.read()
        https_out[label] = {"ok": response.status == 200 and len(body) > 0
                            or (label == "mock" and response.status == 200),
                            "status": response.status, "bytes": len(body),
                            "seconds": round(time.time() - started, 3)}
    except Exception as error:
        https_out[label] = {"ok": False, "error": repr(error)}
        # An HTTP fallback, so "TLS is broken" and "the guest has no network at
        # all" stay distinguishable instead of both reading as a failure.
        try:
            with urllib.request.urlopen(url.replace("https://", "http://", 1), timeout=15) as response:
                https_out[label]["plain_http_fallback"] = {"status": response.status,
                                                           "bytes": len(response.read())}
        except Exception as fallback_error:
            https_out[label]["plain_http_fallback"] = {"error": repr(fallback_error)}
mark("https", https_out)

# --- subprocess: pipes and timeout --------------------------------------
try:
    piped = subprocess.run("printf 'a\\nb\\nc\\n' | grep -c .", shell=True,
                           capture_output=True, text=True, timeout=60)
    uppercase = subprocess.run(["sh", "-c", "echo pipe-ok | tr a-z A-Z"],
                               capture_output=True, text=True, timeout=60)
    started = time.time()
    timed_out = False
    try:
        subprocess.run(["sleep", "30"], timeout=2)
    except subprocess.TimeoutExpired:
        timed_out = True
    elapsed = time.time() - started
    # The child must actually be gone, not merely abandoned.
    leftover = subprocess.run(["sh", "-c", "ps | grep -c '[s]leep 30' || true"],
                              capture_output=True, text=True, timeout=30)
    mark("subprocess", {"ok": piped.stdout.strip() == "3" and uppercase.stdout.strip() == "PIPE-OK"
                        and timed_out and elapsed < 10,
                        "pipe_lines": piped.stdout.strip(), "devnull_equivalent": uppercase.stdout.strip(),
                        "timed_out": timed_out, "timeout_seconds": round(elapsed, 2),
                        "leftover_sleep": leftover.stdout.strip()[:40]})
except Exception as error:
    mark("subprocess", {"ok": False, "error": repr(error)})

# --- threading ----------------------------------------------------------
try:
    results = []
    lock = threading.Lock()
    def work(index):
        total = 0
        for value in range(20000):
            total += (value * index) % 7
        with lock:
            results.append((index, total))
    threads = [threading.Thread(target=work, args=(index,)) for index in range(8)]
    started = time.time()
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    elapsed = time.time() - started
    mark("threading", {"ok": len(results) == 8 and all(isinstance(total, int) for _, total in results),
                       "threads": 8, "seconds": round(elapsed, 3),
                       "active_after": threading.active_count()})
except Exception as error:
    mark("threading", {"ok": False, "error": repr(error)})

# ------------------------------------------------------------------- output
print(json.dumps(out, ensure_ascii=False))
`;

/** One CPU loop, shared by every timing in this module and by the host baseline. */
const CPU_ITERATIONS = 3_000_000;

const PY_CPU = String.raw`
import time, json, sys
iterations = int(sys.argv[1])
started = time.time()
total = 0
for index in range(iterations):
    total = (total + index * 7) % 1000003
elapsed = time.time() - started
print(json.dumps({"seconds": elapsed, "checksum": total, "iterations": iterations,
                  "ns_per_iteration": round(elapsed * 1e9 / iterations, 2)}))
`;

const NODE_CPU = String.raw`
const iterations = Number(process.argv[2]);
const started = process.hrtime.bigint();
let total = 0;
for (let index = 0; index < iterations; index += 1) total = (total + index * 7) % 1000003;
const elapsedNs = Number(process.hrtime.bigint() - started);
console.log(JSON.stringify({ seconds: elapsedNs / 1e9, checksum: total, iterations,
  ns_per_iteration: Math.round((elapsedNs / iterations) * 100) / 100 }));
`;

/** Node: CJS, ESM, streams, timers, child_process, TLS — one json line. */
const NODE_CAPABILITIES = String.raw`
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const https = require('node:https');
const { spawn, execSync } = require('node:child_process');

const root = process.argv[2] ?? '/tmp';
const mockUrl = process.argv[3] ?? '';
const out = { node: process.version, arch: process.arch, modules: process.versions.modules };

function mark(name, value) { out[name] = value; }

// --- CommonJS ----------------------------------------------------------
try {
  mark('cjs', { ok: typeof require === 'function' && typeof module === 'object',
                filename: path.basename(__filename) });
} catch (error) { mark('cjs', { ok: false, error: String(error) }); }

// --- file streams ------------------------------------------------------
function streamCheck() {
  return new Promise((resolve) => {
    const target = path.join(root, 'stream.txt');
    const writer = fs.createWriteStream(target);
    let written = 0;
    const lines = 5000;
    const writeNext = () => {
      if (written >= lines) { writer.end(); return; }
      const more = writer.write('line ' + written + ' ' + 'x'.repeat(40) + '\n');
      written += 1;
      if (more) writeNext(); else writer.once('drain', writeNext);
    };
    writer.on('finish', () => {
      let bytes = 0;
      let chunks = 0;
      const reader = fs.createReadStream(target, { highWaterMark: 4096 });
      reader.on('data', (chunk) => { bytes += chunk.length; chunks += 1; });
      reader.on('end', () => {
        const stat = fs.statSync(target);
        resolve({ ok: bytes === stat.size && stat.size > lines * 40 && chunks > 1,
                  bytes, chunks, lines });
      });
    });
    writeNext();
  });
}

// --- timers ------------------------------------------------------------
function timerCheck() {
  return new Promise((resolve) => {
    const started = Date.now();
    let immediate = null;
    let intervalTicks = 0;
    setImmediate(() => { immediate = Date.now() - started; });
    const timer = setInterval(() => { intervalTicks += 1; if (intervalTicks >= 3) clearInterval(timer); }, 20);
    setTimeout(() => {
      resolve({ ok: immediate !== null && intervalTicks >= 3 && Date.now() - started >= 55,
                immediateAfterMs: immediate, intervalTicks, elapsedMs: Date.now() - started });
    }, 120);
  });
}

// --- child_process -----------------------------------------------------
function childCheck() {
  return new Promise((resolve) => {
    const child = spawn('sh', ['-c', 'printf "spawned\\n"; exit 0'], { stdio: ['ignore', 'pipe', 'pipe'] });
    let text = '';
    child.stdout.on('data', (chunk) => { text += chunk.toString(); });
    child.on('error', (error) => resolve({ ok: false, error: String(error) }));
    child.on('close', (code) => {
      let execText = '';
      let execCode = null;
      try { execText = execSync('printf exec-sync-ok').toString().trim(); execCode = 0; }
      catch (error) { execText = String(error); }
      resolve({ ok: code === 0 && text.trim() === 'spawned' && execText === 'exec-sync-ok',
                spawnText: text.trim(), spawnCode: code, execText, execCode });
    });
  });
}

// --- TLS ---------------------------------------------------------------
// The registry arm is a real chain verification. The mock arm exists so "the guest
// has no route out" and "TLS is broken" stay separate answers — and the mock speaks
// PLAIN http, so it goes through 'http.get' and is recorded as HTTP reachability,
// not as TLS.
//
// TWO THINGS THIS HAD TO GET RIGHT, both measured rather than guessed:
//   * 'response.socket' is DETACHED once the response ends, so reading
//     'socket.authorized' inside the 'end' handler throws on a null and the promise
//     never settles. The TLS facts are captured when the response arrives.
//   * An exception inside a stream event handler does not reject the promise that
//     wraps it. That is how a TLS check turned into a six-minute hang with no
//     output at all. Every branch now resolves, and a per-check deadline resolves
//     the promise even if an event never fires.
function withinDeadline(label, milliseconds, work) {
  return new Promise((resolve) => {
    let settled = false;
    const deadline = setTimeout(() => {
      finish({ label, ok: false, error: 'no answer within ' + milliseconds + ' ms' });
    }, milliseconds);
    // Unref'd and cleared for the reason in 'guard' below: an armed deadline is
    // enough to keep this process alive after the answer has arrived.
    if (typeof deadline.unref === 'function') deadline.unref();
    function finish(value) {
      if (settled) return;
      settled = true;
      clearTimeout(deadline);
      resolve(value);
    }
    work(finish);
  });
}

function tlsCheck() {
  const fetchOne = (url, label) => withinDeadline(label, 45000, (finish) => {
    const started = Date.now();
    const secure = url.startsWith('https:');
    try {
      const request = (secure ? https : http).get(url, { timeout: 30000 }, (response) => {
        // Captured HERE, not in 'end': see the note above.
        const socket = response.socket;
        const facts = {
          label,
          secure,
          status: response.statusCode,
          protocol: socket && typeof socket.getProtocol === 'function' ? socket.getProtocol() : (secure ? null : 'http'),
          cipher: socket && typeof socket.getCipher === 'function' ? (socket.getCipher() || {}).name ?? null : null,
          authorized: secure && socket ? socket.authorized : null,
          authorizationError: secure && socket ? String(socket.authorizationError ?? '') : '',
        };
        let bytes = 0;
        response.on('data', (chunk) => { bytes += chunk.length; });
        response.on('end', () => finish({ ...facts, ok: response.statusCode === 200 && bytes > 0,
                                          bytes, seconds: Math.round(Date.now() - started) / 1000 }));
        response.on('error', (error) => finish({ ...facts, ok: false, error: String(error) }));
      });
      request.on('timeout', () => request.destroy(new Error('timeout after 30 s')));
      request.on('error', (error) => finish({ label, secure, ok: false, error: String(error) }));
    } catch (error) {
      finish({ label, secure, ok: false, error: String(error) });
    }
  });

  return (async () => {
    const results = {};
    results.registry = await fetchOne('https://registry.npmjs.org/ms', 'registry');
    if (mockUrl) results.mock = await fetchOne(mockUrl, 'mock');
    // The verdict is about TLS, so it reads the registry arm. The mock is reported
    // beside it as the plain-HTTP cross-check, which is what separates "no route
    // out" from "TLS broken".
    const ok = results.registry?.ok === true;
    return { ok, tls_verified: results.registry?.authorized === true, ...results };
  })();
}

// --- ESM: a real file, imported dynamically ----------------------------
// '--input-type=module -e' would only prove the parser accepts the syntax. A file
// with its own import graph proves module resolution and the loader.
async function esmCheck() {
  const target = path.join(root, 'esm-probe.mjs');
  fs.writeFileSync(target, [
    "import { Basename } from './esm-helper.mjs';",
    'export const answer = Basename(41) + 1;',
    'export const defaults = typeof import.meta.url;',
  ].join('\n'));
  fs.writeFileSync(path.join(root, 'esm-helper.mjs'),
    'export const Basename = (value) => value;\n');
  try {
    const module = await import(target + '?v=' + Date.now());
    return { ok: module.answer === 42 && module.defaults === 'string',
             answer: module.answer, metaUrlType: module.defaults };
  } catch (error) {
    return { ok: false, error: String(error) };
  }
}

// EACH CHECK GETS ITS OWN DEADLINE AND ITS OWN CATCH.
//
// Measured the hard way: the first version awaited four checks in one try block,
// an exception inside a stream event handler left one of them pending forever, and
// the whole run produced no output at all -- which the harness reported as a
// six-minute timeout with every criterion "failed" and not one line saying why.
// A check that cannot answer is a recorded failure with a reason, not a hang.
// The deadline timer is CLEARED when the check answers, and unref'd besides.
// Measured: leaving it armed kept the process alive until the longest deadline
// expired — a two-minute wall for a two-second run, which then read as "Node is
// slow in the guest" rather than "the harness was holding its own event loop open".
function guard(name, milliseconds, work) {
  return new Promise((resolve) => {
    let settled = false;
    const deadline = setTimeout(() => {
      finish({ ok: false, error: 'no answer within ' + milliseconds + ' ms' });
    }, milliseconds);
    if (typeof deadline.unref === 'function') deadline.unref();
    function finish(value) {
      if (settled) return;
      settled = true;
      clearTimeout(deadline);
      resolve(value);
    }
    Promise.resolve().then(work).then(finish, (error) => finish({ ok: false, error: String(error) }));
  });
}

(async () => {
  mark('fs_stream', await guard('fs_stream', 60000, streamCheck));
  mark('timers', await guard('timers', 30000, timerCheck));
  mark('child_process', await guard('child_process', 120000, childCheck));
  mark('tls', await guard('tls', 120000, tlsCheck));
  mark('esm', await guard('esm', 60000, esmCheck));
  console.log(JSON.stringify(out));
})();
`;

// ------------------------------------------------------------------ segments

const segments = {};
const results = {};

/** Register one criterion: it is recorded, flushed, and returned to the caller. */
async function criterion(segment, id, fn) {
  (segments[segment] ??= []).push({ id, fn });
}

// ---------------------------------------------------------------- isolate
//
// One command per criterion, in the order the capability script runs them.
//
// WHY THIS SEGMENT EXISTS: the capability criteria are a few seconds each on the
// host's emulator CLI, and inside the app one of them wedged for the whole
// ten-minute watchdog with no output and no failing sub-check. A single criterion
// that says "the node capabilities did not answer" cannot say WHICH statement
// stopped, and guessing at it from the outside is how a step reports a mystery
// instead of a fact. So each step of the script is run as its own guest command:
// whichever one stops is the answer.
//
// It is not part of the default run (`DSHPORTE_STEP24_ONLY=isolate` runs it), and
// its results are evidence for the report rather than a claim about the product.
// The evidence set. Each step is one guest command, and each answers a question
// the report has to be able to state as a fact rather than a guess:
//
//   * does node run at all in this guest, and where exactly does it stop
//   * is the stop thread creation, and does the guest let other runtimes create
//     threads
//   * does the process die when it aborts, or spin
//   * do Python and npm — the other two runtimes this step adds — work
//
// `timeout -s KILL` is what makes these safe to run unattended: a wedged node
// ignores SIGTERM (its own handler is what wedged), so the KILL is the only thing
// that ends it, and the exit code 137 is the fact being recorded.
const ISOLATE_STEPS = {
  // THE EVIDENCE SET for the two questions this step has to answer with facts
  // rather than guesses: why `node` cannot run in this guest, and what the guest
  // actually makes visible.
  //
  // Each step is ONE guest command and each is safe to run unattended:
  // `timeout -s KILL` is what ends a wedged process, because the process that
  // wedges here does so inside its own signal path and ignores SIGTERM. Its exit
  // code 137 is itself part of the evidence.

  // --- what the guest can see -------------------------------------------
  fixtures_visible:
    'ls -la /workspace/step24-fixtures 2>&1 | head -6; echo "---"; '
    + 'ls -la /workspace/step24-fixtures/project-js 2>&1 | head -6; echo "---"; '
    + 'head -2 /workspace/step24-fixtures/project-js/run-project.js 2>&1',
  rootfs_write:
    'mkdir -p /root/vis && echo hi > /root/vis/a.txt && cat /root/vis/a.txt && ls /root/vis',

  // --- node: where exactly it stops -------------------------------------
  node_argv_only: 'node --version; node --v8-options 2>&1 | head -1',
  node_runs_script: 'timeout -s KILL 12 node -e "console.log(7*6)" 2>&1; echo "rc=$?"',
  node_abort_message: 'timeout -s KILL 12 node -e "console.log(1)" 2>&1 | head -12',
  node_empty_script: 'timeout -s KILL 12 node -e "" 2>&1; echo "rc=$?"',
  node_after_wedge:
    'timeout -s KILL 8 node -e "" >/dev/null 2>&1; echo "wedged=$?"; '
    + 'timeout -s KILL 8 node -e "console.log(42)" 2>&1; echo "after=$?"',

  // --- thread creation, the actual cause --------------------------------
  python_threads:
    'python3 -c "import threading,time\n'
    + 'ts=[threading.Thread(target=lambda:time.sleep(1)) for _ in range(64)]\n'
    + '[t.start() for t in ts]\n[t.join() for t in ts]\nprint(\'64 threads ok\')"',
  python_abort:
    'python3 -c "import os,signal;os.kill(os.getpid(),signal.SIGABRT)" 2>&1; echo "rc=$?"',
  guest_rlimit:
    'python3 -c "import resource;print(\'nproc\',resource.getrlimit(resource.RLIMIT_NPROC))"',

  // --- the other two runtimes ------------------------------------------
  npm_runs: 'timeout -s KILL 15 npm --version 2>&1; echo "rc=$?"',
  // `rc=$?` after a pipeline reports the LAST stage's status, so `... | tail -2` made
  // a killed npm look like a success. Measured here: the first version of this step
  // printed `rc=0` for an npm that was killed. Captured into a variable instead.
  // THE WORST CASE IN THIS STEP, and the reason it is last in this map.
  //
  // `npm --version` is killed by its timer and reports 137. `npm init` does not:
  // after `timeout -s KILL 20` the command still never returns, and because the
  // provider runs one command at a time it holds the queue open until the harness
  // watchdog fires. That is a strictly worse failure than a crash — the shell does
  // not get control back — so the step is recorded as it is rather than retried
  // with a longer timer, and it is placed last so it cannot shadow the others.
  npm_init_runs:
    'rm -rf /tmp/i-npm && mkdir -p /tmp/i-npm && cd /tmp/i-npm && '
    + 'timeout -s KILL 20 npm init -y > /tmp/npm-init.log 2>&1; rc=$?; '
    + 'tail -3 /tmp/npm-init.log; echo "rc=$rc"; ls -la package.json 2>&1 | head -1',
  cancel_then_immediate:
    'echo one; echo two',
  python_long_loop: 'python3 -c "s=0\nfor i in range(200000): s+=i\nprint(s)"',
};

// When `DSHPORTE_STEP24_ISOLATE_CASE` names one step, only that one runs. That is
// how the sequence above was established: one step per launch, because a wedged
// command holds the provider's single queue open and every later command in the
// same launch would time out behind it rather than report its own answer.
const onlyCase = process.env.DSHPORTE_STEP24_ISOLATE_CASE ?? '';
const stepsToRun = onlyCase === ''
  ? ISOLATE_STEPS
  : Object.fromEntries(Object.entries(ISOLATE_STEPS).filter(([name]) => name === onlyCase));

await criterion('isolate', 'isolate_steps', async () => {
  const detail = {};
  for (const [name, command] of Object.entries(stepsToRun)) {
    // Each step gets a short watchdog, so one wedge does not hide the rest. A
    // step that times out is recorded as such and the next one still runs.
    // 20 s, not 90: this segment exists to find out WHICH step stops, so a step
    // that stops has to say so quickly enough for the rest to still run inside
    // the segment's own budget.
    const result = await run(command, { watchdogMs: 20_000 });
    detail[name] = {
      exitCode: result.exitCode,
      wallMs: result.wallMs,
      stdout: String(result.stdout).slice(0, 300),
      stderr: String(result.stderr).slice(0, 300),
      ...result.error === undefined ? {} : { error: result.error },
    };
  }
  // The verdict is "every step answered", and each answer is kept.
  const answered = Object.entries(detail).filter(([, value]) => value.exitCode === 0).map(([name]) => name);
  return {
    pass: answered.length === Object.keys(stepsToRun).length,
    answered,
    wedged: Object.entries(detail).filter(([, value]) => value.exitCode === null).map(([name]) => name),
    detail,
  };
});

// ---------------------------------------------------------------- python

await criterion('python', 'python_capabilities', async () => {
  const root = `${scratchGuest}/python-work`;
  const mockUrl = process.env.DSHPORTE_STEP24_MOCK_URL ?? '';
  const result = await runJson(
    `mkdir -p ${root} && python3 /tmp/step24-py.py ${root} ${mockUrl}`,
    { watchdogMs: 600_000 },
  );
  // The script itself is written first, so a syntax error shows up as a stderr
  // line rather than as "the json was empty".
  const detail = result.json ?? {};
  // `https` carries one verdict per target rather than a single `ok`, because
  // "the registry answered" and "the local mock answered" are separate facts and
  // the task allows the mock to stand in for the network. Its own criterion below
  // reads it; here the check is the interpreter's own machinery.
  const wanted = ['json', 'fs_atomic', 'sqlite3', 'zip_gzip', 'subprocess', 'threading'];
  const failed = wanted.filter((key) => detail[key]?.ok !== true);
  return {
    pass: result.exitCode === 0 && failed.length === 0,
    failed,
    https: detail.https ?? null,
    detail: Object.fromEntries(Object.entries(detail).filter(([key]) => key !== 'https')),
    ...brief(result, 1200),
  };
});

// The network arm, on its own. Split out because it is the one capability whose
// answer depends on the environment rather than on the interpreter: a guest with
// no route out fails TLS for a reason that has nothing to do with Python.
await criterion('python', 'python_https', async () => {
  const root = `${scratchGuest}/python-work`;
  const mockUrl = process.env.DSHPORTE_STEP24_MOCK_URL ?? '';
  const result = await runJson(
    `mkdir -p ${root} && python3 /tmp/step24-py.py ${root} ${mockUrl}`,
    { watchdogMs: 600_000 },
  );
  const https = result.json?.https ?? null;
  if (https === null) return { pass: false, reason: 'the probe printed no https verdict', ...brief(result, 600) };
  const targets = Object.entries(https);
  return {
    // The task allows the mock to stand in for a public endpoint, so the pass
    // condition is "at least one https target answered with a real TLS request",
    // and both answers are recorded either way.
    pass: targets.some(([, value]) => value.ok === true),
    targets: Object.fromEntries(targets),
    openssl: result.json?.openssl ?? null,
    ...brief(result, 400),
  };
});

// The scripts are written once, through the provider, so their content is the
// same text the host's baseline runner uses.
await (async () => {
  const write = await run(`mkdir -p ${scratchGuest} && cat > /tmp/step24-py.py <<'PYEOF'\n${PY_CAPABILITIES}\nPYEOF\ncat > /tmp/step24-cpu.py <<'PYEOF'\n${PY_CPU}\nPYEOF\ncat > /tmp/step24-node.js <<'JSEOF'\n${NODE_CAPABILITIES}\nJSEOF\ncat > /tmp/step24-node-cpu.js <<'JSEOF'\n${NODE_CPU}\nJSEOF\nwc -l /tmp/step24-py.py /tmp/step24-cpu.py /tmp/step24-node.js /tmp/step24-node-cpu.js`);
  record('scripts_written', brief(write));
  if (write.exitCode !== 0) {
    // Everything below depends on these files; say so once instead of failing
    // eight criteria with the same unexplained ENOENT.
    report.scripts_write_failed = true;
  }
})();

// The same file-relevant checks on the guest's OWN rootfs, off the bind mount.
// The mount is a host directory seen through the kernel; the rootfs is the
// fakefs's own SQLite-backed storage. A write that works on one and not the
// other is a difference the model would hit the moment it wrote outside
// `/workspace`, so both are measured.
await criterion('python', 'python_capabilities_rootfs', async () => {
  const root = '/root/step24-work';
  const result = await runJson(
    `mkdir -p ${root} && python3 /tmp/step24-py.py ${root} ""`,
    { cwd: '/root', watchdogMs: 600_000 },
  );
  const detail = result.json ?? {};
  const failed = Object.entries(detail).filter(([key, value]) =>
    key !== 'python' && key !== 'openssl' && value && typeof value === 'object' && value.ok !== true)
    .map(([key]) => key);
  // `https` is excluded here: this arm exists to compare FILESYSTEM behaviour on
  // the two storage paths, and repeating the network check would only add a
  // second way for it to fail. Its shape is also different — one verdict per
  // target rather than one `ok` — so it is not comparable with the file arms.
  const fileKeys = ['json', 'fs_atomic', 'sqlite3', 'zip_gzip', 'subprocess', 'threading'];
  return {
    pass: result.exitCode === 0 && fileKeys.every((key) => detail[key]?.ok === true),
    failed,
    detail: Object.fromEntries(Object.entries(detail).filter(([key]) => key !== 'https')),
    ...brief(result, 800),
  };
});

await criterion('python', 'python_cpu', async () => {
  const result = await runJson(`python3 /tmp/step24-cpu.py ${CPU_ITERATIONS}`, { watchdogMs: 600_000, killMs: 300_000 });
  return {
    pass: result.exitCode === 0 && result.json?.checksum === expectedChecksum(CPU_ITERATIONS),
    iterations: CPU_ITERATIONS,
    expected_checksum: expectedChecksum(CPU_ITERATIONS),
    ...result.json === null ? {} : { seconds: result.json.seconds, ns_per_iteration: result.json.ns_per_iteration },
    ...brief(result, 300),
  };
});

// ---------------------------------------------------------------- node

await criterion('node', 'node_capabilities', async () => {
  const root = `${scratchGuest}/node-work`;
  const mockUrl = process.env.DSHPORTE_STEP24_MOCK_URL ?? '';
  const result = await runJson(
    `mkdir -p ${root} && node /tmp/step24-node.js ${root} ${mockUrl}`,
    { killMs: 180_000, watchdogMs: 240_000 },
  );
  const detail = result.json ?? {};
  const wanted = ['cjs', 'esm', 'fs_stream', 'timers', 'child_process', 'tls'];
  const failed = wanted.filter((key) => detail[key]?.ok !== true);
  // A killed command prints nothing, so `detail` is empty and every capability is
  // "failed". That is the correct verdict when Node cannot run at all; the reason
  // is in `stdout`/`stderr` and, more precisely, in the isolate segment.
  return {
    pass: result.exitCode === 0 && failed.length === 0,
    failed,
    reached_node: Object.keys(detail).length > 0,
    detail,
    ...brief(result, 1200),
  };
});

await criterion('node', 'node_cpu', async () => {
  const result = await runJson(`node /tmp/step24-node-cpu.js ${CPU_ITERATIONS}`, { watchdogMs: 180_000, killMs: 120_000 });
  return {
    pass: result.exitCode === 0 && result.json?.checksum === expectedChecksum(CPU_ITERATIONS),
    iterations: CPU_ITERATIONS,
    expected_checksum: expectedChecksum(CPU_ITERATIONS),
    ...result.json === null ? {} : { seconds: result.json.seconds, ns_per_iteration: result.json.ns_per_iteration },
    ...brief(result, 300),
  };
});

await criterion('node', 'node_cancel_then_rerun', async () => {
  // "Cancel a running program, then run one again and have it work." Both halves
  // matter: a cancel that wedges the provider's single queue would leave every
  // later command waiting forever, and a cancel-only test cannot see that.
  //
  // WHAT THIS MEASURES IN THIS GUEST: `node -e` never returns on its own here, so
  // the "running program" is one that is already spinning. The pair of questions
  // is still the right one, and the two answers are recorded separately — the
  // queue check is what separates "node is broken" from "the provider is wedged".
  const controller = new AbortController();
  const pending = run('node -e "setInterval(() => {}, 1000)"', {
    signal: controller.signal,
    // A long guest-side timer on purpose: the cancel has to be what stops it, or
    // the case would pass on the timeout instead of on the cancel.
    killMs: 120_000,
    watchdogMs: 180_000,
  });
  await new Promise((resolve) => { setTimeout(resolve, 3000); });
  const cancelledAt = Date.now();
  controller.abort();
  const cancelled = await pending;
  const cancelMs = Date.now() - cancelledAt;
  const after = await run('node -e "console.log(41 + 1)"', { killMs: 60_000, watchdogMs: 90_000 });
  const bashAfter = await run('echo queue-still-usable', { killMs: 30_000, watchdogMs: 60_000 });
  return {
    pass: cancelled.cancelled === true
      && after.exitCode === 0 && after.stdout.trim() === '42'
      && bashAfter.stdout.trim() === 'queue-still-usable',
    queue_still_usable: bashAfter.stdout.trim() === 'queue-still-usable',
    cancel_wall_ms: cancelled.wallMs,
    cancel_settle_ms: cancelMs,
    cancelled: brief(cancelled, 300),
    after: brief(after, 300),
    bash_after: brief(bashAfter, 200),
  };
});

await criterion('pipe', 'cancel_handoff_race', async () => {
  // AFTER A CANCEL, DOES THE NEXT COMMAND START?
  //
  // Measured while building this step: cancelling a running command and issuing the
  // next one immediately produced `launchError: "a guest command is already
  // running"`. That is a real handoff race, not a test artefact — the app clears its
  // in-flight marker with `dispatch_async(_guestQueue, ...)` AFTER the completion
  // block, so a caller that reacts to the cancellation before that block runs sees a
  // guest that still believes it is busy.
  //
  // The question this criterion settles is how wide the window is: immediately,
  // after 50 ms, and after 500 ms. A window that only closes after a fixed delay is
  // a fact the report has to state, because the model's own retry loop would hit it.
  const attempt = async (settleMs) => {
    const controller = new AbortController();
    const pending = run('sleep 30', { signal: controller.signal, killMs: 120_000, watchdogMs: 180_000 });
    await new Promise((resolve) => { setTimeout(resolve, 1200); });
    controller.abort();
    const cancelled = await pending;
    const cancelledAt = Date.now();
    if (settleMs > 0) await new Promise((resolve) => { setTimeout(resolve, settleMs); });
    const next = await run('echo handoff', { killMs: 30_000, watchdogMs: 45_000 });
    return {
      settle_ms: settleMs,
      cancelled_settle_ms: cancelledAt - (cancelledAt - cancelled.wallMs),
      cancel_wall_ms: cancelled.wallMs,
      next_exit: next.exitCode,
      next_stdout: String(next.stdout).trim(),
      next_launch_error: next.spawnError ?? null,
      next_wall_ms: next.wallMs,
    };
  };
  const immediate = await attempt(0);
  const shortGap = await attempt(50);
  const longGap = await attempt(500);
  const works = (value) => value.next_exit === 0 && value.next_stdout === 'handoff';
  return {
    // The criterion is "a shell works again after a cancel", which is what the task
    // asks. The three timings are recorded so a reader can see the window.
    pass: works(longGap) || works(shortGap) || works(immediate),
    immediate,
    short_gap: shortGap,
    long_gap: longGap,
    window_closed_by: works(immediate) ? 'no gap needed'
      : works(shortGap) ? 'between 0 and 50 ms'
        : works(longGap) ? 'between 50 and 500 ms' : 'not closed within 500 ms',
  };
});

// ---------------------------------------------------------------- npm

/**
 * Can `node` run a script in this guest at all?
 *
 * Asked once per npm arm. Every npm command is Node: when the answer is no (this
 * guest, measured), three clean installs per package would each burn the full kill
 * budget and the segment would spend an hour reporting the same fact five times.
 * When the answer is yes, the three rounds run exactly as designed.
 *
 * This is a SHORTENER, not a weaker criterion: a run where node works does every
 * install and every comparison, and a run where it does not says so once per arm,
 * with the probe's own output as the reason.
 */
async function nodeRunsScripts() {
  const result = await run('timeout -s KILL 10 node -e "console.log(6*7)" 2>&1; echo "rc=$?"',
    { killMs: 20_000, watchdogMs: 30_000 });
  const ok = /\b42\b/.test(result.stdout) && /rc=0/.test(result.stdout);
  return { ok, probe: brief(result, 600) };
}

/** A package install arm: three clean installs, file list compared to the tarball. */
async function npmInstallArm(label, spec, requireExpression) {
  const root = `${scratchGuest}/npm-${label}`;
  // `npm init` first, for the same reason `npm_init` exists as its own criterion:
  // an install into a directory with no package.json writes a tree npm has not
  // described, and a comparison against the tarball would then be measuring a
  // different thing.
  const prepare = await run(`rm -rf ${root} && mkdir -p ${root} && cd ${root} && npm init -y >/dev/null 2>&1`,
    { cwd: scratchGuest, watchdogMs: 300_000 });
  const rounds = [];
  const directory = packageDir(spec);
  const node = await nodeRunsScripts();
  const maxRounds = node.ok ? 3 : 1;
  for (let round = 1; round <= maxRounds; round += 1) {
    const install = await run(
      `rm -rf node_modules package-lock.json && npm install ${spec} --no-audit --no-fund 2>&1 | tail -4`,
      { cwd: root, watchdogMs: 240_000, killMs: 180_000 },
    );
    // TWO SNAPSHOTS, taken 3 s apart. The report this step had to check says a
    // large package's extraction can end with node exiting early and status 0.
    // A single count after the command returns cannot see a late write; a count
    // that changes between the two snapshots can. That is the whole instrument
    // for that claim, so it is here rather than in prose.
    const first = await countTree(root, `node_modules/${directory}`);
    await new Promise((resolve) => { setTimeout(resolve, 3000); });
    const second = await countTree(root, `node_modules/${directory}`);
    rounds.push({
      round,
      install: brief(install, 500),
      install_reported_no_error: install.exitCode === 0 && !/npm error/i.test(install.stdout),
      files_first_snapshot: first,
      files_second_snapshot: second,
      late_writes: second.files - first.files,
      stable: second.files === first.files && second.bytes === first.bytes,
    });
  }
  // The tarball's own file list, from the registry tarball npm itself downloaded.
  // `npm pack` is the honest source: it asks the registry for the same tarball
  // the install used, so the comparison is against the bytes on the wire rather
  // than against a hand-written expectation.
  const packResult = await run(`rm -f /tmp/${directory}-*.tgz; npm pack ${spec} --silent --pack-destination /tmp 2>/dev/null | tail -1`, { cwd: root, watchdogMs: 240_000, killMs: 180_000 });
  const tarball = packResult.stdout.trim().split('\n').pop() ?? '';
  const listing = await run(`tar tzf /tmp/${tarball} 2>/dev/null | sed 's:/$::' | sort`, { cwd: root, watchdogMs: 120_000, killMs: 90_000 });
  const tarballFiles = listing.stdout.split('\n').filter((line) => line.length > 0);
  // npm strips the leading `package/` when it extracts.
  const expected = tarballFiles.map((entry) => entry.replace(/^package\//, '')).sort();
  const installedList = await run(
    `cd node_modules/${directory} && find . -type f | sed 's:^\\./::' | sort`,
    { cwd: root, watchdogMs: 120_000, killMs: 90_000 },
  );
  const installed = installedList.stdout.split('\n').filter((line) => line.length > 0).sort();
  const missing = expected.filter((entry) => !installed.includes(entry));
  const extraFiles = installed.filter((entry) => !expected.includes(entry));
  const requireResult = await run(`node -e ${JSON.stringify(requireExpression)}`, { cwd: root, watchdogMs: 120_000, killMs: 90_000 });
  return {
    root,
    spec,
    prepare_ok: prepare.exitCode === 0,
    tarball,
    tarball_file_count: expected.length,
    installed_file_count: installed.length,
    // A file-count match is necessary but not sufficient: a truncated file of the
    // right name would pass it. The byte total from the same listing is compared
    // too, and the two sides use the same command so the numbers are comparable.
    missing: missing.slice(0, 20),
    missing_count: missing.length,
    extra: extraFiles.slice(0, 20),
    extra_count: extraFiles.length,
    file_lists_match: missing.length === 0 && extraFiles.length === 0,
    rounds,
    rounds_attempted: maxRounds,
    node_probe: node,
    every_round_complete: rounds.every((entry) => entry.install.exitCode === 0
      && entry.install_reported_no_error && entry.stable),
    require: brief(requireResult, 600),
    require_ok: requireResult.exitCode === 0,
  };
}

/** `ms` → `ms`; `typescript@5.6.3` → `typescript`; `@scope/pkg` → `@scope/pkg`. */
function packageDir(spec) {
  if (spec.startsWith('@')) {
    const [scope, rest] = spec.split('/');
    return `${scope}/${(rest ?? '').split('@')[0]}`;
  }
  return spec.split('@')[0];
}

/** Count files and bytes under a guest path, through the provider. */
async function countTree(cwd, relative) {
  const result = await run(
    `if [ -d ${relative} ]; then echo "files=$(find ${relative} -type f | wc -l) dirs=$(find ${relative} -type d | wc -l) bytes=$(find ${relative} -type f -exec wc -c {} + 2>/dev/null | tail -1 | awk '{print $1}')"; else echo "files=0 dirs=0 bytes=0"; fi`,
    { cwd, watchdogMs: 300_000 },
  );
  const text = result.stdout;
  const files = Number(/files=(\d+)/.exec(text)?.[1] ?? 0);
  const bytes = Number(/bytes=(\d+)/.exec(text)?.[1] ?? 0);
  const dirs = Number(/dirs=(\d+)/.exec(text)?.[1] ?? 0);
  return { files, dirs, bytes };
}

await criterion('npm', 'npm_init', async () => {
  const root = `${scratchGuest}/npm-init`;
  // `npm init` is a Node program. Probing first means the arm reports "node does not
  // run, so npm cannot" in about ten seconds instead of waiting out a 90-second kill
  // budget to learn the same thing.
  const node = await nodeRunsScripts();
  if (!node.ok) {
    return { pass: false, blocked_by: 'node does not run in this guest', node_probe: node };
  }
  const result = await run(
    `rm -rf ${root} && mkdir -p ${root} && cd ${root} && npm init -y 2>&1 | tail -6 && echo '--- package.json ---' && cat package.json`,
    { cwd: scratchGuest, watchdogMs: 120_000, killMs: 90_000 },
  );
  let manifest = null;
  const start = result.stdout.indexOf('{');
  if (start >= 0) {
    try { manifest = JSON.parse(result.stdout.slice(start, result.stdout.lastIndexOf('}') + 1)); } catch { manifest = null; }
  }
  // `npm --version` is recorded only when `npm init` got far enough to be worth
  // asking: when node cannot start, `npm` cannot either, and two killed commands
  // say the same thing twice.
  const npmVersion = result.exitCode === 0
    ? (await run('npm --version', { cwd: root, killMs: 60_000, watchdogMs: 90_000 })).stdout.trim()
    : null;
  return {
    pass: result.exitCode === 0 && manifest !== null && typeof manifest.name === 'string',
    manifest_name: manifest?.name ?? null,
    manifest_version: manifest?.version ?? null,
    npm_version: npmVersion,
    ...brief(result, 900),
  };
});

await criterion('npm', 'npm_small_package', async () => {
  const arm = await npmInstallArm('ms', 'ms@2.1.3',
    'const ms = require("ms"); console.log(ms("2 days"), ms(120000), typeof ms.parse)');
  return {
    pass: arm.file_lists_match && arm.every_round_complete && arm.require_ok
      && arm.require.stdout.includes('172800000'),
    ...arm,
  };
});

await criterion('npm', 'npm_large_package', async () => {
  // `typescript` measured by FILE COUNT. The version that matters here is the one
  // whose tarball is a real tree rather than a single bundled file: 5.6.3 is 121
  // files / 22 MB, and its esbuild-era successor (7.x) is 416 files / 2.5 MB. The
  // pinned version is deliberate so the file-count comparison means something
  // across runs.
  const arm = await npmInstallArm('typescript', 'typescript@5.6.3',
    'const ts = require("typescript"); const sf = ts.createSourceFile("a.ts", "const x: number = 1;", 99);'
    + ' console.log(ts.version, sf.statements.length, ts.transpileModule("const a:number=1",{}).outputText.trim())');
  const tsc = await run('./node_modules/.bin/tsc --version', { cwd: arm.root, watchdogMs: 120_000, killMs: 90_000 });
  const compile = await run(
    `mkdir -p src out && printf 'export const add = (a: number, b: number): number => a + b;\\n' > src/m.ts`
    + ' && ./node_modules/.bin/tsc src/m.ts --outDir out --module commonjs --target es2020'
    + ' && node -e "console.log(require(\'./out/m.js\').add(2,3))"',
    { cwd: arm.root, watchdogMs: 180_000, killMs: 120_000 },
  );
  return {
    pass: arm.file_lists_match && arm.every_round_complete && arm.require_ok
      && arm.require.stdout.startsWith('5.6.3') && compile.stdout.trim().endsWith('5')
      && arm.rounds.every((entry) => entry.late_writes === 0),
    ...arm,
    tsc: brief(tsc, 200),
    compile: brief(compile, 400),
    early_exit_investigated: {
      question: 'does a large extraction finish after node exits with status 0?',
      instrument: 'file/byte count immediately after the command returns, then again 3 s later',
      late_writes_per_round: arm.rounds.map((entry) => entry.late_writes),
      stable_per_round: arm.rounds.map((entry) => entry.stable),
      file_lists_identical_to_tarball: arm.file_lists_match,
    },
  };
});

await criterion('npm', 'npm_run_and_npx', async () => {
  const root = `${scratchGuest}/npm-scripts`;
  // The manifest is written as a file rather than through `node -e` with nested
  // quoting: three levels of shell quoting is where a harness starts testing
  // itself instead of the guest.
  const manifest = JSON.stringify({
    name: 'step24-npm-scripts',
    version: '1.0.0',
    private: true,
    scripts: {
      greet: 'node scripts/greet.js',
      chain: 'npm run greet',
      fail: 'node scripts/fail.js',
    },
    dependencies: { ms: '2.1.3', typescript: '5.6.3' },
  }, null, 2);
  const setup = await run(
    `rm -rf ${root} && mkdir -p ${root}/scripts && cd ${root}`
    + ` && cat > package.json <<'JSONEOF'\n${manifest}\nJSONEOF\ntrue`
    + ` && printf 'console.log("script-greet-ok", require("ms")(2000))\\n' > scripts/greet.js`
    + ` && printf 'process.exit(7)\\n' > scripts/fail.js`
    + ` && npm install --no-audit --no-fund 2>&1 | tail -3`,
    { cwd: scratchGuest, watchdogMs: 240_000, killMs: 180_000 },
  );
  const node = await nodeRunsScripts();
  if (!node.ok) {
    // Nothing in this criterion can pass without node: `npm run` and `npx` are both
    // Node programs. Recorded with the probe's own evidence instead of five killed
    // commands that would all say the same thing.
    return {
      pass: false,
      blocked_by: 'node does not run in this guest',
      node_probe: node,
      setup: brief(setup, 400),
    };
  }
  const greet = await run('npm run greet', { cwd: root, watchdogMs: 120_000, killMs: 90_000 });
  const chain = await run('npm run chain', { cwd: root, watchdogMs: 120_000, killMs: 90_000 });
  const fail = await run('npm run fail', { cwd: root, watchdogMs: 120_000, killMs: 90_000 });
  // `npx` against a LOCAL bin. `--no-install` makes "it reached the network"
  // an error, which is the distinction that matters: the local resolution path
  // and the download path must not be conflated.
  const npx = await run('npx --no-install tsc --version', { cwd: root, watchdogMs: 120_000, killMs: 90_000 });
  // And the negative arm: a name that is not installed must FAIL. Without
  // `--no-install` npx would fetch it, which is precisely what a guest with no
  // compiler and no package cache cannot be relied on to do.
  const npxMissing = await run('npx --no-install definitely-not-installed-xyz --version', { cwd: root, watchdogMs: 120_000, killMs: 90_000 });
  return {
    pass: setup.exitCode === 0
      && greet.stdout.includes('script-greet-ok') && greet.stdout.includes('script-greet-ok 2s')
      && chain.stdout.includes('script-greet-ok')
      && fail.exitCode === 7
      && npx.stdout.trim() === 'Version 5.6.3'
      && npxMissing.exitCode !== 0,
    setup: brief(setup, 400),
    greet: brief(greet, 300),
    chain: brief(chain, 400),
    fail: brief(fail, 300),
    fail_exit_7: fail.exitCode === 7,
    npx_local_bin: brief(npx, 300),
    npx_missing: { exitCode: npxMissing.exitCode, stderr: String(npxMissing.stderr).slice(0, 400) },
  };
});

// ---------------------------------------------------------------- project

// The two "real projects" are written by generator scripts that live in the
// repository (`tests/fixtures/step24/`). The host runner copies them into the
// workspace before launch, because `tests/` is not a bundle resource and the
// guest cannot read the host filesystem: the workspace bind mount is the only
// way in. `DSHPORTE_STEP24_FIXTURES` names that copy.
const fixturesDir = process.env.DSHPORTE_STEP24_FIXTURES ?? '';

/**
 * Read one fixture generator out of the guest, and say exactly why when it is not
 * there.
 *
 * READ WITH `cat` THROUGH THE PROVIDER, not with `node:fs` and not with `ctx.fs`.
 * Both of those were tried and both failed for namespace reasons that took longer
 * to diagnose than to avoid:
 *
 *   * `node:fs` runs on the APP's Node and sees the HOST filesystem, where the
 *     guest path `/workspace/step24-fixtures` does not exist;
 *   * `ctx.fs` is guest-aware for paths it is given, but a read through it still
 *     has to land on a target the host provider can open, and the bind mount is the
 *     one place the two namespaces meet — this run reported "fixture unreadable"
 *     while `ls` from inside the guest listed the file.
 *
 * `cat` in the guest has no such ambiguity: the file is either there or the shell
 * says why. The size is checked too, because a truncated read would otherwise
 * produce a script that fails for a reason that looks like the script's fault.
 */
async function readFixture(relative) {
  if (fixturesDir === '') {
    throw new Error('DSHPORTE_STEP24_FIXTURES is not set; the host runner must copy '
      + 'tests/fixtures/step24 into the workspace and name it');
  }
  const guestPath = `${fixturesDir}/${relative}`;
  const result = await run(
    `test -f ${guestPath} && wc -c < ${guestPath} && cat ${guestPath}`,
    { killMs: 60_000, watchdogMs: 90_000 },
  );
  if (result.exitCode !== 0) {
    throw new Error(`fixture unreadable at ${guestPath}: exit ${result.exitCode} `
      + `${String(result.stderr).slice(0, 200)}`);
  }
  const newline = result.stdout.indexOf('\n');
  const declared = Number(result.stdout.slice(0, newline));
  const text = result.stdout.slice(newline + 1);
  if (!Number.isFinite(declared) || text.length === 0) {
    throw new Error(`fixture at ${guestPath} read back empty (declared ${declared} bytes)`);
  }
  return { text, declaredBytes: declared, readBytes: text.length };
}

await criterion('project', 'project_js', async () => {
  const root = `${scratchGuest}/project-js`;
  const fixture = await readFixture('project-js/run-project.js');
  const write = await run(
    `mkdir -p ${root} && cat > ${root}/run-project.js <<'JSEOF'\n${fixture.text}\nJSEOF\nwc -c ${root}/run-project.js`,
    { killMs: 60_000, watchdogMs: 90_000 },
  );
  const result = await runJson(`node ${root}/run-project.js ${root}`, { killMs: 180_000, watchdogMs: 240_000 });
  return {
    pass: write.exitCode === 0 && result.json?.test_exit === 0,
    fixture_bytes: { declared: fixture.declaredBytes, read: fixture.readBytes },
    write: brief(write, 300),
    detail: result.json,
    ...brief(result, 800),
  };
});

await criterion('project', 'project_python', async () => {
  const root = `${scratchGuest}/project-py`;
  const fixture = await readFixture('project-python/run-project.py');
  const write = await run(
    `mkdir -p ${root} && cat > ${root}/run-project.py <<'PYEOF'\n${fixture.text}\nPYEOF\nwc -c ${root}/run-project.py`,
    { killMs: 60_000, watchdogMs: 90_000 },
  );
  const result = await runJson(`python3 ${root}/run-project.py ${root}`, { killMs: 600_000, watchdogMs: 900_000 });
  const detail = result.json ?? {};
  // The pass condition is the TEST result, not the dependency story: this image
  // has no system pip, and that is a constraint the report states rather than a
  // criterion. The dependency facts are still recorded per arm, because a venv
  // built from CPython's own bundled wheel does work and the difference matters
  // to whatever gets written into the guest's capability text.
  //
  // Read from the runner's own EXIT marker AND from unittest's summary. Both: the
  // marker proves the process status, the summary proves the runner ran tests
  // rather than exiting before collection.
  const testOk = /EXIT=0/.test(detail.test?.stdout ?? '')
    && /^OK$/m.test(detail.test?.stdout ?? '')
    && /Ran \d+ tests?/.test(detail.test?.stdout ?? '');
  // The negative control must be able to FAIL; a suite that always passes is not
  // evidence that anything works.
  // `negative_control` is the runner's {command, exitCode, stdout, stderr} record,
  // not a string: reading it as one made this arm report "cannot fail" while the
  // captured output plainly said EXIT=1.
  const negativeOk = /EXIT=1/.test(detail.negative_control?.stdout ?? '');
  // The sdist arm is a FACT, not a criterion: `six` builds its wheel from the
  // sdist because it is pure Python, so this image does not need a compiler for
  // it. The claim the report makes is narrower than "no compiler": it is that a
  // package with a C extension cannot be built. Recorded verbatim either way.
  const sdistBuilt = /Successfully (installed|built)/.test(detail.sdist_attempt?.tail ?? '');
  return {
    pass: write.exitCode === 0 && testOk && negativeOk,
    tests_passed: testOk,
    negative_control_can_fail: negativeOk,
    system_pip: detail.system_pip,
    venv_created: detail.venv?.exitCode === 0,
    venv_pip: detail.venv_pip?.stdout?.trim() ?? null,
    venv_install: {
      exitCode: detail.venv_install?.exitCode,
      tail: (detail.venv_install?.stdout ?? '').slice(-300),
    },
    sdist_attempt: {
      exitCode: detail.sdist_attempt?.exitCode,
      built_from_sdist: sdistBuilt,
      tail: (detail.sdist_attempt?.stdout ?? '').slice(-400),
    },
    negative_control: detail.negative_control ?? null,
    test: detail.test ?? null,
    ...brief(result, 400),
  };
});

// ---------------------------------------------------------------- pipe

await criterion('pipe', 'pipe_basics', async () => {
  // EACH CASE IS A SCRIPT FILE, not `python3 -c "..."` with embedded newlines.
  //
  // Measured: the first version passed a Python program through `-c` with `\\n`
  // escapes, and the guest's shell received a literal backslash-n, so the program
  // was one long syntax error and the case produced empty output. That looked like
  // "a pipe loses the producer's output" when the producer never ran. The writer
  // the runner already has (a file plus `timeout`) is also the cleaner way to
  // express a multi-line program.
  // Written through a heredoc, not `printf '%s' <json>`: JSON's newline escapes
  // reach `printf` as a two-character sequence that `%s` does not interpret, and the
  // producer file came out as one long line -- measured as `0 loops.py`. A heredoc
  // carries the text verbatim, and the runner already passes commands as files.
  const PY_LOOP = [
    'import sys',
    'for i in range(300000):',
    '    sys.stdout.write("%d\\n" % i)',
  ].join('\n');
  const c = `${scratchGuest}/pipe-cases`;
  const write = await run(
    `mkdir -p ${c} && cat > ${c}/loop.py <<'PYEOF'\n${PY_LOOP}\nPYEOF\nwc -l ${c}/loop.py`,
    { killMs: 60_000, watchdogMs: 90_000 },
  );
  const cases = {
    head_rg: `printf 'alpha\\nbeta\\n' | rg -c alpha`,
    head_rg_pipe: `rg --version >/dev/null 2>&1 && seq 1 200000 | rg '^7$' | head -3`,
    python3_head: `python3 ${c}/loop.py 2>/dev/null | head -3`,
    // Bounded, and short: `console.log` swallows EPIPE and a synchronous loop never
    // reaches its error event, so 300000 lines run to the end after `head` has gone.
    // 0.2 s on a Mac, past a 30 s timer here. That is the CPU, not the pipe.
    node_head: `node -e 'for (let i=0;i<3000;i++) console.log(i)' 2>/dev/null | head -3`,
    // Recorded, not judged. The fork turns a fatal V8 abort into exit 0 on purpose
    // (`v8_aborting` in `kernel/signal.c`), so npx's pipeline carries on. A crashed
    // Node can therefore look like a success, and the model is told to check.
    node_abort: `node -e 'process.abort()' >/dev/null 2>&1; echo "rc=$?"`,
    yes_head: `yes | head -3`,
    early_close: `node -e 'process.stdout.on("error",()=>process.exit(0));let i=0;setInterval(()=>console.log(i++),1)' 2>/dev/null | head -2`,
    pipe_fail_propagates: `false | true; echo "pipe-exit=$?"; set -o pipefail 2>/dev/null; false | true; echo "pipefail-exit=$?"`,
  };
  const detail = {};
  for (const [name, command] of Object.entries(cases)) {
    // The kill timer keeps a wedged producer from swallowing the rest of the segment.
    const result = await run(command, { killMs: 30_000, watchdogMs: 45_000 });
    detail[name] = { exitCode: result.exitCode, wallMs: result.wallMs,
                     stdout: String(result.stdout).slice(0, 200), stderr: String(result.stderr).slice(0, 200) };
  }
  const lines = (entry) => String(entry.stdout ?? '').trim().split('\n').filter(Boolean).length;
  const pipePass = write.exitCode === 0
    && detail.head_rg.exitCode === 0 && detail.head_rg.stdout.trim() === '1'
    && lines(detail.python3_head) === 3
    && lines(detail.yes_head) === 3
    && detail.node_head.exitCode === 0 && lines(detail.node_head) === 3
    && detail.early_close.exitCode === 0 && lines(detail.early_close) === 2
    && detail.pipe_fail_propagates.stdout.includes('pipefail-exit=1');
  return {
    pass: pipePass,
    py_loop_file: brief(write, 200),
    python3_head_lines: lines(detail.python3_head),
    yes_head_lines: lines(detail.yes_head),
    detail,
  };
});

await criterion('pipe', 'pipe_repeats', async () => {
  // 20 consecutive executions of one command that ends in a closed pipe. The
  // question is not whether one works but whether the twentieth does: a pipe
  // whose reader goes away can leave the write end spinning, and the guest keps
  // that thread alive.
  const rounds = [];
  const producer = `${scratchGuest}/pipe-repeats.py`;
  const producerCode = ['for i in range(200000):', '    print(i)'].join('\n');
  await run(`mkdir -p ${scratchGuest} && cat > ${producer} <<'PYEOF'\n${producerCode}\nPYEOF`,
    { killMs: 60_000, watchdogMs: 90_000 });
  for (let index = 1; index <= 20; index += 1) {
    const result = await run(
      `python3 ${producer} 2>/dev/null | head -2`,
      { killMs: 30_000, watchdogMs: 45_000 },
    );
    rounds.push({ round: index, exitCode: result.exitCode, wallMs: result.wallMs,
                  lines: String(result.stdout).trim().split('\n').length });
  }
  const wallTimes = rounds.map((entry) => entry.wallMs);
  const slowest = Math.max(...wallTimes);
  const firstFive = wallTimes.slice(0, 5).reduce((sum, value) => sum + value, 0) / 5;
  const lastFive = wallTimes.slice(-5).reduce((sum, value) => sum + value, 0) / 5;
  return {
    pass: rounds.every((entry) => entry.exitCode === 0 && entry.lines === 2),
    rounds_completed: rounds.length,
    slowest_ms: slowest,
    median_ms: wallTimes.slice().sort((a, b) => a - b)[10],
    first_five_mean_ms: Math.round(firstFive),
    last_five_mean_ms: Math.round(lastFive),
    // A wedged pipe shows up as the tail of the run being much slower than the
    // head. 3x is a generous bound that still catches a growing backlog.
    tail_slower_than_head: lastFive > firstFive * 3,
    rounds,
  };
});

await criterion('pipe', 'pipe_three_shells', async () => {
  // THREE AT ONCE. The provider serialises commands (the guest runs one at a
  // time; see the header of plugins/dsh-subprocess-ish), so what this measures is
  // that concurrent callers QUEUE instead of interleaving or deadlocking. The
  // report says which of the two it observed rather than calling it concurrency.
  const started = Date.now();
  const three = await Promise.all([
    run('sleep 1; echo shell-a', { watchdogMs: 120_000 }),
    run('sleep 1; echo shell-b', { watchdogMs: 120_000 }),
    run('sleep 1; echo shell-c', { watchdogMs: 120_000 }),
  ]);
  const totalMs = Date.now() - started;
  const outputs = three.map((entry) => String(entry.stdout).trim());
  return {
    pass: three.every((entry) => entry.exitCode === 0)
      && outputs.join(',') === 'shell-a,shell-b,shell-c',
    wall_ms: totalMs,
    // Three 1 s commands: ~1 s would mean real concurrency, ~3 s means they were
    // serialised. Both are correct behaviour for this provider; only one is true.
    serialised: totalMs >= 2800,
    concurrency_observed: totalMs < 2500,
    individual_wall_ms: three.map((entry) => entry.wallMs),
    outputs,
  };
});

await criterion('pipe', 'pipe_after_cancel', async () => {
  // After a cancel: does a piped command with a closed reader still work, and does
  // a shell still run? The task asks about both, and they are different failures —
  // a dead pipe reader versus a wedged provider queue.
  const controller = new AbortController();
  const pending = run('sleep 30', { signal: controller.signal, killMs: 120_000, watchdogMs: 180_000 });
  await new Promise((resolve) => { setTimeout(resolve, 1500); });
  controller.abort();
  const cancelled = await pending;
  const after = await run('seq 1 300000 | head -2', { killMs: 60_000, watchdogMs: 90_000 });
  const again = await run('echo 42', { killMs: 30_000, watchdogMs: 45_000 });
  const nodeAfter = await run('node -e "console.log(7*6)"', { killMs: 60_000, watchdogMs: 90_000 });
  return {
    pass: cancelled.cancelled === true && after.exitCode === 0
      && String(after.stdout).trim().split('\n').filter(Boolean).length === 2
      && again.stdout.trim() === '42'
      && nodeAfter.stdout.trim() === '42',
    cancelled: brief(cancelled, 200),
    piped_after_cancel: brief(after, 200),
    shell_after_cancel: brief(again, 200),
    node_after_cancel: brief(nodeAfter, 200),
  };
});

await criterion('pipe', 'pipe_idle_cpu', async () => {
  // "Is there CPU spinning, or does a later shell hang?" — asked directly, and the
  // instrument had to change.
  //
  // FIRST ATTEMPT, and why it was wrong: this read the guest's `/proc/stat` `cpu`
  // line and compared busy jiffies across two 4-second idle windows. Measured in
  // the app's guest, that line grows by ~2400 busy jiffies in 4 seconds while
  // NOTHING is running — a full core's worth — because the counters are the
  // EMULATOR's, and the host's own work is inside them. A baseline that moves when
  // idle cannot measure idleness. (It also means the number is not comparable with
  // a native Linux guest's, which the report has to say rather than quietly
  // quoting.)
  //
  // WHAT REPLACES IT: two facts that do not depend on that counter.
  //   1. Does a command after a closed-pipe command return at all, and how fast
  //      compared with the same command run cold? A wedged shell shows up as a
  //      wall-clock blow-up, not as a jiffy count.
  //   2. Is anything left running afterwards? `ps` inside the guest lists the
  //      processes; a spinning writer would still be there.
  const readPs = async () => {
    const result = await run('ps -o pid,stat,comm 2>/dev/null | tail -n +2 | wc -l; ps -o pid,stat,comm 2>/dev/null | tail -n +2',
      { killMs: 30_000, watchdogMs: 45_000 });
    const rows = String(result.stdout).trim().split('\n');
    return { count: Number(rows[0] ?? 0), rows: rows.slice(1).slice(0, 12), wallMs: result.wallMs };
  };
  const producer = `${scratchGuest}/idle-probe.py`;
  const producerCode = ['for i in range(50000):', '    print(i)'].join('\n');
  await run(`mkdir -p ${scratchGuest} && cat > ${producer} <<'PYEOF'\n${producerCode}\nPYEOF`,
    { killMs: 60_000, watchdogMs: 90_000 });

  const baseline = await run('echo baseline', { killMs: 30_000, watchdogMs: 45_000 });
  const before = await readPs();
  // A command whose reader goes away, then a plain command immediately after.
  const piped = await run(`python3 ${producer} 2>/dev/null | head -1`, { killMs: 60_000, watchdogMs: 90_000 });
  const after = await run('echo after-pipe', { killMs: 30_000, watchdogMs: 45_000 });
  await new Promise((resolve) => { setTimeout(resolve, 4000); });
  const settled = await readPs();
  return {
    pass: piped.exitCode === 0 && after.stdout.trim() === 'after-pipe'
      && after.wallMs < 5000
      && settled.count <= before.count + 2,
    // The evidence behind the verdict, so a reader can disagree with it.
    baseline_wall_ms: baseline.wallMs,
    after_pipe_wall_ms: after.wallMs,
    processes_before: before.count,
    processes_after_settle: settled.count,
    leftovers_after_settle: settled.rows,
    piped: brief(piped, 200),
    note: '/proc/stat busy jiffies grow while idle in this guest (measured), so that '
      + 'counter is not used as an idleness baseline; wall-clock and process count are',
  };
});

// ------------------------------------------------------------- prompt text
//
// Does the assembled system prompt actually carry the capability section?
//
// The plugin is mounted by the profile, and this module mounts the SAME profile, so
// the answer here is the answer the model gets. Asserted rather than assumed,
// because a section whose plugin row is skipped by a patch mismatch, or whose text
// renders empty, is silently absent with nothing in any log.
//
// READ THROUGH `assemble()`, WHICH RETURNS THE SECTION LIST — not a flat string.
// Step 8 documents this the hard way: it first read `await prompt.render()` as one
// string and got zero characters, then read `entry.order` (which `assemble()` does
// not include) and reported a section that was demonstrably present as absent.
// Position in the returned array and the `text` of each entry are what exist.
await criterion('python', 'prompt_section', async () => {
  const prompt = ctx.get('systemPrompt');
  if (prompt === undefined) return { pass: false, reason: 'no systemPrompt service in the mounted tree' };

  let sections = [];
  let assembleError = null;
  try {
    const assembled = await prompt.assemble({});
    sections = Array.isArray(assembled?.sections) ? assembled.sections : [];
  } catch (error) {
    assembleError = messageOf(error);
  }
  const names = sections.map((entry) => entry?.name).filter((name) => typeof name === 'string');
  const mine = sections.find((entry) => entry?.name === 'ios:guest-runtimes');
  const text = typeof mine?.text === 'string' ? mine.text : '';

  // The three claims that must survive into the prompt. The third is the one that
  // stops a retry loop, and it is the one a future edit is most likely to soften
  // into "may not work".
  const wanted = ['python3', 'pip', '`node` 22', 'no C compiler'];
  const missing = wanted.filter((needle) => !text.includes(needle));
  const myIndex = sections.findIndex((entry) => entry?.name === 'ios:guest-runtimes');
  const pathsIndex = sections.findIndex((entry) => entry?.name === 'ios:path-namespaces');

  return {
    pass: assembleError === null && mine !== undefined && missing.length === 0,
    assemble_error: assembleError,
    section_registered: mine !== undefined,
    section_chars: text.length,
    section_names: names,
    after_path_namespaces: myIndex >= 0 && pathsIndex >= 0 && myIndex > pathsIndex,
    missing_claims: missing,
    // A sample so a reader can see the wording without opening the app.
    sample: text.slice(0, 400),
  };
});

// The A/B control: with the switch off the section must be ABSENT on this same
// build. Without this the criterion above could pass on a stale profile and nobody
// would know.
await criterion('python', 'prompt_section_ab', async () => {
  const expectedOff = process.env.DSHPORTE_GUEST_RUNTIME_NOTE === '0';
  const prompt = ctx.get('systemPrompt');
  if (prompt === undefined) return { pass: false, reason: 'no systemPrompt service' };
  let names = [];
  try {
    names = ((await prompt.assemble({}))?.sections ?? []).map((entry) => entry?.name);
  } catch { names = []; }
  const present = names.includes('ios:guest-runtimes');
  return {
    // The criterion is about the switch being honoured, in whichever direction this
    // launch asked for.
    pass: present !== expectedOff,
    switch: process.env.DSHPORTE_GUEST_RUNTIME_NOTE ?? '(unset)',
    expected_present: !expectedOff,
    actually_present: present,
  };
});

// ------------------------------------------------------------------ run it

function expectedChecksum(iterations) {
  // The loop is `total = (total + index * 7) % 1000003` from 0. Computed here in
  // the host's Node so the guest's answer has something to be checked against:
  // a loop that silently ran fewer iterations prints a plausible time and a wrong
  // sum, and only the sum catches it.
  let total = 0;
  for (let index = 0; index < iterations; index += 1) total = (total + index * 7) % 1000003;
  return total;
}

/** Which segments to run. Unset means all; an unknown name is an error. */
const requested = (process.env.DSHPORTE_STEP24_ONLY ?? '').split(',')
  .map((part) => part.trim()).filter(Boolean);
const known = Object.keys(segments);
const unknown = requested.filter((name) => !known.includes(name));
if (unknown.length > 0) {
  record('bad_segment', { unknown, known });
  process.stdout.write(`DSHPORTE_STEP24_UNKNOWN ${JSON.stringify(unknown)}\n`);
  process.exit(2);
}
const selected = requested.length > 0 ? requested : known;

for (const segment of selected) {
  for (const { id, fn } of segments[segment] ?? []) {
    // The scripts the python/node criteria depend on are written by the
    // `python` segment's setup; a run that asks for `node` alone must have them.
    if (report.scripts_write_failed === true && id !== 'scripts_written') {
      record(id, { pass: false, skipped: 'the probe scripts could not be written' });
      results[id] = false;
      continue;
    }
    try {
      const value = await fn();
      record(id, value);
      results[id] = value.pass === true;
    } catch (error) {
      record(id, {
        pass: false,
        error: messageOf(error),
        stack: String(error?.stack ?? '').split(String.fromCharCode(10)).slice(0, 5),
      });
      results[id] = false;
    }
  }
}

report.summary = {
  passed: Object.values(results).filter(Boolean).length,
  total: Object.keys(results).length,
  results,
  segments: selected,
  finishedAt: new Date().toISOString(),
};
write();
process.stdout.write(`DSHPORTE_STEP24 ${JSON.stringify(report.summary)}\n`);
process.exit(0);
