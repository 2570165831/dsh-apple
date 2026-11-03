// `dsh-notify-ios`: turn the four things a user waits for into one line each on
// stdout, so the app shell can put a local notification on the phone.
//
// WHY THE SHELL CANNOT WORK THIS OUT FOR ITSELF
// ---------------------------------------------
// The four events are "a turn finished", "a turn failed", "a tool is waiting for
// approval" and "the agent asked a question". All four exist only inside DSH's
// durable session log, and a backgrounded process cannot be asked to answer
// questions about itself: a backgrounded WKWebView may be throttled, and the
// session log is zstd frames being appended to. So the observation happens where
// the events are published, which is `session/event` — the same published cordis
// event `dsh-agent-loop`, `dsh-agent-instructions`, `dsh-compaction-basic` and
// this task's own `busy-ios` subscribe to. Zero lines of DSH source change (see
// PATCHES.md P-26).
//
// WHY ONE LINE PER EVENT AND NOT A QUERY INTERFACE
// -----------------------------------------------
// The shell already owns fd 1 (it dup2s a pipe over it to read the launch token)
// and `NodeRunner.handleLine` already dispatches prefixed lines. A status
// query would need a second channel in the other direction, and the answer would
// arrive after the moment it was needed. Events push; that is the right shape.
//
// WHAT IS DELIBERATELY NOT IN THE PAYLOAD
// ---------------------------------------
// No prompt text, no tool arguments, no tool results, no command text, no
// stdout, no paths. The body is one of four short sentences (plus a truncated
// question for the question case). A notification is drawn on top of whatever
// the user is doing: it is the last place a token, a key or a path should be
// able to appear by accident. `NotificationBridge` scrubs what it is given as a
// second line of defence, but the payload does not carry the material in the
// first place.
//
// WHO GETS NOTIFIED
// -----------------
// Only sessions the user can see: the root of a session tree. A subagent's turn
// is reported to its parent agent, not to the person holding the phone, and a
// notification for it would be an interruption with no action behind it. The
// Session header says which kind a session is (`origin: 'subagent'`), and a
// header this build cannot read is treated as "not rooted" — silence is the
// safe failure for an interruption.

export const name = 'notify-ios';

/** The stdout prefix the app's line dispatcher looks for. */
const PREFIX = 'DSHPORTC_NOTIFY ';

/** Longest question excerpt kept, in characters. */
const QUESTION_LIMIT = 80;

/**
 * Chinese wording for the failure codes `dsh-llm` produces.
 *
 * The code is a stable identifier (`AUTH`, `RATE_LIMIT`, …); the prose beside it
 * is what the report and the notification use. An unknown code deliberately maps
 * to a fixed sentence rather than echoing the code, because the message this
 * vocabulary comes from can contain a provider URL.
 */
const FAILURE_LABELS = {
  AUTH: '认证失败',
  RATE_LIMIT: '被服务限流',
  QUOTA_EXCEEDED: '额度用尽',
  SERVER: '服务端错误',
  TIMEOUT: '超时',
  TRANSPORT: '网络中断',
  INVALID_REQUEST: '请求无效',
  CONTEXT_WINDOW_EXCEEDED: '上下文超长',
  EMPTY_RESPONSE: '模型返回了空回复',
  PI_AI_ERROR: '模型接口出错',
  ABORTED: '已中断',
};

/**
 * The English rule name inside `ish-approval-policy`'s audit reason.
 *
 * `dsh-user-approval` records `reason` on `approval/asked`, and that reason is
 * the policy's English audit string — the dialog's Chinese sentence
 * (`displayReason.zh`) is not part of the durable event. Rather than invent a
 * second translation, this reads the rule name back out of the audit string and
 * looks the label up in the one rule table that owns it. A reason this build does
 * not recognise falls back to a sentence that still tells the truth.
 */
const APPROVAL_REASON = /matches the "([^"]+)" rule/u;

/** Chinese labels, keyed by the audit reason `ish-approval-policy` writes. */
const APPROVAL_LABELS = {
  'recursive or forced delete': '递归或强制删除',
  delete: '删除文件',
  'raw device or filesystem write': '直接写设备或文件系统',
  'irreversible git operation': '不可撤销的 git 操作',
  'recursive permission change': '递归修改权限或属主',
  'fork bomb': 'fork 炸弹',
  'privilege escalation': '提权',
};

/**
 * Is this a session the user can see?
 * @param {object|undefined} session - the session the event belongs to.
 * @returns {boolean} true for a session-tree root.
 */
function isRootSession(session) {
  const header = session?.header;
  if (header === undefined || header === null) return false;
  if (header.origin === 'subagent') return false;
  if (header.parentSession !== undefined) return false;
  return true;
}

/**
 * The first question's text from one `ask_user_question` call.
 *
 * Read from the recorded arguments rather than from a projection: the projection
 * only tracks the timed variant of the tool (it keys off a `timeout` parameter),
 * and this build registers the legacy variant. The recorded arguments are the
 * same bytes the tool received, so both variants look identical from here.
 * @param {string} argumentsText - raw JSON arguments from `tool/call`.
 * @returns {string|undefined} the question text, trimmed to the limit.
 */
function questionText(argumentsText) {
  let parsed;
  try {
    parsed = JSON.parse(argumentsText);
  } catch {
    return undefined;
  }
  const questions = parsed?.questions;
  if (!Array.isArray(questions) || questions.length === 0) return undefined;
  const first = questions[0];
  const text = typeof first?.question === 'string' ? first.question : first?.header;
  if (typeof text !== 'string') return undefined;
  const flat = text.replace(/\s+/gu, ' ').trim();
  if (flat.length === 0) return undefined;
  return flat.length > QUESTION_LIMIT ? `${flat.slice(0, QUESTION_LIMIT)}…` : flat;
}

