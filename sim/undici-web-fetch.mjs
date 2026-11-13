// Stand-in for `undici`, installed by `sim/undici-hook.mjs` for exactly one
// importer: `@deepseek-ai/dsh-web-fetch-http`.
//
// It exports the two names that importer uses, `Agent` and `fetch`, built on
// `node:http` / `node:https` so no WebAssembly parser is involved.
//
// What is preserved from the real thing, because the importer relies on it:
//   * the Agent's `connect.lookup` is the ONLY source of addresses. The provider
//     validates one DNS answer set as public and pins the connection to it; this
//     transport passes that same callback to the socket and never resolves again.
//   * the URL hostname stays the HTTP Host and the TLS server name.
//   * `redirect: 'manual'`: a 3xx is returned as it is; the provider follows it.
//   * the body is a real stream, decoded from gzip/deflate/br like `fetch` does,
//     so the provider's byte cap still cuts a large response short.
//   * a failure rejects with `TypeError` carrying the socket error as `cause`.
//
// One deliberate difference: the message names the cause
// (`fetch failed: ECONNRESET …`). The provider prints only `String(error)`, and a
// bare "fetch failed" is what made this bug unreadable from the transcript.
//
// HTTP/2 is not attempted. A dispatcher this module did not create (the proxy
// policy's) is handed to the real package untouched.

import http from 'node:http';
import https from 'node:https';
import zlib from 'node:zlib';

const REAL_UNDICI_URL = new URL(import.meta.url).searchParams.get('real') ?? '';

/** Statuses whose `Response` must be built with a null body. */
const NULL_BODY_STATUS = new Set([101, 204, 205, 304]);

/**
 * The pinned-lookup dispatcher the provider creates per request.
 *
 * Only `connect.lookup` and `autoSelectFamily` are read; they are the only options
 * the provider passes.
 */
export class Agent {
  /** @param {{ autoSelectFamily?: boolean, connect?: { lookup?: Function } }} [options] - undici Agent options. */
  constructor(options = {}) {
    this.lookup = options.connect?.lookup;
    this.autoSelectFamily = options.autoSelectFamily === true;
    /** @type {Set<import('node:http').ClientRequest>} */
    this.requests = new Set();
  }

  /** Tear down whatever is still open; the provider calls this after every hop. */
  async close() {
    for (const request of this.requests) request.destroy();
    this.requests.clear();
  }

  /** Same as {@link Agent.close}; present because undici dispatchers have both. */
  async destroy() {
    await this.close();
  }
}

/**
 * A decoder for one `Content-Encoding` token, or undefined for identity/unknown.
 * @param {string} token - a single lower-cased coding.
 * @returns {import('node:stream').Transform|undefined} the decoder stream.
 */
function decoderFor(token) {
  if (token === 'gzip' || token === 'x-gzip') return zlib.createGunzip({ flush: zlib.constants.Z_SYNC_FLUSH, finishFlush: zlib.constants.Z_SYNC_FLUSH });
  if (token === 'deflate') return zlib.createInflate({ flush: zlib.constants.Z_SYNC_FLUSH, finishFlush: zlib.constants.Z_SYNC_FLUSH });
  if (token === 'br') return zlib.createBrotliDecompress();
  if (token === 'zstd' && typeof zlib.createZstdDecompress === 'function') return zlib.createZstdDecompress();
  return undefined;
}

/**
 * The response body as a byte stream with content codings removed.
 * @param {import('node:http').IncomingMessage} incoming - the live response.
 * @returns {import('node:stream').Readable} decoded bytes.
 */
function decodedBody(incoming) {
  const codings = String(incoming.headers['content-encoding'] ?? '')
    .split(',').map((token) => token.trim().toLowerCase()).filter((token) => token !== '' && token !== 'identity');
  /** @type {import('node:stream').Readable} */
  let stream = incoming;
  // Codings are listed in the order applied, so they are undone last to first.
  for (const token of codings.reverse()) {
    const decoder = decoderFor(token);
    if (decoder === undefined) break;
    const source = stream;
    source.on('error', (error) => decoder.destroy(error));
    stream = source.pipe(decoder);
  }
  return stream;
}

/**
 * Wrap a Node readable as a WHATWG stream of Uint8Array.
 * @param {import('node:stream').Readable} readable - decoded response bytes.
 * @param {() => void} release - called once the body is finished or abandoned.
 * @returns {ReadableStream<Uint8Array>} the body stream.
 */
