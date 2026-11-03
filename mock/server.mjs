#!/usr/bin/env node
// Mock model server for the ios-port-C end-to-end test.
//
// Speaks the OpenAI Chat Completions wire protocol on 127.0.0.1 so that the DSH
// build running inside an iOS app can talk to a model without any API key. It is
// deliberately small and dependency-free: `node:http` only, so it also runs
// under `node --jitless` if that is ever useful.
//
// Why the streaming is written the way it is: the point of this server in the
// test is to prove that token streaming survives the embedded-Node path. A
// reply assembled in memory and flushed once would prove nothing, so every SSE
// event goes out through its own `res.write()` with the socket's Nagle
// algorithm disabled, and each write is recorded with its ordinal, byte length
// and timestamp in logs/mock-stream.jsonl.
//
// Endpoints
//   POST /v1/chat/completions   (also /chat/completions)
//   GET  /v1/models             (also /models)
//   GET  /healthz
//
// Configuration (environment)
//   MOCK_PORT             default 19700
//   MOCK_HOST             default 127.0.0.1 (must stay a loopback address)
//   MOCK_CHUNK_DELAY_MS   default 120, pause between SSE events
//   MOCK_LOG_DIR          default <repo>/logs
//   MOCK_TOOL_PATH        default mock-tool-output.txt (file the scripted write creates)

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  allImageParts,
  planReply,
  APPROVALTEST_KEYWORD,
  CODE_KEYWORD,
  ERRORTEST_KEYWORD,
  IMAGE_KEYWORD,
  PATHTEST_KEYWORD,
  QUESTIONTEST_KEYWORD,
  READ_IMAGE_KEYWORD,
  RMTEST_KEYWORD,
  STREAM_KEYWORD,
  TOOL_KEYWORD,
} from './replies.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(HERE, '..');

/** Loopback-only binding is a hard requirement: this server hands out fake model replies. */
const HOST = process.env.MOCK_HOST || '127.0.0.1';
const PORT = Number.parseInt(process.env.MOCK_PORT || '19700', 10);
const CHUNK_DELAY_MS = Number.parseInt(process.env.MOCK_CHUNK_DELAY_MS || '120', 10);
const LOG_DIR = process.env.MOCK_LOG_DIR || path.join(REPO_ROOT, 'logs');

const REQUEST_LOG = path.join(LOG_DIR, 'mock-requests.jsonl');
const STREAM_LOG = path.join(LOG_DIR, 'mock-stream.jsonl');
const SERVER_LOG = path.join(LOG_DIR, 'mock-server.log');

/** Maximum request body we will accept: a real transcript is far smaller. */
const MAX_BODY_BYTES = 32 * 1024 * 1024;

fs.mkdirSync(LOG_DIR, { recursive: true });

/** Append one JSON line, synchronously, so a crash cannot lose the last record. */
function appendJsonl(file, record) {
  try {
    fs.appendFileSync(file, `${JSON.stringify(record)}\n`);
  } catch (error) {
    // Logging must never take the request down.
    process.stderr.write(`mock: failed to append ${file}: ${error.message}\n`);
  }
}

/** Human-readable line into the server log and stderr. */
function note(message) {
  const line = `${new Date().toISOString()} ${message}`;
  try {
    fs.appendFileSync(SERVER_LOG, `${line}\n`);
  } catch {
    /* ignore */
  }
  process.stderr.write(`${line}\n`);
}

/**
 * Estimate the prompt's token-bearing size, charging images a realistic amount.
 *
 * WHY THIS EXISTS: the naive `JSON.stringify(messages).length / 4` charges a
 * base64 image its encoded characters, so three phone photos made a ~2.5 MB
 * request look like ~640k tokens. The harness compares the provider's reported
 * usage against the route's declared `contextWindow` and refuses the turn with
 * CONTEXT_WINDOW_EXCEEDED before anything is sent — a false positive caused by
 * the mock's own arithmetic.
 *
 * A vision provider does not price a picture by its byte length either; it
 * charges a per-image allowance plus roughly one token per patch of pixels. The
 * constants below are estimates, chosen to be the right order of magnitude
 * rather than exact: 1024 tokens per image plus 1 token per 4096 pixels. Their
 * only job is to keep the number plausible, and the mock's request log still
 * records the true byte sizes separately.
 * @param {object[]} messages - the request's messages.
 * @returns {number} the estimated character-equivalent size (tokens = this / 4).
 */
