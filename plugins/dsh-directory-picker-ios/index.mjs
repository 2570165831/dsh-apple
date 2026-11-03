// `dsh-directory-picker-ios`: the in-app folder browser, confined to the App's
// own workspace folder.
//
// The stock browse backend (`dsh-host-directory-picker-browse`) lists the whole
// filesystem from `os.homedir()`. That is the right default for a laptop and the
// wrong one on a phone: the App sandbox already hides most of it, but a picker
// that offers `/` and other containers' parents is both confusing and an
// invitation to register a path the sandbox then refuses (the EPERM seen in
// step 4B). This subclass keeps the stock listing code and only adds a root:
//
//   * no path asked for  -> the workspace root (`DSH_IOS_WORKSPACE`)
//   * a path outside the root -> a normal `directory-unreadable` error
//   * breadcrumbs start at the root, so the UI cannot navigate above it
//   * creating a folder is allowed only inside the root
//
// It is pure `node:fs` (the parent class), no subprocess, no native addon.

const { createRequire } = process.getBuiltinModule('node:module');
const { pathToFileURL, fileURLToPath } = process.getBuiltinModule('node:url');
const { join, resolve: resolvePath, sep } = process.getBuiltinModule('node:path');
const { realpathSync } = process.getBuiltinModule('node:fs');

const HERE = fileURLToPath(new URL('.', import.meta.url));
const PAYLOAD_ROOT = process.env.IOS_SIM_DSH_INSTALL ?? resolvePath(HERE, '..', '..', 'payload');
const requireFromPayload = createRequire(join(PAYLOAD_ROOT, 'package.json'));
const importFromPayload = (specifier) => import(pathToFileURL(requireFromPayload.resolve(specifier)).href);

const { default: BrowseDirectoryPicker } = await importFromPayload('@deepseek-ai/dsh-host-directory-picker-browse');
const { DirectoryPickerError } = await importFromPayload('@deepseek-ai/dsh-host-directory-picker');

/** Cordis plugin name used in loader diagnostics. */
export const name = 'directory-picker-ios';

/**
 * The one canonical spelling — `realpath`, i.e. what `dsh-workspace` stores.
 *
 * STEP 9 CHANGED THE DIRECTION HERE, AND IT MATTERED. This used to fold
 * `/private/var/…` to `/var/…`, on the reasonable-sounding grounds that the two
 * name the same place and one is friendlier. But `list()` hands its `home` and its
 * `crumbs` to the client, and the client sends the chosen `path` straight back
 * through `workspaceController.create` → `dsh-workspace.create`, which canonicalises
 * it with `fs.realpath`. The fold therefore did nothing except make this plugin
 * disagree with the store about how to spell a path it was about to hand over: the
 * picked folder was reported as `/var/…`, DSH stored `/private/var/…`, and the
 * phone's dropdown ended up with both. Compare against `realpath`, hand back
 * `realpath`.
 *
 * @param {string} path - any absolute path.
 * @returns {string} the canonical spelling; unresolvable paths keep their own.
 */
function canonical(path) {
  let value = resolvePath(path);
  if (value === '/var') value = '/private/var';
  else if (value.startsWith('/var/')) value = `/private${value}`;
  try { value = realpathSync(value); } catch { /* the path may not exist yet */ }
  return value;
}

function rootDirectory() {
  const root = process.env.DSH_IOS_WORKSPACE;
  if (root === undefined || root === '') throw new Error('directory-picker-ios: DSH_IOS_WORKSPACE is not set');
  return canonical(root);
}

function inside(root, path) {
  const target = canonical(path);
  return target === root || target.startsWith(root + sep);
}

class IosDirectoryPicker extends BrowseDirectoryPicker {
  async list(path, signal) {
    const root = rootDirectory();
    const asked = path ?? root;
    if (!inside(root, asked)) {
      throw new DirectoryPickerError('directory-unreadable', asked, `cannot list "${asked}": outside the app workspace`);
    }
    // Ask the stock backend for the CANONICAL path, not for whatever spelling the
    // caller used. Two reasons, both measured shapes of the same bug: the listing's
    // own `path` is echoed back to the client and becomes the value the user picks,
    // and its `crumbs` are compared against `home` by `displayCrumbs` on the client
    // (`crumb.path === listing.home`). A `/var/…` caller would otherwise produce a
    // listing whose `path`, crumbs and `home` are in three different spellings.
    const listing = await super.list(canonical(asked), signal);
    const cut = listing.crumbs.findIndex((crumb) => canonical(crumb.path) === root);
    return {
      ...listing,
      home: root,
      crumbs: cut >= 0 ? listing.crumbs.slice(cut) : listing.crumbs,
    };
  }

  async createDirectory(path, folder) {
    const root = rootDirectory();
    if (!inside(root, path)) {
      throw new DirectoryPickerError('directory-create-failed', path, `cannot create under "${path}": outside the app workspace`);
    }
    // The stock backend returns `join(parent, name)`. Handing it the canonical
    // parent means the value it returns — which the client sends on as the folder
    // to register — is already in the spelling DSH stores, so a folder created
    // through the picker cannot be the origin of a second spelling.
    return super.createDirectory(canonical(path), folder);
  }
}

/**
 * Load the picker.
 * @param {object} ctx - cordis context.
 */
export function apply(ctx) {
  ctx.plugin(IosDirectoryPicker, {});
}

export { IosDirectoryPicker };
export default { name, apply, inject: [] };
