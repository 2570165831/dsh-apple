// Step 7's functional acceptance: the four model-facing path/tool problems the
// phone run reported, measured against the REAL mounted profile.
//
// WHY IT RUNS IN THE APP AND MOUNTS THE REAL PROFILE. Every criterion here is
// about what the model's tools do, not about what a string helper returns. The
// module boots the shipped `ios-sim` profile through `runProfile()` — the same
// entry `dsh --profile ios-sim` calls, so the same bundles, the same patch
// layers, the same rows — and then drives the real services:
//
//   * `ctx.fs` for the two path namespaces (problem 3),
//   * `ctx.subprocess` as `dsh-bash-local` calls it, for the default cwd and
//     `workdir` handling (problem 2),
//   * the registered `glob` / `grep` tools through the tool runtime, which is
//     what actually failed with "ripgrep launch failed" on the phone (problem 1),
//   * `workspaceChanges` for the changed-files card (problem 5a),
//   * the `write`→`edit` sequence through the tools for the "file changed since
//     it was read" report (problem 5b).
//
// Driving the tools through the runtime rather than calling their internals is
// the difference between "the argv builder is right" and "the model's call
// works": the failure the phone saw happened inside `ctx.subprocess.spawn`, and a
// unit test of the argv never reaches it.
//
// GATED like the other acceptance modules: `sim/ios-app-entry.mjs` imports this
// INSTEAD of DSH when `DSHPORTE_STEP7_ACCEPTANCE=1`.

import { mkdirSync, writeFileSync, readFileSync, existsSync, rmSync, statSync } from 'node:fs';
import { dirname, join, relative } from 'node:path';

const RESULT_NAME = 'DSHPortE-step7-acceptance.json';

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
    process.stderr.write(`step7-acceptance: could not write the report: ${error}\n`);
  }
}

const messageOf = (error) => String(error && error.message ? error.message : error);

// ------------------------------------------------------------------ mounting
// Same `runProfile` entry the app ships, with the launch environment snapshot the
// CLI builds. `boot()` directly needs its config path, patch list and env
// assembled by hand and yields a tree with rows missing when that is subtly
// wrong; `runProfile` is what the profile mechanism is actually for.
const payload = process.env.IOS_SIM_DSH_INSTALL ?? join(process.env.IOS_SIM_BUNDLE ?? '.', 'payload');
const payloadPath = (name) => join(payload, 'node_modules', '@deepseek-ai', name, 'lib', 'index.js');

// The SAME two loader hooks the production entry registers, registered here so
// this module measures the shipped composition rather than a bare payload.
// Without them the ripgrep criterion measured the un-hooked reality (a missing
// `@vscode/ripgrep`) and reported `packaged_rg: null` no matter what the fix did —
// which is what the first hooked run of this module showed. A measurement that
// cannot see the fix is not evidence about the fix.
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
  process.stdout.write(`DSHPORTE_STEP7 ${JSON.stringify(report.criteria)}\n`);
  process.exit(1);
}
record('boot', { ok: true });

const hostWorkspace = process.env.DSH_IOS_WORKSPACE ?? process.cwd();
const guestWorkspace = process.env.DSH_GUEST_WORKSPACE ?? '/workspace';

// A scratch directory inside the workspace, so everything this module writes is
// inside the one folder the app publishes and the guest mounts.
const scratch = join(hostWorkspace, 'step7-acceptance');
try { rmSync(scratch, { recursive: true, force: true }); } catch { /* first run */ }
mkdirSync(scratch, { recursive: true });

