// `dsh-fs-ios`: the `ctx.fs` provider for the iOS port. Two jobs, both about
// one fact: **the model sees two path namespaces and only one of them is real
// to the guest.**
//
// THE FACT. The app's workspace lives at
// `/var/mobile/Containers/Data/Application/<uuid>/Documents/workspace` on the
// host (a container UUID that changes on every reinstall), and the *same*
// directory is bind-mounted into the embedded iSH guest at `/workspace`. Every
// bash command runs in the guest, so bash prints and accepts `/workspace/...`.
// Every file tool runs in Node on the host, so `read`/`write`/`edit`/`ls` take
// host paths. A model that has just run `ls /workspace` and then calls
// `read /workspace/x.md` gets
//
//     cannot read "/workspace/x.md": not found
//
// which is true and useless: the file is right there, under the other spelling.
// Measured on the phone in step 7's input.
//
// JOB 1: ACCEPT THE GUEST SPELLING. `resolve()` and `lstat()` are the only two
// entry points in `LocalFileSystem` that take a raw model-supplied path (every
// other method takes an already-resolved target, and `dsh-tool-fs` reaches the
// provider through those two). Translating a guest path to its host counterpart
// there means one rule covers read, write, edit, ls, present, the workspace
// file browser and `read_image` — without touching `dsh-tool-fs`,
// `dsh-fs-local` or `dsh-fs-sandbox`, which is the same "replace the seam, not
// the consumer" argument as P-6/P-10.
//
// JOB 2: STATE THE RULE TO THE MODEL. One prompt section says which namespace
// bash uses, which one the file tools use, and that both are accepted. Without
// it the model has to discover the mapping by trial and error, which is exactly
// what the phone run did.
//
// WHY A SUBCLASS OF `SandboxedFileSystem`. The stock provider is
// `@deepseek-ai/dsh-fs-sandbox`, which is `LocalFileSystem` plus the per-call
// policy fence. Subclassing keeps the fence, the atomic write, the read-match-
// write edit critical section, the realpath-derived target identity and the
// diff basis untouched — this file only adds one translation in front of two
// methods. `dsh-fs-sandbox` is the row this plugin replaces in the profile, so
// there is no second `ctx.fs`.
//
// IT DOES NOT MAKE THE GUEST A SECOND FILESYSTEM. The guest path is translated
// to the host path and then handled entirely by the host provider: version
// tokens, mtime, staleness and the containment fence all keep working, because
// after translation the target is an ordinary host file. Nothing here writes
// through the guest channel, and no `fakefs` metadata is involved.

const { createRequire } = process.getBuiltinModule('node:module');
const { pathToFileURL, fileURLToPath } = process.getBuiltinModule('node:url');
const { basename, dirname, join, resolve: resolvePath, sep } = process.getBuiltinModule('node:path');

const HERE = fileURLToPath(new URL('.', import.meta.url));
const PAYLOAD_ROOT = process.env.IOS_SIM_DSH_INSTALL ?? resolvePath(HERE, '..', '..', 'payload');
const requireFromPayload = createRequire(join(PAYLOAD_ROOT, 'package.json'));

/** Import a payload package by bare specifier, following its `exports` map. */
async function importFromPayload(specifier) {
  return import(pathToFileURL(requireFromPayload.resolve(specifier)).href);
}

const { SandboxedFileSystem } = await importFromPayload('@deepseek-ai/dsh-fs-sandbox');
const { FsError } = await importFromPayload('@deepseek-ai/dsh-fs');
const { canonicalPath, createFenceChecker, fenceMessage } = await import(new URL('./lib/fence.mjs', import.meta.url).href);

/** Cordis plugin name used in loader diagnostics. */
export const name = 'fs-ios';

/** The prompt section this plugin owns; named so a composition can replace it. */
const PATHS_SECTION = 'ios:path-namespaces';