function estimatePromptChars(messages) {
  const IMAGE_TOKEN_ALLOWANCE = 1024;
  const TOKENS_PER_PIXEL = 1 / 4096;
  // One token is about four characters, so a token allowance converts back with *4.
  let total = 0;
  for (const message of messages) {
    if (message === null || typeof message !== 'object') continue;
    const images = allImageParts([message]);
    total += JSON.stringify(stripImagePayloads(message)).length;
    for (const image of images) {
      const pixels = (image.width ?? 1024) * (image.height ?? 1024);
      total += 4 * Math.ceil(IMAGE_TOKEN_ALLOWANCE + pixels * TOKENS_PER_PIXEL);
    }
  }
  return total;
}

/** A copy of one message with base64 image payloads replaced by a short marker. */
function stripImagePayloads(message) {
  if (!Array.isArray(message.content)) return message;
  return {
    ...message,
    content: message.content.map((part) => {
      if (part === null || typeof part !== 'object') return part;
      if (part.type === 'image_url') return { type: 'image_url', image_url: { url: '<image>' } };
      if (part.type === 'image' && typeof part.data === 'string') return { ...part, data: '<image>' };
      return part;
    }),
  };
}

/** Every image part in one decoded request, flattened across messages. */
function allImagesOf(request) {
  const messages = Array.isArray(request?.messages) ? request.messages : [];
  return allImageParts(messages);
}

let requestOrdinal = 0;
let streamOrdinal = 0;
const startedAt = Date.now();

/** Split a JSON argument string into small pieces, as a real model streams it. */
function sliceArguments(json, size = 18) {
  const pieces = [];
  for (let offset = 0; offset < json.length; offset += size) {
    pieces.push(json.slice(offset, offset + size));
  }
  return pieces.length === 0 ? [''] : pieces;
}

/** Wrap one event as an SSE frame. */
function sseFrame(payload) {
  return `data: ${typeof payload === 'string' ? payload : JSON.stringify(payload)}\n\n`;
}

/**
 * Write one SSE event and record exactly what left the process.
 * @param {import('node:http').ServerResponse} res - the response.
 * @param {object} context - per-request bookkeeping.
 * @param {object|string} payload - the `data:` payload.
 * @param {string} label - what this event carries, for the log.
 * @returns {Promise<void>} resolves after the socket accepted the bytes.
 */
