// Can a session that survived a container change still take a turn?
//
// WHY THIS EXISTS, AND WHAT IT ADDS TO session-list-acceptance.mjs
// ---------------------------------------------------------------
// Step 6's first criterion is "the session from before the change is still in the
// list, can be OPENED, and can take one more turn". `session-list-acceptance.mjs`
// answers the listing and the open. It cannot answer the turn, and the reason is
// not laziness: the sidebar cannot be clicked on this device.
//
//   Measured in this step, with the driver's own records: the WKWebView lays out
//   at 402 px, which is below DSH's 1024 px `SIDEBAR_AUTO_COLLAPSE` threshold, so
//   the sidebar is a 56 px rail. Twelve presses of the rail toggle left
//   `data-sidebar-collapsed` in place, `[data-row-key]` never entered the document,
//   and `pressFirstSessionScript()` answered `no-session-row`. `session_in_list`
//   reported `{"renderedRow":false,"inBody":false}`, and the turn that then ran
//   landed in a NEW session (`dsh.sessions.current` held a different id) — so the
//   browser-driven run cannot be the evidence for this criterion.
//
// What CAN be measured is the thing the row would have done: hand the session to
// DSH's own session controller and let it run a turn. That is not a simulation of
// the UI — it is the same service the RPC that the UI's send button ultimately
// reaches (`sessionController.prompt`, `dsh-api-session-controller`), mounted with
// the real `ios-sim` profile, against the real migrated log on disk. If the log
// were unusable, resuming it is exactly where that would surface.
//
// WHAT IT RECORDS
//   * the log's size, event count and last event BEFORE the turn,
//   * the same log's size and event count AFTER the turn,
//   * whether the new events landed in the SAME session id (not a new one),
//   * whether a `user/message` carrying this prompt and a `turn/end` were written,
//   * whether the pre-existing events are still there and unchanged.
//
// GATED like the others: `sim/ios-app-entry.mjs` imports this when
// `DSHPORTE_SESSION_CONTINUE=1`, and it exits the process afterwards.
//
// USAGE (from the Swift host's forwarded flags)
//   -DSHPortCTestContinueSession 1
//   -DSHPortCTestSessionId <id>
//   -DSHPortCTestContinuePrompt "<text>"

import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';

const RESULT_NAME = 'DSHPortE-session-continue-acceptance.json';

function resultPath() {
  const workspace = process.env.DSH_IOS_WORKSPACE ?? process.cwd();
  return process.env.DSHPORTE_CONTINUE_OUT ?? join(dirname(workspace), RESULT_NAME);
}

const report = { startedAt: new Date().toISOString(), node: process.versions.node, criteria: {} };

function record(id, value) {
  report.criteria[id] = value;
  write();
}

function write() {
  try {
    writeFileSync(resultPath(), JSON.stringify(report, null, 2));
  } catch (error) {
    process.stderr.write(`session-continue-acceptance: could not write the report: ${error}\n`);
  }
}

const payload = process.env.IOS_SIM_DSH_INSTALL ?? join(process.env.IOS_SIM_BUNDLE ?? '.', 'payload');
const payloadPath = (name) => join(payload, 'node_modules', '@deepseek-ai', name, 'lib', 'index.js');
const { runProfile } = await import(join(payload, 'node_modules/@deepseek-ai/dsh/lib/profile-boot.js'));
const appBoot = await import(payloadPath('dsh-app-boot'));

let ctx;
try {
  const mounted = await runProfile({
    environment: appBoot.loadLayeredEnv('dsh'),
    profile: 'ios-sim',
    patchFiles: [],
    args: [],
  });
  ctx = mounted?.ctx;
  if (ctx === undefined) throw new Error('runProfile returned no context');
} catch (error) {
  record('boot', { ok: false, error: String(error && error.message ? error.message : error) });
  process.stdout.write(`DSHPORTE_SESSION_CONTINUE ${JSON.stringify(report.criteria)}\n`);
  process.exit(1);
}
record('boot', { ok: true });

const target = process.env.DSHPORTE_EXPECT_SESSION;
const promptText = process.env.DSHPORTE_CONTINUE_PROMPT ?? 'STEP echo continued-after-container-change';

if (!target) {
  record('setup', { ok: false, error: 'DSHPORTE_EXPECT_SESSION is not set' });
  write();
  process.stdout.write(`DSHPORTE_SESSION_CONTINUE ${JSON.stringify(report.criteria)}\n`);
  process.exit(2);
}