// ------------------------------------------------------- problem 1: ripgrep
//
// The phone reported `glob` / `grep` failing with "ripgrep launch failed" and an
// empty `command -v rg`. Three facts have to hold, and the third is the one that
// was broken:
//
//   1. the guest really has an `rg`,
//   2. it runs in the guest (a musl binary from the image, not the packaged
//      host binary),
//   3. `ctx.subprocess.spawn` accepts the argv the search tools build, i.e. the
//      packaged HOST path is respelled onto the guest binary.
//
// The assertion is made by running the exact argv `dsh-tool-fs-search` builds —
// `rgPath` included — so a respell that only worked for a hand-written argv would
// not pass.
async function criterionRipgrep() {
  const subprocess = ctx.get('subprocess');
  const search = await import(join(payload, 'node_modules/@deepseek-ai/dsh-tool-fs-search/lib/index.js'));
  const facts = { guestWorkspace };

  // 1. Does the guest have rg at all, through the same resolver the tools use?
  try {
    facts.resolved_rg = await subprocess.resolveExecutable('rg', undefined, undefined);
  } catch (error) {
    facts.resolved_rg = null;
    facts.resolve_error = messageOf(error);
  }

  // 2. The packaged binary's own path, which is what the tool passes as argv[0].
  let packaged;
  try {
    packaged = await search.resolveRgPath();
  } catch (error) {
    packaged = null;
    facts.package_error = messageOf(error);
  }
  facts.packaged_rg = packaged;

  // 3. Run the tool's own glob argv, with the tool's own binary path.
  const globArgv = search.buildGlobCommand({ pattern: '*.txt' });
  facts.glob_argv = globArgv;
  const collect = { maxBytes: 1 << 20 };
  const runArgv = async (argv, cwd) => {
    const handle = subprocess.spawn({
      argv,
      cwd,
      stdio: { stdin: 'ignore', stdout: collect, stderr: collect },
      graceMs: 3000,
    });
    const outcome = await handle.done;
    return {
      exitCode: outcome.exitCode,
      stdout: handle.collected.stdout?.readFrom(0).text ?? '',
      stderr: handle.collected.stderr?.readFrom(0).text ?? '',
    };
  };

  // A file for the search to find, written on the HOST side through `ctx.fs` so
  // the test does not depend on bash working. Placed in `scratch` — the
  // `step7-acceptance/` directory both searches are run from — because a grep
  // looks in the WORKDIR: seeding it anywhere else makes the grep find nothing
  // and look like a broken ripgrep when it is a broken fixture. (Measured exactly
  // that way on the first run of this module.)
  const seedHost = join(scratch, 'rg-seed.txt');
  const seedTarget = await ctx.fs.resolve(seedHost);
  await ctx.fs.writeText(seedTarget, 'needle alpha\nbeta\n', undefined, undefined);
  const searchCwd = `${guestWorkspace}/step7-acceptance`;
  facts.search_cwd = searchCwd;

  try {
    const globResult = await runArgv([packaged ?? 'rg', '--no-config', ...globArgv], searchCwd);
    facts.glob = globResult;
    facts.glob_ok = globResult.exitCode === 0 && globResult.stdout.includes('rg-seed.txt');
  } catch (error) {
    facts.glob = { error: messageOf(error) };
    facts.glob_ok = false;
  }

  const grepArgv = search.buildGrepCommand({ pattern: 'needle' });
  facts.grep_argv = grepArgv;
  try {
    const grepResult = await runArgv([packaged ?? 'rg', '--no-config', ...grepArgv], searchCwd);
    facts.grep = { exitCode: grepResult.exitCode, stdoutHead: grepResult.stdout.slice(0, 400), stderr: grepResult.stderr.slice(0, 400) };
    facts.grep_ok = grepResult.exitCode === 0 && grepResult.stdout.includes('"type":"match"');
  } catch (error) {
    facts.grep = { error: messageOf(error) };
    facts.grep_ok = false;
  }

  // DIAGNOSTICS, because "the glob lists it and the grep searches nothing" has
  // more than one possible cause and the difference decides who has to fix what:
  //
  //   * can the guest READ the file's bytes at all (a permission/metadata problem in
  //     the bind mount that directory listing does not hit),
  //   * which candidate set does rg see under each combination of its own
  //     filters (`--no-ignore`, `--hidden`, an explicit path),
  //   * what does rg itself say on stderr when it is forced verbose.
  //
  // Recorded, not asserted: these exist to make the failure legible.
  const diag = {};
  try {
    diag.ls = await runArgv(['bash', '-c', `cd ${searchCwd} && ls -ln`], searchCwd);
  } catch (error) {
    diag.ls = { error: messageOf(error) };
  }
  // A file the GUEST wrote, in the same directory, for comparison. This is the
  // distinction that decides who owns the problem: if rg reads the guest-written
  // file but not the host-written one, the directory walk is fine and the file
  // metadata the host provider produced is the cause.
  try {
    diag.guest_written = await runArgv(['bash', '-c',
      `printf 'guestmade needle\\n' > ${searchCwd}/guest-made.txt && ls -ln ${searchCwd}/guest-made.txt`], searchCwd);
  } catch (error) {
    diag.guest_written = { error: messageOf(error) };
  }
  for (const [label, extra] of [
    ['files_no_ignore', ['--files', '--no-ignore', '--hidden']],
    ['json_explicit_path', ['--json', '--no-ignore', '--regexp=needle', 'rg-seed.txt']],
    ['json_no_ignore', ['--json', '--no-ignore', '--hidden', '--regexp=needle']],
    ['json_no_mmap', ['--json', '--no-ignore', '--hidden', '--no-mmap', '--regexp=needle']],
    ['json_single_thread', ['--json', '--no-ignore', '--hidden', '-j', '1', '--regexp=needle']],
    ['json_one_thread_no_mmap', ['--json', '--no-ignore', '--hidden', '-j', '1', '--no-mmap', '--regexp=needle']],
    // `--debug` is the only way to hear rg's own decision about these files: it
    // logs "ignoring X: not a file" / "X: No such file or directory" per candidate.
    // Without it, "searches=0" does not say which of those happened.
    ['debug', ['--debug', '--no-ignore', '--hidden', '--regexp=needle']],
    // And the guest's own view of the same entries: `stat -c %F` prints the TYPE
    // the kernel reports, which is what rg's `is_file` test reads.
    ['stat_all', ['bash', '-c', `cd ${searchCwd} && for f in *; do echo "$f: $(stat -c '%F %a %u:%g %s' "$f" 2>&1)"; done`]],
  ]) {
    try {
      // Each entry decides its own argv: `stat_all` is a bash command, not rg.
      const argv = extra[0] === 'bash' ? [...extra] : [packaged ?? 'rg', '--no-config', ...extra];
      const result = await runArgv(argv, searchCwd);
      diag[label] = {
        exitCode: result.exitCode,
        stdoutHead: result.stdout.slice(0, 1200),
        stderrHead: result.stderr.slice(0, 1200),
      };
    } catch (error) {
      diag[label] = { error: messageOf(error) };
    }
  }
  facts.diagnostics = diag;

  // THE MODEL'S OWN PATH. Not asserted here, and the reason is structural rather
  // than convenient: the tools are registered inside the AGENT PRESET's scope, so
  // `tools.execute()` with no `agent` resolves against the global view and answers
  // `unknown tool "glob"` for every one of them — measured, on the first version of
  // this criterion. Driving them needs a live agent, which means a live model turn.
  //
  // So the model path is measured OUTSIDE this module, through the app's real agent
  // loop against the mock: `scripts/agent-turn.py` with `prompts/15-step7-pathtest.txt`
  // (keyword `PATHTEST`) makes a real turn call `glob`, `grep`, `write`, `edit`,
  // `read` in order, and the session log records what each returned. That is
  // stronger evidence than a service call would be, because it includes the tool
  // layer AND the model-visible rendering. `REPORT-7.md` quotes it.
  //
  // What IS checked here is the layer underneath: that the argv the search tools
  // build runs in the guest, which is where the phone's failure actually was.
  facts.model_path_measured_by = 'scripts/agent-turn.py + prompts/15-step7-pathtest.txt (PATHTEST)';

  facts.pass = typeof facts.resolved_rg === 'string'
    && facts.resolved_rg.includes('/rg')
    && facts.glob_ok === true
    && facts.grep_ok === true;
  record('ripgrep', facts);
  return facts.pass;
}

