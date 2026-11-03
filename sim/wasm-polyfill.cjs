// Minimal `WebAssembly` stand-in for a jitless (iOS) Node.
//
// WHY: `node --jitless` deletes the WebAssembly namespace. Two classes of code
// then break:
//
//   1. Code that only *touches* the namespace at module load (feature probes like
//      `typeof WebAssembly === 'object'`, capability tables). A bare
//      `ReferenceError: WebAssembly is not defined` at import time kills the
//      whole module graph even when the wasm path is never taken.
//   2. undici, whose llhttp parser is wasm. That is handled separately by
//      `sim/fetch-polyfill.cjs`, which replaces `fetch` outright.
//
// WHAT THIS IS NOT: a wasm implementation. It cannot execute a module. Every
// compilation entry point throws `CompileError` with a message that names the
// jitless cause, so a code path that genuinely needs wasm fails loudly and
// legibly instead of silently returning wrong bytes. That is deliberate: a fake
// successful compile would corrupt any real parser that used it.
//
// `Memory` and `Table` are real objects with real bounds checking because code
// frequently allocates them before deciding it has no module to run.

'use strict';

/** An error type matching the shape callers expect from a compile failure. */
class CompileError extends Error {
  constructor(message) {
    super(message);
    this.name = 'CompileError';
  }
}

class LinkError extends Error {
  constructor(message) {
    super(message);
    this.name = 'LinkError';
  }
}

class RuntimeError extends Error {
  constructor(message) {
    super(message);
    this.name = 'RuntimeError';
  }
}

const JITLESS_REASON =
  'WebAssembly is unavailable because this process runs with --jitless (no JIT, therefore no wasm engine). '
  + 'If you reached this through node:http internals, use sim/fetch-polyfill.cjs instead.';

/** A wasm page is 64 KiB. */
const PAGE_SIZE = 65536;

/**
 * Linear memory with the bounds behaviour wasm requires.
 * Kept faithful so buffer arithmetic in callers stays correct.
 */
class Memory {
  constructor(descriptor = {}) {
    const initialPages = descriptor.initial ?? 0;
    if (!Number.isInteger(initialPages) || initialPages < 0) throw new TypeError('Memory: initial must be a non-negative integer');
    const maximumPages = descriptor.maximum;
    if (maximumPages !== undefined && (!Number.isInteger(maximumPages) || maximumPages < initialPages)) {
      throw new TypeError('Memory: maximum must be an integer >= initial');
    }
    this._maxPages = maximumPages ?? 65536;
    this._pages = initialPages;
    this.buffer = new ArrayBuffer(initialPages * PAGE_SIZE);
  }

  /** Current size in pages. */
  get _size() { return this._pages; }

  /** Grow by `delta` pages, returning the previous size or -1 on failure. */
  grow(delta) {
    if (!Number.isInteger(delta) || delta < 0) throw new RangeError('Memory.grow: delta must be a non-negative integer');
    const next = this._pages + delta;
    if (next > this._maxPages) return -1;
    const grown = new ArrayBuffer(next * PAGE_SIZE);
    new Uint8Array(grown).set(new Uint8Array(this.buffer));
    this.buffer = grown;
    const previous = this._pages;
    this._pages = next;
    return previous;
  }
}

/** A function table with real bounds checking. */
class Table {
  constructor(descriptor = {}) {
    const initial = descriptor.initial ?? 0;
    const maximum = descriptor.maximum;
    if (!Number.isInteger(initial) || initial < 0) throw new TypeError('Table: initial must be a non-negative integer');
    if (maximum !== undefined && (!Number.isInteger(maximum) || maximum < initial)) {
      throw new TypeError('Table: maximum must be an integer >= initial');
    }
    this._max = maximum ?? 65536;
    this._elements = new Array(initial).fill(null);
  }

  /** Current element count. */
  get length() { return this._elements.length; }

  /** Read one element. */
  get(index) {
    if (!Number.isInteger(index) || index < 0 || index >= this._elements.length) {
      throw new RangeError('Table.get: index out of bounds');
    }
    return this._elements[index];
  }

  /** Write one element. */
  set(index, value) {
    if (!Number.isInteger(index) || index < 0 || index >= this._elements.length) {
      throw new RangeError('Table.set: index out of bounds');
    }
    this._elements[index] = value;
  }

  /** Grow by `delta` elements, returning the previous size or -1. */
  grow(delta) {
    if (!Number.isInteger(delta) || delta < 0) throw new RangeError('Table.grow: delta must be a non-negative integer');
    const next = this._elements.length + delta;
    if (next > this._max) return -1;
    const previous = this._elements.length;
    while (this._elements.length < next) this._elements.push(null);
    return previous;
  }
}

/** Global holder; values are inert. */
class Global {
  constructor(descriptor = {}) {
    this.value = descriptor.value;
    this.mutable = descriptor.mutable === true;
  }

  valueOf() { return this.value; }
}

/** Compilation is impossible without an engine: say so, loudly. */
class Module {
  constructor() {
    throw new CompileError(JITLESS_REASON);
  }

  static compile() {
    return Promise.reject(new CompileError(JITLESS_REASON));
  }

  static compileStreaming() {
    return Promise.reject(new CompileError(JITLESS_REASON));
  }

  static instantiate() {
    return Promise.reject(new CompileError(JITLESS_REASON));
  }
}

/** Instantiation needs a module, so it can never succeed here. */
class Instance {
  constructor() {
    throw new CompileError(JITLESS_REASON);
  }

  static instantiate() {
    return Promise.reject(new CompileError(JITLESS_REASON));
  }
}

/** No module can exist, so no function can be exported. */
function exportedFunction() {
  throw new RuntimeError(JITLESS_REASON);
}

const WebAssemblyNamespace = {
  CompileError,
  LinkError,
  RuntimeError,
  Memory,
  Table,
  Global,
  Module,
  Instance,
  Function: exportedFunction,
  validate: () => false,
  compile: Module.compile,
  compileStreaming: Module.compileStreaming,
  instantiate: Module.instantiate,
  instantiateStreaming: () => Promise.reject(new CompileError(JITLESS_REASON)),
};

/**
 * Install the namespace when the engine removed it.
 * @param {object} [target] - object to define on; defaults to globalThis.
 * @returns {{ installed: boolean, reason: string }} what happened.
 */
function install(target = globalThis) {
  if (typeof target.WebAssembly !== 'undefined') {
    return { installed: false, reason: 'a real WebAssembly namespace is already present' };
  }
  // Mark the stub so later probes can tell "the global exists because we faked
  // it" from "this build really supports wasm". Without the marker,
  // `typeof WebAssembly === 'object'` reads as wasm support on a jitless build,
  // which is exactly the wrong conclusion.
  try {
    Object.defineProperty(WebAssemblyNamespace, '__iosSimStub', {
      value: true,
      enumerable: false,
      configurable: false,
      writable: false,
    });
  } catch {
    // A frozen namespace would make the marker impossible; the capability probe
    // in ios-app-entry.mjs still catches the stub by failing to compile.
  }
  Object.defineProperty(target, 'WebAssembly', {
    value: WebAssemblyNamespace,
    configurable: true,
    writable: true,
    enumerable: false,
  });
  return { installed: true, reason: 'jitless removed WebAssembly; installed a load-only stub' };
}

module.exports = { install, WebAssemblyNamespace, JITLESS_REASON, CompileError, LinkError, RuntimeError, Memory, Table };
