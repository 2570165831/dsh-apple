// Scripted replies for the mock model server, plus the decision logic that
// picks one for a given request.
//
// Two things matter for an end-to-end test of DSH inside an iOS process:
//
//   1. The reply must be chosen from REQUEST CONTENT, never from a counter held
//      in server memory. The app may restart, several sessions may interleave,
//      and a replayed request must get the same answer. So the whole decision is
//      a pure function of the messages array (plus the tools list).
//   2. A tool-call turn is a MULTI-TURN conversation. Turn 1 hands out a
//      tool call; the client executes it and sends the result back as a
//      `role: "tool"` message; turn 2 reads how many tool results already
//      exist to decide what comes next. That count is the "step".

import { createHash } from 'node:crypto';

/** Keyword that selects the tool-call script. */
export const TOOL_KEYWORD = 'TOOLTEST';
/** Keyword that selects the multi-chunk streaming-text script. */
export const STREAM_KEYWORD = 'STREAMTEST';

/**
 * Keyword that selects the long-line code-block script.
 *
 * WHY A SEPARATE SCRIPT: step 15 has to answer "does a long code line scroll
 * inside its own box instead of widening the page", and that question needs a
 * code block whose single line is wider than the phone. The streaming script's
 * chunks are short prose, so measuring with them would only ever answer "no
 * <pre> in the document" — which is what the first attempt measured
 * (`preCount: 0`). The reply is one fenced block with a 400-character line.
 */
export const CODE_KEYWORD = 'CODEBLOCK';

/**
 * Keyword that selects the image-report script.
 *
 * WHY A KEYWORD AT ALL: the mock must decide from request content, never from
 * memory (see the header). A prompt containing `IMAGETEST` asks the mock to
 * describe the images it actually received — their MIME type, decoded byte
 * length, and the first bytes of the base64 payload — and put that description
 * in its visible reply. That turns "the model saw the picture" into a claim the
 * session log and a screenshot can both be checked against, instead of an
 * assertion about the client.
 */
export const IMAGE_KEYWORD = 'IMAGETEST';

/**
 * Keyword that selects the `read_image` script.
 *
 * One turn only: the mock asks for `read_image` on the file the prompt names,
 * and the following turn (which carries the tool result) reports what the tool
 * actually returned — including whether the result carried an image block and
 * what the attachment's facts were. That is what makes criterion 3 checkable
 * from a session log rather than from an assertion about the code.
 */
export const READ_IMAGE_KEYWORD = 'READIMAGE';

/**
 * Keyword that selects a scripted bash session.
 *
 * The script is carried in the prompt itself, so one keyword covers every
 * command an acceptance run needs. The shape is:
 *
 *     BASHTEST
 *     STEP echo hi
 *     STEP exit 3
 *     ...
 *
 * Each `STEP` line is one `bash` tool call. After the last one the mock answers
 * with prose, which ends the turn. Keeping the steps in the *prompt* rather than
 * in server config is what makes a run reproducible: the same request always
 * produces the same sequence, and `logs/mock-requests.jsonl` records exactly
 * which prompt drove it.
 */
export const BASH_KEYWORD = 'BASHTEST';

/**
 * Keyword that selects the path/tool script.
 *
 * WHY IT EXISTS. Step 7's problems are about what a MODEL experiences: `grep`
 * answering "no matches" because ripgrep never searched, a `read` refusing a path
 * bash had just printed, a `write`→`edit` sequence failing. Each was measured
 * against `ctx.subprocess` and `ctx.fs` directly, but those measurements cannot
 * prove the model's own call works — the tool layer sits between them, and it is
 * what reports `unknown tool` or a sandbox refusal.
 *
 * So this script drives the tools a real model would call, in the order a real
 * model would: list, search, write, edit without reading (the reported failure),
 * read, then edit again (the documented recovery). The reply reports what each
 * call RETURNED, so the assertion is on the model-visible result rather than on
 * the harness's opinion of it.
 *
 * The directory is carried in the prompt as `DIR <guest path>` so the script can
 * target the workspace the app actually mounted.
 */
export const PATHTEST_KEYWORD = 'PATHTEST';

/**
 * Keyword that selects the "deleted file" script (step 8).
 *
 * WHY IT EXISTS. The phone reported a deadlock that no service-level probe can
 * show: a file created by `write`, deleted by a bash `rm`, and then refused by
 * `write` with
 *
 *     cannot write "…": file no longer exists — re-read the file, then retry
 *
 * `str_replace_editor create` refuses it the same way, and since the file is
 * gone the obvious remedy — re-read it — cannot succeed either. Whether that is
 * really a deadlock depends on a detail inside `fs-observation-policy`: a `read`
 * that fails with `FS_NOT_FOUND` still EMITS `fs/observed {kind:"absent"}`
 * first, and an absent observation makes the next `write` a guarded CREATE
 * rather than a versioned REPLACE. If that is so, the cycle is broken by the very
 * call whose failure looks fatal, and the only thing missing was that no prompt
 * said so.
 *
 * So this script walks exactly that path and reports what each call returned:
 * create, delete through the guest, overwrite (the reported failure), read of
 * the deleted path (the "pointless" remedy), overwrite again (the recovery). The
 * evidence is the model-visible text of calls 3 and 5, not an assertion about
 * the policy's internals.
 */
export const RMTEST_KEYWORD = 'RMTEST';

/**
 * Keyword that selects the approval script (step 16).
 *
 * WHY IT EXISTS. Step 16 needs one notification per thing the user might be
 * waiting for, and "a tool is waiting for approval" is the hardest of the four to
 * reach on demand: the approval seam only asks when some composition contributes an
 * `ask` decision, and `ish-approval-policy` contributes one for a command whose text
 * matches a destructive rule. So this script asks for exactly such a command —
 * `rm -rf` on a file the script itself created — and then stops, because a model
 * that kept going would be proposing the very operation that is being asked about.
 *
 * WHAT THE RUN CAN THEREFORE MEASURE. That `approval/asked` reaches the plugin, that
 * the plugin writes one `DSHPORTC_NOTIFY` line for it, that the app posts one
 * notification, that a second identical ask does not post a second one, and that
 * answering it withdraws the delivered one. What it cannot measure is how long a
 * person would actually take to answer; that is not the claim.
 */
export const APPROVALTEST_KEYWORD = 'APPROVALTEST';

/**
 * Keyword that selects the question script (step 16).
 *
 * The same shape as the approval script: one `ask_user_question` call and then
 * nothing, so the run observes the waiting state rather than a conclusion. The
 * question text is long on purpose — the notification truncates it at about 80
 * characters, and a short question would leave that untested.
 */
