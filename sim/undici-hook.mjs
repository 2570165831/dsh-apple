// ESM loader hook: answer `dsh-web-fetch-http`'s `import("undici")` with a
// transport that works without WebAssembly.
//
// WHY THIS EXISTS
// ---------------
// `@deepseek-ai/dsh-web-fetch-http` (the provider behind the model's `web_fetch`)
// does not use global `fetch`; it imports the npm `undici` package directly so it
// can hand it an `Agent` whose lookup is pinned to an already validated address
// set. undici parses HTTP/1.1 with llhttp, which is WebAssembly, and a jitless
// (iOS) Node has none. The request then rejects with
//
//     TypeError: fetch failed   (cause: ReferenceError: WebAssembly is not defined)
//
// and the tool reports only "web fetch failed: TypeError: fetch failed". Origins
// that negotiate HTTP/2 never reach llhttp, so they kept working: on a phone this
// looked like "some sites fetch, most do not" (measured: 18 of 26 calls in one
// session failed, every plain-http URL among them).
//
// `sim/fetch-polyfill.cjs` cannot help: it replaces GLOBAL fetch, and this import
// never touches the global.
//
// WHY A HOOK AND NOT A PATCH: same reasoning as `sim/ripgrep-hook.mjs` — the
// import is a dynamic `import()` inside module-private functions, with no service
// seam to plug into. Only that one importer is redirected; every other consumer of
// undici (the proxy policy, the model routes) keeps the real package.
//
// The real package's URL rides along as `?real=` so the stand-in can still reach
// it for a dispatcher it does not own (a configured proxy route).

import { pathToFileURL, fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));

/** The one importer whose `undici` is replaced. */
const WEB_FETCH_IMPORTER = /@deepseek-ai[/\\]dsh-web-fetch-http[/\\]lib[/\\]/;

/**
 * Whether this request is `dsh-web-fetch-http` asking for `undici`.
 * @param {string} specifier - the requested specifier.
 * @param {string|undefined} parentURL - the importing module.
 * @returns {boolean} true when this hook owns the request.
 */
export function isWebFetchUndici(specifier, parentURL) {
  return specifier === 'undici' && typeof parentURL === 'string' && WEB_FETCH_IMPORTER.test(parentURL);
}

/**
 * Redirect that one import; leave everything else to the default resolver.
 * @param {string} specifier - the requested specifier.
 * @param {object} context - `{ parentURL, conditions, importAttributes }`.
 * @param {Function} nextResolve - the default resolver.
 * @returns {Promise<object>} the resolution.
 */
export async function resolve(specifier, context, nextResolve) {
  if (isWebFetchUndici(specifier, context.parentURL)) {
    let real = '';
    try {
      real = (await nextResolve(specifier, context)).url;
    } catch {
      // A pruned payload may not carry undici at all; the stand-in then refuses a
      // foreign dispatcher by name instead of failing here.
    }
    const standIn = pathToFileURL(join(HERE, 'undici-web-fetch.mjs')).href;
    return { url: `${standIn}?real=${encodeURIComponent(real)}`, shortCircuit: true, format: 'module' };
  }
  return nextResolve(specifier, context);
}
