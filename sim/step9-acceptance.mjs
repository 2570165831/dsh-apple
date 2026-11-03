// Step 9's functional acceptance: one canonical path spelling, end to end.
//
// THE PHONE'S REPORT. The workspace dropdown listed the same folder twice
// (`deepseek-harness`, `deepseek-harness`) plus `默认工作区`, and selecting an
// existing row failed — only "添加工作区… → pick a folder" worked. Its
// `storages/workspace.json` held five records for two folders, in both
// `/var/...` and `/private/var/...`, and new sessions' project directories were
// `--private-var-...` while the older ones were `--var-...`.
//
// THE CAUSE, established by reading the code rather than guessing: step 7 made the
// Swift host publish `realpath(3)` (`/private/var/...`), which is what DSH's own
// `fs.realpath` answers and therefore what `dsh-workspace` stores — but
// `dedupeWorkspaceRegistry()` (Node) and `repairWorkspaceRegistry()` (Swift) still
// folded `/private/var` BACK to `/var`. So every launch rewrote the registry into
// the one spelling the runtime would immediately disagree with:
//
//   * two records for one folder -> two dropdown rows;
//   * selecting the `/var/...` row -> `sessionController.create({workspaceId})`
//     uses the record's path as the cwd, then `workspace.attachSession(sessionId)`
//     realpaths that cwd, gets `/private/var/...`, compares it to the stored
//     `/var/...` path, and throws "could not attach to workspace …" — surfaced to
//     the UI as `session/workspace-attach-failed`. That is the exact "selecting an
//     existing workspace errors" the phone reported.
//
// ORDER OF OPERATIONS, AND WHY IT IS THIS ORDER. The fixture is planted BEFORE
// `runProfile()`, and the shipped migration is run before the mount too, because
// that is what the app does: Swift repairs what it can, Node migrates, and only
// then does DSH read the registry. Planting after the mount would measure a
// registry nothing had loaded, and the first draft of this module did exactly that
// — every `create({workspaceId})` came back `workspace/not-found`, which was the
// fixture's fault and not the product's.
//
// WHAT IS MEASURED
//   1. `fold_rules`       the `/var` <-> `/private/var` rule, on the shipped
//                         function. Fails by construction under
//                         `DSHPORTE_PATH_FOLD=friendly`.
//   2. `migration`        the shipped launch-time sequence run on the phone's five
//                         records AND session logs seeded under both spellings.
//   3. `selection`        the operation that failed: for EVERY live workspace,
//                         `create({workspaceId})` then a real prompt with a bash
//                         tool call.
//   4. `project_dirs`     one project directory per session cwd, named with the
//                         canonical spelling, after those sessions exist.
//   5. `default_workspace` the first-use record is at the path the controller
//                         would register, in the canonical spelling.
//
// GATED like steps 7 and 8: `sim/ios-app-entry.mjs` imports this INSTEAD of DSH
// when `DSHPORTE_STEP9_ACCEPTANCE=1`.

import { mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import zlib from 'node:zlib';

const RESULT_NAME = 'DSHPortE-step9-acceptance.json';

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
    process.stderr.write(`step9-acceptance: could not write the report: ${error}\n`);
  }
}

const messageOf = (error) => String(error && error.message ? error.message : error);

const simDir = dirname(new URL(import.meta.url).pathname);
const sessionMigrate = await import(join(simDir, 'session-migrate.mjs'));
const canonical = (path) => sessionMigrate.canonicalPath(path);

const hostWorkspace = process.env.DSH_IOS_WORKSPACE ?? process.cwd();
const dshHome = process.env.DSH_HOME ?? '';
const sessionsRoot = join(dshHome, 'sessions');
const storagesRoot = join(dshHome, 'storages');

