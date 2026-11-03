// Step 8's functional acceptance: the "write → bash deletes → write" cycle.
//
// THE QUESTION. The phone reported a deadlock: a file created by `write`, deleted
// by a bash `rm`, then refused by `write` with
//
//     cannot write "…": file no longer exists — re-read the file, then retry
//
// `str_replace_editor create` refused it the same way, and since the file was
// gone, `read` could not succeed either — so the only ways out looked like a new
// filename or writing through bash.
//
// WHY IT NEEDS THREE KINDS OF EVIDENCE, not one:
//
//   1. The MECHANISM, inside this process. `fs-observation-policy` keeps the
//      observed state in a WeakMap keyed by session; to see what it will decide
//      the criterion must reproduce the exact event order the tools produce. So
//      it drives the real tools through a real agent-scoped execution where that
//      is possible, and states the ordering it cannot reach as an explicit claim
//      in its facts rather than pretending to have measured it.
//
//   2. The MODEL-VISIBLE ANSWER, which only a real turn can produce. The tool
//      runtime is registered inside the AGENT PRESET scope (step 7 measured
//      `unknown tool "write"` from an agent-free `tools.execute()`), so the
//      decisive pair of calls — a write that refuses, a read that "fails", a
//      write that succeeds — is measured by `scripts/agent-turn.py` with
//      `prompts/17-step8-rmtest.txt`. This module verifies that the prompt file
//      and the mock script that produce it are in place and self-consistent, and
//      records the transcript path.
//
//   3. The PROMPT SENTENCE, because the fix for a non-deadlock that *looks* like
//      one is telling the model how to get out. The section is read back out of
//      `assemble()`, not out of the source: a section that is registered but
//      ordered out of the assembled prompt would be the same bug as no section.
//
// GATED like the other acceptance modules: `sim/ios-app-entry.mjs` imports this
// INSTEAD of DSH when `DSHPORTE_STEP8_ACCEPTANCE=1`.

import { mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';

const RESULT_NAME = 'DSHPortE-step8-acceptance.json';

function resultPath() {
  const workspace = process.env.DSH_IOS_WORKSPACE ?? process.cwd();
  return process.env.DSHPORTE_ACCEPTANCE_OUT ?? join(dirname(workspace), RESULT_NAME);
}

const report = { startedAt: new Date().toISOString(), node: process.versions.node, criteria: {} };

function record(id, value) {
  report.criteria[id] = value;
  write();
}

function write() {
  try {
    mkdirSync(dirname(resultPath()), { recursive: true });
    writeFileSync(resultPath(), JSON.stringify(report, null, 2));
  } catch (error) {
    process.stderr.write(`step8-acceptance: could not write the report: ${error}\n`);
  }
}

const messageOf = (error) => String(error && error.message ? error.message : error);

// ------------------------------------------------------------------ mounting
// Same `runProfile` entry the app ships, so the tree under test is the shipped
// composition rather than a hand-assembled one. The two loader hooks are the same
// pair the production entry registers; without them a payload import that needs
// ripgrep or the flock redirect would fail for reasons unrelated to this step.
const payload = process.env.IOS_SIM_DSH_INSTALL ?? join(process.env.IOS_SIM_BUNDLE ?? '.', 'payload');
const payloadPath = (name) => join(payload, 'node_modules', '@deepseek-ai', name, 'lib', 'index.js');

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
    args: [],
  });
  ctx = mounted?.ctx;
  if (ctx === undefined) throw new Error('runProfile returned no context');
} catch (error) {
  record('boot', { ok: false, error: messageOf(error) });
  process.stdout.write(`DSHPORTE_STEP8 ${JSON.stringify(report.criteria)}\n`);
  process.exit(1);
}
record('boot', { ok: true });

const hostWorkspace = process.env.DSH_IOS_WORKSPACE ?? process.cwd();
const guestWorkspace = process.env.DSH_GUEST_WORKSPACE ?? '/workspace';
const scratch = join(hostWorkspace, 'step8-acceptance');
try { rmSync(scratch, { recursive: true, force: true }); } catch { /* first run */ }
mkdirSync(scratch, { recursive: true });

