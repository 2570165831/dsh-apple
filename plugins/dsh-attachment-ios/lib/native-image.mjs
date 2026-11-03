// The Node half of the platform image service.
//
// WHY THIS FILE EXISTS: `@deepseek-ai/dsh-attachment-local` does every raster
// operation through the `sharp` native addon. iOS cannot load a third-party
// addon at all — `dlopen` of a valid arm64 dylib is refused even when it is
// ad-hoc signed (REPORT-4B measured both cases) — so the decode has to happen in
// the platform's own image stack. `ISHImageService` (Objective-C, ImageIO +
// CoreGraphics) is that decoder, and it is reached over the same authenticated
// loopback channel the guest uses: same listener, same bearer token, same Host
// check. This module is the only place on the Node side that knows the wire
// shape.
//
// WHY THE CHANNEL AND NOT A NEW SOCKET: the security posture an image decoder
// needs for arbitrary bytes — loopback-only binding, a per-launch 32-byte token,
// a Host check against DNS rebinding, one request per connection — is exactly
// what `ISHGuestChannel` already implements and has had reviewed by three earlier
// steps. A second listener would be a second place for that to be got wrong.
//
// WHAT IT DOES NOT DO: it never invents a URL or a token. Without both, every
// call fails with `IMAGE_CHANNEL_NOT_CONFIGURED` and a message saying why, which
// the provider turns into a real failure. A silent fallback to "decode nothing"
// would look exactly like a working attachment until the model said it could not
// see the picture.

/** Where the channel lives when the host published nothing. */
const NO_URL = 'http://127.0.0.1:0';

/** Endpoint paths, matching `ISHGuestChannelPathImage*` on the Swift side. */
const PROBE_PATH = '/v1/image/probe';
const ENCODE_PATH = '/v1/image/encode';

/** Stable failure codes this module raises. */
export const IMAGE_CHANNEL_NOT_CONFIGURED = 'IMAGE_CHANNEL_NOT_CONFIGURED';
export const IMAGE_CHANNEL_HTTP_FAILURE = 'IMAGE_CHANNEL_HTTP_FAILURE';
export const IMAGE_CHANNEL_PROTOCOL_FAILURE = 'IMAGE_CHANNEL_PROTOCOL_FAILURE';
export const IMAGE_CHANNEL_TRANSPORT_FAILURE = 'IMAGE_CHANNEL_TRANSPORT_FAILURE';

/** Per-request deadline. A 64-megapixel decode on a phone is ~1 s; 30 s means wedged, not slow. */
const REQUEST_TIMEOUT_MS = 30_000;

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
  return { configured: url.length > 0 && token.length > 0, url: url.length > 0 ? url : NO_URL, token };
}

/** The token, cached so `redact()` stays cheap on a hot path. */
let tokenCache;

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
 * The message says what to do, because the failure otherwise surfaces as "the
 * model cannot see images" with no clue why: the channel only exists when the
 * app booted the guest on purpose (`GuestWorkspaceCoordinator.isEnabled`).
 * @returns {object} the configuration.
 */
function requireChannel() {
  const config = channelConfig();
  if (!config.configured) {
    throw channelError(
      IMAGE_CHANNEL_NOT_CONFIGURED,
      'the platform image service is unavailable: DSH_GUEST_CHANNEL_URL / DSH_GUEST_CHANNEL_TOKEN are unset. '
      + 'This build serves image decoding from the app\'s own channel; launch with the guest enabled '
      + '(DSHPORTE_GUEST_CHANNEL=1, the default) so the listener exists.',
    );
  }
  return config;
}

/** Whether the platform decoder is reachable at all. Cheap; used at mount time. */
export function isConfigured() {
  return channelConfig().configured;
}

/**
 * One request/response exchange with the image endpoints.
 *
 * `fetch` here is the polyfill `sim/ios-sim-preload.cjs` installs: nodejs-mobile's
 * own `fetch` is undici, whose llhttp parser is WebAssembly, and a jitless build
 * has no WebAssembly at all.
 * @param {string} path - endpoint path.
 * @param {object} payload - JSON body.
 * @param {AbortSignal} [signal] - caller cancellation.
 * @returns {Promise<object>} the decoded answer.
 */
