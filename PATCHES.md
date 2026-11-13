# 对 DSH 内部的改动登记

本文件登记**所有**对 vendored DSH 的改动，包括第 1 单之前就存在、第 2 单开场时补登的那些。

当前基座：`@deepseek-ai/dsh` 与 agent-team profile 均为 `0.2.1-rc.5`。本次升级及实物比对见末尾“rc.5 升级”节。

登记的目的很具体：DSH 官方说插件 API 会趋于稳定，但**内部实现不承诺**。一旦升级 DSH，本文件里每一条都要重新判定"还成不成立"。没有本文件，升级后只能靠症状去猜。

## 判定原则

新功能优先做成**独立插件或服务提供者**（在 profile 里替换 provider），不改 DSH 内部代码。只有做不到时才改内部代码，并且必须在这里登记三件事：

1. 改了哪个包的哪个文件、哪一行；
2. 为什么不能用插件实现；
3. DSH 升级后怎么检查它是否还成立。

---

## 一、第 2 单之前就存在的改动（补登）

### P-1 `@deepseek-ai/dsh-app-boot` — `requireInternal` 走 `--expose-internals`

| 项 | 内容 |
|---|---|
| 文件 | `payload/node_modules/@deepseek-ai/dsh-app-boot/lib/index.js` |
| 位置 | `internalModules()`，第 1781 行起（`ios-port-A minimal patch` 注释块） |
| 改动 | 在 `internalModules()` 里加了一个 `requireInternal(id)`：当 `process.execArgv` 含 `--expose-internals` 时用普通 `require(id)` 取 Node 内部模块，失败再退回 `node-addon-require-builtin` 原生扩展 |
| 改动量 | 新增约 5 行（`createRequire` + 5 次 `requireInternal(...)` 调用替换 5 次 `addon.requireBuiltin(...)`） |
| 来源 | 从 ios-port-A 阶段继承，随 `8996669 Start from the ios-port-C app scaffolding` 进入本仓库。**不是本单新增** |

**为什么不能用插件实现**：这段代码取的是 Node **自身的模块加载器内部对象**（`internal/modules/esm/loader` 等），调用者是 `dsh-app-boot` 自己的 profile 解析流程，在插件被加载**之前**就要跑。插件此时还不存在，无法接管。而 `node-addon-require-builtin` 是原生扩展，iOS 上不能加载（App 里 `childProcessBlocked` / `addonLoadingBlocked` 都为 true，见运行时报告），所以在 iOS 上这条 fallback 是死路，必须走 `--expose-internals`。

**对应的启动参数**：`app/DSHPortC/NodeRunner.swift` 的 `makeArgv()` 固定传 `--expose-internals`，注释写明"不是可选的"。这两处是一对，改一处必须改另一处。

**DSH 升级后怎么检查**：

```bash
# 1. 这段 patch 还在不在（在 = 需要重新核对；不在 = 上游可能已内置）
grep -n "ios-port-A minimal patch" payload/node_modules/@deepseek-ai/dsh-app-boot/lib/index.js

# 2. 上游是否已自带等价逻辑（含 --expose-internals 分支）
grep -n "expose-internals" payload/node_modules/@deepseek-ai/dsh-app-boot/lib/index.js

# 3. 内部模块的模块名是否还叫这些（名字变了 patch 会静默走 fallback，然后失败）
grep -n 'requireInternal("internal/' payload/node_modules/@deepseek-ai/dsh-app-boot/lib/index.js

# 4. 端到端：App 冷启动后 web 界面能不能建会话（这是这条 patch 的直接症状）
```

**已知的同源未改点**：`dsh-app-boot` 的 **worker** 版本 `lib/worker/profile-resolution-bootstrap.js` 第 565–569 行**仍然只走** `addon.requireBuiltin(...)`，没有 `--expose-internals` 分支。本仓库没有启用 worker 路径（profile 里 `ptc-runtime`/子代理/worker 相关行是关掉的，见 `profiles/ios-sim/cordis.patch.yml`），所以没改它。**如果第 5 步之后要启用 worker，这里会立刻失败**，届时需要照 P-1 的形状再补一处。

---

### P-2 `@deepseek-ai/cordis-plugin-loader` — 上游自带的 `requireInternal`（原登记更正）

| 项 | 内容 |
|---|---|
| 文件 | `payload/node_modules/@deepseek-ai/cordis-plugin-loader/lib/index.js` |
| 位置 | 第 9–18 行，`ModuleLoader.requireInternal` |
| 实际归属 | 上游自带，与干净 rc.2 逐字节一致；rc.5 继续自带，不重打本地补丁 |
| 来源 | rc.2 与 rc.5 的上游发布代码，本次撤销本地补丁归属 |

**为什么不能用插件实现**：这是 `cordis-plugin-loader` 在**定位 Node 的模块加载器**，它本身就是"加载插件"的那个组件，插件机制还没起来。鸡生蛋问题，无法用插件解决。

**DSH 升级后怎么检查**：核对上游的分支和内部模块调用，不查 P-1 独有的本地标记。

```bash
grep -n 'requireInternal\|expose-internals\|requireBuiltin' payload/node_modules/@deepseek-ai/cordis-plugin-loader/lib/index.js
```

这与 P-1 属于不同包，升级后仍需分别检查。

---

### P-3 `@deepseek-ai/dsh-hmr` — 上游自带的 `requireInternal`（原登记更正）

| 项 | 内容 |
|---|---|
| 文件 | `payload/node_modules/@deepseek-ai/dsh-hmr/lib/index.js` |
| 位置 | 第 172–189 行 |
| 实际归属 | 上游自带，与干净 rc.2 逐字节一致；rc.5 继续自带，不重打本地补丁。缺参数时仍抛 `--expose-internals is required for HMR service` |
| 来源 | rc.2 与 rc.5 的上游发布代码，本次撤销本地补丁归属 |

**为什么不能用插件实现**：HMR 服务要拿 `internal/bootstrap/realm` 和模块图，这是加载器内部状态。

**DSH 升级后怎么检查**：核对上游内部模块分支及缺参数时的显式错误。

```bash
grep -n 'requireInternal\|expose-internals\|requireBuiltin' payload/node_modules/@deepseek-ai/dsh-hmr/lib/index.js
```

如果 HMR 报 `--expose-internals is required for HMR service`，应检查启动参数。

---

### P-4 无 ICU 的 Unicode 属性转义重写（**脚本化、可重放**）

这一条**不是**手工改 DSH 源码，而是每次构建时由脚本重写 payload。性质与 P-1 不同，但同样改的是 DSH 的发布文件，所以登记。

| 项 | 内容 |
|---|---|
| 脚本 | `scripts/patch-payload-i18n.py`（被 `scripts/build-app.sh` 每次构建调用） |
| 影响文件 | 6 个：原 4 个 `@deepseek-ai/dsh-tools/lib/index.js`、`@deepseek-ai/dsh-tools/lib/types/py-types.js`、`@deepseek-ai/dsh-llm-deepseek/lib/index.js`、`@js-temporal/polyfill/dist/index.esm.js`；rc.5 新增 `@earendil-works/pi-schema/dist/formats/typebox/idn_email.js` 与 `idna/pattern/pattern.js` |
| 改动 | 把 `\p{XID_Start}` / `\p{XID_Continue}` / `\p{L}` / `\p{N}` 这些**正则字面量**里的 Unicode 属性转义，换成显式的字符类区间 |
| 记录 | 每次运行把逐条结果写进 `logs/i18n-patch.json`；原件备份在 `work/i18n-patch-backup/` |
| 来源 | 继承（ios-port-C 阶段），**不是本单新增** |

**为什么不能用插件实现**：`nodejs-mobile v24.5.0` 的 iOS 切片是 `v8_enable_i18n_support=0` 构建的，`\p{...}` 在**语法解析阶段**就抛错（不是运行时）。这些是模块顶层的正则**字面量**，模块根本加载不起来，插件没有机会介入——插件本身就是 module。

**原 4 文件仍使用近似范围；新增 2 文件使用精确表**：`pi-schema` 的 16 种属性按宿主 Node 的 Unicode 16.0 生成静态区间，保留分组、量词和 `u`/`i` 标志；`node scripts/unicode-property-unit.mjs` 对每种属性遍历全部 1,114,112 个码点，并验证 8 个 IDN 格式用例。设备上的 NFC 归一化仍受现有运行时 shim 限制，本补丁不补齐它。

**原有近似的边界**：`XID_Start`/`XID_Continue` 被换成一个覆盖面较宽的区间表，不是精确的 Unicode 表。未列出的文字（如格鲁吉亚文、埃塞俄比亚文）会被当作非标识符字符。受影响的代码路径是 PTC 运行时（本 profile 已禁用）的 Python 标识符命名、DeepSeek provider 的一处文件 id 词边界检查、js-temporal 的年号清洗——都不在聊天和文件工具路径上。

**DSH 升级后怎么检查**：

```bash
# 1. 脚本还认不认得上游文件（认不出会记 pattern_not_found）
python3 scripts/patch-payload-i18n.py | head -5
python3 -c "import json;d=json.load(open('logs/i18n-patch.json'));print([r for r in d['records'] if r['status'] not in ('already_patched','patched')])"

# 2. 有没有新增的 \p{...} 字面量（新包或新版本会引入新的）
grep -rn '\\p{' payload/node_modules --include=*.js | grep -v '/deps/' | head

# 3. 运行时验证：payload 的入口模块能不能加载
```

**注意**：`grep` 命中的不一定是问题——正则字面量才是致命的，字符串里的 `\p{` 无害。第 2 条要人看。

---

## 二、第 2 单新增的改动

### P-5 iSH 内核：静态 bind mount 的 `stat()` 漏 `st_dev`

**这一条改的是 iSH，不是 DSH**，但同样登记，因为它决定了第 5 步的路由逻辑。

| 项 | 内容 |
|---|---|
| 文件 | `ish/src/ish-arm64/fs/fake.c` |
| 位置 | `fakefs_stat()` 的**静态 bind mount 分支**（`bind_mount_translate_path(...)` 为真、`via_hook` 为负的那一支），约第 822–846 行 |
| 改动 | 补 `fake_stat->dev = dev_fake_from_real(real_stat.st_dev)`，并补 `blksize`/`blocks`/`nsec` 时间字段 |
| 形态 | `ish/patches/0002-bind-mount-stat-dev.patch`，由 `ish/scripts/fetch-sources.sh` 重放；`--check` 可验证 |
| 本单新增 | **是** |

**问题是什么**：`generic_statat()` 在调 `mount->fs->stat()` 前 `memset(stat, 0, ...)`。hook 分支会补 `dev`（第 359a268d 那个修复），**静态表分支没有补**——它只拷 size/nlink/时间，`dev` 留在 0。而 `fakefs_fstat()` 走 `realfs.fstat` → `copy_stat()`，那条路**总是**把 `dev` 设成 `dev_fake_from_real(host_stat.st_dev)`。

于是同一个文件：`stat()` 报 `dev=0`，`fstat()` 报 `dev=269`。coreutils 的 `psame_inode()` 比完 inode 比 dev，dev 不一致就判定"文件在拷贝过程中被换掉了"，`cp` 放弃：

```
cp: skipping file 'src/sub/b.txt', as it was replaced while being copied
```

**这与第 1 单 §5.3 的关系**：第 1 单记录"`359a268d` 一次都没被压到"，并预测第 4 步的 bind mount 会压到。**实测结果是：压到了，但 359a268d 修的是 hook 分支，而 `fakefs_bind_mount()` 走的是静态表分支**——所以第 1 单的修复没有覆盖到这一步，需要这第 5 条补丁。这是"第 1 单遗留要求"的答案：`cp -a` 在 bind mount 上**原来确实失败**，补 `dev` 后**通过**。

**为什么不能用插件实现**：这是内核 syscall 返回的 struct 字段，插件层看不到 `statbuf`。

**DSH 升级后怎么检查**：iSH 与 DSH 是两个独立上游。iSH 升级时：

```bash
# 1. 补丁还打得上吗（打不上会硬失败，不会静默跳过）
ish/scripts/fetch-sources.sh --check
# 2. 上游是否已自带等价修复（有就删掉本补丁）
grep -n 'fake_stat->dev = dev_fake_from_real' ish/src/ish-arm64/fs/fake.c
# 3. 行为验证（最可靠）：在 bind mount 上跑 cp -a，看有没有 "replaced while being copied"
./scripts/channel-acceptance.sh   # cp_a_bind 必须为 true
```

---

## 三、本单新增功能：插件形式的落点

本单的 Node 侧通道客户端 `sim/guest-channel-client.mjs` **还没有**做成插件，原因写在下面；第 5 步会把它包成插件。这里先说明接法，免得第 5 步重新发现。

**它是什么**：一个纯 ESM 模块，导出 `exec()` / `resolve()` / `health()` / `channelConfig()` / `redact()`。不含 cordis 依赖，不注册任何服务——**故意如此**，因为它现在只被验收脚本用。

**第 5 步怎么接成插件**（已核对 `dsh-bash-local` 的真实形状）：

- 目标不是新增一个工具，而是**替换 `subprocess` 这个 capability seam 的实现**。`dsh-bash-local` 的 `LocalBashExecutor extends ShellExecutor`，`static inject = ["subprocess"]`，通过 `ctx.subprocess.spawn(...)` 执行；所以第 5 步要写的是 `SubprocessRuntime` 的实现（`spawn` 等），不是 bash executor。
- profile 的接法：`profiles/ios-sim/cordis.patch.yml` 现在把 `subprocess`、`bash-sandbox`、`tool-bash` 都 `disabled: true`。第 5 步要改成挂一个自有的 subprocess provider 行，并把 `tool-bash` 重新打开；**`shell-env` 必须保持挂着**（profile 里已有注释说明这个坑）。
- 依赖方向：`dsh-bash-local` 与 `dsh-subprocess` 是 peerDependency，插件只需要提供 `ctx.subprocess`，**不需要改 `dsh-bash-local` 的任何一行**。这是"优先插件"能够成立的关键，已从源码确认。

**为什么本单没直接做成插件**：第 3、4 步的验收对象是**通道本身**（能不能流式、鉴权、端口重试），不是"模型能不能用 bash"。真正的 provider 是第 5 步的范围。现在把它硬包成 `ctx.subprocess` 实现，等于提前写第 5 步且无法验收。模块的接口形状（`exec` 返回聚合结果 + `onChunk` 回调）已按 provider 的需要设计。

---

## 四、这张表怎么用

升级 DSH 时，逐条跑上面的检查命令。任何一条的"检查"不再通过，就是必须重新处理的地方，**不要**因为"界面上看起来还好"就跳过——P-4 那类问题在模块解析阶段炸，症状出现在很远的地方。

本文件与 `REPORT-1.md` §10.3 记录的那次范围违规（脚本硬编码路径回写 ios-port-C）是两件事：那条已修好，不是遗留改动。

---

## 五、第 3 单新增的改动

**这一节只有两条，而且都不是"改 DSH 源码"。** 第 3 单的 provider 是插件，profile 是配置，没有一行 DSH 内部代码被改。下面两条是**对 DSH 行为的发现**——它们不影响"改了什么"，但决定升级后必须核对什么，性质与 P-1..P-5 的"改动"不同，单独列出以免混淆。

### P-6 `dsh-subprocess-ish`：为什么是插件而不是补丁（以及升级后怎么验）

| 项 | 内容 |
|---|---|
| 落点 | `plugins/dsh-subprocess-ish/`（`index.mjs` + `lib/guest-channel.mjs`） |
| 接入 | `profiles/ios-sim/cordis.patch.yml`：`subprocess` 行 `disabled: true`，另 `insert` 一行 `subprocess-ish` |
| 改动 DSH 源码 | **零行** |
| 证据 | `git diff` 对 `payload/` 为 0 个文件 |

**为什么插件可以做到**：`dsh-bash-local` 的 `LocalBashExecutor extends ShellExecutor`，只声明 `static inject = ["subprocess"]`，执行时调 `this.ctx.subprocess.spawn(...)`。`ctx.subprocess` 是 cordis **服务**，不是 import。所以替换"提供这个服务的那一行"，就把执行世界换掉了，`dsh-bash-local`、`dsh-tool-bash`、`dsh-workspace-changes` 一行都不用改。这是本单"源码零改动"验收的结构性依据。

**升级后怎么检查**（四条，任何一条变了都要重新判定）：

```bash
# 1. bash-local 还是只 inject subprocess、还是调 ctx.subprocess.spawn
grep -n 'static inject' payload/node_modules/@deepseek-ai/dsh-bash-local/lib/index.js
grep -n 'ctx.subprocess.spawn' payload/node_modules/@deepseek-ai/dsh-bash-local/lib/index.js

# 2. spawn 的入参形状没变（collect 模式 + spill）
grep -n 'maxBytes\|spill' payload/node_modules/@deepseek-ai/dsh-bash-local/lib/index.js | head

# 3. 它还是派 'bash -c' 而不是绝对路径（本单要解析 argv[0]，见报告）
grep -n '"bash"' payload/node_modules/@deepseek-ai/dsh-bash-local/lib/index.js

# 4. OutputCollector 的导出路径还在（provider 直接 import 它）
node -e "console.log(require.resolve('@deepseek-ai/dsh-subprocess-local/output'))" \
  --input-type=commonjs 2>/dev/null || \
  grep -n '"./output"' payload/node_modules/@deepseek-ai/dsh-subprocess-local/package.json
```

