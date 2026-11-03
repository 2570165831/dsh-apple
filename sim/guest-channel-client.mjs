// The Node half of the guest channel.
//
// WHY THIS FILE EXISTS: the guest kernel runs in the Swift/Objective-C half of
// this process and may only be entered from its own serial queue. Node cannot
// call it directly (see ISHGuestChannel.h for why), so the two halves talk over
// a loopback HTTP server with a bearer token. This module is the only place in
// the Node tree that knows that. Step 5's `subprocess` provider will be built on
// `exec()` below, and nothing else should talk to the channel.
//
// WHAT IT GUARANTEES, and how:
//
//   * Streaming. `/v1/exec` answers with chunked NDJSON; this reads the response
//     body as a stream and emits each event as it arrives. A command that prints
//     one line per 100 ms produces one callback per 100 ms, not one at the end.
//     The timestamp on each arrival is recorded so a test can prove it.
//
//   * Incremental UTF-8. A character split across two guest writes must not turn
//     into U+FFFD. The wire format is base64, so the bytes survive HTTP intact;
//     decoding goes through a real `TextDecoder` with `{ stream: true }`, which
//     buffers a partial sequence and completes it on the next chunk.
//
//   * No token in logs. The URL and token come from the environment. The token is
//     never passed to `console.*` here, and `redact()` exists for callers that
//     want to print a request URL.
//
// This module requires no npm dependency: it uses the `fetch` polyfill that
// sim/ios-sim-preload.cjs installs (undici's parser needs WebAssembly, which a
// jitless Node does not have).

'use strict';

/**
 * @typedef {object} ExecEvent
 * @property {'stdout'|'stderr'} type  which stream the bytes came from
 * @property {Buffer} chunk            the raw bytes
 * @property {number} t                device-side timestamp the guest attached
 * @property {number} arrivalMs        ms since the exec started, this process's clock
 */

/**
 * @typedef {object} ExecResult
 * @property {number} exitCode
 * @property {number} pid
 * @property {boolean} timedOut
 * @property {boolean} truncated
 * @property {number} totalOutputBytes
 * @property {number} durationMs
 * @property {string} stdout
 * @property {string} stderr
 * @property {string} [launchError]
 * @property {number[]} chunkArrivalsMs  when each chunk reached this process
 */

/** The endpoint, from the environment the Swift host published. */
const DEFAULT_BASE_URL = 'http://127.0.0.1:0';

/**
 * A token that must never reach a log. `redact()` is the only sanctioned way to
 * put any part of a request into a message.
 */
let tokenCache;

/** Read the channel configuration from the environment. */
export function channelConfig() {
  const url = process.env.DSH_GUEST_CHANNEL_URL ?? '';
  const token = process.env.DSH_GUEST_CHANNEL_TOKEN ?? '';
  const workspace = process.env.DSH_GUEST_WORKSPACE ?? '';
  return {
    configured: url.length > 0 && token.length > 0,
    url: url.length > 0 ? url : DEFAULT_BASE_URL,
    token,
    workspace,
  };
}

/** Replace the channel token with a placeholder, for any text bound for a log. */
export function redact(text) {
  if (typeof text !== 'string' || text.length === 0) return text;
  if (tokenCache === undefined) tokenCache = channelConfig().token;
  if (tokenCache.length === 0) return text;
  return text.split(tokenCache).join('<redacted>');
}

/**
 * Throw a clear error when the channel was not configured.
 *
 * This is a separate function rather than an inline check so the message can say
 * what to do about it: the channel only exists when the app booted the guest on
 * purpose (GuestWorkspaceCoordinator.isEnabled).
 */
function requireChannel() {
  const config = channelConfig();
  if (!config.configured) {
    const error = new Error(
      'guest channel is not configured (DSH_GUEST_CHANNEL_URL / DSH_GUEST_CHANNEL_TOKEN are unset). '
      + 'This build only starts the embedded guest when it is asked to: launch the app with '
      + 'DSHPORTE_GUEST_CHANNEL=1, or -DSHPortEGuestChannel 1.'
    );
    error.code = 'DSH_GUEST_CHANNEL_NOT_CONFIGURED';
    throw error;
  }
  return config;
}

/** The headers every request carries. */
function authHeaders(config, extra = {}) {
  return {
    authorization: `Bearer ${config.token}`,
    accept: 'application/x-ndjson',
    ...extra,
  };
}