function writeEvent(res, context, payload, label) {
  const frame = sseFrame(payload);
  const bytes = Buffer.byteLength(frame);
  res.write(frame);
  // flushHeaders already forces headers out; every `write` below is a separate
  // chunk on the wire because the socket was opened with setNoDelay.
  context.chunks.push({
    ordinal: context.chunks.length + 1,
    label,
    bytes,
    at: new Date().toISOString(),
    elapsedMs: Date.now() - context.startedAt,
  });
  if (typeof res.flush === 'function') res.flush();
  if (context.logChunks) {
    appendJsonl(STREAM_LOG, {
      t: new Date().toISOString(),
      request: context.ordinal,
      chunk: context.chunks.length,
      label,
      bytes,
      elapsedMs: Date.now() - context.startedAt,
    });
  }
  return Promise.resolve();
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** Base chunk every stream starts from. */
function chunkEnvelope(id, model, created) {
  return {
    id,
    object: 'chat.completion.chunk',
    created,
    model,
    choices: [],
  };
}

/**
 * Stream a reply plan as SSE.
 * @param {import('node:http').ServerResponse} res - response.
 * @param {object} plan - from {@link planReply}.
 * @param {object} request - the request body.
 * @param {object} context - per-request bookkeeping.
 */
async function streamReply(res, plan, request, context) {
  const model = typeof request.model === 'string' ? request.model : 'mock-model';
  const streamId = `chatcmpl-mock-${context.ordinal}-${Date.now().toString(36)}`;
  const created = Math.floor(Date.now() / 1000);
  const envelope = chunkEnvelope(streamId, model, created);
  const wantsUsage = Boolean(request?.stream_options?.include_usage);

  // Role announcement, exactly as OpenAI does it.
  await writeEvent(
    res,
    context,
    { ...envelope, choices: [{ index: 0, delta: { role: 'assistant', content: '' }, finish_reason: null }] },
    'role',
  );
  if (CHUNK_DELAY_MS > 0) await sleep(CHUNK_DELAY_MS);

  if (plan.kind === 'tool') {
    for (let callIndex = 0; callIndex < plan.toolCalls.length; callIndex += 1) {
      const call = plan.toolCalls[callIndex];
      const pieces = sliceArguments(call.function.arguments);
      // Head piece: index + id + type + function.name, with the first slice of arguments.
      await writeEvent(
        res,
        context,
        {
          ...envelope,
          choices: [
            {
              index: 0,
              delta: {
                tool_calls: [
                  {
                    index: callIndex,
                    id: call.id,
                    type: 'function',
                    function: { name: call.function.name, arguments: pieces[0] },
                  },
                ],
              },
              finish_reason: null,
            },
          ],
        },
        `tool_call[${callIndex}].head:${call.function.name}`,
      );
      if (CHUNK_DELAY_MS > 0) await sleep(CHUNK_DELAY_MS);
      // Tail pieces: index + arguments increment only, as the protocol specifies.
      for (let pieceIndex = 1; pieceIndex < pieces.length; pieceIndex += 1) {
        await writeEvent(
          res,
          context,
          {
            ...envelope,
            choices: [
              {
                index: 0,
                delta: { tool_calls: [{ index: callIndex, function: { arguments: pieces[pieceIndex] } }] },
                finish_reason: null,
              },
            ],
          },
          `tool_call[${callIndex}].args[${pieceIndex}]`,
        );
        if (CHUNK_DELAY_MS > 0) await sleep(CHUNK_DELAY_MS);
      }
    }
    await writeEvent(
      res,
      context,
      { ...envelope, choices: [{ index: 0, delta: {}, finish_reason: plan.finish }] },
      `finish:${plan.finish}`,
    );
  } else {
    // A text plan carries either `segments` (multi-chunk) or a single `text`
    // string; normalise so one code path streams both.
    const segments = plan.segments ?? [plan.text ?? ''];
    for (let index = 0; index < segments.length; index += 1) {
      await writeEvent(
        res,
        context,
        {
          ...envelope,
          choices: [{ index: 0, delta: { content: segments[index] }, finish_reason: null }],
        },
        `content[${index}]`,
      );
      if (CHUNK_DELAY_MS > 0) await sleep(CHUNK_DELAY_MS);
    }
    await writeEvent(
      res,
      context,
      { ...envelope, choices: [{ index: 0, delta: {}, finish_reason: plan.finish }] },
      `finish:${plan.finish}`,
    );
  }

  if (wantsUsage) {
    // Image parts are counted by what they REPRESENT, not by their base64 length.
    //
    // A base64 data URL is about 4/3 the byte size of the picture, so a 2.5 MB
    // prompt full of photographs measured as ~640k "tokens" and the harness's
    // overflow detector rejected the turn before it was ever sent
    // (CONTEXT_WINDOW_EXCEEDED: "pi-ai detected context overflow"). That number
    // was an artifact of the estimate, not of the request: no real vision
    // provider prices a photo at bytes/4 characters.
    //
    // The estimate now charges each image a flat allowance plus a small amount
    // per megapixel, and counts only the TEXT of a message by its characters.
    const promptChars = estimatePromptChars(request.messages ?? []);
    const outputChars = plan.kind === 'tool'
      ? JSON.stringify(plan.toolCalls).length
      : (plan.segments ?? [plan.text ?? '']).join('').length;
    await writeEvent(
      res,
      context,
      {
        ...envelope,
        choices: [],
        usage: {
          prompt_tokens: Math.max(1, Math.round(promptChars / 4)),
          completion_tokens: Math.max(1, Math.round(outputChars / 4)),
          total_tokens: Math.max(2, Math.round((promptChars + outputChars) / 4)),
        },
      },
      'usage',
    );
    if (CHUNK_DELAY_MS > 0) await sleep(CHUNK_DELAY_MS);
  }

  await writeEvent(res, context, '[DONE]', 'done');
}

/**
 * Answer with one JSON body (stream: false).
 * @param {import('node:http').ServerResponse} res - response.
 * @param {object} plan - from {@link planReply}.
 * @param {object} request - the request body.
 * @param {object} context - per-request bookkeeping.
 */
function sendWholeReply(res, plan, request, context) {
  const model = typeof request.model === 'string' ? request.model : 'mock-model';
  const message = { role: 'assistant', content: null };
  if (plan.kind === 'tool') {
    message.content = null;
    message.tool_calls = plan.toolCalls;
  } else {
    message.content = plan.segments ? plan.segments.join('') : plan.text ?? '';
  }
  const body = {
    id: `chatcmpl-mock-${context.ordinal}-${Date.now().toString(36)}`,
    object: 'chat.completion',
    created: Math.floor(Date.now() / 1000),
    model,
    choices: [{ index: 0, message, finish_reason: plan.finish }],
    usage: {
      prompt_tokens: Math.max(1, Math.round(estimatePromptChars(request.messages ?? []) / 4)),
      completion_tokens: 1,
      total_tokens: 2,
    },
  };
  const payload = JSON.stringify(body);
  res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(payload) });
  res.end(payload);
}