### P-7 profile patch 的 `name` 语义（**这不是改动，是升级后必须重验的行为**）

**这一条是本单踩到的最贵的坑，写在这里因为它在 DSH 升级时可能变。**

一个 patch 行如果写了 `name`，而它的值与**被 patch 的那一行原本的 `name` 不同**，这一行会被**整行跳过**，只在 stderr 留一句 `patch: name mismatch for "X" (expected "A", got "B"), skipping`：

```
payload/node_modules/@deepseek-ai/dsh-app-boot/lib/index.js:100-103
if (name && name !== target.name) {
    warn("patch: name mismatch for %C (expected %C, got %C), skipping", id, target.name, name);
    continue;
}
```

**它为什么难发现**：警告走 stderr，而 App 里的 Node 只把 stdout 转发到启动日志，profile 文件本身看起来完全正确。表现出来的是"provider 挂上了但行为不对"——具体到本单，是 stock `dsh-subprocess-local` 仍在提供服务，于是每个 bash 命令都走宿主 `child_process`（被 preload 拦成抛错），模型看到的是命令失败，而不是"provider 没装上"。

**正确的写法**（本单已改成这个形状）：

```yaml
- id: subprocess
  disabled: true            # 只给 id，无 name → 按 id 找到并禁用原行
- insert:                   # 新行单独 insert，自己带 name
    - id: subprocess-ish
      name: __PLUGINS__/dsh-subprocess-ish/index.mjs
```

**升级后怎么检查**：

```bash
# 1. provider 真的装上了（不是被跳过）
DSH_HOME=… node --expose-internals payload/node_modules/@deepseek-ai/dsh/lib/bin.js \
  --profile ios-sim --dump-config 2>&1 >/dev/null | grep 'name mismatch'
# 期望：没有任何一条 name mismatch

# 2. 组合结果里 subprocess 是被禁用的 stock 行 + 我们 insert 的行
DSH_HOME=… node … --dump-config | grep -A2 'id: subprocess'

# 3. 上面那段 skip 逻辑还在不在（在 = 语义没变）
grep -n 'name mismatch' payload/node_modules/@deepseek-ai/dsh-app-boot/lib/index.js
```

**另一条相关的**：patch 里 `insert` 的 `id` 是**自己的**，不是被替换行的 id。两者同名会撞车（原行还在，只是 disabled），所以本单用的是 `subprocess-ish` / `sandbox-ios` 这样的新 id。

## 六、第 4 单 B 段新增

### P-8 App 外壳：容器路径迁移与旧会话隔离（**不改 DSH 内部代码**）

| 项 | 内容 |
|---|---|
| 文件 | `app/DSHPortC/NodeRunner.swift` 的 `migrateStaleContainerPaths()`，在 `prepareFilesystem()` 里、Node 启动前调用 |
| 症状 1 | 覆盖安装后数据容器 UUID 变了，DSH_HOME 被带进新容器，`storages/workspace.json` 里的工作区绝对路径仍指向旧容器。新建会话报 `failed to ensure project directory ... EPERM: operation not permitted, mkdir '/private/var/mobile/Containers/Data/Application/<旧UUID>'` |
| 症状 2 | 每个会话日志（`sessions/<路径编码>/…/session.v4.jsonl.zstd`）的头部记录了项目路径，且在 zstd 里，无法改写。头部与目录不一致时 DSH 报 `corrupt session log`，`workspaceRegistry` 起不来，`session-controller`、`workspace-controller` 都卡在 pending，目录选择器报 `directoryPickerController is unavailable`。我第一版只改了路径并给目录改名，反而制造了这个症状 |
| 做法 | 在 `DSH/.container-root` 记录上次的容器根。与本次不同（或不存在）时：改写 `storages/**/*.json` 里的容器前缀；把 `sessions/*` 与 `storages/session_projcache` 整体移到 `DSH/sessions-quarantine/<时间戳>/`（不删除）；把 `workspace.json` 里的 `sessionIds`、已归档/置顶列表清空；写入新标记。容器不变时什么都不做。不打开 `.credentials.yaml` |
| 代价 | 容器变化前的会话不再出现在列表里（文件保留在 quarantine 里，可手动取回）。工作区本身（default-workspace）保留 |
| 为什么不用插件 | 要在 DSH 读取这些文件之前改 |
| 升级后检查 | DSH 若改了存储位置、会话目录编码或会话头部内容，这里要跟着改；跑 `scripts/sim-stale-container-test.sh` 复验 |

### P-9 插件 `dsh-directory-picker-ios`：目录选择器后端，限制在 App 工作区内

| 项 | 内容 |
|---|---|
| 文件 | `plugins/dsh-directory-picker-ios/index.mjs`；profile 里 `directory-picker-browse` 一行改用它 |
| 做法 | 继承 DSH 自带的 browse 后端（纯 `node:fs`），只加根目录限制：默认从 `DSH_IOS_WORKSPACE` 开始；根之外的路径返回 `directory-unreadable`；面包屑从根开始；新建文件夹只允许在根内 |
| 为什么 | 原后端从 `os.homedir()` 列整个文件系统，手机上没意义，还会诱导登记沙盒不允许的路径 |
| 升级后检查 | 若 `dsh-host-directory-picker-browse` 的 `list`/`createDirectory` 签名或返回结构变化，这里要同步；验收脚本里的 `directory_picker` 判据会失败 |

---

## 七、第 5 单新增：图片管线换成 iOS 原生接口

本单的目标是"App 里能发图"。结构上的做法与 P-6 相同：**服务接缝换成插件**，DSH 源码不动。但有一处例外（P-11），它改的是 RPC 边界的类型声明，必须登记。

### P-10 插件 `dsh-attachment-ios` + 原生 `ISHImageService`（**不改 DSH 内部代码**）

| 项 | 内容 |
|---|---|
| 落点 | `plugins/dsh-attachment-ios/`（`index.mjs` + `lib/native-image.mjs`）；`app/DSHPortC/ISHImageService.{h,m}`；`ISHGuestChannel.m` 新增 `POST /v1/image/probe`、`POST /v1/image/encode` |
| 接法 | profile：`attachment-local` 行 `disabled: true`，`insert` 一行 `attachment-ios`，并**显式钉住** `dshHome: __DSH_HOME__` |
| 改动 DSH 源码 | **零行**（`git diff payload/` 只显示 P-11 那一处类型声明） |
| 证据 | `git diff --stat payload/` 只列出 `dsh-client-ui-conversation`、`dsh-tool-fs`、三个包的 `typert.*.js`（全属 P-11） |

**为什么插件可以做到**：`ctx.attachments` 是 cordis 服务。所有消费者（prompt 准入、`read_image`、`fileUploads`、给浏览器用的 `imageLimits` 投影）都只跟服务说话，不跟包说话。子类 `IosAttachmentStore extends LocalAttachmentStore`，只覆盖 5 个原本走 `sharp` 的行为：

1. `detectImage` — 全解码 + 格式/尺寸/alpha/位深/色彩空间事实 + 像素与单边准入限制
2. `probeImage` — 只读头部取同一批事实（校验已存对象时用）
3. `normalizeImage` — 定向、转 8-bit sRGB、按像素预算与长边上限缩小、85/75/60 质量梯、再校验
4. `createRequestImage` / `requestVersion` — 每个模型路由的请求版本（按长边缩放 + 字节上限）
5. `verifyNormalizedImage` — 把刚产出的字节再解析一遍，不符就拒

其余全部继承：内容寻址、暂存写、fsync 纪律、只读对象权限、EEXIST 去重、逐字节文件存储、请求图缓存。所以它不可能偏离 DSH 的持久化规则。

**原生侧**：ImageIO + CoreGraphics，跑在 `ISHImageService` 自己的串行队列上。三个要点：
- 先读头部判限，**再**解码。一个 1 亿像素的 HEIC 若先解码后拒绝，那不是报错而是一次 jetsam。
- 用 `CGImageSourceCreateThumbnailAtIndex` 在解码时降采样，全分辨率栅格从不进内存。
- 输出走全新 8-bit sRGB 位图上下文，只拷像素，所以 EXIF/GPS/XMP/IPTC/ICC 没有任何来源可继承。
- **不实现 WebP 编码**：iOS 的 ImageIO 能解 WebP 但不能编。带 alpha 的源改用 PNG（无损且保留透明），所以线上会看到 `image/png` 而 sharp 会给 `image/webp`；存储契约（8-bit sRGB、alpha 保留）一致。

**为什么钉住 `dshHome`**：`LocalAttachmentStore` 的解析顺序是 `config.dshHome` → `$DSH_HOME` → `~/.dsh`。基线那一行没有 `dshHome`，靠环境变量兜底。这在桌面上正确，在 App 里是隐患：环境一旦丢失，它会在用户的桌面端 DSH 目录里建 `attachments/` 并写进用户的照片。现在 profile 显式传 `__DSH_HOME__`（App 容器路径，每次启动由 Swift 替换），插件在没有 `dshHome` 时**拒绝挂载**，并在挂载时打印 `objects=<路径>`。实测该行现在是 App 容器内的路径。

**踩到的坑（值得记下来）**：插件内部的辅助方法**不能用 `#private`**。cordis 的 `Service` 会把实例包成 Proxy / 用 `Object.create(this)` 派生，而 JS 的 `#name` 要求接收者是真正的实例，不满足就抛 `TypeError: Receiver must be an instance of class IosAttachmentStore`。这个异常被 `api-session-controller` 的兜底 catch 变成 `session/agent-busy` / "prompt rejected"，完全看不出跟类有关。现在全部改成 `_` 前缀的普通方法，文件顶部有注释说明不要改回去。

**升级后检查**：

```bash
# 1. 基类还是五个 sharp 点，且方法名未变（变了要同步覆盖）
grep -n 'requireSharp()' payload/node_modules/@deepseek-ai/dsh-attachment-local/lib/index.js
# 2. 基类仍然接受 dshHome 配置并同样解析
grep -n 'resolveDshHome(config.dshHome)' payload/node_modules/@deepseek-ai/dsh-attachment-local/lib/index.js
# 3. 请求缓存的身份函数仍导出（缓存键必须与 sharp 版一致）
grep -n 'requestImageVariantId' payload/node_modules/@deepseek-ai/dsh-attachment-local/lib/index.js
# 4. Service 的构造与 Proxy 派生方式若变了，重新评估"不要用 #private"这条
# 5. 端到端：scripts/image-acceptance.py run ...（三张图必须到达 mock）
```

### P-11 HEIC 进入"图片"的四个边界（**这一条改了 DSH 内部代码**）

| 项 | 内容 |
|---|---|
| 脚本 | `scripts/patch-payload-heic-media-type.py`（幂等，已接进 `build-app.sh` / `build-device.sh`，原始文件备份在 `work/heic-media-type-backup/`） |
| 症状 | 存储层已能解 HEIC（P-10 把 `image/heic`/`image/heif` 加进可接受**源**类型），但浏览器把它当普通文件：`session/prompt` 回 `typert gateway: session/prompt: wire field "request" failed boundary validation (gateway/input-invalid)`，用户只看到一句无效失败 |
| 改了什么 | ① 前端 composer 的两处类型判定（`imageMediaType`/`isImageMediaType`）；② **RPC 入参的 zod schema**（`session/prompt`、`commands`、`subagent` 三个包的 host 与 remote-client）；③ `read_image` 的扩展名表 |
| 为什么不能用插件 | 这些是模块私有函数与生成的 zod schema，没有服务接缝、没有导出符号、没有客户端插件能替换的 slot。①在一个压缩过的客户端 bundle 里被 composer 直接调用；②是每个 RPC 的**运行时**校验器。用客户端插件重写整个 composer 比这两行改动大得多也脆得多 |

**关键的诊断教训**：只改 JSON Schema 镜像**没有任何效果**。真正执行校验的是 `typert.host.js` 里生成的 zod：网关走 `codec.mode === 'strict'` → `codec.create().parse(value)`。第一次补丁装进 bundle 后请求仍被拒，正是这个原因。

**故意没有放宽的地方**：`ImageAttachmentRef.mediaType`（存储引用的**输出**枚举）保持四种。存储对象永远是被重新编码过的 JPEG/PNG，所以那个枚举描述的是事实；放宽它会变成谎报。`imageLimits.mediaTypes`（能力**报告**）则必须放宽，否则浏览器又会把 HEIC 挡回去。

**升级后检查**：

```bash
python3 scripts/patch-payload-heic-media-type.py    # 任何 pattern_not_found 都要人工判定
# 2a. prompt 入参的 zod 已放宽（这是真正执行校验的那层）：两处 image part 各一条
grep -A 2 "'type': z.literal(\"image\").readonly()," payload/node_modules/@deepseek-ai/dsh-api-session-controller/lib/typert.host.js \
  | grep -c 'z.literal("image/heic")'        # 期望 2

# 2b. 能力报告的 zod 也已放宽（否则浏览器又把 HEIC 挡回去）：该文件共 7 处宽版
grep -c 'z.literal("image/heic")' payload/node_modules/@deepseek-ai/dsh-api-session-controller/lib/typert.host.js   # 期望 7

# 2c. 检查实际入参 codec 和各 RPC 的输出 schema，区分输入/输出方向。
node scripts/heic-boundary-unit.mjs
# 期望：36 个输入检查（HEIC/HEIF 通过，SVG 拒绝），6 个存储输出校验、2 个枚举仍为四类。
# 原先全文件 grep 同时命中已放宽的输入，不能用它判定输出被误改。
```

### P-10b App 外壳：工作区注册表去重（`repairWorkspaceRegistry()`）与诊断插件

| 项 | 内容 |
|---|---|
| 文件 | `app/DSHPortC/NodeRunner.swift` 的 `repairWorkspaceRegistry()`；`plugins/dsh-diag-prompt/` |
| 症状 | 同一文件夹在 iOS 上有 `/var/…` 与 `/private/var/…` 两种写法，DSH 里可能各有一条记录；统一写法后碰撞，DSH 报 `workspace domain is inconsistent`，整个注册表不加载 |
| 做法 | 每次启动在 Node 前统一写法并合并同路径记录；不动其他存储。诊断插件只记录 prompt 失败的真实原因（不含请求内容），问题查清后应移除 |
| 升级后检查 | `storages/workspace.json` 的结构（`global.workspaceIds`、`defaultWorkspaceId`、`tables.workspaces[*].{path,sessionIds,createdAt}`）变了就要同步；`scripts/sim-dup-workspace-test.py` 复验 |

### P-11 预加载层 shim：对"容器以上的目录"做只读 open 遇到 EPERM 时当作成功（**不改 DSH 内部代码**）

| 项 | 内容 |
|---|---|
| 文件 | `sim/ios-sim-preload.cjs` 末尾的 `installAncestorOpenShim()`（在 `fs.promises.open` 外包一层，并 `syncBuiltinESMExports()`） |
| 症状 | 带图消息报 `session/agent-busy`，真实原因 `EPERM: operation not permitted, open '/var/mobile/Containers/Data/Application'` |
| 出处 | `payload/node_modules/@deepseek-ai/dsh-attachment-local/lib/index.js`：`ensureDurableHome`(402) → `ensureDurableDirectory(home, parse(home).root)`(381–394) → 对每一级祖先 `syncDirectory`(357) → `open(path, O_RDONLY)`。边界是文件系统根，不是 DSH_HOME。这些是模块私有函数，子类（`dsh-attachment-ios`）覆盖不到 |
| 做法 | 只对"本 App 容器的严格祖先目录"的只读 open：系统拒绝（EPERM/EACCES）时返回空操作句柄（`sync`/`close` 什么都不做）。容器之内的目录照常真 fsync；其他路径、其他错误完全不动 |
| 开关 | `IOS_SIM_ANCESTOR_SHIM=0` 关闭修复；`IOS_SIM_FAULT_ANCESTOR_OPEN=1` 让模拟器也对这些祖先目录返回 EPERM（复现手机上的失败） |
| 升级后检查 | 若 DSH 改了持久化目录链的边界或不再用 `fs.promises.open`，这个 shim 要重看；`scripts/sim-ancestor-eperm-test.sh` 三个用例复验 |

## 八、第 6 单新增：容器变化后保住会话 + 显示本地时区

**本单没有改动 DSH 内部代码。** `git status payload/` 为空可复核：所有落点都在
App 外壳（Swift）、`sim/` 下的启动层与 shim、`plugins/`、以及 profile。

### P-12 容器路径迁移：会话日志（zstd 头帧）与 storages 一起改写（**不改 DSH 内部代码**）

