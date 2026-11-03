// Streaming `fetch` polyfill for a jitless (iOS) Node.
//
// WHY: `node --jitless` removes WebAssembly entirely (measured:
// `typeof WebAssembly === 'undefined'`). Node's built-in `fetch` is undici, and
// undici compiles its llhttp HTTP parser from WebAssembly. The first `fetch()`
// therefore rejects with `TypeError: fetch failed` / cause
// `ReferenceError: WebAssembly is not defined` — before any socket is opened.
// Every model request in DSH goes through global `fetch`, so without this the
// chat is dead on iOS.
//
// WHAT: a `fetch` built directly on `node:http` / `node:https` that returns a
// real WHATWG `Response` with a REAL STREAMING `body` (a ReadableStream fed by
// the response chunk by chunk). Streaming matters: the LLM route is SSE, and a
// buffered body would turn token streaming into one final blob.
//
// Two implementation notes carried over from dsh-ios's working version:
//   1. `globalThis.fetch` is an accessor on the Node global object. A plain
//      assignment can trip Node's own lazy-undici getter; use
//      `Object.defineProperty` with `configurable: true` instead.
//   2. `http`/`https` are required lazily inside the call. Eagerly importing
//      them at preload time adds measurable startup cost on a slow device.
//
// Limits, stated rather than hidden:
//   * request bodies: string / Uint8Array / ArrayBuffer / URLSearchParams /
//     Blob are supported; a ReadableStream request body is not (DSH never sends
//     one — every model request is a JSON string).
//   * `Response.redirected` / `Response.type` are approximated, not real.
//   * HTTP/2 is not attempted; the OpenAI-compatible endpoint speaks HTTP/1.1.

'use strict';

const { defineProperty } = Object;

/** Lazily resolved node:http / node:https, so preload stays cheap. */
let httpMod;
let httpsMod;
function transports() {
  if (httpMod === undefined) {
    httpMod = require('node:http');
    httpsMod = require('node:https');
  }
  return { http: httpMod, https: httpsMod };
}

const REDIRECT_STATUS = new Set([301, 302, 303, 307, 308]);

/** Headers that identify the caller and must not follow a redirect to another origin. */
const SENSITIVE_HEADER = /^(authorization|proxy-authorization|cookie|x-api-key|api-key|x-goog-api-key)$|(^|-)(token|secret|api-?key)$/i;

/**
 * Decide the request a redirect leads to.
 *
 * Cross-origin hops lose every credential-bearing header, and a request body is
 * never resent to another origin: for a model request that body is the
 * conversation. An HTTPS request never continues over plain HTTP.
 *
 * @param {object} hop - from, to (URLs), status, method, headers, body.
 * @returns {{ method: string, headers: Record<string, string>, body: unknown }} the next request.
 * @throws {TypeError} when the redirect must not be followed.
 */
function followRedirect({ from, to, status, method, headers, body }) {
  if (to.protocol !== 'http:' && to.protocol !== 'https:') {
    throw new TypeError(`ios-sim fetch polyfill: refusing redirect to ${to.protocol}`);
  }
  if (from.protocol === 'https:' && to.protocol === 'http:') {
    throw new TypeError('ios-sim fetch polyfill: refusing redirect from HTTPS to HTTP');
  }
  const next = { method, headers: { ...headers }, body };
  if (status === 303 || ((status === 301 || status === 302) && method === 'POST')) {
    if (method !== 'HEAD') next.method = 'GET';
    next.body = undefined;
    for (const name of Object.keys(next.headers)) {
      if (name.startsWith('content-')) delete next.headers[name];
    }
  }
  if (from.origin !== to.origin) {
    if (next.body !== undefined && next.body !== null) {
      throw new TypeError('ios-sim fetch polyfill: refusing to resend a request body to another origin');
    }
    for (const name of Object.keys(next.headers)) {
      if (SENSITIVE_HEADER.test(name)) delete next.headers[name];
    }
  }
  return next;
}

/**
 * Body bytes for a `RequestInit.body`.
 * @param {unknown} body - the caller's body value.
 * @returns {{ payload?: Buffer, contentType?: string }} what to write.
 */
