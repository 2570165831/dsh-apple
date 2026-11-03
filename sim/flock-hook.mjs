// ESM loader hook that reroutes `@deepseek-ai/node-addon-system/flock` to the
// pure-JS stub beside this file. Registered by `sim/sim-entry.mjs` with
// `module.register()` BEFORE dsh is imported, so the persistence plugin's
// import-time binding lands on the stub instead of the native addon.
//
// Only that one specifier is touched. Every other module resolves normally.

import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const STUB = pathToFileURL(join(HERE, 'flock-stub.mjs')).href;

/** The specifier(s) the persistence plugin and any peer may use. */
const FLOCK_SPECIFIERS = new Set([
  '@deepseek-ai/node-addon-system/flock',
]);

/** Whether `specifier` names the flock entry point in any accepted spelling. */
function isFlockSpecifier(specifier, parentURL) {
  if (FLOCK_SPECIFIERS.has(specifier)) return true;
  // A resolved absolute path to the real flock module also counts: the package's
  // own `./flock` export maps there, and a caller may import it directly.
  if (typeof specifier === 'string' && /node-addon-system[/\\]lib[/\\]flock\.js$/.test(specifier)) return true;
  if (specifier.startsWith('file://') && /node-addon-system[/\\]lib[/\\]flock\.js$/.test(specifier)) return true;
  return false;
}

/**
 * Redirect the flock specifier; leave everything else to the default resolver.
 * @param {string} specifier - the requested specifier.
 * @param {object} context - `{ parentURL, conditions, importAttributes }`.
 * @param {Function} nextResolve - the default resolver.
 * @returns {Promise<object>} the resolution.
 */
export async function resolve(specifier, context, nextResolve) {
  if (isFlockSpecifier(specifier, context.parentURL)) {
    return { url: STUB, shortCircuit: true, format: 'module' };
  }
  return nextResolve(specifier, context);
}

/** Present the stub with the named export the native module also offers. */
export async function load(url, context, nextLoad) {
  return nextLoad(url, context);
}
