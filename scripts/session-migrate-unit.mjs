#!/usr/bin/env node
// Host-side unit checks for sim/session-migrate.mjs, run before the in-app
// acceptance so a mistake shows up in a second rather than after a 40 s boot.
//
//   node scripts/session-migrate-unit.mjs <a-real-session-log.jsonl.zstd>
//
// The log is copied into a scratch DSH home under a STALE container path, the
// migration runs, and the result is checked against DSH's own rules:
//
//   * the header cwd is the current container,
//   * every frame still decodes and the header frame is exactly one line,
//   * the session directory name equals `projectKey(cwd)` — the same function
//     DSH uses, so a mismatch here is the exact failure DSH reports as corrupt,
//   * a deliberately corrupted sibling log is isolated ALONE,
//   * a session quarantined by an earlier launch is swept back and wiped clean
//     of its stale container path,
//   * `workspace.json` loses the ids that have no log.
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import zlib from 'node:zlib';
import {
  canonicalHeaderCwd, canonicalPath, dedupeWorkspaceRegistry, liveSessionIds, migrateSessions, projectKey,
  pruneWorkspaceRegistry, respellAll, respellContainer, rewriteHeaderCwd, rewriteStoragePaths, scanFrames,
  sweepQuarantine,
} from '../sim/session-migrate.mjs';

// The fixture log: a real one when given, otherwise built here. Building it is
// better than depending on a simulator container that a reinstall can delete —
// that dependency is exactly what broke this script's first run.
const given = process.argv[2];
const source = (() => {
  if (given) return given;
  const built = join(mkdtempSync(join(tmpdir(), 'step6-fixture-')), 'session.v4.jsonl.zstd');
  const header = {
    type: 'session', version: 4, id: 'session-11111111-1111-4111-8111-111111111111',
    createdAt: 1793179717698, cwd: '/placeholder/workspace', isSeeded: false,
    delegationDepth: 0, agentPreset: 'ios-safe',
  };
  const events = [
    { type: 'turn/start', seq: 0, time: 1793179718000, data: { turn: 1 } },
    { type: 'user/message', seq: 1, time: 1793179719000, data: {
      source: { kind: 'user', rpcId: 'rpc-1' },
      content: [{ type: 'text', text: 'hello from the fixture' }] } },
    { type: 'assistant/message', seq: 2, time: 1793179720000, data: {
      message: { role: 'assistant', content: [{ type: 'text', text: 'acknowledged' }] } } },
    { type: 'turn/end', seq: 3, time: 1793179721000, data: { turn: 1 } },
  ];
  // Three frames, like DSH writes: header, then one frame per durable batch.
  const frames = [
    zlib.zstdCompressSync(Buffer.from(JSON.stringify(header) + '\n', 'utf8'),
      { params: { [zlib.constants.ZSTD_c_checksumFlag]: 1 } }),
    zlib.zstdCompressSync(Buffer.from(events.slice(0, 2).map((e) => JSON.stringify(e)).join('\n') + '\n', 'utf8'),
      { params: { [zlib.constants.ZSTD_c_checksumFlag]: 1 } }),
    zlib.zstdCompressSync(Buffer.from(events.slice(2).map((e) => JSON.stringify(e)).join('\n') + '\n', 'utf8'),
      { params: { [zlib.constants.ZSTD_c_checksumFlag]: 1 } }),
  ];
  writeFileSync(built, Buffer.concat(frames));
  return built;
})();

const checks = [];
const check = (name, ok, detail) => { checks.push({ name, ok: Boolean(ok), detail }); };
const frameOf = (object) => zlib.zstdCompressSync(Buffer.from(JSON.stringify(object) + '\n', 'utf8'), {
  params: { [zlib.constants.ZSTD_c_checksumFlag]: 1 },
});
const headerOf = (path) => {
  const raw = readFileSync(path);
  const { frames } = scanFrames(raw, 1);
  return JSON.parse(zlib.zstdDecompressSync(raw.subarray(frames[0].start, frames[0].end)).toString('utf8'));
};

