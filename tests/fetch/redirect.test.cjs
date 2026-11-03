// Redirect handling of the iOS fetch polyfill. Run with: node --test tests/fetch/
'use strict';
const assert = require('node:assert/strict');
const http = require('node:http');
const { test } = require('node:test');
const { iosFetch, followRedirect } = require('../../sim/fetch-polyfill.cjs');

function serve(handler) {
  return new Promise((resolve) => {
    const server = http.createServer(handler);
    server.listen(0, '127.0.0.1', () => resolve({ server, origin: `http://127.0.0.1:${server.address().port}` }));
  });
}

const auth = { authorization: 'Bearer fake', cookie: 'a=b', 'x-api-key': 'fake', 'x-goog-api-key': 'fake', accept: 'text/plain' };

test('credentials do not follow a redirect to another origin', async () => {
  const seen = [];
  const b = await serve((req, res) => { seen.push(req.headers); res.end('ok'); });
  const a = await serve((req, res) => { res.writeHead(302, { location: `${b.origin}/next` }); res.end(); });
  const response = await iosFetch(`${a.origin}/start`, { headers: auth });
  assert.equal(await response.text(), 'ok');
  for (const name of ['authorization', 'cookie', 'x-api-key', 'x-goog-api-key']) assert.equal(seen[0][name], undefined, name);
  assert.equal(seen[0].accept, 'text/plain');
  a.server.close(); b.server.close();
});

test('credentials stay on a same-origin redirect', async () => {
  const seen = [];
  const a = await serve((req, res) => {
    if (req.url === '/start') { res.writeHead(307, { location: '/next' }); res.end(); return; }
    seen.push(req.headers);
    res.end('ok');
  });
  await (await iosFetch(`${a.origin}/start`, { method: 'POST', headers: auth, body: 'x' })).text();
  assert.equal(seen[0].authorization, 'Bearer fake');
  a.server.close();
});

test('a body is not resent to another origin', async () => {
  let reached = false;
  const b = await serve((req, res) => { reached = true; res.end('ok'); });
  const a = await serve((req, res) => { res.writeHead(307, { location: `${b.origin}/next` }); res.end(); });
  await assert.rejects(iosFetch(`${a.origin}/start`, { method: 'POST', headers: auth, body: 'secret' }), /another origin/);
  assert.equal(reached, false);
  a.server.close(); b.server.close();
});

test('POST becomes GET without a body on 301, 302 and 303', () => {
  for (const status of [301, 302, 303]) {
    const next = followRedirect({
      from: new URL('https://a.example/'), to: new URL('https://b.example/'), status,
      method: 'POST', headers: { 'content-type': 'text/plain', authorization: 'x' }, body: 'secret',
    });
    assert.equal(next.method, 'GET');
    assert.equal(next.body, undefined);
    assert.deepEqual(next.headers, {});
  }
});

test('HTTPS does not continue over HTTP', () => {
  assert.throws(() => followRedirect({
    from: new URL('https://a.example/'), to: new URL('http://a.example/'), status: 302, method: 'GET', headers: {},
  }), /HTTPS to HTTP/);
});

test('redirect: "error" refuses and "manual" returns the redirect', async () => {
  const a = await serve((req, res) => { res.writeHead(302, { location: '/next' }); res.end(); });
  await assert.rejects(iosFetch(`${a.origin}/start`, { redirect: 'error' }), /redirect/);
  const manual = await iosFetch(`${a.origin}/start`, { redirect: 'manual' });
  assert.equal(manual.status, 302);
  await manual.text();
  a.server.close();
});
