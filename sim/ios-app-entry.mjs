// App-owned ESM entry for DSH inside nodejs-mobile on iOS.
//
// This is the file the Swift host hands to `node_start` as the script. It does
// four jobs, in this order, and the order matters:
//
//   1. Report runtime facts on stdout (`DSHPORTC_RUNTIME <json>`). The app parses
//      that line into Documents/DSHPortC-status.json, which is how the report
//      gets `process.versions` out of the real iOS process instead of a guess.
//   2. Register the flock resolve hook. It has to be in place BEFORE
//      `dsh-session-persistence-jsonl` is imported, because that binding is
//      captured at import time and ESM namespaces are frozen afterwards.
//   3. Point dsh at the payload's launcher and call its `runCli()`.
//
// The runtime restrictions themselves (dlopen, child_process) come from
// `ios-sim-preload.cjs`, loaded via `--require`, so they are already installed
// by the time this file runs.

import { register } from 'node:module';
import { pathToFileURL } from 'node:url';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { existsSync, writeFileSync } from 'node:fs';

import * as bootGuard from './boot-guard.mjs';
import * as safeMode from './safe-mode.mjs';
import * as diagnostics from './diagnostics.mjs';
import { previewCombos } from './reset-plan.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const BUNDLE = resolve(HERE, '..');

const payload = process.env.IOS_SIM_DSH_INSTALL ?? join(BUNDLE, 'payload');
const dshHome = process.env.DSH_HOME ?? '';
const workspace = process.env.DSH_IOS_WORKSPACE ?? process.cwd();
const launcher = join(payload, 'node_modules', '@deepseek-ai', 'dsh', 'lib', 'bin.js');

/** Facts the app needs; printed as one machine-readable line. */
function reportRuntime() {
  // `ios-sim-preload.cjs` replaces the seven child_process entry points with
  // throwing stubs and hangs the original off `__iosSimOriginal`. That marker is
  // the honest signal: the stubs are still functions, so a typeof check would
  // report "not blocked" while every call throws.
  let childProcessBlocked = false;
  try {
    const cp = process.getBuiltinModule('node:child_process');
    childProcessBlocked = typeof cp.spawnSync === 'function'
      && cp.spawnSync.__iosSimOriginal !== undefined;
  } catch {
    childProcessBlocked = true;
  }
  // `typeof WebAssembly` is NOT a reliable jitless signal here: the preload's
  // wasm polyfill installs a stub object before this script runs, so the global
  // looks present even on a build with no wasm support at all. Probe the real
  // capability instead, and record which answer came from where.
  let wasmCompiles = false;
  try {
    const module = new WebAssembly.Module(new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0]));
    wasmCompiles = WebAssembly.Module.exports(module).length >= 0;
  } catch {
    wasmCompiles = false;
  }
  const wasmGlobal = typeof WebAssembly;
  // A stub installed by our own preload reports its origin through this marker.
  const wasmIsStub = wasmGlobal === 'object' && globalThis.WebAssembly?.__iosSimStub === true;

  const facts = {
    node: process.versions.node,
    v8: process.versions.v8,
    modules: process.versions.modules,
    napi: process.versions.napi,
    platform: process.platform,
    arch: process.arch,
    // The honest triple: what the global looks like, whether it is our stub, and
    // whether wasm can actually compile anything.
    webAssembly: wasmGlobal,
    webAssemblyIsStub: wasmIsStub,
    webAssemblyCompiles: wasmCompiles,
    jitless: process.execArgv.includes('--jitless') || !wasmCompiles,
    execArgv: process.execArgv,
    payload,
    dshHome,
    workspace,
    childProcessBlocked,
    addonLoadingBlocked: process.env.IOS_SIM_ACTIVE === '1',
  };
  process.stdout.write('DSHPORTC_RUNTIME ' + JSON.stringify(facts) + '\n');
}

reportRuntime();