const root = mkdtempSync(join(tmpdir(), 'step6-unit-'));
// The containers live INSIDE the scratch dir so the sweep can really create a
// missing project directory. The path shape is what matters — the marker
// `/Containers/Data/Application/<uuid>` is what the rewrite keys on — and it is
// identical to the simulator's and the device's.
//
// STEP 9: the fixture is built in the CANONICAL spelling, because that is the only
// spelling the migration is allowed to write. `tmpdir()` on this Mac is
// `/var/folders/...`, and `fs.realpath` (i.e. what `dsh-workspace` compares
// against) answers `/private/var/folders/...` for it — the exact
// `/var` <-> `/private/var` split the phone showed. Spelling the fixture the
// `/var` way and asserting the migration reproduced it byte-for-byte is what let
// the old fold direction look correct while it was splitting the real device.
const OLD = canonicalPath(join(root, 'old/Containers/Data/Application/11111111-1111-1111-1111-111111111111'));
const NOW = canonicalPath(join(root, 'now/Containers/Data/Application/22222222-2222-2222-2222-222222222222'));
const OLD_CWD = `${OLD}/Documents/workspace/deepseek-harness/default-workspace`;
const NOW_CWD = `${NOW}/Documents/workspace/deepseek-harness/default-workspace`;
const sessions = join(root, 'sessions');
const quarantine = join(root, 'sessions-quarantine');
const storages = join(root, 'storages');