| 项 | 内容 |
|---|---|
| 文件 | `sim/session-migrate.mjs`（新）；由 `sim/ios-app-entry.mjs` 在 **import DSH 之前**调用；环境变量 `DSHPORTE_SESSION_MIGRATE` 由 `NodeRunner.swift` 每次启动设置 |
| 症状 | 覆盖安装后 iOS 换数据容器 UUID，DSH_HOME 跟着搬家，但会话日志头部（zstd 帧内）与 `storages/*.json` 里还是旧容器的绝对路径。DSH 的 `assertStoredIdentity` 判定"日志损坏"，而**一个坏日志会让整个工作区注册表不加载** —— 于是第 4B 单把所有会话移进 `sessions-quarantine/`，安全但用户每次更新都丢历史 |
| 做法 | 只改一个字段：解压头帧 → 把 `cwd` 指向当前容器 → 重新压成一个带校验的帧 → 后续事件帧原样拷贝 → 把会话目录移到修正后 cwd 对应的 project key。临时文件 + fsync + rename。任一会话失败只隔离那一个并写明原因；对旧版本隔离过的会话做一次性找回 |
| zstd 来源 | **Node 自带的 `zlib.zstdCompressSync` / `zstdDecompressSync`**（在模拟器内实测存在），不引原生扩展、不用纯 JS 实现 |
| 容器识别 | 不依赖"旧容器路径":头部 cwd 形如 `<container>/Documents/workspace/...`，设备与模拟器都含 `/Containers/Data/Application/<uuid>`，把 marker 之前的全部替换即可，因此跨任意代重装都成立 |
| 升级后检查 | 若 DSH 改了日志帧布局或 `projectKey()` 算法，迁移会写错目录 —— `scripts/session-migrate-unit.mjs` 与 `scripts/sim-container-sessions.py` 复验；`projectKey` 是 DSH 该函数的**拷贝**，升级后须逐字符对齐 |

### P-13 时区：Swift 发布设备时区表，`sim/intl-shim.cjs` 按表回答（**不改 DSH 内部代码**）

| 项 | 内容 |
|---|---|
| 文件 | `app/DSHPortC/DeviceTimeZone.swift`（新，`DSHPORTE_DEVICE_TZ` 环境变量）、`sim/intl-shim.cjs`、`profiles/ios-sim/cordis.patch.yml`（去掉 `timeZone: UTC`） |
| 症状 | 界面/模型时间固定 UTC，用户在 GMT+11 差 11 小时 |
| 真实落点（实测） | **页面时钟从来没被钉成 UTC** —— 页面跑在 WKWebView，有真 ICU，不经过 shim 也不读 profile 的 pin。被钉成 UTC 的是**宿主侧** `dsh-time-context` 给模型的时间戳：改前 `2026-10-28T09:28:37+00:00`，改后 `2026-10-28T20:28:37+11:00` |
| 做法 | Swift 每次启动发布 zone id、当前偏移、以及**前后一年到两年**的每个 DST 切换点；shim 用"某时刻的偏移"回答任意具名时区。无表时退回进程本地偏移并标注 `process-local`，超出表窗口标 `table-stale`，不假装 |
| 近似与边界 | 表覆盖约 -1y ~ +2y，窗口内精确（8 个悉尼切换点前后逐秒验证 8/8）；窗口外沿用最后的偏移；**只实现 `DateTimeFormat`**，`NumberFormat`/`Collator`/月份星期本地化等仍然缺失，故意留 undefined 让需要它的代码显式失败 |
| 升级后检查 | `node scripts/intl-shim-compare.mjs`（8 个时刻、带/不带显式 zone）、`node scripts/intl-callsite-audit.mjs`（真实调用点、两个季节）、以及在 App 内跑 `-DSHPortCTestTzProbe 1` |

### P-14 测试用的"继续一轮"验收门（**不改 DSH 内部代码，只加门控**）

| 项 | 内容 |
|---|---|
| 文件 | `sim/session-continue-acceptance.mjs`（新）、`sim/ios-app-entry.mjs` 的门控、`NodeRunner.forwardTestFlags()` 的两条转发 |
| 为什么需要 | 第 6 单验收 1 要求"旧会话能打开、能继续发一轮"。**这台设备做不到用浏览器点**：WKWebView 布局宽度 402px，低于 DSH 的 1024px 自动收起阈值，侧栏是 56px 竖条，会话行根本不进 DOM（实测：12 次点竖条开关，`data-sidebar-collapsed` 不变，`[data-row-key]` 始终为空，`session_pressed: no-session-row`）。**浏览器驱动发出的那一轮落在了新会话里**（`dsh.sessions.current` 是另一个 id），所以它不能作为这条验收的证据 |
| 做法 | 用真实 `ios-sim` profile 挂载，调 `sessionController.prompt`（UI 发送按钮最终到达的同一个服务）对**迁移后的那份日志**发一轮，然后断言：同一会话事件数增长、多一个 `turn/end`、原历史仍在、新提示词在日志里 |
| 顺序陷阱（实测一次） | 这个门必须在**flock 重定向注册之后**才 import。发一轮走的是写路径，要拿 flock，而 iOS 上 flock 原生插件被替换——放早了每次都是 `flock is not supported on ios-arm64` |
| 开关 | `-DSHPortCTestContinueSession 1` + `DSHPortCTestSessionId`；正常启动不进入 |

### P-10b 更新（第 6 单之后）：工作区去重必须最后执行，现在在 Node 迁移模块里做

| 项 | 内容 |
|---|---|
| 变化 | 第 6 单把路径改写和"从 sessions-quarantine 找回"移进了 `sim/session-migrate.mjs`（在 DSH import 之前由 Node 执行）。Swift 的 `repairWorkspaceRegistry()`（P-10b 原版）在 Node 迁移**之前**运行，看不到迁移和找回写进去的内容，所以它先合并、Node 随后又把两种写法改成同一路径，重复记录再次出现，DSH 报 `workspace domain is inconsistent`，整个注册表不加载 |
| 修复 | `session-migrate.mjs` 新增 `dedupeWorkspaceRegistry()`，在路径改写、会话迁移、隔离区找回、清理失效 id **全部完成之后**执行：`/private/var/` 归一为 `/var/`，同路径的多条记录合并到最早的一条（会话 id 取并集），修正 `workspaceIds`/`defaultWorkspaceId`。迁移本身失败时也会执行。Swift 的那一份保留作为第一遍，无害 |
| 复验 | `scripts/sim-dup-registry-test.py`（真实 `simctl install` 覆盖 + 隔离区里的旧会话 + 设备写法的重复记录）；`--bundle-module` 可替换成修复前的模块做对照 |

## 九、第 7 单新增：路径、ripgrep 与两个命名空间

**本单没有改动 DSH 内部代码。** `git status payload/` 为空可复核。五处新接缝，性质分三类：两个是**插件**（P-15、P-16 的 hook 侧），一个是**改 iSH 行为**（P-17），两个是**App 外壳**（P-18、P-19）。

### P-15 `dsh-fs-ios`：文件工具接受 guest 路径（**不改 DSH 内部代码**）

| 项 | 内容 |
|---|---|
| 文件 | `plugins/dsh-fs-ios/index.mjs`（新）；profile 里 `fs-sandbox` 行 `disabled: true` + `insert` 一行 `fs-ios` |
| 症状 | 同一个工作区有两个名字：宿主容器路径（UUID 每次覆盖安装都变）与 guest 的 `/workspace`。bash 在 guest 里，所以它打印和接受 `/workspace/...`；文件工具在 Node 里，只认宿主路径。于是 `read /workspace/x.md` 对着一份就在那儿的文件回 "not found" |
| 做法 | 继承 `@deepseek-ai/dsh-fs-sandbox` 的 `SandboxedFileSystem`，只覆盖**两个接收原始模型路径的方法**：`resolve()` 与 `lstat()`，把 guest 路径换算成宿主路径。策略围栏、原子写、edit 临界区、realpath 身份、diff basis 全部继承，未动 `dsh-tool-fs` / `dsh-fs-local` / `dsh-fs-sandbox` 一行 |
| 为什么是插件不是补丁 | `ctx.fs` 是 cordis 服务；消费者（prompt 准入、`read_image`、`fileUploads`、工作区文件浏览）只跟服务说话。与 P-6 / P-10 同一个结构性论证 |
| 为什么 `lstat` 要单独接 | 它自己拼 display path（`localDisplayPath`），不经过 `resolve`。只接 `resolve` 的话 `ls` 会列错目标而 `read` 正常——比全坏更难查 |
| 边界 | 只换算两个真实挂载点（工作区、`/tmp`）。挂载之外的路径原样传下去：硬改会把一个清楚的 ENOENT 换成错的答案 |
| prompt | 一句 `ios:path-namespaces`，order = `TOOL_BASH + 1`，经 `systemPrompt.assemble()` 实测拿得到原文。没有 bind mount 的启动不注册这句（那时只有一个文件系统，说了就是假话） |
| 升级后检查 | 若 `fs-sandbox` 的 `resolve`/`lstat` 签名或返回结构变了要同步；`scripts/step7-acceptance.sh` 的 `two_namespaces` 判据会失败 |

### P-16 ripgrep：把 `@vscode/ripgrep` 的 import 答成 guest 的二进制（**不改 DSH 内部代码**）

| 项 | 内容 |
|---|---|
| 文件 | `sim/ripgrep-hook.mjs`（新，ESM resolve hook）、`sim/ripgrep-guest.mjs`（新，被答成的模块）；`plugins/dsh-subprocess-ish` 新增 `respellGuestExecutable` / `_guestRipgrep`；`ish/scripts/build-rootfs.sh` 的包列表加 `ripgrep` |
| 症状 | `glob`/`grep` 报 `ripgrep launch failed`，guest 里 `command -v rg` 为空 |
| 两个独立原因 | ①`@vscode/ripgrep` 的二进制是 12 个按平台分的 **optionalDependency**，没有 `ios` 这一档，所以 `payload/node_modules/@vscode/ripgrep/` 是空目录；`dsh-tool-fs-search` 的 `resolveRgPath()` 在 **spawn 之前** import 它，失败被翻译成 "ripgrep launch failed"。②即使 rg 能跑，`grep` 仍搜 0 个文件（见 P-17） |
| 做法 | hook 把该 specifier 的 import 答成 `sim/ripgrep-guest.mjs`，它导出 `rgPath = /usr/bin/rg`（guest 路径）。provider 侧另加 `respellGuestExecutable`：任何**宿主路径**的 rg（`…/@vscode/ripgrep/bin/rg` 之类）也映射到 guest 的 `/usr/bin/rg`，作为防御——`payload` 若哪天装上了真的包，这条路也要对 |
| 为什么是 hook 不是补丁 | 那个 import 是模块私有函数里的动态 `import()`，没有服务接缝、没有导出符号、没有可子类化的点。hook 是 `sim/flock-hook.mjs` 已经在用的同一机制 |
| 为什么不塞一个假的 `node_modules/@vscode/ripgrep` | 它要导出的值不是常量：是 guest 的路径，只有 guest 起来之后才知道，而且真机上在每次安装都会变的容器里。静态包只能硬编码其中一个 |
| 开关 | `DSHPORTE_RG_HOOK=0` 关 hook（回到"包找不到"）；`DSHPORTE_RG_RESPELL=0` 关 respell |
| 升级后检查 | `grep -n 'import("@vscode/ripgrep")' payload/node_modules/@deepseek-ai/dsh-tool-fs-search/lib/index.js`（还在 = 这个 hook 仍必要）；`grep -n 'ripgrep' ish/scripts/build-rootfs.sh`；端到端跑 `scripts/step7-acceptance.sh` 的 `ripgrep` 判据 |

### P-17 iSH 客户端：没有 stdin 时 fd 0 用 `/dev/null`（**改的是 App 的 guest 驱动，不是 DSH**）

| 项 | 内容 |
|---|---|
| 文件 | `app/DSHPortC/ISHGuest.m`，exec 的 stdio 设置处 |
| 症状 | `glob` 能用、`grep` 不能用；`rg pattern`（不带路径）返回 0 命中 |
| 真实原因 | 原来无条件 `dup(inPipe[0])`——即使没有 stdin 数据，fd 0 也是**管道**。ripgrep 的启发式看到 `is_fifo=true`，判定"用户要搜 stdin"，于是读那个已关闭的管道、搜了 **0 个文件**、exit 1；`grep` 工具把 exit 1 + 空输出读成"无匹配"。`--files` 不碰 stdin，这正是两个工具行为不一致、原因看起来像目录遍历的缘故 |
| 改动 | 有 stdin 数据才 `dup(inPipe[0])`，否则 `open("/dev/null", O_RDONLY)`。带 stdin 的路径一行没改 |
| 实测 | 同一命令：管道 stdin → `searches=0, bytes_searched=0`, exit 1；`/dev/null` → 正常 `match`，exit 0 |
| 升级后检查 | 若 `ISHGuest` 的 exec stdio 逻辑重写，或换了 guest 驱动，这条要重看。验证：`rg -n <pattern>`（不带路径）在 guest 里必须命中 |

### P-18 App 外壳：路径归一改用 `realpath(3)`，消除项目键分裂（**不改 DSH 内部代码**）

| 项 | 内容 |
|---|---|
| 文件 | `app/DSHPortC/NodeRunner.swift` 新增 `realPath()`，用于 `sanitized()`；`app/DSHPortC/GuestWorkspaceCoordinator.swift` 的 `hostTemporaryPath` |
| 症状 | 同一文件夹在 DSH 里有两个 `projectKey()`：部分会话 `--private-var-…--`，其余 `--var-…--`。靠启动去重兜底 |
| 根因 | Foundation 的 `URL.resolvingSymlinksInPath()` **会抹掉 `/private` 前缀**（`/var/tmp` 原样返回），而 `realpath(3)` 与 Node 的 `fs.realpath` 都答 `/private/var/tmp`。App 发布的是 Foundation 那个写法，而 `dsh-workspace` 用 `fs.realpath` 归一注册表；`workspace-controller` 又把子目录**字符串拼接**到 `documentsDirectory` 上，于是新会话的 `cwd` 与注册表记录分裂成两个 key。去重只能事后合并，下一个新会话又把分裂造回来 |
| 改动 | 两处都改用 `realpath(3)`，与 Node 同一套。`realpath` 解析不了时（路径还不存在）才退回 Foundation |
| 实测 | `input /var/tmp` → `realpath(3)` 得 `/private/var/tmp`，Foundation 得 `/var/tmp`，二者不一致；改后 `published == realpath`，`projectKey` 两个来源的字符串**完全相同**，会话项目目录只有 **1** 个 |
| 升级后检查 | 若 DSH 改了 `projectKey()` 或会话目录编码，`sim/session-migrate.mjs` 里的拷贝要逐字符对齐（P-12 已记）；`scripts/sim-dup-registry-test.py` 复验 |

### P-19 provider：bash 的默认 cwd 与相对 workdir（**不改 DSH 内部代码**）

| 项 | 内容 |
|---|---|
| 文件 | `plugins/dsh-subprocess-ish/index.mjs` 的 `guestWorkingDirectory()` + 新增 `normaliseGuestPath()` |
| 症状 | bash 默认 cwd 比会话工作区高一层（`/workspace` vs `/workspace/deepseek-harness/default-workspace` 之类的相对路径全都找不到）；`workdir` 的相对路径被静默忽略 |
| 改动 | 没有 cwd → 返回**会话工作区**（不是 guest 根）;相对路径按会话工作区折叠，`..` 用 guest 的规则折（POSIX 语义，越过根夹在 `/`） |
| 为什么不用 `node:path` | provider 跑在宿主；`path.resolve` 用宿主的规则和宿主自己的 cwd。guest 路径必须用 guest 的规则折，否则 `workdir: "../other"` 会静默跑到宿主的父目录 |
| 实测 | 无 cwd / 宿主 cwd / guest cwd → `/workspace`；相对 `step7-acceptance` → `/workspace/step7-acceptance`；工具层拼接后的形态同样正确。`scripts/path-units.mjs` 21/21 |
| 升级后检查 | `scripts/path-units.mjs` 直接跑（纯函数，不需要 App）；`scripts/step7-acceptance.sh` 的 `bash_cwd` 判据 |

## 十、第 8 单新增：被 bash 删掉的文件不再是"死锁"

**本单没有改动 DSH 内部代码。** `git status payload/` 为空可复核。一处新接缝（P-20），性质是**插件里的 prompt 段**加一个 A/B 开关，另加两个宿主侧/Acceptance 工具（不碰 DSH）。

**结论先说**：手机上报的那个"死锁"在 DSH 里其实**已经有出口**——`read` 一个不存在的文件会先发出"确认不存在"，于是下一次 `write` 走"守卫式新建"而不是"按版本覆盖"。缺的只是没人告诉模型这一点。所以本单不改 DSH，只补一句 prompt，并用同一份构建开着/关着这句做了 A/B。

### P-20 `dsh-fs-ios` 增加 `ios:deleted-file-recovery` prompt 段（**不改 DSH 内部代码**）