/**
 * The recovery note this plugin owns (step 8).
 *
 * WHY IT IS HERE AND NOT IN DSH. The report that prompted it — a file created by
 * `write`, deleted by a bash `rm`, then refused by `write` with `file no longer
 * exists — re-read the file, then retry` — looks like a deadlock, because the
 * remedy it names cannot succeed: the file is gone, so `read` fails too.
 *
 * It is not a deadlock, and the mechanism was measured on this port rather than
 * inferred. `dsh-tool-fs`'s `resolveRegularReadTarget` emits
 * `fs/observed {kind:"absent"}` BEFORE it throws `FS_NOT_FOUND`
 * (`dsh-tool-fs/lib/index.js:195`), and `dsh-fs-observation-policy`'s
 * `writeIntent` resolves a confirmed-absent target to `{kind:"createIfAbsent"}`
 * instead of `{kind:"replaceIfVersion"}`. So the failing read clears the stale
 * `present@v1` record, and the next `write` takes the guarded-create path and
 * succeeds. Measured end to end in a real agent turn: steps 5 and 6 of
 * `prompts/17-step8-rmtest.txt` (TRANSCRIPT in REPORT-8).
 *
 * The gap is therefore not in the policy but in what the model is told: the error
 * says "re-read" without saying that a read of a deleted file is the intended
 * move rather than a second mistake, and a model that reads the second error as
 * confirmation of a deadlock reaches for bash or a new filename instead. One
 * sentence closes it. Nothing in the ordering above is port-specific — the two
 * packages are byte-identical to the desktop install — but the sentence is owned
 * here because this is where the port already states its own filesystem facts,
 * and P-20 records the alternative (patch DSH) that was not taken.
 */
const RECOVERY_SECTION = 'ios:deleted-file-recovery';

/**
 * The two roots, read once at mount.
 *
 * `DSH_GUEST_WORKSPACE` is set by the app only when the bind mount succeeded.
 * When it is absent there is no second namespace and every function here
 * becomes the identity — a host that could not share the workspace must not get
 * silent path rewriting on top of the failure it already has.
 *
 * @returns {{host: string, guest: string, tempHost: string, tempGuest: string}} the mount table.
 */
function mountTable() {
  const host = (process.env.DSH_IOS_WORKSPACE ?? '').replace(/\/$/, '');
  const guest = (process.env.DSH_GUEST_WORKSPACE ?? '').replace(/\/$/, '');
  const tempHost = (process.env.DSH_HOST_TMPDIR ?? '').replace(/\/$/, '');
  const tempGuest = (process.env.DSH_GUEST_TMPDIR ?? '').replace(/\/$/, '');
  return {
    host,
    guest: host.length > 0 ? guest : '',
    tempHost,
    tempGuest: tempHost.length > 0 ? tempGuest : '',
  };
}

/**
 * Whether `path` is `root` itself or sits underneath it.
 *
 * A plain `startsWith` is wrong: `/workspace2` must not be claimed by
 * `/workspace`. The boundary is the separator.
 *
 * @param {string} path - candidate absolute path.
 * @param {string} root - absolute root to test.
 * @returns {boolean} true when the path is inside the root.
 */
function under(path, root) {
  if (root.length === 0) return false;
  if (path === root) return true;
  return path.startsWith(root + '/');
}

/**
 * Translate one model-supplied path from the guest namespace to the host one.
 *
 * The translations, in order:
 *
 *   * `/workspace/...`                 -> `<host workspace>/...`
 *   * `/tmp/...`                       -> `<host tmp>/...`
 *   * `<host workspace>/...` (already) -> unchanged
 *   * anything else                    -> unchanged
 *
 * The last case is deliberate and load-bearing. A path outside both mounts is
 * a host path the provider should answer honestly about: `/var/...` on the
 * device is the app container, and `/etc/passwd` is the host's. Rewriting those
 * would replace a clear ENOENT with a wrong answer.
 *
 * @param {string} path - the raw path from the model.
 * @returns {string} the path to hand the host provider.
 */
export function guestPathToHost(path) {
  const mounts = mountTable();
  if (typeof path !== 'string' || path.length === 0) return path;
  if (mounts.guest.length > 0 && under(path, mounts.guest)) {
    return `${mounts.host}${path.slice(mounts.guest.length)}`;
  }
  if (mounts.tempGuest.length > 0 && under(path, mounts.tempGuest)) {
    return `${mounts.tempHost}${path.slice(mounts.tempGuest.length)}`;
  }
  return path;
}

/**
 * Translate one host path into the guest spelling, for anything shown to the
 * model or put in a prompt.
 *
 * The reverse of {@link guestPathToHost}, and the half that makes the two
 * namespaces *coherent* rather than merely both acceptable: a `read` of a file
 * reports the guest path the model can paste straight into the next bash
 * command.
 *
 * @param {string} path - an absolute host path.
 * @returns {string} the guest spelling when the path is under a mount.
 */