/**
 * Load the bridge.
 * @param {object} ctx - cordis context.
 */
export function apply(ctx) {
  /** sessionId -> latest title, so a notification is labelled with it. */
  const titles = new Map();
  /**
   * Dedupe keys already sent, so one approval cannot produce two banners.
   *
   * Insertion-ordered, and trimmed from the front once it is longer than a few
   * hundred entries: the keys for approvals and questions are removed when the
   * thing is settled, but the per-turn `done`/`error` keys are not, and a process
   * that lives for days must not accumulate them without bound.
   */
  const sent = new Set();

  const write = (payload) => {
    // One write, one line. Nothing else in this package interleaves on fd 1.
    process.stdout.write(PREFIX + JSON.stringify(payload) + '\n');
  };

  const publish = (payload) => {
    if (typeof payload.key === 'string') {
      if (sent.has(payload.key)) return;
      sent.add(payload.key);
      if (sent.size > 512) {
        const oldest = sent.values().next();
        if (oldest.done === false) sent.delete(oldest.value);
      }
    }
    write(payload);
  };

  /**
   * The session's title, from the events seen so far or from the title
   * projection when the title was logged before this plugin mounted.
   *
   * A build without `dsh-session-title` composed simply has no projection to
   * ask, which is why the second source is optional and last: the app falls back
   * to `DSH` rather than to an internal name.
   * @param {object} session - the session the notification is about.
   * @param {string} sessionId - its id.
   * @returns {string} the title, or an empty string.
   */
  const titleOf = (session, sessionId) => {
    const seen = titles.get(sessionId);
    if (typeof seen === 'string' && seen.length > 0) return seen;
    const projected = ctx.get('sessionProjections')?.stateOf(session, 'title');
    return typeof projected === 'string' ? projected : '';
  };

  const abandon = (key) => {
    if (!sent.has(key)) return;
    sent.delete(key);
    write({ kind: 'dismiss', key });
  };

  ctx.on('session/event', (session, event) => {
    const type = event?.type;
    if (typeof type !== 'string') return;
    const data = event?.data ?? {};
    const sessionId = session?.header?.id ?? session?.id;
    if (typeof sessionId !== 'string' || sessionId === '') return;

    if (type === 'session/title') {
      if (typeof data.title === 'string' && data.title.length > 0) titles.set(sessionId, data.title);
      return;
    }

    // The dismissal half runs before the root-session filter on purpose: a
    // notification that was already delivered has to be withdrawable even if the
    // session that produced it is no longer identifiable.
    if (type === 'approval/decided') {
      if (typeof data.id === 'string') abandon(`approval:${data.id}`);
      return;
    }
    if (type === 'tool/result') {
      const callId = data?.message?.toolCallId;
      if (typeof callId === 'string') abandon(`question:${callId}`);
      return;
    }

    if (!isRootSession(session)) return;

    switch (type) {
      case 'turn/start': {
        // Not a notification: this is the moment the app is allowed to ask iOS
        // for permission, because there is now a turn whose end the user might
        // want to hear about. Asking at launch would be a prompt with nothing
        // behind it.
        write({ kind: 'turn-start', sessionId });
        break;
      }
      case 'turn/end': {
        const reason = data.reason ?? {};
        const kind = reason.kind;
        // A turn the user cancelled produces `aborted`; so does a turn the
        // framework tore down with the process. Neither is news, and telling
        // someone their own cancellation finished would be worse than silence.
        if (kind === 'completed') {
          publish({
            kind: 'done',
            sessionId,
            title: titleOf(session, sessionId),
            body: '这一轮做完了',
            key: `done:${sessionId}:${data.turn ?? 0}`,
          });
          break;
        }
        if (kind === 'error') {
          const code = typeof reason.error?.code === 'string' ? reason.error.code : '';
          publish({
            kind: 'error',
            sessionId,
            title: titleOf(session, sessionId),
            body: `出错：${FAILURE_LABELS[code] ?? '未知错误'}`,
            code,
            key: `error:${sessionId}:${data.turn ?? 0}`,
          });
        }
        // `blocked`, `max-tokens`, `interrupted`, `forked` and `aborted` do not
        // map to any of the four things the user asked to be told about.
        break;
      }
      case 'approval/asked': {
        if (typeof data.id !== 'string') break;
        const reason = typeof data.reason === 'string' ? data.reason : '';
        const matched = APPROVAL_REASON.exec(reason);
        const label = matched === null ? undefined : APPROVAL_LABELS[matched[1]];
        publish({
          kind: 'approval',
          sessionId,
          title: titleOf(session, sessionId),
          body: label === undefined ? '有个操作在等你批准' : `等你批准：${label}`,
          key: `approval:${data.id}`,
        });
        break;
      }
      case 'tool/call': {
        if (data.name !== 'ask_user_question') break;
        const callId = data.callId;
        if (typeof callId !== 'string') break;
        const text = questionText(typeof data.arguments === 'string' ? data.arguments : '');
        publish({
          kind: 'question',
          sessionId,
          title: titleOf(session, sessionId),
          body: text ?? '在等你回答问题',
          key: `question:${callId}`,
        });
        break;
      }
      default:
        break;
    }
  });

  // Announce the bridge, the same way `busy-ios` does: "the bridge mounted and
  // has nothing to say yet" and "the bridge never mounted" look identical from
  // the shell otherwise.
  process.stdout.write('notify-ios: installed\n');
}

export default { name, apply };