// ---------------------------------------------------------------- boot guard
//
// STEP 19. Four modules, wired here so the app's own boot can be rescued from a
// composition that will not come up. The whole block is wrapped in try/catch, one
// per job: the mechanism that exists to keep the app booting must never be the
// reason it does not. Everything below is skipped when a launch is one of the
// acceptance gates further down, because those launches replace DSH entirely and
// counting them as real boots would let an acceptance run push a device into safe
// mode — and a device in safe mode is a different composition to measure.
const BOOT_DIR = process.env.DSHPORTE_BOOT_DIR ?? '';
const LAUNCH_ID = process.env.DSHPORTE_BOOT_LAUNCH_ID ?? '';
const BOOT_GUARD_ON = process.env.DSHPORTE_BOOT_GUARD === '1' && BOOT_DIR !== '' && LAUNCH_ID !== '';
const CONTAINER_ROOT = process.env.DSHPORTE_CONTAINER_ROOT ?? resolve(dshHome, '../../..');
const PROFILE_DIR = join(dshHome, 'profiles', 'ios-sim');
// `DSH_HOME` is `<container>/Library/Application Support/DSH`, so its DIRECTORY is
// `.../Application Support` — not the app's own support directory, which is
// `.../Application Support/DSHPortC`. PLAN-19 §8's snippet wrote
// `dirname(dshHome)` for this and that is one level too high: the diagnostics
// bundle would have been written to `Application Support/diagnostics`, where the
// app never looks, so the "导出诊断包" button would always fall back to its minimal
// package and the boot snapshot would accumulate in a directory nothing prunes.
// Measured on the simulator: `boot/reset-plan.json` was written (it uses BOOT_DIR)
// and `diagnostics/` was simply absent next to `DSHPortC/`.
const APP_SUPPORT_DIR = join(dirname(dshHome), 'DSHPortC');
const DIAGNOSTICS_DIR = join(APP_SUPPORT_DIR, 'diagnostics');
// `documents` is supplied so the bundle's `excluded` list can NAME the user's
// workspace rather than report it as a root that was not configured. Nothing under
// it is ever read: `EXCLUDED` lists `workspace` and `FORBIDDEN_SEGMENTS` refuses
// it, both of which key off this root existing.
const DIAGNOSTIC_ROOTS = {
  appSupport: APP_SUPPORT_DIR,
  dshHome,
  boot: BOOT_DIR,
  documents: join(CONTAINER_ROOT, 'Documents'),
};

/** Launch flags that replace DSH with a measurement run. */
const ACCEPTANCE_FLAGS = [
  'DSHPORTE_CHANNEL_ACCEPTANCE', 'DSHPORTE_CANCEL_PROBE', 'DSHPORTE_SUBPROCESS_ACCEPTANCE',
  'DSHPORTE_TZ_PROBE', 'DSHPORTE_TZ_API_PROBE', 'DSHPORTE_SESSION_LIST_ACCEPTANCE',
  'DSHPORTE_STEP6_PROBE', 'DSHPORTE_STEP7_ACCEPTANCE', 'DSHPORTE_STEP8_ACCEPTANCE',
  'DSHPORTE_STEP9_ACCEPTANCE', 'DSHPORTE_STEP24_ACCEPTANCE', 'DSHPORTE_SESSION_CONTINUE',
  // Step 19B's own probe. It has to be counted as a gate for a subtle reason: it
  // mounts the profile a SECOND time in one process to read the safe-mode
  // composition, and a boot-guard decision taken around that would describe a
  // launch the user never sees.
  'DSHPORTE_STEP19_SAFE_PROBE',
  // The purge probe is NOT an acceptance gate: it runs at boot, in the normal
  // composition, and only calls the reset panel's own delete function. Adding it
  // here would skip the boot guard for a launch that is otherwise ordinary, which
  // would make the measurement describe a state no user reaches.
];

function acceptanceGateActive() {
  return ACCEPTANCE_FLAGS.some((name) => (process.env[name] ?? '') === '1');
}

/** One job of the boot block, isolated: a failure is a log line, never a throw. */
function bootStep(label, run) {
  try {
    return run();
  } catch (error) {
    process.stderr.write(`dshportc: ${label} failed: ${error && error.message ? error.message : error}\n`);
    return undefined;
  }
}