async function post(path, payload, signal) {
  const config = requireChannel();
  signal?.throwIfAborted();
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
  const onAbort = () => controller.abort();
  signal?.addEventListener('abort', onAbort, { once: true });
  let response;
  try {
    response = await fetch(`${config.url}${path}`, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${config.token}`,
        'content-type': 'application/json',
        accept: 'application/json',
      },
      body: JSON.stringify(payload),
      signal: controller.signal,
    });
  } catch (error) {
    signal?.throwIfAborted();
    throw channelError(
      IMAGE_CHANNEL_TRANSPORT_FAILURE,
      `the platform image service did not answer POST ${path}: ${redact(String(error?.message ?? error))}`,
      { cause: error },
    );
  } finally {
    clearTimeout(timer);
    signal?.removeEventListener('abort', onAbort);
  }

  if (response.status !== 200) {
    // The body is the channel's own one-line explanation. It never contains the
    // token (the server does not log or echo it); `redact` is the belt to that.
    const detail = await response.text().catch(() => '');
    throw channelError(
      IMAGE_CHANNEL_HTTP_FAILURE,
      `the platform image service answered ${response.status} for ${path}`
      + (detail.length > 0 ? `: ${redact(detail).slice(0, 300)}` : ''),
      { status: response.status },
    );
  }

  let answer;
  try {
    answer = await response.json();
  } catch (error) {
    throw channelError(IMAGE_CHANNEL_PROTOCOL_FAILURE, `the platform image service answered ${path} with something that is not JSON`, { cause: error });
  }
  if (answer === null || typeof answer !== 'object' || typeof answer.ok !== 'boolean') {
    throw channelError(IMAGE_CHANNEL_PROTOCOL_FAILURE, `the platform image service answered ${path} without an "ok" field`);
  }
  return answer;
}

/**
 * Read one image's container facts, optionally proving its pixels decode.
 * @param {Uint8Array} data - encoded image bytes.
 * @param {object} [limits] - `maxPixels` / `maxDimension`; 0 or omitted means no limit.
 * @param {object} [options] - `fullDecode` (default true) and `signal`.
 * @returns {Promise<object>} the service's answer, `ok` included.
 */
export function probe(data, limits = {}, options = {}) {
  return post(PROBE_PATH, {
    data: Buffer.from(data.buffer, data.byteOffset, data.byteLength).toString('base64'),
    maxPixels: limits.maxPixels ?? 0,
    maxDimension: limits.maxDimension ?? 0,
    fullDecode: options.fullDecode === false ? 0 : 1,
  }, options.signal);
}

/**
 * Decode, orient, convert to 8-bit sRGB, fit inside a box, and re-encode.
 * @param {Uint8Array} data - encoded source bytes.
 * @param {object} target - `width`, `height` (the box) and `maxBytes`.
 * @param {AbortSignal} [signal] - caller cancellation.
 * @returns {Promise<object>} the service's answer; `data` is base64 when `ok`.
 */
export function encode(data, target, signal) {
  return post(ENCODE_PATH, {
    data: Buffer.from(data.buffer, data.byteOffset, data.byteLength).toString('base64'),
    maxWidth: target.width ?? 0,
    maxHeight: target.height ?? 0,
    maxBytes: target.maxBytes ?? 0,
  }, signal);
}

/**
 * One-line description of the decoder, for the boot log.
 *
 * Printed once at plugin mount so the report can prove the service is active
 * without decoding anything, and so a future reader of the log can see which
 * path a decode took.
 * @returns {string} a log line with no credential in it.
 */
export function describe() {
  const config = channelConfig();
  return config.configured
    ? `attachment-ios: platform image service at ${config.url} (ImageIO/CoreGraphics; sharp is never required)`
    : 'attachment-ios: platform image service NOT configured (no channel URL/token in the environment)';
}
