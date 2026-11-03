// ESM loader hook: make `@vscode/ripgrep` resolvable inside the app.
//
// THE PROBLEM THIS SOLVES, AND WHY IT IS NOT "ADD A DEPENDENCY".
//
// `@deepseek-ai/dsh-tool-fs-search` — the plugin behind the model's `glob` and
// `grep` tools — resolves its search binary like this
// (`lib/index.js`, `resolveRgPath()`):
//
//     const dependency = (await import("@vscode/ripgrep")).rgPath;
//
// and it does that **before** it calls `ctx.subprocess.spawn`. So when the import
// fails, the failure is not a spawn failure at all:
//
//     Cannot find package '@vscode/ripgrep' imported from …/dsh-tool-fs-search/lib/index.js
//
// which the tool reports to the model as
//
//     grep could not start its search command (ripgrep launch failed)
//
// — exactly what the phone run saw, with `command -v rg` empty on top of it.
//
// Two independent facts made that import fail here, and only the first is a
// packaging choice:
//
//   1. `payload/` is a trimmed install. `@vscode/ripgrep` declares its binaries as
//      platform-specific OPTIONAL dependencies (`@vscode/ripgrep-darwin-arm64`
//      and eleven siblings), and nothing whose `os`/`cpu` matches `ios` exists to
//      install. The package directory is present and empty.
//   2. Even if a binary were unpacked there, the guest could not run it: it is a
//      glibc/macOS build, and the emulated kernel runs musl binaries from the
//      Alpine image.
//
// So the guest gets its own ripgrep from the image (`ripgrep` in
// ish/scripts/build-rootfs.sh, 14.1.1, recorded in RootfsPackages.md), and this
// hook answers the import with a module that reports **the guest's path** instead
// of a host path. The provider then respells it (see
// `respellGuestExecutable` in plugins/dsh-subprocess-ish) and `ctx.subprocess`
// runs `/usr/bin/rg` in the guest.
//
// WHY A LOADER HOOK AND NOT A PATCH TO THE TOOL: the tool's import is a dynamic
// `import()` inside a module private function — no service, no export, no
// subclass point. The alternative would be editing `payload/`, which this task
// reserves for cases with no other seam (PATCHES.md's rule). A resolve hook is the
// same mechanism `sim/flock-hook.mjs` already uses for the native flock addon.
//
// WHY NOT A FAKE `node_modules/@vscode/ripgrep` DIRECTORY: because the value it
// must export is not a constant. It is the guest's own path, which is only known
// after the guest is up, and on a device it is a path inside a container that
// changes per install. A static package would hard-code one of those.
//
// GATED: `sim/ios-app-entry.mjs` registers this only when the guest channel is
// configured — a launch without a guest has no `/usr/bin/rg` to point at, and must
// keep reporting the honest "package not found" instead of a path that cannot
// work.

import { pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));

/** The specifier `dsh-tool-fs-search` imports; nothing else is touched. */
const RIPGREP_SPECIFIERS = new Set(['@vscode/ripgrep']);

/**
 * Whether `specifier` names the ripgrep package in any accepted spelling.
 *
 * A resolved absolute path is also accepted: a caller may import the package's
 * own entry file directly, and that import has to land on the same stand-in.
 *
 * @param {string} specifier - the requested specifier.
 * @returns {boolean} true when this hook owns the request.
 */
function isRipgrepSpecifier(specifier) {
  if (typeof specifier !== 'string') return false;
  if (RIPGREP_SPECIFIERS.has(specifier)) return true;
  return /@vscode[/\\]ripgrep[/\\](lib[/\\])?index\.js$/.test(specifier);
}

/**
 * Redirect the ripgrep specifier; leave everything else to the default resolver.
 * @param {string} specifier - the requested specifier.
 * @param {object} context - `{ parentURL, conditions, importAttributes }`.
 * @param {Function} nextResolve - the default resolver.
 * @returns {Promise<object>} the resolution.
 */
export async function resolve(specifier, context, nextResolve) {
  if (isRipgrepSpecifier(specifier)) {
    return { url: pathToFileURL(join(HERE, 'ripgrep-guest.mjs')).href, shortCircuit: true, format: 'module' };
  }
  return nextResolve(specifier, context);
}
