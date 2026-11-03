// Pure-JS stand-in for `@deepseek-ai/node-addon-system/flock`.
//
// WHY: `dsh-session-persistence-jsonl` takes an exclusive POSIX flock on
// `<session-dir>/session.lock` before appending to a session log. The syscall is
// in `system.node`, a Node-API addon with no iOS build. Under the iOS simulation
// `process.dlopen` is blocked, so `tryLockExclusive` rejects with
// `ERR_DLOPEN_FAILED` and no session can ever be opened or resumed.
// (Measured: see logs/p3e-flock-unshimmed.log.)
//
// WHAT THIS DOES: admits the lock unconditionally, which is safe only because an
// iOS App hosts exactly one DSH process for one DSH_HOME — there is no second
// writer in the address space for the lock to arbitrate. This is the same
// trade-off dsh-ios shipped. It is a *shim*, not a fix: it does not detect a
// second process. If the same DSH_HOME were ever opened by two processes, the
// session log could interleave.
//
// To keep the shim honest even in that impossible-on-iOS case, it still
// verifies that the descriptor it is handed is a real open file and records the
// acquisition so a future two-process deployment would at least have a trace.

import { fstatSync } from 'node:fs';
import { appendFileSync } from 'node:fs';

const LOG_PATH = process.env.IOS_SIM_LOG;

function note(detail) {
  if (LOG_PATH === undefined || LOG_PATH === '') return;
  try {
    appendFileSync(LOG_PATH, JSON.stringify({
      t: new Date().toISOString(),
      pid: process.pid,
      kind: 'flock_shim.admit',
      ...detail,
    }) + '\n');
  } catch { /* never let the log break a session write */ }
}

/** @type {Set<number>} descriptors this process believes it holds. */
const held = new Set();

/**
 * Admit an exclusive lock on `fd` without the native addon.
 * @param {number} fd - descriptor the caller keeps open until it releases.
 * @returns {Promise<void>} always resolves.
 * @throws {TypeError} when `fd` is not an open descriptor, so a caller bug is
 *   still visible instead of being silently swallowed.
 */
export async function tryLockExclusive(fd) {
  // fstatSync throws EBADF for a closed/absent descriptor: that is a caller bug,
  // not lock contention, and must not be masked.
  fstatSync(fd);
  held.add(fd);
  note({ fd, held: held.size });
}

/**
 * Whether this process currently believes it holds `fd`.
 * @param {number} fd - descriptor to test.
 * @returns {boolean} true while the shim has admitted it and it was not released.
 */
export function holdsLock(fd) {
  return held.has(fd);
}

/**
 * Record that the caller released `fd` (closing the descriptor releases a real
 * flock too, so this only keeps the shim's bookkeeping aligned).
 * @param {number} fd - descriptor being closed.
 * @returns {void}
 */
export function forgetLock(fd) {
  held.delete(fd);
}