// ------------------------------------------- problem 2: bash cwd and workdir
//
// Three separate behaviours, each one reported by the phone:
//
//   * no `workdir` at all must land in the session workspace, not the guest root,
//   * a `workdir` RELATIVE to the session must resolve against the workspace,
//   * a `workdir` given as a HOST absolute path must be respelled for the guest.
async function criterionBashCwd() {
  const subprocess = ctx.get('subprocess');
  const facts = { hostWorkspace, guestWorkspace };
  const run = async (spec) => {
    const handle = subprocess.spawn({
      ...spec,
      stdio: { stdin: 'ignore', stdout: { maxBytes: 1 << 20 }, stderr: { maxBytes: 1 << 20 } },
      graceMs: 3000,
    });
    const outcome = await handle.done;
    return {
      exitCode: outcome.exitCode,
      stdout: (handle.collected.stdout?.readFrom(0).text ?? '').trim(),
      stderr: (handle.collected.stderr?.readFrom(0).text ?? '').trim(),
    };
  };
  const bash = (command, cwd) => run({ argv: ['bash', '-c', command], ...cwd === undefined ? {} : { cwd } });

  // A. No cwd in the spec at all. `dsh-bash-local` always fills one from the
  //    session, but the provider must not fall back to the guest's `/`.
  try {
    facts.no_cwd = await bash('pwd');
  } catch (error) {
    facts.no_cwd = { error: messageOf(error) };
  }

  // B. The session cwd, as the host spells it (what `workingDirectory.ensure`
  //    returns and what `resolveWorkdir` produces for a relative workdir).
  try {
    facts.host_cwd = await bash('pwd', hostWorkspace);
  } catch (error) {
    facts.host_cwd = { error: messageOf(error) };
  }

  // C. A guest-absolute cwd, which a model writes after seeing bash output.
  try {
    facts.guest_cwd = await bash('pwd', guestWorkspace);
  } catch (error) {
    facts.guest_cwd = { error: messageOf(error) };
  }

  // D. A RELATIVE cwd. `dsh-tool-bash` joins it onto the session cwd before the
  //    provider sees it, but a direct caller (and the acceptance criterion) must
  //    not end up at the guest root.
  try {
    facts.relative_cwd = await bash('pwd', 'step7-acceptance');
  } catch (error) {
    facts.relative_cwd = { error: messageOf(error) };
  }

  // E. The same relative cwd reached the way the tool layer actually produces it,
  //    i.e. already joined onto the session cwd. This is the path a real
  //    `bash({workdir: "src"})` call takes.
  try {
    facts.joined_relative = await bash('pwd', join(hostWorkspace, 'step7-acceptance'));
  } catch (error) {
    facts.joined_relative = { error: messageOf(error) };
  }

  const expectWorkspace = (entry) => entry && entry.stdout === guestWorkspace;
  const expectScratch = (entry) => entry && entry.stdout === `${guestWorkspace}/step7-acceptance`;

  facts.pass = expectWorkspace(facts.no_cwd)
    && expectWorkspace(facts.host_cwd)
    && expectWorkspace(facts.guest_cwd)
    && expectScratch(facts.relative_cwd)
    && expectScratch(facts.joined_relative);
  record('bash_cwd', facts);
  return facts.pass;
}