| 项 | 内容 |
|---|---|
| 文件 | `plugins/dsh-fs-ios/index.mjs`（新增 `RECOVERY_SECTION`，order = `TOOL_EDIT + 1`）；`app/DSHPortC/NodeRunner.swift` 转发 `DSHPORTE_RECOVERY_NOTE` 与两个路径变量 |
| 症状 | 文件先由 `write` 创建 → bash 删除 → 再 `write` 被拒：`cannot write "…": file no longer exists — re-read the file, then retry`；`str_replace_editor create` 同样被拒（`…: file no longer exists`，没有后半句）。文件已不存在，所以"重新读一遍"看起来也不可能成功，形成假死锁，模型只能换文件名或改用 bash 写 |
| 报错出处 | `payload/node_modules/@deepseek-ai/dsh-fs-local/lib/index.js:869`（`FS_STALE_VERSION`）。工具层在 `dsh-tool-fs/lib/index.js:478` 给它追加 `— re-read the file, then retry`；`dsh-tool-str-replace-editor` 不做这层修饰，所以两个工具的措辞不同 |
| 真实状态机 | `dsh-tool-fs` 的 `resolveRegularReadTarget` 在抛 `FS_NOT_FOUND` **之前**先 `ctx.emit("fs/observed", target, {kind:"absent"}, exec)`（`dsh-tool-fs/lib/index.js:195`）；`dsh-fs-observation-policy` 的 `writeIntent` 把"已确认不存在"映射成 `{kind:"createIfAbsent"}`，只有"已确认存在"才给 `{kind:"replaceIfVersion", version}`。于是那次"失败"的 read 把陈旧的 `present@v1` 清成 `absent`，下一次 `write` 走守卫式新建并成功 |
| 是不是移植造成的 | **不是**。`dsh-fs-observation-policy`、`dsh-fs-local`、`dsh-tool-str-replace-editor` 三个包在 `dsh-dev/install` 与 `payload/` 之间**逐字节相同**（`cmp` 全 SAME）；`dsh-tool-fs` 的唯一差异是 P-11 的 `.heic/.heif`。桌面版走同一条路，同一句报错 |
| 为什么修在 prompt 而不是代码 | 机制本身是对的：先用版本卡住一个已被外部改动的文件，再让"确认不存在"开出新建通道，这正好防止两方同时创建时互相覆盖（`createIfAbsent` 是 no-clobber 原子新建）。真正缺的是**可发现性**——报错让模型"重新读"，却没说是"读一个已经删掉的文件"这种看起来像再犯错的动作用意。DSH 的 `README` 里写了这条恢复路径，但模型的 system prompt 里没有 |
| 那句子说什么 | 四件事：①被工具之外的力量删掉的文件不是死路；②`write` 的 `file no longer exists` 与 `read` 的 `not found` 都是预期；③那次失败的 read 会记成"确认不存在"，下一次 write/create 走新建并成功；④所以照做：read 一次，再重复原来那次 write，不要换文件名、不要改用 bash 写 |
| 为什么放在 `dsh-fs-ios` | 这里已经是这个移植陈述自家文件系统事实的地方（P-15 的 `ios:path-namespaces`）。并且这段注册在"有没有 bind mount"的判断**之前**：这个循环跟"一个文件两个名字"无关，没有 guest 的启动同样会碰到 |
| A/B 开关 | `DSHPORTE_RECOVERY_NOTE=0` 不注册这段（`scripts/step8-acceptance.sh --note 0`）。同一份构建开着/关着跑，`prompt_section` 判据在两种设置下都通过，但含义相反：开 = section 存在且四句齐全；关 = section 必须**不存在**。实测组装后 9 个 section vs 8 个 |
| 未采取的方案 | 在 DSH 里改报错文案（例如把 `re-read the file` 改成 `read it once even though it is gone, then retry`）。没走这条，因为那要改 `dsh-tool-fs` / `dsh-fs-local` 内部，而本条的性质是"模型缺一条知识"，用 prompt 缝更小、升级后更容易重验。若哪天 DSH 自己改了文案或加了这段说明，本段可以删掉——判据 `prompt_section` 会先失败提醒 |
| 升级后检查 | `node scripts/observation-units.mjs`（31 条断言，直接 import 出厂的两个包，跑约 1 秒）；`scripts/step8-acceptance.sh`；再跑 `scripts/agent-turn.py` + `prompts/17-step8-rmtest.txt`（keyword `RMTEST`，九步）看 transcript 的第 3/5/6 步 |

### 本单另外新增的两个工具（不改 DSH，也不改 App 行为）

| 文件 | 作用 |
|---|---|
| `scripts/observation-units.mjs` | 宿主机单元测试。直接 import `payload/` 里的 `dsh-fs-observation-policy` 与 `dsh-fs`，用一个只提供 `on`/`effect` 的假 `ctx` 挂上真实策略，用复刻 `dsh-fs-local` 三条 intent 分支的假 provider 驱动状态机。31/31。覆盖：未观察 / 已观察存在 / 已确认不存在 三种决策、失败 read 解锁 write、第二轮同样成立、editor 的 stat-then-intent 次序、跨会话不继承观察、无 owner 时 write 会被拒、单槽 first-wins 与"前置捕获后转发同一决定" |
| `sim/step8-acceptance.mjs` + `scripts/step8-acceptance.sh` | App 内验收，4 个判据：`provider_guard`（真实 provider 上删后覆盖必拒、守卫新建必成）、`policy_wiring`（emit 在 throw 之前、absent→create、editor 先 stat 后 intent 三个行号）、`prompt_section`（`assemble()` 里真有这段且顺序在 edit 之后）、`turn_harness`（真实回合用的 prompt 与 mock 脚本在位且九步次序正确） |

## 十一、第 9 单新增：全链路统一到一种规范写法

**本单没有改动 DSH 内部代码。** `git status payload/` 为空可复核。四处落点，全部是这个移植自己的代码：`sim/session-migrate.mjs`（Node 迁移）、`app/DSHPortC/NodeRunner.swift`（Swift 启动修复）、`plugins/dsh-directory-picker-ios/index.mjs`（目录选择器）、以及新增的验收工具。

**结论先说**：手机上的"列表重复 + 选现有工作区报错"不是两个 bug，是**同一个折叠方向错了**。第 7 单把 App 发布给 Node 的路径改成 `realpath(3)`（`/private/var/…`，与 DSH 的 `fs.realpath` 一致，P-18），但去重与修复仍然把 `/private/var` 折回 `/var`。于是每次启动把注册表改成运行时**立刻会否定的**那个写法。

### P-21 路径规范写法统一为 `realpath`（`/private/var/...`），折叠方向反转（**不改 DSH 内部代码**）

| 项 | 内容 |
|---|---|
| 文件 | `sim/session-migrate.mjs` 新增 `canonicalPath()` / `canonicalHeaderCwd()` / `isCanonicalPath()`；`dedupeWorkspaceRegistry()` 与 `respellContainer()` / `respellAll()` 改用它；`app/DSHPortC/NodeRunner.swift` 的 `repairWorkspaceRegistry()`；`plugins/dsh-directory-picker-ios/index.mjs` 的 `canonical()` |
| 症状（手机，`c4f2da0`） | 工作区下拉出现重复：`deepseek-harness` ×2、`workspace` ×2、`默认工作区`。**直接选现有工作区报错**，只有"添加工作区…→选目录"可用。`storages/workspace.json` 五个记录 / 两个文件夹，`/var/…` 与 `/private/var/…` 各一份；新建会话的项目目录是 `--private-var-…`，其余是 `--var-…` |
| 真实原因 | `dsh-workspace` 的 `realpathNormalize()` 对每条 workspace 路径与每个 session cwd 都调 `fs.realpath`，Node 在设备与模拟器上都答 `/private/var/…`。所以存进去的规范形是 `/private`。而第 9 单之前的 `dedupeWorkspaceRegistry()`（P-10b 更新版）与 `repairWorkspaceRegistry()`（P-10b 原版）都把 `/private/var/` 折成 `/var/` —— **方向相反**。启动时改成 `/var/…`，运行时又生成 `/private/var/…`，两边永远不一致：<br>① 同一文件夹两条记录 → 下拉两行；<br>② 选中 `/var/…` 那行时，`sessionController.create({workspaceId})` 拿记录里的路径当 cwd，`workspace.attachSession()` 把新会话 cwd realpath 成 `/private/var/…`，与存储的 `/var/…` 比较不等，抛 `cannot attach session … its cwd resolves to …`，在界面上就是 `session/workspace-attach-failed` —— **这正是用户说的"选现有工作区报错"** |
| 改动 | ① `canonicalPath()` 是**唯一**的规范形函数：`/var` 与 `/var/…` 前缀折成 `/private`，再走 `realpathSync`；解析不了（目录已删）保留已折好的字符串，不让它变成第三种写法。② `respellContainer()` 换容器与换写法一起做，`current` 本身先规范化（旧构建或手跑 harness 传 `/var/…` 时不会写回错写法）。③ 新增 `canonicalHeaderCwd()`：`respellContainer` 只回答"容器对不对"，而会话头可以是容器对、**子目录写法错**（任何 symlink 祖先都能造成）；DSH 的 `assertStoredIdentity` 拿 `projectKey(cwd)` 对日志所在文件夹，所以头必须无条件落到规范形，随后迁移把目录搬过去。④ `dedupeWorkspaceRegistry()` 折进规范形再合并，返回值多一个 `folded` 计数。⑤ `repairWorkspaceRegistry()` 用同一个 `realPath()`（App 发布路径用的就是它）。⑥ 目录选择器 `canonical()` 改折到 `/private`，并且 `list()`/`createDirectory()` 把**规范路径**交给 stock 后端 —— 因为 listing 的 `path` 会被原样回传给客户端当"用户选的那个"，写错这里就是在源头造出第二种写法 |
| 实测（同一份构建，A/B） | **修复后**：5 条记录 → 3 条（`deepseek-harness` / `workspace` / `default-workspace`），全部规范形，`folded 2 / merged 2`；3 行**全部能选中并能跑完一轮**（含真实 bash 工具调用），新会话 cwd 规范；旧会话 `session-step9-legacy-a/b` 都在、并进了同一项目目录。**修复前**（`--fold friendly`）：5 条记录 5 行，标题重复 `["deepseek-harness","deepseek-harness","workspace","workspace","default-workspace"]`，两条 `/var` 写法记录**选中即报** `session/workspace-attach-failed` |
| A/B 开关 | `DSHPORTE_PATH_FOLD=friendly`（Node 侧 `canonicalPath()`）与 `DSHPORTE_REGISTRY_FOLD=friendly`（Swift 侧 `repairWorkspaceRegistry()`），两个都由 `-DSHPortCTestPathFold friendly` 一起转发（`NodeRunner.forwardTestFlags`）。`scripts/step9-acceptance.sh --fold friendly` 就是"修复前"那一列。同一份二进制跑两遍，结论 5/5 vs 2/5 |
| 为什么折叠方向必须跟运行时一致 | 这是本条的核心判断，也是第 7 单（P-18）只做了一半的地方：P-18 统一了"App 发布给 Node 的路径"，但没统一"App 与 Node 事后各自改写注册表时往哪个方向折"。规范形由**读它的那个程序**决定，不是由哪个写法更好看决定。`fs.realpath` 是 `dsh-workspace` 的判等依据，所以规范形就是 `realpath` |
| 升级后检查 | `node scripts/session-migrate-unit.mjs`（67 条，含 `canonicalPath` 7 条、`canonicalHeaderCwd` 4 条、去重 8 条；`DSHPORTE_PATH_FOLD=friendly` 跑同一份应掉到 51/67，这是开关还有效的证据）；`scripts/step9-acceptance.sh`（5 判据）与 `--fold friendly`（对照）；`scripts/sim-dup-registry-test.py`、`scripts/sim-dup-workspace-test.py`、`scripts/sim-container-sessions.py` 复验。若 DSH 改了 `realpathNormalize` 或 `projectKey()`，本条与 P-12 的 `projectKey` 拷贝要一起对齐 |

### 本单新增的验收工具（不改 DSH，也不改 App 行为）

| 文件 | 作用 |
|---|---|
| `sim/step9-acceptance.mjs` + `scripts/step9-acceptance.sh` | App 内验收，5 个判据。**测试替身**：模拟器上不存在 `/private/var` 容器，所以在 App 自己的 tmp 下建一个指向 workspace 的 symlink，"一个文件夹两种写法"就真实成立（与手机上 `/var` vs `/private/var` 同构）。**顺序**：先种夹具（5 条记录 + 两个项目键下的真实会话日志）→ 跑**出厂的** `runFromEnvironment()` → 再 `runProfile()` 挂载 → 用真实的 `sessionController.create({workspaceId})` + `prompt` 逐行验证。判据：`fold_rules`（出厂 `canonicalPath`，`friendly` 模式下按定义必失败）、`migration`（去重/合并/项目键/默认工作区）、`selection`（**每个**工作区都能选中并跑完一轮，含 bash 工具调用）、`project_dirs`（一个文件夹一个项目目录）、`default_workspace`（首次使用路径与注册记录一致） |
| `scripts/session-migrate-unit.mjs`（扩充） | 宿主机 67 条断言。新增：`canonicalPath` 7 条（`/var`、`/var` 子树、已是规范形、模拟器 tmpdir 别名、不存在的路径、已删的 `/var` 路径、非 `/var` 交给 realpath）、`canonicalHeaderCwd` 4 条（容器对但子目录写法错必须折、规范形 no-op、跨容器仍处理）、去重 8 条（折向、合并、会话 id 并集、`workspaceIds` 去重且都活、默认记录可解析、二次运行 no-op、被并掉的默认记录把角色交给 keeper）。测试夹具本身改用规范形构造，因为 `/var/folders` vs `/private/var/folders` 正是手机那个分裂在模拟器上的同构 |

## 十二、第 10 单新增：iPad 上的测量，不改 DSH

**本单没有改动 DSH 内部代码。** `git status payload/` 为空可复核。新增的全部是 App 外壳里的测量钩子、宿主侧脚本、以及一个 UI 测试文件。

**结论先说**：iPad 上 DSH 网页界面的布局由 DSH 自己的 `SIDEBAR_AUTO_COLLAPSE = 1024` 决定，不由"是不是 iPad"决定。iPad Air 11-inch (M4) 竖屏视口 820 pt、横屏 1180 pt —— 只有横屏**满宽**越过阈值，侧栏展开到 280 pt、会话行进 DOM、可点开；竖屏 820、以及任何窄到 786 pt 以下的分屏近似，都退回 56 pt 竖条，与 iPhone 同样是窄布局。这不是 bug，是阈值在决定，报告里给了逐状态实测。

### P-22 `PadProbe`：App 外壳里的 iPad 测量钩子（**不改 DSH 内部代码**）

| 项 | 内容 |
|---|---|
| 文件 | 新增 `app/DSHPortC/PadProbe.swift`；`ContentView.swift` 里三处接线（`onReady` 的 sweep、`padLayoutFraction` 修饰符、`atDocumentStart` 的按键记录器） |
| 为什么需要它 | 任务要问的四件事在源码里都读不出来：①侧栏在 iPad 上展开还是收回，取决于 `dsh-client-ui-layout` 里 `SIDEBAR_AUTO_COLLAPSE = 1024` 与**运行时量到的**帧宽比较；②⌘ 组合键能不能到页面，是 iPadOS/WKWebView 的事实；③旋转与切后台是事件，事后轮询只能看到终态；④分屏窄窗下有没有元素溢出或点不到，只有问 DOM 才知道 |
| 记录什么 | 每次 sweep 记：视口宽高、DPR、`window.__padProbeResizes`、`documentElement.scrollWidth`、帧元素的 `data-sidebar-collapsed` 与 `gridTemplateColumns`、`[class*="_sidebarCol"]` 的实际宽度、`[data-row-key^="session:"]` 的条数与标题、`composerPresent`、**部分**越出视口的元素（`clipped`）、完全在视口外的元素（`spill`，只作计数，因为 DSH 右栏面板是刻意停在右侧的）、发送按钮在自己中心点上的命中测试（`elementFromPoint` 是否落在按钮自身或子节点）、以及页面至今收到的每一个 keydown/input |
| 门控 | `-DSHPortEPadProbe 1` 才启用。正常启动一行都不跑，成本为零，界面也无法触发 |
| 会话行点击 | `-DSHPortEPadPressSession 1` 时轮询等一行出现（最多 60 s），在行的中心做完整 pointer 序列 + `click()`，记录 `inViewport` / `hitIsSelfOrChild` / 按之前的正文长度，2.5 s 后再 sweep 一次看结果 |
| 键盘探测 | `-DSHPortEPadKeyboard 1` 时对 DSH 自己快捷键表里的九条 chord 逐条派发 `KeyboardEvent('keydown')`，记 `defaultPrevented`、`navigator.platform`、`runtime`。**每条记录都带 `synthetic: true`**：这不是键盘按出来的，是页面内合成的 |
| 分屏近似 | `-DSHPortEPadLayoutFraction 0.6667` 把 web view 约束到窗口宽度的该比例，SwiftUI 居中，DSH 的布局存储据此看到更窄的帧 —— 这正是真实 Split View 面板会让它看到的那个量。**它不是 Split View**：iPadOS 没有真的在改这个 scene，键盘 inset、安全区、多任务手势都还是全屏的。报告引用这些数字的地方都写明了 |
| 一个改错的地方（记下来） | 第一版把"`rect.right` 超过视口"都算溢出，结果每个状态都报 8 个"溢出"，而同一份数据里 `docScrollWidth` 恰好等于 `innerWidth`（根本不横向滚动）。原因是 DSH 右栏面板挂在原地、靠 `left >= innerWidth` 停在右侧。改成只统计**部分**在视口内的元素（`clipped`）后，七个状态全部为 0 |
| 升级后检查 | `[data-row-key]` 前缀、`data-sidebar-collapsed` 属性、`_sidebarCol` 类名前缀、`button[aria-label*="发送"]` 这几处选择器分别来自 `dsh-client-ui-workspace`、`dsh-client-ui-layout`、`dsh-client-ui-conversation`；改了要同步。快捷键表来自 `dsh-client-ui-workspace` 的 `installWorkspaceShortcuts()` 与 `dsh-client-ui-shortcuts` 的 `fixedCommands()` |
| 旋转怎么做的 | `-DSHPortEPadRotate landscape` 调 `requestGeometryUpdate(.iOS(interfaceOrientations:))`。**调用时机是关键**：第一版在 `onReady` 里立刻调，被拒并返回"当前窗口模式不允许以编程方式更改界面方向"，屏幕留在竖屏；同样的调用在页面就绪、scene 激活后再发，iPad 旋转到 landscapeRight，820 → 1180 pt。所以那次的失败是时机，不是 API 不可用。现在先等 `Loading plugins` 消失、再等 2 s，才发请求 |
| 分屏/窄窗怎么做 | `-DSHPortEPadLayoutFraction` 把 web view 约束到窗口宽度的该比例。**是近似**：DSH 的布局存储看到的是同一个更窄的帧，但 iPadOS 没在改这个 scene，键盘 inset、安全区、多任务手势都还是全屏的 |
| 一条没走通的路（也记下来） | `XCUIDevice.orientation` 能旋转，但只在 UI 测试里存在；`xcodebuild` 看不见本单的自定义设备集（REPORT-1 §9.3），只会落到默认设备集里的设备，而任务禁止动那些。写好的 `PadSweepTests.swift` 与 `scripts/pad-sweep.sh` 因此在本机跑不了，已删除——留下的是一条跑不了的测试，比没有更容易误导 |

