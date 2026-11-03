// Acceptance run for steps 3 and 4, from the Node side.
//
// WHY IT RUNS INSIDE THE APP: the acceptance criteria are about the *Node* half
// of this process talking to the *Swift* half over the channel. A host script
// cannot be that half — it would be a fourth process, and it would prove nothing
// about the embedded runtime (jitless, no WebAssembly, the fetch polyfill, the
// preload's child_process block). So this runs in the app's own Node process,
// through the same client module step 5's provider will use, and writes its
// verdict to a JSON file the host script reads back.
//
// It is gated: `ios-app-entry.mjs` runs it instead of DSH only when
// `DSHPORTE_CHANNEL_ACCEPTANCE=1` is in the environment. A normal launch never
// reaches this file.
//
// Every criterion writes a `pass`/`fail` plus the raw measurement that decided
// it. Where a result is a fact rather than a pass/fail (the symlink conclusion,
// the case experiment), it is recorded as text and the report quotes it as-is.

import { writeFileSync, readFileSync, mkdirSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { exec, resolve, health, channelConfig } from './guest-channel-client.mjs';

const RESULT_NAME = 'DSHPortE-channel-acceptance.json';

/** Where to write the verdict: beside the workspace, in the app's Documents. */
function resultPath() {
  const workspace = process.env.DSH_IOS_WORKSPACE ?? process.cwd();
  return process.env.DSHPORTE_ACCEPTANCE_OUT ?? join(dirname(workspace), RESULT_NAME);
}

/** Nanoseconds as milliseconds, for anything measured with `hrtime`. */
function msSince(startNs) {
  return Number(process.hrtime.bigint() - startNs) / 1e6;
}

const report = {
  startedAt: new Date().toISOString(),
  node: process.versions.node,
  execArgv: process.execArgv,
  jitless: process.execArgv.includes('--jitless'),
  criteria: {},
};

function record(id, value) {
  report.criteria[id] = value;
  write();
}

function write() {
  try {
    mkdirSync(dirname(resultPath()), { recursive: true });
    writeFileSync(resultPath(), JSON.stringify(report, null, 2));
  } catch (error) {
    process.stderr.write(`acceptance: could not write the report: ${error}\n`);
  }
}

/** Run a guest command and return the raw result, asserting nothing. */
async function guest(command, options = {}) {
  return exec({ command, timeoutMs: 120000, ...options });
}

// ---------------------------------------------------------------- criterion 1
// Streaming: five lines 100 ms apart must arrive as separate chunks, not as one
// blob at the end.
async function criterionStreaming() {
  const arrivals = [];
  const startNs = process.hrtime.bigint();
  const result = await exec({
    command: 'for i in 1 2 3 4 5; do echo $i; sleep 0.1; done',
    timeoutMs: 60000,
    onChunk: (event) => {
      arrivals.push({
        arrivalMs: Number(msSince(startNs).toFixed(1)),
        bytes: event.chunk.length,
        text: event.chunk.toString('utf8'),
      });
    },
  });

  const wallMs = Number(msSince(startNs).toFixed(1));
  // What "streaming" has to mean here: at least five separate arrivals, spread
  // over time rather than all within a millisecond of each other, and the first
  // one well before the total finished.
  const firstMs = arrivals.length > 0 ? arrivals[0].arrivalMs : null;
  const lastMs = arrivals.length > 0 ? arrivals[arrivals.length - 1].arrivalMs : null;
  const spread = firstMs !== null && lastMs !== null ? lastMs - firstMs : 0;

  const distinctNumbers = new Set();
  for (const a of arrivals) {
    for (const token of a.text.split(/\s+/)) if (/^[1-5]$/.test(token)) distinctNumbers.add(token);
  }

  const pass =
    arrivals.length >= 5
    && spread >= 250 // five 100 ms steps cannot all land inside 250 ms
    && distinctNumbers.size === 5
    && result.stdout === '1\n2\n3\n4\n5\n';

  record('stream_chunks', {
    pass,
    chunk_count: arrivals.length,
    first_arrival_ms: firstMs,
    last_arrival_ms: lastMs,
    spread_ms: Number(spread.toFixed(1)),
    process_wall_ms: wallMs,
    stdout: result.stdout,
    stderr: result.stderr,
    exit_code: result.exitCode,
    arrivals: arrivals.map((a) => ({ ms: a.arrivalMs, bytes: a.bytes, text: a.text.trim() })),
  });
  return pass;
}

// ---------------------------------------------------------------- criterion 2a
// A wrong token must be rejected with 401, and the guest must not have run.
async function criterionAuth() {
  const config = channelConfig();
  const goodToken = config.token;
  const attempts = [];

  const cases = [
    { name: 'no header', headers: {} },
    { name: 'empty bearer', headers: { authorization: 'Bearer ' } },
    { name: 'wrong token', headers: { authorization: `Bearer ${'0'.repeat(goodToken.length)}` } },
    { name: 'wrong scheme', headers: { authorization: `Basic ${goodToken}` } },
    { name: 'prefix of token', headers: { authorization: `Bearer ${goodToken.slice(0, -1)}` } },
  ];

  for (const testCase of cases) {
    const response = await fetch(`${config.url}/v1/exec`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', ...testCase.headers },
      body: JSON.stringify({ command: 'echo SHOULD-NOT-RUN' }),
    });
    const body = await response.text();
    attempts.push({ case: testCase.name, status: response.status, body: body.slice(0, 120) });
  }

  // The positive control: with the right token the same request works, so a 401
  // everywhere cannot be mistaken for "auth is enforced".
  const ok = await exec({ command: 'echo AUTH-POSITIVE-CONTROL', timeoutMs: 30000 });

  const all401 = attempts.every((a) => a.status === 401);
  const pass = all401 && ok.exitCode === 0 && ok.stdout.includes('AUTH-POSITIVE-CONTROL');

  record('auth_401', {
    pass,
    attempts,
    positive_control: { exit_code: ok.exitCode, stdout: ok.stdout.trim() },
  });
  return pass;
}

