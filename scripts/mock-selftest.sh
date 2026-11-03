#!/bin/bash
# Self-test for the mock model server: proves the two behaviours the ios-port-E
# end-to-end test depends on.
#
#   1. STREAMING is really incremental. The client receives >= 6 separate SSE
#      content events and their arrival times are ~120ms apart. A reply
#      assembled in memory and flushed once would arrive in one millisecond.
#   2. TOOL CALLS form a multi-turn conversation keyed on REQUEST CONTENT:
#      turn 1 (0 tool results) -> `write`; turn 2 (1 tool result) -> `read` +
#      `glob`; turn 3 (2 tool results) -> final text. Streamed
#      `delta.tool_calls` fragments must reassemble into valid JSON arguments.
#
# Also covers: the non-streaming JSON path, /healthz, /v1/models, both URL
# spellings (/v1/chat/completions and /chat/completions), loopback-only binding,
# and error status codes.
#
# Usage: scripts/mock-selftest.sh [output-log]
#   output-log defaults to logs/mock-selftest.log
#
# Starts its own server on MOCK_PORT (default 19701, so a long-running instance
# on 19700 is untouched) and stops it afterwards.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="${NODE_BIN:-/opt/homebrew/bin/node}"
MOCK_PORT="${MOCK_PORT:-19701}"
OUT="${1:-$REPO_ROOT/logs/mock-selftest.log}"
LOG_DIR="$REPO_ROOT/logs"
BASE="http://127.0.0.1:$MOCK_PORT"
PARSER="$REPO_ROOT/mock/parse-sse.mjs"
CLIENT="$REPO_ROOT/mock/selftest-client.mjs"
TOOLS="$REPO_ROOT/mock/selftest-tools.json"
PROMPT='TOOLTEST write a file then read it back and search the workspace'

mkdir -p "$LOG_DIR"
: >"$OUT"

# Everything below is teed into the evidence log, including the commands, so the
# log reads as a transcript rather than a conclusion.
exec > >(tee -a "$OUT") 2>&1

say() { printf '\n=== %s ===\n' "$*"; }
run() { printf '\n$ %s\n' "$*"; "$@"; echo "[exit $?]"; }

printf 'mock self-test\n'
printf 'date        : %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
printf 'host        : %s %s\n' "$(uname -s)" "$(uname -m)"
printf 'node        : %s (%s)\n' "$("$NODE_BIN" -v)" "$NODE_BIN"
printf 'curl        : %s\n' "$(curl --version | head -1)"
printf 'port        : %s\n' "$MOCK_PORT"
printf 'repo        : %s\n' "$REPO_ROOT"

say '0. clean slate'
rm -f "$LOG_DIR/mock-requests.jsonl" "$LOG_DIR/mock-stream.jsonl"
printf '\n--- selftest run %s ---\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >>"$LOG_DIR/mock-server.log"
echo 'cleared mock-requests.jsonl and mock-stream.jsonl'

say "1. start server on 127.0.0.1:$MOCK_PORT"
MOCK_PORT="$MOCK_PORT" MOCK_CHUNK_DELAY_MS=120 MOCK_LOG_DIR="$LOG_DIR" \
  nohup "$NODE_BIN" "$REPO_ROOT/mock/server.mjs" >>"$LOG_DIR/mock-server.log" 2>&1 &
SERVER_PID=$!
echo "server pid $SERVER_PID"
cleanup() {
  if kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
    echo 'server stopped'
  fi
}
trap cleanup EXIT

for _ in $(seq 1 50); do
  if curl -fsS -m 2 "$BASE/healthz" >/dev/null 2>&1; then break; fi
  sleep 0.1
done

say '2. /healthz'
run curl -sS "$BASE/healthz"

say '3. /v1/models'
run curl -sS "$BASE/v1/models"

say '4. loopback-only binding (the LAN address must NOT answer)'
if LAN_IP="$(ipconfig getifaddr en0 2>/dev/null)" && [ -n "$LAN_IP" ]; then
  echo "LAN address: $LAN_IP"
  echo 'expect: refused / timeout, because the server binds 127.0.0.1 only'
  curl -sS -m 2 "http://$LAN_IP:$MOCK_PORT/healthz"; echo "[curl exit $?]"