// DSH ends a failed startup with `process.exit(1)`, and this Node lives inside the
// app's process, so that call closes the app: no failure screen, and with a broken
// credentials file no way out, because safe mode dies the same way. Instead the app
// is told why and this thread parks, which keeps the process and its screen alive.
// Exit code 0 is still a real exit. V8 aborts do not come through here;
// `NodeRunner.prepareAndLaunch` catches those by the safe-mode failure count.
let lastStartupFailure = '';
function installFatalExit() {
  for (const stream of [process.stdout, process.stderr]) {
    const write = stream.write;
    stream.write = function patchedWrite(chunk, ...rest) {
      const text = typeof chunk === 'string' ? chunk : '';
      if (lastStartupFailure === '' && text.includes('startup failed')) {
        lastStartupFailure = text.split('\n').find((line) => line.includes('startup failed')).trim();
      }
      return write.call(this, chunk, ...rest);
    };
  }
  const realExit = process.exit;
  process.exit = (code) => {
    const status = code ?? process.exitCode ?? 0;
    if (status === 0) return realExit.call(process, 0);
    parkStartup(lastStartupFailure || `DSH exited with code ${status}`, 'dsh');
    return undefined;
  };
}

/** Record a failed startup, tell the app, and park this thread for good. */
function parkStartup(reason, phase) {
  bootStep('boot guard failure', () => bootGuard.noteFailure({
    stateFile: join(BOOT_DIR, bootGuard.BOOT_FILES.state),
    launchId: LAUNCH_ID,
    reason,
    phase,
  }));
  process.stdout.write(`DSHPORTC_FATAL ${reason}\n`);
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0);
}

// A measurement run is not a boot of the app, so it must not move the counter —
// and it must not push a device into safe mode either, because a device in safe
// mode is a different composition to measure next time.
//
// What it DOES keep is the safe-mode OVERLAY: `DSHPORTE_STEP19_SAFE_PROBE` exists
// to measure whether a session can be created in the safe-mode composition, so it
// has to run under the same `--patch` a safe-mode launch would use. Skipping the
// whole block would have made the probe measure the normal composition and report
// a PASS about the wrong thing.
const GATE = acceptanceGateActive();
const KEEPS_SAFE_MODE = (process.env.DSHPORTE_STEP19_SAFE_PROBE ?? '') === '1';

if (BOOT_GUARD_ON && !GATE) bootStep('fatal exit', installFatalExit);

let decision;
if (BOOT_GUARD_ON && !GATE) {
  decision = bootStep('boot guard', () => bootGuard.beginLaunch({
    stateFile: join(BOOT_DIR, bootGuard.BOOT_FILES.state),
    outcomeFile: join(BOOT_DIR, bootGuard.BOOT_FILES.outcome),
    backgroundFile: join(BOOT_DIR, bootGuard.BOOT_FILES.background),
    requestFile: join(BOOT_DIR, bootGuard.BOOT_FILES.request),
    launchId: LAUNCH_ID,
  }));
} else if (BOOT_GUARD_ON && KEEPS_SAFE_MODE) {
  // A measurement run reads the guard's DECISION but does not settle anything: it
  // must not consume an outcome, must not advance the streak, and must not write an
  // attempt. `readStateFile` is the read half of the same module, so the mode the
  // probe runs in is the mode a real launch would have chosen, without the run
  // itself becoming a data point.
  const read = bootStep('boot guard state', () => bootGuard.readStateFile(
    join(BOOT_DIR, bootGuard.BOOT_FILES.state),
  ));
  if (read !== undefined) {
    decision = {
      mode: read.state.safeMode ? 'safe' : 'normal',
      failures: read.state.failures,
      threshold: read.state.threshold,
      safeModeReason: read.state.safeModeReason,
      previous: read.state.lastOutcome,
      // Named so the log does not claim a settlement that did not happen.
      measurementOnly: true,
    };
    process.stderr.write(`dshportc: probe launch reads mode=${decision.mode} `
      + `failures=${decision.failures} without settling any attempt\n`);
  }
}

