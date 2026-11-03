// `ish-approval-policy`: a real, small command policy that makes the approval
// dialog reachable on this device.
//
// WHY THIS IS NEEDED. `dsh-user-approval` only ever *asks* when some composition
// contributes an `ask` decision on the `tools/pre-execute` waterfall
// (`dsh-tools/lib/index.js:3321`). In the stock bundle the two contributors are
// per-call sandbox escalation (which needs a confining executor this device
// cannot provide — see `dsh-sandbox-ios`) and `dsh-experimental-auto-review`
// (which needs to bill an LLM call per tool invocation). With neither, the
// approval service exists and the UI panel is mounted, but nothing ever asks, so
// the dialog can never appear — and an acceptance criterion that says "the
// dialog appears on commands that need approval" would be untestable rather
// than merely unmet.
//
// So this plugin supplies the missing piece honestly: a fixed rule set that asks
// the user before a command whose *text* matches a destructive pattern. It is a
// genuine policy plugin — the same shape, on the same waterfall, that a real
// product would use — not a test hook wired into the harness. Nothing here is
// conditional on being under test.
//
// WHAT IT IS NOT: it is not a confinement mechanism. It reads the command string,
// so a command that obfuscates the operation (`base64 -d | sh`, a variable
// holding `rm`, a script it writes itself) is not caught. The profile says so;
// the App sandbox remains the actual boundary. This is a *human in the loop for
// obviously destructive commands*, which is exactly what it claims to be.

/** Cordis plugin name used in loader diagnostics. */
export const name = 'ish-approval-policy';

/** Services required: the tool registry and the approval seam. */
export const inject = ['tools', 'approval'];

/**
 * Patterns that require a human decision, with the reason shown in the dialog.
 *
 * Deliberately short and legible: every entry is a thing a user would want to
 * be asked about before it runs on their phone. Ordered most-specific first so
 * the reported reason is the most informative matching one.
 */
const RULES = [
  // `reason` is the audit string kept in the session log, and it stays in
  // English because that log is a machine- and developer-facing record. The
  // dialog is what the user reads, so each rule also carries a Chinese
  // `label`; that is what the sentence in the dialog is built from. The rules
  // themselves — patterns, order, and which one matches first — are untouched:
  // this is a wording change, not a policy change.
  {
    pattern: /\brm\s+(-[A-Za-z]*[rf][A-Za-z]*\s+)+/u,
    reason: 'recursive or forced delete',
    label: '递归或强制删除',
  },
  { pattern: /\brm\b/u, reason: 'delete', label: '删除文件' },
  {
    pattern: /\b(mkfs|fdisk|dd\s+[^|]*of=)/u,
    reason: 'raw device or filesystem write',
    label: '直接写设备或文件系统',
  },
  {
    pattern: /\bgit\s+(push|reset\s+--hard|clean\s+-[A-Za-z]*f)/u,
    reason: 'irreversible git operation',
    label: '不可撤销的 git 操作',
  },
  {
    pattern: /\b(chmod|chown)\s+-[A-Za-z]*R/u,
    reason: 'recursive permission change',
    label: '递归修改权限或属主',
  },
  { pattern: /:\s*\(\s*\)\s*\{.*\}\s*;\s*:/u, reason: 'fork bomb', label: 'fork 炸弹' },
  { pattern: /\bsudo\b/u, reason: 'privilege escalation', label: '提权' },
];

/**
 * Match one tool call against the rule set.
 * @param {object} exec - the tool execution being prepared.
 * @returns {{pattern: RegExp, reason: string} | undefined} the first matching rule.
 */
function matchRule(exec) {
  // Only shell commands are inspected. A `write` tool call is a file mutation
  // the fs layer already governs; pretending to review it here would be a
  // second, weaker opinion.
  if (exec?.name !== 'bash') return undefined;
  const command = exec.arguments?.command;
  if (typeof command !== 'string' || command.length === 0) return undefined;
  return RULES.find((rule) => rule.pattern.test(command));
}

/**
 * Load the policy.
 * @param {object} ctx - cordis context.
 */
export function apply(ctx) {
  ctx.on('tools/pre-execute', (exec, next) => {
    const rule = matchRule(exec);
    if (rule === undefined) return next();
    // `reason` is the English audit string the session log keeps; the localized
    // `displayReason` is what the dialog shows. Both are part of the seam's
    // contract (`dsh-user-approval`), so a client that only renders one still
    // has something to render.
    return {
      kind: 'ask',
      reason: `this command matches the "${rule.reason}" rule, which requires your approval`,
      displayReason: {
        en: `This command looks like: ${rule.label ?? rule.reason}. Allow it to run?`,
        zh: `这条命令看起来属于「${rule.label ?? rule.reason}」。允许执行吗？`,
      },
    };
  });
}

export { RULES, matchRule };
export default { name, apply, inject };