// ---------------------------------------------------------------- the fixture
//
// THE PHONE'S STATE, RECONSTRUCTED IN THE APP'S OWN DSH_HOME.
//
// A `/private/var/...` *container* path does not exist on this simulator (the
// container is under `~/Library/Caches/...`), so the aliasing is built: a
// symlink in the app's temp directory points at the workspace, and the two
// spellings are then real, distinct strings that resolve to one directory —
// structurally identical to `/var/mobile/...` (the alias) vs
// `/private/var/mobile/...` (the realpath) on the phone.
//
// Two folders, five records, exactly as the phone reported:
//
//   folder                      spellings                    records
//   Documents/workspace         real + alias                 ws-workspace-real / ws-workspace-friendly
//   .../workspace/deepseek-harness  real + alias              ws-harness-real    / ws-harness-friendly
//   .../deepseek-harness/default-workspace  real (first use)  ws-default
const scratchRoot = hostWorkspace;
const folderHarness = join(hostWorkspace, 'deepseek-harness');
const folderDefault = join(folderHarness, 'default-workspace');
const aliasLink = join(process.env.TMPDIR ?? '/tmp', 'step9-workspace-alias');

const LEGACY_A = 'session-step9-legacy-a';
const LEGACY_B = 'session-step9-legacy-b';

/** One DSH-shaped session log: a zstd header frame plus one event frame. */
function sessionLogBytes(id, cwd) {
  const header = {
    type: 'session', version: 4, id, createdAt: Date.now() - 86_400_000,
    cwd, isSeeded: false, delegationDepth: 0, agentPreset: 'ios-safe',
  };
  const events = [
    { type: 'turn/start', seq: 0, time: header.createdAt + 1, data: { turn: 1 } },
    {
      type: 'user/message', seq: 1, time: header.createdAt + 2,
      data: { source: { kind: 'user', rpcId: `rpc-${id}` }, content: [{ type: 'text', text: 'seeded before the migration' }] },
    },
    {
      type: 'assistant/message', seq: 2, time: header.createdAt + 3,
      data: { message: { role: 'assistant', content: [{ type: 'text', text: 'acknowledged' }] } },
    },
    { type: 'turn/end', seq: 3, time: header.createdAt + 4, data: { turn: 1 } },
  ];
  const frame = (text) => zlib.zstdCompressSync(Buffer.from(text, 'utf8'), {
    params: { [zlib.constants.ZSTD_c_checksumFlag]: 1 },
  });
  return Buffer.concat([
    frame(JSON.stringify(header) + '\n'),
    frame(events.map((event) => JSON.stringify(event)).join('\n') + '\n'),
  ]);
}

/** Plant a session log under the project key of `cwd` — including a WRONG spelling. */
function seedSession(id, cwd) {
  const dir = join(sessionsRoot, sessionMigrate.projectKey(cwd), id);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, 'session.v4.jsonl.zstd'), sessionLogBytes(id, cwd));
  return { id, cwd, key: sessionMigrate.projectKey(cwd), dir };
}

