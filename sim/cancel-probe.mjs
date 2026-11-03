// Does the workspace-changes git sequence complete when its paths are consistent?
//
// The plugin's chain is: rev-parse -> mkdtemp(host tmpdir) -> git add --all with
// GIT_OBJECT_DIRECTORY/GIT_INDEX_FILE under that dir -> write-tree -> diff-tree.
// The question this probe answers is which specific step the two-namespace split
// actually breaks, by running the sequence by hand with (a) everything in the
// guest namespace and (b) the mixed spelling the plugin produces.
import { exec } from '../plugins/dsh-subprocess-ish/lib/guest-channel.mjs';

const ws = '/workspace/deepseek-harness/default-workspace';
const guestScratch = '/tmp/ws-probe-consistent';

const runBoth = async (label, scratch) => {
  const script = [
    `rm -rf ${scratch}`,
    `mkdir -p ${scratch}/objects`,
    `cd ${ws}`,
    `export GIT_OBJECT_DIRECTORY=${scratch}/objects`,
    `export GIT_INDEX_FILE=${scratch}/index`,
    `cp .git/index ${scratch}/index 2>/dev/null || true`,
    `echo "== add"`,
    `git add --all --ignore-errors 2>&1; echo "add-rc=$?"`,
    `echo "== write-tree"`,
    `git write-tree 2>&1; echo "write-tree-rc=$?"`,
    `echo "== diff-tree"`,
    `git diff-tree -r -M -z --numstat HEAD $(git write-tree 2>/dev/null) 2>&1 | head -c 300; echo`,
    `echo "diff-tree-rc=$?"`,
  ].join('\n');
  const r = await exec({ command: script, timeoutMs: 90000, collect: true });
  console.log(`${label}-STDOUT`, JSON.stringify(r.stdout.slice(0, 900)));
  console.log(`${label}-EXIT`, r.exitCode);
};

// (a) consistent: scratch inside the guest's own /tmp
await runBoth('GUEST-SCRATCH', guestScratch);

// (b) the mixed spelling: the host's tmpdir, which the guest cannot see
const hostTmp = process.env.TMPDIR ?? '/tmp';
await runBoth('HOST-SCRATCH', `${hostTmp}ws-probe-mixed`);
process.exit(0);