### 本单新增的验收工具（不改 DSH）

| 文件 | 作用 |
|---|---|
| `scripts/device_pick.py` | `DSHPORTE_DEVICE=phone|ipad` 的单一取值点，七个原脚本改用它；未知值硬报错而不回落到手机 |
| `scripts/device.sh` | 同上，`DEVICE_KIND`/`DEVICE_NAME`/`DEVICE_TYPE` 由环境选择；iPad 只认已存在的，不会隐式新建 |
| `scripts/pad-state.py` | 测一个 iPad 窗口状态：装指定变体、启动、等 `webViewReady`、截图、把 probe 文件与一份摘要（`logs/step10/state-<tag>.json`）落盘 |
| `scripts/pad-measure.sh` | 七个状态的完整计划，每个状态一次全新启动 |
| `scripts/build-pad-landscape.sh` | 备用路线：临时把 `UISupportedInterfaceOrientations~ipad` 收成横屏、构建、再用 trap 恢复 plist。**本单的横屏数字不来自它** —— `-DSHPortEPadRotate` 直接旋转成功；保留它是因为它是唯一另一条路，且只花一个脚本 |

---



## 十三、第 13 单：后台续命

**本单没有改动 DSH 内部代码。** `git status payload/` 为空可复核。两处新接缝，性质都是"插件 + App 外壳"：一个订阅公开的 cordis 事件，一个用 iOS 26 的系统 API。没有一行 vendored 代码被改。

### P-24 `busy-ios` 插件：把"有没有一轮在跑"报给 App 外壳（**不改 DSH 内部代码**）

| 项 | 内容 |
|---|---|
| 文件 | 新增 `plugins/dsh-busy-ios/index.mjs`；profile 里挂一行（`profiles/ios-sim/cordis.patch.yml` 的 `insert`）；`NodeRunner.handleLine` 增加一个 `DSHPORTC_BUSY` 前缀分支 |
| 要解决的问题 | 第 13 单要在**切到后台的那一刻**决定是否向 iOS 申请持续后台运行。这个决定只有"现在确实有活"时才该做——空闲时申请会给用户看一个不存在的系统任务。所以外壳必须能立刻回答"有没有一轮正在跑、跑到第几步"。 |
| 为什么外壳自己答不了 | 三条路都试过/评估过：①问 WebView（`evaluateJavaScript` 读 DOM）—— 那一刻 App 已在后台，WKWebView 可能已被节流，回调可能来不及，而且 DOM 只反映"界面最后画成什么样"；②读会话日志 —— 是 zstd 帧且正在追加，每条事件后读一次的代价比整个功能还大；③订阅 `session/event` —— **采用**。 |
| 为什么插件够 | `session/event` 是**公开的 cordis 事件**，不是内部接口：`dsh-agent-loop`、`dsh-agent-instructions`、`dsh-compaction-basic` 三个包都从自己的包内 `ctx.on("session/event", …)`。所以一个订阅者零行 DSH 源码改动。与 P-6（`dsh-subprocess-ish`）、P-10（`dsh-attachment-ios`）同一个结构性论证：消费者只跟事件说话。 |
| 传输 | stdout 一行，前缀 `DSHPORTC_BUSY `，载荷 `{"busy":bool,"sessions":[{"id","turn","step","tools"}]}`。选 stdout 是因为 App **已经拥有 fd 1**（`PipeOutputStream` 为了读启动 token 把 fd 1/2 dup2 到管道上），`NodeRunner.handleLine` 已经在分发不认识的行。没有新 socket、没有轮询、没有第二把锁。 |
| 粒度 | turn/step/tool 三个边界，**不是 token**。只有这几个点会改变持久日志，也正好是系统进度指示器能表达的东西；token 级会产生每 token 一行的噪声。 |
| 报了哪些内容 | 只有会话 id、轮次号、步骤号、工具调用计数。**没有**提示词、工具参数、工具结果文本、URL、路径。 |
| 没做什么 | 没有定时器：崩溃的会话留下的"忙"比迟到的"忙"更糟，而进程死了整个 App 也死了。没有持久化：忙状态是内存态，重启即正确。 |
| 门控 | 无。这是功能本身，不是测量钩子；正常启动就会打印。代价是一行 stdout —— 与 DSH 自己已经打印的启动行同一量级。 |
| 升级后检查 | ①`grep -c 'session/event' payload/node_modules/@deepseek-ai/dsh-session/lib/index.js` 仍应命中（事件仍从 Session 提交时发布）；②`event.type` 的四个值 `turn/start`、`step/start`、`tool/call`、`turn/end` 仍是 `dsh-agent-loop` 里的 `session.append` 字面量；③`session.id` 仍来自 header；④启动日志里 `node| busy-ios: installed` 仍出现，且切一次会话能看到 `DSHPORTC_BUSY` 行。任何一条不成立，先看这个插件，不要先怀疑 iOS 侧。 |

### P-25 App 外壳：`BackgroundContinuation` 与 Info.plist 的两个键（**不改 DSH 内部代码**）

| 项 | 内容 |
|---|---|
| 文件 | 新增 `app/DSHPortC/BackgroundContinuation.swift`；`ContentView.swift` **一行**（`onAppear` 里 `BackgroundContinuation.shared.start()`）；`NodeRunner.swift` 三处小改（`BootStatus.background` 可选字段、`handleLine` 的 `DSHPORTIC_BUSY` 分支、`noteBackgroundLine`）；`Info.plist` 增加 `UIBackgroundModes` 与 `BGTaskSchedulerPermittedIdentifiers` |
| 为什么放在新文件 | 第 11 单正在大改 `ContentView.swift`。把整个生命周期放进新文件、在 `ContentView` 只留一行，是为了让合并只需要挪一行；逻辑本身不依赖那个视图的任何状态（它自己订阅 `didEnterBackground` / `willEnterForeground`）。 |
| 用的系统 API | `BGContinuedProcessingTask`（iOS 26+）、`BGContinuedProcessingTaskRequest`、`BGTaskScheduler`。标识符 `local.dshportc.app.continued-processing.<8 hex>`，每次提交新生成一个——`BGTaskScheduler.h` 写明同一标识符注册两次会被系统杀进程。 |
| Info.plist 两个键为什么都要 | ①`UIBackgroundModes` 含 `processing`：Background Tasks 框架对该任务类型的要求；②`BGTaskSchedulerPermittedIdentifiers` 含 `local.dshportc.app.continued-processing.*`：不在该数组里会得到 `BGTaskSchedulerErrorCodeNotPermitted`。**不需要 entitlement**（默认资源集）；GPU 资源才要 `com.apple.developer.background-tasks.continued-processing.gpu`，本单不加（Node jitless、guest 是 CPU 解释器，没有 GPU 用途）。 |
| 进度怎么报 | `task.progress.totalUnitCount = max(step+1,1)`、`completedUnitCount = step`，外加 `updateTitle(_:subtitle:)`。**分母是"到目前为止观察到的步数"而不是总步数**：外壳不可能知道一轮会有多少步，编一个分母会让进度条在回合没结束时先到 100%，而"看起来没进展"正是系统判定卡住、优先终止的依据。副标题报实测值（"第 N 轮 · 第 M 步 · K 个工具调用"），不报百分比。 |
| 收回时做什么 | 记日志（**明确写上"无法区分用户取消与系统收回"**，因为 `expirationHandler` 不带参数），然后 `setTaskCompleted(success: false)`。**不杀 Node、不碰会话**：这一轮的持久事件已在磁盘上，`turn/end` 有没有出现正是下次启动能否恢复的依据；进程马上要被挂起，杀掉只会白丢正在进行的那次工具调用。 |
| 一条做了又拆掉的路（记下来） | 曾打算在收回时反向通知 Node 做 `session/flush`（往子进程 stdin 写一行）。查清后放弃：GUI App 的 stdin 是 `/dev/null`，且 `dsh-cmdline` 的 `exitOnStdinEnd` 把 stdin EOF 当作退出信号（当前 profile 没挂 tui/acp/sdk，不会触发，但等于在别人的语义上埋雷）。**代价已写进 REPORT-13 §2.3**：收回时不强制 flush，极端情况最多丢最后 200ms 的持久事件（`enqueueLive` 的 `batchTimer` 窗口）。 |
| 模拟收回的钩子 | `-DSHPortESimulateExpiration <秒>`：到期调用**框架会调用的同一个** `handleExpiration()`。存在的理由：系统不会按需收回，模拟器上 `BGTaskScheduler` 又完全不可用，没有它收尾路径就是未测代码。**它证明什么、不证明什么**写在 REPORT-13 §3.3(c)。 |
| 可移植性 | 存储属性用 `AnyObject?` + `@available(iOS 26.0, *)` 的取用器，因为 App 的部署下限是 iOS 17 而该类型是 26。所有触碰该类型的代码路径都拆进了 `@available` 辅助方法，所以 iOS 17–25 上编译、运行、只记一行"需要 iOS 26"而不崩。 |
| 升级 / 换机后检查 | ①`Info.plist` 两个键还在；②启动日志有 `dshportc: bg BGContinuedProcessingTask: 可用（iOS …）`；③`supportedResources` 一行；④真机上切后台看是否出现 `bg submitted …` 而不是 `bg submit FAILED …`；⑤`Documents/DSHPortC-status.json` 的 `background` 段有 `identifier`、`lastOutcome`。 |

---

## 十四、第 15 单：手机交互补做与发送方式

**没有一行改动落在 `payload/` 里。** `git status payload/` 为空可复核（排除构建产物）。

但这一单有**一处行为改动值得登记**，因为它改写的是页面里一条会影响平台上正常功能的规则：

### P-26 `-webkit-touch-callout` 的抑制范围从整个 body 收到 chrome（**不改 DSH 内部代码**）

| 项 | 内容 |
|---|---|
| 文件 | `app/DSHPortC/MobileWebTuning.swift` 的注入样式表 |
| 第 11 单怎么写的 | `body, body * { -webkit-touch-callout: none !important; }`，注释写着"文字选择保留" |
| 实测出来的问题 | XCUITest 真实 1.2 秒长按，两种人会用到的序列（直接长按；双击选词后再长按）都没有出现编辑菜单，也没有"拷贝"项。`-DSHPortEShellDisable 1` 的对照组（整套注入关闭）结果相同，所以这不是模拟器局限，是这条规则把承载"拷贝"的菜单一起去掉了 |
| 现在怎么写 | 只对 `button, [role="button"], [data-row-key], [data-dockkit-tab], nav, header, [data-composer-dock], [data-composer-card], [data-shell-bottom]` 抑制；消息正文保留平台行为 |
| 为什么这样够 | 第 11 单要解决的"误触弹出菜单"发生在 chrome 上（按钮、会话行），不在正文上。链接预览由原生 `allowsLinkPreview = false` 单独关着，与 callout 菜单不是同一个开关 |
| 升级后检查 | ①`grep -c 'webkit-touch-callout' app/DSHPortC/MobileWebTuning.swift` 应为 1 条规则，且选择器里不含 `body`；②真机长按一条回复应出现"拷贝"，长按会话行不应弹菜单；③`scripts/step15-xct.sh Step15TouchTests` 里 `testLongPressStillCopiesText` 会打印两段菜单证据 |

### 本单新增的外壳文件（不改 DSH）

| 文件 | 作用 |
|---|---|
| `app/DSHPortC/Step15Probe.swift` | 第 15 单的全部测量：安全区/IME/会话列表/深色/代码块/切后台/竖条/发送方式/连点/启动屏，`-DSHPortEStep15 1` 才跑；另有 `eval` 两段式通道用于页面侧实验 |
| `app/DSHPortC/Assets.xcassets/PageBackground.colorset` | 启动屏颜色（浅/深两版），与 `MobileWebTuning.Palette` 同一对值 |
| `app/DSHPortCUITests/Step15TouchTests.swift` | 五项真实触摸测试（长按选字、连点、双击不缩放、左边缘、Home 键切后台） |
| `scripts/step15-state.py`、`scripts/step15-xct.sh` | 单状态采集与本机 XCUITest 运行器（用默认设备集里为这一单新建的 `dsh-portE-xct-15`） |
| `scripts/step15-pixels.py`、`scripts/step15-bootshot.py` | 截图像素读数与冷启动高频截图亮度统计 |
| `scripts/step15-xcresult-shots.py` | 从 `.xcresult` 里导出测试自己拍的截图 |

### 第 15 单改了 DSH 之外的第三方行为（记录，不是 patch）

| 项 | 内容 |
|---|---|
| `WKContentView` 子类（P-23，第 11 单登记） | 本单未改，仍在生效；`keyboard.accessoryPresent == false` 的复验命令仍适用 |
| `MobileWebTuning` 的 `touchend` 双击拦截 | **已删除**。它取消任意 320 ms 内的第二次点击，实测一次"侧栏开关 + 新建会话"的快速两连点里第二下被吞。改由 CSS `touch-action: manipulation` 在定义处禁用双击缩放，脚本不再事后取消任何触摸 |

## 十五、第 16 单：系统通知

**本单没有改动 DSH 内部代码。** `git status payload/` 为空可复核（`payload/` 里唯一的改动来自 `scripts/build-app.sh` 每次构建都会跑的两个幂等补丁脚本，它们在 HEAD 上已经是打过的状态）。两处新接缝，性质都是"插件 + App 外壳"：一个订阅公开的 cordis 事件，一个用 iOS 的本地通知 API。

### P-26 `notify-ios` 插件：把"有事要告诉用户"报给 App 外壳（**不改 DSH 内部代码**）