export const QUESTIONTEST_KEYWORD = 'QUESTIONTEST';

/**
 * Keyword that selects the failing-provider script (step 16).
 *
 * Planned as a plan rather than as an HTTP failure so the failure is DSH's own
 * `turn/end {kind:'error'}` and not a transport error the retry policy would
 * absorb: the mock answers with a well-formed reply whose stream ends in an error
 * chunk, which is the wire shape pi-ai documents for a provider-side failure.
 */
export const ERRORTEST_KEYWORD = 'ERRORTEST';

/** File the delete script uses, relative to the directory carried in the prompt. */
export const RM_TARGET_NAME = 'rmtest-target.md';

/** File the scripted `write` tool call creates, relative to the agent workspace. */
export const TOOL_TARGET_PATH = process.env.MOCK_TOOL_PATH || 'mock-tool-output.txt';

/** Content the scripted `write` tool call puts in that file. */
export const TOOL_TARGET_CONTENT =
  'mock-model wrote this file through the DSH write tool inside the app process.\n';

/**
 * Flatten a message `content` field to plain text.
 *
 * OpenAI-compatible clients send either a string or an array of parts
 * (`{type:"text",text:"…"}`, image parts, …). DSH sends strings for text, but a
 * multimodal history would break a naive `content.includes`, so normalise.
 * @param {unknown} content - the raw `content` value.
 * @returns {string} concatenated text.
 */
function contentText(content) {
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) {
    return content
      .map((part) => {
        if (typeof part === 'string') return part;
        if (part && typeof part === 'object' && typeof part.text === 'string') return part.text;
        return '';
      })
      .join('\n');
  }
  return '';
}

/**
 * Join every text-bearing field of one message.
 * @param {object} message - one entry of the request `messages` array.
 * @returns {string} its text.
 */
function messageText(message) {
  const parts = [contentText(message.content)];
  // A tool result may carry the file body we asked the agent to read.
  if (typeof message.name === 'string') parts.push(message.name);
  return parts.join('\n');
}

/**
 * Scan a request for a script selector.
 *
 * The keyword is searched over the whole message history, not only the last
 * user message: on turn 2 of a tool conversation the client re-sends the
 * original user prompt, and the script must stay the same across turns.
 * @param {object[]} messages - request messages.
 * @returns {{keyword: string|null, where: string|null}} the selector and its origin.
 */
export function findSelector(messages) {
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index];
    if (!message || message.role !== 'user') continue;
    const text = messageText(message);
    if (text.includes(PATHTEST_KEYWORD)) return { keyword: PATHTEST_KEYWORD, where: `messages[${index}]` };
    if (text.includes(RMTEST_KEYWORD)) return { keyword: RMTEST_KEYWORD, where: `messages[${index}]` };
    if (text.includes(APPROVALTEST_KEYWORD)) return { keyword: APPROVALTEST_KEYWORD, where: `messages[${index}]` };
    if (text.includes(QUESTIONTEST_KEYWORD)) return { keyword: QUESTIONTEST_KEYWORD, where: `messages[${index}]` };
    if (text.includes(ERRORTEST_KEYWORD)) return { keyword: ERRORTEST_KEYWORD, where: `messages[${index}]` };
    if (text.includes(BASH_KEYWORD)) return { keyword: BASH_KEYWORD, where: `messages[${index}]` };
    if (text.includes(TOOL_KEYWORD)) return { keyword: TOOL_KEYWORD, where: `messages[${index}]` };
    if (text.includes(CODE_KEYWORD)) return { keyword: CODE_KEYWORD, where: `messages[${index}]` };
    if (text.includes(STREAM_KEYWORD)) return { keyword: STREAM_KEYWORD, where: `messages[${index}]` };
    if (text.includes(IMAGE_KEYWORD)) return { keyword: IMAGE_KEYWORD, where: `messages[${index}]` };
    if (text.includes(READ_IMAGE_KEYWORD)) return { keyword: READ_IMAGE_KEYWORD, where: `messages[${index}]` };
  }
  // Fall back to a full scan: a system prompt could also carry the marker.
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index];
    if (!message) continue;
    const text = messageText(message);
    if (text.includes(PATHTEST_KEYWORD)) return { keyword: PATHTEST_KEYWORD, where: `messages[${index}]` };
    if (text.includes(RMTEST_KEYWORD)) return { keyword: RMTEST_KEYWORD, where: `messages[${index}]` };
    if (text.includes(APPROVALTEST_KEYWORD)) return { keyword: APPROVALTEST_KEYWORD, where: `messages[${index}]` };
    if (text.includes(QUESTIONTEST_KEYWORD)) return { keyword: QUESTIONTEST_KEYWORD, where: `messages[${index}]` };
    if (text.includes(ERRORTEST_KEYWORD)) return { keyword: ERRORTEST_KEYWORD, where: `messages[${index}]` };
    if (text.includes(BASH_KEYWORD)) return { keyword: BASH_KEYWORD, where: `messages[${index}]` };
    if (text.includes(TOOL_KEYWORD)) return { keyword: TOOL_KEYWORD, where: `messages[${index}]` };
    if (text.includes(CODE_KEYWORD)) return { keyword: CODE_KEYWORD, where: `messages[${index}]` };
    if (text.includes(STREAM_KEYWORD)) return { keyword: STREAM_KEYWORD, where: `messages[${index}]` };
    if (text.includes(IMAGE_KEYWORD)) return { keyword: IMAGE_KEYWORD, where: `messages[${index}]` };
    if (text.includes(READ_IMAGE_KEYWORD)) return { keyword: READ_IMAGE_KEYWORD, where: `messages[${index}]` };
  }
  return { keyword: null, where: null };
}

/**
 * Count how the conversation has progressed through tool turns.
 *
 * `toolResults` is what the server keys the step on: it is a fact the client
 * sends back, so it survives a server restart and needs no session state.
 * @param {object[]} messages - request messages.
 * @returns {{toolResults: number, assistantToolTurns: number, tools: string[]}} progress facts.
 */
export function toolProgress(messages) {
  let toolResults = 0;
  let assistantToolTurns = 0;
  /** @type {string[]} */
  const tools = [];
  for (const message of messages) {
    if (!message) continue;
    if (message.role === 'tool') toolResults += 1;
    if (message.role === 'assistant' && Array.isArray(message.tool_calls) && message.tool_calls.length > 0) {
      assistantToolTurns += 1;
      for (const call of message.tool_calls) {
        const name = call?.function?.name;
        if (typeof name === 'string') tools.push(name);
      }
    }
  }
  return { toolResults, assistantToolTurns, tools };
}

/** Stable short id so a replayed request gets a stable completion id. */
function digest(value) {
  return createHash('sha1').update(value).digest('hex').slice(0, 10);
}