function buildFixture() {
  // Idempotent: the app may be relaunched against a container it already used.
  rmSync(folderDefault, { recursive: true, force: true });
  mkdirSync(folderDefault, { recursive: true });
  try { rmSync(aliasLink, { force: true }); } catch { /* absent */ }
  const { symlinkSync } = process.getBuiltinModule('node:fs');
  try { symlinkSync(hostWorkspace, aliasLink); } catch (error) {
    return { ok: false, error: `cannot create the alias: ${messageOf(error)}` };
  }
  const aliasWorkspace = aliasLink;
  const aliasHarness = join(aliasLink, 'deepseek-harness');
  const facts = {
    ok: true,
    aliasLink,
    realWorkspace: hostWorkspace,
    aliasWorkspace,
    realHarness: folderHarness,
    aliasHarness,
    realDefault: folderDefault,
    // The property the fixture has to have for the test to mean anything.
    aliasResolvesToReal: canonical(aliasWorkspace) === canonical(hostWorkspace),
    aliasDiffersFromReal: aliasWorkspace !== hostWorkspace,
  };

  // The split the phone showed: sessions under BOTH project keys for one folder.
  facts.seeded = [seedSession(LEGACY_A, aliasHarness), seedSession(LEGACY_B, folderHarness)];
  facts.seeded_keys_differ = new Set(facts.seeded.map((entry) => entry.key)).size === 2;

  // The phone's five records, in the phone's two spellings.
  const now = new Date().toISOString();
  const earlier = new Date(Date.now() - 86_400_000).toISOString();
  const older = new Date(Date.now() - 172_800_000).toISOString();
  const registry = {
    unit: { name: 'workspace', version: 2 },
    global: {
      initialized: true,
      workspaceIds: ['ws-harness-friendly', 'ws-harness-real', 'ws-workspace-friendly', 'ws-workspace-real', 'ws-default'],
      archivedSessionIds: [],
      pinnedSessionIds: [],
      defaultWorkspaceId: 'ws-default',
    },
    tables: {
      workspaces: {
        // Oldest record for the harness folder is the FRIENDLY spelling, so the
        // merge has to keep a record whose path must then be rewritten — not the
        // easy case where the survivor is already canonical.
        'ws-harness-friendly': { path: aliasHarness, title: 'deepseek-harness', sessionIds: [LEGACY_A], createdAt: older, updatedAt: older },
        'ws-harness-real': { path: folderHarness, title: 'deepseek-harness', sessionIds: [LEGACY_B], createdAt: earlier, updatedAt: earlier },
        'ws-workspace-friendly': { path: aliasWorkspace, title: 'workspace', sessionIds: [], createdAt: earlier, updatedAt: earlier },
        'ws-workspace-real': { path: hostWorkspace, title: 'workspace', sessionIds: [], createdAt: now, updatedAt: now },
        'ws-default': { path: folderDefault, title: 'default-workspace', sessionIds: [], createdAt: now, updatedAt: now },
      },
    },
  };
  mkdirSync(storagesRoot, { recursive: true });
  writeFileSync(join(storagesRoot, 'workspace.json'), JSON.stringify(registry, null, 2));
  facts.records_planted = registry.global.workspaceIds.length;
  return facts;
}

function readRegistry() {
  try { return JSON.parse(readFileSync(join(storagesRoot, 'workspace.json'), 'utf8')); } catch { return undefined; }
}

const fixture = buildFixture();
record('fixture', fixture);

// ----------------------- 1. the fold rule, on the shipped function, before DSH
//
// `/var` <-> `/private/var` cannot be exercised through a real directory on the
// simulator, so it is checked as the string rule it is — calling the SAME exported
// function the migration uses, not a restatement of it. Under
// `DSHPORTE_PATH_FOLD=friendly` the expected answers invert, which is what makes
// this a test of the fix rather than a test of the weather.
function criterionFoldRules() {
  const facts = { fold_mode: process.env.DSHPORTE_PATH_FOLD ?? 'canonical' };
  const friendly = facts.fold_mode === 'friendly';
  const cases = [
    ['/var', '/private/var', '/private/var'],
    ['/var/mobile/Containers/Data/Application/U', '/private/var/mobile/Containers/Data/Application/U', '/var/mobile/Containers/Data/Application/U'],
    ['/private/var/mobile/Containers/Data/Application/U', '/private/var/mobile/Containers/Data/Application/U', '/var/mobile/Containers/Data/Application/U'],
    ['/var/folders/x', '/private/var/folders/x', '/var/folders/x'],
  ];
  facts.cases = cases.map(([input, wantCanonical, wantFriendly]) => {
    const want = friendly ? wantFriendly : wantCanonical;
    return { input, want, got: canonical(input), ok: canonical(input) === want };
  });
  facts.all_cases_hold = facts.cases.every((entry) => entry.ok);
  // And the switch really is a switch: the OTHER mode's answer must not also hold,
  // or the two runs would be indistinguishable and neither would be evidence.
  const other = cases.map(([input, wantCanonical, wantFriendly]) => (friendly ? wantCanonical : wantFriendly));
  facts.other_mode_disagrees = cases.some(([input], index) => canonical(input) !== other[index]);
  facts.pass = facts.all_cases_hold === true && facts.other_mode_disagrees === true;
  record('fold_rules', facts);
  return facts.pass;
}