// A safe-mode launch whose overlay could not be prepared must not go on to boot
// the normal composition: that is the composition that just failed three times,
// and the banner would still say "safe mode". Stop at the failure screen instead,
// where the log, the export and the reset are.
let safeModePrepareFailure = '';
if (BOOT_GUARD_ON && (KEEPS_SAFE_MODE || !GATE)) {
  bootStep('safe mode', () => {
    if (decision?.mode === 'safe') {
      let prepared;
      try {
        prepared = safeMode.prepare({
          profileDir: PROFILE_DIR,
          overlayPath: join(BOOT_DIR, bootGuard.BOOT_FILES.overlay),
          reason: decision.safeModeReason ?? '',
        });
      } catch (error) {
        safeModePrepareFailure = `safe mode could not be prepared: ${error && error.message ? error.message : error}`;
        throw error;
      }
      for (const warning of prepared.warnings) process.stderr.write(`dshportc: safe mode: ${warning}\n`);
      // The overlay has to go BEFORE the arguments that belong to the booted app.
      // `bin.js` parses the outer `dsh` options and then hands everything from the
      // first app argument on through untouched (`passThroughOptions()`), so an
      // overlay pushed onto the end — after `--port 0` — is delivered to DSH's own
      // service and rejected there:
      //
      //     node| error: unknown option '--patch'
      //     dshportc: node_start returned 1
      //
      // Measured on the simulator in this step. `safeMode.applyToArgv()` owns the
      // rule and its comment has the full argument; this call site only has to use
      // it on the right slice of argv (index 0 is node, 1 is this script).
      const dshArgs = process.argv.slice(2);
      process.argv = [process.argv[0], process.argv[1], ...safeMode.applyToArgv(dshArgs, { patch: prepared.overlayPath })];
    } else {
      const restored = safeMode.restoreUserPatch({ profileDir: PROFILE_DIR });
      if (restored.restored) {
        process.stderr.write('dshportc: user layer restored from the safe-mode park\n');
      }
      // An edit made during a safe-mode session is beside the file it came from,
      // not gone. Saying so in the log is what lets the failure screen — or a
      // person reading it later — explain where those settings went.
      if (restored.editedCopy) {
        process.stderr.write(`dshportc: settings saved during safe mode kept at ${restored.editedCopy}\n`);
      }
    }
    return undefined;
  });
  if (safeModePrepareFailure !== '' && !GATE) parkStartup(safeModePrepareFailure, 'safe-mode');
}

if (BOOT_GUARD_ON && !GATE) {
  // The one line the app's banner is built from. Printed whether or not safe mode
  // is active: "normal mode, 0 failures" is the fact that answers "am I still in
  // safe mode", and the app cannot learn it from the absence of a line.
  bootStep('safe mode line', () => {
    process.stdout.write(`DSHPORTC_SAFEMODE ${JSON.stringify({
      ...safeMode.describeDecision(decision ?? { mode: 'normal' }),
      failures: decision?.failures ?? 0,
      previous: decision?.previous ?? null,
    })}\n`);
  });

  // Reset panel's list, one file, four combinations. Written here because this is
  // the only moment the container root is known for certain; the sheet falls back
  // to its own copy of the same table when this file is absent.
  bootStep('reset preview', () => {
    const preview = previewCombos({ root: CONTAINER_ROOT });
    writeFileSync(
      join(BOOT_DIR, bootGuard.BOOT_FILES.resetPreview),
      `${JSON.stringify({ ...preview, generatedAt: new Date().toISOString() }, null, 2)}\n`,
    );
  });

  // One diagnostics snapshot per launch, taken while Node is certainly alive and
  // the profile has settled — the only moment at which both are true.
  bootStep('diagnostics snapshot', () => diagnostics.snapshot({
    outDir: DIAGNOSTICS_DIR,
    roots: DIAGNOSTIC_ROOTS,
    keep: 3,
  }));

  // The answer to the app's "导出诊断包" button. Idle when the request file is not
  // there, which is every launch the user does not press it.
  bootStep('diagnostics poller', () => {
    setInterval(() => {
      try {
        diagnostics.exportOnce({
          requestFile: join(BOOT_DIR, bootGuard.BOOT_FILES.exportRequest),
          doneFile: join(BOOT_DIR, bootGuard.BOOT_FILES.exportDone),
          outDir: DIAGNOSTICS_DIR,
          roots: DIAGNOSTIC_ROOTS,
          pruneKeep: 3,
        });
      } catch (error) {
        process.stderr.write(`dshportc: diagnostics export failed: ${error}\n`);
      }
    }, 1000).unref();
  });

  // The attempt's progress, so a launch that dies in the foreground has a phase
  // in its reason rather than "unknown".
  bootStep('boot progress', () => bootGuard.noteProgress({
    stateFile: join(BOOT_DIR, bootGuard.BOOT_FILES.state),
    launchId: LAUNCH_ID,
    phase: 'entry',
  }));
}

