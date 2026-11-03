#!/usr/bin/env node
// Integration check: drive the mock server through the SAME client library that
// DSH uses for the `openai-completions` protocol.
//
// The self-test's curl checks prove the bytes on the wire. This check proves the
// other half: that those bytes parse into the stream events DSH expects —
// `text_delta` for prose, `toolcall_start`/`toolcall_delta`/`toolcall_end` for
// tool calls, and a `done` event carrying a stopReason of `stop` or `toolUse`.
//
// It imports `@earendil-works/pi-ai`'s openai-completions protocol straight out
// of the ios-port-A install tree (read-only) — the exact module
// @deepseek-ai/dsh-llm-pi-ai calls. Nothing is written to that tree.
//
// Usage: mock/verify-with-pi-ai.mjs [baseUrl]
//   baseUrl defaults to http://127.0.0.1:19701
//
// Requires nothing beyond the ios-port-A install, so it does not touch any
// global install.

import path from 'node:path';
import { pathToFileURL } from 'node:url';

const BASE = process.argv[2] || 'http://127.0.0.1:19701';
const PI_AI_ROOT =
  process.env.PI_AI_ROOT ||
  `${process.env.DSH_NODE_MODULES}/@earendil-works/pi-ai`;

/** Load the openai-completions protocol module from the ios-port-A install. */
async function loadProtocol() {
  const entry = path.join(PI_AI_ROOT, 'dist/api/openai-completions.js');
  const module = await import(pathToFileURL(entry).href);
  if (typeof module.stream !== 'function') {
    throw new Error(`expected a stream() export from ${entry}`);
  }
  return module;
}

/**
 * Collect one streamed reply into a compact summary.
 * @param {AsyncIterable<object>} events - pi-ai assistant message events.
 * @returns {Promise<object>} what the stream produced.
 */
async function collect(events) {
  const summary = {
    textDeltas: 0,
    text: '',
    toolCallStarts: 0,
    toolCallDeltas: 0,
    toolCalls: [],
    thinkingDeltas: 0,
    done: null,
    errors: [],
  };
  /** @type {Map<number, {id: string, name: string, args: string}>} */
  const slots = new Map();
  for await (const event of events) {
    switch (event.type) {
      case 'text_delta':
        summary.textDeltas += 1;
        summary.text += event.delta;
        break;
      case 'thinking_delta':
        summary.thinkingDeltas += 1;
        break;
      case 'toolcall_start':
        summary.toolCallStarts += 1;
        break;
      case 'toolcall_delta':
        summary.toolCallDeltas += 1;
        break;
      case 'toolcall_end': {
        const call = event.toolCall;
        slots.set(slots.size, {
          id: call.id,
          name: call.name,
          args: JSON.stringify(call.arguments ?? {}),
        });
        break;
      }
      case 'done':
        summary.done = { reason: event.reason };
        break;
      case 'error':
        summary.errors.push(event.error?.errorMessage ?? 'unknown error');
        break;
      default:
        break;
    }
  }
  summary.toolCalls = [...slots.values()];
  return summary;
}

/** Build a minimal pi-ai model descriptor pointed at the mock. */
function modelDescriptor() {
  return {
    id: 'mock-model',
    name: 'Mock Model',
    api: 'openai-completions',
    provider: 'mock',
    baseUrl: `${BASE}/v1`,
    reasoning: false,
    input: ['text'],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow: 128000,
    maxTokens: 8192,
    compat: {
      supportsStore: false,
      supportsDeveloperRole: false,
      supportsReasoningEffort: false,
      maxTokensField: 'max_tokens',
    },
  };
}

/**
 * The tool catalog, in the shape pi-ai's transcript expects.
 *
 * pi-ai does not read a top-level `tools` field off the context: tool
 * declarations live on system messages as `toolsAdded`, and
 * `resolveTranscriptTools` projects them onto the request's `tools` field. So a
 * test that puts `tools` on the context would send no tools at all and the mock
 * would (correctly) refuse to script a tool call.
 * @returns {object[]} tool declarations.
 */
