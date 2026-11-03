// Make `new TextDecoder('utf-8', { fatal: true })` work on a Node built without ICU.
//
// WHY THIS EXISTS
// ---------------
// Measured in the iOS 27 simulator (logs/spike-probe5-textdecoder.log): with
// `v8_enable_i18n_support: 0`, Node's TextDecoder rejects the `fatal` option
// outright:
//
//   new TextDecoder('utf-8', { fatal: true }).decode(bytes)
//     -> TypeError: "fatal" option is not supported on Node.js compiled without ICU
//
// Without `fatal` the same decoder works normally. DSH's local filesystem
// backend uses exactly the fatal form to decide whether a file is text:
//
//   dsh-fs-local/lib/index.js:331   decodeUtf8()
//     new TextDecoder("utf-8", { fatal: true })
//   dsh-fs-local/lib/index.js:340   decodeUtf8Stream()
//     decoder.decode(chunk, { stream: true })   then   decoder.decode()
//
// Because the CONSTRUCTOR throws, `decodeUtf8()` never even reaches its catch on
// the decode call; it surfaces as
//
//   cannot read "<path>": invalid UTF-8 text
//
// for perfectly ordinary ASCII. In the app runs this made the `read` tool fail
// while `write` and `glob` worked.
//
// WHAT THIS DOES
// --------------
// Replaces the global TextDecoder with a wrapper that keeps `fatal` semantics
// without ICU:
//
//   * Non-streaming decode: decode with the non-fatal decoder, then re-encode
//     and compare bytes. Valid UTF-8 round-trips exactly; malformed bytes do
//     not, so the TypeError a fatal decoder would raise is raised here.
//   * Streaming decode: buffer and decode only the complete UTF-8 prefix,
//     retaining a trailing split sequence for the next call. Each emitted piece
//     is round-trip checked, so a chunk may end mid-codepoint without being
//     reported as invalid.
//   * The final `decode()` flushes the buffer and reports an error when it ends
//     with an incomplete sequence.
//
// The byte-to-string work is delegated to the platform decoder, so labels,
// `ignoreBOM` and message text keep their native behaviour.
//
// WHERE IT MUST BE INSTALLED
// --------------------------
// Replacing `globalThis.TextDecoder` is NOT enough. dsh-fs-local imports the
// class from the builtin instead of using the global:
//
//   dsh-fs-local/lib/index.js:11   import { TextDecoder, promisify } from "node:util";
//
// so the ES-module namespace of `node:util` also has to be pointed at the
// wrapper. `installNodeUtil()` below does that by patching the module's
// CommonJS exports object, which the namespace getters read through. Verified in
// the simulator: without this step the app still reported "invalid UTF-8 text"
// even though the global was replaced (logs/spike-probe6-decoder.log vs the
// run recorded in logs/e2e-stream.log).
//
// LIMIT, STATED PLAINLY: only UTF-8 is emulated. Any other label falls back to
// the platform decoder with `fatal` removed, i.e. invalid bytes become U+FFFD
// instead of throwing. DSH only ever asks for UTF-8 here, and the report says so.

'use strict';

/** The TypeError a fatal decoder raises for malformed input. */
function invalidUtf8() {
  return new TypeError('The encoded data was not valid for encoding utf-8');
}

/** Coerce a decode input to a Uint8Array view. */
function toBytes(input) {
  if (input instanceof Uint8Array) return input;
  if (input instanceof ArrayBuffer) return new Uint8Array(input);
  return new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
}

/** Byte-for-byte equality. */
function sameBytes(left, right) {
  if (left.length !== right.length) return false;
  for (let index = 0; index < left.length; index += 1) {
    if (left[index] !== right[index]) return false;
  }
  return true;
}

/** Concatenate two byte arrays. */
function concatBytes(left, right) {
  if (!left || left.length === 0) return right;
  if (!right || right.length === 0) return left;
  const out = new Uint8Array(left.length + right.length);
  out.set(left, 0);
  out.set(right, left.length);
  return out;
}

/**
 * Split a buffer at the last complete UTF-8 sequence boundary.
 *
 * A trailing multi-byte sequence that has not fully arrived is the normal case
 * for a streaming decoder, so it is held back rather than reported invalid.
 * @param {Uint8Array} bytes
 * @returns {{complete: Uint8Array, rest: Uint8Array}}
 */
