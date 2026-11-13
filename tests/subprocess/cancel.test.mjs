import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { IshSubprocessRuntime } from '../../plugins/dsh-subprocess-ish/index.mjs';
import { CHANNEL_LAUNCH_FAILURE } from '../../plugins/dsh-subprocess-ish/lib/guest-channel.mjs';

const execId = 'cancel-test';

function channel(t, answers) {
  const saved = [process.env.DSH_GUEST_CHANNEL_URL, process.env.DSH_GUEST_CHANNEL_TOKEN];
  process.env.DSH_GUEST_CHANNEL_URL = 'http://127.0.0.1:1';
  process.env.DSH_GUEST_CHANNEL_TOKEN = 'test-token';
  t.after(() => {
    for (const [i, key] of ['DSH_GUEST_CHANNEL_URL', 'DSH_GUEST_CHANNEL_TOKEN'].entries()) {
      if (saved[i] === undefined) delete process.env[key];
      else process.env[key] = saved[i];
    }
  });
  let now = 0;
  let calls = 0;
  let requestedId = execId;
  const warnings = [];
  t.mock.method(Date, 'now', () => now);
  t.mock.method(globalThis, 'setTimeout', (callback, delay) => {
    now += delay;
    queueMicrotask(callback);
    return 0;
  });
  t.mock.method(globalThis, 'fetch', async (url, options) => {
    assert.equal(url, 'http://127.0.0.1:1/v1/cancel');
    assert.deepEqual(JSON.parse(options.body), { execId: requestedId });
    const answer = answers[Math.min(calls++, answers.length - 1)];
    if (answer instanceof Error) throw answer;
    return { ok: true, json: async () => ({ execId: requestedId, ...answer }) };
  });
  const runtime = Object.assign(Object.create(IshSubprocessRuntime.prototype), {
    ctx: { logger: { warn: (line) => warnings.push(line), debug() {} } },
    live: new Set(),
    _queue: Promise.resolve(),
    _execSeq: 0,
    _spill: {},
    _guestRg: null,
  });
  return {
    runtime,
    // The callback reproduces the old HTTP-settled shortcut on the baseline.
    terminate: () => runtime._terminate(execId, () => true),
    calls: () => calls,
    setExecId: (id) => { requestedId = id; },
    warnings,
  };
}

function response(event) {
  let sent = false;
  return {
    ok: true,
    body: {
      getReader: () => ({
        read: async () => {
          if (sent) return { done: true };
          sent = true;
          return { value: Buffer.from(JSON.stringify(event) + '\n'), done: false };
        },
      }),
    },
  };
}

function spawn(runtime, signal) {
  return runtime.spawn({ argv: ['/bin/sh', '-c', 'true'], cwd: '/tmp', stdio: {}, graceMs: 100, signal });
}

for (const [name, answers] of [
  ['an aborted HTTP call does not prove a queued guest exited', [
    { cancelled: false, state: 'unknown' },
    { cancelled: true, state: 'pending-cancelled' },
  ]],
  ['cancellation before task_start prevents execution', [
    { cancelled: true, state: 'pending-cancelled' },
  ]],
  ['a running guest is polled until completion', [
    { cancelled: true, state: 'running' },
    { cancelled: true, state: 'running' },
    { cancelled: false, state: 'finished' },
  ]],
  ['an id disappearing after a running acknowledgement has finished', [
    { cancelled: true, state: 'running' },
    { cancelled: false, state: 'unknown' },
  ]],
  ['a late cancel can use a retained completion', [
    { cancelled: false, state: 'finished' },
  ]],
  ['an answer for another exec cannot acknowledge this cancellation', [
    { execId: 'another-exec', cancelled: true, state: 'pending-cancelled' },
    { cancelled: true, state: 'pending-cancelled' },
  ]],
]) {
  test(name, async (t) => {
    const c = channel(t, answers);
    assert.equal(await c.terminate(), true);
    assert.equal(c.calls(), answers.length);
    assert.deepEqual(c.warnings, []);
  });
}

