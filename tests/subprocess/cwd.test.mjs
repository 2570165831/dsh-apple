import { test } from 'node:test';
import { strict as assert } from 'node:assert';

const HOST = '/var/mobile/Containers/Data/Application/ABC/Documents/workspace';
const HOST_TMP = '/private/var/mobile/Containers/Data/Application/ABC/tmp';
process.env.DSH_IOS_WORKSPACE = HOST;
process.env.DSH_GUEST_WORKSPACE = '/workspace';
process.env.DSH_HOST_TMPDIR = `${HOST_TMP}/`;
process.env.DSH_GUEST_TMPDIR = '/tmp';

const { guestWorkingDirectory: g } = await import(
  '../../plugins/dsh-subprocess-ish/index.mjs'
);

test('no cwd -> default workspace', () => {
  assert.equal(g(undefined), '/workspace');
  assert.equal(g(null), '/workspace');
  assert.equal(g(''), '/workspace');
});

test('mapped host paths are respelled', () => {
  assert.equal(g(HOST), '/workspace');
  assert.equal(g(`${HOST}/src`), '/workspace/src');
  assert.equal(g(`${HOST}/`), '/workspace');
  assert.equal(g(HOST_TMP), '/tmp');
  assert.equal(g(`${HOST_TMP}/snap`), '/tmp/snap');
});

test('guest absolute paths pass through, not swapped for /workspace', () => {
  assert.equal(g('/tmp'), '/tmp');
  assert.equal(g('/root'), '/root');
  assert.equal(g('/usr/share'), '/usr/share');
  assert.equal(g('/workspace/src'), '/workspace/src');
  assert.equal(g('/tmp/../root/./x'), '/root/x');
  assert.equal(g('/'), '/');
});

test('relative paths resolve under the workspace', () => {
  assert.equal(g('src'), '/workspace/src');
  assert.equal(g('./a/../b'), '/workspace/b');
});

test('unmounted host paths are refused', () => {
  for (const bad of [
    '/var/mobile/Containers/Data/Application/ABC/Documents',
    '/var/mobile/Containers/Data/Application/ABC/Documents/other',
    '/var/mobile/Containers/Data/Application/ABC/Library',
    '/private/var/somewhere',
    '/Users/someone/project',
    '/var/mobile/Containers/Data/Application/XYZ/Documents/workspace',
    `${HOST}2`,
  ]) {
    assert.throws(() => g(bad), /host path outside[\s\S]*not run/, bad);
  }
});

test('malformed cwd is refused', () => {
  assert.throws(() => g(42), /must be a string/);
  assert.throws(() => g('/tmp\0x'), /NUL/);
});

test('without a temp mapping, host temp is refused rather than mapped', () => {
  const saved = process.env.DSH_GUEST_TMPDIR;
  delete process.env.DSH_GUEST_TMPDIR;
  try {
    assert.throws(() => g(HOST_TMP), /not run/);
    assert.equal(g('/tmp'), '/tmp');
  } finally {
    process.env.DSH_GUEST_TMPDIR = saved;
  }
});
