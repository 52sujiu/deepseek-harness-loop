# deepseek-harness-loop

让 AI agent 自己迭代开发 `deepseek-harness` 的外层驱动循环。

每轮起一个**全新的 headless session**，只给一个任务 + 磁盘上的进度文件；轮次之间不共享上下文，状态靠文件交接。这样单轮爆掉不会污染下一轮，也让每轮可以独立复盘。

## 用法

放进目标仓库根目录：

```
<repo>/.pi-glla/loop/
  loop.sh       # 外层驱动
  TASK.md       # 每轮的固定指令（改这个来换项目）
  BACKLOG.md    # 候选队列，每轮取最上面一条
  PROGRESS.md   # 轮次交接状态，agent 每轮追加
```

然后：

```sh
# 默认 10 轮
./.pi-glla/loop/loop.sh

# 3 轮
MAX=3 ./.pi-glla/loop/loop.sh

# 只打印将发给 agent 的 prompt，不执行
DRY=1 ./.pi-glla/loop/loop.sh

# 单轮墙钟上限（秒），默认 1800
TASK_TIMEOUT=900 ./.pi-glla/loop/loop.sh

# 进度刷新间隔，默认 15 秒；设 0 关掉
PROGRESS_INTERVAL=5 ./.pi-glla/loop/loop.sh
```

前置条件：`pnpm`、本地 **WorkBuddy relay** 在 `127.0.0.1:8787` 上跑着（脚本启动时会探活，不通直接退出）。

## 模型是怎么定的

跑的是 `workbuddy` relay 上的 `deepseek-v4.1-flash`——和 TUI 里同一个模型，**不走官方 `deepseek-official`**。

### 为什么需要专属 DSH_HOME

先说两个实测结论：

1. **`headless` profile 没有 `--model` 参数**，`--help` 只有 `-h`。模型来自 settings 的 `agent-default-model` 段，而这份 settings 是**全局共享**的。
2. **`--patch` 覆盖不了它**，会被 settings 盖掉：

| settings `agent-default-model` | `--patch` 指定 | 实际请求的模型 |
|---|---|---|
| `deepseek-flash` | `deepseek-v4-pro` | **`deepseek-flash`** |
| 无该段 | `deepseek-v4-pro` | `deepseek-v4-pro` |

坑在于 `--dump-config` 只显示 composition entry，会**误报** patch 生效（显示 `v4-pro`，运行时用 `deepseek-flash`）。判定实际模型只能读会话日志——`sessions/**/session.v3.jsonl.zstd` 的 `model` 字段，或 system-prompt 的 `powered by the X model`。

所以循环自带一份 `DSH_HOME`（`.pi-glla/loop/home/`），首次运行生成：

```yaml
llm-pi-ai:
  providers:
    workbuddy:
      displayName: WorkBuddy (local relay)
      baseURL: http://127.0.0.1:8787/v1
      api: openai-completions
      apiKeyEnv: WORKBUDDY_API_KEY
      compat:
        supportsDeveloperRole: false
        supportsReasoningEffort: false
      models:
        - id: deepseek-v4.1-flash
agent-default-model:
  provider: workbuddy
  model: deepseek-v4.1-flash
```

凭证不复制，只按符号链接共享 `~/.dsh/.credentials.yaml`；`.gitignore` 排除整个 `home/`。顺带隔离了会话——循环跑挂不碰日常 dsh 状态。

### 三个会咬人的坑

**`pi-workbuddy` 在 headless 里不存在。** TUI 里那条路由叫 `pi-workbuddy`，但 headless 只认 `llm-pi-ai` 按 **settings key** 注册的名字 —— 这里就是 `workbuddy`。写成 `pi-workbuddy` 会 `NO_ADAPTER: no adapter registered for provider`。同一个 relay、同一个模型，只是路由名的层级不同。

**relay 不支持 reasoning effort。** 它声明 `supportsReasoningEffort: false`，所以 settings 里**不能**写 `reasoningEffort: max`——写了会 `UNSUPPORTED_REASONING_EFFORT` 直接启动失败。TUI 里能用 `max` 是因为它走的是另一条注入的路由。

**`apiKey` 不是 `apiKeyEnv`。** schema 只接受 `apiKeyEnv`（环境变量名）；写 `apiKey: local-relay` 会在请求时报 `no API key for provider`。脚本 export 了 `WORKBUDDY_API_KEY=local-relay`（本地 relay 的占位串，不是真密钥）。

切模型：删掉 `home/settings.yaml` 重跑，或直接改它。relay 还暴露了 `gpt-5.6-sol`、`kimi-k3`、`glm-5.3` 等 20 个模型，`curl http://127.0.0.1:8787/v1/models` 可以看全量。

## 压缩策略：无损（context-mode），不是官方默认

先说默认有多糟。DSH 出厂的 `compaction-basic` 是**八段式摘要**：让模型把对话"复述"成八个固定段落，而**工具输出没有自己的段落**——它只能以摘要模型恰好写下的散文形式存活。实测下来，真正说过的大部分内容在第一次压缩后就没了。

循环跑起来的是 `dsh-context-mode-compaction`，**直接重建对话而不是复述**：

| 来源 | 保留什么 |
|---|---|
| `user/message` | **整条**；超 1000 字符留首尾各 500，中间归档可检索 |
| `assistant/message` | 首尾各 200 字符；不足 400 字符整条保留 |
| `tool/result` | **只留一行索引**，从不复制原文——那行说明工具名、字节数、输出在哪 |