try {
  // ---------------------------------------------------------------- fixture
  // Reuse a real log's frames but move its header cwd to the stale container, so
  // the migration has something to rewrite and the event frames are DSH's own
  // writer output rather than a synthetic stand-in.
  const raw = readFileSync(source);
  const { frames } = scanFrames(raw);
  check('source log scans into frames', frames.length >= 2, `${frames.length} frame(s), ${raw.length} bytes`);
  const header = JSON.parse(zlib.zstdDecompressSync(raw.subarray(frames[0].start, frames[0].end)).toString('utf8'));
  const staleLog = Buffer.concat([frameOf({ ...header, cwd: OLD_CWD }), raw.subarray(frames[0].end)]);

  const sessionId = header.id;
  const oldProjectKey = projectKey(OLD_CWD);
  const oldDir = join(sessions, oldProjectKey, sessionId);
  mkdirSync(oldDir, { recursive: true });
  writeFileSync(join(oldDir, 'session.v4.jsonl.zstd'), staleLog);

  // A second log in the same project directory that is not a session at all.
  const damagedId = 'session-00000000-0000-4000-8000-000000000bad';
  const damagedDir = join(sessions, oldProjectKey, damagedId);
  mkdirSync(damagedDir, { recursive: true });
  writeFileSync(join(damagedDir, 'session.v4.jsonl.zstd'), Buffer.from([0xde, 0xad, 0xbe, 0xef, 1, 2, 3, 4]));

  // A third: a log whose first frame is valid zstd but not a header line.
  const garbageId = 'session-00000000-0000-4000-8000-000000000c0d';
  const garbageDir = join(sessions, oldProjectKey, garbageId);
  mkdirSync(garbageDir, { recursive: true });
  writeFileSync(join(garbageDir, 'session.v4.jsonl.zstd'), zlib.zstdCompressSync(Buffer.from('not a header\n')));

  // ---------------------------------------------------------------- migrate
  const lines = [];
  const result = migrateSessions({
    sessionsRoot: sessions, quarantineRoot: quarantine, current: NOW, log: (l) => lines.push(l),
  });
  check('migration rewrote only the real log', result.rewritten === 1, JSON.stringify({ rewritten: result.rewritten, moved: result.moved }));
  check('migration isolated exactly the two bad logs', result.quarantined === 2, result.failed.join(' | '));
  check('migration named both reasons',
    /invalid frame magic/.test(result.failed.join(' ')) && /header line is not valid JSON/.test(result.failed.join(' ')),
    result.failed.join(' | '));
  check('migration logged each isolation', lines.filter((l) => l.startsWith('isolating')).length === 2, lines.join(' | '));
  check('migration recorded no unexpected error', result.errors.length === 0, result.errors.join(' | '));

  // ------------------------------------------------------- header + identity
  const newProjectKey = projectKey(NOW_CWD);
  check('session directory moved to projectKey(current cwd)', readdirSync(sessions).includes(newProjectKey), readdirSync(sessions).join(','));
  const moved = join(sessions, newProjectKey, sessionId, 'session.v4.jsonl.zstd');
  const movedRaw = readFileSync(moved);
  const movedScan = scanFrames(movedRaw).frames;
  check('migrated log scans cleanly', movedScan.length === frames.length, `${movedScan.length} vs ${frames.length}`);
  const movedHeaderText = zlib.zstdDecompressSync(
    movedRaw.subarray(movedScan[0].start, movedScan[0].end),
  ).toString('utf8');
  check('header frame is exactly one line',
    movedHeaderText.endsWith('\n') && movedHeaderText.indexOf('\n') === movedHeaderText.length - 1, `${movedHeaderText.length} bytes`);
  const movedHeader = JSON.parse(movedHeaderText);
  check('header cwd is the current container', movedHeader.cwd === NOW_CWD, movedHeader.cwd);
  check('every other header field survived',
    JSON.stringify({ ...movedHeader, cwd: null }) === JSON.stringify({ ...header, cwd: null }), 'field-by-field compare');
  check('directory name equals projectKey(header cwd)', projectKey(movedHeader.cwd) === newProjectKey);

  // Every event frame after the header must decode to the same bytes as before.
  const bodyOf = (buffer, list, skip) => list.slice(skip)
    .map((f) => zlib.zstdDecompressSync(buffer.subarray(f.start, f.end)).toString('utf8')).join('');
  check('event frames are byte-identical after migration',
    bodyOf(raw, frames, 1) === bodyOf(movedRaw, movedScan, 1), `${bodyOf(movedRaw, movedScan, 1).length} bytes of events`);

  // -------------------------------------------------------- quarantine path
  const stampDirs = readdirSync(quarantine).filter((n) => !n.startsWith('.'));
  check('quarantine holds one stamp folder', stampDirs.length === 1, stampDirs.join(','));
  const isolatedProject = join(quarantine, stampDirs[0], oldProjectKey);
  check('both bad sessions sit in quarantine',
    readdirSync(isolatedProject).sort().join(',') === [damagedId, garbageId].sort().join(','), readdirSync(isolatedProject).join(','));
  check('the healthy session was not quarantined', !readdirSync(isolatedProject).includes(sessionId), readdirSync(isolatedProject).join(','));

  // -------------------------------------------------------- second run no-op
  const again = migrateSessions({ sessionsRoot: sessions, quarantineRoot: quarantine, current: NOW, log: () => {} });
  check('a second run rewrites and isolates nothing', again.rewritten === 0 && again.quarantined === 0, JSON.stringify(again));

  // -------------------------------------------------------- rewrite contract
  const noop = rewriteHeaderCwd(moved, (h) => (h.cwd.startsWith(NOW) ? undefined : h.cwd));
  check('rewrite is a no-op when the header already matches', noop.status === 'unchanged', JSON.stringify(noop));

  // ------------------------------------------------------- path respelling
  // Both container spellings DSH has to handle must resolve to this one, AND to
  // the canonical spelling (§step 9): a header rewritten to `/var/...` is the bug
  // the phone reported, because `dsh-workspace` realpaths the cwd and the two
  // strings then never match.
  const deviceOld = '/var/mobile/Containers/Data/Application/33333333-3333-3333-3333-333333333333';
  check('device-spelled path is respelled to the canonical container',
    respellContainer(`${deviceOld}/Documents/x`, NOW) === canonicalPath(`${NOW}/Documents/x`),
    respellContainer(`${deviceOld}/Documents/x`, NOW));
  check('/private/var spelling is respelled to the canonical container',
    respellContainer(`/private${deviceOld}/Documents/x`, NOW) === canonicalPath(`${NOW}/Documents/x`),
    respellContainer(`/private${deviceOld}/Documents/x`, NOW));
  check('a path already in this container is untouched', respellContainer(NOW_CWD, NOW) === undefined, String(respellContainer(NOW_CWD, NOW)));
  check('a path with no container marker is untouched', respellContainer('/tmp/nowhere', NOW) === undefined, String(respellContainer('/tmp/nowhere', NOW)));

  // A `/var/...` header naming the CURRENT container is still wrong, and this is
  // the case the phone hit: the container is right, the spelling is not, so
  // `attachSession` can never match it. It must be folded, not left alone.
  const sameContainerFriendly = `/var${NOW.replace('/private/var', '')}/Documents/x`;
  check('a current-container path in the /var spelling is still folded',
    respellContainer(sameContainerFriendly, NOW) === canonicalPath(sameContainerFriendly.replace('/var/', '/private/var/')),
    String(respellContainer(sameContainerFriendly, NOW)));

  // A header can be right about the container and wrong about a SUBDIRECTORY's
  // spelling — any symlinked ancestor does it. `respellContainer` deliberately says
  // "nothing to do" there, so `canonicalHeaderCwd` is what the migration calls; if
  // this regressed, one folder would get two project directories again.
  const aliasDir = join(root, 'now', 'alias-into-documents');
  // The leaf has to EXIST: `realpath` on a missing last segment fails and the fold
  // falls back to the string rule, which would make this fixture prove nothing
  // about symlink resolution.
  mkdirSync(join(root, 'now', 'Documents', 'real-sub', 'deepseek-harness'), { recursive: true });
  try {
    const { symlinkSync } = process.getBuiltinModule('node:fs');
    symlinkSync(join(root, 'now', 'Documents', 'real-sub'), aliasDir);
  } catch { /* already linked */ }
  const aliasedCwd = `${aliasDir}/deepseek-harness`;
  const realCwd = canonicalPath(aliasedCwd);
  check('the alias really is a second spelling', aliasedCwd !== realCwd && realCwd.endsWith('/Documents/real-sub/deepseek-harness'),
    `${aliasedCwd} -> ${realCwd}`);
  check('respellContainer alone leaves an in-container alias spelling alone',
    respellContainer(aliasedCwd, NOW) === undefined, String(respellContainer(aliasedCwd, NOW)));
  check('canonicalHeaderCwd folds an in-container alias spelling',
    canonicalHeaderCwd(aliasedCwd, NOW) === realCwd, String(canonicalHeaderCwd(aliasedCwd, NOW)));
  check('canonicalHeaderCwd is a no-op on a canonical path',
    canonicalHeaderCwd(realCwd, NOW) === undefined, String(canonicalHeaderCwd(realCwd, NOW)));
  check('canonicalHeaderCwd still handles a foreign container',
    canonicalHeaderCwd(`${deviceOld}/Documents/x`, NOW) === canonicalPath(`${NOW}/Documents/x`),
    String(canonicalHeaderCwd(`${deviceOld}/Documents/x`, NOW)));

  // ------------------------------------------------- canonical spelling unit
  // The single function every other step now routes through. Each case is a
  // spelling that actually occurred on this platform or on the phone.
  check('canonicalPath folds /var to /private/var', canonicalPath('/var') === '/private/var', canonicalPath('/var'));
  check('canonicalPath folds the /var subtree',
    canonicalPath('/var/mobile/Containers/Data/Application/X') === '/private/var/mobile/Containers/Data/Application/X',
    canonicalPath('/var/mobile/Containers/Data/Application/X'));
  check('canonicalPath leaves the canonical subtree alone',
    canonicalPath('/private/var/mobile/Containers/Data/Application/X') === '/private/var/mobile/Containers/Data/Application/X',
    canonicalPath('/private/var/mobile/Containers/Data/Application/X'));
  check('canonicalPath resolves the simulator tmpdir alias',
    canonicalPath('/var/folders') === '/private/var/folders', canonicalPath('/var/folders'));
  check('canonicalPath survives a path that does not exist',
    canonicalPath('/private/var/mobile/does/not/exist') === '/private/var/mobile/does/not/exist',
    canonicalPath('/private/var/mobile/does/not/exist'));
  check('canonicalPath folds a dead /var path without needing it to exist',
    canonicalPath('/var/mobile/gone') === '/private/var/mobile/gone', canonicalPath('/var/mobile/gone'));
  check('canonicalPath leaves a non-/var path to realpath', canonicalPath('/tmp') === '/private/tmp', canonicalPath('/tmp'));

  // ------------------------------------------------ whole-text respelling
  // Both container spellings, both slash encodings, and idempotence. This is the
  // function the storage rewrite uses, and the first version of it replaced its
  // own output (`/a/b/Containers/...`) — which is why it is checked on text, not
  // only on one path.
  const NEWB = NOW;
  const cases = [
    ['plain simulator path', `${OLD}/Documents/ws`],
    ['device path', '/var/mobile/Containers/Data/Application/33333333-3333-3333-3333-333333333333/Documents/ws'],
    ['json-escaped slashes', `\/Users\/x\/Containers\/Data\/Application\/44444444-4444-4444-4444-444444444444\/ws`],
    ['two paths in one document', `{"a":"${OLD}/x","b":"${OLD}/y"}`],
    ['already current', `${NOW}/Documents/ws`],
    ['no marker', 'nothing here'],
  ];
  for (const [name, input] of cases) {
    const once = respellAll(input, NEWB);
    const twice = respellAll(once, NEWB);
    const mentionsOld = once.includes(OLD) || /Containers\/Data\/Application\/(?!22222222)/.test(once.replace(/\\/g, ''));
    check(`respellAll is idempotent and leaves no foreign container: ${name}`,
      once === twice && !mentionsOld, `${JSON.stringify(once)}`);
  }
  check('respellAll replaces every path in one document',
    (respellAll(`{"a":"${OLD}/x","b":"${OLD}/y"}`, NEWB).match(/22222222-2222-2222-2222-222222222222/g) || []).length === 2,
    respellAll(`{"a":"${OLD}/x","b":"${OLD}/y"}`, NEWB));

  // -------------------------------------------------- quarantine sweep back
  // The two bad sessions cannot be restored, so a sweep must leave them and say
  // why. A session quarantined with a merely stale cwd must come back.
  const firstSweep = sweepQuarantine({ sessionsRoot: sessions, quarantineRoot: quarantine, current: NOW, log: () => {} });
  check('sweep leaves the unreadable sessions in quarantine', firstSweep.recovered === 0 && firstSweep.left === 2, JSON.stringify(firstSweep));
  check('sweep records why they stayed', firstSweep.failed.length === 2, firstSweep.failed.join(' | '));

  // Build a stamp folder the way step 4B/5 left one: real frames, stale cwd only.
  const restorableId = 'session-00000000-0000-4000-8000-0000000005e6';
  const restorableStamp = join(quarantine, '2026-01-01T000000Z', oldProjectKey, restorableId);
  mkdirSync(restorableStamp, { recursive: true });
  writeFileSync(join(restorableStamp, 'session.v4.jsonl.zstd'), staleLog);

  const secondSweep = sweepQuarantine({ sessionsRoot: sessions, quarantineRoot: quarantine, current: NOW, log: () => {} });
  check('sweep restores the session whose cwd was merely stale', secondSweep.recovered === 1, JSON.stringify(secondSweep));
  const restored = join(sessions, newProjectKey, restorableId, 'session.v4.jsonl.zstd');
  check('restored session landed under projectKey(current cwd)',
    readdirSync(join(sessions, newProjectKey)).includes(restorableId), readdirSync(join(sessions, newProjectKey)).join(','));
  check('restored header carries the current container', headerOf(restored).cwd === NOW_CWD, headerOf(restored).cwd);
  check('restored log still scans', scanFrames(readFileSync(restored)).frames.length === frames.length);

  const thirdSweep = sweepQuarantine({ sessionsRoot: sessions, quarantineRoot: quarantine, current: NOW, log: () => {} });
  check('an already-swept stamp folder is not swept again', thirdSweep.stamps === 0, JSON.stringify(thirdSweep));

  // ------------------------------------------------- storage path rewrite
  // The Swift version of this only knew the device spelling, so on the simulator
  // it rewrote nothing and said nothing. Exercised here on a simulator-shaped
  // path, which is the case that was broken.
  mkdirSync(storages, { recursive: true });
  writeFileSync(join(storages, 'workspace.json'), JSON.stringify({
    unit: { name: 'workspace', version: 2 },
    global: { workspaceIds: ['w1'], archivedSessionIds: [], pinnedSessionIds: [], initialized: true },
    tables: { workspaces: { w1: { path: `${OLD}/Documents/workspace`, sessionIds: [sessionId], title: 't' } } },
  }, null, 2));
  writeFileSync(join(storages, 'unrelated.json'), JSON.stringify({ note: 'no path here' }));
  const storageRewrite = rewriteStoragePaths({ storagesRoot: storages, current: NOW, log: () => {} });
  const storageAfter = JSON.parse(readFileSync(join(storages, 'workspace.json'), 'utf8'));
  check('the storage rewrite touches exactly the file with a stale path', storageRewrite.rewritten === 1, JSON.stringify(storageRewrite));
  check('the storage path now names the current container',
    storageAfter.tables.workspaces.w1.path === `${NOW}/Documents/workspace`, storageAfter.tables.workspaces.w1.path);
  check('the storage rewrite keeps every other field',
    storageAfter.global.workspaceIds.join(',') === 'w1' && storageAfter.tables.workspaces.w1.sessionIds.join(',') === sessionId
    && storageAfter.unit.version === 2, 'unrelated fields');
  const storageAgain = rewriteStoragePaths({ storagesRoot: storages, current: NOW, log: () => {} });
  check('a second storage rewrite changes nothing', storageAgain.rewritten === 0, JSON.stringify(storageAgain));

  // ------------------------------------------------- registry pruning
  mkdirSync(storages, { recursive: true });
  const registry = {
    global: { archivedSessionIds: [sessionId, damagedId], pinnedSessionIds: [garbageId], workspaceIds: ['w1'], initialized: true },
    tables: { workspaces: { w1: { path: NOW_CWD, sessionIds: [sessionId, damagedId, garbageId], title: 'default-workspace' } } },
    unit: { name: 'workspace', version: 2 },
  };
  writeFileSync(join(storages, 'workspace.json'), JSON.stringify(registry, null, 2));
  const prune = pruneWorkspaceRegistry({ storagesRoot: storages, liveIds: liveSessionIds(sessions), log: () => {} });
  const after = JSON.parse(readFileSync(join(storages, 'workspace.json'), 'utf8'));
  check('pruning counts the dead ids', prune.pruned === 4, JSON.stringify(prune));
  check('archived list keeps only the live session', after.global.archivedSessionIds.join(',') === sessionId, after.global.archivedSessionIds.join(','));
  check('pinned list is emptied', after.global.pinnedSessionIds.length === 0, after.global.pinnedSessionIds.join(','));
  // The registry only ever named the three ids the fixture put in it; the
  // restored session was never a member, so it must not appear.
  check('workspace membership keeps the live session and nothing else',
    after.tables.workspaces.w1.sessionIds.join(',') === sessionId,
    after.tables.workspaces.w1.sessionIds.join(','));
  check('pruning preserves unrelated fields',
    after.unit.version === 2 && after.global.workspaceIds.join(',') === 'w1' && after.tables.workspaces.w1.title === 'default-workspace');
  const pruneAgain = pruneWorkspaceRegistry({ storagesRoot: storages, liveIds: liveSessionIds(sessions), log: () => {} });
  check('a second prune changes nothing', pruneAgain.pruned === 0 && pruneAgain.changed === false, JSON.stringify(pruneAgain));

  // ------------------------------------------------- registry dedupe (step 9)
  //
  // THE PHONE'S STATE, REPRODUCED. Two records for one folder — one spelled
  // `/var/...`, one `/private/var/...`, which is what a launch produced when the
  // fold direction disagreed with the runtime — plus a default-workspace record.
  // The requirement is one record per folder, in the canonical spelling, holding
  // the union of both session lists, with `workspaceIds` and `defaultWorkspaceId`
  // still pointing at live records.
  const friendlyNow = `/var${NOW.replace('/private/var', '')}`;
  const sharedFolder = `${NOW_CWD}`;
  const sharedFolderFriendly = `${friendlyNow}/Documents/workspace/deepseek-harness/default-workspace`;
  mkdirSync(sharedFolder, { recursive: true });
  const dupRegistry = {
    unit: { name: 'workspace', version: 2 },
    global: {
      initialized: true,
      workspaceIds: ['ws-friendly', 'ws-canonical', 'ws-default'],
      archivedSessionIds: [],
      pinnedSessionIds: [],
      defaultWorkspaceId: 'ws-default',
    },
    tables: {
      workspaces: {
        'ws-friendly': { path: sharedFolderFriendly, title: 'default-workspace', sessionIds: ['s-early'], createdAt: '2026-10-28T00:00:00.000Z', updatedAt: '2026-10-28T00:00:00.000Z' },
        'ws-canonical': { path: sharedFolder, title: 'default-workspace', sessionIds: ['s-late'], createdAt: '2026-10-29T00:00:00.000Z', updatedAt: '2026-10-29T00:00:00.000Z' },
        'ws-default': { path: `${sharedFolder}-other`, title: 'other', sessionIds: [], createdAt: '2026-10-29T01:00:00.000Z', updatedAt: '2026-10-29T01:00:00.000Z' },
      },
    },
  };
  mkdirSync(`${sharedFolder}-other`, { recursive: true });
  writeFileSync(join(storages, 'workspace.json'), JSON.stringify(dupRegistry, null, 2));
  const dedupe = dedupeWorkspaceRegistry({ storagesRoot: storages, log: (l) => lines.push(l) });
  const deduped = JSON.parse(readFileSync(join(storages, 'workspace.json'), 'utf8'));
  const dedupedRecords = Object.entries(deduped.tables.workspaces);
  const dedupedPaths = dedupedRecords.map(([, record]) => record.path);
  check('dedupe folded the /var spelling into the canonical one',
    dedupedPaths.includes(sharedFolder) && !dedupedPaths.includes(sharedFolderFriendly), dedupedPaths.join(' | '));
  check('dedupe merged the two records for one folder into one',
    dedupedPaths.filter((p) => p === sharedFolder).length === 1 && dedupedRecords.length === 2,
    `${dedupedRecords.length} record(s): ${dedupedPaths.join(' | ')}`);
  check('dedupe reported what it did', dedupe.merged === 1 && dedupe.folded >= 1 && dedupe.changed === true, JSON.stringify(dedupe));
  const mergedInto = deduped.tables.workspaces['ws-friendly'];
  check('dedupe kept the oldest record and unioned the session ids',
    mergedInto !== undefined && mergedInto.sessionIds.includes('s-early') && mergedInto.sessionIds.includes('s-late'),
    JSON.stringify(mergedInto?.sessionIds));
  check('dedupe dropped the loser from workspaceIds and kept order unique',
    !deduped.global.workspaceIds.includes('ws-canonical')
    && new Set(deduped.global.workspaceIds).size === deduped.global.workspaceIds.length,
    JSON.stringify(deduped.global.workspaceIds));
  check('dedupe left a live defaultWorkspaceId',
    deduped.tables.workspaces[deduped.global.defaultWorkspaceId] !== undefined,
    `${deduped.global.defaultWorkspaceId} -> ${deduped.tables.workspaces[deduped.global.defaultWorkspaceId]?.path ?? 'MISSING'}`);
  const dedupeAgain = dedupeWorkspaceRegistry({ storagesRoot: storages, log: () => {} });
  check('a second dedupe changes nothing', dedupeAgain.changed === false, JSON.stringify(dedupeAgain));

  // A dropped record that WAS the default must hand that role to its keeper,
  // otherwise the dropdown loses its default entry — the second half of the same
  // symptom (`默认工作区` disappearing from the list).
  mkdirSync(`${sharedFolder}-next`, { recursive: true });
  const defaultInDropped = {
    unit: { name: 'workspace', version: 2 },
    global: {
      initialized: true, workspaceIds: ['k-old', 'k-new'], archivedSessionIds: [], pinnedSessionIds: [],
      defaultWorkspaceId: 'k-new',
    },
    tables: {
      workspaces: {
        'k-old': { path: `${sharedFolder}-next`, title: 'next', sessionIds: [], createdAt: '2026-10-28T00:00:00.000Z', updatedAt: '2026-10-28T00:00:00.000Z' },
        'k-new': { path: `/var${`${sharedFolder}-next`.replace('/private/var', '')}`, title: 'next', sessionIds: [], createdAt: '2026-10-29T00:00:00.000Z', updatedAt: '2026-10-29T00:00:00.000Z' },
      },
    },
  };
  writeFileSync(join(storages, 'workspace.json'), JSON.stringify(defaultInDropped, null, 2));
  dedupeWorkspaceRegistry({ storagesRoot: storages, log: () => {} });
  const afterDefaultMove = JSON.parse(readFileSync(join(storages, 'workspace.json'), 'utf8'));
  check('a merged-away default record hands the role to its keeper',
    afterDefaultMove.global.defaultWorkspaceId === 'k-old',
    `${afterDefaultMove.global.defaultWorkspaceId} (order ${JSON.stringify(afterDefaultMove.global.workspaceIds)})`);

} catch (error) {
  // An exception is a check failure, not a silent early exit: the earlier
  // version of this file swallowed one and printed 12/12 while half the checks
  // had never run.
  checks.push({ name: 'the unit run itself completes', ok: false, detail: String(error && error.stack ? error.stack.split('\n').slice(0, 3).join(' | ') : error) });
} finally {
  const failed = checks.filter((c) => !c.ok);
  for (const c of checks) console.log(`${c.ok ? 'PASS' : 'FAIL'}  ${c.name}${c.detail ? '  [' + c.detail + ']' : ''}`);
  console.log(`\n${checks.length - failed.length}/${checks.length} checks passed`);
  rmSync(root, { recursive: true, force: true });
  process.exit(failed.length === 0 ? 0 : 1);
}