| 项 | 内容 |
|---|---|
| 文件 | 新增 `plugins/dsh-notify-ios/index.mjs`；profile 里挂一行（`profiles/ios-sim/cordis.patch.yml` 末尾的 `insert`）；`NodeRunner.handleLine` 增加一个 `DSHPORTC_NOTIFY` 前缀分支 |
| 要解决的问题 | 四种情况（一轮做完、出错、等批准、AI 提问）全部只存在于 DSH 的持久会话日志里，而**需要它们的时刻正是 App 刚被切到后台**：那一刻 WKWebView 可能已被节流，会话日志是正在追加的 zstd 帧。所以观察必须发生在事件被发布的地方。 |
| 为什么插件够 | `session/event` 是**公开的 cordis 事件**，`dsh-agent-loop`、`dsh-agent-instructions`、`dsh-compaction-basic` 三个包都从自己的包内订阅它，第 13 单的 `busy-ios` 也是。一个订阅者零行 DSH 源码改动。与 P-6、P-10、P-24 同一个结构性论证。 |
| 传输 | stdout 一行，前缀 `DSHPORTC_NOTIFY `，载荷 `{"kind","sessionId","title","body","key"}`。与 P-24 相同的管道、相同的前缀分发点，没有新 socket、没有轮询。 |
| 四个事件的判定 | `turn/end` 且 `reason.kind === 'completed'` → 做完；`=== 'error'` → 出错，正文用错误码的中文类别（`FAILURE_LABELS`），不取 `error.message`（那里面有 provider URL）；`approval/asked` → 等批准，正文从审计字符串里反读规则名再查 `APPROVAL_LABELS`；`tool/call` 且 `name === 'ask_user_question'` → 提问，正文取第一条问题并截到 80 字。**以代码为准核对过**：`TurnEndReasonMap`、`ApprovalOutcome`、`ask_user_question` 的参数结构都读自 `payload/node_modules` 的类型声明与实际实现。 |
| 不发的三种 | 用户取消（`reason.kind === 'aborted'`，**代码里根本没有对应分支**）；子代理会话（`session.header.origin === 'subagent'` 或带 `parentSession` 的直接 return，只有会话树根会发）；同一次审批或提问发两遍（`approval:<id>` / `question:<callId>` 做去重键，`approval/decided` 与 `tool/result` 到达时把键撤掉并写一行 `dismiss`）。 |
| 载荷里没有的东西 | 提示词、工具参数、工具结果、命令文本、stdout、路径。正文是几句固定的中文，加上一段被截断的问题。通知画在别的 App 上面，是 token 和路径最不该意外出现的地方。 |
| 与 `busy-ios` 的关系 | 两个插件订阅同一个事件流，各写各的前缀，互不依赖。`busy-ios` 报"有没有在跑"给第 13 单的后台申请用；`notify-ios` 报"有什么值得告诉用户"。分开是刻意的：其中任何一个被停用，另一个照常工作。 |
| 升级后检查 | ①`event.type` 的 `turn/end` 仍带 `reason.kind`；②`approval/asked` 仍带 `id` 与 `reason`；③`ask_user_question` 的 `tool/call` 参数仍是 `{questions:[{id,question,...}]}`；④启动日志仍有 `notify-ios: installed`；⑤跑一轮能看到 `DSHPORTC_NOTIFY` 行。任何一条不成立先看这个插件，不要先怀疑 iOS 侧。 |

### P-27 App 外壳：`NotificationBridge` 与 `Settings.bundle`（**不改 DSH 内部代码**）

| 项 | 内容 |
|---|---|
| 文件 | 新增 `app/DSHPortC/NotificationBridge.swift`（含 `NotifyKind`/`NotifySettings`/`NotificationTapRelay`/`NotificationNavigation`/`NotificationActionDriver`）、`app/DSHPortC/NotificationSettingsView.swift`、`app/DSHPortC/Settings.bundle/Root.plist`；`ContentView.swift` 五行（`start()`、`pageDidBecomeReady()`、菜单入口、sheet、`register`）；`DSHPortCApp.swift` 的 `init()` 一行（`NotificationTapRelay.install()`）；`NodeRunner.swift` 三处（`BootStatus.notifications`、`handleLine` 的 `DSHPORTC_NOTIFY` 分支、`noteNotificationReport`） |
| 为什么点通知要走 `init()` | 一条 tap **启动了** App 时，`UNUserNotificationCenter` 在启动末尾把 response 交给当时的 delegate。`NotificationBridge` 是 `@MainActor`、从第一个视图的 `onAppear` 启动——装在那里的 delegate 会错过"App 已被杀"这一种，而那正是任务要求处理的三种之一。所以 `NotificationTapRelay` 在 `DSHPortCApp.init()` 里装上，先把 tap 存住，等 bridge 接手时回放。 |
| 跳转怎么做的 | 没有 URL 能指到一个会话：页面选择是客户端 store（`uiWorkspace` 的 `selection`，持久化在 `dsh.sessions.current`），web app 没有为它保留路由——它读的 query 参数只属于子代理面板。所以 tap 被翻译成**和点侧边栏行完全一样的东西**：按压 `[data-row-key="session:<id>"]`，这是 `ui-workspace` 给每一行打的标识，也是 `UIDriver` 已经在用的选择器。**没有改 `payload/`**，也没有发明一个下次升级就会失效的 deep link。降级顺序：行已在 → 按它；抽屉关着 → 开抽屉再按；行根本不在 DOM（别的 workspace）→ 写持久化选择并 reload，走 `uiWorkspace.restoreSelection` 自己的恢复路径。 |
| 什么时候不发 | 前台（`sceneIsActive`，记一条 `suppressed` 说明原因）；开关关掉（同样记账，**负例的证据就是这张表**）；系统未授权（`denied`/`notDetermined` 各有一句）。三种都写进 `DSHPortC-status.json` 的 `notifications.suppressed`，所以"什么都没出现"和"功能没运行"可以分开。 |
| 授权 | 不在启动时问。`turn-start` 到达时才问，且只在这一次进程里问一次；四个开关全关时连问都不问（那等于问"能不能什么都不做"）。用户拒绝后不再请求——`denied` 是系统的最终答复，再问也改不了。没有授权时不崩：`postable()` 读缓存的状态，未授权只记一条抑制。 |
| 系统状态为什么缓存 | `notificationSettings()` 是一次到系统守护进程的异步往返，而这个决定发生在 App 刚被切后台的一刻——第一次实现就是在这里挂住的：`Task` 在等回复，进程先被挂起，请求既没投递也没记账。改成缓存后判定是同步的，即使进程马上要停也能写完日志。缓存会在启动、每次授权回复、每次投递之后刷新。 |
| 开关放哪、用户几步能到 | **两处，写的是同一批 `UserDefaults` 键**（`DSHPortENotify.<kind>`）：①双指长按界面 → 调试菜单 → 「通知设置」，一步到位，还能看到"系统通知已关闭"并跳到系统设置；②iOS 设置 App → DSH → 通知，`Settings.bundle/Root.plist` 的四行 `PSToggleSwitchSpecifier`。**为什么不用 DSH 设置页**：`dsh-client-ui-settings-plugins` 是个**壳**——它只拥有导航入口和 tab 行，页里每个 tab 都由别的客户端包注册，唯一随包发布的 tab 是只读清单。所以"设置页会自动渲染插件配置项"不成立；要走那条路得新写并发布一个浏览器插件，也就是往 `payload/` 里加东西，这是本任务排在最后的选择。 |
| 后台收回的通知 | `BackgroundContinuation.handleExpiration()` 在有回合未完成时发一条「任务被系统暂停，回到 App 继续」，归入"出错"开关。**为什么不在插件里做**：收回不产生任何持久事件——进程被挂起、回合留着、`turn/end` 永远不到，所以唯一诚实的观察点就是 `handleExpiration()` 本身。第 13 单已记录"`expirationHandler` 不带参数，无法区分用户取消与系统收回"，所以从系统界面取消的用户也会收到这一条；任务说多发一条可以接受，而猜一个原因等于撒谎。 |
| 调试钩子（都在正常启动走不到的地方） | `-DSHPortESetNotify kind=on/off,...` 写开关（写的是设置页写的同一批键，所以下一次**不带任何参数**的启动就是"重启后还在"的证据）；`-DSHPortENotifyDump 1` 把 `getDeliveredNotifications` 的结果转储到 `Documents/DSHPortC-notifications.json`；`-DSHPortESimulateNotifyTap <id>` 在启动时喂一次 tap；`-DSHPortENotifyDrive 1` 打开命令文件通道；`-DSHPortEHoldApproval 1` 让测试驱动不要自动答审批。 |
| 命令文件通道是什么 | `Documents/DSHPortENotifyCommand.json` 进、`DSHPortENotifyResult.json` 出，内容是"执行这段 JS"。存在的理由：acceptance 要在**已经在跑的** App 上答审批、按停止、读页面选择，而这几个动作都没有外部触发方式，`xcodebuild test` 又看不见本任务的自定义设备集。它证明 App 对一次按压的反应；**不证明**这次按压能被手指够到——后者是 XCUITest 的事，REPORT-16 把两者分开写。 |
| 可移植性 | `NotificationBridge` 用 iOS 15+ 的 `UNUserNotificationCenter` API，部署下限 17，没有 availability 分支。`NotificationTapRelay` 是 `NSObject` + `UNUserNotificationCenterDelegate`，`nonisolated` 方法里 hop 回主 actor。 |
| 升级 / 换机后检查 | ①`Settings.bundle` 还在包里（`ls DSHPortC.app/Settings.bundle/Root.plist`）；②启动日志有 `dshportc: notify bridge started (…=on …)`；③`turn-start` 之后有 `dshportc: notify authorization now authorized`；④切后台跑完一轮看到 `dshportc: notify delivered done …`；⑤`Documents/DSHPortC-status.json` 的 `notifications` 段有 `delivered`/`suppressed`/`switches`。 |

### P-28 后台续命：前台申请，以及冻结时间不算工具耗时

| 项 | 内容 |
|---|---|
| 症状 | 第 12 单真机上后台申请被接受，但系统一次都没启动任务；冻结后回来，正常的 bash 被报 `timed out after 60000ms` 并杀掉 |
| 申请时机 | `BackgroundContinuation` 改为回合开始且 App 在前台时提交，用 `.fail` 策略，回前台不结束任务，持续到回合结束 |
| 进度 | `plugins/dsh-busy-ios` 在回合进行中每 10 秒多发一行 `beat`，每行推进一格。它只证明 Node 活着，不代表回合有进展 |
| 没拿到续命 | 切后台时发“任务被系统暂停”通知，回前台或回合结束时撤掉 |
| payload 改动 | `scripts/patch-payload-frozen-timeout.py` 改 `@deepseek-ai/dsh-timeout` 的 `deadline` 和 `idleWatchdog`，幂等，`build-app.sh` 每次运行 |
| 证据 | 进程被 SIGSTOP 10 秒、预算 6 秒：原版 12.0 秒时超时（只实际跑了 2 秒），修后 16.0 秒超时。模拟器没有这个调度器，能否续命只能真机验证 |
| 升级后检查 | `grep -n 'frozen time is not spent' payload/node_modules/@deepseek-ai/dsh-timeout/lib/index.js`；补丁脚本匹配不到原文会报错退出 |

### P-29 手机单栏布局：收起的右侧栏不能盖住内容

| 项 | 内容 |
|---|---|
| 症状 | 手机竖屏上对话和轨迹不能滑动，命令和思考不能展开，顶部标签正常 |
| 原因 | `MobileWebTuning` 的单栏规则把 `_rightbarCol` 放进第 1 列，不分是否收起。收起时它是一个 402x778 的透明空列，`elementsFromPoint` 测得内容区的触摸都落在它上面 |
| 做法 | `[data-rightbar-collapsed] > _rightbarCol` 回到 0 宽的第 3 列，展开时不变 |
| 证据 | `app/DSHPortCUITests/Step22ScrollTests.swift`，真实拖动和点按；修前对话滑动、折叠行展开、轨迹滑动三项都失败，修后全过 |

### P-30 Mock 只在测试启动时存在，正常启动用上游默认模型

| 项 | 内容 |
|---|---|
| 目的 | 手机上不再出现 Mock，也不再默认选中它，同时保住设置页的第三方和自定义提供商 |
| 做法 | `profiles/ios-sim/cordis.patch.yml` 里两行互斥：没有 `DSHPORTC_MOCK_PORT` 时运行原版 `llm-pi-ai`，有时运行带 `local-mock` 的 `llm-pi-ai-mock`。默认模型无 Mock 时回落 `deepseek-official` / `deepseek-flash` |
| 试过不行的 | 正常启动禁用 `llm-pi-ai`：第三方提供商消失。`providers: !!js`：每次保存报 `$.providers.__jsExpr expected object`。两个实例同时运行：`configurable provider "amazon-bedrock" is already declared`，Mock 注册不上 |
| 带来的差别 | 测试启动时设置命名空间是 `llm-pi-ai-mock`，提供商表单没有自定义那一半，所以 `testSettingsAPIFieldStaysAboveTheKeyboard` 改为正常启动 |
| 证据 | `logs/step22/merged2/summary.txt`、`logs/step22/merged3/summary.txt`。`testNormalLaunchOffersRealProviders` 存假密钥后重启：当前模型 DeepSeek-V4.1-Flash，列表有 DeepSeek-V4.1-Flash 和 DeepSeek-V4-Pro，无 Mock |
| 后续 | 保存的提供商重启后消失的问题见 P-31 |

### P-31 App 自己的配置层不再覆盖设置页保存的内容

| 项 | 内容 |
|---|---|
| 症状 | 设置页添加的第三方提供商，重启后配置消失，密钥还在 `.credentials.yaml` |
| 原因 | 设置页保存到 profile 的 `cordis.patch.yml`，`NodeRunner` 每次启动又用模板重写同一个文件 |
| 做法 | 模板渲染到 `profiles/ios-sim/node_modules/dsh-ios-profile/`，作为 profile 的第三个 bundle，每次启动重写。`cordis.patch.yml` 归用户，只在不存在时写 `[]` |
| 升级 | 旧安装的 `package.json` 没有这个 bundle 时替换。旧 `cordis.patch.yml` 含 `dsh-sandbox-ios/index.mjs` 时移到 `cordis.patch.yml.before-bundle`，只迁移一次，旧文件里上一次会话保存的内容不带过来 |
| 证据 | `logs/step22/merged4/summary.txt`。`testNormalLaunchOffersRealProviders` 保存后重启，模型列表有 Bedrock，用户层只有 `llm-pi-ai` 的 `amazon-bedrock`。已保存提供商后再做测试启动通过。旧配置迁移另行手动测过：有备份、清单含 bundle、用户层为 `[]`。summary 里 `upgrade:` 那行是检查抢在重启前读的旧日志，不算数 |
| 升级后检查 | `sim-tz-ab.py` 等改的是 App 包内模板，不受影响；改 profile 只改 `profiles/ios-sim/cordis.patch.yml` |

### P-32 模型按钮不显示 1017 标签，手机抽屉有动画

| 项 | 内容 |
|---|---|
| 标签 | 上游插件把模型名和 1017 标签包在不换行的 inline-flex 里，省略号不生效，标签被裁成残边。`MobileWebPolish` 让按钮内的包裹层变成 inline 并隐藏标签，打开的模型列表不受影响 |
| 抽屉 | `MobileWebTuning` 的单栏规则：侧边栏开合都保持在第 1 列第 1 行，用 `@starting-style` 和 `display` 的 `allow-discrete` 过渡滑动 0.26 秒，遮罩淡入淡出，右侧栏只有打开时有动画。不支持这些特性的系统退回无动画 |
| 证据 | `logs/step22/merged5/summary.txt`。`testDrawerSlidesInAndOut` 逐帧采样：有中间位置，遮罩有中间透明度，内容列高度全程 778 |

### P-33 轨迹详情在手机上按内容高度显示，抽屉跟手

| 项 | 内容 |
|---|---|
| 详情面板 | 上游窄屏是整高、92 % 宽的侧滑面板，挡住整个列表。手机竖屏改为通栏，从列表顶部垂下，高度随内容，最多到输入框上方 |
| 选中下划线 | 第 18 单的点击范围 `::after` 把详情标签的下划线拉成压字的线。该规则的背景加 `!important`，下划线改用 `box-shadow` |
| 跟手 | `MobileWebTuning` 用 `--dsh-rail-x` 记录位置，边缘 24 pt 内横向拖动打开，打开后任意位置向左拖动收起。松手过半或快速一甩决定开合。纵向起手仍归列表 |
| 证据 | `logs/step22/merged6/summary.txt`。`testDrawerFollowsTheFinger` 用真实拖动并停住：左边缘 -180、-50、-80、-210，都在预期 12 pt 内，松手后按预期开合 |

### P-35 客户机预装 Python、Node、npm（试验性），App 向内核提供内存读数

**更正：** 下表是执行方的初稿，其中“Node、npm 不可用”和“建议删除”已被推翻。`ISHGuest.m` 接上内存读数（`ish_set_memory_status`，做法同上游 `app/AppDelegate.m`）后，模拟器上 Node 3/3、npm 4/4、JS 和 Python 项目、管道 6/6 全过。`dsh-subprocess-ish` 在取消后等待被取消的命令退完。真机未测。Node 崩溃可能报退出码 0（`kernel/signal.c` 的 `v8_aborting`，上游有意为之）。详见 `REPORT-24.md` 开头。


