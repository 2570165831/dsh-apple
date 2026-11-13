// The Node side of the guest channel, as the provider needs it.
//
// This is a hardened descendant of `sim/guest-channel-client.mjs` rather than
// an import of it. The differences are all things a *provider* needs and an
// acceptance script does not:
//
//   * `exec()` takes an AbortSignal. The provider requests cancellation through
//     `POST /v1/cancel`; closing the stream also cancels pending or running work.
//   * Cancellation states are returned intact, so an initially unknown id is
//     never mistaken for a confirmed exit.
//   * The NDJSON reader tolerates the terminating chunk boundary and a body
//     that ends without a trailing newline; the acceptance client only ever saw
//     well-formed streams from its own commands.
//   * Every failure carries a `code` the provider can classify, because the
//     seam distinguishes "the executable does not exist" (a user-facing fact)
//     from "the transport broke" (an infrastructure failure that must reach the
//     model as a failed spawn, never as a silent success).
//
// It still refuses to invent a token or a URL: without both, `requireChannel()`
// throws with an explanation, and the provider turns that into a failed spawn.

/** Where the channel lives when the host published nothing. */
const NO_URL = 'http://127.0.0.1:0';

/** Error codes this module raises. */
export const CHANNEL_NOT_CONFIGURED = 'DSH_GUEST_CHANNEL_NOT_CONFIGURED';
export const CHANNEL_HTTP_FAILURE = 'DSH_GUEST_CHANNEL_HTTP_FAILURE';
export const CHANNEL_PROTOCOL_FAILURE = 'DSH_GUEST_CHANNEL_PROTOCOL_FAILURE';
export const CHANNEL_TRANSPORT_FAILURE = 'DSH_GUEST_CHANNEL_TRANSPORT_FAILURE';
export const CHANNEL_LAUNCH_FAILURE = 'DSH_GUEST_CHANNEL_LAUNCH_FAILURE';

/**
 * Build one coded error.
 * @param {string} code - stable classification.
 * @param {string} message - human-readable, token-free.
 * @param {object} [extra] - fields to attach.
 * @returns {Error} the error.
 */
function channelError(code, message, extra = {}) {
  const error = new Error(message);
  error.code = code;
  Object.assign(error, extra);
  return error;
}

/** Read the channel configuration from the environment the host published. */
export function channelConfig() {
  const url = process.env.DSH_GUEST_CHANNEL_URL ?? '';
  const token = process.env.DSH_GUEST_CHANNEL_TOKEN ?? '';
  const workspace = process.env.DSH_GUEST_WORKSPACE ?? '';
  return {
    configured: url.length > 0 && token.length > 0,
    url: url.length > 0 ? url : NO_URL,
    token,
    workspace,
  };
}

/** The token, cached so `redact()` stays cheap on a hot path. */
let tokenCache;

/**
 * Replace the channel token with a placeholder in any text bound for a log.
 * @param {string} text - candidate text.
 * @returns {string} the same text with the token removed.
 */
export function redact(text) {
  if (typeof text !== 'string' || text.length === 0) return text;
  if (tokenCache === undefined) tokenCache = channelConfig().token;
  if (tokenCache.length === 0) return text;
  return text.split(tokenCache).join('<redacted>');
}

/**
 * The configuration, or a coded throw. Deliberately not a silent "not
 * configured" return: every caller of this module needs the channel, and the
 * only correct behaviour without one is to fail loudly.
 * @returns {{configured: boolean, url: string, token: string, workspace: string}} config.
 */