function toolCatalog() {
  return [
    {
      name: 'write',
      description: 'Create or fully replace a UTF-8 text file.',
      parameters: {
        type: 'object',
        additionalProperties: false,
        properties: {
          file_path: { type: 'string' },
          content: { type: 'string' },
        },
        required: ['file_path', 'content'],
      },
    },
    {
      name: 'read',
      description: 'Read a UTF-8 text file and return line-numbered content.',
      parameters: {
        type: 'object',
        additionalProperties: false,
        properties: { file_path: { type: 'string' } },
        required: ['file_path'],
      },
    },
    {
      name: 'glob',
      description: 'Find files whose paths match a glob pattern.',
      parameters: {
        type: 'object',
        additionalProperties: false,
        properties: { pattern: { type: 'string' }, path: { type: 'string' } },
        required: ['pattern'],
      },
    },
  ];
}

/**
 * A system message that declares the tool catalog, in pi-ai's transcript shape.
 * @returns {object} the system message.
 */
function systemWithTools() {
  return { role: 'system', content: 'you are a test fixture', toolsAdded: toolCatalog() };
}

/** Render one summary the way the report needs it. */
function printSummary(title, summary) {
  console.log(`\n--- ${title} ---`);
  console.log(`text_delta events : ${summary.textDeltas}`);
  if (summary.text.length > 0) console.log(`text              : ${JSON.stringify(summary.text)}`);
  console.log(`toolcall_start    : ${summary.toolCallStarts}`);
  console.log(`toolcall_delta    : ${summary.toolCallDeltas}`);
  for (const call of summary.toolCalls) {
    console.log(`tool call         : ${call.name}  args=${call.args}`);
  }
  console.log(`done reason       : ${summary.done?.reason ?? '(none)'}`);
  if (summary.errors.length > 0) console.log(`errors            : ${summary.errors.join('; ')}`);
}

const failures = [];
const check = (label, condition, detail) => {
  const status = condition ? 'PASS' : 'FAIL';
  console.log(`${label.padEnd(46)}: ${status}${detail ? ` — ${detail}` : ''}`);
  if (!condition) failures.push(label);
};

const protocol = await loadProtocol();
const model = modelDescriptor();

console.log('verifying the mock against pi-ai openai-completions (the module DSH uses)');
console.log(`protocol module : ${path.join(PI_AI_ROOT, 'dist/api/openai-completions.js')}`);
console.log(`baseUrl         : ${model.baseUrl}`);
console.log(`auth            : no key sent; the mock ignores Authorization`);

// ---------------------------------------------------------------- 1. streaming
console.log('\n=== 1. streaming text (STREAMTEST) ===');
const textSummary = await collect(
  protocol.stream(
    model,
    { messages: [{ role: 'user', content: [{ type: 'text', text: 'STREAMTEST please stream' }] }] },
    { apiKey: 'mock-not-a-real-key' },
  ),
);
printSummary('parsed by pi-ai', textSummary);

check('text_delta events >= 6', textSummary.textDeltas >= 6, `${textSummary.textDeltas} observed`);
check('done reason is stop', textSummary.done?.reason === 'stop', String(textSummary.done?.reason));
check('no error events', textSummary.errors.length === 0, textSummary.errors.join('; ') || 'none');
check('text reassembles fully', textSummary.text.includes('STREAMTEST-COMPLETE'), `${textSummary.text.length} chars`);

// --------------------------------------------------------------- 2. tool turn 1
console.log('\n=== 2. tool turn 1 (TOOLTEST, no tool results yet) ===');
const turn1Context = {
  messages: [
    systemWithTools(),
    { role: 'user', content: [{ type: 'text', text: 'TOOLTEST write then read' }] },
  ],
};
const turn1 = await collect(
  protocol.stream(model, turn1Context, { apiKey: 'mock-not-a-real-key' }),
);
printSummary('parsed by pi-ai', turn1);

check('turn 1 exposes one tool call', turn1.toolCalls.length === 1, `${turn1.toolCalls.length}`);
check('turn 1 tool name is write', turn1.toolCalls[0]?.name === 'write', turn1.toolCalls[0]?.name ?? 'none');
check('turn 1 done reason is toolUse', turn1.done?.reason === 'toolUse', String(turn1.done?.reason));
check('turn 1 arguments parsed', turn1.toolCalls[0]?.args?.includes('file_path'), turn1.toolCalls[0]?.args ?? 'none');

