# PROGRESS

每轮**追加**一节，不要重写历史。最新在最上面。

判定完成：改动 + 验证证据（命令与结果）+ 本轮记录，三者齐备。
全部做完时在文件第一行写 `DONE`。

---

## 第 1 轮 — 修真失败 + 清 207 个假红（已产出代码改动）

**结论先行**：测试基线从 `209 failed / 19105 passed` 修到 `1264 passed / 0 failed`。共 3 个独立缺陷，2 个是真 bug、1 个是测试环境定义问题。

| | 文件失败 | 测试失败 | 通过 | `(0 test)` 文件 |
|---|---|---|---|---|
| 修复前（带泄漏） | **209** | 3 | 19105 | 207 |
| 修复后（仍带泄漏） | **0** | **0** | **22471** | **0** |

最终验证：`pnpm run test` → **exit 0**，`Test Files 1264 passed | 12 skipped`，`Tests 22471 passed | 1 expected fail | 131 skipped`。日志：`.pi-glla/runs/test-final2.log`
注意最终是在 **`NODE_ENV=production` 泄漏仍然存在**的情况下全绿的 —— 这正是修复生效的证明。

### 缺陷 A：setupFile 顶层 `node:fs` import 让 207 个 jsdom 规格加载失败 —— 真 bug，已修

`scripts/test-proxy-environment.ts` 是全局 `setupFiles`，顶层 `import { globSync } from 'node:fs'` / `'node:path'`。
jsdom 规格也会加载这个 setupFile → vite 把 `node:fs` browser-externalize 成空 stub → `Error: No such built-in module: node:` → **该规格 0 test**（测试根本没跑）。

**修法**：`vitestConfigFiles()` 内改成 `await import('node:fs'/'node:path')`。`clearAmbientProxyEnv` 保持顶层（纯 `process.env`/`Reflect`，jsdom 安全）。
调用方 `scripts/test-proxy-environment.spec.ts`：`it.each` 在收集期求值拿不到异步结果，改为 `beforeAll` + 单用例内循环。

**验证**：`npx vitest run scripts/test-proxy-environment.spec.ts` → 4 passed。

### 缺陷 B：`browser-bundled-externals.spec.ts` 的 vite 构建断言失败 —— 测试缺陷，已修

根因：fixture 的 `mkdtempSync(join(tmpdir(), ...))` 在 macOS 得到 `/var/folders/...`，而 **`/var` 是指向 `/private/var` 的符号链接**。
spec 把 HTML 入口写成**绝对路径**（模拟真实 `apps/web/vite.config.ts` 的 `fileURLToPath`），vite 内部 realpath 后该路径落在 `root` 之外，rollup 拒绝相对 `fileName`：

```
RollupError: ... must be strings that are neither absolute nor relative paths,
received "../../../../../../../../private/var/folders/.../apps/web/index.html"
```

真实仓库在 `/Users/...` 下无符号链接，所以产品代码是对的。

**修法**：`fixture()` 对 mkdtemp 结果做 `realpathSync`（一行，所有 fixture 路径一起正过来）。
**验证**：`npx vitest run scripts/browser-bundled-externals.spec.ts` → 6 passed。

### 缺陷 C：`NODE_ENV` 泄漏 —— 测试环境定义问题，已修（且我第一次修错了）

宿主 shell 有 `NODE_ENV=production`，vitest 不覆盖它。

**我第一次的错误修法**：在 `test:` 里加 `env: { NODE_ENV: 'test' }`。**无效** —— `test.env` 只设置测试 worker 自己的 `process.env`，而 **vite 的模块解析发生在更早的配置/transform 阶段**，那时读的还是环境里泄漏的值。

**正确修法**：在 `vitest.config.ts` **模块顶层**直接 `process.env.NODE_ENV = 'test'`（`defineConfig` 之前）。

**决定性对照**（同样 5 个规格，都带泄漏）：

| 配置 | 结果 |
|---|---|
| 宿主 `NODE_ENV=production`，无修复 | ❌ 5 文件 0 test |
| 宿主 `NODE_ENV=production`，顶层钉死后 | ✅ **5 文件 / 213 tests passed** |