/** Read the request body with a hard size cap. */
function readBody(req) {
  return new Promise((resolve, reject) => {
    const parts = [];
    let total = 0;
    req.on('data', (chunk) => {
      total += chunk.length;
      if (total > MAX_BODY_BYTES) {
        reject(new Error(`request body exceeds ${MAX_BODY_BYTES} bytes`));
        req.destroy();
        return;
      }
      parts.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(parts)));
    req.on('error', reject);
  });
}

/** Send a JSON error body the way the OpenAI API does. */
function sendError(res, status, message, type = 'invalid_request_error') {
  if (res.headersSent) {
    res.end();
    return;
  }
  const payload = JSON.stringify({ error: { message, type, code: status } });
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(payload);
}

/** Route one request. */
async function handle(req, res) {
  const url = new URL(req.url ?? '/', `http://${HOST}:${PORT}`);
  const route = url.pathname;

  if (route === '/healthz') {
    const payload = JSON.stringify({
      ok: true,
      service: 'mock-model',
      pid: process.pid,
      node: process.version,
      host: HOST,
      port: PORT,
      chunkDelayMs: CHUNK_DELAY_MS,
      uptimeSeconds: Math.round((Date.now() - startedAt) / 1000),
      requests: requestOrdinal,
      streams: streamOrdinal,
      keywords: {
        tool: TOOL_KEYWORD,
        stream: STREAM_KEYWORD,
        code: CODE_KEYWORD,
        image: IMAGE_KEYWORD,
        readImage: READ_IMAGE_KEYWORD,
        path: PATHTEST_KEYWORD,
        remove: RMTEST_KEYWORD,
        approval: APPROVALTEST_KEYWORD,
        question: QUESTIONTEST_KEYWORD,
        error: ERRORTEST_KEYWORD,
      },
      logs: { requests: REQUEST_LOG, stream: STREAM_LOG },
    });
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(payload);
    return;
  }

  if (route === '/v1/models' || route === '/models') {
    const payload = JSON.stringify({
      object: 'list',
      data: [
        { id: 'mock-model', object: 'model', owned_by: 'mock', created: Math.floor(startedAt / 1000) },
        { id: 'mock-model-tools', object: 'model', owned_by: 'mock', created: Math.floor(startedAt / 1000) },
      ],
    });
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(payload);
    return;
  }

  // Both spellings are served because a baseURL may or may not carry /v1.
  if (route === '/v1/chat/completions' || route === '/chat/completions') {
    if (req.method !== 'POST') {
      sendError(res, 405, 'chat completions requires POST');
      return;
    }
    let raw;
    try {
      raw = await readBody(req);
    } catch (error) {
      sendError(res, 413, error.message);
      return;
    }
    let request;
    try {
      request = JSON.parse(raw.toString('utf8'));
    } catch (error) {
      sendError(res, 400, `request body is not JSON: ${error.message}`);
      return;
    }

    const plan = planReply(request);
    requestOrdinal += 1;
    const context = {
      ordinal: requestOrdinal,
      startedAt: Date.now(),
      chunks: [],
      logChunks: true,
    };
    const stream = request.stream === true;
    if (stream) streamOrdinal += 1;

    const toolResultMessages = (request.messages ?? []).filter((message) => message?.role === 'tool').length;
    const record = {
      t: new Date().toISOString(),
      request: requestOrdinal,
      method: req.method,
      path: route,
      model: request.model ?? null,
      stream,
      streamOptions: request.stream_options ?? null,
      messageCount: Array.isArray(request.messages) ? request.messages.length : 0,
      roles: Array.isArray(request.messages) ? request.messages.map((message) => message?.role ?? '?') : [],
      toolResultCount: toolResultMessages,
      hasTools: Array.isArray(request.tools) && request.tools.length > 0,
      toolNames: Array.isArray(request.tools) ? request.tools.map((tool) => tool?.function?.name ?? null) : [],
      userId: request.user ?? null,
      script: plan.script,
      scriptKind: plan.kind,
      step: plan.step,
      selection: plan.selection,
      finishReason: plan.finish,
      requestBytes: raw.length,
      // Image parts, described from the request the client actually sent. This
      // is the primary evidence for the attachment acceptance: it records what
      // arrived (media type, byte length, sniffed container) without echoing the
      // pixels into a log.
      images: allImagesOf(request),
      authHeaderPresent: typeof req.headers.authorization === 'string' && req.headers.authorization.length > 0,
      // The complete request body, as the task asks for. It is the whole point of
      // this log: when a turn misbehaves, the transcript is the evidence.
      // Named `requestBody`, NOT `request`: `request` above is this record's
      // ordinal, and reusing the key silently replaced the number with the body.
      requestBody: request,
    };

    if (!stream) {
      sendWholeReply(res, plan, request, context);
      appendJsonl(REQUEST_LOG, { ...record, mode: 'json', responseChunks: 1 });
      note(`#${context.ordinal} ${route} model=${record.model} messages=${record.messageCount} tools=${record.hasTools} script=${plan.script} step=${plan.step} -> json`);
      return;
    }

    res.writeHead(200, {
      'Content-Type': 'text/event-stream; charset=utf-8',
      'Cache-Control': 'no-cache, no-transform',
      Connection: 'keep-alive',
      'X-Accel-Buffering': 'no',
    });
    // Force the headers onto the wire before the first event so the client can
    // start reading immediately, and disable Nagle so 120ms spacing is real.
    res.flushHeaders();
    if (req.socket) {
      req.socket.setNoDelay(true);
      req.socket.setKeepAlive(true);
    }

    try {
      await streamReply(res, plan, request, context);
    } catch (error) {
      note(`#${context.ordinal} stream failed: ${error.message}`);
    }
    res.end();
    appendJsonl(REQUEST_LOG, {
      ...record,
      mode: 'sse',
      responseChunks: context.chunks.length,
      responseBytes: context.chunks.reduce((sum, chunk) => sum + chunk.bytes, 0),
      streamDurationMs: Date.now() - context.startedAt,
      chunkLabels: context.chunks.map((chunk) => `${chunk.ordinal}:${chunk.label}:${chunk.bytes}B`),
    });
    note(
      `#${context.ordinal} ${route} model=${record.model} messages=${record.messageCount} tools=${record.hasTools} ` +
        `script=${plan.script} step=${plan.step} -> sse ${context.chunks.length} chunks ` +
        `${context.chunks.reduce((sum, chunk) => sum + chunk.bytes, 0)}B in ${Date.now() - context.startedAt}ms`,
    );
    return;
  }

  sendError(res, 404, `no route for ${req.method} ${route}`, 'not_found');
}

const server = http.createServer((req, res) => {
  handle(req, res).catch((error) => {
    note(`unhandled: ${error.stack ?? error.message}`);
    sendError(res, 500, error.message, 'server_error');
  });
});
server.keepAliveTimeout = 65_000;
server.headersTimeout = 70_000;

server.on('error', (error) => {
  note(`listen failed: ${error.message}`);
  process.exitCode = 1;
});

server.listen(PORT, HOST, () => {
  note(
    `mock-model listening on http://${HOST}:${PORT} (node ${process.version}, chunk delay ${CHUNK_DELAY_MS}ms)`,
  );
  note(`request log: ${REQUEST_LOG}`);
  note(`stream log:  ${STREAM_LOG}`);
  process.stdout.write(
    `mock-model listening on http://${HOST}:${PORT}\n` +
      `  POST /v1/chat/completions  (also /chat/completions)\n` +
      `  GET  /v1/models, /healthz\n` +
      `  logs: ${LOG_DIR}\n`,
  );
});

/** Exit cleanly so the self-test script does not have to SIGKILL. */
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    note(`received ${signal}, shutting down after ${requestOrdinal} request(s)`);
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 2_000).unref();
  });
}
