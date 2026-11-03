# Mock 模型服务

用于 ios-port-C 端到端测试的假模型服务：说 OpenAI / DeepSeek 的 Chat Completions 协议，**不需要任何真实密钥**，只绑 `127.0.0.1`。

App 里内嵌的 Node 跑着 DSH，DSH 的模型提供方（`openai-completions` 协议）指向这个服务，就能在真 iOS 进程里验证「流式输出」和「文件工具调用」两条链路。

## 为什么长这样

两件事决定了实现方式。

**流式必须是真的逐块写。** 这个服务在测试里唯一的价值，就是证明 token 流没有被某层缓冲吃掉。如果先把整段回复拼好再一次性 flush，那这个测试什么也证明不了。所以每个 SSE 事件走独立的 `res.write()`，socket 关掉 Nagle（`setNoDelay`），每块之间停顿约 120ms，并且**每一块写出去都记一条带序号、字节数、时间戳的日志**（`logs/mock-stream.jsonl`）。客户端侧只要看到 15 个回调相隔约 120ms，就说明是真流式。

**脚本必须由请求内容决定，不能靠服务端计数器。** App 会重启、多个会话会交错、同一个请求可能被重放。所以"这一轮该回什么"是 `messages` 数组的纯函数：命中哪个关键词决定走哪条脚本，`role: "tool"` 消息的条数决定走到第几步。服务端不存会话状态。

## 快速开始

```bash
# 默认 127.0.0.1:19700，后台起
scripts/mock-start.sh start

curl -sS http://127.0.0.1:19700/healthz

# 停
scripts/mock-start.sh stop
```

## 接口

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/v1/chat/completions`、`/chat/completions` | Chat Completions。两种拼法都支持，因为 DSH 的 `baseURL` 可能带也可能不带 `/v1` |
| GET | `/v1/models`、`/models` | 列出 `mock-model` |
| GET | `/healthz` | 健康检查，返回端口、pid、请求计数、关键词 |

`stream: true` 走 SSE（`data: {...}` 逐块，结尾 `data: [DONE]`）；`stream: false` 走一次性 JSON。`Authorization` 头**不做任何校验**——传占位值、传空值、完全不传都行，就是这个服务存在的意义。

## 两条脚本

选哪个脚本看 `messages` 里有没有关键词（从最后一条 user 消息往前找，找不到再全量扫一遍）。

### (a) 流式文本：`STREAMTEST`

12 段文本，每段一个 SSE 事件，事件间约 120ms。最后一段是 `STREAMTEST-COMPLETE`，方便脚本断言"整段都收到了"。

```bash
curl -sS -N http://127.0.0.1:19700/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"mock-model","stream":true,
       "messages":[{"role":"user","content":"STREAMTEST 流式测试"}]}'
```

### (b) 工具调用：`TOOLTEST`

三轮，靠 `role: "tool"` 消息条数推进。用的是 DSH 真实的工具名和参数形状（`write` / `read` / `glob`，见 `selftest-tools.json`）。

| 步 | 请求里的 tool 结果数 | 返回 |
|---|---|---|
| 1 | 0 | `write` 工具调用，写 `mock-tool-output.txt` |
| 2 | 1 | `read` + `glob` 两个工具调用（同一轮里） |
| 3 | ≥2 | 最终文本，`finish_reason: stop` |

流式下 `tool_calls` 按协议分片：首片带 `index`、`id`、`type: "function"`、`function.name` 和第一段 arguments；后续片只带 `index` 和 `function.arguments` 的增量片段。这几片拼起来必须是合法 JSON —— `mock/parse-sse.mjs` 就是干这个的。

安全阀：如果累积到 3 次 assistant 工具回合还在发工具结果（说明客户端没在推进），就返回最终文本结束循环，而不是无限打转。

两个关键词都没有时，回一条短文本用于连通性检查。

## 文件

```
mock/
  server.mjs              HTTP 服务本体（node:http，零依赖）
  replies.mjs             脚本选择逻辑 + 回复内容（纯函数，无状态）
  parse-sse.mjs           把 SSE transcript 重组成文本 / 工具调用，供自测断言
  selftest-client.mjs     模拟客户端跑完整个多轮工具对话
  selftest-tools.json     write/read/glob/grep 的工具声明，形状对齐 DSH 真实注册
  verify-with-pi-ai.mjs   用 DSH 自己的 openai-completions 客户端库解析我的回复
  reachability/probe.swift 从模拟器内部探测宿主机 loopback 的 Swift 探针
```

```
scripts/
  mock-start.sh           start | stop | status | foreground
  mock-selftest.sh        服务端自测（curl + pi-ai 双层验证）
  mock-reachability.sh    模拟器内可达性 + 真流式到达验证