/**
 * Describe every image part in one request.
 *
 * OpenAI-compatible image parts arrive either as
 * `{type:"image_url", image_url:{url:"data:<mime>;base64,<bytes>"}}` or as
 * `{type:"image", data:"<base64>", mimeType:"<mime>"}` depending on the client.
 * Both shapes are handled because the mock stands in for whichever adapter the
 * profile happens to mount, and a shape it did not recognise would silently
 * report zero images — the one failure mode this function must not have.
 *
 * @param {unknown} content - one message's `content`.
 * @returns {Array<{mediaType: string, base64Length: number, byteLength: number, head: string}>} what was found.
 */
export function imagePartsOf(content) {
  if (!Array.isArray(content)) return [];
  const found = [];
  for (const part of content) {
    if (part === null || typeof part !== 'object') continue;
    if (part.type === 'image_url') {
      const url = typeof part.image_url === 'string' ? part.image_url : part.image_url?.url;
      if (typeof url !== 'string') continue;
      const match = /^data:([^;,]+);base64,(.*)$/su.exec(url);
      if (match !== null) found.push(describeImage(match[1], match[2]));
      else found.push({ mediaType: 'url', base64Length: 0, byteLength: 0, head: url.slice(0, 24), width: null, height: null });
      continue;
    }
    if (part.type === 'image' && typeof part.data === 'string') {
      const mediaType = typeof part.mimeType === 'string'
        ? part.mimeType
        : (typeof part.media_type === 'string' ? part.media_type : 'unknown');
      found.push(describeImage(mediaType, part.data));
    }
  }
  return found;
}

/**
 * One image part, described from its own bytes.
 *
 * Only a bounded prefix is decoded for measurement: PNG puts its dimensions in
 * the IHDR at byte 16, and a JPEG's SOF marker is far ahead of any realistic
 * payload start unless the file carries a huge thumbnail in its first APP
 * segment. 256 KiB of prefix is enough for every camera file this task sends and
 * keeps the mock from holding a 20 MB buffer per part.
 * @param {string} mediaType - declared MIME type.
 * @param {string} base64 - payload.
 * @returns {object} the description.
 */
function describeImage(mediaType, base64) {
  const prefix = Buffer.from(base64.slice(0, Math.min(base64.length, Math.ceil((256 * 1024 * 4) / 3))), 'base64');
  const size = measureImage(prefix);
  return {
    mediaType,
    base64Length: base64.length,
    byteLength: Math.floor((base64.length * 3) / 4),
    head: base64.slice(0, 24),
    container: sniffContainer(prefix),
    width: size.width,
    height: size.height,
  };
}

/**
 * Read pixel dimensions out of an encoded header.
 *
 * Deliberately a tiny hand-rolled parser rather than an image library: the mock
 * must stay dependency-free so it also runs under `node --jitless`, and reading
 * two integers from a header is not worth a decoder. Returns nulls when the
 * format is not one it can measure, which the reply then says out loud instead
 * of inventing a number.
 * @param {Buffer} bytes - encoded prefix.
 * @returns {{width: number|null, height: number|null}} the dimensions.
 */
export function measureImage(bytes) {
  // PNG: signature, then IHDR with width and height as big-endian u32 at 16/20.
  if (bytes.length >= 24
    && bytes[0] === 0x89
    && bytes.subarray(1, 4).toString('latin1') === 'PNG'
    && bytes.subarray(12, 16).toString('latin1') === 'IHDR') {
    return { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20) };
  }
  // JPEG: walk the segment chain to the first start-of-frame marker.
  if (bytes.length >= 4 && bytes[0] === 0xff && bytes[1] === 0xd8) {
    let offset = 2;
    while (offset + 9 < bytes.length) {
      if (bytes[offset] !== 0xff) { offset += 1; continue; }
      const marker = bytes[offset + 1];
      // SOF0..SOF15, excluding the non-frame markers DHT (C4), JPG (C8) and DAC (CC).
      if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) {
        return { width: bytes.readUInt16BE(offset + 7), height: bytes.readUInt16BE(offset + 5) };
      }
      if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) { offset += 2; continue; }
      const length = bytes.readUInt16BE(offset + 2);
      if (length < 2) break;
      offset += 2 + length;
    }
    return { width: null, height: null };
  }
  // WebP (VP8/VP8L/VP8X), GIF87a/GIF89a.
  if (bytes.subarray(0, 4).toString('latin1') === 'RIFF' && bytes.subarray(8, 12).toString('latin1') === 'WEBP') {
    const chunk = bytes.subarray(12, 16).toString('latin1');
    if (chunk === 'VP8X' && bytes.length >= 30) {
      return { width: 1 + bytes.readUIntLE(24, 3), height: 1 + bytes.readUIntLE(27, 3) };
    }
    if (chunk === 'VP8 ' && bytes.length >= 30) {
      return { width: bytes.readUInt16LE(26) & 0x3fff, height: bytes.readUInt16LE(28) & 0x3fff };
    }
    if (chunk === 'VP8L' && bytes.length >= 25) {
      const bits = bytes.readUInt32LE(21);
      return { width: (bits & 0x3fff) + 1, height: ((bits >> 14) & 0x3fff) + 1 };
    }
    return { width: null, height: null };
  }
  if (bytes.subarray(0, 3).toString('latin1') === 'GIF' && bytes.length >= 10) {
    return { width: bytes.readUInt16LE(6), height: bytes.readUInt16LE(8) };
  }
  return { width: null, height: null };
}

/** Every image part in the whole conversation, in order. */
export function allImageParts(messages) {
  const images = [];
  for (const message of messages) {
    if (message === null || typeof message !== 'object') continue;
    images.push(...imagePartsOf(message.content));
  }
  return images;
}

/**
 * Decode the first bytes of a base64 image payload and identify its container.
 *
 * The reply says what the BYTES are, not what the client claimed they are: a
 * JPEG that was labelled `image/png` would show up here as a mismatch, which is
 * exactly the kind of thing the attachment path is supposed to prevent. Magic
 * numbers only — no decoder, no dependency.
 * @param {string} base64 - payload.
 * @returns {string} the sniffed container name.
 */
function sniffContainer(head) {
  const bytes = Buffer.from(head, 'base64');
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return 'JPEG';
  if (bytes.length >= 8 && bytes[0] === 0x89 && bytes.subarray(1, 4).toString('latin1') === 'PNG') return 'PNG';
  if (bytes.subarray(0, 4).toString('latin1') === 'RIFF' && bytes.subarray(8, 12).toString('latin1') === 'WEBP') return 'WebP';
  if (bytes.subarray(0, 3).toString('latin1') === 'GIF') return 'GIF';
  if (bytes.subarray(4, 8).toString('latin1') === 'ftyp') return 'HEIC/HEIF';
  return 'unknown';
}