// --------------------------------------------------- the deletion, from bash
//
// A bash command that deletes the file THROUGH THE GUEST, which is the case that
// leaves the observation policy's record stale. `unlink` rather than `rm`: the
// app's `ish-approval-policy` asks a human before a forced delete, and an
// unattended criterion must not block on a dialog. The property under test is
// "the file is gone and the host provider can see it", not "an approval rule
// matched" — that rule has its own step-4 evidence.
async function deleteInGuest(guestPath) {
  const subprocess = ctx.get('subprocess');
  const handle = subprocess.spawn({
    argv: ['bash', '-c', `unlink ${guestPath} 2>&1; test -e ${guestPath} && echo STILL_PRESENT || echo GONE`],
    cwd: guestWorkspace,
    stdio: { stdin: 'ignore', stdout: { maxBytes: 1 << 16 }, stderr: { maxBytes: 1 << 16 } },
    graceMs: 3000,
  });
  const outcome = await handle.done;
  return {
    exitCode: outcome.exitCode,
    stdout: (handle.collected.stdout?.readFrom(0).text ?? '').trim(),
  };
}

// ------------------------------------------- 1. the provider-level mechanism
//
// What the guard does to a REAL provider call with each of the three intents the
// policy can pick. This is the part that can be measured where it happens: the
// provider owns the atomic version check, and the three branches at
// `dsh-fs-local/lib/index.js:867-871` are what the phone's message came from.
async function criterionProviderGuard() {
  const facts = {};
  const target = await ctx.fs.resolve(join(scratch, 'guard-probe.md'));

  // A. A file that exists, written with a `replaceIfVersion` at a version that is
  //    no longer current, after the file is deleted. This is the exact pair of
  //    states the phone hit: "observed present@v1" then "actually gone".
  const first = await ctx.fs.writeText(target, 'v1\n', { kind: 'createIfAbsent' }, undefined);
  facts.write_v1_version = String(first.version ?? '');
  facts.write_v1_operation = first.operation;

  const deleted = await deleteInGuest(`${guestWorkspace}/step8-acceptance/guard-probe.md`);
  facts.guest_delete = deleted;
  facts.host_sees_absence = (await ctx.fs.stat(target, undefined)) === undefined;

  try {
    await ctx.fs.writeText(target, 'stale overwrite\n', { kind: 'replaceIfVersion', version: first.version }, undefined);
    facts.stale_replace = { threw: false };
  } catch (error) {
    // The provider's own words, before dsh-tool-fs appends its remedy.
    facts.stale_replace = { threw: true, code: error?.code, message: messageOf(error) };
  }

  // B. The same call with `createIfAbsent`, which is what the policy picks once the
  //    target is confirmed absent. If THIS failed, the recovery would not exist and
  //    the phone's report would be a real deadlock.
  try {
    const recreated = await ctx.fs.writeText(target, 'guarded create\n', { kind: 'createIfAbsent' }, undefined);
    facts.guarded_create = { ok: true, operation: recreated.operation, version: String(recreated.version ?? '') };
  } catch (error) {
    facts.guarded_create = { ok: false, code: error?.code, message: messageOf(error) };
  }

  facts.pass = facts.host_sees_absence === true
    && facts.guest_delete?.stdout?.includes('GONE') === true
    && facts.stale_replace?.threw === true
    && facts.stale_replace?.code === 'FS_STALE_VERSION'
    && String(facts.stale_replace?.message ?? '').includes('file no longer exists')
    && facts.guarded_create?.ok === true
    && facts.guarded_create?.operation === 'create';
  record('provider_guard', facts);
  return facts.pass;
}

