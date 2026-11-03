// The credential fence in `plugins/dsh-fs-ios`: file tools must not reach the
// DSH credential store, key files, or the app's runtime state, by any spelling.
//
// The provider is exercised through the real payload classes
// (`SandboxedFileSystem` -> `LocalFileSystem`), with only the cordis constructor
// bypassed: `Service` needs a live cordis context, and none of the methods under
// test touch it beyond `ctx.sandboxPolicy`. Everything lives in a fresh
// `mkdtemp` tree shaped like an app container; every secret is an obvious fake.

import { after, before, describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { link, mkdir, mkdtemp, realpath, rename, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO = resolve(fileURLToPath(new URL('.', import.meta.url)), '..', '..');
const FAKE_KEY = 'FAKE-KEY-for-fence-test-not-a-credential';

const { IosFileSystem } = await import(join(REPO, 'plugins', 'dsh-fs-ios', 'index.mjs'));
const fence = await import(join(REPO, 'plugins', 'dsh-fs-ios', 'lib', 'fence.mjs'));

let root;
let container;
let dshHome;
let appSupport;
let workspace;
let fs;
const savedEnv = {};
const ENV_KEYS = ['DSH_HOME', 'DSH_IOS_WORKSPACE', 'DSH_GUEST_WORKSPACE', 'DSHPORTE_BOOT_DIR', 'DSH_HOST_TMPDIR', 'DSH_GUEST_TMPDIR'];

/** A provider instance without the cordis constructor; see the header. */
function makeProvider(cwd) {
  const provider = Object.create(IosFileSystem.prototype);
  Object.assign(provider, {
    config: { cwd, diffBasisMaxBytes: 1 << 20 },
    internals: {},
    locks: new Map(),
    defaultMode: 'danger-full-access',
    ctx: { sandboxPolicy: { defaultMode: 'danger-full-access', resolve: () => ({ mode: 'danger-full-access' }) } },
  });
  return provider;
}

/** Assert that `promise` is refused by the fence, with the explicit message. */
async function assertFenced(promise, label) {
  await assert.rejects(promise, (error) => {
    assert.equal(error.code, 'FS_PERMISSION_DENIED', `${label}: code`);
    assert.match(error.message, /protected area/, `${label}: message names the rule`);
    assert.match(error.message, /受保护路径/, `${label}: Chinese explanation present`);
    assert.ok(!error.message.includes(FAKE_KEY), `${label}: secret never echoed`);
    return true;
  }, label);
}

/** Text of a read, whatever shape the provider returns it in. */
async function readTextOf(target) {
  const result = await fs.readText(target);
  return typeof result === 'string' ? result : result.content ?? result.text;
}

before(async () => {
  for (const key of ENV_KEYS) savedEnv[key] = process.env[key];
  // macOS `tmpdir()` is under `/var/folders`, whose realpath is `/private/var/...`:
  // the same two-spelling situation as a device container.
  root = await mkdtemp(join(tmpdir(), 'fs-fence-'));
  container = join(root, 'Data', 'Application', 'UUID-TEST');
  dshHome = join(container, 'Library', 'Application Support', 'DSH');
  appSupport = join(container, 'Library', 'Application Support', 'DSHPortC');
  workspace = join(container, 'Documents', 'workspace');
  await mkdir(join(dshHome, 'storages', 'workspace'), { recursive: true });
  await mkdir(join(dshHome, 'profiles', 'ios-sim'), { recursive: true });
  await mkdir(join(appSupport, 'boot'), { recursive: true });
  await mkdir(workspace, { recursive: true });
  await writeFile(join(dshHome, '.credentials.yaml'), `refs:\n  deepseek: ${FAKE_KEY}\n`);
  await writeFile(join(dshHome, '.credentials.yaml.lock'), 'lock');
  await writeFile(join(dshHome, '.env'), `DEEPSEEK_API_KEY=${FAKE_KEY}\n`);
  await writeFile(join(dshHome, 'storages', 'workspace', 'registry.json'), '{"apiKey":"FAKE"}');
  await writeFile(join(dshHome, 'profiles', 'ios-sim', 'cordis.yml'), 'plugins: []\n');
  await writeFile(join(dshHome, 'AGENTS.md'), '# not fenced\n');
  await writeFile(join(appSupport, 'DSHPortC-session-url.txt'), `http://127.0.0.1:1/?token=${FAKE_KEY}\n`);
  await writeFile(join(appSupport, 'DSHPortC-status.json'), '{}');
  await writeFile(join(appSupport, 'reset-request.json'), '{}');
  await writeFile(join(appSupport, 'boot', 'boot-guard.json'), '{}');
  await writeFile(join(workspace, 'hello.txt'), 'hello workspace\n');
  // The bypass fixtures a guest shell could plant in the shared workspace.
  await symlink(join(dshHome, '.credentials.yaml'), join(workspace, 'creds-link'));
  await symlink(dshHome, join(workspace, 'home-link'));
  await symlink(appSupport, join(workspace, 'state-link'));
  await link(join(dshHome, '.credentials.yaml'), join(workspace, 'creds-hardlink'));

  process.env.DSH_HOME = dshHome;
  process.env.DSH_IOS_WORKSPACE = workspace;
  process.env.DSH_GUEST_WORKSPACE = '/workspace';
  process.env.DSHPORTE_BOOT_DIR = join(appSupport, 'boot');
  delete process.env.DSH_HOST_TMPDIR;
  delete process.env.DSH_GUEST_TMPDIR;
  fs = makeProvider(workspace);
});

after(async () => {
  for (const key of ENV_KEYS) {
    if (savedEnv[key] === undefined) delete process.env[key];
    else process.env[key] = savedEnv[key];
  }
  if (root) await rm(root, { recursive: true, force: true });
});

describe('direct access to credential files', () => {
  test('reading .credentials.yaml by its host path is refused', async () => {
    await assertFenced(fs.resolve(join(dshHome, '.credentials.yaml')), 'resolve');
  });

  test('a different letter case is refused the same way (APFS is case-insensitive)', async () => {
    await assertFenced(fs.resolve(join(dshHome, '.CREDENTIALS.YAML')), 'upper-case name');
    await assertFenced(fs.resolve(join(container, 'Library', 'APPLICATION SUPPORT', 'dsh', '.Credentials.yaml')), 'upper-case dirs');
  });

  test('the store\'s lock/temp siblings, .env and storages/ are refused', async () => {
    await assertFenced(fs.resolve(join(dshHome, '.credentials.yaml.lock')), 'lock sibling');
    await assertFenced(fs.resolve(join(dshHome, '.credentials.yaml.0a1b2c.tmp')), 'missing temp sibling');
    await assertFenced(fs.resolve(join(dshHome, '.env')), '.env');
    await assertFenced(fs.resolve(join(dshHome, 'storages', 'workspace', 'registry.json')), 'storages file');
    await assertFenced(fs.resolve(join(dshHome, 'storages')), 'storages dir');
  });

  test('lstat cannot probe a credential file for existence', async () => {
    await assertFenced(fs.lstat(join(dshHome, '.credentials.yaml'), {}, undefined), 'lstat');
  });

  test('read_image\'s byte read and a write are refused too', async () => {
    const forged = { targetKey: join(dshHome, '.credentials.yaml'), displayPath: join(dshHome, '.credentials.yaml') };
    await assertFenced(fs.readBytes(forged, undefined, 1024), 'readBytes on a forged target');
    await assertFenced(fs.readText(forged), 'readText on a forged target');
    await assertFenced(fs.writeText(forged, 'x', undefined, undefined, undefined), 'writeText on a forged target');
  });
});

describe('bypass attempts', () => {
  test('.. from the guest spelling of the workspace is refused', async () => {
    await assertFenced(
      fs.resolve('/workspace/../../Library/Application Support/DSH/.credentials.yaml'),
      'guest ..',
    );
  });

  test('.. from the host spelling, relative to cwd, is refused', async () => {
    await assertFenced(fs.resolve(join(workspace, '..', '..', 'Library', 'Application Support', 'DSH', '.env')), 'host ..');
    await assertFenced(fs.resolve('../../Library/Application Support/DSH/.credentials.yaml'), 'relative ..');
  });

  test('a symlink to the credential file is refused on resolve and on lstat', async () => {
    await assertFenced(fs.resolve('/workspace/creds-link'), 'symlink resolve');
    await assertFenced(fs.lstat('/workspace/creds-link', {}, undefined), 'symlink lstat');
  });

  test('a symlink to DSH_HOME cannot reach the store through it', async () => {
    await assertFenced(fs.resolve('/workspace/home-link/.credentials.yaml'), 'dir symlink');
    await assertFenced(fs.resolve('/workspace/home-link/storages/workspace/registry.json'), 'dir symlink storages');
  });

  test('a hard link to the credential file is refused by identity', async () => {
    await assertFenced(fs.resolve('/workspace/creds-hardlink'), 'hard link');
  });

  test('a target re-pointed after resolve is refused at read time', async () => {
    const swap = join(workspace, 'swap-link');
    await writeFile(join(workspace, 'innocent.txt'), 'innocent\n');
    await symlink(join(workspace, 'innocent.txt'), swap);
    const target = await fs.resolve(swap);
    assert.equal(await readTextOf(target), 'innocent\n');
    // The model-controlled guest swaps the link between two tool calls.
    await rm(swap);
    await symlink(join(dshHome, '.credentials.yaml'), `${swap}.new`);
    await rename(`${swap}.new`, swap);
    // A target whose key is the link path itself (what a listing hands back).
    const stale = { targetKey: swap, displayPath: swap };
    await assertFenced(fs.readText(stale), 're-pointed link');
    await rm(swap);
  });
});

describe('listings', () => {
  test('listing DSH_HOME shows ordinary entries but no credential, key or state entries', async () => {
    const entries = await fs.listDir(await fs.resolve(dshHome));
    const names = entries.map((entry) => entry.name);
    assert.ok(names.includes('profiles'), `profiles listed: ${names}`);
    assert.ok(names.includes('AGENTS.md'), `AGENTS.md listed: ${names}`);
    for (const hidden of ['.credentials.yaml', '.credentials.yaml.lock', '.env', 'storages']) {
      assert.ok(!names.includes(hidden), `${hidden} must not be listed: ${names}`);
    }
  });

  test('listing DSH_HOME through a workspace symlink hides the same entries', async () => {
    const names = (await fs.listDir(await fs.resolve('/workspace/home-link'))).map((entry) => entry.name);
    assert.ok(names.includes('profiles'));
    assert.ok(!names.includes('.credentials.yaml'));
    assert.ok(!names.includes('.env'));
  });

  test('listing the workspace hides links that point into the fence, and keeps real files', async () => {
    const names = (await fs.listDir(await fs.resolve('/workspace'))).map((entry) => entry.name);
    assert.ok(names.includes('hello.txt'), `hello.txt listed: ${names}`);
    assert.ok(names.includes('home-link'), 'a link to DSH_HOME itself is not a secret');
    for (const hidden of ['creds-link', 'creds-hardlink', 'state-link']) {
      assert.ok(!names.includes(hidden), `${hidden} must not be listed: ${names}`);
    }
  });

  test('listing Application Support hides the app\'s own directory', async () => {
    const names = (await fs.listDir(await fs.resolve(join(container, 'Library', 'Application Support')))).map((e) => e.name);
    assert.ok(names.includes('DSH'));
    assert.ok(!names.includes('DSHPortC'), `DSHPortC must not be listed: ${names}`);
  });
});

describe('app runtime state', () => {
  test('boot-guard, reset request, session URL and the directory itself are refused', async () => {
    await assertFenced(fs.resolve(join(appSupport, 'boot', 'boot-guard.json')), 'boot-guard');
    await assertFenced(fs.resolve(join(appSupport, 'reset-request.json')), 'reset-request');
    await assertFenced(fs.resolve(join(appSupport, 'DSHPortC-session-url.txt')), 'session url');
    await assertFenced(fs.resolve(appSupport), 'support dir');
    await assertFenced(fs.resolve('/workspace/state-link/boot/boot-guard.json'), 'via symlink');
  });

  test('a new file cannot be planted in boot/ to steer the next launch', async () => {
    await assertFenced(fs.resolve(join(appSupport, 'boot', 'boot-request.json')), 'new boot-request');
  });
});

describe('normal workspace use is unaffected', () => {
  test('a workspace file reads through both spellings', async () => {
    assert.equal(await readTextOf(await fs.resolve('/workspace/hello.txt')), 'hello workspace\n');
    assert.equal(await readTextOf(await fs.resolve(join(workspace, 'hello.txt'))), 'hello workspace\n');
    assert.equal(await readTextOf(await fs.resolve('hello.txt')), 'hello workspace\n');
    const facts = await fs.lstat('/workspace/hello.txt', {}, undefined);
    assert.equal(facts.type, 'file');
    const bytes = await fs.readBytes(await fs.resolve('/workspace/hello.txt'), undefined, 1024);
    assert.ok(bytes.byteLength > 0 || bytes.data?.byteLength > 0);
  });

  test('a workspace file can be created and read back', async () => {
    const target = await fs.resolve('/workspace/sub/new.txt');
    await mkdir(join(workspace, 'sub'), { recursive: true });
    await fs.writeText(target, 'created\n', undefined, undefined, undefined);
    assert.equal(await readTextOf(await fs.resolve('/workspace/sub/new.txt')), 'created\n');
  });

  test('lstat of a missing workspace path still answers undefined', async () => {
    assert.equal(await fs.lstat('/workspace/does-not-exist.txt', {}, undefined), undefined);
  });

  test('ordinary DSH_HOME files outside the fence stay readable', async () => {
    assert.equal(await readTextOf(await fs.resolve(join(dshHome, 'AGENTS.md'))), '# not fenced\n');
    assert.equal(await readTextOf(await fs.resolve(join(dshHome, 'profiles', 'ios-sim', 'cordis.yml'))), 'plugins: []\n');
  });
});

describe('fence module', () => {
  test('without DSH_HOME there is nothing to fence', async () => {
    const fenced = await fence.createFenceChecker({});
    assert.equal(await fenced(join(dshHome, '.credentials.yaml')), false);
  });

  test('canonicalPath realpaths the existing ancestor and keeps the missing suffix', async () => {
    const real = await realpath(workspace);
    assert.equal(await fence.canonicalPath(join(workspace, 'missing', 'x.txt')), join(real, 'missing', 'x.txt'));
    assert.equal(await fence.canonicalPath(join(workspace, 'home-link', '.env')), join(await realpath(dshHome), '.env'));
  });

  test('comparable folds case, NFC and a trailing separator', () => {
    assert.equal(fence.comparable('/A/Café/'), '/a/café');
  });

  test('a name that merely starts like the store, elsewhere, is not fenced', async () => {
    const fenced = await fence.createFenceChecker({ DSH_HOME: dshHome });
    assert.equal(await fenced(join(workspace, '.credentials.yaml')), false);
    assert.equal(await fenced(join(dshHome, 'credentials.yaml')), false);
    assert.equal(await fenced(join(dshHome, 'storages-not')), false);
  });
});