export function hostPathToGuest(path) {
  const mounts = mountTable();
  if (typeof path !== 'string' || path.length === 0) return path;
  if (mounts.host.length > 0 && under(path, mounts.host)) {
    return `${mounts.guest}${path.slice(mounts.host.length)}`;
  }
  if (mounts.tempHost.length > 0 && under(path, mounts.tempHost)) {
    return `${mounts.tempGuest}${path.slice(mounts.tempHost.length)}`;
  }
  return path;
}

/**
 * The filesystem provider: the stock sandboxed host provider with the guest
 * namespace accepted at its two path-taking entry points.
 */
class IosFileSystem extends SandboxedFileSystem {
  // Plain fields, not `#private`: cordis hands services out through a Proxy, and
  // a private field access checks the receiver against the declaring class. See
  // the same note in plugins/dsh-subprocess-ish. Measured there; the mechanism is
  // identical here.

  /**
   * Resolve a model path, accepting either namespace.
   * @param {string} path - raw path from a tool argument.
   * @param {object} [opts] - resolution options (`cwd`, `signal`).
   * @returns {Promise<object>} the resolved target.
   */
  async resolve(path, opts) {
    const target = await super.resolve(guestPathToHost(path), opts);
    await this._fence(target);
    return target;
  }

  /**
   * Refuse a target inside the credential fence (see `lib/fence.mjs`).
   *
   * Called at `resolve` AND again in every method that takes a target: a target
   * object can outlive the check that produced it (a listing's children, a
   * symlink swapped between resolve and read), and the cost is a few `realpath`
   * calls against a refusal that must hold every time. `FS_PERMISSION_DENIED`,
   * not `FS_SANDBOX_DENIED`: the tool layer turns the latter into an escalation
   * hint, and no escalation can open this fence.
   *
   * @param {{targetKey: string, displayPath: string}} target - a resolved target.
   * @returns {Promise<void>} resolves when the target is allowed.
   */
  async _fence(target) {
    const fenced = await createFenceChecker();
    const key = String(target?.targetKey ?? '');
    const display = String(target?.displayPath ?? key);
    if (await fenced(key) || (display !== key && await fenced(display))) {
      throw new FsError(fenceMessage(display), 'FS_PERMISSION_DENIED');
    }
  }

  /** @inheritdoc */
  async stat(target, signal) {
    await this._fence(target);
    return super.stat(target, signal);
  }

  /** @inheritdoc */
  async readText(target, signal) {
    await this._fence(target);
    return super.readText(target, signal);
  }

  /** @inheritdoc */
  async streamText(target, signal) {
    await this._fence(target);
    return super.streamText(target, signal);
  }

  /** @inheritdoc */
  async readBytes(target, signal, maxBytes) {
    await this._fence(target);
    return super.readBytes(target, signal, maxBytes);
  }

  /** @inheritdoc */
  async readByteRange(target, range, signal) {
    await this._fence(target);
    return super.readByteRange(target, range, signal);
  }

  /** @inheritdoc */
  async writeText(target, content, expected, signal, sandboxPolicy) {
    await this._fence(target);
    return super.writeText(target, content, expected, signal, sandboxPolicy);
  }

  /** @inheritdoc */
  async editText(target, edit, expected, signal, sandboxPolicy) {
    await this._fence(target);
    return super.editText(target, edit, expected, signal, sandboxPolicy);
  }

  /** @inheritdoc */
  async watch(target, changed, signal) {
    await this._fence(target);
    return super.watch(target, changed, signal);
  }

  /**
   * List a directory with fenced children left out.
   *
   * Left out rather than shown and refused on open: the NAME `.credentials.yaml`
   * in a listing is already a fact the model has no use for, and an entry that
   * every follow-up call refuses is noise. A symlink child pointing into the
   * fence is left out too, because its `targetKey` is the realpath the provider
   * already computed. The listed directory itself goes through `_fence` first,
   * so listing `DSHPortC/` is an explicit refusal, not an empty result.
   *
   * @param {{targetKey: string, displayPath: string}} target - the directory.
   * @param {AbortSignal} [signal] - cancellation.
   * @returns {Promise<object[]>} the allowed children.
   */
  async listDir(target, signal) {
    await this._fence(target);
    const entries = await super.listDir(target, signal);
    const fenced = await createFenceChecker();
    const kept = [];
    for (const entry of entries) {
      const key = String(entry?.target?.targetKey ?? '');
      if (await fenced(key, { fresh: false })) continue;
      kept.push(entry);
    }
    return kept;
  }