function encodeBody(body) {
  if (body === undefined || body === null) return {};
  if (typeof body === 'string') return { payload: Buffer.from(body, 'utf8') };
  if (Buffer.isBuffer(body)) return { payload: body };
  if (body instanceof ArrayBuffer) return { payload: Buffer.from(body) };
  if (ArrayBuffer.isView(body)) return { payload: Buffer.from(body.buffer, body.byteOffset, body.byteLength) };
  if (typeof URLSearchParams !== 'undefined' && body instanceof URLSearchParams) {
    return { payload: Buffer.from(body.toString(), 'utf8'), contentType: 'application/x-www-form-urlencoded;charset=UTF-8' };
  }
  if (typeof Blob !== 'undefined' && body instanceof Blob) return { payload: Buffer.from('') };
  if (typeof body === 'object' && typeof body[Symbol.asyncIterator] === 'function') {
    throw new TypeError('ios-sim fetch polyfill: streaming request bodies are not supported');
  }
  return { payload: Buffer.from(String(body), 'utf8') };
}

/**
 * Flatten a `HeadersInit` into a plain object of string values.
 * @param {unknown} init - Headers, array of pairs, or record.
 * @returns {Record<string, string>} header map.
 */
function flattenHeaders(init) {
  /** @type {Record<string, string>} */
  const out = {};
  if (init === undefined || init === null) return out;
  if (typeof init.forEach === 'function' && typeof init.get === 'function') {
    init.forEach((value, name) => { out[String(name).toLowerCase()] = String(value); });
    return out;
  }
  if (Array.isArray(init)) {
    for (const pair of init) if (Array.isArray(pair) && pair.length === 2) out[String(pair[0]).toLowerCase()] = String(pair[1]);
    return out;
  }
  for (const [name, value] of Object.entries(init)) out[String(name).toLowerCase()] = String(value);
  return out;
}

/**
 * One HTTP(S) exchange, resolving once response headers arrive.
 * @param {string} target - absolute URL.
 * @param {object} init - normalized request options.
 * @returns {Promise<{ status:number, statusText:string, headers:Record<string,string>, rawIncoming:import('node:http').IncomingMessage, url:string }>}
 */
function beginRequest(target, init) {
  return new Promise((resolve, reject) => {
    let url;
    try {
      url = new URL(target);
    } catch (error) {
      reject(new TypeError(`ios-sim fetch polyfill: invalid URL ${JSON.stringify(target)}`));
      return;
    }
    const { http, https } = transports();
    const secure = url.protocol === 'https:';
    if (!secure && url.protocol !== 'http:') {
      reject(new TypeError(`ios-sim fetch polyfill: unsupported protocol ${url.protocol}`));
      return;
    }
    const client = secure ? https : http;
    const headers = { ...init.headers };
    const { payload, contentType } = encodeBody(init.body);
    if (payload !== undefined) {
      headers['content-length'] = String(payload.length);
      if (contentType !== undefined && headers['content-type'] === undefined) headers['content-type'] = contentType;
    }
    const request = client.request({
      protocol: url.protocol,
      hostname: url.hostname,
      port: url.port === '' ? undefined : Number(url.port),
      path: `${url.pathname}${url.search}`,
      method: init.method,
      headers,
      // Model endpoints behind the OpenDesign/DeepSeek routes use standard
      // certificates; SNI must carry the hostname, not the IP.
      servername: secure ? url.hostname : undefined,
      // Keep-alive agents are created per call; DSH requests are long-lived SSE
      // streams, so pooling buys little and complicates abort.
      agent: init.agent,
    }, (res) => {
      /** @type {Record<string,string>} */
      const flat = {};
      for (const [name, value] of Object.entries(res.headers)) {
        if (value === undefined) continue;
        flat[name.toLowerCase()] = Array.isArray(value) ? value.join(', ') : String(value);
      }
      resolve({
        status: res.statusCode ?? 0,
        statusText: res.statusMessage ?? '',
        headers: flat,
        rawIncoming: res,
        url: url.href,
      });
    });
    request.on('error', (error) => {
      reject(new TypeError(`ios-sim fetch polyfill: request failed: ${error.message}`, { cause: error }));
    });
    if (init.signal !== undefined && init.signal !== null) {
      if (init.signal.aborted) {
        request.destroy(new Error('aborted'));
        reject(new DOMException('The operation was aborted.', 'AbortError'));
        return;
      }
      init.signal.addEventListener('abort', () => {
        request.destroy(new Error('aborted'));
      }, { once: true });
    }
    if (payload !== undefined) request.write(payload);
    request.end();
  });
}