每个被裁掉的位置都留一个指针，指向可检索的 `source` 和它的 `seq`。所以 checkpoint 说的是**哪个事件丢了细节**，而不只是"有个归档存在"。

参数（比官方默认更激进）：

| 参数 | 本循环 | 官方默认 |
|---|---|---|
| `thresholdRatio` | 0.8 | 0.8 |
| `retainRatio` | **0.1** | 0.16 |

窗口 300k → **240k 触发**，最近 30k 原样保留，每次重写最旧的那 70%。（`retainRatio: 0.1` 是 myharness preset 的选择：少留一点原文，多换压缩收益。）

另有一层更早的压缩：`tool-result-pruner`，单个工具结果超 **8192 字符**裁成 头 4096 + 尾 1024。

### 怎么挂上去的

headless **不加载 agent preset**（`--dump-config` 的 87 个插件里没有 `agent-presets`），所以 myharness 里那行替换根本到不了 headless。改用 `--patch` overlay 复刻：

```yaml
- id: compaction-basic
  disabled: true

- insert:
    - id: cmc-compaction
      name: '<..>/dsh-context-mode-compaction/lib/types/index.js'
      config: { thresholdRatio: 0.8, retainRatio: 0.1 }
    - id: dsh-context-mode
      name: '<..>/dsh-context-mode/lib/types/index.js'
      inject: [tools, systemPrompt]
      config: { enabled: true }
```

**为什么是 `disabled` + `insert`，而不是直接改 `name`：** `--patch` 按 id 定位时不允许改 `name`，会报 `name mismatch for "compaction-basic" ... skipping`。上游 `wire.mjs` 之所以要写个脚本，就是因为它改的是 **preset 文件里的那一行**——那条路 headless 走不通。

**为什么用绝对路径：** patch 行用**裸包名**时从 harness base 解析，用户装的第三方包在 base 里不可见；用相对/绝对路径才按所在目录解析。脚本生成 overlay 时把两个包的绝对路径写进去，并在启动前逐个 `-f` 校验，缺包直接退出而不是跑到一半才发现。

配套的归档器 `dsh-context-mode` 是必需的——**策略本身能独立工作，但它写的 Archive Index 只有归档器在跑时才解析得开**。归档器只依赖 `tools`/`systemPrompt` 这类通用服务，没有 TUI 专有依赖，所以 headless 挂得上。挂上后循环会话里会出现 8 个 `ctx_*` 工具（`ctx_search`、`ctx_index`、`ctx_execute`…）。

## 实时进度

跑起来就在**原地刷一行状态**，不用另开终端 `tail -f`：

```
   ⏳ 第1轮 45s · 12行 · reading packages/core/agent-loop/src/index.ts
```

左侧是已运行秒数和日志行数，右侧是**从日志尾部抓的当前动作**——所以你能看出 agent 真在干什么，而不是干等一个计时器。默认每 15 秒刷一次，`PROGRESS_INTERVAL` 可调，设 0 关掉。

进度写在 **stderr**、日志走 stdout：两者共用 stdout 会互相截断。非 TTY（重定向到文件、CI）时自动关闭，否则 `\r` 重画会在日志里糊成一团。

配合 `tee` 的行缓冲（`stdbuf -oL`），`tail -f .pi-glla/loop/logs/iter-1.log` 也能实时看到内容——而不是等一轮跑完才落盘。

## 终止条件

任一命中即停：

| 条件 | 说明 |
|---|---|
| 跑满 `MAX` 轮 | 正常结束 |
| `PROGRESS.md` 首行是 `DONE` | agent 自己宣布做完 |
| `PROGRESS.md` 连续两轮未增长 | 干了活但没记账 = 空转，及时止损 |
| 连续两轮非零退出 | 环境坏了，再跑也是烧钱 |
| 单轮超时（rc 124） | 计入失败，连续两次即停 |

## 输出

```
.pi-glla/loop/logs/
  iter-N.log     # 该轮完整 stdout/stderr
  iter-N.diff    # 该轮结束时的 git diff（改动互相污染时用来归因）
```

每轮存一份 diff 是刻意的：迭代到第 5 轮时，前几轮的改动会混在一起，没有逐轮 diff 就无法判断哪个回归是哪轮引入的。`TASK.md` 禁止 agent 自己 commit，所以改动都留在工作区，由人审完再决定。

## 设计取舍

- **不做并发**：`mkdir` 原子锁保证单实例，第二个进程直接退出。并发跑会互相覆盖 `PROGRESS.md`。
- **不自动 commit/push**：全自动落库意味着没人看过就进历史。每轮产出 diff，人工过一遍。
- **无进展检测看文件长度**，不看哈希：只判断"有没有记账"，不判断记的内容对不对——那是人的事。
- **`unset NODE_ENV`**：宿主 shell 的 `NODE_ENV=production` 会泄漏进 vitest 并翻转 dev/prod 分支，导致大量 client 规格 `(0 test)`。这是踩过的坑，不是防御性冗余。

## 已知坑

**macOS 自带 bash 3.2 在双引号内，变量后紧跟多字节字符会把该字符首字节并入变量名**：

```bash
echo "未增长（$size），停"   # ✗ bash: size�: unbound variable
echo "未增长（${size}），停" # ✓
```

GNU bash 4/5（Linux/CI）不受影响，所以这个 bug 只在开发机上静默发作，`set -u` 下直接终止整个循环。**所有变量引用一律加大括号**，或干脆别让变量后面跟中文标点。

## License

MIT