| 项 | 内容 |
|---|---|
| 目的 | 让 bash 所在的客户机里有 `python3`、`node`、`npm`，并用实测回答"能不能用、稳不稳、多慢多大" |
| 镜像 | `ish/scripts/build-rootfs.sh` 的 `GUEST_PACKAGES` 加 `nodejs npm python3`；不加 `pip`/`gcc`/`make`/`*-dev`。压缩后 15.28 → 52.76 MB，包数 54 → 72 |
| 不留 apk | 装完校验后 `apk del apk-tools`，再写清单。`/sbin/apk` 消失，`/lib/apk/db` 保留（清单的数据源）。build 里加了"apk 若还在就 fail"的断言 |
| 清单生成 | `RootfsPackages.md` 从 `apk info -v` 改为读 `/lib/apk/db/installed`，因为镜像里已经没有 apk。文件头写明原因 |
| 修了一个一直骗人的检查 | 原来的安装校验 `guest -c "apk info -e $pkg"` 依赖退出码，而宿主 `ish` CLI **不传播客户机退出码**（`exit 3` 也返回 0）。改成从 stdout 读 `GUEST-CHECK-PRESENT`/`MISSING`，并对三个 runtime 各加一条"真的能跑起来"的检查 |
| Python 结论 | 通过。`/workspace` 和 rootfs 两处都验了：JSON、`os.replace` 原子替换、`sqlite3`（含回滚）、`zipfile`/`gzip`、HTTPS（证书链 `authorized: true`，OpenSSL 3.3.2）、`subprocess` 管道+超时（残留 sleep 为 0）、8 线程、CPU 循环。真实项目 8 个 unittest 全过，负控能失败 |
| Node 结论 | **不可用**。`node --version`/`--v8-options` 能答，`node -e ""`、`node file.js`、`node --check` 全部 abort 后空转：`Assertion failed: (0) == (uv_thread_create(...))`，`node_platform.cc:104`，进程停在 `R` 状态、`wchan` 空 |
| Node 根因 | 内核 `task.c:265` 的 `pthread_create` 返回 EAGAIN/ENOMEM，`sys_clone` 把负 errno 交给客户机，libuv 断言。最可能的来源是内存准入：`kernel/mm.h` 的旧账本按**承诺量**记账（上限 131072 页），Node 启动承诺 640 MB V8 cage。宿主 CLI 之所以能跑 node，是因为 `main.c` 调了 `ish_cli_memory_governor_start()`；App 侧 `ISHGuest.m` 里**没有** `ish_set_memory_status`，仍在旧账本模式 |
| 没修 | 上面这条根因**没改**：给 App 接 `os_proc_available_memory()` 采样源并改内存准入是另一个任务的范围，会影响所有已在跑的负载。只把证据和位置写在 REPORT-24 §2.4 / §7 |
| npm 结论 | 不可用（它是 Node 程序）。`npm --version` 被 KILL 于 137；`npm init -y` 更糟：连 `timeout -s KILL 20` 都不返回，会把 provider 的单命令队列按住到外部看门狗触发（REPORT-24 §2.6） |
| 提示段 | 新插件 `plugins/dsh-guest-runtimes/index.mjs`，段名 `ios:guest-runtimes`，位置 `TOOL_BASH + 2`，在 `profiles/ios-sim/cordis.patch.yml` 里以 `guest-runtimes` 行挂载。**只写实测通过的**：python3 能力清单、约 50 倍慢、无 pip 无编译器、venv 可装纯 Python wheel，以及**明说 Node 不可用且不要重试** |
| A/B 开关 | `DSHPORTE_GUEST_RUNTIME_NOTE=0` 移除该段，与 `DSHPORTE_RECOVERY_NOTE` 同法 |
| 验收脚本 | `scripts/step24-acceptance.py` + `sim/step24-acceptance.mjs`，五段矩阵 + 诊断段 `isolate`。App gate `DSHPORTE_STEP24_ACCEPTANCE`，四个旋钮走 launch argument（`SIMCTL_CHILD_*` 在同一 boot 内会被锁成首值，REPORT-5 记录过） |
| 每条命令套 KILL | 客户机侧 `timeout -s KILL`，不是防御性编程：会挂的进程卡在自己的信号路径里，`SIGTERM` 无效。退出码 137 本身是证据 |
| 附带发现 | cancel 之后有 <50 ms 的交接窗口：`ISHGuest.m` 在 completion 之后才用 `dispatch_async(_guestQueue, ...)` 清 in-flight 标记，期间下一条命令报 `a guest command is already running`。**没修**，位置写在 REPORT-24 §2.5 |
| 体积 | 镜像 +37,475,306 B；App 437 → 473 MB。其中 `icu-data-en` 单独 25 MB，是 `nodejs` 拉进来的 |
| 许可证 | `THIRD_PARTY_NOTICES.md` §4.1 新增 nodejs(MIT) / npm(Artistic-2.0) / python3(PSF-2.0) 及其依赖；另单列 `apk-tools`(GPL-2.0-only) 为何不在镜像里 |
| 回归 | step7 6/6、step8 4/4、step9 5/5、subprocess 9/9，全在 `phone-polish` 上，证据 `logs/step24/regression/` |
| 建议 | **删 `nodejs` 和 `npm`，保留 `python3`。** 理由：不能用；占 +35 MB 的绝大部分；引入 Artistic-2.0 许可族。若保留，至少去掉 `icu-data-en` |
| 升级后检查 | `grep -n 'guest-runtimes' profiles/ios-sim/cordis.patch.yml`；`grep -c . RootfsPackages.md`（应 83 行含注释，72 个包）；客户机内 `command -v apk` 应为空、`python3 --version` 应有输出 |
### P-34 抽屉拖动不再重算整页样式

| 项 | 内容 |
|---|---|
| 原因 | P-33 把位置写在根元素的 `--dsh-rail-x` 上。这个变量会继承给所有元素，每次移动都要重算整页样式；根元素的 `style` 变化还会触发输入框提示的检查 |
| 改法 | 位置直接写在侧边栏元素的内联 `transform` 上，拖动期间侧边栏和遮罩用 `will-change` 独立成层，输入框提示的检查在拖动时跳过。`--dsh-rail-x` 删除 |
| 证据 | `logs/rail-perf/`。模拟器上 399 个元素的页面：写根元素每次 8.2 ms，写侧边栏每次 0.1 ms。`testDrawerDragLeavesTheRestOfThePageAlone` 修前根元素被写 40 次而失败，修后 0 次 |
| 未解决 | 拖动刚开始时 DSH 要渲染约 80 个新元素，模拟器上卡 40 到 130 ms，手机上没有测过 |

### P-36 启动容错：安全模式、失败页、诊断包、重置运行环境

第 19 单的 JS 方案在手机上写完，这一单把它接到 App 上，并在模拟器上逐条验收。过程中发现并修掉了五个方案缺陷，其中三个会让功能在最需要它的时候失效——都写在下表里，因为它们比新增的功能更值得记。

| 项 | 内容 |
|---|---|
| 安全模式 | 连续 3 次启动失败后，第 4 次启动用 `--patch` 覆盖层关掉 6 个 App 自有插件（`guest-runtimes`、`diag-prompt`、`busy-ios`、`notify-ios`、`directory-picker-browse`、`ui-directory-picker-browse`），并把用户层 `profiles/ios-sim/cordis.patch.yml` 停车成 `.safe-mode-parked` + 原地写 `[]`。`fs-ios`/`subprocess-ish`/`sandbox-ios` 是服务提供者，`ish-approval-policy` 是唯一的破坏性命令 `ask` 来源，`attachment-ios` 是唯一的 `ctx.attachments` 提供者——这 5 个必须留 |
| `--patch` 位置（修） | **位置比拼写更容易错**。`bin.js` 的 `passThroughOptions()` 让 `--no-open` 之后的参数原样进被启动的 App，所以把覆盖层追加到末尾会得到 `error: unknown option '--patch'` 和 `node_start returned 1`。必须插在第一个 App 参数之前。本机 `--dump-config` 对照验证过 |
| 失败计数（修） | `boot-outcome.json` 改成一行一条紧凑 JSON 的追加式。原先是"一个文件一条结论"，而 `node_start` 之前就失败的启动（缺 `payload/`、`fail-fast`）从不运行 `beginLaunch()`，于是每次失败覆盖上一条，实测三次失败后计数仍是 0、安全模式进不去——恰好是最需要它的故障 |
| 安全模式的跳过清单（修） | `attachment-ios` 原本要跳过。实测跳过之后页面 4.51 秒能开，但 `dsh-api-session-controller` 因 `inject = [..., "attachments", "fileUploads", ...]` 一直 pending，一条会话都建不出来。改为保留：它只在客户机通道缺席时才硬失败，那不是安全模式要救的故障 |
| 停车后还原（修） | `restoreUserPatch()` 现在会看当前用户层内容：不是空也不是 `[]` 就说明安全模式期间有人存过设置，把它改名成 `cordis.patch.yml.safe-mode-edited`（已存在加序号、绝不覆盖），返回值带路径，启动日志说明"设置保存在这里"。`[]` 与空文件不算改动 |
| 失败页 | 两个按钮（查看启动日志 / 导出诊断包）+ 一个"重置运行环境"入口，`accessibilityIdentifier` 为 `bootLogButton`、`bootDiagnosticsButton`、`bootResetButton`。诊断包在 Node 已死时有最小包兜底 |
| 安全模式横幅 | 顶部窄条：跳过 N 个插件、原因、"退出安全模式"、"重置运行环境"。用 overlay 而不是改布局，因为安全模式正是最不该让页面重排的那次启动 |
| 看门狗 | 60 秒，覆盖插件加载及客户端挂载。旧的 4.74 秒中位数测到 `didFinish`，不能与现在的界面就绪耗时直接比较，也不能据此验证新口径的超时阈值。`didFinish` 只记 `documentLoaded`；`webViewReady` 等待 `#root` 内出现可见布局或交互控件且不再显示插件加载页。`-DSHPortEStep19HoldReadyMs <毫秒>` 延迟这个就绪信号；普通客户端异常只留作诊断，超时时附上第一条错误，ResizeObserver loop 提示忽略。升级后须复验首次安装、已有会话、安全模式及不同语言的界面 |
| 诊断包（修） | `diagnostics/` 原方案写成 `dirname(dshHome)/diagnostics`，那是 `.../Application Support/diagnostics`，而 App 读 `.../Application Support/DSHPortC/diagnostics`。修正后实测 9 个文件、64 KB，五条脱敏规则在真实内容上命中，假密钥 0 泄漏 |
| 重置 | 两个开关 + 清单预览（Node 写 `boot/reset-plan.json`；缺失时用 App 内置的同一张表）+ 确认。两阶段 `rename` 进 `reset-staging/`，`in-progress.json` 让断电后能接着做完。`boot/` 本身在移走范围内，所以清单先读进内存 |
| 清暂存（新） | 面板上"彻底清除上次重置留下的数据"：先显示占用，确认后删除，**绝不自动**。实测 45056 字节 → 清除 3 项 → 0 字节 |
| 两张表不许漂移 | Swift 的 `ResetTable.tiers` 与 JS 的 `TIERS` 由 `scripts/reset-plan-parity.py` 逐条同序比对，漂移退出码 1。负控跑过（删一条 → 退出 1 并指出缺哪一条） |
| 验收 | 第 9 节九条全过（第 7 条的说明见 `work-step19/REPORT-19B.md` §5），外加安全模式建会话/发消息/`bash`、破坏性命令仍确认、暂存清除。回归 step7 6/6、step8 4/4、step9 5/5、子进程 9/9 |
| 测试 | `tests/step19` 从 100 条增到 112 条，宿主 Node 24.10.0 全过；客户机 Node 22.23.4 经 `ctx.subprocess` 跑同一批，也是 112/112（与 `REPORT-24` 记的"Node 不可用"不同，只记录现象） |
| 证据 | `logs/step19/acceptance-final.log`、`logs/step19/acceptance/summary.txt`、`logs/step19/tests-node24.log`、`logs/step19/parity.log`、`logs/step7|8|9/`、`logs/step5/subprocess-acceptance.json` |
| 升级后检查 | `grep -c '^- id: ' <container>/Library/Application Support/DSHPortC/boot/safe-mode.patch.yml`（安全模式时 6 行）；`python3 scripts/reset-plan-parity.py`；正常启动后 `profiles/ios-sim/cordis.patch.yml.safe-mode-parked` 应为空 |
| 启动失败不关 App | DSH 的 `process.exit(1)` 在 App 进程内会关掉 App。`ios-app-entry.mjs` 拦截非 0 退出，发 `DSHPORTC_FATAL <原因>` 后停住 Node 线程，App 显示失败页 |
| 崩溃循环 | 安全模式失败 2 次后，下一次不启动 Node，停在失败页并写 `clear-guard`；再下一次重新计数 |
| 诊断包文件 | 分享的是合并后的单个文本文件 `DSH-diagnostics-*.txt` |
| 未解决 | 真机未测；真实 V8 崩溃未测；分享没有真的发到别的 App。详情见 `work-step19/REPORT-19B.md` §11 |

### P-37 开源前必修：第 19 单合并后审查发现的问题

2026-11-03 对合并后的 master 做了第二轮审查，修掉了以下问题。P-36 里“两阶段能接着做完”在这一条之前并不成立：移动失败照样算完成，见下表。

| 项 | 内容 |
|---|---|
| 失败页白屏（修） | `ContentView` 原来是“有 URL 就显示网页，否则显示启动页”，Node 一打印 URL，启动页和失败页的按钮就没了。网页之后一直没画出来时（实测：卡住 75 秒），`boot-outcome.json` 记了失败，屏幕却是空白。现在启动页叠在网页上方，直到网页画出来才淡出 |
| 重复计数（修） | Node 的 `noteFailure` 已结算一次，Swift 收到 `DSHPORTC_FATAL` 后又写同一 launchId 的 outcome，下次启动再算一次。`boot-guard.mjs` 现在跳过 history 里已有的 launchId |
| 安全模式准备失败（修） | `ios-app-entry.mjs` 原来吞掉 `safeMode.prepare()` 的异常，接着用刚失败过三次的正常组合启动，横幅还写着安全模式。现在停在失败页（`parkStartup`） |
| 重置（修） | `ResetRunner` 任一项移动失败就保留 `in-progress.json` 和请求、写 `ok:false`、本次启动停在失败页，下次续做。执行前逐项校验路径（容器内相对路径、只限三个根、逐级拒绝符号链接），不合格整体拒绝并把请求改名为 `reset-request.refused.json` |
| 诊断包脱敏（修） | `redactText` 补了 YAML/JSON 键值形式的密钥、环境变量赋值、URL 里的账号密码；manifest 和 SUMMARY 的路径也脱敏。失败页兜底的最小包原来直接复制文件，现在 Swift 端按同样规则脱敏，只取白名单文件，单文件 256 KB、整包 2 MB |
| 命令工作目录（修） | `dsh-subprocess-ish` 原来把认不出的绝对路径静默换成 `/workspace`。现在客户机路径（如 `/tmp`）原样交给客户机，明显是宿主路径但没挂载的报错不执行。`ISHGuest.m` 里 chdir 失败不再执行命令，返回 launchError |
| 外链（修） | `LinkRouter.openExternally` 统一检查 scheme 白名单；新窗口和 popup 分支原来绕过了它 |
| 文件工具围栏（新） | `plugins/dsh-fs-ios/lib/fence.mjs`：文件工具不能读写 `DSH_HOME/.credentials.*`、`.env*`、`storages/` 和 `DSHPortC/`；先 realpath，按不区分大小写比较，凭据文件另比 dev+ino 防硬链接 |
| 客户机挂载（新，改 iSH） | `ish/patches/0003-deny-guest-realfs-mount.patch`：`sys_mount` 拒绝 `realfs`。原来客户机里 `mount -t real <容器路径> /mnt` 可挂任意宿主目录，包括密钥目录。宿主自己的挂载走 `do_mount()`/`fakefs_bind_mount()`，不受影响。实测：tmpfs 对照挂载成功，realfs 挂载 `permission denied`，探针文件读不到（`scripts/guest-test.sh fence`，`logs/guest-fence.json`） |
| 构建：Xcode 升级（修） | Meson 只在首次 `setup` 读交叉文件的参数，Xcode 把 SDK 从 27.1 换成 27.2 后，重新生成时报 `library 'sqlite3' not found`。`build-ish.sh` 记下用过的 `cross.ini`，变了就把旧构建目录改名放一边再配置 |
| 文档 | `THIRD_PARTY_NOTICES.md` 的包数改为实际的 599 个（原写 536），无 LICENSE 文件的为 15 个；`ISHImageService.m` 补 `profileIsSRGB` 原型 |
| 验收 | 构建通过；Node 单元测试 163/163（`tests/fetch`、`tests/step19`、`tests/subprocess`、`tests/fs-fence`），路径单元 21/21；模拟器上第 19 单 14/14、子进程 12/12、step7 6/6、step8 4/4、step9 5/5、客户机围栏 3/3。证据在 `logs/must-fix/` |
| 未解决 | 真机未测；测试开关仍在产品构建里（普通安装不会打开，发安装包前要去掉）；App 内没有法律文本 |

### P-38 许可页面现状、分发检查与对应源码边界

`ec86b85` 已增加“关于与许可”页面，并将 `LICENSE`、
`THIRD_PARTY_NOTICES.md`、`RootfsPackages.md` 打进 App。P-37 的
“App 内没有法律文本”是此前的历史状态。