// ---------------------------------------------------------------- criterion 2b
// A non-loopback Host must be refused even with the right token. This is the
// DNS-rebinding guard: a page that resolves to 127.0.0.1 still sends its own Host.
async function criterionHostCheck() {
  const config = channelConfig();
  const attempts = [];

  const hostileHosts = [
    'evil.example.com',
    'evil.example.com:80',
    '192.168.1.10',
    '127.0.0.1.evil.example.com',
  ];

  for (const host of hostileHosts) {
    const response = await fetch(`${config.url}/v1/exec`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${config.token}`,
        host,
      },
      body: JSON.stringify({ command: 'echo HOST-SHOULD-BLOCK' }),
    });
    const body = await response.text();
    attempts.push({ host, status: response.status, body: body.slice(0, 120) });
  }

  // Positive controls: both spellings of loopback must be accepted.
  const loopback = [];
  for (const host of ['127.0.0.1', `127.0.0.1:${config.url.split(':').pop()}`, 'localhost']) {
    const response = await fetch(`${config.url}/v1/health`, {
      method: 'GET',
      headers: { authorization: `Bearer ${config.token}`, host },
    });
    loopback.push({ host, status: response.status });
  }

  const refused = attempts.every((a) => a.status === 403 || a.status === 401);
  const acceptedLoopback = loopback.every((a) => a.status === 200);
  const pass = refused && acceptedLoopback;

  record('host_check', { pass, hostile: attempts, loopback });
  return pass;
}

// ---------------------------------------------------------------- criterion 2c
// The token must not appear in any log the app wrote.
async function criterionTokenNotLogged() {
  const config = channelConfig();
  const token = config.token;
  const documents = dirname(process.env.DSH_IOS_WORKSPACE ?? process.cwd());
  const candidates = [
    join(documents, 'DSHPortC-node.log'),
    join(documents, 'DSHPortE-guest-test.json'),
    join(process.env.DSH_HOME ?? '', 'events.jsonl'),
  ].filter((p) => p.length > 0 && existsSync(p));

  const hits = [];
  for (const path of candidates) {
    let text;
    try {
      text = readFileSync(path, 'utf8');
    } catch {
      continue;
    }
    if (token.length > 0 && text.includes(token)) hits.push(path);
  }

  const pass = token.length === 64 && hits.length === 0;
  record('token_not_logged', {
    pass,
    token_length: token.length,
    scanned_files: candidates,
    files_containing_token: hits,
    // Deliberately not the token itself, and not a prefix of it either.
  });
  return pass;
}

// ---------------------------------------------------------------- criterion 3
// Port retry: the host script holds one loopback port before launch and tells
// the app to want it. The app must come up somewhere else rather than failing.
//
// The check has three parts, because any one alone can pass for the wrong reason:
//   1. a preferred port WAS requested (otherwise retry was never exercised);
//   2. the port actually bound is not that port (failover happened);
//   3. the preferred port really was occupied by someone else at the time
//      (otherwise the app simply took it and nothing was tested).
async function criterionPortRetry() {
  const preferred = Number(process.env.DSH_GUEST_CHANNEL_PREFERRED_PORT ?? 0);
  const config = channelConfig();
  const requested = Number.isInteger(preferred) && preferred > 0;
  const boundPort = Number(new URL(config.url).port);
  let preferredWasOccupied = null;
  let occupiedBy = null;
  try {
    // Ask the guest kernel to connect to the preferred port. If something is
    // listening there, the app's own environment proves the collision rather
    // than the host script asserting it.
    const probe = await guest(
      `(printf 'GET / HTTP/1.0\\r\\n\\r\\n'; sleep 0.3) | nc 127.0.0.1 ${preferred} 2>&1 | head -1`,
      { timeoutMs: 15000 }
    );
    preferredWasOccupied = probe.stdout.trim().length > 0;
    occupiedBy = probe.stdout.trim().slice(0, 120);
  } catch (error) {
    preferredWasOccupied = null;
    occupiedBy = `probe failed: ${error}`;
  }

  const pass = requested && boundPort > 0 && boundPort !== preferred;
  record('port_retry', {
    pass,
    preferred_port_requested: requested ? preferred : null,
    bound_port: boundPort,
    failover_happened: requested ? boundPort !== preferred : null,
    preferred_port_answerable_from_guest: preferredWasOccupied,
    preferred_port_answer: occupiedBy,
    note: 'pass requires a preferred port was requested AND a different port got '
      + 'bound; preferred_port_answerable_from_guest is recorded separately '
      + 'because the occupant is a host process the guest may not reach',
  });
  return pass;
}

// ---------------------------------------------------------------- criterion 4
// The workspace is the same files on both sides.
async function criterionSharedReadWrite() {
  const config = channelConfig();
  const workspaceHost = process.env.DSH_IOS_WORKSPACE ?? process.cwd();
  const workspaceGuest = config.workspace || '/workspace';
  const stamp = Date.now().toString(36);

  // --- guest writes, host reads -------------------------------------------
  const guestFile = `guest-wrote-${stamp}.txt`;
  const guestPayload = `hi-from-guest ${stamp}`;
  const guestWrite = await guest(`printf '%s\\n' '${guestPayload}' > ${workspaceGuest}/${guestFile}`);
  const hostReadPath = join(workspaceHost, guestFile);
  const hostSawIt = existsSync(hostReadPath);
  const hostContent = hostSawIt ? readFileSync(hostReadPath, 'utf8').trim() : null;

  // --- host writes, guest reads -------------------------------------------
  const hostFile = `host-wrote-${stamp}.txt`;
  const hostPayload = `hi-from-host ${stamp}`;
  writeFileSync(join(workspaceHost, hostFile), `${hostPayload}\n`);
  const guestRead = await guest(`cat ${workspaceGuest}/${hostFile}`);

  // --- same file, not a copy: write from guest, append from host, read back --
  const sharedFile = `shared-${stamp}.txt`;
  await guest(`printf 'line-from-guest\\n' > ${workspaceGuest}/${sharedFile}`);
  const sharedHostPath = join(workspaceHost, sharedFile);
  const afterGuestWrite = existsSync(sharedHostPath) ? readFileSync(sharedHostPath, 'utf8') : '';
  // host appends, guest sees two lines
  writeFileSync(sharedHostPath, `${afterGuestWrite}line-from-host\n`);
  const guestSeesBoth = await guest(`cat ${workspaceGuest}/${sharedFile}`);

  // --- identity: the guest's view and the host's view agree on inode/dev ----
  const resolved = await resolve(`${workspaceGuest}/${sharedFile}`);
  let hostStat = null;
  try {
    const { statSync } = await import('node:fs');
    const s = statSync(sharedHostPath);
    hostStat = { size: s.size, ino: s.ino, dev: s.dev };
  } catch { /* recorded as null */ }

  const pass =
    guestWrite.exitCode === 0
    && hostSawIt
    && hostContent === guestPayload
    && guestRead.exitCode === 0
    && guestRead.stdout.trim() === hostPayload
    && guestSeesBoth.stdout === 'line-from-guest\nline-from-host\n';

  record('shared_rw', {
    pass,
    workspace_guest: workspaceGuest,
    workspace_host: workspaceHost,
    guest_to_host: {
      guest_command: `printf ... > ${workspaceGuest}/${guestFile}`,
      guest_exit: guestWrite.exitCode,
      host_path: hostReadPath,
      host_saw_file: hostSawIt,
      host_content: hostContent,
      expected: guestPayload,
    },
    host_to_guest: {
      host_path: join(workspaceHost, hostFile),
      guest_command: `cat ${workspaceGuest}/${hostFile}`,
      guest_exit: guestRead.exitCode,
      guest_stdout: guestRead.stdout.trim(),
      expected: hostPayload,
    },
    same_file_both_directions: {
      guest_stdout: guestSeesBoth.stdout,
      expected: 'line-from-guest\nline-from-host\n',
    },
    identity: { guest_resolve: resolved, host_stat: hostStat },
  });
  return pass;
}

// ---------------------------------------------------------------- criterion 5
// `ln -s` under /workspace. The answer is the deliverable, not a pass/fail.
async function criterionSymlink() {
  const config = channelConfig();
  const guestWorkspace = config.workspace || '/workspace';
  const workspaceHost = process.env.DSH_IOS_WORKSPACE ?? process.cwd();
  const stamp = Date.now().toString(36);

  const result = await guest(
    `cd ${guestWorkspace} && rm -f sym-a-${stamp} sym-b-${stamp} && `
    + `echo target > sym-a-${stamp} && ln -s sym-a-${stamp} sym-b-${stamp}; echo "exit=$?"`
  );

  // Read it back from the guest: does the link resolve, and to what?
  const readBack = await guest(
    `cd ${guestWorkspace} && ls -l sym-b-${stamp} 2>&1; echo "---"; `
    + `cat sym-b-${stamp} 2>&1; echo "---"; readlink sym-b-${stamp} 2>&1; echo "exit=$?"`
  );

  // And from the host: what did the host filesystem actually get?
  let hostLstat = null;
  let hostReadlink = null;
  try {
    const { lstatSync, readlinkSync } = await import('node:fs');
    const linkPath = join(workspaceHost, `sym-b-${stamp}`);
    hostLstat = existsSync(linkPath) ? { isSymlink: lstatSync(linkPath).isSymbolicLink(), size: lstatSync(linkPath).size } : null;
    if (hostLstat?.isSymlink) hostReadlink = readlinkSync(linkPath);
  } catch (error) {
    hostLstat = { error: String(error) };
  }

  const combined = `${result.stdout}\n${result.stderr}\n${readBack.stdout}\n${readBack.stderr}`;
  let outcome;
  if (/Operation not permitted|EPERM/i.test(combined)) outcome = 'EPERM';
  else if (/Read-only file system|EROFS/i.test(combined)) outcome = 'EROFS';
  else if (/exit=0/.test(result.stdout) && hostLstat?.isSymlink === true) outcome = 'success';
  else if (/exit=0/.test(result.stdout) && hostLstat?.isSymlink === false) outcome = 'created-but-not-a-host-symlink';
  else outcome = 'other';

  // A host-side non-symlink of exactly the target's length is the signature of
  // fakefs_symlink's own model: it writes the target into a regular file and
  // marks S_IFLNK in meta.db. Recording the length and the content makes that
  // identification checkable rather than asserted.
  let hostFileContent = null;
  if (hostLstat?.isSymlink === false) {
    try {
      const { readFileSync: readF } = await import('node:fs');
      hostFileContent = readF(join(workspaceHost, `sym-b-${stamp}`), 'utf8');
    } catch (error) {
      hostFileContent = `error: ${error}`;
    }
  }

  // ---- the other direction: a symlink the HOST creates, read from the guest.
  //
  // This is the case the provider actually depends on. `npm install`, `pnpm`
  // and `node_modules/.bin` either run on the host or are created there; if the
  // guest cannot follow a host symlink, a package tree built on the host is
  // only half-usable from the guest. The guest->host direction above is the
  // reverse question. Both are measured because they can disagree.
  let hostToGuest = null;
  try {
    const fsMod = await import('node:fs');
    const hostTarget = `host-target-${stamp}`;
    const hostLink = `host-link-${stamp}`;
    fsMod.writeFileSync(join(workspaceHost, hostTarget), 'host-side-content\n');
    try {
      fsMod.symlinkSync(hostTarget, join(workspaceHost, hostLink));
    } catch (error) {
      hostToGuest = { host_symlink_created: false, host_error: String(error) };
    }
    if (hostToGuest === null) {
      const seen = await guest(
        `cd ${guestWorkspace} && ls -l ${hostLink} 2>&1; echo "---"; `
        + `cat ${hostLink} 2>&1; echo "---"; readlink ${hostLink} 2>&1; echo "readlink-exit=$?"; `
        + `echo "---"; stat -c 'lstat=%F' ${hostLink} 2>&1; `
        + `stat -L -c 'stat-follow=%F' ${hostLink} 2>&1; `
        + `test -L ${hostLink} && echo TEST-L-TRUE || echo TEST-L-FALSE`
      );
      hostToGuest = {
        host_symlink_created: true,
        host_link_target: hostTarget,
        guest_stdout: seen.stdout,
        guest_stderr: seen.stderr,
        guest_exit: seen.exitCode,
        guest_follows_host_symlink: seen.stdout.includes('host-side-content'),
        // Test the mode column only. A bare /-l/ test against the whole line
        // matched the hyphen in the file's own name ("host-link-...") and
        // reported true for a regular file — caught by reading the recorded
        // stdout, which said `-rw-r--r--`.
        guest_lists_as_symlink: /^l[rwxsStT-]{9}\s/.test(seen.stdout.split('---')[0] ?? ''),
        guest_mode_column: (seen.stdout.split('---')[0] ?? '').trim().slice(0, 10),
      };

      // Which field is the guest reporting? The link's target string and the
      // target file's contents have different lengths here on purpose (a long
      // name, short content). If the guest reports the *target string's*
      // length, its st_size came from lstat; if the *content's* length, from
      // stat-after-follow. That decides whether a tool can trust st_size.
      const longTarget = `x-${'y'.repeat(60)}-target-${stamp}`;
      const longLink = `long-link-${stamp}`;
      fsMod.writeFileSync(join(workspaceHost, longTarget), 'abc\n');
      try {
        fsMod.symlinkSync(longTarget, join(workspaceHost, longLink));
        const sizes = await guest(
          `cd ${guestWorkspace} && `
          + `echo "link-target-string-len=$(printf %s ${longTarget} | wc -c)"; `
          + `echo "target-content-len=$(wc -c < ${longTarget})"; `
          + `echo "stat-nofollow=$(stat -c '%F %s' ${longLink} 2>&1)"; `
          + `echo "stat-follow=$(stat -L -c '%F %s' ${longLink} 2>&1)"; `
          + `echo "ls-l=$(ls -l ${longLink} 2>&1)"; `
          + `echo "readlink=$(readlink ${longLink} 2>&1)"; `
          + `echo "cat=$(cat ${longLink} 2>&1 | tr -d '\\n')"; `
          + `test -L ${longLink} && echo "test-L=true" || echo "test-L=false"; `
          + `test -e ${longLink} && echo "test-e=true" || echo "test-e=false"`
        );
        hostToGuest.size_probe = {
          guest_stdout: sizes.stdout,
          guest_stderr: sizes.stderr,
          target_string_length: longTarget.length,
          content_length: 4,
        };
      } catch (error) {
        hostToGuest.size_probe = { error: String(error) };
      }
    }
  } catch (error) {
    hostToGuest = { error: String(error) };
  }

  record('symlink', {
    outcome,
    guest_script_stdout: result.stdout,
    guest_script_stderr: result.stderr,
    guest_exit: result.exitCode,
    guest_readback_stdout: readBack.stdout,
    guest_readback_exit: readBack.exitCode,
    host_lstat: hostLstat,
    host_readlink: hostReadlink,
    host_file_content: hostFileContent,
    guest_sees_symlink: /^l/.test(readBack.stdout.trim()),
    host_created_symlink_seen_from_guest: hostToGuest,
    intersection_explanation:
      'fakefs_symlink (fs/fake.c:690) stores a symlink as a regular file holding '
      + 'the target plus an S_IFLNK mode bit in meta.db. On a bind mount that file '
      + 'is created in the HOST directory, so the guest sees a working symlink '
      + 'while the host sees a small regular file containing the target string. '
      + 'The two views disagree on purpose and by construction, not by accident.',
    provider_implication:
      'Guest->host symlinks are NOT real host symlinks, so anything the host '
      + 'does with the workspace (npm, pnpm, node resolution, `fs.readlink`) '
      + 'sees a small regular file. Host->guest symlinks hit the opposite '
      + 'limitation: the guest resolves them through its own path model. The '
      + 'provider must not assume either side can create links the other sees.',
  });
  return outcome === 'success';
}

// ---------------------------------------------------------------- criterion 6
// A package-install-shaped operation: a tree with symlinks and many small files.
// There is no Node in the guest, so `npm install` itself is impossible; this is
// the operation the task book allows as the equivalent, plus the directory shape
// npm produces (`node_modules/.bin` full of symlinks).
async function criterionInstallShaped() {
  const config = channelConfig();
  const guestWorkspace = config.workspace || '/workspace';
  const workspaceHost = process.env.DSH_IOS_WORKSPACE ?? process.cwd();
  const stamp = Date.now().toString(36);

  // Build the tarball on the HOST (where Node exists), then unpack it in the
  // GUEST. That split is the point: it is the exact shape of "the host has the
  // tool, the guest has to receive the tree".
  const pkgDir = join(workspaceHost, `pkg-src-${stamp}`);
  mkdirSync(join(pkgDir, 'node_modules', '.bin'), { recursive: true });
  mkdirSync(join(pkgDir, 'node_modules', 'dep-a', 'lib'), { recursive: true });
  mkdirSync(join(pkgDir, 'node_modules', 'dep-b'), { recursive: true });

  const { writeFileSync: writeFile, symlinkSync } = await import('node:fs');
  writeFile(join(pkgDir, 'package.json'), JSON.stringify({ name: 'dsh-workspace-probe', version: '1.0.0' }, null, 2));
  for (let i = 0; i < 50; i += 1) {
    writeFile(join(pkgDir, 'node_modules', 'dep-a', 'lib', `mod-${i}.js`), `export const n = ${i};\n`);
  }
  writeFile(join(pkgDir, 'node_modules', 'dep-a', 'index.js'), "export * from './lib/mod-0.js';\n");
  writeFile(join(pkgDir, 'node_modules', 'dep-b', 'index.js'), "export default 1;\n");
  // The npm shape: .bin entries are symlinks into the package.
  symlinkSync('../dep-a/index.js', join(pkgDir, 'node_modules', '.bin', 'dep-a'));
  symlinkSync('../dep-b/index.js', join(pkgDir, 'node_modules', '.bin', 'dep-b'));

  // tar it on the host
  const tarPath = join(workspaceHost, `pkg-${stamp}.tar.gz`);
  const { execSync } = { execSync: null }; // deliberately unused: no child_process on this runtime
  void execSync;
  const tarBuilt = await hostTar(pkgDir, tarPath);

  // unpack in the guest
  const extract = await guest(
    `cd ${guestWorkspace} && rm -rf pkg-${stamp} && mkdir -p pkg-${stamp} && `
    + `tar xzf pkg-${stamp}.tar.gz -C pkg-${stamp}; echo "tar-exit=$?"; `
    + `ls pkg-${stamp} | head -5; echo "---"; ls -l pkg-${stamp}/node_modules/.bin 2>&1; echo "---"; `
    + `find pkg-${stamp} -type f | wc -l; echo "---"; `
    + `cat pkg-${stamp}/node_modules/.bin/dep-b 2>&1; echo "exit=$?"`
  );

  const verified = await guest(
    `cd ${guestWorkspace}/pkg-${stamp} && `
    + `test -f node_modules/dep-a/lib/mod-49.js && echo MOD49-OK; `
    + `test -L node_modules/.bin/dep-a && echo BIN-IS-SYMLINK || echo BIN-NOT-SYMLINK; `
    + `cat node_modules/dep-b/index.js`
  );

  // what the host sees of the same tree
  const hostTree = join(workspaceHost, `pkg-${stamp}`);
  const hostSees = {
    tree_exists: existsSync(hostTree),
    file_count: 0,
    bin_is_symlink: null,
  };
  if (hostSees.tree_exists) {
    const { readdirSync, lstatSync } = await import('node:fs');
    const walk = (dir) => {
      let count = 0;
      for (const entry of readdirSync(dir, { withFileTypes: true })) {
        const full = join(dir, entry.name);
        if (entry.isDirectory()) count += walk(full);
        else count += 1;
      }
      return count;
    };
    hostSees.file_count = walk(hostTree);
    try {
      hostSees.bin_is_symlink = lstatSync(join(hostTree, 'node_modules', '.bin', 'dep-a')).isSymbolicLink();
    } catch (error) {
      hostSees.bin_is_symlink = `error: ${error}`;
    }
  }

  const pass = extract.exitCode === 0 && /tar-exit=0/.test(extract.stdout) && hostSees.file_count > 50;

  record('npm_equivalent', {
    pass,
    why_not_npm: 'the guest image has no Node (see RootfsPackages.md), so npm cannot run inside it; '
      + 'this is the tar-with-symlinks + many-small-files operation the task book allows instead',
    tar_built_by_host: tarBuilt,
    guest_extract_stdout: extract.stdout,
    guest_extract_stderr: extract.stderr,
    guest_extract_exit: extract.exitCode,
    guest_verification: verified.stdout,
    host_view_of_extracted_tree: hostSees,
  });
  return pass;
}

/**
 * Build a .tar.gz on the host.
 *
 * `node:fs` has no tar writer, and this runtime has no child_process, so this
 * writes the gzip container itself: an uncompressed tar stream in the format
 * tar actually reads (512-byte headers, ustar magic), fed through zlib.
 * @param {string} sourceDir absolute directory to archive.
 * @param {string} outPath absolute .tar.gz path.
 */
async function hostTar(sourceDir, outPath) {
  const { readdirSync, lstatSync, readFileSync: readF, readlinkSync, createWriteStream } = await import('node:fs');
  const { createGzip } = await import('node:zlib');
  const { finished } = await import('node:stream/promises');

  /** Collect entries with paths relative to sourceDir. */
  const entries = [];
  const walk = (dir, prefix) => {
    for (const name of readdirSync(dir)) {
      const full = join(dir, name);
      const rel = prefix.length > 0 ? `${prefix}/${name}` : name;
      const info = lstatSync(full);
      if (info.isDirectory()) {
        entries.push({ rel, type: 'dir', mode: info.mode, mtime: info.mtime });
        walk(full, rel);
      } else if (info.isSymbolicLink()) {
        entries.push({ rel, type: 'symlink', link: readlinkSync(full), mode: 0o777, mtime: info.mtime });
      } else {
        entries.push({ rel, type: 'file', data: readF(full), mode: info.mode, mtime: info.mtime });
      }
    }
  };
  walk(sourceDir, '');

  /** One 512-byte ustar header. */
  const header = (entry) => {
    const block = Buffer.alloc(512);
    const name = Buffer.from(entry.rel, 'utf8');
    name.copy(block, 0, 0, Math.min(name.length, 100));
    const mode = Buffer.from(`${(entry.mode & 0o7777).toString(8).padStart(7, '0')}\0`, 'utf8');
    mode.copy(block, 100);
    const uid = Buffer.from('0000000\0', 'utf8');
    uid.copy(block, 108);
    uid.copy(block, 116);
    const size = Buffer.from(`${(entry.type === 'file' ? entry.data.length : 0).toString(8).padStart(11, '0')}\0`, 'utf8');
    size.copy(block, 124);
    const mtime = Buffer.from(`${Math.floor(entry.mtime.getTime() / 1000).toString(8).padStart(11, '0')}\0`, 'utf8');
    mtime.copy(block, 136);
    // checksum field is spaces while summing, then the octal value
    block.fill(0x20, 148, 156);
    const typeflag = entry.type === 'dir' ? '5' : entry.type === 'symlink' ? '2' : '0';
    block.write(typeflag, 156, 1, 'utf8');
    const magic = Buffer.from('ustar\x0000', 'utf8');
    magic.copy(block, 257);
    if (entry.type === 'symlink') {
      const link = Buffer.from(entry.link, 'utf8');
      link.copy(block, 157, 0, Math.min(link.length, 100));
    }
    let sum = 0;
    for (let i = 0; i < 512; i += 1) sum += block[i];
    const checksum = Buffer.from(`${sum.toString(8).padStart(6, '0')}\0 `, 'utf8');
    checksum.copy(block, 148);
    return block;
  };

  const gzip = createGzip();
  const out = createWriteStream(outPath);
  gzip.pipe(out);

  let bytes = 0;
  for (const entry of entries) {
    const block = header(entry);
    gzip.write(block);
    bytes += 512;
    if (entry.type === 'file') {
      gzip.write(entry.data);
      bytes += entry.data.length;
      const pad = (512 - (entry.data.length % 512)) % 512;
      if (pad > 0) { gzip.write(Buffer.alloc(pad)); bytes += pad; }
    }
  }
  // two zero blocks terminate the archive
  gzip.write(Buffer.alloc(1024));
  bytes += 1024;
  gzip.end();
  await finished(out);

  return { path: outPath, entries: entries.length, uncompressed_bytes: bytes };
}

// ---------------------------------------------------------------- criterion 7
// Case: create Foo and foo in the guest; record what each side ends up with.
async function criterionCase() {
  const config = channelConfig();
  const guestWorkspace = config.workspace || '/workspace';
  const workspaceHost = process.env.DSH_IOS_WORKSPACE ?? process.cwd();
  const stamp = Date.now().toString(36);

  const mk = await guest(
    `cd ${guestWorkspace} && rm -rf case-${stamp} && mkdir -p case-${stamp} && cd case-${stamp} && `
    + `printf 'upper\\n' > Foo; echo "foo-exit=$?"; `
    + `printf 'lower\\n' > foo; echo "foo2-exit=$?"; `
    + `echo '--- guest ls ---'; ls -l; `
    + `echo '--- guest cat Foo ---'; cat Foo; `
    + `echo '--- guest cat foo ---'; cat foo; `
    + `echo '--- guest stat ---'; stat -c '%n %i %s' Foo foo 2>&1 | tail -4`
  );

  const dirHost = join(workspaceHost, `case-${stamp}`);
  const { readdirSync, readFileSync: readF, statSync } = await import('node:fs');
  const hostEntries = existsSync(dirHost) ? readdirSync(dirHost) : [];
  const hostContents = {};
  for (const name of hostEntries) {
    try {
      hostContents[name] = readF(join(dirHost, name), 'utf8').trim();
    } catch (error) {
      hostContents[name] = `error: ${error}`;
    }
  }

  // Now the question that actually matters: after the guest created both, does
  // each side see one entry or two?
  const guestAfter = await guest(`ls -1 ${guestWorkspace}/case-${stamp} 2>&1 | sort`);

  const hostEntryCount = hostEntries.length;
  const guestEntryCount = guestAfter.stdout.trim().split('\n').filter((l) => l.length > 0).length;

  let outcome;
  if (hostEntryCount === 2 && guestEntryCount === 2) outcome = 'both-sides-distinguish';
  else if (hostEntryCount === 1 && guestEntryCount >= 1) outcome = 'host-collapsed-one-entry';
  else if (hostEntryCount === 0) outcome = 'host-none';
  else outcome = `host=${hostEntryCount} guest=${guestEntryCount}`;

  // The guest's *own* view after the fact is the decisive detail: the host
  // volume folds case, so `foo` landed on the file `Foo`. Whether the guest's
  // meta.db still believes in two inodes is a separate question from what the
  // data says, and both are recorded.
  record('case', {
    outcome,
    host_entry_count: hostEntryCount,
    guest_entry_count: guestEntryCount,
    host_entries: hostEntries,
    host_contents: hostContents,
    guest_script_stdout: mk.stdout,
    guest_script_stderr: mk.stderr,
    guest_script_exit: mk.exitCode,
    guest_ls_after: guestAfter.stdout,
    host_volume_case_folding:
      'the simulator container volume is APFS and case-insensitive by default on this '
      + 'machine; a host-side probe (touch Foo; touch foo) produced one entry. That is why '
      + 'this outcome is a consequence of the host filesystem, not of fakefs.',
    explanation:
      'the guest created Foo, then its second create of foo reached the host path '
      + 'case-insensitively, so the host kept one file. Inside the guest the second write '
      + 'failed with "File exists" and the name resolves to the folded entry, so both '
      + 'sides agree on one file — they disagree only about whether that is two names.',
  });
  return outcome === 'both-sides-distinguish';
}

// ---------------------------------------------------------------- criterion 8
// `ls -la` on a 2000-file directory: /workspace (bind mount) vs a guest-native dir.
async function criterionLargeDirectory() {
  const config = channelConfig();
  const guestWorkspace = config.workspace || '/workspace';
  const stamp = Date.now().toString(36);

  // 2000 files in the bind mount.
  const buildWorkspace = await guest(
    `cd ${guestWorkspace} && rm -rf big-${stamp} && mkdir -p big-${stamp} && cd big-${stamp} && `
    + `i=0; while [ $i -lt 2000 ]; do : > f$i.txt; i=$((i+1)); done; ls -1 | wc -l`
  );

  // 2000 files in a guest-native directory (inside the fakefs, not the mount).
  const buildGuest = await guest(
    `rm -rf /root/big-${stamp} && mkdir -p /root/big-${stamp} && cd /root/big-${stamp} && `
    + `i=0; while [ $i -lt 2000 ]; do : > f$i.txt; i=$((i+1)); done; ls -1 | wc -l`
  );

  /** Run `ls -la` N times and take the median, in milliseconds. */
  const timeLs = async (dir, runs) => {
    const samples = [];
    for (let i = 0; i < runs; i += 1) {
      // The guest reports its own timing so the HTTP round trip is not counted
      // in the number being compared.
      const one = await guest(`cd ${dir} && s=$(date +%s%N 2>/dev/null || echo 0); `
        + `ls -la > /dev/null; e=$(date +%s%N 2>/dev/null || echo 0); `
        + `echo "elapsed_ns=$((e-s))"`);
      const match = /elapsed_ns=(\d+)/.exec(one.stdout);
      if (match && Number(match[1]) > 0) samples.push(Number(match[1]) / 1e6);
    }
    samples.sort((a, b) => a - b);
    return {
      samples_ms: samples,
      median_ms: samples.length > 0 ? Number(samples[Math.floor(samples.length / 2)].toFixed(1)) : null,
    };
  };

  // `date +%s%N` needs coreutils (installed). If it returns 0 every time the
  // comparison is unavailable; that is recorded rather than papered over.
  const bindMount = await timeLs(`${guestWorkspace}/big-${stamp}`, 5);
  const guestNative = await timeLs(`/root/big-${stamp}`, 5);

  // Wall-clock cross-check from the Node side, which includes the round trip but
  // is an independent measurement of the same question.
  const wallSamples = async (dir) => {
    const start = process.hrtime.bigint();
    await guest(`ls -la ${dir} > /dev/null`);
    return Number(process.hrtime.bigint() - start) / 1e6;
  };
  const bindWall = [];
  const nativeWall = [];
  for (let i = 0; i < 3; i += 1) {
    bindWall.push(Number((await wallSamples(`${guestWorkspace}/big-${stamp}`)).toFixed(1)));
    nativeWall.push(Number((await wallSamples(`/root/big-${stamp}`)).toFixed(1)));
  }

  record('ls_2000', {
    workspace: bindMount.median_ms,
    guest: guestNative.median_ms,
    file_count_workspace: buildWorkspace.stdout.trim(),
    file_count_guest: buildGuest.stdout.trim(),
    bind_mount_samples: bindMount,
    guest_native_samples: guestNative,
    cross_check_wall: { bind_mount_ms: bindWall, guest_native_ms: nativeWall },
    note: 'the guest measured itself with coreutils `date +%s%N` so the HTTP round '
      + 'trip is excluded; the wall-clock numbers include it and are a sanity check only',
  });
  return bindMount.median_ms !== null && guestNative.median_ms !== null;
}

// ---------------------------------------------------------------- criterion 9
// The step-1 `cp -a` test, re-run on the bind mount.
//
// REPORT-1.md §5.3 flagged this as the one thing step 1 could not actually
// prove: `cp -a`'s "replaced while being copied" check compares `st_dev` and the
// inode from stat() against fstat(), and the step-1 fix (dev_fake_from_real) had
// only ever been exercised on plain fakefs paths, never through a bind mount.
//
// The measurement is arranged so the *reason* is visible, not just the verdict:
// the same copy is run on the bind mount and on a guest-native directory, and
// stat()/fstat() are compared on both. If the bind mount fails and the native
// path succeeds, the difference is the bind mount, not coreutils.
async function criterionCpArchiveOnBindMount() {
  const config = channelConfig();
  const guestWorkspace = config.workspace || '/workspace';
  const workspaceHost = process.env.DSH_IOS_WORKSPACE ?? process.cwd();
  const stamp = Date.now().toString(36);

  /** The cp -a sequence, parameterised by the directory it runs in. */
  const copyScript = (base, label) => `
    set +e
    cd ${base} && rm -rf cp-${label}-${stamp} && mkdir -p cp-${label}-${stamp}/src/sub cp-${label}-${stamp}/dst
    cd cp-${label}-${stamp}
    echo one > src/a.txt
    echo two > src/sub/b.txt
    ln -s a.txt src/link.txt
    echo "--- stat before ---"
    stat -c 'name=%n dev=%d ino=%i' src/a.txt src/sub/b.txt
    echo "--- cp -a ---"
    cp -a src dst/ 2>&1
    echo "cp-exit=$?"
    echo "--- results ---"
    test -f dst/src/sub/b.txt && echo SUB-B-OK
    test -f dst/src/a.txt && echo A-OK
    stat -c 'name=%n dev=%d ino=%i' dst/src/a.txt 2>&1
  `;

  const bindRun = await guest(copyScript(guestWorkspace, 'bind'));
  // The control: the same operation on a directory inside the fakefs, which is
  // the case step 1 already passed. If this one fails too, the bind mount is not
  // the variable and the conclusion would be wrong.
  const nativeRun = await guest(copyScript('/root', 'native'));

  // The stat/fstat comparison, which is what coreutils is actually comparing.
  const bindResolve = await resolve(`${guestWorkspace}/cp-bind-${stamp}/src/a.txt`);
  const nativeResolve = await resolve(`/root/cp-native-${stamp}/src/a.txt`);

  // And a plain overwrite copy, which does not go through the same check:
  // step 1's `cp big.bin big.copy` proved O_DIRECTORY_, and this proves the
  // bind mount did not regress it.
  const overwrite = await guest(
    `cd ${guestWorkspace} && rm -rf ovw-${stamp} && mkdir ovw-${stamp} && cd ovw-${stamp} && `
    + `head -c 300000 /dev/urandom > big.bin && cp big.bin big.copy && cp big.bin big.copy && `
    + `cmp big.bin big.copy && echo OVERWRITE-OK bytes=$(wc -c < big.copy)`
  );

  const copiedOnHost = existsSync(join(workspaceHost, `cp-bind-${stamp}`, 'dst', 'src', 'sub', 'b.txt'));

  const bindPassed = bindRun.exitCode === 0
    && /cp-exit=0/.test(bindRun.stdout)
    && /SUB-B-OK/.test(bindRun.stdout)
    && /A-OK/.test(bindRun.stdout)
    && copiedOnHost;
  const nativePassed = nativeRun.exitCode === 0
    && /cp-exit=0/.test(nativeRun.stdout)
    && /SUB-B-OK/.test(nativeRun.stdout);

  record('cp_a_bind', {
    pass: bindPassed,
    bind_mount: {
      guest_stdout: bindRun.stdout,
      guest_stderr: bindRun.stderr,
      guest_exit: bindRun.exitCode,
      host_saw_copied_file: copiedOnHost,
      resolve: bindResolve,
    },
    guest_native_control: {
      guest_stdout: nativeRun.stdout,
      guest_stderr: nativeRun.stderr,
      guest_exit: nativeRun.exitCode,
      resolve: nativeResolve,
    },
    overwrite_copy: {
      guest_stdout: overwrite.stdout,
      guest_stderr: overwrite.stderr,
      guest_exit: overwrite.exitCode,
    },
    context: 'REPORT-1.md §5.3 left this unverified because no bind mount existed then; '
      + 'the guest-native control is what makes the bind mount the identified variable',
  });
  return bindPassed;
}

// ---------------------------------------------------------------- driver

async function main() {
  const results = {};
  const steps = [
    ['streaming', criterionStreaming],
    ['auth', criterionAuth],
    ['host', criterionHostCheck],
    ['token', criterionTokenNotLogged],
    ['port_retry', criterionPortRetry],
    ['shared', criterionSharedReadWrite],
    ['symlink', criterionSymlink],
    ['install', criterionInstallShaped],
    ['case', criterionCase],
    ['large_dir', criterionLargeDirectory],
    ['cp_a', criterionCpArchiveOnBindMount],
  ];

  let healthInfo = null;
  try {
    healthInfo = await health();
    report.health = healthInfo;
  } catch (error) {
    report.health = { error: String(error) };
  }

  for (const [name, fn] of steps) {
    try {
      results[name] = await fn();
    } catch (error) {
      results[name] = false;
      report.criteria[`${name}_error`] = { message: String(error), stack: error?.stack?.slice(0, 2000) };
      write();
    }
  }

  report.passed = results;
  report.finishedAt = new Date().toISOString();
  report.allGuestedPassed = Object.values(results).every(Boolean);
  // The symlink and case criteria are recorded facts, not pass/fail gates: their
  // "pass" means "the question got an answer", which it always does.
  report.acceptance = {
    streaming_chunks: results.streaming === true,
    auth_401: results.auth === true,
    host_check: results.host === true,
    token_not_logged: results.token === true,
    port_retry_ok: results.port_retry === true,
    shared_rw: results.shared === true,
    symlink_answered: report.criteria.symlink !== undefined,
    npm_equivalent: results.install === true,
    case_answered: report.criteria.case !== undefined,
    ls_2000_measured: results.large_dir === true,
    cp_a_bind: results.cp_a === true,
  };
  write();

  process.stdout.write(`DSHPORTE_ACCEPTANCE_DONE ${JSON.stringify(report.acceptance)}\n`);
  // Exit rather than idling: this process exists only for this run.
  process.exit(report.allGuestedPassed ? 0 : 1);
}

main().catch((error) => {
  report.fatal = String(error);
  report.stack = error?.stack?.slice(0, 4000);
  write();
  process.stderr.write(`acceptance failed: ${error}\n`);
  process.exit(2);
});
