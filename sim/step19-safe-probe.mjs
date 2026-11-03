// Step 19B: can a SAFE-MODE launch create a session and take a turn?
//
// WHY THIS EXISTS
// ---------------
// PLAN-19 §9 criterion 5 says "safe mode opens the page, creates a session and
// sends one message", and §11 item 3 flagged the risk that skipping a plugin could
// leave the session RPC surface pending. That risk is real and was measured the
// expensive way: `dsh-api-session-controller` declares
//
//     static inject = ["agentDefaultModel", "agents", "attachments", "fileUploads",
//                      "fs", "llm", "remoteAccess", "sessions", "sessionProjections",
//                      "sessionQuery", "typert", "workspaceRegistry"]
//
// so skipping `attachment-ios` — the only `ctx.attachments` provider, because the
// app layer disables the stock `attachment-local` — leaves `attachments` and
// `fileUploads` unprovided and the controller pending. The page still opened, the
// boot guard counted a success, and no session could be created: exactly the
// "opens but is useless" state the safe-mode list is supposed to avoid.
//
// The BROWSER cannot be the instrument here. At 402 px the sidebar is a rail and
// its rows never enter the DOM (REPORT-6, and `sim/session-continue-acceptance.mjs`
// carries the measurements), so a UI-driven run would report "no session row" for
// a reason that has nothing to do with this criterion.
//
// What IS measurable is what the UI's buttons ultimately reach: the real
// `sessionQuery` / `sessionController` services, mounted through DSH's own profile
// loader, in whatever composition the launch actually used. That is what this
// module does — and because it runs under the same `--patch` overlay a safe-mode
// launch appends, it measures the safe-mode composition rather than the normal one.
//
// WHAT IT RECORDS
//   * `boot`          — did the profile mount at all
//   * `services`      — which of the services the controller injects are present;
//                       the names come from the controller's own inject list
//   * `create-session`— a real `createSession`, and the id it returned
//   * `turn`          — one prompt through `sessionController.prompt`, then the
//                       session log read back: a `user/message` carrying this
//                       prompt and a new `turn/end`
//
// GATED: `sim/ios-app-entry.mjs` imports this when `DSHPORTE_STEP19_SAFE_PROBE=1`,
// which the Swift host forwards from `-DSHPortEStep19SafeProbe 1`. It exits the
// process afterwards. A normal launch never sets the flag.

import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { randomUUID } from 'node:crypto';

const RESULT_NAME = 'DSHPortE-step19-safe-probe.json';

function resultPath() {
  const workspace = process.env.DSH_IOS_WORKSPACE ?? process.cwd();
  return process.env.DSHPORTE_STEP19_PROBE_OUT ?? join(dirname(workspace), RESULT_NAME);
}

const report = {
  startedAt: new Date().toISOString(),
  node: process.versions.node,
  overlay: null,
  criteria: {},
};

function write() {
  try {
    writeFileSync(resultPath(), `${JSON.stringify(report, null, 2)}\n`);
  } catch (error) {
    process.stderr.write(`step19-safe-probe: could not write the report: ${error}\n`);
  }
}

function record(id, value) {
  report.criteria[id] = value;
  write();
}

const payload = process.env.IOS_SIM_DSH_INSTALL ?? join(process.env.IOS_SIM_BUNDLE ?? '.', 'payload');
const payloadPath = (name) => join(payload, 'node_modules', '@deepseek-ai', name, 'lib', 'index.js');

// The SAME loader hooks the production entry registers, registered here FIRST, so
// this probe measures the shipped composition rather than a bare payload.
//
// MEASURED, THE HARD WAY: without this, the turn ended at once with
//
//     turn/end -> {"reason": {"kind": "error",
//                  "error": {"message": "flock is not supported on ios-arm64"}}}
//
// and the mock was never asked anything. `dsh-session-persistence-jsonl` takes the
// flock at import time, the native addon has no iOS build, and the pure-JS redirect
// is what `flock-hook.mjs` registers. The probe imports the profile itself, so it
// has to register the hook itself — the production entry's registration happened in
// the OTHER module graph. Steps 7, 8 and 9 each answer this the same way and their
// comments say so; this is the same trap, and it is why the first three runs of this
// probe reported a failure that had nothing to do with safe mode.
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
      record(`hook_${file}`, { ok: false, error: String(error && error.message ? error.message : error) });
    }
  }
}

const { runProfile } = await import(join(payload, 'node_modules/@deepseek-ai/dsh/lib/profile-boot.js'));
const appBoot = await import(payloadPath('dsh-app-boot'));