// ------------------- 2. the shipped launch-time sequence, on the phone's state
//
// Calls `runFromEnvironment()` — the exact function `sim/ios-app-entry.mjs` calls
// on every launch — with `DSHPORTE_SESSION_MIGRATE` pointed at the container. Not a
// reimplementation of the sequence: the sequence itself, in its own order
// (storage rewrite, session migration, quarantine sweep, prune, dedupe).
function criterionMigration() {
  const facts = {};
  const before = readRegistry();
  facts.records_before = Object.values(before?.tables?.workspaces ?? {}).map((record) => record.path);
  facts.distinct_paths_before = new Set(facts.records_before).size;
  // THE CONTAINER ROOT, NOT THE WORKSPACE. `DSHPORTE_SESSION_MIGRATE` carries
  // `workspace.deletingLastPathComponent().deletingLastPathComponent()`
  // (`NodeRunner.makeEnvironment`), because `respellAll` substitutes it for
  // everything up to `/Containers/Data/Application/<uuid>`. Passing the workspace
  // here — which the first draft of this module did — makes the rewrite prepend the
  // workspace path to every container path, so `.../Documents/workspace/Documents/
  // workspace/...` appears and every criterion downstream fails on the harness's own
  // mistake. Measured: exactly that happened on the first full run.
  const containerRoot = process.env.DSHPORTE_SESSION_MIGRATE ?? join(hostWorkspace, '..', '..');
  facts.container_root_used = containerRoot;
  facts.container_root_is_an_ancestor = hostWorkspace.startsWith(canonical(containerRoot) + '/');
  const savedMigrate = process.env.DSHPORTE_SESSION_MIGRATE;
  process.env.DSHPORTE_SESSION_MIGRATE = containerRoot;
  try {
    sessionMigrate.runFromEnvironment();
  } finally {
    if (savedMigrate === undefined) delete process.env.DSHPORTE_SESSION_MIGRATE;
    else process.env.DSHPORTE_SESSION_MIGRATE = savedMigrate;
  }
  let summary = {};
  try { summary = JSON.parse(readFileSync(join(dshHome, 'DSHPortE-session-migrate.json'), 'utf8')); } catch { /* absent */ }
  facts.summary = summary;

  const after = readRegistry();
  const records = Object.entries(after?.tables?.workspaces ?? {});
  const paths = records.map(([, rec]) => rec.path);
  facts.records_after = paths;
  facts.record_count_after = records.length;
  facts.distinct_paths_after = new Set(paths).size;
  facts.titles_after = records.map(([, rec]) => rec.title);
  facts.no_duplicate_rows = facts.distinct_paths_after === facts.record_count_after;
  facts.no_duplicate_titles = new Set(facts.titles_after).size === facts.titles_after.length;
  facts.all_canonical = paths.every((path) => canonical(path) === path);
  facts.alias_spellings_gone = !paths.includes(fixture.aliasHarness) && !paths.includes(fixture.aliasWorkspace);
  // Five records for two folders collapse to one per folder plus the default.
  facts.collapsed = facts.record_count_after === 3;

  // Both legacy sessions must still be accounted for, in the surviving record.
  const harness = records.find(([, rec]) => canonical(rec.path) === canonical(folderHarness));
  facts.harness_record = harness === undefined ? null : { id: harness[0], path: harness[1].path, sessionIds: harness[1].sessionIds };
  facts.both_legacy_sessions_kept = harness !== undefined
    && [LEGACY_A, LEGACY_B].every((id) => harness[1].sessionIds.includes(id));
  // ...and their logs must now sit under ONE project directory.
  const sessionDirs = (() => {
    try { return readdirSync(sessionsRoot).filter((name) => name.startsWith('--')); } catch { return []; }
  })();
  facts.session_project_dirs_after = sessionDirs;
  facts.legacy_sessions_moved_to_one_dir = sessionDirs.filter((dir) => {
    try { return readdirSync(join(sessionsRoot, dir)).some((name) => name === LEGACY_A || name === LEGACY_B); } catch { return false; }
  }).length === 1;
  const keysAfter = new Set(Object.values(after?.tables?.workspaces ?? {}).map((rec) => sessionMigrate.projectKey(rec.path)));
  facts.project_dir_matches_record_keys = sessionDirs.every((dir) => keysAfter.has(dir));

  facts.workspace_ids = after?.global?.workspaceIds ?? [];
  facts.workspace_ids_unique = new Set(facts.workspace_ids).size === facts.workspace_ids.length;
  facts.workspace_ids_all_live = facts.workspace_ids.every((id) => after?.tables?.workspaces?.[id] !== undefined);
  facts.default_workspace_id = after?.global?.defaultWorkspaceId ?? null;
  facts.default_is_live = after?.tables?.workspaces?.[facts.default_workspace_id] !== undefined;

  facts.pass = facts.no_duplicate_rows === true
    && facts.no_duplicate_titles === true
    && facts.all_canonical === true
    && facts.alias_spellings_gone === true
    && facts.collapsed === true
    && facts.both_legacy_sessions_kept === true
    && facts.legacy_sessions_moved_to_one_dir === true
    && facts.project_dir_matches_record_keys === true
    && facts.workspace_ids_unique === true
    && facts.workspace_ids_all_live === true
    && facts.default_is_live === true;
  record('migration', facts);
  return facts.pass;
}