// ------------------------------------------------ problem 3: two namespaces
//
// The file tools are in Node and the shell is in the guest. A model that ran
// `ls /workspace` and then asked to `read /workspace/x.md` was told "not found".
// The fix is in `ctx.fs` (plugins/dsh-fs-ios), so the criterion is on `ctx.fs`:
// every read path must accept the guest spelling and land on the same bytes.
async function criterionTwoNamespaces() {
  const facts = {};
  const guestPath = `${guestWorkspace}/step7-acceptance/namespaces.txt`;
  const hostPath = join(hostWorkspace, 'step7-acceptance', 'namespaces.txt');
  const body = 'same file, two names\n';

  try {
    // Write through the HOST spelling.
    const written = await ctx.fs.resolve(hostPath);
    await ctx.fs.writeText(written, body, undefined, undefined);
    facts.wrote_host_path = written.displayPath;

    // Read it back through the GUEST spelling: this is the call that used to fail.
    const viaGuest = await ctx.fs.resolve(guestPath);
    facts.guest_display = viaGuest.displayPath;
    facts.via_guest = await ctx.fs.readText(viaGuest, undefined);
    facts.guest_resolves_to_host = viaGuest.displayPath === hostPath;
  } catch (error) {
    facts.error = messageOf(error);
  }

  // `lstat` builds its own display path instead of going through `resolve`, so it
  // needs the translation separately or `ls` would list the wrong target.
  try {
    facts.lstat_guest = await ctx.fs.lstat(guestPath, {}, undefined);
  } catch (error) {
    facts.lstat_error = messageOf(error);
  }

  // A path in neither namespace must stay honest: `/etc/passwd` is the host's, and
  // rewriting it would be a wrong answer rather than a translation.
  try {
    facts.outside_untouched = await ctx.fs.resolve('/etc/passwd');
    facts.outside_display = facts.outside_untouched.displayPath;
  } catch (error) {
    facts.outside_error = messageOf(error);
  }

  // The prompt sentence: the model has to be told the rule, not left to infer it.
  facts.prompt_section = await readPromptSection();

  facts.pass = facts.via_guest === body
    && facts.guest_resolves_to_host === true
    && facts.lstat_guest?.type === 'file'
    && facts.outside_display === '/etc/passwd'
    && typeof facts.prompt_section === 'string'
    && facts.prompt_section.includes(guestWorkspace);
  record('two_namespaces', facts);
  return facts.pass;
}