if (turn1.toolCalls.length !== 1) {
  console.log('\nRESULT: FAIL — cannot continue to turn 2 without a turn-1 tool call');
  process.exit(1);
}

// --------------------------------------------------------------- 3. tool turn 2
console.log('\n=== 3. tool turn 2 (after the write tool result) ===');
const turn1Call = turn1.toolCalls[0];
const turn1ParsedArgs = JSON.parse(turn1Call.args);
const turn2Context = {
  messages: [
    ...turn1Context.messages,
    {
      role: 'assistant',
      content: [
        { type: 'toolCall', id: turn1Call.id, name: turn1Call.name, arguments: turn1ParsedArgs },
      ],
    },
    {
      role: 'toolResult',
      toolCallId: turn1Call.id,
      toolName: 'write',
      content: [{ type: 'text', text: `Created ${turn1ParsedArgs.file_path}` }],
    },
  ],
};
const turn2 = await collect(
  protocol.stream(model, turn2Context, { apiKey: 'mock-not-a-real-key' }),
);
printSummary('parsed by pi-ai', turn2);

const turn2Names = turn2.toolCalls.map((call) => call.name);
check('turn 2 exposes two tool calls', turn2.toolCalls.length === 2, String(turn2.toolCalls.length));
check('turn 2 calls read and glob', turn2Names.includes('read') && turn2Names.includes('glob'), turn2Names.join(', '));
check('turn 2 done reason is toolUse', turn2.done?.reason === 'toolUse', String(turn2.done?.reason));

// --------------------------------------------------------------- 4. final text
console.log('\n=== 4. final turn (after read + glob results) ===');
const finalContext = {
  messages: [
    ...turn2Context.messages,
    {
      role: 'assistant',
      content: turn2.toolCalls.map((call) => ({
        type: 'toolCall',
        id: call.id,
        name: call.name,
        arguments: JSON.parse(call.args),
      })),
    },
    ...turn2.toolCalls.map((call) => ({
      role: 'toolResult',
      toolCallId: call.id,
      toolName: call.name,
      content: [{ type: 'text', text: call.name === 'read' ? '1\tmock file body' : 'mock-tool-output.txt' }],
    })),
  ],
};
const finalTurn = await collect(
  protocol.stream(model, finalContext, { apiKey: 'mock-not-a-real-key' }),
);
printSummary('parsed by pi-ai', finalTurn);

check('final turn emits text, no tool calls', finalTurn.toolCalls.length === 0 && finalTurn.textDeltas > 0, `${finalTurn.textDeltas} deltas`);
check('final turn done reason is stop', finalTurn.done?.reason === 'stop', String(finalTurn.done?.reason));

// ------------------------------------------------- 5. auth is not enforced
// pi-ai itself refuses to open a request with no apiKey ("No API key for
// provider"), which is a client-side guard and irrelevant to this server. What
// the mock must guarantee is that it ACCEPTS whatever Authorization value
// arrives, including a placeholder or none at all, so that no real credential is
// needed anywhere in the test. Check that directly over HTTP.
console.log('\n=== 5. the mock does not validate Authorization ===');
for (const [label, headers] of [
  ['no Authorization header at all', {}],
  ['a placeholder bearer token', { Authorization: 'Bearer mock-not-a-real-key' }],
  ['an empty bearer token', { Authorization: 'Bearer ' }],
]) {
  const response = await fetch(`${BASE}/v1/chat/completions`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...headers },
    body: JSON.stringify({
      model: 'mock-model',
      stream: true,
      messages: [{ role: 'user', content: 'STREAMTEST auth probe' }],
    }),
  });
  const body = await response.text();
  const events = body.split('\n').filter((line) => line.startsWith('data: ')).length;
  check(`accepts ${label}`, response.status === 200 && events >= 6, `HTTP ${response.status}, ${events} SSE events`);
}

// ---------------------------------------------------------------- verdict
console.log('\n=== verdict ===');
if (failures.length === 0) {
  console.log('VERDICT: PASS — pi-ai (DSH\'s own openai-completions client) consumed every scripted reply');
  process.exit(0);
}
console.log(`VERDICT: FAIL — ${failures.length} check(s) failed: ${failures.join(', ')}`);
process.exit(1);