/**
 * Text-only reply split across several chunks.
 *
 * Twelve segments, so the client has to render at least six intermediate
 * states; a buffered (non-streaming) transport would collapse them into one.
 * @returns {string[]} chunk payloads in order.
 */
function streamingTextSegments() {
  return [
    '流式验证开始。',
    '第 01 块：服务端逐块写出 SSE 事件。',
    '第 02 块：每块之间停顿约 120ms。',
    '第 03 块：客户端应立即看到上面这几行。',
    '第 04 块：如果一次性出现，说明链路被缓冲了。',
    '第 05 块：这一块是第 5 个数据事件。',
    '第 06 块：已经过半。',
    '第 07 块：继续逐块推进。',
    '第 08 块：接近结尾。',
    '第 09 块：下一块之后发送 [DONE]。',
    '第 10 块：流式验证结束。',
    'STREAMTEST-COMPLETE',
  ];
}

/**
 * Build one tool call, with its `function.arguments` JSON string.
 * @param {number} index - position in the assistant message's tool_calls array.
 * @param {string} name - DSH tool name.
 * @param {object} args - arguments object, serialised to a JSON string.
 * @returns {{id: string, type: string, function: {name: string, arguments: string}}} the call.
 */
function toolCall(index, name, args) {
  const json = JSON.stringify(args);
  return {
    id: `call_mock_${index}_${digest(name + json)}`,
    type: 'function',
    function: { name, arguments: json },
  };
}

/**
 * The bash steps carried in a BASHTEST prompt.
 *
 * `STEP <command>` lines are taken verbatim, so a step can contain pipes,
 * redirects, heredocs (written as `HEREDOC` markers), and arbitrary quoting.
 * Anything that is not a STEP line is ignored, which lets the prompt carry
 * human commentary for the log.
 *
 * @param {object[]} messages - request messages.
 * @returns {Array<{command: string, stdin?: string, timeoutMs?: number, workdir?: string}>} the steps.
 */
export function bashSteps(messages) {
  // The *first* user message carrying BASHTEST defines the script. Later turns
  // re-send it verbatim, and replies must not change across turns.
  for (const message of messages) {
    if (!message || message.role !== 'user') continue;
    const text = messageText(message);
    if (!text.includes(BASH_KEYWORD)) continue;
    return parseBashScript(text);
  }
  return [];
}

/**
 * Parse the script body out of one prompt.
 *
 * Recognised lines:
 *   `STEP <command>`        one bash tool call with that command
 *   `STDIN <text>`          stdin for the preceding STEP (one line, unescaped)
 *   `HEREDOC <path>`        expand to a real heredoc writing the following
 *                           `...` body; ends at `ENDHEREDOC`
 *   `TIMEOUTMS <n>`         timeoutMs for the preceding STEP
 *   `WORKDIR <path>`        workdir for the preceding STEP
 *   `DESCRIPTION <text>`    the required bash-tool description for the preceding
 *                           STEP (defaults to a derived one-liner)
 *
 * @param {string} text - the prompt text.
 * @returns {Array<object>} the steps.
 */
export function parseBashScript(text) {
  const lines = text.split(/\r?\n/);
  /** @type {Array<object>} */
  const steps = [];
  let current = null;
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    const step = /^\s*STEP\s+(.*)$/u.exec(line);
    if (step !== null) {
      current = { command: step[1] };
      steps.push(current);
      continue;
    }
    if (current === null) continue;
    // `+ <text>` continues the previous STEP's command on a new line. Needed
    // because a real multi-line command (a pipeline split for readability, a
    // `for` loop) is otherwise impossible to put in a prompt without the parser
    // treating the continuation as commentary.
    const more = /^\s*\+\s?(.*)$/u.exec(line);
    if (more !== null) {
      current.command = `${current.command}\n${more[1]}`;
      continue;
    }
    const stdin = /^\s*STDIN\s+(.*)$/u.exec(line);
    if (stdin !== null) {
      current.stdin = stdin[1];
      continue;
    }
    const timeout = /^\s*TIMEOUTMS\s+(\d+)\s*$/u.exec(line);
    if (timeout !== null) {
      current.timeoutMs = Number(timeout[1]);
      continue;
    }
    const workdir = /^\s*WORKDIR\s+(.*)$/u.exec(line);
    if (workdir !== null) {
      current.workdir = workdir[1];
      continue;
    }
    const description = /^\s*DESCRIPTION\s+(.*)$/u.exec(line);
    if (description !== null) {
      current.description = description[1];
      continue;
    }
    const heredoc = /^\s*HEREDOC\s+(\S+)\s*$/u.exec(line);
    if (heredoc !== null) {
      const target = heredoc[1];
      const body = [];
      for (index += 1; index < lines.length; index += 1) {
        if (/^\s*ENDHEREDOC\s*$/u.test(lines[index])) break;
        body.push(lines[index]);
      }
      // A quoted delimiter, so the shell does not expand anything in the body:
      // that is the case a naive `echo`-based test never covers and the one a
      // real heredoc test must.
      current.command = `cat > ${target} <<'DSH_MOCK_EOF'\n${body.join('\n')}\nDSH_MOCK_EOF`;
      current.stdin = '';
      continue;
    }
  }
  return steps;
}

/**
 * Decide one bash step: hand out the next command, or finish.
 *
 * The basis is the number of `role: "tool"` messages already in the
 * conversation, which is what {@link toolProgress} counts: those are results the
 * client sent back, so the decision needs no server state and a replayed request
 * gets the same answer.
 *
 * @param {object[]} messages - request messages.
 * @param {object} selection - the selection record for the log.
 * @returns {object} a reply plan.
 */