function requireChannel() {
  const config = channelConfig();
  if (!config.configured) {
    throw channelError(
      CHANNEL_NOT_CONFIGURED,
      'the guest channel is not configured: the app started Node without '
      + 'DSH_GUEST_CHANNEL_URL / DSH_GUEST_CHANNEL_TOKEN, which happens when '
      + 'the guest was not booted for this launch',
    );
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
 * `GET /v1/health`.
 * @returns {Promise<object>} the decoded health payload.
 */
export async function health() {
  const config = requireChannel();
  let response;
  try {
    response = await fetch(`${config.url}/v1/health`, { method: 'GET', headers: authHeaders(config) });
  } catch (error) {
    throw channelError(CHANNEL_TRANSPORT_FAILURE, `guest channel health request failed: ${redact(String(error))}`, { cause: error });
  }
  if (!response.ok) throw channelError(CHANNEL_HTTP_FAILURE, `guest channel health failed: HTTP ${response.status}`);
  return response.json();
}

/**
 * `POST /v1/executable` — ask the guest whether a name is executable.
 *
 * The guest is the only authority on this. Answering on the host would mean
 * guessing with the *host's* filesystem, and on a phone the host's
 * `/usr/bin/git` and the guest's are unrelated files.
 *
 * @param {string} name - absolute path or bare name.
 * @param {string} [pathValue] - PATH to search; the guest default when omitted.
 * @param {AbortSignal} [signal] - cancellation.
 * @returns {Promise<{found: boolean, path?: string}>} the guest's answer.
 */
export async function resolveExecutable(name, pathValue, signal) {
  const config = requireChannel();
  let response;
  try {
    response = await fetch(`${config.url}/v1/executable`, {
      method: 'POST',
      headers: authHeaders(config, { 'content-type': 'application/json' }),
      body: JSON.stringify({ name, ...pathValue === undefined ? {} : { path: pathValue } }),
      signal,
    });
  } catch (error) {
    if (signal?.aborted === true) throw error;
    throw channelError(CHANNEL_TRANSPORT_FAILURE, `guest channel executable lookup failed: ${redact(String(error))}`, { cause: error });
  }
  if (response.status === 401) {
    throw channelError(CHANNEL_HTTP_FAILURE, 'guest channel rejected the token (401); the app minted a different one this launch');
  }
  if (!response.ok) {
    throw channelError(CHANNEL_HTTP_FAILURE, `guest channel executable lookup failed: HTTP ${response.status}`);
  }
  const payload = await response.json();
  return payload;
}

/**
 * `POST /v1/cancel` — cancel a pending or running exec.
 *
 * state is pending-cancelled (cannot start), running (termination requested),
 * finished (completion observed), or unknown (no retained record).
 * Closing the exec stream also requests cancellation; it does not prove exit.
 *
 * @param {string} execId - the id passed to `exec()`.
 * @param {AbortSignal} [signal] - cancellation of the *cancel request* itself.
 * @returns {Promise<{execId: string, cancelled: boolean, state: string, active: number}>} the guest's answer.
 */
export async function cancel(execId, signal) {
  const config = requireChannel();
  const response = await fetch(`${config.url}/v1/cancel`, {
    method: 'POST',
    headers: authHeaders(config, { 'content-type': 'application/json' }),
    body: JSON.stringify({ execId }),
    signal,
  });
  if (!response.ok) {
    throw channelError(CHANNEL_HTTP_FAILURE, `guest channel cancel failed: HTTP ${response.status}`);
  }
  return response.json();
}

/**
 * `POST /v1/resolve` — stat + access a guest path.
 * @param {string} path - absolute guest path.
 * @returns {Promise<object>} the resolve payload.
 */
export async function resolve(path) {
  const config = requireChannel();
  const response = await fetch(`${config.url}/v1/resolve`, {
    method: 'POST',
    headers: authHeaders(config, { 'content-type': 'application/json' }),
    body: JSON.stringify({ path }),
  });
  if (!response.ok) {
    throw channelError(CHANNEL_HTTP_FAILURE, `guest channel resolve failed: HTTP ${response.status}`);
  }
  return response.json();
}

/**
 * Run one command in the guest, streaming its output.
 *
 * @param {object} options
 * @param {string[]} [options.argv] - explicit argv (argv[0] included).
 * @param {string} [options.command] - run as `/bin/sh -c command` instead.
 * @param {string} [options.cwd] - guest working directory.
 * @param {number} [options.timeoutMs] - guest-side timeout, 0 for none.
 * @param {string|Buffer} [options.stdin] - written to the child, then EOF.
 * @param {string[]} [options.env] - "K=V" overrides.
 * @param {string} [options.execId] - correlation id, required for `cancel()`.
 * @param {(event: {type: 'stdout'|'stderr', chunk: Buffer, t: number}) => void} [options.onChunk]
 * @param {boolean} [options.collect] - also accumulate the whole stream and
 *   return it as `stdout`/`stderr`. DEFAULT FALSE, and that is a memory
 *   decision: the provider hands every chunk to the Node-side `OutputCollector`
 *   as it arrives, so a second whole-stream copy here doubles the peak for no
 *   benefit — measured at 10 MB of avoidable growth on the `yes | head -c
 *   10000000` criterion, which is exactly the case the bound exists to protect.
 *   Callers that want the finished text (a probe, a diagnostic) ask for it.
 * @param {AbortSignal} [options.signal] - cancellation.
 * @returns {Promise<object>} the aggregated result.
 */
export async function exec(options = {}) {
  const config = requireChannel();
  const startedAt = Date.now();

  const body = {
    argv: options.argv,
    command: options.command,
    cwd: options.cwd,
    timeout: options.timeoutMs !== undefined ? options.timeoutMs / 1000 : 0,
    env: options.env,
    execId: options.execId,
    stdinBase64: options.stdin === undefined || options.stdin === null
      ? undefined
      : Buffer.from(options.stdin).toString('base64'),
  };

  let response;
  try {
    response = await fetch(`${config.url}/v1/exec`, {
      method: 'POST',
      headers: authHeaders(config, { 'content-type': 'application/json' }),
      body: JSON.stringify(body),
      signal: options.signal,
    });
  } catch (error) {
    if (options.signal?.aborted === true) throw error;
    throw channelError(CHANNEL_TRANSPORT_FAILURE, `guest channel exec request failed: ${redact(String(error))}`, { cause: error });
  }

  if (response.status === 401) {
    throw channelError(CHANNEL_HTTP_FAILURE, 'guest channel rejected the token (401); the app minted a different one this launch');
  }
  if (!response.ok) {
    const detail = await response.text().catch(() => '');
    throw channelError(CHANNEL_HTTP_FAILURE, `guest channel exec failed: HTTP ${response.status} ${redact(detail)}`.trim());
  }
  if (response.body === null || typeof response.body.getReader !== 'function') {
    throw channelError(CHANNEL_PROTOCOL_FAILURE, 'guest channel: response has no readable body stream');
  }

  // NDJSON framing. The line decoder and the per-stream UTF-8 decoders are
  // separate on purpose: framing is a byte protocol (always ASCII), while
  // character completion is per stream and must survive a multi-byte scalar
  // split across two chunks — that is the U+FFFD failure this whole arrangement
  // exists to prevent.
  const lineDecoder = new TextDecoder('utf-8');
  const stdoutDecoder = new TextDecoder('utf-8');
  const stderrDecoder = new TextDecoder('utf-8');

  // Only populated when the caller asked for the whole stream; see `collect`.
  const collect = options.collect === true;
  /** @type {Buffer[]} */
  const stdoutParts = [];
  /** @type {Buffer[]} */
  const stderrParts = [];
  /** @type {number[]} */
  const chunkArrivalsMs = [];
  let pending = '';
  let exitEvent = null;
  let totalOutputBytes = 0;

  /** Decode one NDJSON line. */
  const handleLine = (line) => {
    if (line.length === 0) return;
    let event;
    try {
      event = JSON.parse(line);
    } catch {
      throw channelError(CHANNEL_PROTOCOL_FAILURE, `guest channel: unparsable event ${JSON.stringify(line.slice(0, 200))}`);
    }

    if (event.type === 'exit') {
      exitEvent = event;
      return;
    }

    const bytes = Buffer.from(String(event.data ?? ''), 'base64');
    const arrivalMs = Date.now() - startedAt;
    chunkArrivalsMs.push(arrivalMs);
    totalOutputBytes += bytes.length;

      if (collect) {
      if (event.type === 'stderr') stderrParts.push(bytes);
      else stdoutParts.push(bytes);
    }

    if (typeof options.onChunk === 'function') {
      options.onChunk({
        type: event.type === 'stderr' ? 'stderr' : 'stdout',
        chunk: bytes,
        t: typeof event.t === 'number' ? event.t : 0,
        arrivalMs,
      });
    }
  };

  const reader = response.body.getReader();
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    pending += lineDecoder.decode(value, { stream: true });
    let newline;
    while ((newline = pending.indexOf('\n')) >= 0) {
      const line = pending.slice(0, newline);
      pending = pending.slice(newline + 1);
      handleLine(line);
    }
  }
  // Flush the framing decoder, then a final line that arrived without a
  // trailing newline. Both are protocol-level: bytes must not be dropped just
  // because the peer's last write was not newline-terminated.
  pending += lineDecoder.decode();
  if (pending.trim().length > 0) handleLine(pending);

  // Flush the per-stream decoders. Anything they were holding is a partial or
  // complete trailing sequence; emitting it is what makes "no U+FFFD" true even
  // when the stream ends mid-character.
  const flushedStdout = stdoutDecoder.decode();
  const flushedStderr = stderrDecoder.decode();
  if (collect) {
    if (flushedStdout.length > 0) stdoutParts.push(Buffer.from(flushedStdout, 'utf8'));
    if (flushedStderr.length > 0) stderrParts.push(Buffer.from(flushedStderr, 'utf8'));
  }

  if (exitEvent === null) {
    throw channelError(CHANNEL_PROTOCOL_FAILURE, 'guest channel: stream ended without an exit event');
  }

  // A `launchError` means the guest never started a process: no argv, no shell,
  // a pipe or task_start failure. Reporting its exit code as if it were the
  // command's is how "the shell is broken" turns into "the command failed",
  // which is the single most misleading outcome this seam can produce — the
  // model then retries the same command forever. It is thrown, so `done`
  // rejects and the seam's own "provider failure" path shows the reason.
  if (typeof exitEvent.launchError === 'string' && exitEvent.launchError.length > 0) {
    throw channelError(
      CHANNEL_LAUNCH_FAILURE,
      `guest channel: the command never started in the guest: ${redact(exitEvent.launchError)}`,
      { launchError: exitEvent.launchError, execId: options.execId },
    );
  }

  return {
    // Convenience text views beside the buffers. The buffers are what the
    // provider collects from (via `onChunk`), but a caller that only wants the
    // finished output — an acceptance probe, a diagnostic, the report — should
    // not have to know the buffers exist. Leaving them out produced `undefined`
    // for `stdout` on every call, which read as "the channel returned nothing"
    // rather than "you asked for a field that is not there".
    // Absent unless `collect` was set, rather than an empty string: a caller
    // must not be able to mistake "not collected" for "the command printed
    // nothing".
    ...collect ? {
      stdout: Buffer.concat(stdoutParts).toString('utf8'),
      stderr: Buffer.concat(stderrParts).toString('utf8'),
    } : {},
    exitCode: exitEvent.exitCode,
    pid: exitEvent.pid,
    timedOut: Boolean(exitEvent.timedOut),
    truncated: Boolean(exitEvent.truncated),
    // Counted from the frames themselves, which costs nothing and works with or
    // without `collect`.
    totalOutputBytes: Number(exitEvent.totalOutputBytes ?? totalOutputBytes),
    durationMs: Number(exitEvent.durationMs ?? 0),
    ...collect ? {
      stdoutBuffer: Buffer.concat(stdoutParts),
      stderrBuffer: Buffer.concat(stderrParts),
    } : {},
    launchError: exitEvent.launchError,
    chunkArrivalsMs,
    wallMs: Date.now() - startedAt,
  };
}

export default { channelConfig, redact, health, resolve, resolveExecutable, exec, cancel };
