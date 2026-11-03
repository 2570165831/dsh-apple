// Stand-in for `@vscode/ripgrep`, installed by `sim/ripgrep-hook.mjs`.
//
// THE CONTRACT. The real package exports one thing that
// `dsh-tool-fs-search` uses: `rgPath`, an absolute path to a ripgrep binary.
// This module exports the same name, but the value is the **guest's** ripgrep
// (`/usr/bin/rg` from the Alpine image), because that is the only ripgrep this
// process can actually start — `ctx.subprocess` runs commands in the guest, so a
// host path would be a path the executor cannot see.
//
// WHAT IT DOES NOT DO, DELIBERATELY. It does not check that the binary exists.
// That would move the failure here, at import time, where the tool cannot report
// it well: `resolveRgPath()` is awaited inside `runRipgrep`'s try/catch, which
// turns a rejection into "ripgrep launch failed" without saying which part failed.
// Leaving the path unchecked means the RESOLUTION always succeeds and the SPAWN is
// what reports a missing binary — through the provider's own
// `SubprocessExecutableNotFoundError`, which names the program and the guest PATH.
// A clearer error, in the place that knows what to say about it.
//
// The path is resolved from the environment the app publishes rather than assumed,
// so a build whose image did not include ripgrep fails loudly at the spawn instead
// of silently searching nothing.

import { existsSync } from 'node:fs';

/**
 * The guest's ripgrep, as an absolute question-free default.
 *
 * `/usr/bin/rg` is where the Alpine `ripgrep` package installs, recorded in
 * `RootfsPackages.md` from the image build itself rather than guessed. It is not
 * configurable: a second path would be a second thing to get wrong, and the guest
 * rootfs is built by this repository.
 */
export const rgPath = process.env.DSHPORTE_GUEST_RG ?? '/usr/bin/rg';

/** Diagnostics for the boot log: which path this stand-in reports, and why. */
export const guestRipgrep = {
  rgPath,
  guest: process.env.DSH_GUEST_WORKSPACE ?? null,
  // Whether the HOST happens to have that path. False on both device and
  // simulator, and it must not be read as a failure: the path is a guest path and
  // only the guest can answer whether it exists.
  hostHasIt: existsSync(rgPath),
};

export default { rgPath, guestRipgrep };