for (const answer of [{ cancelled: false, state: 'unknown' }, { cancelled: false }]) {
  test('an unknown id or a legacy boolean cannot prove quiescence: ' + JSON.stringify(answer), async (t) => {
    const c = channel(t, [answer]);
    assert.equal(await c.terminate(), false);
    assert.ok(c.calls() > 1);
    assert.equal(c.warnings.length, 1);
  });
}

test('a broken cancel transport reports an unknown exit', async (t) => {
  const c = channel(t, [new Error('connection lost')]);
  assert.equal(await c.terminate(), false);
  assert.match(c.warnings[0], /may still be running/);
});

test('abort waits for the guest after the exec HTTP promise rejects', async (t) => {
  const c = channel(t, [
    { cancelled: false, state: 'unknown' },
    { cancelled: true, state: 'pending-cancelled' },
  ]);
  const cancelFetch = globalThis.fetch;
  const received = Promise.withResolvers();
  t.mock.method(globalThis, 'fetch', (url, options) => {
    if (!url.endsWith('/v1/exec')) return cancelFetch(url, options);
    c.setExecId(JSON.parse(options.body).execId);
    received.resolve();
    return new Promise((resolve, reject) => {
      options.signal.addEventListener('abort', () => reject(options.signal.reason), { once: true });
    });
  });
  const controller = new AbortController();
  const handle = spawn(c.runtime, controller.signal);
  await received.promise;
  controller.abort(new Error('stopped'));
  await assert.rejects(handle.done, /stopped/);
  assert.equal(await handle.waitForExit(), true);
  assert.equal(c.calls(), 2);
});

test('a launchError exit needs no cancel even if the id would be unknown', async (t) => {
  const c = channel(t, [{ cancelled: false, state: 'unknown' }]);
  const cancelFetch = globalThis.fetch;
  t.mock.method(globalThis, 'fetch', async (url, options) => {
    if (!url.endsWith('/v1/exec')) return cancelFetch(url, options);
    return response({ type: 'exit', exitCode: -1, pid: -1, launchError: 'cannot enter cwd' });
  });
  const handle = spawn(c.runtime);
  await assert.rejects(handle.done, { code: CHANNEL_LAUNCH_FAILURE });
  assert.equal(await handle.waitForExit(), true);
  assert.equal(c.calls(), 0);
  assert.deepEqual(c.warnings, []);
  assert.equal(c.runtime.live.size, 0);
});

test('transport failure retains the live handle until the guest acknowledges exit', async (t) => {
  const c = channel(t, []);
  const acknowledged = Promise.withResolvers();
  t.mock.method(globalThis, 'fetch', async (url, options) => {
    const id = JSON.parse(options.body).execId;
    if (url.endsWith('/v1/exec')) throw new Error('connection lost');
    assert.ok(url.endsWith('/v1/cancel'));
    await acknowledged.promise;
    return { ok: true, json: async () => ({ execId: id, state: 'finished', cancelled: false }) };
  });
  const handle = spawn(c.runtime);
  await assert.rejects(handle.done, /connection lost/);
  assert.ok(c.runtime.live.has(handle));
  acknowledged.resolve();
  assert.equal(await handle.waitForExit(), true);
  assert.equal(c.runtime.live.size, 0);
});

test('busy retries tolerate an id still awaiting channel cleanup', async (t) => {
  const c = channel(t, []);
  let calls = 0;
  const responses = [
    { ok: false, status: 500, text: async () => 'a guest command is already running' },
    { ok: false, status: 409, text: async () => 'execId is already active' },
    response({ type: 'exit', exitCode: 0, pid: 2 }),
  ];
  t.mock.method(globalThis, 'fetch', async (url) => {
    assert.ok(url.endsWith('/v1/exec'));
    return responses[calls++];
  });
  const handle = spawn(c.runtime);
  assert.deepEqual(await handle.done, { exitCode: 0, signal: null });
  assert.equal(calls, 3);
});