### 我这一轮犯的两个错（记录下来，避免下轮重蹈）

1. **把 207 个文件失败归因给 NODE_ENV** —— 错。NODE_ENV 只影响 17 个；207 个是缺陷 A。
2. **`test.env` 能钉死 vite 的解析环境** —— 错。它不够早，必须在 config 模块顶层设。

教训：**「同时改多处、然后看总数变化」不足以定位因果**。A 和 B 两个修复叠在一起时，我误以为 NODE_ENV 是主因。正确做法是一次只改一个变量，或像上面的 A/B 对照实验。

### 侦察结论：两个「看着该修」的 TODO 实际不该修

两个后台侦察（只读，未改任何文件）：

- **`settings/redact.ts:87` 的 `TODO(settings-wire-redaction)`（安全）**：`walk()` 只处理 `object`/`dict`/`array`，其余类型走 `default:` 原样返回。**但当前不可达**：全仓库非测试 `src/` 里唯一的 `role('secret')` 是 `web-search-deepseek/src/index.ts:64` 的顶层 `apiKey`，走 `object` 分支、被正确剥离。四个 shipped union（llm-deepseek、llm-pi-ai、permission-presets、ui-theme）都不包裹 secret。
  **建议：不改。** 在 `walk()` 里 throw 会打断四个正常工作的 union；真正的 fail-closed 该在 `register()`，那是 README 已记录的更大改动。

- **`hooks-*/` 的 `TODO(stop-loop-guard)`**：两个 bridge 是近乎逐行孪生（重复被 `jscpd:ignore` 有意围栏，不要顺手去重）。codex 提到的 `stop_hook_active` **不是能力差异**，CC 有同样字段（`hooks-claude-code/src/index.ts:344`），两边都硬编码 `false`。
  **建议：先做 stop-loop-guard。** 计数器放 `hook-protocol`（那里已拥有 sticky `stop`），按 agent/session 键、内存态。`cap` 必须是校验过的 `Config` 字段（仓库规则禁止硬编码 tunable），CC 的 8 是默认值。
  **注意**：现有测试**故意断言当前坏行为**，同 PR 必须一起改 —— `hooks-claude-code/tests/coverage-cases.ts:411,426` 和 `hooks-codex/tests/coverage-cases.ts:390,404`。

### 下一轮从这里继续

优先做 `BACKLOG.md` 的 **stop-loop-guard**（有明确 blast radius、无需新核心原语、侦察已给出最小形状）。
`settings-wire-redaction` 已判定不该改，可从队列移入「已评估/不做」。

## 第 0 轮 — 侦察与脚手架（人工/首轮）

**做了什么**
- 建立本循环：`TASK.md`（每轮指令）、`BACKLOG.md`（候选队列）、`loop.sh`（外层驱动）。
- 确认 `dsh --profile headless "task"` 是每轮的执行单元：新建 session、跑完、刷盘、exit 0=completed / 非 0=失败。

**侦察发现**
- 仓库干净：`master`，仅 `.pi-glla/` 与 `.pi-glla/runs/` 未跟踪。
- 935 篇已实现 Agent Note；TODO 均带具名 rationale（`TODO(name):`）。纪律很高的仓库。
- **基线测试是红的**：`209 failed | 1055 passed`（文件级），但**只有 3–4 个测试真正失败**。

**根因（已定位）**
`NODE_ENV=production` 在宿主 shell 环境里，vitest 不覆盖它 → 泄漏进测试进程。
- 直接后果：`packages/client/store/src/index.ts:170` 的 `devFreeze` 走 prod 分支提前返回 → 2 个断言失败。
- 大面积后果：约 200 个 `packages/client/**/*.client.spec.tsx` 报 `(0 test)`（加载期就挂了），以及 `scripts/browser-bundled-externals.spec.ts` 的 vite 构建断言失败。

