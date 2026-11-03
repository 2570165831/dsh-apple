#!/usr/bin/env node
// Host-side unit tests for the two pure path functions the guest provider owns.
//
// WHY THIS FILE EXISTS, AND WHY IT IS NOT A SUBSTITUTE FOR THE IN-APP RUN.
// `sim/step7-acceptance.mjs` proves the whole path works inside the app, which is
// the only place the answer counts. But two of its branches are unreachable there
// by construction, and asserting them from the app would be a lie:
//
//   * `respellGuestExecutable` maps a HOST path (`…/@vscode/ripgrep/bin/rg`) onto
//     the guest's `/usr/bin/rg`. After the loader hook (`sim/ripgrep-hook.mjs`)
//     the tool is *already* handed `/usr/bin/rg`, so in-app the respell is a
//     no-op. Turning it off therefore cannot make the app fail — measured, and
//     the reason this A/B switch alone proves nothing. The branch still has to be
//     right, because a payload with a real `@vscode/ripgrep` install (a desktop
//     build, or a future image that ships the binary) reaches it.
//   * `normaliseGuestPath` folds `..`/`.` for a RELATIVE workdir. The tool layer
//     joins a relative workdir onto the session cwd before the provider sees it,
//     so the in-app criterion exercises the joined form, not the raw one.
//
// So both are tested here, directly, with the paths that actually occur.
//
// Usage: node scripts/path-units.mjs   (exit 0 = all pass)

import { strict as assert } from 'node:assert';

process.env.DSH_IOS_WORKSPACE = '/var/mobile/Containers/Data/Application/ABC/Documents/workspace';
process.env.DSH_GUEST_WORKSPACE = '/workspace';

const {
  guestWorkingDirectory,
  normaliseGuestPath,
  respellGuestExecutable,
} = await import('../plugins/dsh-subprocess-ish/index.mjs');

let passed = 0;
const failures = [];

/** Run one named check; a throw is recorded, not fatal. */
function check(name, fn) {
  try {
    fn();
    passed += 1;
  } catch (error) {
    failures.push({ name, message: String(error && error.message ? error.message : error) });
  }
}

const HOST = process.env.DSH_IOS_WORKSPACE;

// --------------------------------------------------- normaliseGuestPath
check('normalise keeps an absolute path', () => {
  assert.equal(normaliseGuestPath('/workspace/a'), '/workspace/a');
});
check('normalise collapses a dot segment', () => {
  assert.equal(normaliseGuestPath('/workspace/./a'), '/workspace/a');
});
check('normalise resolves a parent segment', () => {
  assert.equal(normaliseGuestPath('/workspace/src/../lib'), '/workspace/lib');
});
check('normalise clamps .. at the root', () => {
  assert.equal(normaliseGuestPath('/../../etc'), '/etc');
});
check('normalise collapses repeated slashes', () => {
  assert.equal(normaliseGuestPath('/workspace//a///b'), '/workspace/a/b');
});
check('normalise rejects a relative path', () => {
  assert.equal(normaliseGuestPath('src/a'), undefined);
});
check('normalise rejects an empty path', () => {
  assert.equal(normaliseGuestPath(''), undefined);
});

// ------------------------------------------------ guestWorkingDirectory
check('no cwd means the workspace, not the guest root', () => {
  // The defect the phone reported: bash ran one level above the session.
  assert.equal(guestWorkingDirectory(undefined), '/workspace');
  assert.equal(guestWorkingDirectory(''), '/workspace');
});
check('a host cwd is respelled', () => {
  assert.equal(guestWorkingDirectory(HOST), '/workspace');
  assert.equal(guestWorkingDirectory(`${HOST}/src`), '/workspace/src');
});
check('a guest cwd passes through', () => {
  assert.equal(guestWorkingDirectory('/workspace/src'), '/workspace/src');
});
check('a relative cwd resolves under the workspace', () => {
  assert.equal(guestWorkingDirectory('src'), '/workspace/src');
  assert.equal(guestWorkingDirectory('src/nested'), '/workspace/src/nested');
});
check('a relative cwd may climb, and climbing past the workspace leaves it', () => {
  // `..` from `/workspace` is `/`, so `../lib` is `/lib` — a guest path that really
  // exists, outside the shared tree. That is the honest POSIX answer and it is what
  // the guest kernel would do for a shell's own `cd ../lib`; refusing to fold it
  // would mean the provider's answer disagreed with the shell's for the same input.
  assert.equal(guestWorkingDirectory('../lib'), '/lib');
  assert.equal(guestWorkingDirectory('../../../etc'), '/etc');
});
check('a guest absolute path is used as given', () => {
  // A path in neither host namespace is a guest path. It used to fall back to the
  // workspace, which ran the command somewhere the model never named; the guest's
  // own chdir now decides whether it exists.
  assert.equal(guestWorkingDirectory('/usr/share'), '/usr/share');
});

// --------------------------------------------- respellGuestExecutable
const RG = '/usr/bin/rg';
check('the packaged ripgrep path is respelled', () => {
  const packaged = '/private/var/containers/Bundle/Application/X/DSHPortC.app/payload/node_modules/@vscode/ripgrep/bin/rg';
  assert.equal(respellGuestExecutable(packaged, RG), RG);
});
check('the packaged darwin ripgrep path is respelled', () => {
  const packaged = '/x/payload/node_modules/@vscode/ripgrep-darwin-arm64/bin/rg';
  assert.equal(respellGuestExecutable(packaged, RG), RG);
});
check('a bare rg is respelled', () => {
  assert.equal(respellGuestExecutable('rg', RG), RG);
});
check('the guest rg itself is left alone', () => {
  assert.equal(respellGuestExecutable(RG, RG), RG);
});
check('grep is NOT mistaken for ripgrep', () => {
  for (const program of ['/usr/bin/grep', '/bin/grep', 'grep', '/usr/bin/egrep', '/usr/bin/rgrep']) {
    assert.equal(respellGuestExecutable(program, RG), program, `${program} must pass through`);
  }
});
check('bash and git are not touched', () => {
  for (const program of ['bash', '/bin/bash', '/usr/bin/git', 'git', '/bin/sh']) {
    assert.equal(respellGuestExecutable(program, RG), program, `${program} must pass through`);
  }
});
check('no known guest rg means no rewriting at all', () => {
  const packaged = '/x/payload/node_modules/@vscode/ripgrep/bin/rg';
  assert.equal(respellGuestExecutable(packaged, undefined), packaged);
  assert.equal(respellGuestExecutable(packaged, ''), packaged);
});
check('the A/B switch disables the respell', () => {
  const packaged = '/x/payload/node_modules/@vscode/ripgrep/bin/rg';
  process.env.DSHPORTE_RG_RESPELL = '0';
  try {
    assert.equal(respellGuestExecutable(packaged, RG), packaged);
  } finally {
    delete process.env.DSHPORTE_RG_RESPELL;
  }
});

// ------------------------------------------------------------------ verdict
const total = passed + failures.length;
process.stdout.write(`${passed}/${total} path-unit checks passed\n`);
for (const failure of failures) process.stdout.write(`  FAIL ${failure.name}: ${failure.message}\n`);
process.exit(failures.length === 0 ? 0 : 1);