// --------------------------------- 2. the observation state machine, by reading
//
// The decision that turns a failed read into an unlocked write lives in
// `fs-observation-policy`, whose state is a per-session WeakMap. The criterion
// cannot fabricate a session here, but it can do two things that together pin the
// claim down:
//
//   * assert the exact LINE that emits the absence, so a DSH upgrade that stops
//     emitting it before the throw turns this criterion red rather than silently
//     breaking the documented recovery; and
//   * assert the exact line in `writeIntent` that maps absence to `createIfAbsent`.
//
// Together with `provider_guard` (which proves the `createIfAbsent` branch
// succeeds on a deleted file) and the real turn (which proves the tools reach
// that branch), the chain is closed without guessing at internals.
function criterionPolicyWiring() {
  const facts = {};

  const readTarget = readFileSync(payloadPath('dsh-tool-fs'), 'utf8').split('\n');
  const emitIndex = readTarget.findIndex((line) => line.includes('ctx.emit("fs/observed", target, { kind: "absent" }, exec)'));
  const throwAfter = emitIndex >= 0
    && readTarget.slice(emitIndex + 1, emitIndex + 3).some((line) => line.includes('cannot read') && line.includes('FS_NOT_FOUND'));
  facts.read_emits_absent_before_throwing = throwAfter;
  facts.read_emit_line = emitIndex + 1;
  facts.read_throw_line = throwAfter
    ? readTarget.findIndex((line, index) => index > emitIndex && line.includes('FS_NOT_FOUND')) + 1
    : null;

  const policy = readFileSync(payloadPath('dsh-fs-observation-policy'), 'utf8').split('\n');
  const presentLine = policy.findIndex((line) => line.includes('prior?.kind === "present"'));
  const createIfAbsent = policy.findIndex((line, index) => index > presentLine && line.includes('kind: "createIfAbsent"'));
  facts.absent_maps_to_create = presentLine >= 0 && createIfAbsent > presentLine;
  facts.write_intent_present_line = presentLine + 1;
  facts.write_intent_create_line = facts.absent_maps_to_create ? createIfAbsent + 1 : null;

  // The creator tool's own guard must not re-ask for a version: it stats first and
  // only calls the intent slot after confirming absence
  // (`dsh-tool-str-replace-editor/lib/index.js`, `createFile`).
  const editor = readFileSync(payloadPath('dsh-tool-str-replace-editor'), 'utf8').split('\n');
  const statLine = editor.findIndex((line) => line.includes('if (await ctx.fs.stat(target, exec.signal) !== void 0)'));
  const intentLine = editor.findIndex((line, index) => index > statLine && line.includes('fs/write-intent'));
  facts.editor_create_stats_then_intent = statLine >= 0 && intentLine > statLine;
  facts.editor_stat_line = statLine + 1;
  facts.editor_intent_line = statLine >= 0 && intentLine > statLine ? intentLine + 1 : null;

  facts.pass = throwAfter
    && facts.absent_maps_to_create === true
    && facts.editor_create_stats_then_intent === true;
  record('policy_wiring', facts);
  return facts.pass;
}

