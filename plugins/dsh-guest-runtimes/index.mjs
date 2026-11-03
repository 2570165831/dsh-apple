// `dsh-guest-runtimes`: state what the guest's `python3`, `node` and `npm` can do,
// and what they cannot, in the assembled system prompt.
//
// WHY THIS IS A PLUGIN AND NOT PART OF `dsh-fs-ios`. That plugin owns the path
// rule; this one owns a fact about the image. They change for different reasons —
// a new package in `ish/scripts/build-rootfs.sh` changes this one and leaves the
// path rule alone — and a composition that removes one should not have to keep the
// other's text.
//
// WHY IT IS WORDED AS CAPABILITIES RATHER THAN A VERSION LIST. "The guest has
// Python 3.12.16" is not something a model can act on. "You can run a script,
// write files, use sqlite3 and threads, and reach HTTPS; you cannot install
// anything, because there is no pip and no compiler" is. Every claim below was
// measured inside the app's guest by `sim/step24-acceptance.mjs`, and the numbers
// are in `REPORT-24.md` §3.
//
// A/B SWITCH: `DSHPORTE_GUEST_RUNTIME_NOTE=0` removes the section, the same way
// `DSHPORTE_RECOVERY_NOTE=0` removes step 8's. That is how the assembled prompt is
// compared with and without it on one build.

/** The prompt section this plugin owns; named so a composition can replace it. */
const RUNTIME_SECTION = 'ios:guest-runtimes';

/**
 * The text. Written as a list of sentences rather than a table because the model
 * reads it as guidance, and because a table's columns would have to be invented
 * to describe "works, but not for that".
 */
const RUNTIME_TEXT = [
  'The shell environment is a small Alpine Linux guest emulated inside the app. Support for its',
  'runtimes is experimental.',
  '',
  '`python3` 3.12 runs scripts from a file, JSON, atomic file replacement with `os.replace`,',
  '`sqlite3` (with transactions and rollback), `zipfile` and `gzip`, threads, `subprocess` with',
  'pipes and timeouts, and HTTPS requests with a verified certificate chain.',
  'The system interpreter has no `pip`. `python3 -m venv` works, and a venv can install',
  'pure-Python packages from the network.',
  '',
  '`node` 22 runs CommonJS and ES modules, file streams, timers, `child_process` and TLS. `npm`',
  'can `init`, install from the registry, `run`, and `npx` runs a locally installed package.',
  '',
  'There is no C compiler, `make` or Python headers, so a dependency with a native module or a C',
  'extension will not install: look for a pure JavaScript or pure Python alternative rather than',
  'retrying. Neither runtime can be added to with `apk`, which is not in the image.',
  'A crash inside `node` can still report exit code 0, so after `npm install` or any step that',
  'matters, check the result itself (the files, the output) rather than only the exit code.',
  '',
  'Everything here is much slower than on a computer: a tight CPU loop takes roughly 50 times as',
  'long in Python and over 100 times as long in Node, even before counting a phone. Prefer one',
  'script over a loop of small invocations, and work from files rather than long one-liners.',
].join(' ');

/**
 * Install the section.
 * @param {object} ctx - the cordis context.
 */
function apply(ctx) {
  if (process.env.DSHPORTE_GUEST_RUNTIME_NOTE === '0') return;

  ctx.inject(['systemPrompt'], (scoped) => {
    scoped.systemPrompt.section({
      name: RUNTIME_SECTION,
      // Immediately after the path rule: a model that has just learned which
      // namespace to use in a shell is about to write its first command, and this
      // is the paragraph that should be in front of it at that moment.
      order: scoped.systemPrompt.getSectionOrder('TOOL_BASH') + 2,
      text: () => RUNTIME_TEXT,
    });
  });
}

export { RUNTIME_SECTION, RUNTIME_TEXT };
export default { name: 'guest-runtimes', apply, inject: [] };