// The step-3/step-4 acceptance run, when asked for. It replaces DSH entirely for
// that launch: the criteria are about the channel, not the web UI, and running
// both at once would put Node heap pressure and web-view work into a timing
// measurement that is supposed to be about the guest. A normal launch never sets
// this — see scripts/channel-acceptance.sh for the only caller.
if (process.env.DSHPORTE_CHANNEL_ACCEPTANCE === '1') {
  await import('./channel-acceptance.mjs');
  // That module exits the process when it finishes. If it ever returns instead
  // (a future change), do not fall through into DSH: the run is already over and
  // starting the web UI would only make the report confusing.
  await new Promise(() => { /* idle until the process is killed */ });
}

// The step-5 acceptance run. It mounts the profile through DSH's own loader and
// drives `ctx.subprocess` directly, so it covers the provider rather than the
// channel the previous module already covers. Same gating, same replacement of
// DSH: two servers in one process would confuse both the measurement and the
// report.
// A one-off probe for the cancel path, kept as a separate gate because it
// answers ONE question and a failure inside it must not be mistaken for a
// provider or agent-loop failure.
if (process.env.DSHPORTE_CANCEL_PROBE === '1') {
  await import('./cancel-probe.mjs');
  await new Promise(() => { /* idle until the process is killed */ });
}

if (process.env.DSHPORTE_SUBPROCESS_ACCEPTANCE === '1') {
  await import('./subprocess-acceptance.mjs');
  await new Promise(() => { /* idle until the process is killed */ });
}

// The step-6 timezone probe. One question: does this Node know the device's
// local zone, and how wrong is the ICU-less shim across a DST boundary? Answers
// from inside the app, because a host Node would be a different libc.
if (process.env.DSHPORTE_TZ_PROBE === '1') {
  await import('./tz-probe.mjs');
  await new Promise(() => { /* idle until the process is killed */ });
}

// Which of the page's three time mechanisms survive without ICU, and what each
// reports. Separate gate because it answers a different question from the zone
// probe above (that one asks "is the zone right", this one asks "does the API
// exist at all").
if (process.env.DSHPORTE_TZ_API_PROBE === '1') {
  await import('./tz-api-probe.mjs');
  await new Promise(() => { /* idle until the process is killed */ });
}

// Step 6's functional half: does DSH itself list (and open) a session that
// survived a container change? Separate from the UI-side evidence, and separate
// from DSH's own server, because the question is about the store, not the screen.
// Note on how this is switched on: `simctl launch` passes `-DKey value` into the
// argument domain, but Node cannot see that domain, so the Swift host re-publishes
// the flags it cares about into the environment before `node_start`. The
// environment form here is therefore reliable for flags the host forwards, and the
// `SIMCTL_CHILD_*` form is NOT — the simulator keeps the first set it saw until
// the whole device shuts down (measured repeatedly in this step, and recorded in
// REPORT-5). NodeRunner.swift is the forwarder; see `forwardTestFlags()`.
if (process.env.DSHPORTE_SESSION_LIST_ACCEPTANCE === '1') {
  await import('./session-list-acceptance.mjs');
  await new Promise(() => { /* idle until the process is killed */ });
}

// The other half of that criterion: can the migrated session take a TURN? The
// listing module cannot answer it, and neither can the browser on this device —
// the sidebar is a 56 px rail at 402 px, so its rows never enter the DOM and the
// browser-driven run puts its prompt in a NEW session (measured; see
// sim/session-continue-acceptance.mjs). This hands the session to the same
// controller the UI's send button reaches, against the same migrated log on disk.
//
// THIS GATE IS DELIBERATELY BELOW, not here. A turn is the WRITE path: resuming a
// session takes the flock, and `@deepseek-ai/node-addon-system`'s flock addon is
// the one `dsh-ios` stubs out — it throws `flock is not supported on ios-arm64`.
// The pure-JS redirect is registered further down, so a gate imported before that
// point resumes straight into the native addon and fails. Measured exactly once,
// the hard way: the first version of this gate sat here and every follow-up turn
// died with that message. See the registration site below.

// Capability probe for both step-6 problems: which zstd surface this Node has,
// and what its `Date`/`Intl` report about the device's zone.
if (process.env.DSHPORTE_STEP6_PROBE === '1') {
  await import('./step6-probe.mjs');
  await new Promise(() => { /* idle until the process is killed */ });
}