/**
 * `GET /v1/health`. Answers whether the guest is booted and where the workspace
 * is mounted, without starting anything.
 * @returns {Promise<object>} the decoded health payload.
 */
export async function health() {
  const config = requireChannel();
  const response = await fetch(`${config.url}/v1/health`, {
    method: 'GET',
    headers: authHeaders(config),
  });
  if (!response.ok) {
    throw new Error(`guest channel health failed: HTTP ${response.status}`);
  }
  return response.json();
}

/**
 * `POST /v1/resolve`. Stat + access a guest path.
 *
 * Returns the guest's answer as an object: `exists`, `isDirectory`,
 * `isRegularFile`, `executable`, `mode`, `size`, `dev`, `inode`. A missing path
 * is `{ exists: false, error: 'ENOENT' }`, not a thrown error — asking whether a
 * path exists is not an error condition.
 *
 * @param {string} path absolute path in the guest.
 * @returns {Promise<object>} the resolve payload.
 */
export async function resolve(path) {
  const config = requireChannel();
  const response = await fetch(`${config.url}/v1/resolve`, {
    method: 'POST',
    headers: authHeaders(config, { 'content-type': 'application/json' }),
    body: JSON.stringify({ path }),
  });
  if (response.status === 401) {
    throw new Error('guest channel rejected the token (401); the app minted a different one this launch');
  }
  if (!response.ok) {
    throw new Error(`guest channel resolve failed: HTTP ${response.status}`);
  }
  return response.json();
}

/**
 * `POST /v1/exec`, streaming.
 *
 * Resolves with the aggregated result once the guest process exits. Calls
 * `onChunk` for every chunk while it runs, and records the arrival time of each
 * one in the result.
 *
 * @param {object} options
 * @param {string} [options.command]      run as `/bin/sh -c command`
 * @param {string[]} [options.argv]       or run argv directly (argv[0] included)
 * @param {string} [options.cwd]          guest working directory
 * @param {number} [options.timeoutMs]    0 / undefined means no timeout
 * @param {string|Buffer} [options.stdin] written to the guest process, then closed
 * @param {string[]} [options.env]        "K=V" overrides
 * @param {number} [options.maxOutputBytes] guest-side retention cap
 * @param {string} [options.execId]       correlation id
 * @param {(event: ExecEvent) => void} [options.onChunk]
 * @param {(line: string, isStderr: boolean) => void} [options.onLine] convenience
 * @param {AbortSignal} [options.signal]
 * @returns {Promise<ExecResult>} the aggregated result.
 */
