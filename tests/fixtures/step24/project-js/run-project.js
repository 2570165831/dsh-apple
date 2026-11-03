'use strict';
// The JavaScript project used by step 24's "real project" criterion.
//
// Why it is a generator rather than a checked-in tree: the criterion is "install
// the dependencies, then run the tests", and the tree has to be written into the
// GUEST, where the only writable places are `/workspace` and the guest's own
// rootfs. Committing the tree and copying it in would need a copy step that does
// not exist in the guest (no host→guest file push except the bind mount), so the
// project is written by this script through plain `fs` calls.
//
// What it exercises, and why each part is here:
//
//   * a real third-party dependency (`ms`, the same package the npm criterion
//     installs) — so `node_modules` resolution, not just a relative import;
//   * `node --test`, which is the test runner that ships with Node, so the
//     project has a test story without adding a dev dependency;
//   * an ES module source file imported from a CommonJS test, which is the
//     interop path a real project hits first;
//   * a deliberate failure assertion, run once, so the "tests pass" claim is not
//     made by a runner that cannot fail.
//
// The script prints ONE json line. Everything else it prints goes to stderr, so
// the caller can parse the verdict without depending on output order.

const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const root = process.argv[2];
if (!root) {
  process.stderr.write('usage: node run-project.js <dir>\n');
  process.exit(2);
}

/** Run a shell command in the project, returning its exit code and output. */
function shell(command, extraEnv = {}) {
  const started = Date.now();
  try {
    const stdout = execFileSync('sh', ['-c', command], {
      cwd: root,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
      env: { ...process.env, ...extraEnv },
      timeout: 600_000,
    });
    return { command, exitCode: 0, stdout, stderr: '', seconds: (Date.now() - started) / 1000 };
  } catch (error) {
    return {
      command,
      exitCode: typeof error.status === 'number' ? error.status : null,
      stdout: String(error.stdout ?? ''),
      stderr: String(error.stderr ?? error.message),
      seconds: (Date.now() - started) / 1000,
    };
  }
}

const files = {
  'package.json': `${JSON.stringify({
    name: 'step24-project-js',
    version: '1.0.0',
    private: true,
    description: 'A small project that installs a dependency and runs its tests',
    main: 'src/index.js',
    scripts: {
      test: 'node --test',
      start: 'node src/cli.js',
    },
    dependencies: { ms: '2.1.3' },
  }, null, 2)}\n`,

  'src/index.js': `'use strict';
// A CommonJS module that leans on the installed dependency. The point is that
// \`require('ms')\` resolves through node_modules the way a real project does.
const ms = require('ms');

/** Render a duration in the largest unit that reads naturally. */
function humanise(milliseconds) {
  if (typeof milliseconds !== 'number' || Number.isNaN(milliseconds)) {
    throw new TypeError('humanise expects a number of milliseconds');
  }
  return ms(milliseconds, { long: true });
}

/** Add up durations given as {value, unit} pairs. */
function totalMs(parts) {
  return parts.reduce((sum, part) => sum + ms(part.value + part.unit), 0);
}

module.exports = { humanise, totalMs };
`,

  'src/esm-format.mjs': `// An ES module in the same project as the CommonJS one above. A real project
// ends up with both, and the interop edge is where module resolution breaks first.
export function pad(value, width = 6) {
  return String(value).padStart(width, ' ');
}

export default { pad };
`,

  'src/cli.js': `#!/usr/bin/env node
'use strict';
const { humanise, totalMs } = require('./index');

process.stdout.write(humanise(totalMs([{ value: 2, unit: 'd' }, { value: 3, unit: 'h' }])) + '\\n');
`,

  'test/index.test.js': `'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { humanise, totalMs } = require('../src/index');

test('humanise renders days in long form', () => {
  assert.equal(humanise(totalMs([{ value: 2, unit: 'd' }, { value: 3, unit: 'h' }])), '2 days');
});

test('humanise rejects a non-number', () => {
  assert.throws(() => humanise('soon'), TypeError);
});

test('totalMs adds mixed units', () => {
  assert.equal(totalMs([{ value: 1, unit: 'h' }, { value: 30, unit: 'm' }]), 5400000);
});
`,

  'test/esm-interop.test.js': `'use strict';
// A CommonJS test importing an ES module. This is the interop path that fails
// with "must use import to load ES Module" when the module type is wrong.
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { pathToFileURL } = require('node:url');

test('the ESM module can be imported and used', async () => {
  const module = await import(pathToFileURL(path.join(__dirname, '..', 'src', 'esm-format.mjs')).href);
  assert.equal(module.pad(42), '    42');
  assert.equal(module.default.pad(7, 3), '  7');
});
`,
};

const out = { root, files: [] };

for (const [name, content] of Object.entries(files)) {
  const target = path.join(root, name);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, content);
  out.files.push({ name, bytes: Buffer.byteLength(content) });
}

out.install = shell('npm install --no-audit --no-fund 2>&1');
out.installed_modules = fs.existsSync(path.join(root, 'node_modules'))
  ? fs.readdirSync(path.join(root, 'node_modules')).filter((entry) => !entry.startsWith('.'))
  : [];

// The runner must be able to fail: a suite that always passes proves nothing
// about the project, only about the harness.
out.negative_control = shell(
  'node --test > /tmp/negative.txt 2>&1; rc=$?; tail -4 /tmp/negative.txt; printf "\\nEXIT=%s\\n" "$rc"',
  { STEP24_EXPECT_FAILURE: '1' },
);
fs.writeFileSync(path.join(root, 'test', 'zz-deliberate-failure.test.js'),
  "'use strict';\nconst test = require('node:test');\nconst assert = require('node:assert/strict');\n"
  + "test('this one must fail', () => { assert.equal(1, 2); });\n");
out.negative_control = shell('node --test > /tmp/negative.txt 2>&1; rc=$?; tail -6 /tmp/negative.txt; echo "EXIT=$rc"');
fs.unlinkSync(path.join(root, 'test', 'zz-deliberate-failure.test.js'));

out.test = shell('npm test 2>&1; echo "EXIT=$?"');
out.start = shell('npm start 2>&1; echo "EXIT=$?"');
out.dependency_version = (() => {
  try {
    return JSON.parse(fs.readFileSync(path.join(root, 'node_modules', 'ms', 'package.json'), 'utf8')).version;
  } catch {
    return null;
  }
})();
out.test_exit = /EXIT=0/.test(out.test.stdout) ? 0 : 1;

process.stderr.write(out.test.stdout);
process.stdout.write(JSON.stringify(out) + '\n');