// Step 7: the four model-facing problems the phone run reported — glob/grep's
// missing ripgrep, bash's default cwd and `workdir`, the two path namespaces, and
// the changed-files card's treatment of bash writes. It mounts the real profile
// and drives the real services and tools, so a criterion failing here means the
// model's call fails, not that a string helper is wrong.
//
// Placed BELOW the flock redirect's sibling gates for the same reason
// `session-continue-acceptance` is: this module runs a real agent-free but
// complete tool path, and the `workspaceChanges` criterion spawns git. Nothing
// here resumes a session, so the flock ordering constraint does not bite, but
// keeping every functional gate below the redirect avoids re-learning it.
if (process.env.DSHPORTE_STEP7_ACCEPTANCE === '1') {
  await import('./step7-acceptance.mjs');
  await new Promise(() => { /* idle until the process is killed */ });
}

// Step 8: the "write → bash deletes → write" cycle the phone reported as a
// deadlock. Same placement reasoning as step 7's gate (no session resume, no
// flock), and it must be below the loader hooks for the same reason: it mounts the
// real profile, and the payload import would otherwise fail on the packages the
// hooks answer for.
if (process.env.DSHPORTE_STEP8_ACCEPTANCE === '1') {
  await import('./step8-acceptance.mjs');
  await new Promise(() => { /* idle until the process is killed */ });
}

// Step 9: one canonical path spelling, end to end — the workspace list no longer
// showing one folder twice, and every row being selectable again.
//
// THIS GATE NEEDS THE FLOCK REDIRECT, and it sits here because it brings its own.
// Its central criterion sends a real prompt through `sessionController.prompt`,
// which resumes the session and takes the flock; without the pure-JS redirect that
// turn dies with `flock is not supported on ios-arm64`, and the criterion would
// report "selecting a workspace fails" about a completely different failure. Steps
// 7 and 8 answered this the same way — each registers the hooks itself before
// importing the payload — rather than relying on the registrations further down,
// which by then have not run.
if (process.env.DSHPORTE_STEP9_ACCEPTANCE === '1') {
  await import('./step9-acceptance.mjs');
  await new Promise(() => { /* idle until the process is killed */ });
}

// Step 24: what the guest's `node`, `npm` and `python3` can actually do.
//
// Placed with the other functional gates, for the same reason: it mounts the
// real profile (so it drives the SHIPPED `ctx.subprocess` provider, not a
// hand-rolled channel call), and it must sit below the loader hooks so the
// payload imports resolve. It resumes no session, so the flock ordering
// constraint above does not apply to it.
if (process.env.DSHPORTE_STEP24_ACCEPTANCE === '1') {
  await import('./step24-acceptance.mjs');
  await new Promise(() => { /* idle until the process is killed */ });
}

// Step 19B: is the composition this launch is running one a session can be created
// in? It runs INSTEAD of DSH for that launch, because it mounts the profile itself
// and a second web UI in the same process would be a second composition — the
// question is about one. Placed here, below the loader hooks and the flock
// redirect, for the same reason steps 7, 8 and 9 are: it mounts the real profile
// and drives a real turn, which resumes a session and takes the flock.
if (process.env.DSHPORTE_STEP19_SAFE_PROBE === '1') {
  await import('./step19-safe-probe.mjs');
  await new Promise(() => { /* idle until the process is killed */ });
}

// The step-6 session migration. Runs BEFORE dsh is imported, because the state
// it repairs is read during that import: `dsh-session-persistence-jsonl` scans
// the session logs and `dsh-workspace` builds its header index from them, and a
// stale header cwd is what makes DSH call a log corrupt.
//
// Not gated on a separate flag: this is production behaviour for the app, not a
// measurement. It is driven by DSHPORTE_SESSION_MIGRATE, which the Swift host
// sets on every launch (NodeRunner.swift), and it does nothing when absent — so
// importing this entry from a desktop test harness leaves the tree untouched.
if (process.env.DSHPORTE_SESSION_MIGRATE) {
  const { runFromEnvironment } = await import('./session-migrate.mjs');
  runFromEnvironment();
}