**验证证据**
```
$ env | grep NODE_ENV
NODE_ENV=production

$ npx vitest run scripts/env-probe.spec.ts    # 探针
NODE_ENV="production"   MODE="test"   DEV=false

$ npx vitest run packages/client/store/tests/store.client.spec.ts
Test Files  1 failed (1) | Tests  2 failed | 18 passed      # 有泄漏

$ env -u NODE_ENV npx vitest run packages/client/store/tests/store.client.spec.ts
Test Files  1 passed (1) | Tests  20 passed (20)            # 无泄漏 → 全绿
```

全量对比（决定性证据）：

| | 文件失败 | 测试失败 | 通过 |
|---|---|---|---|
| 有 `NODE_ENV` 泄漏 | **209** | 3 | 19105 |
| `env -u NODE_ENV` | **1** | 1 | **22474** |

泄漏吃掉 208 个文件、3369 个通过的测试。

=> 定性：**环境泄漏，不是产品缺陷**。但 BACKLOG P0 第二条是它的根因修复。

**干净基线剩余的唯一真失败**
`scripts/browser-bundled-externals.spec.ts > follows shell workspace aliases, CSS assets and lazy imports without writing output`
—— vite 构建在 46ms 内失败，rollup `buildEnvironment` 抛错。无泄漏时依然失败，是**独立真 bug**，已加入 BACKLOG P0。
日志：`.pi-glla/runs/test-clean.log`

**下一轮从这里继续**
做 `BACKLOG.md` 的 P0 第一条或第二条。建议先做**第二条**（vitest 钉死 NODE_ENV）：改动小、可验证、一次修复一大片噪声，让后续轮次拿到干净基线。
第一条（`devFreeze` 判据）依赖第二条的结果才能正确验证，排在其后。

---

## 第 2 轮 — `TODO(stop-loop-guard)` ✅

**做了什么**
给 Stop hook 的强制续跑加了连续次数上限。原先无条件 block 会无限重开同一轮
（每次续跑本身又是一轮，同一 hook 还能再 block 它），两个 bridge 都没有上限。

- `hook-protocol` 新增 `createStopLoopCounts`：按 `(sessionId, turn)` 计数，
  只保留最高 key —— 一轮的续跑是背靠背的，不需要随会话增长的 map。
  内存态、不持久化：守卫防单轮失控，不是会话总量。
- 两个 bridge 各接 `stopLoopCap`（Config 字段，默认 8 = CC 自己的值），
  在 `turn-stopping` handler 里门控续跑；触顶放行 + logger 告警，不 throw。
- 顺带修掉 codex 的 `stop_hook_active` 硬编码 `false` —— 现在回报真实计数。
- 两个 bridge 原先**故意断言旧行为**的测试一并更新。
- 写了三语 Agent Note（`2026-09-15-stop-loop-guard.*`）。

**验证证据**
```
$ env -u NODE_ENV npx vitest run packages/hooks
Test Files  19 passed (19)
     Tests  215 passed (215)
```
含三条新用例，其中决定性的一条是端到端（走 Loader + 真进程）：
`an UNCONDITIONALLY blocking Stop hook stops forcing continuation at the cap`。

```
$ pnpm run typecheck
exit 0
```

**已提交**：`4a4eee8020`（本轮）、`34a05f534c`（上轮测试基建）、`2915bd3102`（.gitignore）。
工作区干净。

**注意（流程教训）**
本轮 agent 自己选了 `npx oxlint packages/hooks` 做验证，**绕过了
`scripts/run-oxlint.ts` 的线程上限**，吃满 14 核跑满 5 分钟超时被杀、零输出，
之后又卡在别处，最终没走到第 6 步「记账」就被人工中断。
代码本身是完整且验证过的，但 PROGRESS 缺账（这段由人工补写）。
`TASK.md` 已补上 lint 正门与「自选命令超时 ≤120s」的约束。

**下一轮从这里继续**
P1 只剩 `TODO(hook-continue-false)`（需要新的核心原语，见 BACKLOG 说明）。
也可以转去 P0 剩下的 `devFreeze` 死代码判定，或 P2 那三条契约核对。