function splitCompleteUtf8(bytes) {
  const length = bytes.length;
  if (length === 0) return { complete: bytes, rest: new Uint8Array(0) };

  // A UTF-8 sequence is at most 4 bytes, so only the last 3 can be incomplete.
  for (let back = 1; back <= Math.min(3, length); back += 1) {
    const byte = bytes[length - back];
    if ((byte & 0x80) === 0) {
      // ASCII byte: everything ends on a boundary.
      return { complete: bytes, rest: new Uint8Array(0) };
    }
    if ((byte & 0xc0) === 0xc0) {
      // A lead byte: its expected length decides whether the tail is complete.
      const expected = byte >= 0xf0 ? 4 : byte >= 0xe0 ? 3 : 2;
      if (back >= expected) {
        return { complete: bytes, rest: new Uint8Array(0) };
      }
      const cut = length - back;
      return { complete: bytes.subarray(0, cut), rest: bytes.subarray(cut) };
    }
    // A continuation byte: keep walking back toward its lead byte.
  }
  // Three continuation bytes and no lead byte in the window: malformed. Hand the
  // whole buffer to validation so the error surfaces rather than being hidden.
  return { complete: bytes, rest: new Uint8Array(0) };
}

/** Whether the running Node accepts `{ fatal: true }`. */
function supportsFatal() {
  try {
    new TextDecoder('utf-8', { fatal: true }).decode(new Uint8Array(0));
    return true;
  } catch {
    return false;
  }
}

/**
 * Install the wrapper. No-op when the platform already supports `fatal`.
 * @returns {{installed: boolean, reason: string}} what happened.
 */
function installTextDecoder() {
  const Original = globalThis.TextDecoder;
  if (typeof Original !== 'function') {
    return { installed: false, reason: 'TextDecoder is not defined' };
  }
  if (supportsFatal()) {
    return { installed: false, reason: 'platform already supports {fatal: true}' };
  }

  class FatalTextDecoder {
    /** @param {string} [label] @param {object} [options] */
    constructor(label = 'utf-8', options = {}) {
      const wantsFatal = options !== null && options !== undefined && options.fatal === true;
      const sanitized = { ...options };
      delete sanitized.fatal;
      this._inner = new Original(label, sanitized);
      this._label = String(this._inner.encoding || 'utf-8').toLowerCase();
      this._emulate = wantsFatal && this._label === 'utf-8';
      this._pending = new Uint8Array(0);
    }

    /** @returns {string} the canonical encoding name. */
    get encoding() {
      return this._inner.encoding;
    }

    /** @returns {boolean} */
    get ignoreBOM() {
      return this._inner.ignoreBOM;
    }

    /**
     * @param {ArrayBufferView|ArrayBuffer} [input]
     * @param {{stream?: boolean}} [options]
     * @returns {string}
     */
    decode(input, options) {
      if (!this._emulate) {
        // Any other encoding keeps platform behaviour; `fatal` was stripped, so
        // the constructor cannot throw.
        return this._inner.decode(input, options);
      }
      const streaming = options !== null && options !== undefined && options.stream === true;
      const incoming = input === undefined ? new Uint8Array(0) : toBytes(input);

      if (streaming) {
        this._pending = concatBytes(this._pending, incoming);
        const split = splitCompleteUtf8(this._pending);
        this._pending = split.rest;
        if (split.complete.length === 0) return '';
        return this._decodeVerified(split.complete);
      }

      // Final call: what just arrived plus anything held back must now be whole.
      const buffer = concatBytes(this._pending, incoming);
      this._pending = new Uint8Array(0);
      if (buffer.length === 0) return '';
      const split = splitCompleteUtf8(buffer);
      if (split.rest.length > 0) throw invalidUtf8();
      return this._decodeVerified(buffer);
    }

    /** Decode one complete buffer and verify it round-trips. */
    _decodeVerified(bytes) {
      const text = this._inner.decode(bytes, { stream: false });
      if (!sameBytes(bytes, new TextEncoder().encode(text))) throw invalidUtf8();
      return text;
    }
  }

  Object.defineProperty(globalThis, 'TextDecoder', {
    value: FatalTextDecoder,
    writable: true,
    configurable: true,
    enumerable: false,
  });
  const nodeUtil = installNodeUtil(FatalTextDecoder);
  return {
    installed: true,
    reason: 'emulating {fatal: true} with a decode/re-encode round-trip',
    streaming: 'buffers an incomplete trailing sequence between calls',
    global: true,
    nodeUtil,
  };
}

/**
 * Point `node:util`'s exported `TextDecoder` at the wrapper too.
 *
 * ESM consumers (`import { TextDecoder } from "node:util"`) read through the
 * builtin's CommonJS exports object, so replacing the property there reaches
 * them. Done through `process.getBuiltinModule` (Node 22+) to avoid needing a
 * `require` in this file's module scope.
 * @param {Function} replacement
 * @returns {boolean} whether the builtin was patched.
 */
function installNodeUtil(replacement) {
  try {
    const getBuiltin = process.getBuiltinModule;
    if (typeof getBuiltin !== 'function') return false;
    const util = getBuiltin('node:util');
    if (!util || typeof util !== 'object') return false;
    Object.defineProperty(util, 'TextDecoder', {
      value: replacement,
      writable: true,
      configurable: true,
      enumerable: true,
    });
    return util.TextDecoder === replacement;
  } catch {
    return false;
  }
}

module.exports = { installTextDecoder, supportsFatal, splitCompleteUtf8 };