const migrationPassed = (() => {
  try { return criterionMigration(); } catch (error) {
    record('migration_error', { message: messageOf(error), stack: String(error?.stack ?? '').split('\n').slice(0, 4) });
    return false;
  }
})();

// --------------------------------------------------------------- then mount
const payload = process.env.IOS_SIM_DSH_INSTALL ?? join(process.env.IOS_SIM_BUNDLE ?? '.', 'payload');
const payloadPath = (name) => join(payload, 'node_modules', '@deepseek-ai', name, 'lib', 'index.js');

{
  const { register } = await import('node:module');
  const { pathToFileURL } = await import('node:url');
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
  report.summary = { total: 3, passed: Number(migrationPassed), results: { migration: migrationPassed, boot: false } };
  write();
  process.stdout.write(`DSHPORTE_STEP9 ${JSON.stringify(report.summary)}\n`);
  process.exit(1);
}
record('boot', { ok: true });

// ------------------------ 3. can every row the registry offers be selected?
//
// THIS IS THE CRITERION THAT WOULD HAVE CAUGHT THE BUG. The phone's failure was not
// a cosmetic duplicate: pressing the row threw. The failing call is
// `sessionController.create({ workspaceId })` -> `SessionCommandController.create`
// -> `agents.createSession({ cwd: workspace.path })` -> `workspace.attachSession`,
// which realpaths the new session's cwd and compares it to the record's stored
// path. So the acceptance drives that same call for every workspace DSH itself
// lists, then sends a prompt that makes the mock run a real bash tool call — "the
// row is selectable" has to mean the session it opened is usable, not merely
// created.
async function criterionSelection() {
  const facts = { attempts: [] };
  const registry = ctx.get('workspaceRegistry');
  facts.registry_mounted = registry !== undefined;
  const controller = ctx.get('sessionController');
  facts.controller_mounted = controller !== undefined;
  const query = ctx.get('sessionQuery');
  facts.session_query_mounted = query !== undefined;
  if (registry === undefined || controller === undefined) { facts.pass = false; record('selection', facts); return false; }

  const listed = registry.list().map((workspace) => ({ id: workspace.id, path: workspace.path, title: workspace.title }));
  facts.workspaces_listed = listed;
  facts.listed_count = listed.length;
  facts.listed_paths_canonical = listed.every((workspace) => canonical(workspace.path) === workspace.path);
  facts.listed_paths_distinct = new Set(listed.map((workspace) => canonical(workspace.path))).size === listed.length;
  facts.listed_titles_distinct = new Set(listed.map((workspace) => workspace.title)).size === listed.length;

  for (const workspace of listed) {
    const attempt = { workspaceId: workspace.id, path: workspace.path, title: workspace.title };
    try {
      const created = await controller.create({ workspaceId: workspace.id });
      attempt.create = created;
      const sessionId = created?.sessionId;
      attempt.sessionId = sessionId;
      const abort = new AbortController();
      const promptText = `BASHTEST selection from ${workspace.id}\nSTEP echo step9-selection\n`;
      try {
        await controller.prompt({
          sessionId,
          requestId: `step9-${workspace.id}-${Date.now()}`,
          mode: 'followup',
          content: [{ type: 'text', text: promptText }],
        }, abort.signal);
        attempt.prompt = { accepted: true };
      } catch (promptError) {
        attempt.prompt = { accepted: false, code: promptError?.code, message: messageOf(promptError) };
      }
      // Wait for the turn to end, and record the tool call the mock drove — a
      // session that answers without its tool path working would otherwise pass.
      const deadline = Date.now() + 150_000;
      let turns = 0;
      let sawBash = false;
      let sessionCwd = null;
      while (Date.now() < deadline) {
        try {
          const loaded = await query.readSession(sessionId);
          const events = loaded.events;
          turns = events.filter((event) => event?.type === 'turn/end').length;
          sawBash = events.some((event) => JSON.stringify(event).includes('step9-selection'));
          sessionCwd = loaded.session.cwd;
          if (turns >= 1 && sawBash) break;
        } catch { /* mid-write reads can fail; retry until the deadline */ }
        await new Promise((resolve) => setTimeout(resolve, 1_500));
      }
      attempt.turnEnds = turns;
      attempt.saw_bash_tool_call = sawBash;
      attempt.session_cwd = sessionCwd;
      attempt.cwd_matches_workspace = sessionCwd === null ? null : canonical(sessionCwd) === canonical(workspace.path);
      attempt.cwd_is_canonical = sessionCwd === null ? null : canonical(sessionCwd) === sessionCwd;
      attempt.ok = attempt.prompt?.accepted === true
        && turns >= 1
        && sawBash === true
        && attempt.cwd_matches_workspace === true
        && attempt.cwd_is_canonical === true;
    } catch (error) {
      attempt.ok = false;
      attempt.error = { code: error?.code, message: messageOf(error), reason: error?.details?.reason ?? null };
    }
    facts.attempts.push(attempt);
  }
  facts.every_row_selectable = facts.attempts.length > 0 && facts.attempts.every((attempt) => attempt.ok === true);
  facts.failures = facts.attempts.filter((attempt) => attempt.ok !== true);
  facts.pass = facts.listed_count >= 3
    && facts.listed_paths_canonical === true
    && facts.listed_paths_distinct === true
    && facts.listed_titles_distinct === true
    && facts.every_row_selectable === true;
  record('selection', facts);
  return facts.pass;
}

