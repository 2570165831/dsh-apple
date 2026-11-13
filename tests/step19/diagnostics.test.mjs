// Tests for sim/diagnostics.mjs.
//
// Two things matter here and both are tested against a bundle that really is
// written: that nothing forbidden ends up in it, and that the secrets planted in
// the files it does read are gone from the output. A redaction test that only
// checks "the call returned" would pass with no rules at all.

import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import {
  mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import {
  DEFAULT_LIMITS, FORBIDDEN_NAMES, collect, exportOnce, isForbiddenPath, materialize,
  pruneExports, redactText, renderBundleText, safeResolve, snapshot, sourceList,
} from '../../sim/diagnostics.mjs';
import { REDACTION_CASES } from './diagnostics-fixtures.mjs';

let base;

before(() => {
  base = mkdtempSync(join(tmpdir(), 'dsh19-diag-'));
});

after(() => {
  rmSync(base, { recursive: true, force: true });
});

/** A secret planted in every forbidden location, so a leak is unmissable. */
const SECRETS = {
  credentials: 'CREDENTIAL-SECRET-9f3a',
  sessions: 'CONVERSATION-SECRET-1b2c',
  storages: 'STORED-PATH-SECRET-4d5e',
  attachments: 'ATTACHMENT-SECRET-7a8b',
  sessionUrl: 'LIVE-TOKEN-SECRET-0c1d',
  agents: 'PERSONAL-INSTRUCTION-SECRET-2e3f',
  events: 'EVENT-STREAM-SECRET-5a6b',
};

const LOG = [
  'dshportc: boot pipeline started',
  'node| dsh web: http://127.0.0.1:5555/?token=TOKEN-VALUE-abcdef123456',
  'node| Authorization: Bearer BEARER-VALUE-zyx987',
  'node| Cookie: dsh-auth=COOKIE-VALUE-qwerty',
  'node| client sent apikey sk-SECRETKEY-abcdefghijklmnop',
  'node| github ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345',
  'node| jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U',
  'node| dshportc: FAILED missing bundle resource: sim/ios-app-entry.mjs',
  '',
].join('\n');

function fixture({ containerId = 'DEADBEEF-1111-2222-3333-444455556666' } = {}) {
  const root = mkdtempSync(join(base, 'case-'));
  const appSupport = join(root, 'Library Application Support', 'DSHPortC');
  const dshHome = join(root, 'Library Application Support', 'DSH');
  const boot = join(appSupport, 'boot');
  const documents = join(root, 'Documents');
  mkdirSync(boot, { recursive: true });
  mkdirSync(join(dshHome, 'profiles', 'ios-sim', 'node_modules', 'dsh-ios-profile'), { recursive: true });
  mkdirSync(join(dshHome, 'sessions', 'proj', 'session-1'), { recursive: true });
  mkdirSync(join(dshHome, 'sessions-quarantine', 'stamp'), { recursive: true });
  mkdirSync(join(dshHome, 'attachments'), { recursive: true });
  mkdirSync(join(dshHome, 'storages'), { recursive: true });
  mkdirSync(join(documents, 'workspace'), { recursive: true });

  writeFileSync(join(appSupport, 'DSHPortC-node.log'), LOG);
  writeFileSync(join(appSupport, 'DSHPortC-status.json'), JSON.stringify({ phase: 'failed', error: 'missing resource' }));
  writeFileSync(join(appSupport, 'DSHPortC-session-url.txt'), SECRETS.sessionUrl);
  writeFileSync(join(boot, 'boot-guard.json'), JSON.stringify({ version: 1, failures: 2, attempt: { id: 'L3' } }));
  writeFileSync(join(boot, 'boot-outcome.json'), JSON.stringify({ launchId: 'L3', kind: 'failure' }));
  writeFileSync(join(boot, 'boot-background.txt'), 'L3\n');
  writeFileSync(join(boot, 'boot-request.json'), JSON.stringify({ action: 'exit-safe-mode' }));
  writeFileSync(join(boot, 'safe-mode.patch.yml'), '- id: attachment-ios\n  disabled: true\n');
  writeFileSync(join(dshHome, '.credentials.yaml'), `apiKey: ${SECRETS.credentials}\n`);
  writeFileSync(join(dshHome, 'AGENTS.md'), `${SECRETS.agents}\n`);
  writeFileSync(join(dshHome, 'events.jsonl'), `${SECRETS.events}\n`);
  writeFileSync(join(dshHome, 'sessions', 'proj', 'session-1', 'session.v1.jsonl.zstd'), SECRETS.sessions);
  writeFileSync(join(dshHome, 'sessions-quarantine', 'stamp', 'log.zst'), SECRETS.sessions);
  writeFileSync(join(dshHome, 'storages', 'workspace.json'), `{"path":"${SECRETS.storages}"}`);
  writeFileSync(join(dshHome, 'attachments', 'a.bin'), SECRETS.attachments);
  writeFileSync(join(documents, 'workspace', 'notes.txt'), 'user file\n');
  writeFileSync(join(dshHome, 'profiles', 'ios-sim', 'package.json'), '{"name":"ios-sim"}\n');
  writeFileSync(join(dshHome, 'profiles', 'ios-sim', 'cordis.yml'), '[]\n');
  writeFileSync(join(dshHome, 'profiles', 'ios-sim', 'cordis.patch.yml'), '- id: x\n');
  writeFileSync(
    join(dshHome, 'profiles', 'ios-sim', 'node_modules', 'dsh-ios-profile', 'cordis.patch.yml'),
    `# rendered for /var/mobile/Containers/Data/Application/${containerId}/Documents/workspace\n`,
  );
  return { root, appSupport, dshHome, boot, documents };
}

function roots(fixtureTree) {
  return {
    appSupport: fixtureTree.appSupport,
    dshHome: fixtureTree.dshHome,
    boot: fixtureTree.boot,
    documents: fixtureTree.documents,
  };
}

test('the bundle collects the fixed list and nothing else', () => {
  const tree = fixture();
  const report = collect({ roots: roots(tree), now: '2026-11-02T00:00:00.000Z' });
  const ids = report.files.map((file) => file.id);
  assert.deepEqual(ids, sourceList().filter((source) => source.id !== 'reset-preview').map((source) => source.id));
  assert.equal(report.totals.redactions['authorization-header'], 1);
  assert.equal(report.totals.redactions['cookie-header'], 1);
  assert.equal(report.absent.length, 1, 'reset-plan.json was not created');
});

test('nothing forbidden reaches the bundle, in any form', () => {
  const tree = fixture();
  const report = collect({ roots: roots(tree), now: '2026-11-02T00:00:00.000Z' });
  const summary = renderBundleText(report);
  const everything = summary + report.files.map((file) => file.content ?? '').join('\n');
  for (const [name, secret] of Object.entries(SECRETS)) {
    assert.equal(everything.includes(secret), false, `${name} must not be in the bundle`);
  }
  // The excluded list explains itself instead.
  const paths = report.excluded.map((entry) => entry.path).join('\n');
  assert.match(paths, /dshHome\/\.credentials\.yaml/);
  assert.match(paths, /dshHome\/sessions\b/);
  assert.match(paths, /dshHome\/storages\b/);
  assert.match(paths, /appSupport\/DSHPortC-session-url\.txt/);
  assert.match(paths, /documents\/workspace/);
});

test('secrets inside the files that ARE read are redacted', () => {
  const tree = fixture();
  const report = collect({ roots: roots(tree), now: '2026-11-02T00:00:00.000Z' });
  const log = report.files.find((file) => file.id === 'app-log');
  assert.ok(log.content.includes('dshportc: boot pipeline started'), 'the useful lines survive');
  assert.ok(log.content.includes('FAILED missing bundle resource'), 'the failure line survives');
  for (const leaked of [
    'TOKEN-VALUE-abcdef123456',
    'BEARER-VALUE-zyx987',
    'COOKIE-VALUE-qwerty',
    'sk-SECRETKEY-abcdefghijklmnop',
    'ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345',
    'eyJhbGciOiJIUzI1NiJ9',
  ]) {
    assert.equal(log.content.includes(leaked), false, `${leaked} must be redacted`);
  }
  assert.ok(log.content.includes('token=<redacted>'));
  assert.ok(log.content.includes('sk-<redacted>'));
  assert.ok(log.redactions['token-parameter'] >= 1);
});

test('redactText covers each rule independently', () => {
  const cases = [
    ['https://x.test/?token=abc123', 'abc123', 'token-parameter'],
    ['Authorization: Basic dXNlcjpwYXNz', 'dXNlcjpwYXNz', 'authorization-header'],
    ['Set-Cookie: session=deadbeef', 'deadbeef', 'cookie-header'],
    ['key sk-proj-AAAAbbbbCCCC1234', 'AAAAbbbbCCCC1234', 'sk-key'],
    ['xoxb-1234567890-abcdefghij', '1234567890-abcdefghij', 'provider-key'],
    ['before eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.signaturepart after', 'eyJhbGciOiJIUzI1NiJ9', 'jwt'],
    ['dsh-auth-9f8e7d6c5b4a', '9f8e7d6c5b4a', 'dsh-auth-cookie'],
    ['password=hunter2', 'hunter2', 'token-parameter'],
    ['-----BEGIN RSA PRIVATE KEY-----\nMIIabc\n-----END RSA PRIVATE KEY-----', 'MIIabc', 'private-key-block'],
  ];
  for (const [input, secret, rule] of cases) {
    const result = redactText(input);
    assert.equal(result.text.includes(secret), false, `${rule} leaked ${secret}`);
    assert.ok(result.counts[rule] >= 1, `${rule} did not fire`);
  }
});

test('redactText leaves ordinary text alone', () => {
  const text = 'dshportc: webview ready after 5.21s';
  assert.deepEqual(redactText(text), { text, counts: {} });
});

// A fake key, obviously not real, planted in every config shape the bundle reads.
const FAKE_KEY = 'sk-FAKE-1234567890abcdef';
const FAKE_PLAIN = 'PLAINFAKE0987654321zz';

test('redactText covers YAML key: value forms, any case, quoted or not', () => {
  for (const key of [
    'apiKey', 'api_key', 'API_KEY', 'api-key', 'ApiKey', 'token', 'Token', 'access_token', 'accessToken',
    'secret', 'client_secret', 'clientSecret', 'password', 'Password', 'passwd', 'authorization',
    'Authorization', 'openaiApiKey', 'DEEPSEEK_API_KEY', 'private_key', 'auth_token', 'refreshToken',
  ]) {
    for (const value of [FAKE_PLAIN, `"${FAKE_PLAIN}"`, `'${FAKE_PLAIN}'`]) {
      for (const line of [
        `${key}: ${value}`,
        `  ${key}: ${value}`,
        `- ${key}: ${value}`,
        `node| ${key}: ${value}`,
        `"${key}": ${value}`,
      ]) {
        const result = redactText(`id: provider\n${line}\nmodel: deepseek-chat\n`);
        assert.equal(result.text.includes(FAKE_PLAIN), false, `leaked through: ${line}`);
        assert.match(result.text, /model: deepseek-chat/, `the next line survives: ${line}`);
        assert.match(result.text, /<redacted>/, line);
      }
    }
  }
});

test('redactText covers JSON fields, compact and pretty', () => {
  const compact = `{"apiKey":"${FAKE_PLAIN}","model":"deepseek-chat","password":"${FAKE_PLAIN}2"}`;
  const out = redactText(compact).text;
  assert.equal(out.includes(FAKE_PLAIN), false, out);
  assert.match(out, /"model":"deepseek-chat"/, 'neighbouring fields survive');
  assert.match(out, /"apiKey":"<redacted>"/);

  const pretty = JSON.stringify({ provider: { token: FAKE_PLAIN, secret: FAKE_PLAIN, name: 'x' } }, null, 2);
  const prettyOut = redactText(pretty).text;
  assert.equal(prettyOut.includes(FAKE_PLAIN), false, prettyOut);
  assert.match(prettyOut, /"name": "x"/);

  const escaped = `{"token":"ab\\"${FAKE_PLAIN}","ok":true}`;
  const escapedOut = redactText(escaped).text;
  assert.equal(escapedOut.includes(FAKE_PLAIN), false, escapedOut);
  assert.match(escapedOut, /"ok":true/);

  const keyed = redactText(`{"apiKey": "${FAKE_KEY}"}`).text;
  assert.equal(keyed.includes('1234567890abcdef'), false, keyed);
});

test('redactText covers env-style assignments with a prefixed key', () => {
  for (const line of [`DEEPSEEK_API_KEY=${FAKE_PLAIN}`, `export OPENAI_API_KEY="${FAKE_PLAIN}"`, `MY_SECRET=${FAKE_PLAIN}`]) {
    const out = redactText(line).text;
    assert.equal(out.includes(FAKE_PLAIN), false, out);
  }
});

test('redactText removes the userinfo of a URL', () => {
  for (const url of [
    `https://someone:${FAKE_PLAIN}@proxy.example.test:8080/v1`,
    `http://user:${FAKE_PLAIN}@127.0.0.1/`,
    `socks5://u:${FAKE_PLAIN}@h`,
    `git clone https://${FAKE_PLAIN}abcdefghij@git.example.test/repo.git`,
  ]) {
    const result = redactText(`proxy ${url} ok`);
    assert.equal(result.text.includes(FAKE_PLAIN), false, result.text);
    assert.equal(result.text.includes('someone'), false, result.text);
    assert.ok(result.counts['url-credentials'] >= 1, url);
    assert.match(result.text, / ok$/);
  }
  // A URL without userinfo, and an e-mail address, are left alone.
  for (const text of ['open https://example.test/a@b/c', 'mail me at a@b.test', 'http://127.0.0.1:5555/']) {
    assert.deepEqual(redactText(text), { text, counts: {} }, text);
  }
});

test('redactText still catches the shapes it caught before, inside configs', () => {
  const config = [
    'providers:',
    '  - id: deepseek',
    `    apiKey: ${FAKE_KEY}`,
    '    baseURL: https://api.deepseek.test/v1',
    '    headers:',
    `      Authorization: Bearer ${FAKE_PLAIN}`,
    '',
  ].join('\n');
  const out = redactText(config).text;
  assert.equal(out.includes('1234567890abcdef'), false, out);
  assert.equal(out.includes(FAKE_PLAIN), false, out);
  assert.match(out, /baseURL: https:\/\/api\.deepseek\.test\/v1/);
  assert.match(out, /- id: deepseek/);
});

test('redactText does not eat ordinary sentences that mention a key word', () => {
  for (const text of [
    'node| the token expired, please sign in again',
    'node| invalid token: please sign in again',
    'dshportc: password prompt dismissed by the user',
    'maxTokens: 4096',
    'max_tokens: 4096',
    'tokenizer: cl100k',
    'secretsManager: disabled',
    'apiKeyHeader: x-api-key',
    'token:',
    'token: ',
    'auth:\n  mode: oauth',
    'dshportc: webview ready after 5.21s; secret sauce is patience',
  ]) {
    assert.deepEqual(redactText(text), { text, counts: {} }, text);
  }
});

test('redactText leaves a value already redacted by an earlier rule alone', () => {
  const result = redactText('node| Authorization: Bearer abcdefghijkl');
  assert.equal(result.text, 'node| Authorization: <redacted>');
  assert.deepEqual(Object.keys(result.counts), ['authorization-header']);
});

test('a config file the bundle reads has its key: value secrets removed', () => {
  const tree = fixture();
  writeFileSync(
    join(tree.dshHome, 'profiles', 'ios-sim', 'cordis.patch.yml'),
    `- id: provider-deepseek\n  config:\n    apiKey: ${FAKE_KEY}\n    proxy: http://me:${FAKE_PLAIN}@10.0.0.1:3128\n    model: deepseek-chat\n`,
  );
  const report = collect({ roots: roots(tree), now: '2026-11-02T00:00:00.000Z' });
  const patch = report.files.find((file) => file.id === 'profile-user-patch');
  assert.equal(patch.content.includes('1234567890abcdef'), false, patch.content);
  assert.equal(patch.content.includes(FAKE_PLAIN), false, patch.content);
  assert.match(patch.content, /model: deepseek-chat/);
});

test('redactText covers the shared privacy regression cases', () => {
  for (const entry of REDACTION_CASES) {
    const result = redactText(entry.text);
    for (const secret of entry.secrets) assert.equal(result.text.includes(secret), false, entry.name);
    for (const kept of entry.kept ?? []) assert.ok(result.text.includes(kept), entry.name);
    if (entry.omitted) {
      assert.equal(result.text, '[omitted: multiline sensitive field]\n', entry.name);
      assert.equal(result.counts['multiline-secret'], 1, entry.name);
    }
  }
});

test('materialized files, manifest and SUMMARY contain no planted private content', () => {
  for (const entry of REDACTION_CASES) {
    const tree = fixture();
    const target = entry.source === 'profile'
      ? join(tree.dshHome, 'profiles', 'ios-sim', 'cordis.patch.yml')
      : join(tree.appSupport, entry.source === 'status' ? 'DSHPortC-status.json' : 'DSHPortC-node.log');
    writeFileSync(target, entry.text);
    const report = collect({ roots: roots(tree), now: '2026-11-02T00:00:00.000Z' });
    const written = materialize({ report, outDir: join(tree.root, 'bundle') });
    for (const file of [written.summaryPath, written.manifestPath, ...written.files]) {
      const text = readFileSync(file, 'utf8');
      for (const secret of entry.secrets) assert.equal(text.includes(secret), false, entry.name + ': ' + file);
    }
  }
});

test('the manifest and summary carry no absolute path from the device', () => {
  const tree = fixture();
  // Roots that look like a real container, under the test's own temp directory.
  const container = join(tree.root, 'var', 'mobile', 'Containers', 'Data', 'Application', 'ABCDEF01-2345-6789-ABCD-EF0123456789');
  const appSupport = join(container, 'Library', 'Application Support', 'DSHPortC');
  mkdirSync(join(appSupport, 'boot'), { recursive: true });
  writeFileSync(join(appSupport, 'DSHPortC-node.log'), 'dshportc: boot pipeline started\n');
  const report = collect({
    roots: {
      appSupport,
      // A root that does not exist, under a fake home directory: its error
      // message names the path.
      dshHome: '/Users/fakeperson/Library/Developer/CoreSimulator/Devices/11111111-2222-3333-4444-555555555555/data/DSH',
      documents: join(container, 'Documents'),
    },
    now: '2026-11-02T00:00:00.000Z',
  });
  const outDir = join(mkdtempSync(join(base, 'bundle-paths-')), 'bundle');
  const written = materialize({ report, outDir });
  const manifestText = readFileSync(written.manifestPath, 'utf8');
  const summaryText = readFileSync(written.summaryPath, 'utf8');
  const manifest = JSON.parse(manifestText);
  // `roots` is the one place a full (redacted) path is meant to stay: the
  // fixture's temp prefix is in it only because this test put it there.
  const { roots: shownRoots, ...rest } = manifest;
  const summaryWithoutRoots = summaryText.replace(/## Roots\n[\s\S]*?\n## /, '## ');
  for (const [name, text] of [
    ['manifest', manifestText], ['summary', summaryText],
    ['manifest outside roots', JSON.stringify(rest)], ['summary outside roots', summaryWithoutRoots],
  ]) {
    assert.equal(text.includes('ABCDEF01-2345-6789-ABCD-EF0123456789'), false, `${name} names the container`);
    assert.equal(text.includes('fakeperson'), false, `${name} names the user`);
    assert.equal(text.includes('11111111-2222-3333-4444-555555555555'), false, `${name} names the simulator device`);
    if (name.endsWith('outside roots')) assert.equal(text.includes(tree.root), false, `${name} names the fixture root`);
  }
  assert.ok(Object.keys(shownRoots).length > 0);
  const log = manifest.files.find((file) => file.id === 'app-log');
  assert.equal(log.path, 'appSupport/DSHPortC-node.log', 'a collected file is named relative to its root');
  const inventory = manifest.inventory.find((entry) => entry.root === 'appSupport');
  assert.equal(inventory.path, 'appSupport');
  assert.match(manifest.roots.appSupport, /Containers\/Data\/Application\/<container>/);
  assert.match(manifest.roots.dshHome, /^\/Users\/<user>\//);
});

test('a home directory in a file the bundle reads is replaced too', () => {
  const tree = fixture();
  writeFileSync(join(tree.appSupport, 'DSHPortC-node.log'), 'node| cwd /Users/fakeperson/Projects/x and /home/otherfake/y\n');
  const report = collect({ roots: roots(tree), now: '2026-11-02T00:00:00.000Z' });
  const log = report.files.find((file) => file.id === 'app-log');
  assert.equal(log.content.includes('fakeperson'), false, log.content);
  assert.equal(log.content.includes('otherfake'), false, log.content);
  assert.match(log.content, /\/Users\/<user>\/Projects\/x/);
});

test('isForbiddenPath refuses sessions, attachments, storages and credentials', () => {
  for (const rel of [
    '.credentials.yaml',
    'sessions/x',
    'sessions/session-1/session.v1.jsonl.zstd',
    'attachments/a.jpg',
    'storages/workspace.json',
    'events.jsonl',
    'AGENTS.md',
    '../outside',
    'nested/sessions/x',
  ]) {
    assert.equal(isForbiddenPath(rel), true, rel);
  }
  for (const rel of ['DSHPortC-node.log', 'profiles/ios-sim/cordis.patch.yml', 'boot/boot-guard.json']) {
    assert.equal(isForbiddenPath(rel), false, rel);
  }
  assert.equal(FORBIDDEN_NAMES.includes('.credentials.yaml'), true);
});

test('safeResolve refuses escapes and absolute input', () => {
  const root = join(base, 'safe-root');
  mkdirSync(root, { recursive: true });
  assert.equal(safeResolve(root, 'a/b.txt'), join(root, 'a/b.txt'));
  assert.equal(safeResolve(root, '../escape'), null);
  assert.equal(safeResolve(root, 'a/../../escape'), null);
  assert.equal(safeResolve(root, '/etc/passwd'), null);
  assert.equal(safeResolve('relative', 'a'), null);
  assert.equal(safeResolve(root, ''), null);
  assert.equal(safeResolve(root, 'a\0b'), null);
});

test('a large file is cut to the per-file limit from the tail', () => {
  const tree = fixture();
  const big = ('node| ' + 'x'.repeat(99) + '\n').repeat(4100) + 'node| TAIL-MARKER-1234567890\n';
  writeFileSync(join(tree.appSupport, 'DSHPortC-node.log'), big);
  const report = collect({
    roots: roots(tree),
    limits: { maxFileBytes: 4096, readWindowBytes: 8192 },
    now: '2026-11-02T00:00:00.000Z',
  });
  const log = report.files.find((file) => file.id === 'app-log');
  assert.equal(log.truncated, 'window', 'the read window is smaller than the file');
  assert.ok(Buffer.byteLength(log.content) <= 4096 + 200);
  assert.ok(log.content.includes('TAIL-MARKER-1234567890'), 'the end of the log is what is kept');
  assert.match(log.content, /\[truncated:/);
});

test('a file over the per-file limit but inside the read window is marked "file"', () => {
  const tree = fixture();
  writeFileSync(join(tree.appSupport, 'DSHPortC-node.log'), `${'y'.repeat(20000)}TAIL-2\n`);
  const report = collect({
    roots: roots(tree),
    limits: { maxFileBytes: 2048, readWindowBytes: 64 * 1024 },
    now: '2026-11-02T00:00:00.000Z',
  });
  const log = report.files.find((file) => file.id === 'app-log');
  assert.equal(log.truncated, 'file');
  assert.ok(Buffer.byteLength(log.content) <= 2048 + 200);
  assert.ok(log.content.includes('TAIL-2'));
});

test('the read window never starts mid-line', () => {
  const tree = fixture();
  const lines = [];
  for (let index = 0; index < 200; index += 1) lines.push(`node| line-${String(index).padStart(3, '0')}-${'z'.repeat(40)}`);
  writeFileSync(join(tree.appSupport, 'DSHPortC-node.log'), `${lines.join('\n')}\n`);
  const report = collect({
    roots: roots(tree),
    limits: { readWindowBytes: 1000, maxFileBytes: 100000 },
    now: '2026-11-02T00:00:00.000Z',
  });
  const log = report.files.find((file) => file.id === 'app-log');
  const body = log.content.split('\n').filter((line) => line.startsWith('node| line-'));
  assert.ok(body.length > 0);
  assert.match(body[0], /^node\| line-\d{3}-z+$/, 'the first kept line is complete');
});

test('a cut log drops old notification continuations and keeps later records', () => {
  const tree = fixture();
  writeFileSync(join(tree.appSupport, 'DSHPortC-node.log'),
    'dshportc: notify delivered question title=private\n' + (FAKE_PLAIN + '\n').repeat(200)
      + 'dshportc: boot recovered\nnode| TAIL-AFTER-NOTIFICATION\n');
  const report = collect({
    roots: roots(tree), limits: { readWindowBytes: 1000 }, now: '2026-11-02T00:00:00.000Z',
  });
  const log = report.files.find((file) => file.id === 'app-log');
  assert.equal(log.truncated, 'window');
  assert.match(log.content, /boot recovered/);
  assert.match(log.content, /TAIL-AFTER-NOTIFICATION/);
  const written = materialize({ report, outDir: join(tree.root, 'bundle') });
  for (const file of [written.summaryPath, written.manifestPath, ...written.files]) {
    assert.equal(readFileSync(file, 'utf8').includes(FAKE_PLAIN), false, file);
  }
});

test('a structured source cannot export a tail without its field context', () => {
  for (const source of sourceList().filter((entry) => entry.id !== 'app-log')) {
    const tree = fixture();
    writeFileSync(join(roots(tree)[source.root], source.rel),
      'credentials:\n  provider:\n' + ('    ' + FAKE_PLAIN + '\n').repeat(200));
    const report = collect({
      roots: roots(tree), limits: { readWindowBytes: 1000 }, now: '2026-11-02T00:00:00.000Z',
    });
    assert.equal(report.files.some((file) => file.id === source.id), false, source.id);
    assert.ok(report.excluded.some((entry) => entry.path.endsWith(source.rel) && /field context/.test(entry.reason)));
    assert.equal(renderBundleText(report).includes(FAKE_PLAIN), false, source.id);
  }
});

test('the whole-bundle budget truncates the files at the end of the list', () => {
  const tree = fixture();
  writeFileSync(join(tree.appSupport, 'DSHPortC-node.log'), `${'a'.repeat(5000)}\n`);
  writeFileSync(join(tree.appSupport, 'DSHPortC-status.json'), `${'b'.repeat(5000)}\n`);
  const report = collect({
    roots: roots(tree),
    limits: { maxFileBytes: 100000, maxTotalBytes: 6000 },
    now: '2026-11-02T00:00:00.000Z',
  });
  const log = report.files.find((file) => file.id === 'app-log');
  const status = report.files.find((file) => file.id === 'status');
  assert.equal(log.truncated, null);
  assert.equal(status.truncated, 'total');
  assert.match(status.content, /budget/);
  const later = report.files.find((file) => file.id === 'profile-app-patch');
  assert.equal(later.truncated, 'total');
  assert.equal(later.content, null, 'a file with no room left is listed but not copied');
  assert.ok(report.totals.keptBytes <= 6000 + 300);
});

test('a binary file is reported without its bytes', () => {
  const tree = fixture();
  writeFileSync(join(tree.appSupport, 'DSHPortC-status.json'), Buffer.from([0x7b, 0x00, 0x01, 0x02, 0x03]));
  const report = collect({ roots: roots(tree), now: '2026-11-02T00:00:00.000Z' });
  const status = report.files.find((file) => file.id === 'status');
  assert.equal(status.binary, true);
  assert.equal(status.content, null);
  assert.equal(status.truncated, 'binary');
});

test('a source file that is a symbolic link is not followed', () => {
  const tree = fixture();
  const outside = join(mkdtempSync(join(base, 'outside-')), 'secret.log');
  writeFileSync(outside, SECRETS.credentials);
  rmSync(join(tree.appSupport, 'DSHPortC-node.log'));
  symlinkSync(outside, join(tree.appSupport, 'DSHPortC-node.log'));
  const report = collect({ roots: roots(tree), now: '2026-11-02T00:00:00.000Z' });
  const log = report.files.find((file) => file.id === 'app-log');
  assert.equal(log, undefined);
  assert.match(report.excluded.map((entry) => `${entry.path} ${entry.reason}`).join('\n'), /symbolic link/);
  assert.equal(renderBundleText(report).includes(SECRETS.credentials), false);
});

test('a root that is itself a symbolic link is refused', () => {
  const tree = fixture();
  const moved = join(base, 'moved-boot');
  mkdirSync(moved, { recursive: true });
  writeFileSync(join(moved, 'boot-guard.json'), `{"secret":"${SECRETS.storages}"}`);
  rmSync(tree.boot, { recursive: true, force: true });
  symlinkSync(moved, tree.boot);
  const report = collect({ roots: roots(tree), now: '2026-11-02T00:00:00.000Z' });
  assert.equal(report.files.some((file) => file.id === 'boot-guard'), false);
  assert.match(report.excluded.map((entry) => entry.reason).join('\n'), /itself a symbolic link/);
  assert.equal(renderBundleText(report).includes(SECRETS.storages), false);
});

test('a missing root is an error entry, not a throw', () => {
  const tree = fixture();
  const report = collect({ roots: { dshHome: tree.dshHome }, now: '2026-11-02T00:00:00.000Z' });
  assert.ok(report.errors.length > 0);
  assert.match(report.errors[0].error, /not configured/);
  assert.equal(report.files.length, 4, 'the four dshHome files are still collected');
});

test('the container id is replaced, and can be kept on request', () => {
  const tree = fixture();
  const withRedaction = collect({ roots: roots(tree), now: '2026-11-02T00:00:00.000Z' });
  const appPatch = withRedaction.files.find((file) => file.id === 'profile-app-patch');
  assert.equal(appPatch.content.includes('DEADBEEF-1111-2222-3333-444455556666'), false);
  assert.match(appPatch.content, /Containers\/Data\/Application\/<container>/);

  const withoutRedaction = collect({ roots: roots(tree), now: '2026-11-02T00:00:00.000Z', redactPaths: false });
  const raw = withoutRedaction.files.find((file) => file.id === 'profile-app-patch');
  assert.match(raw.content, /DEADBEEF-1111-2222-3333-444455556666/);
});

test('the rendered bundle is readable and says what it left out', () => {
  const tree = fixture();
  const text = renderBundleText(collect({ roots: roots(tree), now: '2026-11-02T00:00:00.000Z' }));
  assert.match(text, /^# DSHPortC diagnostics bundle/);
  assert.match(text, /## What this bundle does not contain/);
  assert.match(text, /## Inventory/);
  assert.match(text, /## appSupport\/DSHPortC-node\.log/);
  assert.match(text, /id: status/);
});

test('materialize writes a summary, a manifest with no content, and one file per entry', () => {
  const tree = fixture();
  const report = collect({ roots: roots(tree), now: '2026-11-02T00:00:00.000Z' });
  const outDir = join(mkdtempSync(join(base, 'bundle-')), 'bundle');
  const written = materialize({ report, outDir });
  assert.ok(written.files.length > 0);
  const manifest = JSON.parse(readFileSync(written.manifestPath, 'utf8'));
  for (const entry of manifest.files) {
    assert.equal(Object.hasOwn(entry, 'content'), false, 'the manifest carries no content');
  }
  assert.match(readFileSync(written.summaryPath, 'utf8'), /diagnostics bundle/);
  const names = readdirSync(join(outDir, 'files'));
  assert.ok(names.every((name) => /^\d{2}-[A-Za-z0-9._-]+$/.test(name)));
  const everything = readdirSync(join(outDir, 'files'))
    .map((name) => readFileSync(join(outDir, 'files', name), 'utf8')).join('\n');
  for (const secret of Object.values(SECRETS)) assert.equal(everything.includes(secret), false);
});

test('materialize refuses a relative directory and a missing report', () => {
  const report = collect({ roots: {}, now: '2026-11-02T00:00:00.000Z' });
  assert.throws(() => materialize({ report, outDir: 'relative' }), TypeError);
  assert.throws(() => materialize({ outDir: join(base, 'x') }), TypeError);
});

test('exportOnce answers a request exactly once', () => {
  const tree = fixture();
  const work = mkdtempSync(join(base, 'export-'));
  const requestFile = join(work, 'export-request.json');
  const doneFile = join(work, 'export-done.json');
  const outDir = join(work, 'bundles');

  assert.deepEqual(exportOnce({ requestFile, doneFile, outDir, roots: roots(tree) }), { status: 'idle' });

  writeFileSync(requestFile, JSON.stringify({ action: 'export-diagnostics', id: 'r-1' }));
  const first = exportOnce({ requestFile, doneFile, outDir, roots: roots(tree), now: '2026-11-02T00:00:00.000Z' });
  assert.equal(first.status, 'exported');
  assert.equal(first.id, 'r-1');
  assert.ok(readFileSync(first.summary).includes('diagnostics bundle'));

  const second = exportOnce({ requestFile, doneFile, outDir, roots: roots(tree) });
  assert.equal(second.status, 'already-done');
  assert.equal(second.dir, first.dir);

  writeFileSync(requestFile, JSON.stringify({ action: 'reboot' }));
  assert.equal(exportOnce({ requestFile, doneFile, outDir, roots: roots(tree) }).status, 'ignored');

  writeFileSync(requestFile, '{not json');
  assert.equal(exportOnce({ requestFile, doneFile, outDir, roots: roots(tree) }).status, 'invalid-request');

  writeFileSync(requestFile, JSON.stringify({ action: 'export-diagnostics' }));
  assert.equal(exportOnce({ requestFile, doneFile, outDir, roots: roots(tree) }).status, 'invalid-request');
});

test('snapshot writes a bundle and keeps only the newest few', () => {
  const tree = fixture();
  const outDir = join(mkdtempSync(join(base, 'snapshots-')), 'bundles');
  const first = snapshot({ outDir, roots: roots(tree), now: '2026-11-01T00:00:00.000Z', keep: 2 });
  assert.match(first.dir.slice(outDir.length + 1), /^\d{8}T\d{6}Z-boot$/);
  assert.ok(readFileSync(first.summaryPath, 'utf8').includes('diagnostics bundle'));
  snapshot({ outDir, roots: roots(tree), now: '2026-11-02T00:00:00.000Z', keep: 2 });
  const third = snapshot({ outDir, roots: roots(tree), now: '2026-11-03T00:00:00.000Z', keep: 2 });
  assert.deepEqual(third.pruned.removed, [first.dir.slice(outDir.length + 1)]);
  assert.throws(() => snapshot({ outDir: 'relative' }), TypeError);
});

test('exportOnce names bundles so that pruning works on them', () => {
  const tree = fixture();
  const work = mkdtempSync(join(base, 'export-names-'));
  const requestFile = join(work, 'export-request.json');
  const doneFile = join(work, 'export-done.json');
  const outDir = join(work, 'bundles');
  writeFileSync(requestFile, JSON.stringify({ action: 'export-diagnostics', id: 'a' }));
  const first = exportOnce({ requestFile, doneFile, outDir, roots: roots(tree), now: '2026-11-01T00:00:00.000Z' });
  assert.equal(first.status, 'exported');
  const name = first.dir.slice(outDir.length + 1);
  assert.match(name, /^\d{8}T\d{6}Z-a$/);
  writeFileSync(requestFile, JSON.stringify({ action: 'export-diagnostics', id: 'b' }));
  const second = exportOnce({ requestFile, doneFile, outDir, roots: roots(tree), now: '2026-11-02T00:00:00.000Z' });
  const pruned = pruneExports({ outDir, keep: 1 });
  assert.deepEqual(pruned.kept, [second.dir.slice(outDir.length + 1)]);
  assert.deepEqual(pruned.removed, [name]);
});

test('pruneExports keeps the newest bundles only', () => {
  const outDir = mkdtempSync(join(base, 'prune-'));
  for (const stamp of ['20261101T000000', '20261102T000000', '20261103T000000', 'not-a-bundle']) {
    mkdirSync(join(outDir, `${stamp}-x`), { recursive: true });
  }
  const result = pruneExports({ outDir, keep: 2 });
  assert.deepEqual(result.kept, ['20261102T000000-x', '20261103T000000-x']);
  assert.deepEqual(result.removed, ['20261101T000000-x']);
  assert.ok(readdirSync(outDir).includes('not-a-bundle-x'), 'unrelated directories are left alone');
  assert.throws(() => pruneExports({ outDir, keep: 0 }), TypeError);
});

test('collect never throws, whatever the roots look like', () => {
  for (const rootsInput of [{}, { dshHome: 'relative' }, { appSupport: 42 }, { boot: '/nonexistent/boot' }]) {
    const report = collect({ roots: rootsInput, now: '2026-11-02T00:00:00.000Z' });
    assert.equal(Array.isArray(report.files), true);
  }
});

test('DEFAULT_LIMITS are the ones the plan promises', () => {
  assert.equal(DEFAULT_LIMITS.maxFileBytes, 256 * 1024);
  assert.equal(DEFAULT_LIMITS.maxTotalBytes, 2 * 1024 * 1024);
});