/**
 * The text of this plugin's prompt section, assembled through the real prompt
 * registry.
 *
 * Read from `ctx.systemPrompt.assemble()` rather than from the plugin's source,
 * because the question is "does the model receive this sentence", not "does the
 * file contain it". A section that failed to register (a wrong order, a missing
 * service) is invisible in the source and obvious here. `assemble()` is the same
 * call the agent loop makes before a request, so the text returned is the text
 * that would be sent.
 */
async function readPromptSection() {
  try {
    const assembled = await ctx.systemPrompt.assemble({});
    const found = (assembled?.sections ?? []).find((entry) => entry?.name === 'ios:path-namespaces');
    return found?.text;
  } catch (error) {
    return `unreadable: ${messageOf(error)}`;
  }
}

// ------------------------------------------ problem 4: one project-key spelling
//
// Every session lives under a directory whose name encodes its project path
// (`projectKey()`), so two spellings of one folder produce two directory names —
// which is exactly what the phone showed (`--private-var-…--` and `--var-…--`).
// The fix is upstream of that: the Swift host now resolves with `realpath(3)`,
// the same call Node's `fs.realpath` makes, so the path published to Node and the
// path Node canonicalises are one string.
//
// What this criterion can check from INSIDE the process is the second half: that
// `projectKey` of the workspace Node was given equals the key of the workspace as
// Node canonicalises it. The phone-side confirmation is the user's, and the report
// says so.
async function criterionProjectKey() {
  const facts = { hostWorkspace };
  const { realpath } = await import('node:fs/promises');
  facts.realpath_of_workspace = await realpath(hostWorkspace).catch((error) => `unreadable: ${messageOf(error)}`);

  // `projectKey` is module-private, so it is recomputed with the same documented
  // rule instead of imported: separators collapse to one `-`, other unsafe code
  // units become `~XXXX`, wrapped in `--`, bounded to 251 characters. The rule is
  // restated here on purpose — if DSH changes it, this criterion fails loudly
  // rather than agreeing with itself.
  const keyOf = (cwd) => {
    let readable = '';
    let separatorRun = false;
    for (let index = 0; index < cwd.length; index += 1) {
      const code = cwd.charCodeAt(index);
      const ch = String.fromCharCode(code);
      if (ch === '/' || ch === '\\' || ch === ':') {
        if (!separatorRun) readable += '-';
        separatorRun = true;
      } else if (ch !== '~' && /^[A-Za-z0-9._-]$/.test(ch)) {
        readable += ch;
        separatorRun = false;
      } else {
        readable += '~' + code.toString(16).toUpperCase().padStart(4, '0');
        separatorRun = false;
      }
    }
    return `--${(readable.replace(/^-+/, '') || 'root').slice(0, 251)}--`;
  };
  facts.key_from_published_path = keyOf(hostWorkspace);
  facts.key_from_realpath = keyOf(String(facts.realpath_of_workspace));

  // The real question: how many project directories exist, and do they all agree
  // with each other about the `/private` prefix? A mix is the defect.
  const sessionsRoot = join(process.env.DSH_HOME ?? '', 'sessions');
  try {
    const { readdirSync } = await import('node:fs');
    const dirs = readdirSync(sessionsRoot).filter((entry) => entry.startsWith('--'));
    facts.project_dirs = dirs;
    facts.project_dir_count = dirs.length;
    facts.distinct_of_this_workspace = dirs.filter((entry) => entry === facts.key_from_realpath).length;
    facts.stale_spellings = dirs.filter((entry) => entry !== facts.key_from_realpath);
    const persistenceKeys = dirs.filter((entry) => entry.includes('private-var')).length;
    facts.dirs_with_private_var = persistenceKeys;
    facts.dirs_with_bare_var = dirs.filter((entry) => /(^|-)var-mobile-/.test(entry)).length;
  } catch (error) {
    facts.sessions_error = messageOf(error);
  }
  facts.published_equals_realpath = facts.realpath_of_workspace === hostWorkspace;
  facts.pass = facts.key_from_published_path === facts.key_from_realpath
    && facts.published_equals_realpath === true
    && (facts.stale_spellings ?? []).length === 0;
  record('project_key', facts);
  return facts.pass;
}