/**
 * Wrap a Node `IncomingMessage` as a WHATWG `ReadableStream` of Uint8Array.
 * Chunks are forwarded as they arrive, which is what keeps SSE streaming live.
 * @param {import('node:http').IncomingMessage} incoming - the live response.
 * @returns {ReadableStream<Uint8Array>} the body stream.
 */
function bodyStreamOf(incoming) {
  return new ReadableStream({
    start(controller) {
      incoming.on('data', (chunk) => {
        try {
          controller.enqueue(new Uint8Array(chunk.buffer, chunk.byteOffset, chunk.byteLength));
        } catch {
          // The consumer cancelled; stop feeding it.
          incoming.destroy();
        }
      });
      incoming.on('end', () => {
        try { controller.close(); } catch { /* already closed */ }
      });
      incoming.on('error', (error) => {
        try { controller.error(error); } catch { /* already errored */ }
      });
      incoming.on('aborted', () => {
        try { controller.error(new DOMException('The operation was aborted.', 'AbortError')); } catch { /* already errored */ }
      });
    },
    cancel() {
      incoming.destroy();
    },
  });
}

/**
 * `fetch` replacement. Follows redirects up to `redirectLimit`, exposes a
 * streaming body, and mirrors the headers object onto a real `Headers`.
 * @param {string|URL} input - request URL.
 * @param {object} [init] - standard RequestInit subset.
 * @returns {Promise<Response>} the response.
 */
async function iosFetch(input, init = {}) {
  const started = Date.now();
  const href = input instanceof URL ? input.href : String(input);
  let target = href;
  let method = (init.method ?? 'GET').toUpperCase();
  let body = init.body;
  let headers = flattenHeaders(init.headers);
  const redirect = init.redirect ?? 'follow';
  const maxRedirects = 10;

  for (let hop = 0; hop <= maxRedirects; hop += 1) {
    const outcome = await beginRequest(target, {
      method,
      headers,
      body,
      signal: init.signal,
      agent: init.agent,
    });
    const location = outcome.headers.location;
    const redirected = REDIRECT_STATUS.has(outcome.status) && typeof location === 'string' && location !== '';
    if (redirected && redirect === 'error') {
      outcome.rawIncoming.destroy();
      throw new TypeError('ios-sim fetch polyfill: redirect refused by redirect: "error"');
    }
    if (redirected && redirect === 'follow') {
      outcome.rawIncoming.destroy();
      if (hop === maxRedirects) throw new TypeError('ios-sim fetch polyfill: too many redirects');
      const from = new URL(outcome.url);
      const to = new URL(location, from);
      ({ method, headers, body } = followRedirect({ from, to, status: outcome.status, method, headers, body }));
      target = to.href;
      continue;
    }
    /** @type {HeadersInit} */
    const headerInit = [];
    for (const [name, value] of Object.entries(outcome.headers)) {
      if (name === 'content-encoding' || name === 'transfer-encoding') continue;
      headerInit.push([name, value]);
    }
    const response = new Response(outcome.status === 204 || outcome.status === 304 ? null : bodyStreamOf(outcome.rawIncoming), {
      status: outcome.status,
      statusText: outcome.statusText,
      headers: headerInit,
    });
    // Node's Response rejects a 204/304 body, so those were passed as null above.
    defineProperty(response, 'url', { value: outcome.url, configurable: true });
    if (process.env.IOS_SIM_FETCH_TRACE === '1') {
      process.stderr.write(`[ios-sim fetch] ${method} ${outcome.url} -> ${outcome.status} (${Date.now() - started}ms, ${redirect})\n`);
    }
    return response;
  }
  throw new TypeError('ios-sim fetch polyfill: too many redirects');
}

/**
 * Install the polyfill on the global object.
 * @returns {{ installed: boolean, previous: string }} what happened.
 */
function install() {
  const previous = typeof globalThis.fetch === 'function' ? 'native' : 'absent';
  // An accessor, not a data property: a plain assignment can wake Node's own
  // lazy undici getter, which is what crashes on jitless.
  defineProperty(globalThis, 'fetch', {
    value: iosFetch,
    configurable: true,
    writable: true,
    enumerable: false,
  });
  return { installed: true, previous };
}

module.exports = { iosFetch, install, beginRequest, bodyStreamOf, flattenHeaders, encodeBody, followRedirect };