if (!existsSync(launcher)) {
  const reason = `dsh launcher not found at ${launcher}`;
  process.stderr.write(`dshportc: ${reason}\n`);
  // Record why, so the failure screen names a missing payload instead of "the
  // process ended". `noteFailure` closes this launch's attempt; it is a no-op
  // when the guard is off or the attempt is somebody else's.
  if (BOOT_GUARD_ON) {
    bootStep('boot guard failure', () => bootGuard.noteFailure({
      stateFile: join(BOOT_DIR, bootGuard.BOOT_FILES.state),
      launchId: LAUNCH_ID,
      reason,
      phase: 'launcher',
    }));
  }
  process.exit(1);
}

// The flock redirect must precede every import of the persistence plugin.
if (process.env.IOS_SIM_FLOCK_SHIM !== '0') {
  try {
    register('./flock-hook.mjs', pathToFileURL(HERE + '/'));
  } catch (error) {
    process.stderr.write(`dshportc: flock hook registration failed: ${error}\n`);
  }
}

// Make `@vscode/ripgrep` resolvable, pointing at the GUEST's ripgrep.
//
// `dsh-tool-fs-search` (the plugin behind the model's `glob`/`grep`) imports that
// package to find its binary, and does so BEFORE spawning, so a missing package is
// reported as "ripgrep launch failed" with no other clue. The package cannot be
// installed here: its binaries are platform-specific optional dependencies and no
// `ios` build exists, while the guest gets its own from the image. The hook
// answers the import with the guest path; the provider respells it for the
// executable it actually starts.
//
// Gated on the guest being configured: with no guest there is no `/usr/bin/rg`,
// and the honest answer is the original "package not found" rather than a path
// that cannot work. Registered before DSH is imported, because the search plugin
// resolves the dependency lazily but the hook has to be in place first anyway.
if (process.env.DSHPORTE_RG_HOOK !== '0' && (process.env.DSH_GUEST_CHANNEL_URL ?? '').length > 0) {
  try {
    register('./ripgrep-hook.mjs', pathToFileURL(HERE + '/'));
  } catch (error) {
    process.stderr.write(`dshportc: ripgrep hook registration failed: ${error}\n`);
  }
}

// "And it can still take a turn" — imported HERE, after the flock redirect and
// before DSH itself, for the reason given at the gate's comment above: resuming a
// session takes the flock, and the pure-JS redirect has to be registered first or
// the resume reaches the native addon and dies with
// `flock is not supported on ios-arm64`. Placing it with the read-only gates
// above was measured to fail exactly that way.
if (process.env.DSHPORTE_SESSION_CONTINUE === '1') {
  await import('./session-continue-acceptance.mjs');
  await new Promise(() => { /* idle until the process is killed */ });
}

// dsh reads its own argv; hand it the arguments this process received. argv is
// [node, <this script>, ...dsh args], so the dsh args start at index 2.
process.argv = [process.argv[0], launcher, ...process.argv.slice(2)];

// `bin.js` self-executes only under `import.meta.main`, which is false for an
// imported module, so call the exported entry point explicitly.
const launcherModule = await import(pathToFileURL(launcher).href);
if (typeof launcherModule.runCli !== 'function') {
  const reason = `${launcher} does not export runCli`;
  process.stderr.write(`dshportc: ${reason}\n`);
  if (BOOT_GUARD_ON) {
    bootStep('boot guard failure', () => bootGuard.noteFailure({
      stateFile: join(BOOT_DIR, bootGuard.BOOT_FILES.state),
      launchId: LAUNCH_ID,
      reason,
      phase: 'launcher',
    }));
  }
  process.exit(1);
}
// `runCli()` throwing is the third failure this side can name by itself: the
// bundle loaded, so the payload is there, and what failed is DSH's own startup.
if (BOOT_GUARD_ON) {
  bootStep('boot progress', () => bootGuard.noteProgress({
    stateFile: join(BOOT_DIR, bootGuard.BOOT_FILES.state),
    launchId: LAUNCH_ID,
    phase: 'launcher',
  }));
}
try {
  await launcherModule.runCli();
} catch (error) {
  const reason = `runCli threw: ${error && error.message ? error.message : error}`;
  process.stderr.write(`dshportc: ${reason}\n`);
  if (BOOT_GUARD_ON) {
    bootStep('boot guard failure', () => bootGuard.noteFailure({
      stateFile: join(BOOT_DIR, bootGuard.BOOT_FILES.state),
      launchId: LAUNCH_ID,
      reason,
      phase: 'dsh',
    }));
  }
  process.exit(1);
}