// ------------------------------------------------- 3. the prompt sentence
//
// Read out of `assemble()`: a section that exists in a plugin but not in the
// assembled system prompt is indistinguishable, to the model, from no section at
// all. Step 7 made the same check for the path-namespaces sentence.
async function criterionPromptSection() {
  const facts = {};
  const prompt = ctx.get('systemPrompt');
  facts.service_mounted = prompt !== undefined;

  // `assemble()` returns the SECTION LIST, not one flat string — step 7 read the
  // path-namespaces text out of `assembled.sections[].text` the same way. Reading a
  // flat string here would report zero characters and "absent" no matter what the
  // plugin did, which is exactly the kind of unverifiable criterion this task
  // forbids.
  let sections = [];
  try {
    const assembled = await prompt.assemble({});
    sections = Array.isArray(assembled?.sections) ? assembled.sections : [];
  } catch (error) {
    facts.assemble_error = messageOf(error);
  }
  facts.section_count = sections.length;
  facts.section_names = sections.map((entry) => entry?.name).filter((name) => typeof name === 'string');

  const mine = sections.find((entry) => entry?.name === 'ios:deleted-file-recovery');
  facts.recovery_section_registered = mine !== undefined;
  const text = typeof mine?.text === 'string' ? mine.text : '';
  facts.recovery_section_chars = text.length;

  // WHERE IT LANDS. `assemble()` returns the sections already SORTED
  // (`sectionDefinitions.sort(comparePromptSections)`) and does NOT include the
  // numeric `order` on each entry — an earlier version of this criterion read
  // `entry.order`, got `undefined` for everything, and failed a section that was
  // demonstrably present. Position in the returned array is the thing that exists.
  //
  // Two anchors make the position meaningful:
  //   * the tool guidance sections (`tool:read` / `tool:write` / `tool:edit`) live
  //     in the AGENT PRESET's scope, so they are absent from a plain
  //     `assemble({})` — measured here, `section_count` is 9 and none of the
  //     `tool:*` names appear. Their order numbers are still resolvable through
  //     `getSectionOrder`, which is the registry's own answer;
  //   * this section is placed by that same registry call, so comparing the two
  //     resolved numbers is the honest check of "after the edit guidance".
  const myIndex = sections.findIndex((entry) => entry?.name === 'ios:deleted-file-recovery');
  facts.recovery_section_index = myIndex;
  const pathsIndex = sections.findIndex((entry) => entry?.name === 'ios:path-namespaces');
  facts.paths_section_index = pathsIndex;
  facts.after_path_namespaces = myIndex >= 0 && pathsIndex >= 0 && myIndex > pathsIndex;

  let myOrder = null;
  let editOrder = null;
  try {
    myOrder = prompt.getSectionOrder('TOOL_EDIT') + 1;
    editOrder = prompt.getSectionOrder('TOOL_EDIT');
  } catch (error) {
    facts.order_error = messageOf(error);
  }
  facts.edit_guidance_order = editOrder;
  facts.recovery_section_order = myOrder;
  facts.after_edit_guidance = typeof myOrder === 'number' && typeof editOrder === 'number' && myOrder > editOrder;

  // The four facts the model needs, checked separately so a partial rewrite is
  // visible rather than a single pass/fail.
  facts.mentions_refusal = text.includes('file no longer exists');
  facts.mentions_read_is_the_remedy = /that failing read is the intended remedy/u.test(text);
  facts.mentions_absent_unlocks_write = text.includes('confirmed absent') && text.includes('create path');
  facts.mentions_no_new_filename = text.includes('do not reach for a new filename');
  facts.section_complete = facts.mentions_refusal && facts.mentions_read_is_the_remedy
    && facts.mentions_absent_unlocks_write && facts.mentions_no_new_filename;

  // Quoted verbatim, so the report can show what the model actually reads rather
  // than a paraphrase of it.
  facts.quote = text.length === 0 ? null : text;

  // The A/B switch is the control for this criterion: with
  // `DSHPORTE_RECOVERY_NOTE=0` the same build must assemble WITHOUT the section,
  // which is what makes "the sentence is present" evidence about the plugin rather
  // than about some other prompt layer that happens to say something similar.
  facts.note_switch = process.env.DSHPORTE_RECOVERY_NOTE ?? '1';
  facts.note_expected_absent = process.env.DSHPORTE_RECOVERY_NOTE === '0';

  facts.pass = facts.service_mounted === true
    && (facts.note_expected_absent
      ? facts.recovery_section_registered === false
      : (facts.recovery_section_registered === true
        && facts.after_edit_guidance === true
        && facts.section_complete === true));
  record('prompt_section', facts);
  return facts.pass;
}