// ------------------------ 4. one project directory per folder, after sessions
function criterionProjectDirs() {
  const facts = {};
  let dirs = [];
  try { dirs = readdirSync(sessionsRoot).filter((name) => name.startsWith('--')); } catch { /* none */ }
  facts.project_dirs = dirs;
  const cwds = [];
  for (const dir of dirs) {
    let children = [];
    try { children = readdirSync(join(sessionsRoot, dir)); } catch { continue; }
    for (const session of children) {
      let names = [];
      try { names = readdirSync(join(sessionsRoot, dir, session)); } catch { continue; }
      const file = names.find((name) => /^session(\.v\d+)?\.jsonl(\.zstd)?$/.test(name));
      if (file === undefined) continue;
      const cwd = headerCwdOf(join(sessionsRoot, dir, session, file));
      if (typeof cwd === 'string') cwds.push(cwd);
    }
  }
  facts.session_cwds_sample = [...new Set(cwds)].slice(0, 12);
  facts.session_count = cwds.length;
  facts.all_cwds_canonical = cwds.every((cwd) => canonical(cwd) === cwd);
  facts.dirs_with_private_var = dirs.filter((dir) => dir.includes('private-var')).length;
  facts.dirs_with_bare_var = dirs.filter((dir) => /(^|-)var-/.test(dir) && !dir.includes('private-var')).length;
  // Every project directory must be the key of a cwd that actually exists inside
  // it — no directory left over from a spelling nothing uses.
  const wanted = new Set(cwds.map((cwd) => sessionMigrate.projectKey(canonical(cwd))));
  facts.expected_keys = [...wanted];
  facts.no_stale_key_dirs = dirs.every((dir) => wanted.has(dir));
  facts.dirs_cover_all_cwds = [...wanted].every((key) => dirs.includes(key));
  facts.pass = facts.session_count >= 3
    && facts.all_cwds_canonical === true
    && facts.no_stale_key_dirs === true
    && facts.dirs_cover_all_cwds === true;
  record('project_dirs', facts);
  return facts.pass;
}

