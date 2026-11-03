#!/usr/bin/env node
// Test helper: act like an OpenAI-compatible client for the tool-call script.
//
// The mock's tool script is a conversation, not a single response: turn 1 hands
// out `write`, turn 2 (after the tool result) hands out `read` + `glob`, turn 3
// returns prose. Driving that from bash means echoing `assistant.tool_calls` and
// appending `role: "tool"` messages by hand, which is fiddly and easy to get
// subtly wrong. This helper does it with the same reassembly logic a real client
// uses, then prints what each turn produced.
//
// Modes
//   build-turn2 <transcript1.sse> <tools.json> <prompt> <out-request.json>
//       Read turn 1's stream, replay the assistant tool_calls, append one
//       role:tool result, write the turn-2 request body.
//   build-turn3 <turn2-request.json> <turn2-transcript.sse> <out-request.json>
//       Read the turn-2 request, append results for both calls, set stream:false.
//   summary <response.json>
//       Print choices[0].message and finish_reason of a non-streaming body.
//
// Exit code 1 if any reassembled arguments were not valid JSON.

import fs from 'node:fs';

/** Reassemble one SSE transcript into text + tool calls. */
function reassembleTranscript(filePath) {
  const raw = fs.readFileSync(filePath, 'utf8');
  const state = { text: '', calls: new Map() };
  let finishReason = null;
  for (const line of raw.split('\n')) {
    if (!line.startsWith('data: ')) continue;
    const body = line.slice(6).trim();
    if (body === '[DONE]') continue;
    let chunk;
    try {
      chunk = JSON.parse(body);
    } catch {
      continue;
    }
    const choice = Array.isArray(chunk.choices) ? chunk.choices[0] : undefined;
    if (!choice) continue;
    if (choice.finish_reason) finishReason = choice.finish_reason;
    const delta = choice.delta;
    if (!delta) continue;
    if (typeof delta.content === 'string') state.text += delta.content;
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
      let argumentsObject = null;
      let argumentsError = null;
      try {
        argumentsObject = JSON.parse(slot.args);
      } catch (error) {
        argumentsError = error.message;
      }
      return { index, id: slot.id, name: slot.name, arguments: argumentsObject, argumentsError };
    });
  return { text: state.text, toolCalls, finishReason };
}

const [, , mode, ...rest] = process.argv;

if (mode === 'build-turn2') {
  const [transcriptPath, toolsPath, prompt, outPath] = rest;
  const { toolCalls, finishReason } = reassembleTranscript(transcriptPath);
  if (toolCalls.length === 0) {
    process.stderr.write('build-turn2: turn 1 produced no tool calls; nothing to replay\n');
    process.exit(1);
  }
  const bad = toolCalls.filter((call) => call.argumentsError !== null);
  if (bad.length > 0) {
    process.stderr.write(`build-turn2: reassembled arguments are not valid JSON: ${bad[0].argumentsError}\n`);
    process.exit(1);
  }
  const body = {
    model: 'mock-model',
    stream: true,
    messages: [
      { role: 'system', content: 'you are a test fixture' },
      { role: 'user', content: prompt },
      {
        role: 'assistant',
        content: null,
        tool_calls: toolCalls.map((call) => ({
          id: call.id,
          type: 'function',
          function: { name: call.name, arguments: JSON.stringify(call.arguments) },
        })),
      },
      // One tool result for the single call turn 1 made.
      {
        role: 'tool',
        tool_call_id: toolCalls[0].id,
        content: `Created ${toolCalls[0].arguments.file_path}`,
      },
    ],
    tools: JSON.parse(fs.readFileSync(toolsPath, 'utf8')).tools,
  };
  fs.writeFileSync(outPath, JSON.stringify(body, null, 2));
  process.stdout.write(
    `turn 1 finish_reason : ${finishReason}\n` +
      `turn 1 tool calls    : ${toolCalls.map((call) => `${call.name}(${call.id})`).join(', ')}\n` +
      `turn 1 arguments     : ${JSON.stringify(toolCalls[0].arguments)}\n` +
      `turn-2 request       : ${outPath}\n` +
      `  assistant replays the tool_call, then 1 role:tool message -> expect toolResultCount 1\n`,
  );
  process.exit(0);
}

if (mode === 'build-turn3') {
  const [turn2RequestPath, turn2TranscriptPath, outPath] = rest;
  const body = JSON.parse(fs.readFileSync(turn2RequestPath, 'utf8'));
  // The calls to answer next are in turn 2's RESPONSE, not its request. Turn 2's
  // request already carries one tool result (from the write call).
  const turn2 = reassembleTranscript(turn2TranscriptPath);
  if (turn2.toolCalls.length === 0) {
    process.stderr.write('build-turn3: turn 2 produced no tool calls; nothing to answer\n');
    process.exit(1);
  }
  const badArgs = turn2.toolCalls.filter((call) => call.argumentsError !== null);
  if (badArgs.length > 0) {
    process.stderr.write(`build-turn3: reassembled arguments are not valid JSON: ${badArgs[0].argumentsError}\n`);
    process.exit(1);
  }
  const existingResults = body.messages.filter((message) => message.role === 'tool').length;
  body.messages = [
    ...body.messages,
    {
      role: 'assistant',
      content: null,
      tool_calls: turn2.toolCalls.map((call) => ({
        id: call.id,
        type: 'function',
        function: { name: call.name, arguments: JSON.stringify(call.arguments) },
      })),
    },
    ...turn2.toolCalls.map((call) => ({
      role: 'tool',
      tool_call_id: call.id,
      content:
        call.name === 'read'
          ? '1\tmock-model wrote this file through the DSH write tool inside the app process.'
          : 'mock-tool-output.txt',
    })),
  ];
  // Non-streaming here on purpose: this turn also covers the one-shot JSON path.
  body.stream = false;
  delete body.stream_options;
  fs.writeFileSync(outPath, JSON.stringify(body, null, 2));
  const totalResults = body.messages.filter((message) => message.role === 'tool').length;
  process.stdout.write(
    `turn-3 request       : ${outPath} (stream:false)\n` +
      `  turn 2 answered with : ${turn2.toolCalls.map((call) => `${call.name}(${call.id})`).join(', ')} (finish_reason ${turn2.finishReason})\n` +
      `  role:tool messages   : ${existingResults} already + ${turn2.toolCalls.length} new = ${totalResults} -> expect the final-text script\n`,
  );
  process.exit(0);
}

if (mode === 'summary') {
  const [responsePath] = rest;
  const body = JSON.parse(fs.readFileSync(responsePath, 'utf8'));
  const choice = body.choices?.[0];
  process.stdout.write(`${JSON.stringify(choice?.message ?? null, null, 2)}\n`);
  process.stdout.write(`finish_reason: ${choice?.finish_reason}\n`);
  process.stdout.write(`usage        : ${JSON.stringify(body.usage)}\n`);
  process.exit(0);
}

process.stderr.write(
  'usage:\n' +
    '  node mock/selftest-client.mjs build-turn2 <transcript.sse> <tools.json> <prompt> <out-request.json>\n' +
    '  node mock/selftest-client.mjs build-turn3 <turn2-request.json> <turn2-transcript.sse> <out-request.json>\n' +
    '  node mock/selftest-client.mjs summary <response.json>\n',
);
process.exit(2);