// The overlay a safe-mode launch passes on the command line. Read from argv rather
// than from an environment variable so the probe measures the composition this
// process was ACTUALLY started with; the flag is inserted by `ios-app-entry.mjs`,
// which is the same code path a real safe-mode boot uses.
function overlayFromArgv() {
  const argv = process.argv.slice(2);
  for (let i = 0; i < argv.length - 1; i += 1) {
    if (argv[i] === '--patch') return argv[i + 1];
  }
  return undefined;
}

const patchFiles = [];
const overlay = overlayFromArgv();
if (overlay !== undefined) {
  patchFiles.push(overlay);
  report.overlay = overlay;
}

let ctx;
try {
  // `loadLayeredEnv('dsh')` returns the dotenv layers, NOT `process.env`, and the
  // profile's `!!js` expressions (`agent-default-model`, `llm-pi-ai-mock`) read the
  // launch environment directly. Without this spread the mock route does not exist,
  // the default model is `deepseek-official` with no key, and a turn ends with a
  // `turn/start` + `turn/end` pair and NO model call at all — which is exactly what
  // the first run of this probe measured: `eventCount: 7`, no `user/message`, and
  // `requests: 0` on the mock's own health endpoint. The turn looked successful
  // ("a turn/end was written") while nothing had been asked of any model.
  const mounted = await runProfile({
    environment: { ...appBoot.loadLayeredEnv('dsh'), ...process.env },
    profile: 'ios-sim',
    patchFiles,
    args: [],
  });
  ctx = mounted?.ctx;
  if (ctx === undefined) throw new Error('runProfile returned no context');
} catch (error) {
  record('boot', { ok: false, error: String(error && error.message ? error.message : error) });
  process.stdout.write(`DSHPORTE_STEP19_PROBE ${JSON.stringify(report.criteria)}\n`);
  process.exit(1);
}
record('boot', { ok: true, patchFiles });
// What the profile's `!!js` expressions will actually see. Recorded because these
// three decide whether a turn reaches a model at all, and a turn that closes
// without a model call looks identical to one that worked if nobody checks.
record('environment', {
  mockPort: process.env.DSHPORTC_MOCK_PORT ?? null,
  defaultProvider: process.env.DSH_PORTE_DEFAULT_PROVIDER ?? null,
  defaultModel: process.env.DSH_PORTE_DEFAULT_MODEL ?? null,
  dshHome: process.env.DSH_HOME ?? null,
  guestChannelUrl: process.env.DSH_GUEST_CHANNEL_URL ?? null,
});

// Which of the controller's own inject names this composition actually provides.
// Spelled out rather than derived, so the report states the requirement instead of
// re-deriving it at run time from a service list that may itself be the problem.
const CONTROLLER_INJECTS = [
  'agentDefaultModel', 'agents', 'attachments', 'fileUploads', 'fs', 'llm',
  'remoteAccess', 'sessions', 'sessionProjections', 'sessionQuery', 'typert',
  'workspaceRegistry',
];
record('services', Object.fromEntries(CONTROLLER_INJECTS.map((name) => {
  try {
    return [name, ctx.get(name) !== undefined];
  } catch {
    return [name, false];
  }
})));

/**
 * How many requests the mock has answered, or null when there is no mock.
 *
 * WHY THE PROBE ASKS THIS ITSELF
 * ------------------------------
 * "A turn ended" is not the same as "the model was asked". The first run of this
 * probe reported `turn.ok: true` from a `turn/end` that arrived with no
 * `user/message` and no `assistant/message` alongside it — the turn had been closed
 * before any model call, because the profile's default route was the real provider
 * and there was no key. The mock's own counter was 0, which is the fact that
 * distinguishes the two. So the counter is read before and after, and a turn only
 * counts when it moved.
 *
 * @returns {Promise<number|null>}
 */
async function mockRequests() {
  const port = process.env.DSHPORTC_MOCK_PORT;
  if (port === undefined || port === '') return null;
  try {
    const response = await fetch(`http://127.0.0.1:${port}/healthz`);
    if (!response.ok) return null;
    const body = await response.json();
    return typeof body.requests === 'number' ? body.requests : null;
  } catch {
    return null;
  }
}