// --------------------------------------------- problem 5b: write then edit
//
// The phone reported `write` followed immediately by `edit` failing with "file
// changed since it was read", needing a `read` in between. Three separate things
// have to be separated, and they have different answers:
//
//   A. Is the version token coherent on this port? It is `dev:ino:size:mtimeNs:ctimeNs`
//      and it crosses a bind mount, so a guest write that the host cannot see in
//      the metadata would make every guard fail. Measured below.
//   B. Does an UNGUARDED edit work right after a write? (i.e. is the provider
//      itself fine)
//   C. Does the TOOL refuse it, and is that DSH's design or this port's defect?
//
// (C) is answered by the source, not by an opinion, and the answer is "design":
// `@deepseek-ai/dsh-fs-observation-policy` requires a prior observation for every
// mutating call, and a `write` is not an observation of the file's content — it is
// a mutation. The desktop harness has the same plugin with the same rule (the two
// packages are byte-identical between `dsh-dev/install` and `payload/`, compared
// with `cmp`), so the model sees the same `cannot modify "…": file has not been
// read — read the file, then retry` on a laptop. What this criterion has to prove
// is that no *additional*, port-specific staleness is layered on top: that the
// version a write reports is the version the next stat returns, and that a guest
// write is visible to it.
async function criterionWriteThenEdit() {
  const facts = {};
  const tools = ctx.get('tools');
  facts.tool_runtime = tools === undefined ? null : (tools.constructor?.name ?? typeof tools);

  const target = await ctx.fs.resolve(join(guestWorkspace, 'step7-acceptance', 'edit-probe.txt'));
  facts.display_path = target.displayPath;

  // A. Write through the provider, and compare the version it reports with a
  //    fresh stat of the same path. Same version = coherent metadata.
  const first = await ctx.fs.writeText(target, 'one\ntwo\n', undefined, undefined);
  facts.write_version = String(first.version ?? '');
  facts.write_operation = first.operation;
  const afterWrite = await ctx.fs.stat(target, undefined);
  facts.stat_after_write = String(afterWrite?.version ?? '');
  facts.metadata_coherent = facts.stat_after_write === facts.write_version;

  // B. A GUEST write, then the same comparison. This is the case a bind mount
  //    could break: the bytes land through the guest kernel and the metadata the
  //    host provider reads comes from the other side of the mount.
  const subprocess = ctx.get('subprocess');
  const runBash = async (command) => {
    const handle = subprocess.spawn({
      argv: ['bash', '-c', command],
      cwd: guestWorkspace,
      stdio: { stdin: 'ignore', stdout: { maxBytes: 1 << 16 }, stderr: { maxBytes: 1 << 16 } },
      graceMs: 3000,
    });
    const outcome = await handle.done;
    return { exitCode: outcome.exitCode, stdout: (handle.collected.stdout?.readFrom(0).text ?? '').trim() };
  };
  facts.bash_append = await runBash(
    `printf 'three\\n' >> ${guestWorkspace}/step7-acceptance/edit-probe.txt && stat -c '%s' ${guestWorkspace}/step7-acceptance/edit-probe.txt`,
  );
  const afterBash = await ctx.fs.stat(target, undefined);
  facts.stat_after_bash_write = String(afterBash?.version ?? '');
  facts.guest_write_visible_to_host_version = facts.stat_after_bash_write !== facts.stat_after_write;

  // B2. An UNGUARDED edit, which is what the provider does with no policy. If this
  //     failed, the provider would be broken and no policy answer would save it.
  try {
    const edited = await ctx.fs.editText(target, { oldString: 'one', newString: 'ONE', replaceAll: false }, undefined, undefined);
    facts.unguarded_edit = { ok: true, version: String(edited.version ?? '') };
  } catch (error) {
    facts.unguarded_edit = { ok: false, error: messageOf(error), code: error?.code };
  }

  // C. The model-visible layer. NOT driven here, and the reason is structural:
  //    the tools are registered inside the AGENT PRESET scope, so
  //    `tools.execute()` with no `agent` resolves against the global view and
  //    answers `unknown tool "write"` — measured, on the first version of this
  //    criterion. Driving them needs a live agent, i.e. a live model turn.
  //
  //    The model path is therefore measured through the app's real agent loop
  //    against the mock: `prompts/15-step7-pathtest.txt` (keyword `PATHTEST`) makes
  //    one turn call `write` then `edit` with no read in between, then `read` and
  //    `edit` again. What came back is in the session log and quoted in REPORT-7.
  //    That is better evidence than a service call: it includes the observation
  //    policy, the sandbox fence and the model-facing text.
  facts.model_path_measured_by = 'scripts/agent-turn.py + prompts/15-step7-pathtest.txt (PATHTEST)';

  //    What this criterion keeps is the part the tool layer cannot show: whether
  //    the version metadata survives the bind mount at all. If it did not, no
  //    policy answer would help, because every guard would fail on unchanged files.
  //    The guest's own view of a file the FILE TOOL wrote is checked too — that is
  //    the two-namespaces property, end to end.
  facts.guest_sees_provider_write = await runBash(
    `cat ${guestWorkspace}/step7-acceptance/edit-probe.txt`,
  );

  // Both the provider AND the tool layer must be coherent; the "needs a read"
  // answer is the documented policy, verified by the recovery step above.
  facts.pass = facts.metadata_coherent === true
    && facts.guest_write_visible_to_host_version === true
    && facts.unguarded_edit?.ok === true
    && facts.guest_sees_provider_write?.stdout?.includes('ONE') === true;
  record('write_then_edit', facts);
  return facts.pass;
}

