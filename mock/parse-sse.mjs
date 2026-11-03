#!/usr/bin/env node
// Test helper: reassemble an SSE transcript the way an OpenAI-compatible client
// would, then print what the model "said".
//
// Two uses:
//   node mock/parse-sse.mjs logs/mock-selftest-tool1.sse        human summary
//   node mock/parse-sse.mjs logs/mock-selftest-tool1.sse --json  machine-readable
//
// This exists because the tool-call script spreads one `function.arguments` JSON
// string over several `delta.tool_calls` fragments; reassembling them by index
// and concatenating is exactly the work a real client (the OpenAI SDK inside
// DSH) does, and it is the check that the fragments compose into valid JSON.

import fs from 'node:fs';

const [, , filePath, ...flags] = process.argv;
if (!filePath) {
  process.stderr.write('usage: node mock/parse-sse.mjs <transcript.sse> [--json]\n');
  process.exit(2);
}
const asJson = flags.includes('--json');

const raw = fs.readFileSync(filePath, 'utf8');

/** @type {{text: string, calls: Map<number, {id: string, name: string, args: string}>}} */
const state = { text: '', calls: new Map() };
let events = 0;
let finishReason = null;
let usage = null;
let sawDone = false;
let role = null;

for (const line of raw.split('\n')) {
  if (!line.startsWith('data: ')) continue;
  const body = line.slice(6).trim();
  events += 1;
  if (body === '[DONE]') {
    sawDone = true;
    continue;
  }
  let chunk;
  try {
    chunk = JSON.parse(body);
  } catch (error) {
    process.stderr.write(`skipping unparseable event: ${error.message}\n`);
    continue;
  }
  if (chunk.usage) usage = chunk.usage;
  const choice = Array.isArray(chunk.choices) ? chunk.choices[0] : undefined;
  if (!choice) continue;
  if (choice.finish_reason) finishReason = choice.finish_reason;
  const delta = choice.delta;
  if (!delta) continue;
  if (delta.role) role = delta.role;
  if (typeof delta.content === 'string' && delta.content.length > 0) state.text += delta.content;
  if (Array.isArray(delta.tool_calls)) {
    for (const fragment of delta.tool_calls) {
      const index = typeof fragment.index === 'number' ? fragment.index : 0;
      const slot = state.calls.get(index) ?? { id: '', name: '', args: '' };
      if (fragment.id) slot.id = fragment.id;
      if (fragment.function?.name) slot.name = fragment.function.name;
      if (fragment.function?.arguments) slot.args += fragment.function.arguments;
      state.calls.set(index, slot);
    }
  }
}

const toolCalls = [...state.calls.entries()]
  .sort((left, right) => left[0] - right[0])
  .map(([index, slot]) => {
    let parsedArguments = null;
    let argumentsError = null;
    try {
      parsedArguments = JSON.parse(slot.args);
    } catch (error) {
      argumentsError = error.message;
    }
    return { index, id: slot.id, name: slot.name, arguments: parsedArguments, argumentsRaw: slot.args, argumentsError };
  });

const result = {
  file: filePath,
  events,
  sawDone,
  role,
  finishReason,
  usage,
  contentLength: state.text.length,
  content: state.text,
  toolCalls,
};

if (asJson) {
  process.stdout.write(`${JSON.stringify(result)}\n`);
} else {
  process.stdout.write(`file        : ${result.file}\n`);
  process.stdout.write(`SSE events  : ${result.events}${result.sawDone ? ' (terminated by [DONE])' : ' (NO [DONE])'}\n`);
  process.stdout.write(`finish      : ${result.finishReason ?? '(none)'}\n`);
  if (result.usage) process.stdout.write(`usage       : ${JSON.stringify(result.usage)}\n`);
  process.stdout.write(`text        : ${result.content.length === 0 ? '(none)' : `${result.content.length} chars`}\n`);
  if (result.content.length > 0) {
    for (const line of result.content.split('\n')) process.stdout.write(`            | ${line}\n`);
  }
  if (result.toolCalls.length === 0) {
    process.stdout.write('tool calls  : (none)\n');
  } else {
    process.stdout.write(`tool calls  : ${result.toolCalls.length}\n`);
    for (const call of result.toolCalls) {
      process.stdout.write(`            [${call.index}] ${call.name}  id=${call.id}\n`);
      if (call.argumentsError) {
        process.stdout.write(`                ARGUMENTS INVALID: ${call.argumentsError}\n`);
        process.stdout.write(`                raw: ${call.argumentsRaw}\n`);
      } else {
        process.stdout.write(`                arguments: ${JSON.stringify(call.arguments)}\n`);
      }
    }
  }
}

const invalid = toolCalls.some((call) => call.argumentsError !== null);
process.exitCode = invalid ? 1 : 0;