else
  echo 'no en0 address on this host; skipped'
fi

# ---------------------------------------------------------------------------
say '5. STREAMING PATH — /v1/chat/completions, stream:true, 12 content chunks'
echo 'Each line below is one SSE event as it arrived, prefixed with +Nms since the'
echo 'first byte. ~120ms between content events is the proof that the reply is'
echo 'written incrementally instead of assembled and flushed once.'
curl -sS -N -m 30 -X POST "$BASE/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer mock-not-a-real-key' \
  --data-binary '{
    "model": "mock-model",
    "stream": true,
    "stream_options": {"include_usage": true},
    "messages": [
      {"role": "system", "content": "you are a test fixture"},
      {"role": "user", "content": "STREAMTEST please stream a long answer"}
    ]
  }' \
  | "$NODE_BIN" -e '
      const readline = require("node:readline");
      const start = process.hrtime.bigint();
      const rl = readline.createInterface({ input: process.stdin });
      let events = 0;
      let contentEvents = 0;
      let bytes = 0;
      rl.on("line", (line) => {
        const ms = Number((process.hrtime.bigint() - start) / 1000000n);
        if (line === "") return;
        events += 1;
        bytes += Buffer.byteLength(line) + 1;
        if (line.includes("\"content\"")) contentEvents += 1;
        const shown = line.length > 150 ? line.slice(0, 150) + "…" : line;
        console.log(`+${String(ms).padStart(4)}ms  e${String(events).padStart(2)}  ${shown}`);
      });
      rl.on("close", () => {
        console.log(`--- ${events} SSE lines, ${contentEvents} carrying a content delta, ${bytes} bytes total ---`);
      });
    '

say '6. STREAMING PATH via the bare /chat/completions spelling (baseURL without /v1)'
# Saved to a file rather than piped into `head`: closing the pipe early would
# truncate the stream and make the test weaker than the thing it checks.
curl -sS -N -m 30 -X POST "$BASE/chat/completions" \
  -H 'Content-Type: application/json' \
  --data-binary '{"model":"mock-model","stream":true,"messages":[{"role":"user","content":"STREAMTEST bare path"}]}' \
  >"$LOG_DIR/mock-selftest-barepath.sse"
echo "\$ raw SSE saved to logs/mock-selftest-barepath.sse ($(wc -c <"$LOG_DIR/mock-selftest-barepath.sse") bytes); parsed summary:"
run "$NODE_BIN" "$PARSER" "$LOG_DIR/mock-selftest-barepath.sse"

# ---------------------------------------------------------------------------
say '7. TOOL CALL PATH — turn 1: zero tool results in the conversation, expect a write tool call'
printf '{"model":"mock-model","stream":true,"messages":[{"role":"system","content":"you are a test fixture"},{"role":"user","content":"%s"}],"tools":%s}' \
  "$PROMPT" "$("$NODE_BIN" -e 'process.stdout.write(JSON.stringify(require(process.argv[1]).tools))' "$TOOLS")" \
  >"$LOG_DIR/mock-selftest-tool1-request.json"
run curl -sS -N -m 30 -X POST "$BASE/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  --data-binary "@$LOG_DIR/mock-selftest-tool1-request.json" >"$LOG_DIR/mock-selftest-tool1.sse"
echo "\$ raw SSE saved to logs/mock-selftest-tool1.sse ($(wc -c <"$LOG_DIR/mock-selftest-tool1.sse") bytes)"
run cat "$LOG_DIR/mock-selftest-tool1.sse"
echo
echo '$ reassembled (the same reassembly the OpenAI SDK inside DSH performs):'
run "$NODE_BIN" "$PARSER" "$LOG_DIR/mock-selftest-tool1.sse"

say '8. TOOL CALL PATH — turn 2: exactly one tool result present, expect read + glob'
run "$NODE_BIN" "$CLIENT" build-turn2 \
  "$LOG_DIR/mock-selftest-tool1.sse" "$TOOLS" "$PROMPT" "$LOG_DIR/mock-selftest-tool2-request.json"