/**
 * The prompt to send.
 *
 * `\n` in the value is turned back into a real newline before it is used. That is
 * not cosmetic: `simctl launch -DKey value` takes one argument per `-D`, so a
 * literal newline in the value is re-split by the launcher and the second line
 * arrives as a separate launch argument — measured on the simulator, where the
 * probe then reported `no-report` because the app never got a prompt it recognised.
 * With the escape, the command line stays one line and the mock's own
 * `parseBashScript` (which splits on real newlines) sees the lines it expects.
 */
const promptText = (process.env.DSHPORTE_STEP19_PROMPT ?? 'STEP19 safe mode turn')
  .replace(/\\n/g, '\n');
try {
  const controller = ctx.get('sessionController');
  if (controller === undefined) throw new Error('sessionController is not mounted');
  // `sessionController` is the RPC-facing service (`super(ctx, "sessionController",
  // { namespace: "session" })`), and its method is `create`, not `createSession` —
  // the latter belongs to the internal command layer. Measured: calling
  // `createSession` on this service answered "is not a function" on the device.
  const created = await controller.create({});
  const id = created?.sessionId ?? created?.id ?? created?.header?.id ?? null;
  if (id === null) throw new Error(`create returned no id: ${JSON.stringify(created)}`);
  record('create-session', { ok: true, id });

  const query = ctx.get('sessionQuery');
  const before = await query.readSession(id);
  const turnEndsBefore = before.events.filter((event) => event?.type === 'turn/end').length;
  const mockBefore = await mockRequests();

  // The RPC shape, not the internal one: `content` is an array of parts, and the
  // deduplication key is `requestId`. An abort signal is required by the signature
  // (`signal.throwIfAborted()` runs first), so a never-aborting one is passed.
  await controller.prompt({
    sessionId: id,
    requestId: `step19-probe-${randomUUID()}`,
    content: [{ type: 'text', text: promptText }],
  }, new AbortController().signal);

  // The turn is asynchronous; poll the log until a new `turn/end` lands or the
  // deadline passes. 60 s is the tool timeout budget and this run sends one short
  // prompt to a local mock.
  const deadline = Date.now() + 60_000;
  let after = await query.readSession(id);
  while (Date.now() < deadline) {
    const turnEnds = after.events.filter((event) => event?.type === 'turn/end').length;
    if (turnEnds > turnEndsBefore) break;
    await new Promise((resolve) => { setTimeout(resolve, 250); });
    after = await query.readSession(id);
  }
  const turnEndsAfter = after.events.filter((event) => event?.type === 'turn/end').length;
  // The prompt's TEXT is not asserted, and that is a deliberate limit rather than
  // an oversight: `sessionQuery.readSession` returns the events it decodes, and on
  // this build the log is `session.v4.jsonl.zstd`, so the decoded event carries no
  // plain string for `JSON.stringify` to find. Measured here: `sawPrompt` was false
  // for a turn that plainly ran (a `turn/start` and a `turn/end` were written, and
  // the mock logged the request). What IS asserted is the pair that only a real
  // turn produces — a `turn/start` and a NEW `turn/end` — plus the event count
  // growing. The prompt content is checked on the mock side, where the request
  // arrives in the clear.
  const types = [...new Set(after.events.map((event) => event?.type).filter(Boolean))];
  // The events themselves, for the report: a `turn/end` on its own does not say
  // WHY the turn ended, and "no model call happened" has several causes. Recording
  // the shapes here is what turned this from "it passed" into a fact.
  // Truncated as TEXT, not as JSON: slicing a serialized object and parsing it
  // back throws `Unterminated string in JSON`, which is how this line cost a run.
  const clip = (value) => {
    if (value === undefined) return null;
    const text = JSON.stringify(value);
    return text.length <= 900 ? value : `${text.slice(0, 900)}…`;
  };
  record('events', after.events.map((event) => ({
    type: event?.type,
    keys: event && typeof event === 'object' ? Object.keys(event) : null,
    data: clip(event?.data),
  })));
  const mockAfter = await mockRequests();
  const modelCalled = mockBefore === null || mockAfter === null ? null : mockAfter > mockBefore;
  const wroteMessages = types.includes('user/message') || types.includes('assistant/message');
  record('turn', {
    // All three, because each one alone has been seen to be true of a turn that did
    // not actually happen: a new `turn/end` (the pair closed), a `turn/start` (the
    // turn was admitted), and either a message event or a moving mock counter (the
    // work reached a model).
    ok: turnEndsAfter > turnEndsBefore
      && types.includes('turn/start')
      && (wroteMessages || modelCalled === true),
    // Whether the composition asked a human before running a destructive command.
    // `null` when this prompt never proposed one — the probe runs several different
    // prompts and this fact only exists for the approval arm.
    approvalAsked: types.includes('approval/asked') ? true
      : (types.includes('tool/result') ? false : null),
    turnEndsBefore,
    turnEndsAfter,
    eventCount: after.events.length,
    types,
    mockRequestsBefore: mockBefore,
    mockRequestsAfter: mockAfter,
    modelCalled,
    wroteMessages,
  });
} catch (error) {
  const message = String(error && error.message ? error.message : error);
  record(report.criteria['create-session'] === undefined ? 'create-session' : 'turn', {
    ok: false,
    error: message,
  });
}