```

## 配置

| 环境变量 | 默认 | 说明 |
|---|---|---|
| `MOCK_PORT` | `19700` | 监听端口 |
| `MOCK_HOST` | `127.0.0.1` | 监听地址，应当保持 loopback |
| `MOCK_CHUNK_DELAY_MS` | `120` | 事件间隔；设 0 可加速（但流式证据就弱了） |
| `MOCK_LOG_DIR` | `<repo>/logs` | 日志目录 |
| `MOCK_TOOL_PATH` | `mock-tool-output.txt` | 脚本让 agent 写的文件路径（相对 agent 工作区） |

## 日志

三个文件，分工明确：

**`logs/mock-requests.jsonl`** — 每个请求一行，回复结束后追加。关键字段：

- `request`：请求序号；`t`：时间戳
- `model`、`stream`、`messageCount`、`roles`
- `hasTools`、`toolNames`：这次请求带了哪些工具
- `toolResultCount`：**当前是第几步的依据**
- `script`、`scriptKind`、`step`：本次回了哪种脚本、走到第几步
- `selection`：为什么选这个脚本——命中的关键词、在 `messages[i]`、以及 step 的判定理由
- `responseChunks`、`responseBytes`、`streamDurationMs`、`chunkLabels`：回了多少块、多少字节、用了多久
- `requestBody`：**完整请求体 JSON**（注意字段名是 `requestBody` 不是 `request`——`request` 是这条记录的序号）

**`logs/mock-stream.jsonl`** — 每个 SSE 事件一行：`request` 序号、`chunk` 块序号、`label`（这块是什么）、`bytes` 字节数、`elapsedMs` 距请求开始的毫秒数。这份是"流式是真的"的原始证据。

**`logs/mock-server.log`** — 服务端自己的运行日志（启动、每个请求一行摘要、错误）。

## 实测

两条路径都跑通了，证据在 `logs/`。

**服务端自测**（`scripts/mock-selftest.sh`，产物 `logs/mock-selftest.log`）：14 组 wire 级检查加一组 pi-ai 解析检查，全 PASS。关键数字来自 `mock-stream.jsonl`：

```
chunk  1  +   0ms   203B  role
chunk  2  + 121ms   205B  content[0]
chunk  3  + 243ms   232B  content[1]
...
chunk 13  +1454ms   203B  content[11]
chunk 14  +1575ms   174B  finish:stop
chunk 15  +1575ms   199B  usage
chunk 16  +1695ms    14B  done
inter-chunk gaps (ms): 122, 121, 121, 122, 121, 122, 120, 121, 120, 122, 120, 122, 121, 0, 120
```

工具三轮的判定记录：

```
#3 toolResults=0 -> script=tool-step1-write      step=1  finish=tool_calls
#4 toolResults=1 -> script=tool-step2-read-glob  step=2  finish=tool_calls
#5 toolResults=3 -> script=tool-step3-final-text step=3  finish=stop
```

**DSH 自己的客户端解析**（`mock/verify-with-pi-ai.mjs`）：直接 import `ios-port-A/install` 里那份 `@earendil-works/pi-ai/dist/api/openai-completions.js`——也就是 `@deepseek-ai/dsh-llm-pi-ai` 实际调用的模块——喂它我的回复。文本流解析出 12 个 `text_delta`、`done reason: stop`；第一步解析出 `toolcall_start: 1` / `toolcall_delta: 8` / `write` 的参数合法；第二步解析出 `read` + `glob` 两个调用；最终轮解析出文本且 `stop`。

**模拟器内可达性**（`scripts/mock-reachability.sh`，产物 `logs/mock-reachability.log`）：一个编译给 `arm64-apple-ios18.0-simulator` 的 Swift 探针，用 `simctl spawn` 在模拟器里跑，访问 `127.0.0.1:19700`。

```
HTTP status             : 200
delegate data callbacks : 15
content delta events    : 12
inter-event gap         : min 113ms, max 133ms
text reassembled        : "...流式验证结束。STREAMTEST-COMPLETE"
```

15 个 delegate 回调相隔 113–133ms，说明模拟器与宿主机共享 loopback **且**流式在模拟器里也是逐块到达的，不是一次性 blob。这一条是"App 里 DSH 能不能连上"的前提，所以单独测了。

## 已知边界

- 回复内容是写死的脚本，不是真模型。它只验证链路，不验证模型能力。
- 没做 token 计数（`usage` 按字符数粗估），只为了让 DSH 的用量字段有值。
- 没实现 `tools` 的 `strict` 语义、没实现 function call 之外的任何 OpenAI 特性（`logprobs`、`n`、多 choice 等）。
- 脚本选择依赖关键词。真模型不会这样，所以这个服务只适合做端到端测试，不能当通用 mock。
- `MOCK_CHUNK_DELAY_MS=0` 时流式证据会退化：块还是分开写的，但到达时间挤在一起，从日志上无法区分"逐块"和"一次拼好"。报告里引用的证据都是默认 120ms 跑出来的。