run curl -sS -N -m 30 -X POST "$BASE/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  --data-binary "@$LOG_DIR/mock-selftest-tool2-request.json" >"$LOG_DIR/mock-selftest-tool2.sse"
echo "\$ raw SSE saved to logs/mock-selftest-tool2.sse ($(wc -c <"$LOG_DIR/mock-selftest-tool2.sse") bytes)"
run cat "$LOG_DIR/mock-selftest-tool2.sse"
echo
echo '$ reassembled:'
run "$NODE_BIN" "$PARSER" "$LOG_DIR/mock-selftest-tool2.sse"

say '9. TOOL CALL PATH — turn 3: two tool results present, expect final text'
run "$NODE_BIN" "$CLIENT" build-turn3 \
  "$LOG_DIR/mock-selftest-tool2-request.json" "$LOG_DIR/mock-selftest-tool2.sse" \
  "$LOG_DIR/mock-selftest-tool3-request.json"
echo
echo '$ single JSON response body (stream:false):'
run curl -sS -X POST "$BASE/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  --data-binary "@$LOG_DIR/mock-selftest-tool3-request.json" >"$LOG_DIR/mock-selftest-tool3.json"
cat "$LOG_DIR/mock-selftest-tool3.json"; echo
echo
echo '$ message + finish_reason:'
run "$NODE_BIN" "$CLIENT" summary "$LOG_DIR/mock-selftest-tool3.json"

# ---------------------------------------------------------------------------
say '10. non-streaming short fallback (no keyword in the conversation)'
run curl -sS -X POST "$BASE/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  --data-binary '{"model":"mock-model","messages":[{"role":"user","content":"ping"}]}'

say '11. error handling: malformed JSON, unknown route, GET on the completions route'
run curl -sS -o /dev/null -w 'malformed body  -> HTTP %{http_code}\n' -X POST "$BASE/v1/chat/completions" \
  -H 'Content-Type: application/json' --data-binary '{"model":'
run curl -sS -o /dev/null -w 'unknown route   -> HTTP %{http_code}\n' "$BASE/v1/nope"
run curl -sS -o /dev/null -w 'GET completions -> HTTP %{http_code}\n' "$BASE/v1/chat/completions"

say '12. the tool names the mock receives, next to the ones DSH registers'
echo 'The mock scripts tool calls by name, so the names it sees in `tools[].function.name`'
echo 'must match what DSH registers. Taken from mock-requests.jsonl (what actually arrived)'
echo 'and from the DSH sources in ios-port-A (what DSH registers).'
"$NODE_BIN" -e '
const fs = require("node:fs");
const records = fs.readFileSync(process.argv[1], "utf8").trim().split("\n").map((line) => JSON.parse(line));
const seen = new Set();
for (const record of records) for (const name of record.toolNames ?? []) seen.add(name);
console.log(`tool names the mock received : ${[...seen].sort().join(", ") || "(none)"}`);
const fixture = JSON.parse(fs.readFileSync(process.argv[2], "utf8")).tools.map((tool) => tool.function.name);
console.log(`tool names in my fixture     : ${fixture.sort().join(", ")}`);
const dshRoot = `${process.env.DSH_NODE_MODULES}/@deepseek-ai`;
const sources = [dshRoot + "/dsh-tool-fs/lib/index.js", dshRoot + "/dsh-tool-fs-search/lib/index.js"];
const registered = [];
for (const source of sources) {
  let text;
  try { text = fs.readFileSync(source, "utf8"); } catch { continue; }
  for (const match of text.matchAll(/name: "(write|read|edit|read_image|glob|grep)"/g)) registered.push(match[1]);
}
console.log(`tool names DSH registers     : ${[...new Set(registered)].sort().join(", ") || "(sources unreadable)"}`);
console.log("");
console.log(`parameter names, per tool (mine vs DSH source):`);
for (const tool of JSON.parse(fs.readFileSync(process.argv[2], "utf8")).tools) {
  if (tool.function.name === "grep") continue;
  console.log(`  ${tool.function.name.padEnd(6)} ${Object.keys(tool.function.parameters.properties).join(", ")}`);
}
console.log("");
console.log("note: the fixture is only what MY self-test sends. When the app runs, the");
console.log("      tools[] it sends comes from DSH itself; the mock reads the names out of");
console.log("      the request and never hard-codes them, so a mismatch would show up in");
console.log("      the request log rather than break the script.");
' "$LOG_DIR/mock-requests.jsonl" "$TOOLS"