function planBashStep(messages, selection) {
  const steps = bashSteps(messages);
  const progress = toolProgress(messages);
  const done = progress.toolResults;

  if (steps.length === 0) {
    return {
      kind: 'text',
      script: 'bash-no-steps',
      step: null,
      finish: 'stop',
      selection: { ...selection, reason: 'BASHTEST matched but the prompt carried no STEP lines' },
      text: 'BASHTEST 已收到，但提示里没有 STEP 行，无法执行命令。',
    };
  }

  if (done >= steps.length) {
    return {
      kind: 'text',
      script: 'bash-final-text',
      step: steps.length,
      finish: 'stop',
      selection: { ...selection, stepBasis: `${done} tool results already present; all ${steps.length} steps dispatched` },
      text:
        `BASHTEST 全部 ${steps.length} 条命令已执行完毕，收到 ${done} 条工具结果。`
        + `已调用工具：${progress.tools.join(', ') || '（无）'}。`,
    };
  }

  const step = steps[done];
  // `description` is REQUIRED by the bash tool's schema (it throws on an empty
  // one before the command runs: dsh-tool-bash/lib/index.js:237). A scripted
  // call without it is rejected with "invalid arguments: missing required
  // property \"description\"" — the command never reaches the provider, so a
  // run that reports this is testing the mock, not the shell.
  //
  // Derived from the command rather than fixed: the tool's own guidance asks
  // for an active-voice summary of what the command does, and a fixed string
  // would tell the model (and the UI) something untrue.
  const args = {
    description: step.description ?? `Run: ${step.command.split('\n')[0].slice(0, 70)}`,
    command: step.command,
  };
  if (step.timeoutMs !== undefined) args.timeoutMs = step.timeoutMs;
  if (step.workdir !== undefined) args.workdir = step.workdir;
  return {
    kind: 'tool',
    script: `bash-step${done + 1}`,
    step: done + 1,
    finish: 'tool_calls',
    selection: { ...selection, stepBasis: `${done} tool results present; dispatching step ${done + 1}` },
    toolCalls: [toolCall(0, 'bash', args)],
  };
}

/**
 * Decide what this request gets.
 *
 * Returns a plain object the server can serialise either as one SSE stream or as
 * a single non-streaming body. `selection` is copied verbatim into
 * logs/mock-requests.jsonl so the report can quote why a script ran.
 * @param {object} request - the parsed request body.
 * @returns {{kind: 'text'|'tool', script: string, step: number|null, selection: object, segments?: string[], text?: string, toolCalls?: object[], finish: string}} the reply plan.
 */
