// ESM entry for the iOS simulation.
//
// Node's `--require` preload cannot register a module-resolve hook, and the
// flock redirect has to be in place BEFORE `dsh-session-persistence-jsonl`
// imports the native flock binding. This file does both jobs in one place:
//
//   1. `register()` the flock hook (sim/flock-hook.mjs) so that specifier lands
//      on the pure-JS stub;
//   2. `import()` the untouched dsh launcher.
//
// The iOS runtime restrictions themselves (dlopen, child_process, writes) are
// installed by `--require sim/ios-sim-preload.cjs`, which runs before this file
// so every module in the graph sees them.
//
// Usage:
//   node --jitless --expose-internals \
//     --require sim/ios-sim-preload.cjs \
//     sim/sim-entry.mjs --profile ios-sim --no-open --host 127.0.0.1 --port 19501

import { register } from 'node:module';
import { pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { existsSync } from 'node:fs';

const HERE = dirname(fileURLToPath(import.meta.url));
const WORKSPACE = join(HERE, '..');

/** Where the dsh install under test lives. */
const installRoot = process.env.IOS_SIM_DSH_INSTALL ?? join(WORKSPACE, 'install');
const launcher = join(installRoot, 'node_modules', '@deepseek-ai', 'dsh', 'lib', 'bin.js');

if (!existsSync(launcher)) {
  process.stderr.write(`ios-sim: dsh launcher not found at ${launcher}\n`);
  process.exit(1);
}

// The flock redirect must be registered before anything imports the plugin.
if (process.env.IOS_SIM_FLOCK_SHIM !== '0') {
  register('./flock-hook.mjs', pathToFileURL(HERE + '/'));
}

// dsh reads its own argv, so hand it the arguments this process received.
process.argv = [process.argv[0], launcher, ...process.argv.slice(2)];

// `bin.js` self-executes only under `import.meta.main`, which is false for an
// imported module, so call the exported entry point explicitly. This is the
// same function the launcher's own main guard calls.
const launcherModule = await import(pathToFileURL(launcher).href);
if (typeof launcherModule.runCli !== 'function') {
  process.stderr.write(`ios-sim: ${launcher} does not export runCli\n`);
  process.exit(1);
}
await launcherModule.runCli();