/** Read a session log's header cwd without DSH's own reader (a test-side check). */
function headerCwdOf(path) {
  try {
    const raw = readFileSync(path);
    if (!path.endsWith('.zstd')) return JSON.parse(raw.toString('utf8').split('\n')[0]).cwd;
    const frames = sessionMigrate.scanFrames(raw, 1).frames;
    if (frames.length === 0) return undefined;
    return JSON.parse(zlib.zstdDecompressSync(raw.subarray(frames[0].start, frames[0].end)).toString('utf8')).cwd;
  } catch { return undefined; }
}

// --------------------------- 5. the default workspace is registered properly
//
// First-use registration goes `workspace-controller.initializeDefault` ->
// `defaultWorkspaceDirectory(documentsDirectory)` -> `join(dir, 'deepseek-harness',
// 'default-workspace')` -> `realpathNormalize`. The JOINED path is what the record
// gets, so a `documentsDirectory` in the wrong spelling produces the wrong spelling
// here and nowhere else.
function criterionDefaultWorkspace() {
  const facts = { documents_directory_published: hostWorkspace };
  const registry = readRegistry();
  const defaultId = registry?.global?.defaultWorkspaceId;
  const defaultRecord = registry?.tables?.workspaces?.[defaultId];
  facts.default_workspace_id = defaultId ?? null;
  facts.default_record = defaultRecord ?? null;
  facts.default_path_is_canonical = defaultRecord === undefined ? false : canonical(defaultRecord.path) === defaultRecord.path;
  const { join: joinPath } = process.getBuiltinModule('node:path');
  const wouldRegister = joinPath(hostWorkspace, 'deepseek-harness', 'default-workspace');
  facts.would_register = wouldRegister;
  facts.would_register_canonical = canonical(wouldRegister) === wouldRegister;
  facts.published_matches_realpath = canonical(hostWorkspace) === hostWorkspace;
  facts.default_matches_first_use_path = defaultRecord === undefined
    ? null
    : canonical(defaultRecord.path) === canonical(wouldRegister);
  // And DSH's own live view must agree: the default record it exposes is the same
  // folder, in the same spelling.
  const live = ctx.get('workspaceRegistry');
  const liveDefault = live === undefined ? undefined : live.list().find((workspace) => workspace.id === defaultId);
  facts.live_default_path = liveDefault?.path ?? null;
  facts.live_default_matches = liveDefault === undefined
    ? null
    : canonical(liveDefault.path) === canonical(wouldRegister);
  facts.pass = facts.default_path_is_canonical === true
    && facts.would_register_canonical === true
    && facts.published_matches_realpath === true
    && facts.default_matches_first_use_path === true
    && facts.live_default_matches === true;
  record('default_workspace', facts);
  return facts.pass;
}

// ------------------------------------------------------------ run everything
const results = { fold_rules: false, migration: migrationPassed };
for (const [id, fn] of [
  ['selection', criterionSelection],
  ['project_dirs', criterionProjectDirs],
  ['default_workspace', criterionDefaultWorkspace],
]) {
  try {
    results[id] = await fn();
  } catch (error) {
    results[id] = false;
    record(`${id}_error`, { message: messageOf(error), stack: String(error?.stack ?? '').split('\n').slice(0, 4) });
  }
}
// `fold_rules` is re-run last so its verdict cannot depend on anything DSH did.
try {
  results.fold_rules = criterionFoldRules();
} catch (error) {
  results.fold_rules = false;
  record('fold_rules_error', { message: messageOf(error) });
}

report.summary = {
  total: Object.keys(results).length,
  passed: Object.values(results).filter(Boolean).length,
  results,
};
write();
process.stdout.write(`DSHPORTE_STEP9 ${JSON.stringify(report.summary)}\n`);
process.exit(0);