  /**
   * Stat a model path without following a final symlink, accepting either
   * namespace.
   *
   * `lstat` builds its own display path instead of going through `resolve`, so
   * the translation has to be repeated here or `ls` on a guest path would list
   * the wrong thing while `read` on the same path worked.
   *
   * @param {string} path - raw path from a tool argument.
   * @param {object} [opts] - resolution options (`cwd`, `signal`).
   * @param {AbortSignal} [signal] - cancellation.
   * @returns {Promise<object|undefined>} the entry facts, or undefined.
   */
  async lstat(path, opts, signal) {
    const host = guestPathToHost(path);
    // Fenced on both readings of the path: the followed one and the entry itself,
    // so neither a symlink INTO the fence nor a symlink that merely sits there can
    // be probed for existence or size. A path the stock resolver cannot resolve
    // (a parent that is a file, `..` across a missing directory) is left to the
    // stock `lstat`, which answers those with `undefined` rather than a throw.
    if (typeof host === 'string' && host.trim().length > 0) {
      let followed;
      try {
        followed = await super.resolve(host, opts);
      } catch {
        followed = undefined;
      }
      if (followed !== undefined) {
        await this._fence(followed);
        const display = String(followed.displayPath);
        const entryKey = join(await canonicalPath(dirname(display)), basename(display));
        await this._fence({ targetKey: entryKey, displayPath: display });
      }
    }
    return super.lstat(host, opts, signal);
  }
}

/**
 * Load the provider and its two prompt sections.
 *
 * The recovery note is registered BEFORE the mount-table check on purpose: the
 * cycle it explains has nothing to do with there being two path namespaces for
 * one file. It is the ordinary single-filesystem case of "bash deleted a file a
 * tool had observed", and it would be wrong to say nothing about it on a launch
 * that had no bind mount.
 *
 * @param {object} ctx - cordis context.
 */
export function apply(ctx) {
  ctx.plugin(IosFileSystem);

  // The A/B switch, for the same reason P-16 has `DSHPORTE_RG_RESPELL`: an
  // acceptance criterion that only ever sees the fixed build cannot show that the
  // fix is what made the difference. `DSHPORTE_RECOVERY_NOTE=0` removes the
  // section, so the same build with the same code can be launched without it and
  // the assembled prompt compared.
  if (process.env.DSHPORTE_RECOVERY_NOTE !== '0') {
    ctx.inject(['systemPrompt'], (scoped) => {
      scoped.systemPrompt.section({
        name: RECOVERY_SECTION,
        // Just after the write/edit guidance it completes, and before the bulk of
        // the tool text: a model that hits the refusal rereads this block first.
        order: scoped.systemPrompt.getSectionOrder('TOOL_EDIT') + 1,
        text: () => [
          'A file that was observed and then deleted outside the file tools (by a shell command, another program, or a person) is NOT a dead end:'
          + ' a guarded write there fails with "file no longer exists — re-read the file, then retry" because the old version is stale,'
          + ' and a read of that path reports "not found" — and that failing read is the intended remedy, not a second error.'
          + ' It records the path as confirmed absent, so the next write (or str_replace_editor create) takes the create path and succeeds.'
          + ' So when a write or edit refuses a path that a shell command just deleted, call read on that path once and then repeat the same write;'
          + ' do not reach for a new filename and do not fall back to writing it from bash.',
        ].join(' '),
      });
    });
  }

  const mounts = mountTable();
  // Only state the path rule when there really are two namespaces. A launch
  // without a bind mount has one filesystem and the sentence would be false.
  if (mounts.guest.length === 0) return;

  ctx.inject(['systemPrompt'], (scoped) => {
    scoped.systemPrompt.section({
      name: PATHS_SECTION,
      order: scoped.systemPrompt.getSectionOrder('TOOL_BASH') + 1,
      text: () => [
        `Paths: shell commands run in a small Linux guest that sees this workspace at ${mounts.guest};`
        + ` file tools (read, write, edit, ls, glob, grep) see the same files at ${mounts.host}.`
        + ` Both spellings are accepted everywhere — ${mounts.guest}/a.txt and the host path name the same file —`
        + ` and paths reported by either are usable in the other.`,
      ].join(' '),
    });
  });
}

export { IosFileSystem, mountTable };
export default { name, apply, inject: [] };