export async function exec(options = {}) {
  const config = requireChannel();
  const startedAt = Date.now();

  const body = {
    command: options.command,
    argv: options.argv,
    cwd: options.cwd,
    timeout: options.timeoutMs !== undefined ? options.timeoutMs / 1000 : 0,
    env: options.env,
    maxOutputBytes: options.maxOutputBytes,
    execId: options.execId,
    stdinBase64: options.stdin === undefined || options.stdin === null
      ? undefined
      : Buffer.from(options.stdin).toString('base64'),
  };

  const response = await fetch(`${config.url}/v1/exec`, {
    method: 'POST',
    headers: authHeaders(config, { 'content-type': 'application/json' }),
    body: JSON.stringify(body),
    signal: options.signal,
  });

  if (response.status === 401) {
    throw new Error('guest channel rejected the token (401); the app minted a different one this launch');
  }
  if (!response.ok) {
    const detail = await response.text().catch(() => '');
    throw new Error(`guest channel exec failed: HTTP ${response.status} ${detail}`.trim());
  }

  // Chunked NDJSON. Read it as a stream so events surface as they arrive; a
  // `response.text()` here would turn live output into one final blob, which is
  // exactly the failure the acceptance test for this step looks for.
  const decoder = new TextDecoder('utf-8');
  const stdoutDecoder = new TextDecoder('utf-8');
  const stderrDecoder = new TextDecoder('utf-8');

  /** @type {Buffer[]} */
  const stdoutParts = [];
  /** @type {Buffer[]} */
  const stderrParts = [];
  /** @type {number[]} */
  const chunkArrivalsMs = [];
  let pending = '';
  let exitEvent = null;

  /** Decode one NDJSON line. */
  const handleLine = (line) => {
    if (line.length === 0) return;
    let event;
    try {
      event = JSON.parse(line);
    } catch {
      // A malformed line is a channel bug, not a guest bug. Surface it rather
      // than dropping it silently: a swallowed parse error looks exactly like
      // "the command printed nothing".
      throw new Error(`guest channel: unparsable event ${JSON.stringify(line.slice(0, 200))}`);
    }

    if (event.type === 'exit') {
      exitEvent = event;
      return;
    }

    const bytes = Buffer.from(String(event.data ?? ''), 'base64');
    const arrivalMs = Date.now() - startedAt;
    chunkArrivalsMs.push(arrivalMs);

    if (event.type === 'stderr') stderrParts.push(bytes);
    else stdoutParts.push(bytes);

    if (typeof options.onChunk === 'function') {
      options.onChunk({
        type: event.type === 'stderr' ? 'stderr' : 'stdout',
        chunk: bytes,
        t: typeof event.t === 'number' ? event.t : 0,
        arrivalMs,
      });
    }
    if (typeof options.onLine === 'function') {
      // Line splitting happens on the *decoded* text with a streaming decoder, so
      // a character split across chunks is completed before it is ever compared
      // to '\n'. The partial line is held in the caller-visible buffer below.
      const text = (event.type === 'stderr' ? stderrDecoder : stdoutDecoder).decode(bytes, { stream: true });
      lineBuffers[event.type === 'stderr' ? 'stderr' : 'stdout'] += text;
      const buffer = lineBuffers[event.type === 'stderr' ? 'stderr' : 'stdout'];
      const parts = buffer.split('\n');
      lineBuffers[event.type === 'stderr' ? 'stderr' : 'stdout'] = parts.pop() ?? '';
      for (const complete of parts) options.onLine(complete, event.type === 'stderr');
    }
  };

  /** @type {{stdout: string, stderr: string}} */
  const lineBuffers = { stdout: '', stderr: '' };

  if (response.body !== null && typeof response.body.getReader === 'function') {
    const reader = response.body.getReader();
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      pending += decoder.decode(value, { stream: true });
      let newline;
      while ((newline = pending.indexOf('\n')) >= 0) {
        const line = pending.slice(0, newline);
        pending = pending.slice(newline + 1);
        handleLine(line);
      }
    }
    pending += decoder.decode();
    if (pending.trim().length > 0) handleLine(pending);
  } else {
    // A Response without a stream is not expected from this server; if one ever
    // appears, say so instead of pretending the output was empty.
    throw new Error('guest channel: response has no readable body stream');
  }

  // Flush whatever the streaming decoders are still holding.
  const flushedStdout = stdoutDecoder.decode();
  const flushedStderr = stderrDecoder.decode();
  if (flushedStdout.length > 0) stdoutParts.push(Buffer.from(flushedStdout, 'utf8'));
  if (flushedStderr.length > 0) stderrParts.push(Buffer.from(flushedStderr, 'utf8'));
  for (const stream of ['stdout', 'stderr']) {
    if (lineBuffers[stream].length > 0 && typeof options.onLine === 'function') {
      options.onLine(lineBuffers[stream], stream === 'stderr');
      lineBuffers[stream] = '';
    }
  }

  const stdoutBuffer = Buffer.concat(stdoutParts);
  const stderrBuffer = Buffer.concat(stderrParts);

  if (exitEvent === null) {
    throw new Error('guest channel: stream ended without an exit event');
  }

  return {
    exitCode: exitEvent.exitCode,
    pid: exitEvent.pid,
    timedOut: Boolean(exitEvent.timedOut),
    truncated: Boolean(exitEvent.truncated),
    totalOutputBytes: Number(exitEvent.totalOutputBytes ?? 0),
    durationMs: Number(exitEvent.durationMs ?? 0),
    stdout: stdoutBuffer.toString('utf8'),
    stderr: stderrBuffer.toString('utf8'),
    stdoutBuffer,
    stderrBuffer,
    launchError: exitEvent.launchError,
    chunkArrivalsMs,
    wallMs: Date.now() - startedAt,
  };
}

/**
 * Cancel a running exec by id.
 *
 * The server keeps the id it was given, so this matches the one passed to
 * `exec({ execId })`. There is no separate cancel endpoint yet — step 5 decides
 * whether the provider needs one or whether killing by signal is enough — so
 * this reports honestly that it is unimplemented rather than pretending.
 * @param {string} execId
 * @returns {Promise<never>}
 */
export async function cancel(execId) {
  throw new Error(
    `guest channel: cancel(${redact(execId)}) is not implemented; `
    + 'step 5 will add either a /v1/cancel endpoint or signal delivery'
  );
}

export default { channelConfig, redact, health, resolve, exec, cancel };