export function planReply(request) {
  const messages = Array.isArray(request?.messages) ? request.messages : [];
  const tools = Array.isArray(request?.tools) ? request.tools : [];
  const toolNames = tools.map((tool) => tool?.function?.name).filter((name) => typeof name === 'string');
  const { keyword, where } = findSelector(messages);
  const progress = toolProgress(messages);

  const selection = {
    keyword,
    matchedAt: where,
    reason: keyword === null ? 'no keyword in the conversation; short fallback reply' : `conversation contains ${keyword} at ${where}`,
    toolResultCount: progress.toolResults,
    assistantToolTurns: progress.assistantToolTurns,
    requestedTools: toolNames,
  };

  if (keyword === BASH_KEYWORD) {
    // A bash script needs the `bash` tool in the catalog; without it a real
    // model would answer in prose.
    if (!toolNames.includes('bash')) {
      return {
        kind: 'text',
        script: 'bash-no-tool',
        step: null,
        finish: 'stop',
        selection: { ...selection, reason: 'BASHTEST matched but the request declared no `bash` tool' },
        text: 'BASHTEST 已收到，但本次请求没有提供 bash 工具。',
      };
    }
    return planBashStep(messages, selection);
  }

  if (keyword === TOOL_KEYWORD) {
    // Without a tool catalog the script cannot make progress: a real model would
    // answer in prose, and so must this one.
    if (toolNames.length === 0) {
      return {
        kind: 'text',
        script: 'tool-no-tools-text',
        step: null,
        finish: 'stop',
        selection: { ...selection, reason: 'TOOLTEST matched but the request declared no tools' },
        text: 'TOOLTEST 已收到，但本次请求没有提供 tools，无法发起工具调用。',
      };
    }
    // Safety valve: if the client kept sending tool results without the
    // conversation advancing, stop handing out tool calls instead of looping.
    if (progress.assistantToolTurns >= 3) {
      return {
        kind: 'text',
        script: 'tool-final-guard',
        step: 99,
        finish: 'stop',
        selection: { ...selection, reason: 'assistant already made 3 tool turns; returning the final text to end the loop' },
        text:
          'TOOLTEST 工具回合结束（安全阀：已发生 3 次工具回合）。' +
          `已经出现 ${progress.toolResults} 条工具结果：${progress.tools.join(', ')}。` +
          `文件 ${TOOL_TARGET_PATH} 应当已经由 write 工具写入。`,
      };
    }

    if (progress.toolResults === 0) {
      const call = toolCall(0, 'write', { file_path: TOOL_TARGET_PATH, content: TOOL_TARGET_CONTENT });
      return {
        kind: 'tool',
        script: 'tool-step1-write',
        step: 1,
        finish: 'tool_calls',
        selection: { ...selection, stepBasis: 'no tool result in the conversation yet' },
        toolCalls: [call],
      };
    }
    if (progress.toolResults === 1) {
      // Read the file back and search the workspace: two calls in one turn.
      const calls = [
        toolCall(0, 'read', { file_path: TOOL_TARGET_PATH }),
        toolCall(1, 'glob', { pattern: '*.txt', path: '.' }),
      ];
      return {
        kind: 'tool',
        script: 'tool-step2-read-glob',
        step: 2,
        finish: 'tool_calls',
        selection: { ...selection, stepBasis: 'exactly 1 tool result present (the write)' },
        toolCalls: calls,
      };
    }
    // Two or more results: the client has the file body and the search listing.
    return {
      kind: 'text',
      script: 'tool-step3-final-text',
      step: 3,
      finish: 'stop',
      selection: { ...selection, stepBasis: `${progress.toolResults} tool results present; wrapping up` },
      text:
        'TOOLTEST 工具回合完成。' +
        `已调用：${progress.tools.join(', ')}。` +
        `工具结果 ${progress.toolResults} 条。` +
        `写入的文件是 ${TOOL_TARGET_PATH}，内容是 mock 指定的那一行文本。`,
    };
  }

  if (keyword === PATHTEST_KEYWORD) {
    // The tools this script needs. A real model would answer in prose if they were
    // absent, and so must this one — otherwise a missing tool shows up as a
    // confusing "unknown tool" inside an otherwise plausible tool-call turn.
    const needed = ['glob', 'grep', 'write', 'read', 'edit'];
    const missing = needed.filter((name) => !toolNames.includes(name));
    if (missing.length > 0) {
      return {
        kind: 'text',
        script: 'pathtest-no-tools',
        step: null,
        finish: 'stop',
        selection: { ...selection, reason: `PATHTEST needs ${needed.join(', ')}; missing: ${missing.join(', ')}` },
        text: `PATHTEST 已收到，但本次请求缺少工具：${missing.join('、')}。`,
      };
    }

    // The directory under test, from `DIR <path>` in the prompt.
    let dir = '.';
    for (const message of messages) {
      const text = messageText(message);
      const match = /^\s*DIR\s+(\S+)\s*$/mu.exec(text);
      if (match !== null) { dir = match[1]; break; }
    }

    // Step basis is the number of tool results the client returned, exactly like
    // the bash script: no server state, so a replayed request gets the same answer.
    const done = progress.toolResults;
    const plan = [
      { name: 'glob', args: { pattern: '*.txt', path: dir } },
      { name: 'grep', args: { pattern: 'needle', path: dir } },
      { name: 'write', args: { file_path: `${dir}/pathtest-output.txt`, content: 'alpha\nbeta\n' } },
      // The reported failure: an edit with no read in between.
      { name: 'edit', args: { file_path: `${dir}/pathtest-output.txt`, old_string: 'alpha', new_string: 'ALPHA' } },
      // The documented recovery.
      { name: 'read', args: { file_path: `${dir}/pathtest-output.txt` } },
      { name: 'edit', args: { file_path: `${dir}/pathtest-output.txt`, old_string: 'alpha', new_string: 'ALPHA' } },
    ];

    if (done >= plan.length) {
      // Report what each call returned, in the model's own words. `tool` messages
      // are the tool results, in order, so index i is the answer to plan[i].
      const answers = [];
      let index = 0;
      for (const message of messages) {
        if (message === null || message.role !== 'tool') continue;
        const text = contentText(message.content);
        const failed = message.isError === true || /^Error:/.test(text.trim());
        answers.push(`${index + 1}. ${plan[index]?.name ?? '?'}: ${failed ? 'FAILED' : 'ok'} — ${text.trim().slice(0, 160)}`);
        index += 1;
      }
      return {
        kind: 'text',
        script: 'pathtest-report',
        step: plan.length,
        finish: 'stop',
        selection: { ...selection, dir, steps: plan.length },
        segments: [`PATHTEST 完成，${plan.length} 步。`, ...answers, 'PATHTEST-DONE'],
      };
    }

    const next = plan[done];
    return {
      kind: 'tool',
      script: `pathtest-step${done + 1}`,
      step: done + 1,
      finish: 'tool_calls',
      selection: { ...selection, dir, stepBasis: `${done} tool results present; dispatching ${next.name}` },
      toolCalls: [toolCall(0, next.name, next.args)],
    };
  }

  if (keyword === RMTEST_KEYWORD) {
    // The tools this script needs. `str_replace_editor` is in the list because
    // the phone reported that it refuses the same file for the same reason; a
    // script that only exercised `write` would leave half the report untested.
    const needed = ['bash', 'write', 'read', 'str_replace_editor'];
    const missing = needed.filter((name) => !toolNames.includes(name));
    if (missing.length > 0) {
      return {
        kind: 'text',
        script: 'rmtest-no-tools',
        step: null,
        finish: 'stop',
        selection: { ...selection, reason: `RMTEST needs ${needed.join(', ')}; missing: ${missing.join(', ')}` },
        text: `RMTEST 已收到，但本次请求缺少工具：${missing.join('、')}。`,
      };
    }

    // The directory under test, from `DIR <guest path>` in the prompt. It must be
    // the GUEST spelling for the bash step, which is the whole point: the deletion
    // happens through the other namespace.
    let dir = '/workspace';
    for (const message of messages) {
      const text = messageText(message);
      const match = /^\s*DIR\s+(\S+)\s*$/mu.exec(text);
      if (match !== null) { dir = match[1]; break; }
    }
    const target = `${dir}/${RM_TARGET_NAME}`;

    // One call per turn, indexed by the number of tool results the client returned
    // — the same stateless basis the other scripts use, so a replayed request gets
    // the same answer and the report step can pair result i with plan[i].
    const done = progress.toolResults;
    const plan = [
      // 1. Create it through the file tool. This records a PRESENT observation at
      //    the version the provider reports.
      { name: 'write', args: { file_path: target, content: 'first\nsecond\n' } },
      // 2. Delete it through the GUEST. Nothing on the host tells the observation
      //    policy that its recorded version is now stale; that omission is the bug.
      // `unlink`, not `rm`: `ish-approval-policy` asks a human before a forced
      // delete, and an unattended scripted turn would block on that dialog
      // forever (measured: step 7 of the first run sat in `approval/asked`).
      // The property under test is "bash deleted the file", not "the approval
      // rule matched", so the deletion goes through the applet that no rule
      // covers.
      { name: 'bash', args: { command: `unlink ${target} && ls -l ${target} 2>&1 || echo RM_OK`, description: `Delete ${target}` } },
      // 3. The reported failure. Expected: `file no longer exists — re-read the
      //    file, then retry`, because the recorded state is still `present@v1`.
      { name: 'write', args: { file_path: target, content: 'second attempt\n' } },
      // 4. The same refusal through the editor's `create`, which stat()s the path
      //    first and finds nothing, then still asks the policy for an intent.
      { name: 'str_replace_editor', args: { command: 'create', path: target, file_text: 'created by the editor\n' } },
      // 5. The "pointless" remedy. Expected: `not found` — AND, invisibly, an
      //    `fs/observed {kind:"absent"}` that authorizes a guarded create.
      { name: 'read', args: { file_path: target } },
      // 6. The question this whole script exists to answer: does the failed read
      //    unlock `write`? Expected success if the absent observation is recorded.
      { name: 'write', args: { file_path: target, content: 'recreated by write after the read\n' } },
      // 7. Delete again, to test the editor's half of the recovery separately.
      { name: 'bash', args: { command: `unlink ${target} && echo RM2_OK`, description: `Delete ${target} again` } },
      // 8. The same failing read, on a path the policy now has as present@v2.
      { name: 'read', args: { file_path: target } },
      // 9. Whether `str_replace_editor create` recovered too. Both tools share the
      //    one intent slot, so a fix for one must fix the other.
      { name: 'str_replace_editor', args: { command: 'create', path: target, file_text: 'editor after the read\n' } },
    ];

    if (done >= plan.length) {
      const answers = [];
      let index = 0;
      for (const message of messages) {
        if (message === null || message.role !== 'tool') continue;
        const text = contentText(message.content);
        const failed = message.isError === true || /^Error:/.test(text.trim());
        answers.push(`${index + 1}. ${plan[index]?.name ?? '?'}: ${failed ? 'FAILED' : 'ok'} — ${text.trim().slice(0, 200)}`);
        index += 1;
      }
      return {
        kind: 'text',
        script: 'rmtest-report',
        step: plan.length,
        finish: 'stop',
        selection: { ...selection, dir, target, steps: plan.length },
        segments: [`RMTEST 完成，${plan.length} 步。`, ...answers, 'RMTEST-DONE'],
      };
    }

    const next = plan[done];
    return {
      kind: 'tool',
      script: `rmtest-step${done + 1}`,
      step: done + 1,
      finish: 'tool_calls',
      selection: { ...selection, dir, target, stepBasis: `${done} tool results present; dispatching ${next.name}` },
      toolCalls: [toolCall(0, next.name, next.args)],
    };
  }

  if (keyword === APPROVALTEST_KEYWORD) {
    if (!toolNames.includes('bash')) {
      return {
        kind: 'text',
        script: 'approval-no-bash',
        step: null,
        finish: 'stop',
        selection: { ...selection, reason: 'APPROVALTEST matched but the request declared no `bash` tool' },
        text: 'APPROVALTEST 已收到，但本次请求没有提供 bash 工具，无法触发审批。',
      };
    }
    let target = '/tmp/approvaltest-target';
    for (const message of messages) {
      const match = /^\\s*TARGET\\s+(\\S+)\\s*$/mu.exec(messageText(message));
      if (match === null) continue;
      target = match[1];
      break;
    }
    // THE ORDER OF THESE THREE BRANCHES IS THE SCRIPT.
    //
    // Measured, the hard way: an earlier version tested "any tool result exists" first, so
    // the warm-up's own result was taken as "the approval has been answered" and the run
    // reported `approval-report` instead of ever proposing the `rm`. The step count is the
    // only state this stateless mock has, so each branch has to name exactly one count.
    //
    //  0 results -> one harmless command, which gives the acceptance a `tool/call` to
    //               wait for so the app is already hidden when the approval is raised;
    //  1 result  -> the `rm -rf` that `ish-approval-policy` asks a human about;
    //  2 results -> the approval was decided; report which way and end.
    if (progress.toolResults === 0) {
      return {
        kind: 'tool',
        script: 'approval-step1-warmup',
        step: 1,
        finish: 'tool_calls',
        selection: { ...selection, target, stepBasis: 'no tool result yet; one harmless command first' },
        toolCalls: [toolCall(0, 'bash', {
          description: 'Check the target before proposing its removal',
          command: `ls -l ${target} 2>&1 || echo approvaltest-target-absent; sleep 2`,
        })],
      };
    }
    if (progress.toolResults === 1) {
      return {
        kind: 'tool',
        script: 'approval-step2-rm',
        step: 2,
        finish: 'tool_calls',
        selection: { ...selection, target, stepBasis: 'the warm-up ran; now proposing the command that needs approval' },
        toolCalls: [toolCall(0, 'bash', {
          description: `Remove ${target}`,
          command: `rm -rf ${target}`,
        })],
      };
    }
    const last = [...messages].reverse().find((message) => message?.role === 'tool');
    const text = last === undefined ? '' : contentText(last.content);
    const refused = last?.isError === true || /^Error:/u.test(text.trim());
    return {
      kind: 'text',
      script: 'approval-report',
      step: 3,
      finish: 'stop',
      selection: { ...selection, stepBasis: 'the approval has been decided; reporting the outcome' },
      segments: [`APPROVALTEST 审批结果：${refused ? '被拒绝' : '已允许'}。`, 'APPROVALTEST-DONE'],
    };
  }

  if (keyword === QUESTIONTEST_KEYWORD) {
    if (!toolNames.includes('ask_user_question')) {
      return {
        kind: 'text',
        script: 'question-no-tool',
        step: null,
        finish: 'stop',
        selection: { ...selection, reason: 'QUESTIONTEST matched but the request declared no ask_user_question tool' },
        text: 'QUESTIONTEST 已收到，但本次请求没有提供 ask_user_question 工具。',
      };
    }
    // THE SAME THREE-BRANCH SHAPE as the approval script, for the same measured reason: a
    // question asked in the first second of a turn is answered by the acceptance's own
    // fallback while the app is still in front, so the notification is suppressed with
    // "App 在前台，不发" and the case can never observe a delivery. One short command
    // first gives the run a `tool/call` to wait for, so the app is hidden when the question
    // is raised.
    //
    //  0 results -> one short command;
    //  1 result  -> the `ask_user_question` call;
    //  2 results -> the answer (or timeout) arrived; report it and end.
    if (progress.toolResults === 0) {
      if (!toolNames.includes('bash')) {
        return {
          kind: 'text',
          script: 'question-no-bash',
          step: null,
          finish: 'stop',
          selection: { ...selection, reason: 'QUESTIONTEST needs bash for its warm-up; the request declared none' },
          text: 'QUESTIONTEST 已收到，但本次请求没有提供 bash 工具。',
        };
      }
      return {
        kind: 'tool',
        script: 'question-step1-warmup',
        step: 1,
        finish: 'tool_calls',
        selection: { ...selection, stepBasis: 'no tool result yet; one short command first' },
        toolCalls: [toolCall(0, 'bash', {
          description: 'Run a short command before asking the question',
          command: 'echo questiontest-warmup && sleep 2 && echo questiontest-warmup-done',
        })],
      };
    }
    if (progress.toolResults === 1) {
      return {
        kind: 'tool',
        script: 'question-step2-ask',
        step: 2,
        finish: 'tool_calls',
        selection: { ...selection, stepBasis: 'the warm-up ran; asking the question' },
        toolCalls: [toolCall(0, 'ask_user_question', {
          questions: [{
            id: 'notify-question',
            header: '通知验收',
            // Long enough that the 80-character truncation in the notification body is
            // exercised: a short question would leave that path untested.
            question: '这是一个专门用来验证提问通知的问题，问题本身故意写得比较长：请确认你希望我在这一轮里把工作区里的临时文件、缓存文件、上一次失败留下的中间产物，以及那几个你还没决定要不要保留的导出副本，全部一次性清理掉，还是先只清理这一步产生的中间文件、其余留到下一轮再统一处理，并且在清理之前先把要删的清单列出来给你过一眼？',
            options: [
              { label: '全部清理', description: '这一步就把临时文件都删掉。' },
              { label: '只清这一步', description: '先只删这一步产生的中间文件。' },
            ],
          }],
        })],
      };
    }
    const last = [...messages].reverse().find((message) => message?.role === 'tool');
    const text = last === undefined ? '' : contentText(last.content);
    return {
      kind: 'text',
      script: 'question-report',
      step: 3,
      finish: 'stop',
      selection: { ...selection, stepBasis: 'the question has an answer or a timeout; reporting it' },
      segments: [`QUESTIONTEST 回答：${text.trim().slice(0, 300) || '（空）'}`, 'QUESTIONTEST-DONE'],
    };
  }

  if (keyword === ERRORTEST_KEYWORD) {
    // TWO STEPS, ON PURPOSE: one successful tool call, then the failure.
    //
    // WHY NOT FAIL IMMEDIATELY. The first version did, and it made the case untestable:
    // the turn ended within a second of starting, before the acceptance could background
    // the app, so the notification was correctly SUPPRESSED with "App 在前台，不发" — a
    // right answer that cannot distinguish "the error path notifies" from "the error path
    // never ran". A first step that runs one short command gives the acceptance a
    // `tool/call` to wait for, which is the same instrument the other cases use, and the
    // failure then happens with the app already hidden.
    //
    // The failure itself is a well-formed plan whose finish reason is `error`: the wire
    // shape pi-ai documents for a provider-side failure, so what the agent loop records
    // is its own `turn/end {kind:'error'}` rather than a transport error the retry policy
    // would absorb. The notification is about a turn that ENDED in error, not one that
    // briefly stumbled.
    if (progress.toolResults === 0) {
      if (!toolNames.includes('bash')) {
        return {
          kind: 'text',
          script: 'errortest-no-tool',
          step: null,
          finish: 'stop',
          selection: { ...selection, reason: 'ERRORTEST matched but the request declared no `bash` tool' },
          text: 'ERRORTEST 已收到，但本次请求没有提供 bash 工具。',
        };
      }
      return {
        kind: 'tool',
        script: 'errortest-step1-command',
        step: 1,
        finish: 'tool_calls',
        selection: { ...selection, stepBasis: 'no tool result yet; running the one command before the failure' },
        toolCalls: [toolCall(0, 'bash', {
          description: 'Run a short command before the provider failure',
          command: "echo errortest-step1 && sleep 2 && echo errortest-step1-done",
        })],
      };
    }
    return {
      kind: 'text',
      script: 'errortest-provider-failure',
      step: 2,
      finish: 'error',
      selection: { ...selection, stepBasis: 'the command ran; the provider now fails on purpose' },
      errorMessage: 'mock provider failed on purpose (ERRORTEST)',
      segments: [],
    };
  }

  if (keyword === READ_IMAGE_KEYWORD) {
    // Turn 1 asks the tool to read the file; turn 2 (which carries the tool
    // result) reports what came back, including the image block's facts.
    if (!toolNames.includes('read_image')) {
      return {
        kind: 'text',
        script: 'read-image-no-tool',
        step: null,
        finish: 'stop',
        selection: { ...selection, reason: 'READIMAGE matched but the request declared no read_image tool' },
        text: 'READIMAGE 已收到，但本次请求没有提供 read_image 工具。',
      };
    }
    // The path is carried in the prompt: `FILE <path>`.
    let target = 'photo.heic';
    for (const message of messages) {
      const text = messageText(message);
      const match = /^\s*FILE\s+(\S+)\s*$/mu.exec(text);
      if (match !== null) { target = match[1]; break; }
    }
    if (progress.toolResults === 0) {
      return {
        kind: 'tool',
        script: 'read-image-step1',
        step: 1,
        finish: 'tool_calls',
        selection: { ...selection, path: target },
        toolCalls: [toolCall(0, 'read_image', { file_path: target })],
      };
    }
    // Report the tool result as the model sees it.
    let reported = '未找到 read_image 的工具结果。';
    for (const message of messages) {
      if (message === null || message.role !== 'tool') continue;
      const images = imagePartsOf(message.content);
      const text = contentText(message.content);
      if (images.length > 0) {
        reported = `read_image 返回了 ${images.length} 张图片：`
          + images.map((i) => `${i.mediaType} ${i.width}x${i.height} ${i.byteLength}B`).join('；')
          + `。工具文本开头：${text.slice(0, 120)}`;
      } else {
        reported = `read_image 没有返回图片内容。工具文本：${text.slice(0, 300)}`;
      }
      break;
    }
    return {
      kind: 'text',
      script: 'read-image-report',
      step: 2,
      finish: 'stop',
      selection: { ...selection, path: target },
      segments: ['READIMAGE 结果。', reported, 'READIMAGE-DONE'],
    };
  }

  if (keyword === IMAGE_KEYWORD) {
    // Report what the request actually carried. The reply is deliberately
    // verbose about the FACTS (media type, byte length, sniffed container) and
    // silent about the first bytes' actual content beyond a short prefix, so it
    // is useful for verification and useless as a way to exfiltrate an image
    // into a log.
    const images = allImageParts(messages);
    if (images.length === 0) {
      return {
        kind: 'text',
        script: 'image-none',
        step: null,
        finish: 'stop',
        selection: { ...selection, reason: 'IMAGETEST matched but the request carried no image parts' },
        text: 'IMAGETEST 收到，但这次请求里没有任何图片内容（image parts = 0）。',
      };
    }
    const lines = images.map((image, index) => {
      const megabytes = (image.byteLength / (1024 * 1024)).toFixed(2);
      const dimensions = image.width === null || image.height === null
        ? '尺寸未能从字节读出'
        : `${image.width}x${image.height}px`;
      return `图 ${index + 1}: 声明类型 ${image.mediaType}，实际容器 ${image.container}，`
        + `${dimensions}，${image.byteLength} 字节（${megabytes} MB）。`;
    });
    return {
      kind: 'text',
      script: 'image-report',
      step: null,
      finish: 'stop',
      selection: { ...selection, imageCount: images.length },
      // Two segments so the reply still exercises incremental rendering.
      segments: [`IMAGETEST 收到 ${images.length} 张图片。`, ...lines, 'IMAGETEST-DONE'],
    };
  }

  if (keyword === CODE_KEYWORD) {
    return {
      kind: 'text',
      script: 'code-block-long-line',
      step: null,
      finish: 'stop',
      selection,
      // A short prose line, one very long code line, and a closing line: the
      // transcript gets a real <pre> whose scrollWidth exceeds its clientWidth on
      // a 402 pt screen, which is the condition the measurement is about.
      segments: [
        'CODEBLOCK 下面是一个很长的代码块。\n\n```bash\n',
        'ffmpeg -i input.mov -vf "scale=1920:-2,fps=30,format=yuv420p" -c:v libx264 -preset slow -crf 18 ',
        '-c:a aac -b:a 192k -movflags +faststart -metadata title="a deliberately long single line so the block has to scroll sideways" output.mp4\n',
        '```\n\nCODEBLOCK-DONE',
      ],
    };
  }

  if (keyword === STREAM_KEYWORD) {
    return {
      kind: 'text',
      script: 'stream-12-chunks',
      step: null,
      finish: 'stop',
      selection,
      segments: streamingTextSegments(),
    };
  }

  return {
    kind: 'text',
    script: 'short-fallback',
    step: null,
    finish: 'stop',
    selection,
    segments: ['MOCK 服务在线。', '这只是一条用于连通性检查的短回复。'],
  };
}
