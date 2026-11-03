// `dsh-sandbox-ios`: the `ctx.sandbox` provider for a phone that has no host
// confinement primitive.
//
// WHY THIS EXISTS AT ALL. `dsh-permission-presets` declares
//
//     static inject = ["shell", "approval", "sessions", "sessionProjections"]
//
// and its constructor throws unless the mounted bash executor confines:
//
//     if (ctx.shell.sandboxMode === void 0) throw new Error("permission: the mounted
//     bash executor does not confine (no sandboxMode) — presets bundle a sandbox mode …")
//
// `sandboxMode` reaches `ctx.shell` only through `dsh-bash-sandbox`, which
// requires `ctx.sandbox` + `ctx.sandboxPolicy`. So one of two things is true on
// iOS: either no `sandbox` provider is mounted, and then the permission preset
// table and the approval dialogs cannot mount at all — which is exactly what
// the previous profile hit (`permission`/`approval` had to be `disabled: true`,
// and session creation fell over behind that gate) — or a provider is mounted
// and it must be *honest* about what it can enforce.
//
// It is honest: iOS has neither Landlock nor bubblewrap nor Seatbelt for the
// app's own children, and this app's children are guest processes in an
// emulated kernel rather than host processes a sandbox could wrap at all. So
// this provider *fails closed*. Asking it to confine anything is a hard
// `SandboxUnavailableError`, never a silent unconfined pass-through — the seam
// forbids the latter in as many words ("silent unconfined passthrough is
// forbidden").
//
// The benign consequence, stated plainly: with `sandbox-policy` set to
// `danger-full-access` (which the profile does, and which is the only mode this
// device can actually deliver), `dsh-bash-sandbox` short-circuits before
// calling `confine()` at all, so commands still run. Switching to
// `workspace-write` or `read-only` in the UI then produces a real, explained
// refusal instead of a false claim of confinement.
//
// WHAT THE SECURITY BOUNDARY ACTUALLY IS: the iOS App sandbox. Guest processes
// see the app container and nothing else, and the guest cannot reach the host
// filesystem outside the bind-mounted workspace. That is a real boundary, but it
// is not a *per-command* policy, and the approval dialog this composition
// re-enables governs escalations rather than confining anything.

/** Resolve payload packages by their exports map; see the note in the subprocess provider. */
const { createRequire } = process.getBuiltinModule('node:module');
const { pathToFileURL, fileURLToPath } = process.getBuiltinModule('node:url');
const { join, resolve: resolvePath } = process.getBuiltinModule('node:path');

const HERE = fileURLToPath(new URL('.', import.meta.url));
const PAYLOAD_ROOT = process.env.IOS_SIM_DSH_INSTALL ?? resolvePath(HERE, '..', '..', 'payload');
const requireFromPayload = createRequire(join(PAYLOAD_ROOT, 'package.json'));

/** Import a payload package by bare specifier. */
async function importFromPayload(specifier) {
  return import(pathToFileURL(requireFromPayload.resolve(specifier)).href);
}

const { SandboxProvider, SandboxUnavailableError } = await importFromPayload('@deepseek-ai/dsh-sandbox');

/** Cordis plugin name used in loader diagnostics. */
export const name = 'sandbox-ios';

/** Modes this provider can actually deliver. */
const ENFORCEABLE_MODES = new Set(['danger-full-access']);

/**
 * The iOS sandbox provider: it can only ever say "unconfined".
 *
 * `confine()` is total and refuses every genuinely confined request. It never
 * returns argv that claims confinement it does not have.
 */
class IosSandboxProvider extends SandboxProvider {
  /**
   * Report the enforcement this composition provides for one mode.
   *
   * `danger-full-access` is not a sandbox, so this returns nothing for it: the
   * caller (`dsh-bash-sandbox`) checks the mode itself and skips `confine()` in
   * that case, which is the correct path.
   *
   * @param {string[]} argv - the argv the caller is about to spawn.
   * @param {object} policy - the resolved file-effect policy.
   * @returns {never} always throws; nothing on this platform is enforceable.
   */
  confine(argv, policy) {
    const mode = policy?.mode;
    throw new SandboxUnavailableError(
      mode ?? 'unknown',
      'iOS has no host process-confinement primitive (no Landlock, no bubblewrap, no Seatbelt for app children), and the '
      + 'commands this build runs are emulated guest processes inside the app, which no host runner can wrap. '
      + 'The App sandbox is the boundary; use danger-full-access.',
    );
  }

  /**
   * Which modes this provider can enforce, for consumers that ask rather than
   * assume. Empty-by-construction for anything but the unconfined mode.
   * @param {string} mode - the requested mode.
   * @returns {boolean} whether this provider can enforce it.
   */
  canEnforce(mode) {
    return ENFORCEABLE_MODES.has(mode);
  }
}

/**
 * Load the provider.
 * @param {object} ctx - cordis context.
 */
export function apply(ctx) {
  ctx.plugin(IosSandboxProvider);
}

export { IosSandboxProvider, ENFORCEABLE_MODES };
export default { name, apply, inject: [] };