// Step 19B: the guest's own `node` running `node --test`, when asked for.
//
// The task asks for the step-19 tests to be run once under the phone's Node 22 as
// well as on the host's Node 24. This is that run, driven through the SHIPPED
// `ctx.subprocess` provider so the result is about the same execution world the
// model's `bash` tool uses. REPORT-24 measured that this Node aborts inside libuv
// on its first thread creation, so the command is wrapped in `timeout -s KILL`
// (a plain SIGTERM is not enough for a process stuck in its own signal path) and a
// timeout is a RESULT here, not an error.
if (process.env.DSHPORTE_STEP19_GUEST_TESTS === '1') {
  const subprocess = ctx.get('subprocess');
  const workspace = process.env.DSH_IOS_WORKSPACE ?? process.cwd();
  const guestDir = process.env.DSHPORTE_STEP19_GUEST_DIR ?? '/workspace/step19-guestsrc';
  const files = ['boot-guard', 'safe-mode', 'diagnostics', 'reset-plan']
    .map((name) => `tests/step19/${name}.test.mjs`).join(' ');
  const runs = [
    { id: 'node-version', command: 'node --version' },
    { id: 'node-eval', command: 'node -e ""' },
    { id: 'node-test', command: `cd ${guestDir} && node --test ${files}` },
  ];
  const results = [];
  for (const run of runs) {
    const started = Date.now();
    try {
      // `ctx.subprocess` is the provider interface, not `child_process`: `spawn()`
      // returns a handle whose `done` resolves to `{exitCode, signal}` and whose
      // `collected.stdout` is an `OutputCollector` with `finalize()`. Measured — the
      // first version of this block called `subprocess.run(...)`, which does not
      // exist on the provider, and every "guest node" result was that TypeError
      // rather than a fact about the guest.
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 130_000);
      let handle;
      try {
        // The provider's spec is `argv`, not `command`/`args` — measured: the
        // three rejected spellings above are each one round trip through the
        // device to discover.
        handle = subprocess.spawn({
          // Absolute paths: the provider resolves a bare name through the guest's
          // PATH via the channel, and its search answered "not found" for
          // `timeout` even though `/usr/bin/timeout` is in the image (present in
          // `build/rootfs/ish-rootfs.tar.gz` as `./data/usr/bin/timeout`). Naming
          // the path skips that lookup entirely and measures the thing this run is
          // about — the guest's `node`.
          argv: ['/usr/bin/timeout', '-s', 'KILL', '120', '/bin/sh', '-c',
            `cd ${guestDir} 2>/dev/null || true; ${run.command}`],
          cwd: workspace,
          env: {},
          // Required by the provider's spec validator; measured — omitting it is
          // `subprocess graceMs must be a positive finite number`.
          graceMs: 2000,
          stdio: {
            stdin: { kind: 'ignore' },
            stdout: { kind: 'collect', maxBytes: 64 * 1024 },
            stderr: { kind: 'collect', maxBytes: 16 * 1024 },
          },
          signal: controller.signal,
        });
        const exit = await handle.done;
        await handle.waitForExit();
        results.push({
          id: run.id,
          command: run.command,
          exitCode: exit?.exitCode ?? null,
          signal: exit?.signal ?? null,
          ms: Date.now() - started,
          stdoutTail: String(handle.collected?.stdout?.finalize()?.text ?? '').slice(-4000),
          stderrTail: String(handle.collected?.stderr?.finalize()?.text ?? '').slice(-2000),
        });
      } finally {
        clearTimeout(timer);
      }
    } catch (error) {
      results.push({
        id: run.id,
        command: run.command,
        thrown: String(error && error.message ? error.message : error),
        ms: Date.now() - started,
      });
    }
  }
  record('guest-node', results);
}

report.finishedAt = new Date().toISOString();
write();
process.stdout.write(`DSHPORTE_STEP19_PROBE ${JSON.stringify(report.criteria)}\n`);
process.exit(0);