| 项 | 内容 |
|---|---|
| 许可资源 | 额外打包整个 `LICENSES/`；关于页显示两份 iSH 说明及已补入的 npm、客户机正文 |
| npm | 裁剪后逐包检查根目录许可文件或精确版本的补充正文，默认报告缺件并警告 |
| 客户机 | 按完整 apk 记录生成名称、版本、许可证和源包四列；缺正文时默认仍生成表格和镜像，不完整的数据库捕获仍停止导出 |
| 表达式 | AND/OR/WITH 不区分大小写；`custom:` 明确报告需人工核对的映射，不猜许可证，默认仍保留草稿表 |
| 旧产物 | Xcode 复查 npm 和客户机材料、镜像与数据库哈希、展示清单；默认 Debug（含模拟器）只警告 |
| 分发 | 必须以 `DSH_REQUIRE_NOTICES=1` 获取 payload、生成镜像，并作为构建设置传给 `xcodebuild`；Release 配置、install/archive 动作也自动严格检查 |
| 源码 | 关于页只承诺仓库含 App 和构建脚本；镜像 `alpine-3.21.0-2e1ec684ab529225`（0.2.1 build 21、22 所带）的客户机对应源码归档已于 2026-11-13 发布在公开仓库 Releases（标签 `guest-sources-alpine-3.21.0-2e1ec684ab529225`），重建镜像后需另出一份 |
| 待补 | 两份 LICENSES 子目录说明只列收集要求，没有伪造上游正文；旧镜像须在分发前重建，默认开发不受此限制 |
| 应用后验证 | `python3 -B -m unittest discover -s tests/licenses -p 'test_*.py'`；补齐材料并重建后，在关于页核对各许可正文 |

### P-39 客户机内核隔离加固（iSH 补丁 0004–0018）

审查发现客户机里一条系统调用就能让宿主 App 崩溃，或越界读写宿主内存。下列补丁按 `ish/patches/` 的编号由 `ish/scripts/fetch-sources.sh` 重放；`--check` 可验证。重放改用 `git apply --index`，补丁新增的客户机回归测试计入树摘要，重置时一并清理 `tests/regress`。

| 补丁 | 修的问题 |
|---|---|
| 0004 | eventfd、epoll、socket 上的 `pread`/`pwrite` 调空函数指针；改为返回 `ESPIPE`，并修 `pwrite` 的缓冲区泄漏 |
| 0005 | 在 `/proc`、`/dev/pts`、tmpfs 下 bind UNIX socket 调空的 `mknod`；改为 `EPERM`，只在 `ENOENT` 时创建 |
| 0006 | 卸载 tmpfs 走到 `TODO()` 直接 abort；改为返回 `EBUSY` 并保留挂载 |
| 0007 | 对 `PROT_NONE` 页做系统调用复制时宿主故障；改为 `EFAULT`，缺页补映射不再放开保护页 |
| 0008 | `close_range` 有符号裁剪：`closefrom` 一个都不关，大 `first` 负下标访问 |
| 0009 | `rt_sigaction` 信号编号无下界，负数越界读写 `sighand->action` |
| 0010 | 设备主次号未限界的分派表访问，PTY 槽位差一 |
| 0011 | 用户地址区间回绕被当作复制成功，48 位以上地址别名 |
| 0012 | `user_read_string` 未读到结尾仍返回成功 |
| 0013 | `readv` 短读后复制未初始化宿主堆 |
| 0014 | 文件偏移校验与 tmpfs 读写越界 |
| 0015 | `clone`/`clone3` 退出信号可为 0–255，子进程退出时越界读写信号表 |
| 0016 | `timer_create` 信号编号未校验；无效线程路径漏解 `pids_lock` |
| 0017 | `getsockname` 长度 0 或 1 时下溢写宿主栈 |
| 0018 | `recvfrom` 按请求长度而非实际长度写回，泄露未初始化堆 |

| 项 | 内容 |
|---|---|
| 未纳入 | SCM_RIGHTS 校验、`clone` 失败回滚、`sendto` 长度上限、停用二进制级原生卸载四项，审查后仍需修改 |
| 验证 | 宿主侧编译和现有回归；新增的 `tests/regress/*.c` 需要 aarch64 musl 工具链，在客户机里执行 |

## 十六、rc.5 升级：逐文件核对与补丁移植

本次将 DSH 和 agent-team profile 从 **0.2.1-rc.2（历史基座）**升到
**0.2.1-rc.5**。原包清单、锁文件逐字节复制到 `$TMPDIR`，在其真实路径下
执行官方源 `npm ci --ignore-scripts`；两个输入安装前后完全一致。npm 缓存
始终指向本工作树 `.npm-cache`，没有运行包的生命周期脚本。宿主为 Node
v24.10.0、npm 11.17.0。最初带 `/var` 别名的 `--prefix` 路线使 npm 对根包
身份误判；改为临时目录的真实工作路径后，原锁文件直接安装成功，没有改写
任何上游版本来凑基线。

逐文件检查内容 SHA-256、文件/软链接类型、链接目标及可执行位：干净安装
63,625 个文件，原仓库 27,605 个；**14 个内容改动、0 个新增、36,020 个裁剪**。
14 个改动全部可由 P-1 与原有三个脚本在内存中逐字节复原，未发现未登记的
内容补丁。每个目标的旧/新上游及补丁后哈希见
[`payload/rc5-upgrade-audit.json`](payload/rc5-upgrade-audit.json)。完整逐文件
原始清单保留在本地忽略目录 `work/rc5-upgrade/rc2-comparison.json`；复现裁剪
只需已提交的 `payload/ios-pruning.json`，无需该临时清单。

### 每处内容补丁的处理

下表路径均相对 `payload/node_modules/`。

| 文件 | 登记 | rc.5 处理 |
|---|---|---|
| `@deepseek-ai/dsh-app-boot/lib/index.js` | P-1 | 上游文件未变，原样重打 `requireInternal`；仍有 5 个内部模块调用 |
| `@deepseek-ai/dsh-tools/lib/index.js` | P-4 | 上游文件未变，重打原有 3 类 Unicode 正则替换 |
| `@deepseek-ai/dsh-tools/lib/types/py-types.js` | P-4 | 上游文件未变，重打原有 3 类替换 |
| `@deepseek-ai/dsh-llm-deepseek/lib/index.js` | P-4 | 上游文件有变化，原替换仍精确匹配；只重打文件 id 边界正则，保留其它上游变动 |
| `@js-temporal/polyfill/dist/index.esm.js` | P-4 | 上游文件未变，重打年号清洗正则 |
| `@deepseek-ai/dsh-client-ui-conversation/lib/client.js` | P-11 HEIC | 上游 bundle 有变化，两处 composer 判定仍精确匹配；重打，不回写整个旧 bundle |
| `@deepseek-ai/dsh-api-session-controller/lib/typert.host.js` | P-11 HEIC | 上游文件未变，重打输入及能力报告，不放宽存储输出 |
| `@deepseek-ai/dsh-api-session-controller/lib/typert.remote-client.js` | P-11 HEIC | 同上 |
| `@deepseek-ai/dsh-commands/lib/typert.host.js` | P-11 HEIC | 上游文件未变，重打命令附件输入 |
| `@deepseek-ai/dsh-commands/lib/typert.remote-client.js` | P-11 HEIC | 同上 |
| `@deepseek-ai/dsh-subagent/lib/typert.host.js` | P-11 HEIC | 上游文件未变，重打子代理图像输入 |
| `@deepseek-ai/dsh-subagent/lib/typert.remote-client.js` | P-11 HEIC | 同上 |
| `@deepseek-ai/dsh-tool-fs/lib/index.js` | P-11 HEIC | 上游文件未变，重打 `.heic` / `.heif` 扩展名表 |
| `@deepseek-ai/dsh-timeout/lib/index.js` | P-28 | 上游文件未变，原样重打冻结时间扣除，6 处脚本替换 |
| `@earendil-works/pi-schema/dist/formats/typebox/idn_email.js` | P-4 扩展 | 新依赖中的 1 个正则；用 Unicode 16.0 静态区间替换属性转义 |
| `@earendil-works/pi-schema/dist/formats/typebox/idna/pattern/pattern.js` | P-4 扩展 | 新依赖中的 12 个正则；保持 ASCII、类别、脚本属性的原有成员集合 |

旧内容补丁没有被上游修复而作废，也没有必须改写旧替换上下文的条目。
本次改写的是 **P-4 补丁脚本的覆盖范围**，新增 13 个字面量替换，另使缺文件
或模式不匹配返回非零。它们来自 `pi-ai` 的 `pi-schema/formats` 导入链，
保留属性转义会在无 ICU 的运行时解析这些模块时失败。新增静态表覆盖 16
种 Unicode 属性，宿主上逐属性遍历全部 1,114,112 个码点与原正则对照相同。
这不证明设备上的 NFC 归一化完整，设备 shim 的原有限制仍在。

### 登记与实物对照的差异

- **P-2、P-3 原登记有误**：对应文件与干净 rc.2 逐字节一致，rc.5 也继续自带
  `--expose-internals` 分支。保留兼容性检查，撤销“本地补丁”的归属；没有
  删除实际代码，也不能说是本次上游才修好。
- **裁剪未完整登记**：补登 `payload/ios-pruning.json`。14 个包根、239 条路径
  和 `.d.ts` / `.d.cts` / `.d.mts` / `.map` 后缀规则，在旧基线上恰好覆盖
  36,020 个缺失文件，既无漏项，也无误裁。包括嵌套 Zod 测试源码、原有
  `build/` 裁剪和 `node-addon-system` 二进制；保留它的 JS shim。未将所有
  `.ts` 源文件一概移除。`scripts/prune-payload-ios.py` 可重放，移动到忽略的
  `work/pruned-payload-*`，可恢复，第二次执行为 0 个文件。
- **HEIC 的旧 2c 检查会误报**：全文件 grep 同时命中应当放宽的输入镜像。
  现改用 `node scripts/heic-boundary-unit.mjs`，运行真实生成 codec 并只遍历
  RPC 结果的存储输出枚举；36 个输入检查、6 个实际存储输出校验和 2 个存储输出枚举通过。
- **许可文档引用了不存在的公开导出脚本**：本私有仓库确实跟踪 payload。
  `THIRD_PARTY_NOTICES.md` 与 npm 许可待补表已按现有 602 包更新。新增
  `pi-schema` 的组件许可仍保留，包本身的完整许可列为待补，未伪造正文。

### 本次可运行的验证

三份 `scripts/patch-payload-*.py` 均执行成功。首次原补丁为 i18n 4 文件/9
处、HEIC 8 文件/9 次改写、timeout 1 文件/6 处替换；扩展 i18n 又改 2 文件/13
处。最终重跑 i18n 的 21 条规则、HEIC 的 9 条规则和 timeout 均已应用，
没有 missing 或 pattern_not_found。

```bash
python3 -B scripts/prune-payload-ios.py
python3 -B scripts/patch-payload-i18n.py
python3 -B scripts/patch-payload-heic-media-type.py
python3 -B scripts/patch-payload-frozen-timeout.py
node scripts/unicode-property-unit.mjs
node scripts/heic-boundary-unit.mjs
```

指定 Node 测试：265 tests、6 suites、265 pass、0 fail、0 cancelled、0 skipped、
0 todo。其余输出保留原样如下：

```text
boot runtime checks passed: active
boot runtime checks passed: background
boot runtime checks passed: returned
boot runtime checks passed: recovery
boot state checks passed
52 Foundation redaction cases, fallback copies and bridge checks passed
21/21 path-unit checks passed
67/67 checks passed
Ran 21 tests
OK
16 Unicode classes x 1114112 code points and 8 IDN format cases passed
36 runtime HEIC/HEIF/SVG input checks, 6 stored-image codec checks and 2 output enums passed
pi-ai provider import passed
```

实际 npm 许可完整性检查退出 1，缺 16 项正文；这是与 21 项许可单元测试
不同的结果。完整日志在 `work/rc5-upgrade/`。未执行 xcodebuild、模拟器、
`build-*.sh` 或任何验收脚本。依赖自身的空白格式保持上游原样。

### 后续模拟器及真机重点

在实际 nodejs-mobile 上冷启动，检查 profile 组合、插件装载、普通及安全模式；
走真实模型适配器的工具 schema 校验，确认新 pi-schema 模块可以解析。再查
HEIC/HEIF 的相册输入、RPC、原生转码和 `read_image`，并回归工作区迁移、
子进程与文件路径、抽屉/输入框，以及禁用入口定制后各栏和会话视图的可达性。
后台冻结后超时预算需要
真机复验；宿主上的表检查和单元测试不能代替这些结果。worker bootstrap
仍是 P-1 已登记的未补分支，本 profile 继续不启用它。

### rc.5 后续：入口定制等待 pluginNavigation（仅改 iOS profile）

`profiles/ios-sim/cordis.patch.yml` 以 id 禁用 `entry-customization`。
rc.5 新增的 `dsh-client-ui-entry-customization` 硬注入 `pluginNavigation`，
但唯一提供者 `ui-plugin-manager` 已按 TASK-3 第 13 条禁用。该入口贡献的
浏览插件和 Creator 动作也不适合此配置；禁用它不撤掉侧栏、会话或右栏。
会话在没有 More 菜单贡献时保留常规视图标签，不按 More 菜单的宽度折叠。

没有改 payload，也没有提供空操作的假导航服务。单启管理器前端会挂上
Plugins 页和安装操作，并调用未启用的 `pluginManager` / `pluginRegistryProbe`
后端；`remote.*` 代理存在不等于后端可用，不能满足只启前端方案的前提。
配置属于每次启动重写的 `dsh-ios-profile` App 层，安全模式收起用户层时仍
生效；安全模式原有跳过清单及计数不变。

新增 `scripts/ios-profile-dependencies.mjs` 使用上游 `composeEntries` 合成
实际 bundle 顺序和安全模式 overlay，扫描全部 79 个 web 前端声明的硬注入、
嵌套注入、模块依赖及服务提供候选，并对照显式禁用的 Host RPC 命名空间。
这是源码检查，不能证明浏览器实际激活。普通 / 安全组合分别包含 63 / 62
个前端包，均未发现缺少候选提供者的注入；恢复旧配置会报告
`entry-customization -> pluginNavigation`。实验性语音输入也需要这个服务，
当前不在 iOS 组合内；终端前端与其服务提供者均已禁用。

测试：`tests/step19/*.test.mjs` 156 项通过；全量主机 Node 测试 275 项中
267 通过、4 因沙盒禁止监听 loopback 而失败、4 因未提供已构建 App 而跳过；
Python 许可单元测试 21 项通过。详细命令、同类依赖、证据和模拟器复验清单
见 `work/rc5-upgrade/HANDOFF-pluginnav.md`。未运行模拟器，不把这些结果
登记为 step19 全量验收通过。

## 十七、`web_fetch` 在 iOS 上大面积失败

### P-40 `web_fetch`：把 `dsh-web-fetch-http` 的 `import("undici")` 答成不依赖 WebAssembly 的传输（**不改 DSH 内部代码**）

| 项 | 内容 |
|---|---|
| 文件 | `sim/undici-hook.mjs`（新，ESM resolve hook）、`sim/undici-web-fetch.mjs`（新，被答成的模块）；`sim/ios-app-entry.mjs` 注册；`tests/fetch/undici-web-fetch.test.mjs`（新） |
| 症状 | 真机一个会话里 `web_fetch` 26 次调用失败 18 次，全部是 `Error: web fetch failed: TypeError: fetch failed`；所有 `http://` 网址必败，gov.cn、央视、腾讯新闻等失败，网易、新浪成功 |
| 原因 | 该包不走全局 `fetch`（所以 `sim/fetch-polyfill.cjs` 管不到），而是直接 `import("undici")`，好把"已校验为公网的那组地址"钉进 `Agent` 的 lookup。undici 解析 HTTP/1.1 用的 llhttp 是 WebAssembly，`--jitless` 下没有，报 `ReferenceError: WebAssembly is not defined`，被包成一句 `fetch failed`。能协商 HTTP/2 的站点不经过 llhttp，所以还能抓 |
| 做法 | hook 只在"导入方是 `dsh-web-fetch-http/lib/`、specifier 是 `undici`"时改答；替身导出该包用到的 `Agent` 与 `fetch`，底层是 `node:http(s)`。保留：钉死的 lookup 是唯一地址来源、Host 与 SNI 仍是原主机名、`redirect: 'manual'`、流式 body（字节上限仍然有效）、gzip/deflate/br 解码。不是自己建的 dispatcher（代理路由）原样交回真 undici |
| 与上游的一处差别 | 失败信息带上底层原因（`fetch failed: ECONNRESET …`）。上游只打印 `String(error)`，原因被吞掉正是这个问题难查的地方 |
| 开关 | `DSHPORTE_UNDICI_HOOK=0` 关 hook（回到原行为） |
| 已验证 | Mac 上 `node --jitless`：`tests/fetch` 15/15；用 payload 里真实的 `HttpFetchProvider` 端到端，关 hook 复现真机症状（6 个网址只有网易成功），开 hook 后 6 个全部 200 且正文正确。真机（iPhone 15 Pro Max，0.2.1 build 21 开发签名，2026-11-13）：同一会话重抓 20 次，无一次 `fetch failed`，18 次 HTTP 200，另 2 次是站点自身 403 与 PDF 类型不支持。模拟器 App 内未单独跑 |
| 升级后检查 | `grep -n 'import("undici")' payload/node_modules/@deepseek-ai/dsh-web-fetch-http/lib/index.js`（还在 = hook 仍必要；若它改用了 `Agent`/`fetch` 之外的导出，替身要补）。Node 换成带 WebAssembly 的版本（如 24.22.1 的 polywasm）后可评估撤掉 |