/** Read a session's events through the service the session view itself uses. */
async function snapshot(query, sessionId) {
  const loaded = await query.readSession(sessionId);
  const events = loaded.events;
  return {
    eventCount: events.length,
    types: [...new Set(events.map((event) => event && event.type).filter(Boolean))],
    // A COUNT, not a boolean. The migrated log already contains one `turn/end`
    // from before the container change, so "hasTurnEnd" is true before this run
    // does anything — and a wait on it returns immediately, before the new turn
    // has finished. Measured: the first version waited on the boolean, broke out
    // on the first poll, and reported turnEndCount=1 while the follow-up was
    // still streaming.
    turnEndCount: events.filter((event) => event && event.type === 'turn/end').length,
    lastType: events.length > 0 ? events[events.length - 1]?.type ?? null : null,
    cwd: loaded.session.cwd,
    createdAt: loaded.session.createdAt,
  };
}

try {
  const query = ctx.get('sessionQuery');
  const controller = ctx.get('sessionController');
  const persistence = ctx.get('sessionPersistence');
  if (query === undefined) throw new Error('sessionQuery is not mounted');
  if (controller === undefined) throw new Error('sessionController is not mounted');

  // The session must be listed before it can be continued; otherwise "it took a
  // turn" would be a statement about a different session than the one the
  // container change moved.
  const listed = await query.listSessions();
  const ids = listed.map((row) => row.header.id);
  record('listed_before_continue', { ids, containsTarget: ids.includes(target) });

  const statBefore = persistence === undefined ? null : await persistence.stat(target);
  const before = await snapshot(query, target);
  record('before', {
    ...before,
    sizeBytes: statBefore?.sizeBytes ?? null,
    formatStatus: statBefore?.formatStatus ?? null,
  });

  // A prompt id that the controller can deduplicate against. Unique per run so a
  // repeated acceptance does not look like the earlier one's no-op replay.
  const requestId = `step6-continue-${Date.now()}`;
  const accepted = await controller.prompt({
    sessionId: target,
    requestId,
    mode: 'followup',
    content: [{ type: 'text', text: promptText }],
  }, new AbortController().signal);
  record('prompt_accepted', accepted);

  // Wait for the turn to finish. The mock answers a `STEP` prompt with a bash tool
  // call and a closing reply, so a completed turn shows up as one more `turn/end`.
  //
  // The condition is "one MORE than before", not "any": the migrated log already
  // ends with a `turn/end` from before the container change, and a wait on the
  // boolean broke out on its first poll, mid-reply (measured — that is why the
  // first run of this module recorded turnEndCount=1).
  const deadline = Date.now() + 180_000;
  let after = null;
  while (Date.now() < deadline) {
    after = await snapshot(query, target);
    if (after.turnEndCount > before.turnEndCount && after.eventCount > before.eventCount) break;
    await new Promise((resolve) => setTimeout(resolve, 2_000));
  }

  const statAfter = persistence === undefined ? null : await persistence.stat(target);
  record('after', {
    ...(after ?? {}),
    sizeBytes: statAfter?.sizeBytes ?? null,
    formatStatus: statAfter?.formatStatus ?? null,
  });

  // The claim: the SAME session grew, and the growth contains the prompt and a
  // finished turn. `query.listSessions()` is checked again so "it is still one
  // session, not a fork" is a measured fact rather than an assumption.
  const listedAfter = await query.listSessions();
  const idsAfter = listedAfter.map((row) => row.header.id);
  record('took_a_turn', {
    grew: after !== null && before.eventCount !== undefined && after.eventCount > before.eventCount,
    finishedATurn: after !== null && after.turnEndCount > before.turnEndCount,
    eventCountBefore: before.eventCount,
    eventCountAfter: after?.eventCount ?? null,
    turnEndsBefore: before.turnEndCount,
    turnEndsAfter: after?.turnEndCount ?? null,
    bytesBefore: statBefore?.sizeBytes ?? null,
    bytesAfter: statAfter?.sizeBytes ?? null,
    sameSessionStillListed: idsAfter.includes(target),
    sessionCount: idsAfter.length,
  });

  // The pre-existing events must be intact: a migration that silently truncated
  // the history would still "accept a turn". Two `turn/end`s (the original and
  // this one), the original opening event still first, and the new prompt present.
  const reloaded = await query.readSession(target);
  const textOf = (events) => events.map((event) => JSON.stringify(event)).join('\n');
  record('history_intact', {
    hasOriginalTurnEnd: reloaded.events.filter((event) => event && event.type === 'turn/end').length >= 2,
    turnEndCount: reloaded.events.filter((event) => event && event.type === 'turn/end').length,
    firstEventTypeMatchesBefore: reloaded.events.length > 0 && reloaded.events[0]?.type === (before.types[0] ?? null),
    carriesTheNewPrompt: textOf(reloaded.events).includes(promptText),
  });
} catch (error) {
  record('error', { message: String(error && error.message ? error.message : error), code: error && error.code });
}

write();
process.stdout.write(`DSHPORTE_SESSION_CONTINUE ${JSON.stringify(report.criteria)}\n`);
process.exit(0);
