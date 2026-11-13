// The WebAssembly-free transport behind `web_fetch` on iOS, and the hook that
// installs it. Run with: node --test tests/fetch/   (also passes under --jitless)
import assert from 'node:assert/strict';
import http from 'node:http';
import zlib from 'node:zlib';
import { test } from 'node:test';
import { Agent, fetch } from '../../sim/undici-web-fetch.mjs';
import { isWebFetchUndici, resolve } from '../../sim/undici-hook.mjs';

function serve(handler) {
  return new Promise((done) => {
    const server = http.createServer(handler);
    server.listen(0, '127.0.0.1', () => done({ server, port: server.address().port }));
  });
}

/** A pinned lookup that records what it was asked and always answers loopback. */
function pinned(asked) {
  return (hostname, options, callback) => {
    asked.push(hostname);
    if (options.all === true) callback(null, [{ address: '127.0.0.1', family: 4 }]);
    else callback(null, '127.0.0.1', 4);
  };
}

test('an HTTP/1.1 response is read through the pinned lookup, Host intact', async () => {
  let host;
  const { server, port } = await serve((req, res) => { host = req.headers.host; res.setHeader('content-type', 'text/html'); res.end('<p>ok</p>'); });
  const asked = [];
  const dispatcher = new Agent({ autoSelectFamily: true, connect: { lookup: pinned(asked) } });
  const response = await fetch(new URL(`http://pinned.example:${port}/a?b=1`), { method: 'GET', redirect: 'manual', headers: { 'user-agent': 'x' }, dispatcher });
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('content-type'), 'text/html');
  assert.equal(await response.text(), '<p>ok</p>');
  assert.deepEqual(asked, ['pinned.example']);
  assert.equal(host, `pinned.example:${port}`);
  await dispatcher.close();
  server.close();
});

for (const [coding, encode] of [['gzip', zlib.gzipSync], ['deflate', zlib.deflateSync], ['br', zlib.brotliCompressSync]]) {
  test(`a ${coding} body is decoded`, async () => {
    const { server, port } = await serve((req, res) => {
      assert.match(req.headers['accept-encoding'], /gzip/);
      res.writeHead(200, { 'content-type': 'text/plain', 'content-encoding': coding });
      res.end(encode(Buffer.from('压缩内容 '.repeat(500))));
    });
    const dispatcher = new Agent({ connect: { lookup: pinned([]) } });
    const response = await fetch(`http://z.example:${port}/`, { dispatcher });
    assert.equal(await response.text(), '压缩内容 '.repeat(500));
    await dispatcher.close();
    server.close();
  });
}

test('a redirect is returned, not followed', async () => {
  let hits = 0;
  const { server, port } = await serve((req, res) => { hits += 1; res.writeHead(302, { location: '/next' }); res.end(); });
  const dispatcher = new Agent({ connect: { lookup: pinned([]) } });
  const response = await fetch(`http://r.example:${port}/`, { redirect: 'manual', dispatcher });
  assert.equal(response.status, 302);
  assert.equal(response.headers.get('location'), '/next');
  await response.body?.cancel();
  assert.equal(hits, 1);
  await dispatcher.close();
  server.close();
});

test('a connection failure names its cause', async () => {
  const { server, port } = await serve(() => {});
  await new Promise((done) => server.close(done));
  const dispatcher = new Agent({ connect: { lookup: pinned([]) } });
  await assert.rejects(fetch(`http://down.example:${port}/`, { dispatcher }), (error) => {
    assert.equal(error.name, 'TypeError');
    assert.match(error.message, /^fetch failed: .*ECONNREFUSED/);
    assert.equal(error.cause.code, 'ECONNREFUSED');
    return true;
  });
  await dispatcher.close();
});

test('an abort rejects with the signal reason and frees the socket', async () => {
  const { server, port } = await serve(() => { /* never answers */ });
  const dispatcher = new Agent({ connect: { lookup: pinned([]) } });
  const controller = new AbortController();
  const reason = new Error('deadline');
  const pending = fetch(`http://slow.example:${port}/`, { dispatcher, signal: controller.signal });
  setTimeout(() => controller.abort(reason), 50);
  await assert.rejects(pending, (error) => error === reason);
  assert.equal(dispatcher.requests.size, 0);
  server.closeAllConnections();
  server.close();
});

test('close() cuts a body that is still streaming', async () => {
  const { server, port } = await serve((req, res) => { res.writeHead(200, { 'content-type': 'text/plain' }); res.write('first'); });
  const dispatcher = new Agent({ connect: { lookup: pinned([]) } });
  const response = await fetch(`http://open.example:${port}/`, { dispatcher });
  const reader = response.body.getReader();
  assert.equal(Buffer.from((await reader.read()).value).toString(), 'first');
  await dispatcher.close();
  await assert.rejects(reader.read());
  server.closeAllConnections();
  server.close();
});

test('only dsh-web-fetch-http importing undici is redirected', async () => {
  const importer = 'file:///x/node_modules/@deepseek-ai/dsh-web-fetch-http/lib/index.js';
  assert.equal(isWebFetchUndici('undici', importer), true);
  assert.equal(isWebFetchUndici('undici', 'file:///x/node_modules/@deepseek-ai/dsh-http-proxy/lib/index.js'), false);
  assert.equal(isWebFetchUndici('undici-types', importer), false);
  assert.equal(isWebFetchUndici('undici', undefined), false);
  const next = async (specifier) => ({ url: `file:///real/${specifier}/index.js` });
  const redirected = await resolve('undici', { parentURL: importer }, next);
  assert.equal(redirected.shortCircuit, true);
  assert.match(redirected.url, /sim\/undici-web-fetch\.mjs\?real=file%3A%2F%2F%2Freal%2Fundici%2Findex\.js$/);
  assert.deepEqual(await resolve('undici', { parentURL: 'file:///other.js' }, next), { url: 'file:///real/undici/index.js' });
});