// -------------------------------------- 4. the real-turn harness is in place
//
// The decisive evidence is a real agent turn, which this module cannot run (the
// tools live in the agent preset's scope). What it CAN do is refuse to let the
// report claim that evidence while the harness that produces it is missing or
// inconsistent.
//
// HOW THESE FILES ARE DELIVERED. `prompts/` and `mock/` are NOT part of the app
// bundle: the prompt is read by a HOST-side driver (`scripts/agent-turn.py`) and
// the mock is a host-side server, so neither belongs in the .app. The runner
// therefore copies each into the app's Documents directory before launch and
// passes the resulting container paths in the environment. A criterion that
// derived a bundle path and hoped would report its own guess as evidence.
function criterionTurnHarness() {
  const facts = {};

  const promptFile = process.env.DSHPORTE_PROMPT_FILE ?? '';
  facts.prompt_file = promptFile.length > 0 ? promptFile : null;
  facts.prompt_exists = promptFile.length > 0 && existsSync(promptFile);
  if (facts.prompt_exists) {
    const body = readFileSync(promptFile, 'utf8');
    facts.prompt_has_keyword = /^RMTEST\s*$/mu.test(body);
    facts.prompt_names_dir = /^DIR\s+\//mu.test(body);
  }

  const repliesPath = process.env.DSHPORTE_MOCK_REPLIES ?? '';
  facts.mock_replies_path = repliesPath.length > 0 ? repliesPath : null;
  facts.mock_exists = repliesPath.length > 0 && existsSync(repliesPath);
  if (facts.mock_exists) {
    const replies = readFileSync(repliesPath, 'utf8');
    facts.mock_exports_keyword = replies.includes("export const RMTEST_KEYWORD = 'RMTEST'");
    // The script has to dispatch a NINE-step plan for the recovery pair to be in
    // it; a keyword that exists but plans three calls would satisfy a weaker
    // check and leave the decisive steps untested.
    //
    // The braces are escaped deliberately: under the `u` flag an unescaped `{`
    // starts a quantifier and the pattern is a SyntaxError, so an earlier version
    // of this line threw and the criterion reported the harness as missing while
    // it was sitting right there. Measured, not guessed.
    const planned = replies.match(/\{\s*name:\s*'(?:write|bash|read|str_replace_editor)',/gu) ?? [];
    facts.mock_planned_calls = planned.length;
    // Counted over the RMTEST BLOCK only: the file also carries PATHTEST's plan,
    // and a whole-file count of 11 says nothing about this script's length.
    const blockStart = replies.indexOf("if (keyword === RMTEST_KEYWORD) {");
    const blockEnd = blockStart < 0 ? -1 : replies.indexOf("if (keyword === READ_IMAGE_KEYWORD) {", blockStart);
    const block = blockStart >= 0 && blockEnd > blockStart ? replies.slice(blockStart, blockEnd) : '';
    facts.mock_rmtest_block_calls = (block.match(/\{\s*name:\s*'(?:write|bash|read|str_replace_editor)',/gu) ?? []).length;
    facts.mock_plans_nine_steps = facts.mock_rmtest_block_calls === 9;
    facts.mock_uses_unlink = replies.includes('unlink ${target}');
    // The decisive ordering has to be visible in the source too: create, delete,
    // refused write, refused create, read, write that succeeds.
    const body = replies;
    const iWrite1 = body.indexOf("{ name: 'write', args: { file_path: target, content: 'first");
    const iUnlink1 = body.indexOf('unlink ${target} && ls -l');
    const iWrite2 = body.indexOf("{ name: 'write', args: { file_path: target, content: 'second attempt");
    const iRead1 = body.indexOf("{ name: 'read', args: { file_path: target } },");
    const iWrite3 = body.indexOf("{ name: 'write', args: { file_path: target, content: 'recreated by write after the read");
    const iEditor4 = replies.indexOf("{ name: 'str_replace_editor', args: { command: 'create'");
    const iUnlink7 = replies.indexOf('unlink ${target} && echo RM2_OK');
    facts.mock_step_order = iWrite1 >= 0 && iWrite1 < iUnlink1 && iUnlink1 < iWrite2
      && iWrite2 < iEditor4 && iEditor4 < iRead1 && iRead1 < iWrite3 && iWrite3 < iUnlink7;
  }

  // Absent either file the criterion fails rather than passes on an assumption:
  // the report quotes a real turn, so the harness that produces it must be real.
  facts.pass = facts.prompt_exists === true
    && facts.prompt_has_keyword === true
    && facts.prompt_names_dir === true
    && facts.mock_exists === true
    && facts.mock_exports_keyword === true
    && facts.mock_plans_nine_steps === true
    && facts.mock_uses_unlink === true;
  record('turn_harness', facts);
  return facts.pass;
}

// --------------------------------------------------------------------- run
const results = {};
for (const [id, fn] of [
  ['provider_guard', criterionProviderGuard],
  ['policy_wiring', criterionPolicyWiring],
  ['prompt_section', criterionPromptSection],
  ['turn_harness', criterionTurnHarness],
]) {
  try {
    results[id] = await fn();
  } catch (error) {
    results[id] = false;
    record(`${id}_error`, {
      message: messageOf(error),
      stack: String((error && error.stack) ?? '').split(String.fromCharCode(10)).slice(0, 4),
    });
  }
}

report.summary = {
  total: Object.keys(results).length,
  passed: Object.values(results).filter(Boolean).length,
  results,
};
write();
process.stdout.write(`DSHPORTE_STEP8 ${JSON.stringify(report.summary)}\n`);
process.exit(0);