say '13. mock-requests.jsonl — one line per request, with the script decision'
run wc -l "$LOG_DIR/mock-requests.jsonl"
echo '--- the fields the report cites ---'
"$NODE_BIN" -e '
const fs = require("node:fs");
const lines = fs.readFileSync(process.argv[1], "utf8").trim().split("\n").map((line) => JSON.parse(line));
// Records are appended when a reply finishes, so a short response can be logged
// after a longer, earlier one. Sort by ordinal for reading.
lines.sort((a, b) => a.request - b.request);
for (const r of lines) {
  console.log(
    `#${r.request} ${r.mode.padEnd(4)} model=${r.model} stream=${r.stream} messages=${r.messageCount} ` +
    `toolResults=${r.toolResultCount} hasTools=${r.hasTools} -> script=${r.script} step=${r.step} ` +
    `chunks=${r.responseChunks} bytes=${r.responseBytes ?? "-"} duration=${r.streamDurationMs ?? "-"}ms`
  );
  console.log(`    selection: keyword=${r.selection?.keyword} at=${r.selection?.matchedAt}`);
  console.log(`               ${r.selection?.reason}`);
  if (r.selection?.stepBasis) console.log(`               step basis: ${r.selection.stepBasis}`);
  if (r.chunkLabels) console.log(`    chunks: ${r.chunkLabels.join(" ")}`);
}
' "$LOG_DIR/mock-requests.jsonl"

say '14. mock-stream.jsonl — every SSE write with ordinal, byte count and elapsed time'
run wc -l "$LOG_DIR/mock-stream.jsonl"
"$NODE_BIN" -e '
const fs = require("node:fs");
const rows = fs.readFileSync(process.argv[1], "utf8").trim().split("\n").map((line) => JSON.parse(line));
const byRequest = new Map();
for (const row of rows) {
  if (!byRequest.has(row.request)) byRequest.set(row.request, []);
  byRequest.get(row.request).push(row);
}
for (const [request, list] of [...byRequest.entries()].sort((a, b) => a[0] - b[0])) {
  const isTextStream = list.some((row) => row.label.startsWith("content["));
  console.log(`request #${request}: ${list.length} SSE writes${isTextStream ? "  <- the 12-chunk streaming text reply" : ""}`);
  if (!isTextStream) {
    console.log(`    labels: ${list.map((row) => row.label).join(" ")}`);
    continue;
  }
  for (const row of list) {
    console.log(`    chunk ${String(row.chunk).padStart(2)}  +${String(row.elapsedMs).padStart(4)}ms  ${String(row.bytes).padStart(4)}B  ${row.label}`);
  }
  const gaps = list.slice(1).map((row, index) => row.elapsedMs - list[index].elapsedMs);
  console.log(`    inter-chunk gaps (ms): ${gaps.join(", ")}`);
}
' "$LOG_DIR/mock-stream.jsonl"

# ---------------------------------------------------------------------------
say '15. verdict'
"$NODE_BIN" -e '
const fs = require("node:fs");
const [requestsPath, streamPath] = process.argv.slice(1);
const requests = fs.readFileSync(requestsPath, "utf8").trim().split("\n").map((line) => JSON.parse(line));
const streamRows = fs.readFileSync(streamPath, "utf8").trim().split("\n").map((line) => JSON.parse(line));

// (a) streaming really produced many separately-written events.
const contentRows = streamRows.filter((row) => row.label.startsWith("content["));
const streamScripts = requests.filter((r) => r.script === "stream-12-chunks");
const streamOk = contentRows.length >= 6 && streamScripts.length >= 2;

// (b) those events were spread over time rather than flushed together.
const groups = new Map();
for (const row of contentRows) {
  if (!groups.has(row.request)) groups.set(row.request, []);
  groups.get(row.request).push(row);
}
const gaps = [];
for (const list of groups.values()) {
  for (let i = 1; i < list.length; i += 1) gaps.push(list[i].elapsedMs - list[i - 1].elapsedMs);
}
const spacingOk = gaps.length > 0 && Math.min(...gaps) >= 50;