function webStreamOf(readable, release) {
  return new ReadableStream({
    start(controller) {
      readable.on('data', (chunk) => {
        try {
          controller.enqueue(new Uint8Array(chunk.buffer, chunk.byteOffset, chunk.byteLength));
        } catch {
          readable.destroy();
        }
      });
      readable.on('end', () => {
        release();
        try { controller.close(); } catch { /* already closed */ }
      });
      readable.on('error', (error) => {
        release();
        try { controller.error(error); } catch { /* already errored */ }
      });
    },
    cancel() {
      release();
      readable.destroy();
    },
  });
}

/**
 * Response headers as `fetch` exposes them: one entry per field line.
 * @param {import('node:http').IncomingMessage} incoming - the live response.
 * @returns {Headers} the header list.
 */
function headersOf(incoming) {
  const headers = new Headers();
  const raw = incoming.rawHeaders;
  for (let index = 0; index + 1 < raw.length; index += 2) {
    try {
      headers.append(raw[index], raw[index + 1]);
    } catch {
      // A field the Headers class refuses (bad bytes) is dropped, not fatal.
    }
  }
  return headers;
}

/**
 * Short, greppable description of a socket-level failure.
 * @param {unknown} error - what the request emitted.
 * @returns {string} code and message.
 */
function describe(error) {
  if (error === null || typeof error !== 'object') return String(error);
  const code = typeof error.code === 'string' ? error.code : '';
  const message = typeof error.message === 'string' ? error.message : '';
  if (code !== '' && message.includes(code)) return message;
  return [code, message].filter((part) => part !== '').join(' ');
}

/**
 * One GET through a pinned-lookup {@link Agent}.
 * @param {URL} url - validated HTTP(S) URL.
 * @param {object} init - `{ method, headers, signal, dispatcher }`.
 * @returns {Promise<Response>} resolves when response headers arrive.
 */
function requestPinned(url, init) {
  const agent = init.dispatcher;
  const { signal } = init;
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(signal.reason ?? new DOMException('The operation was aborted.', 'AbortError'));
      return;
    }
    const secure = url.protocol === 'https:';
    if (!secure && url.protocol !== 'http:') {
      reject(new TypeError(`fetch failed: unsupported protocol ${url.protocol}`));
      return;
    }
    const hostname = url.hostname.startsWith('[') ? url.hostname.slice(1, -1) : url.hostname;
    const headers = { 'accept-encoding': 'gzip, deflate, br' };
    for (const [name, value] of Object.entries(init.headers ?? {})) headers[name.toLowerCase()] = String(value);
    const request = (secure ? https : http).request({
      protocol: url.protocol,
      hostname,
      port: url.port === '' ? undefined : Number(url.port),
      path: `${url.pathname}${url.search}`,
      method: init.method ?? 'GET',
      headers,
      // One connection per request, closed with it: nothing outlives the pinned
      // address set it was opened for.
      agent: false,
      lookup: agent.lookup,
      autoSelectFamily: agent.autoSelectFamily,
    });
    agent.requests.add(request);
    const release = () => {
      agent.requests.delete(request);
      signal?.removeEventListener('abort', onAbort);
    };
    let settled = false;
    function onAbort() {
      const reason = signal.reason ?? new DOMException('The operation was aborted.', 'AbortError');
      request.destroy(reason);
      if (!settled) {
        settled = true;
        release();
        reject(reason);
      }
    }
    signal?.addEventListener('abort', onAbort, { once: true });
    request.on('error', (error) => {
      if (settled) return;
      settled = true;
      release();
      reject(new TypeError(`fetch failed: ${describe(error)}`, { cause: error }));
    });
    request.on('response', (incoming) => {
      settled = true;
      const status = incoming.statusCode ?? 0;
      let body = null;
      if (NULL_BODY_STATUS.has(status)) {
        incoming.resume();
        release();
      } else {
        body = webStreamOf(decodedBody(incoming), release);
      }
      try {
        resolve(new Response(body, { status, statusText: incoming.statusMessage ?? '', headers: headersOf(incoming) }));
      } catch (error) {
        release();
        incoming.destroy();
        reject(new TypeError(`fetch failed: ${describe(error)}`, { cause: error }));
      }
    });
    request.end();
  });
}

/**
 * `undici.fetch` for the one importer this module serves.
 * @param {string|URL} input - request URL.
 * @param {object} [init] - `{ method, redirect, headers, signal, dispatcher }`.
 * @returns {Promise<Response>} the response; a 3xx is returned unfollowed.
 */
export async function fetch(input, init = {}) {
  if (init.dispatcher instanceof Agent) {
    return requestPinned(input instanceof URL ? input : new URL(String(input)), init);
  }
  // Not ours: the proxy policy's dispatcher, which only the real package can drive.
  if (REAL_UNDICI_URL === '') throw new TypeError('fetch failed: undici is not available for a proxied web fetch on this platform');
  const real = await import(REAL_UNDICI_URL);
  return real.fetch(input, init);
}