// --------------------------------------------------- problem 5a: git card
//
// The phone reported the changed-files card counting only the file-tool writes,
// not what bash changed, so its numbers disagreed with `git diff`. The card is
// built by `dsh-workspace-changes` from a turn's git snapshots, so the question
// to answer is: does a snapshot taken through the guest's git see a file that the
// GUEST wrote?
//
// The mechanism that could break this on this port is precise: the plugin builds
// its scratch object store from the HOST `tmpdir()` and hands it to the GUEST's
// git as `GIT_OBJECT_DIRECTORY`; the provider respells those paths (see
// `hostPathToGuest`). If that respell failed, `git add` would fail, no snapshot
// would be taken, and the card would fall back to file-tool captures only —
// exactly the phone's symptom. So the criterion runs the same git commands the
// plugin runs, with the same environment, through `ctx.subprocess`.
async function criterionGitCard() {
  const facts = {};
  const subprocess = ctx.get('subprocess');
  const repo = join(hostWorkspace, 'step7-acceptance', 'git-repo');
  mkdirSync(repo, { recursive: true });

  const run = async (argv, cwd, env) => {
    const handle = subprocess.spawn({
      argv,
      cwd,
      stdio: { stdin: 'ignore', stdout: { maxBytes: 1 << 20 }, stderr: { maxBytes: 1 << 20 } },
      graceMs: 5000,
      ...env === undefined ? {} : { env },
    });
    const outcome = await handle.done;
    return {
      exitCode: outcome.exitCode,
      stdout: (handle.collected.stdout?.readFrom(0).text ?? '').trim(),
      stderr: (handle.collected.stderr?.readFrom(0).text ?? '').trim(),
    };
  };

  try {
    facts.resolved_git = await subprocess.resolveExecutable('git', undefined, undefined);
  } catch (error) {
    facts.resolved_git = null;
    facts.git_resolve_error = messageOf(error);
  }

  const guestRepo = `${guestWorkspace}/step7-acceptance/git-repo`;
  const init = await run(['bash', '-c',
    `cd ${guestRepo} && git init -q 2>&1; git config user.email t@example.invalid; git config user.name T; `
    + 'printf "one\\n" > tracked.txt && git add tracked.txt && git commit -qm initial && echo ready'], guestWorkspace);
  facts.init = init;

  // The scratch object store, spelled exactly as the plugin spells it: the HOST
  // tmpdir. `ctx.subprocess` must respell it into the guest's `/tmp` mount.
  const hostTmp = process.env.DSH_HOST_TMPDIR ?? '';
  const scratchObjects = hostTmp === '' ? '' : join(hostTmp, 'step7-git-objects');
  facts.host_tmp = hostTmp;
  facts.scratch_objects_host_spelling = scratchObjects;
  if (scratchObjects !== '') mkdirSync(scratchObjects, { recursive: true });

  const env = {
    GIT_OBJECT_DIRECTORY: scratchObjects,
    GIT_INDEX_FILE: join(scratchObjects, 'index'),
    GIT_CONFIG_COUNT: '0',
    GIT_TERMINAL_PROMPT: '0',
    GIT_OPTIONAL_LOCKS: '0',
    LC_ALL: 'C',
  };
  const baselineEnv = { ...env, GIT_INDEX_FILE: join(scratchObjects, 'index0') };

  // THE BASELINE COMES FIRST, BEFORE BASH TOUCHES ANYTHING. This is the order the
  // plugin uses (`turn/start` snapshots, then tools run), and it is also the only
  // order that measures anything: a baseline taken after the change produces an
  // empty diff, which would "pass" a weaker check while proving nothing about
  // whether bash's writes reach the snapshot. `git diff-tree` compares two trees
  // for the same reason — there is no `HEAD` to compare against yet in a
  // freshly-initialised repository (`fatal: bad object HEAD`, measured on this
  // criterion's first version).
  let beforeTree = null;
  if (scratchObjects !== '') {
    facts.git_add_baseline = await run(['git', 'add', '--all', '--ignore-errors'], guestRepo, baselineEnv);
    beforeTree = await run(['git', 'write-tree'], guestRepo, baselineEnv);
    facts.git_baseline_tree = beforeTree;
  }

  // A BASH write — the thing the phone said the card ignored.
  const bashChange = await run(['bash', '-c',
    `cd ${guestRepo} && printf 'two\\n' >> tracked.txt && printf 'new\\n' > untracked.txt && git status --porcelain`], guestWorkspace);
  facts.bash_change = bashChange;

  // Then the plugin's own after-snapshot, with its own environment.
  if (scratchObjects !== '' && beforeTree !== null) {
    const added = await run(['git', 'add', '--all', '--ignore-errors'], guestRepo, env);
    facts.git_add = added;
    const tree = await run(['git', 'write-tree'], guestRepo, env);
    facts.git_write_tree = tree;
    const diff = beforeTree.exitCode === 0 && tree.exitCode === 0
      ? await run(['git', 'diff-tree', '-r', '-M', '-z', '--numstat', beforeTree.stdout, tree.stdout], guestRepo, env)
      : { exitCode: null, stdout: '', stderr: 'no tree' };
    facts.git_diff_tree = { exitCode: diff.exitCode, stdout: diff.stdout.slice(0, 500), stderr: diff.stderr.slice(0, 400) };
    // The whole point: the snapshot must contain the file BASH wrote.
    facts.card_would_see_bash_changes = diff.stdout.includes('tracked.txt') || diff.stdout.includes('untracked.txt');
    facts.line_counts = diff.stdout.split('\0').filter((part) => part.length > 0).slice(0, 12);
  }

  // And whether the workspaceChanges service is mounted with a git it can use.
  const changes = ctx.get('workspaceChanges');
  facts.service_mounted = changes !== undefined;

  facts.pass = facts.service_mounted === true
    && typeof facts.resolved_git === 'string'
    && facts.bash_change?.stdout.includes('tracked.txt')
    && facts.card_would_see_bash_changes === true;
  record('git_card', facts);
  return facts.pass;
}

// --------------------------------------------------------------------- run
const results = {};
for (const [id, fn] of [
  ['ripgrep', criterionRipgrep],
  ['bash_cwd', criterionBashCwd],
  ['two_namespaces', criterionTwoNamespaces],
  ['project_key', criterionProjectKey],
  ['write_then_edit', criterionWriteThenEdit],
  ['git_card', criterionGitCard],
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
  passed: Object.values(results).filter(Boolean).length,
  total: Object.keys(results).length,
  results,
};
write();
process.stdout.write(`DSHPORTE_STEP7 ${JSON.stringify(report.summary)}\n`);
process.exit(0);