// (c) the three tool steps were all selected.
const step1 = requests.find((r) => r.script === "tool-step1-write");
const step2 = requests.find((r) => r.script === "tool-step2-read-glob");
const step3 = requests.find((r) => r.script === "tool-step3-final-text");
const toolsOk = Boolean(step1 && step2 && step3);

// (d) the step came from the tool-result count in the request, not a counter.
// Turn 3 legitimately sees 3 results: one from write, two from read+glob.
const progressionOk = toolsOk &&
  step1.toolResultCount === 0 && step2.toolResultCount === 1 && step3.toolResultCount >= 2;

// (e) finish_reason matched what each turn was supposed to be.
const finishOk = toolsOk &&
  step1.finishReason === "tool_calls" && step2.finishReason === "tool_calls" && step3.finishReason === "stop";

// (f) the streamed argument fragments reassembled into valid JSON (parser exits 1 otherwise).
console.log(`(a) streaming chunks   : ${streamOk ? "PASS" : "FAIL"} — ${contentRows.length} content events over ${streamScripts.length} streaming-text requests (need >=6 over >=2)`);
console.log(`(b) chunk spacing      : ${spacingOk ? "PASS" : "FAIL"} — min gap ${gaps.length ? Math.min(...gaps) : "n/a"}ms over ${gaps.length} gaps (need >=50ms)`);
console.log(`(c) tool turns found   : ${toolsOk ? "PASS" : "FAIL"} — step1=${step1?.script ?? "MISSING"} step2=${step2?.script ?? "MISSING"} step3=${step3?.script ?? "MISSING"}`);
console.log(`(d) step from content  : ${progressionOk ? "PASS" : "FAIL"} — toolResultCount ${step1?.toolResultCount ?? "?"} -> ${step2?.toolResultCount ?? "?"} -> ${step3?.toolResultCount ?? "?"} (need 0 -> 1 -> >=2)`);
console.log(`(e) finish_reason      : ${finishOk ? "PASS" : "FAIL"} — ${step1?.finishReason ?? "?"} -> ${step2?.finishReason ?? "?"} -> ${step3?.finishReason ?? "?"}`);

const allOk = streamOk && spacingOk && toolsOk && progressionOk && finishOk;
console.log(allOk ? "VERDICT: PASS" : "VERDICT: FAIL");
process.exitCode = allOk ? 0 : 1;
' "$LOG_DIR/mock-requests.jsonl" "$LOG_DIR/mock-stream.jsonl"
HARNESS_VERDICT=$?
echo "[verdict exit $HARNESS_VERDICT]"

# ---------------------------------------------------------------------------
# The checks above prove the bytes on the wire. This step proves the other half:
# that DSH's own openai-completions client library parses those bytes into the
# stream events it expects. It imports pi-ai straight out of the ios-port-A
# install tree (read-only) — the exact module @deepseek-ai/dsh-llm-pi-ai calls.
say '16. consumed by pi-ai, the openai-completions client DSH actually uses'
echo 'Curling proves the wire bytes; this proves DSH can turn them into text_delta'
echo 'and toolcall_start/delta/end events with the right stopReason.'
if [ -f "$REPO_ROOT/mock/verify-with-pi-ai.mjs" ]; then
  "$NODE_BIN" "$REPO_ROOT/mock/verify-with-pi-ai.mjs" "$BASE"
  PIAI_VERDICT=$?
  echo "[pi-ai verify exit $PIAI_VERDICT]"
else
  echo 'mock/verify-with-pi-ai.mjs not found; skipped'
  PIAI_VERDICT=1
fi

say 'done'
if [ "$HARNESS_VERDICT" -eq 0 ] && [ "$PIAI_VERDICT" -eq 0 ]; then
  echo 'OVERALL: PASS (wire-level checks + pi-ai client parsing)'
  VERDICT=0
else
  echo "OVERALL: FAIL (wire-level exit $HARNESS_VERDICT, pi-ai exit $PIAI_VERDICT)"
  VERDICT=1
fi
echo "evidence log: $OUT"
echo "server log  : $LOG_DIR/mock-server.log"
exit "$VERDICT"
