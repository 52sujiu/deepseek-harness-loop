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

---

## 第 3 轮 — P0 `devFreeze` 死代码判定 ✅（结论反转）

**做了什么**
判定 BACKLOG P0 最后一条。原判据说「devFreeze 的运行时 NODE_ENV 判断在产物中是
死代码，构建期已用 define 静态消除」。**侦察后结论是反的：不是死代码，是生产 bug。**

根因（本轮实测，非推断）：
- `tsdown.client.ts` 有**两个**浏览器构建面。动态面 `clientConfig` 声明了
  `define: { 'process.env.NODE_ENV': ... }`；静态面 `staticLinkedConfig`
  （`staticLinked` 用于 client/store、ui-slots、ui-primitives、ui-dockkit、web）
  **一个 define 都没有**。
- 在 `platform: 'browser'` 下 omit define 不是中性的：rolldown 把未定义的
  `process.env` 换成 `{}`，于是 `process.env.NODE_ENV === 'production'`
  折叠为 `false` → **开发分支留在了生产产物里**。
- 即 `devFreeze` 发布为无条件 `freeze(value, true)`：每个构建出的 client 包
  在生产环境仍对整值 store 状态做深冻结，而源码本意是廉价 `return value`。

决定性实验（同一份源码，只改 NODE_ENV）：
```
修复前： NODE_ENV=development 构建 == 生产构建，逐字节相同（6321 B）
         两者 devFreeze 都是 `return freeze(value, true)`
修复后： 生产构建 6.30 kB → `return value`
         dev  构建 6.32 kB → `return freeze(value, true)`
```
注：BACKLOG 说「产物里 process.env 出现 0 次」属实，但把「0 次」读成
「已被 define 静态消除」是误读——真相是浏览器平台默认把它清空后折叠错了方向。

**修法（最小 diff，3 文件）**
- `browserEnvironmentDefines()` 抽出为一个 helper（动态面原本的内联块），
  两个面都引用它 → 浏览器构建环境只有一个归属，第三个面无法再抄一半漏一半。
- `clientConfig` 内联块改为调用；`staticLinkedConfig` 增 `define: ...`。
- `store/src/index.ts` 的 `devFreeze` 只是补 JSDoc 说明它是构建期决定（源码不动）。
- 新增自检：`scripts/client-bundle-purity.spec.ts` 断言**两个**浏览器面都带
  `process.env.NODE_ENV` / `import.meta.env.MODE` / `import.meta.env`。
- 三语 Agent Note（`2026-09-15-static-face-environment-defines.*`，bug-fix）。
  已做 supersession 审计：`grep` 全 implemented/proposed 树，无同机制旧 note。

**验证证据**
```
$ env -u NODE_ENV npx vitest run packages/client/store \
    scripts/client-bundle-purity.spec.ts \
    scripts/client-build-environment.client.spec.ts scripts/client-bundle-css.spec.ts
Test Files  4 passed (4)
     Tests  51 passed (51)

$ env -u NODE_ENV pnpm run test:gui
Test Files  378 passed (378)
     Tests  5425 passed | 1 skipped (5426)

$ pnpm run typecheck            # exit 0（全量 build 复现了正确产物）
$ pnpm run verify-translation-pairing   # 810 pair(s), all consistent
$ pnpm run verify-agent-note-format     # 345 note(s), all conform
```
**自检是决定性的**（不是自证）：临时移除静态面的 `define` 后重跑，
新用例报 `FAIL ... substitutes NODE_ENV on BOTH browser faces`（1 failed | 19 passed）；
恢复后 20 passed。

**为什么不删源码里的运行时判断**（BACKLOG 原本问的）
它在源码面测试通道下仍是真实的运行时守卫，且它在构建期选择 dev/prod 分支——
这正是构建本身该做的决定。删掉它等于把「生产也永远深冻结」变成明示意图。

**已提交**：本轮未 commit（按 TASK.md，改动留工作区由人审）。

**下一轮从这里继续**
P0/P1 队列已空。剩 P2 三条契约核对：
- `packages/workspace/workspace/src/index.ts:152` `title` 参数（死参数，可直接删，
  最低风险，建议先做）；
- `packages/settings/settings/src/index.ts:78` `ns`→`namespace` 改名（跨模块，需评估面）；
- `packages/guard/timeout-policy/src/index.ts:6` FIXME 降级判定。
另 P3：`packages/e2b/**` 8 处 TODO 分类；`pnpm run duplication` 跑一次。

---

## 第 4 轮 — P2 `WorkspaceRegistry.create` 的死 `title` 参数 ✅

**做了什么**
判定并执行 BACKLOG P2 第一条（PROGRESS 上轮指定的最低风险项）：删掉
`WorkspaceRegistry.create(path, title?)` 的 `title` 参数——源码 TODO 自己提议的改法。

**先理解再动手（侦察结论，全部实测）**
- 全仓库非测试调用点：`webhook/src/session.ts:130`、`api/workspace-controller/src/commands.ts:46`、
  `apps/web/tests/*.e2e.ts` 三处——**无一传第二个实参**。
- `title` 的唯一消费者是测试；生产侧重命名走 `entity.setTitle()` / `workspace.rename`。
- 该参数在归档 note `2026-07-31-one-route-to-add-a-workspace` 里已失去最后一个生产调用方
  （gateway 的 create-by-name 分支删除时）。
- README 对的 Dev Note「开放：`create(path, title?)`」正是这个待决项，本轮把它做完即删除。

**改动（5 文件，全在 `packages/workspace/workspace/`）**
- `src/index.ts`：`create`/`createCanonical` 各去掉 `title?`，`title ?? defaultWorkspaceTitle(canonical)`
  收敛为 `defaultWorkspaceTitle(canonical)`；删掉那段 TODO 与其 `@param title` 子句；
  `create` 的 JSDoc 改成陈述新契约（标题一律取自路径末段）。
- `tests/workspace.spec.ts`：三处传 title 的调用点去掉实参；
  「duplicate display name」用例原先靠显式 `'Shared'` 造重名，改为两个同末段目录
  （`named-first/shared`、`named-second/shared`）——这样它仍然真正测「不同 canonical path
  可重名」，而不是靠一个已删除的参数。
- `README.md` / `README.zh.md`：示例去掉第二实参；删除已完成的 Dev Note 开放项；重录侧车。

**验证证据**
```
$ env -u NODE_ENV npx vitest run packages/workspace/workspace \
    packages/api/workspace-controller packages/webhook
Test Files  14 passed (14)
     Tests  168 passed (168)

$ pnpm run typecheck                  # exit 0
$ pnpm run test:docs                  # 16 passed, 0 failed
$ pnpm run verify-translation-pairing # 810 pair(s), all consistent
```
**自检是决定性的**：新增用例断言 `WorkspaceRegistry.prototype.create` 的 arity 为 1
（并断言标题确实取自路径）。临时把 `title?` 加回去重跑 →
`FAIL ... expected [AsyncFunction create] to have a length of 1 but got 2`（1 failed | 49 passed）；
还原后 50 passed。

**为什么不写 Agent Note**：这是机械的局部编辑（删死参数 + 同步文档/测试），
AGENTS.md 明确豁免；该决策的理由已由归档 note 拥有，且本轮不改任何行为。

**已提交**：本轮未 commit（按 TASK.md，改动留工作区由人审）。

**下一轮从这里继续**
P2 还剩两条：
- `packages/settings/settings/src/index.ts:78` `ns`→`namespace` 改名（跨模块，需先评估调用面）；
- `packages/guard/timeout-policy/src/index.ts:6` FIXME（`dsh-timeout-guard` 改名）降级判定。
另 P3：`packages/e2b/**` 8 处 TODO 分类；`pnpm run duplication` 跑一次。

---

## 第 5 轮 — P2 `settings` 的 `ns`→`namespace` 改名 ✅（判定：不改，退役该 TODO）

**做了什么**
判定 BACKLOG P2 第一条（上轮指定的 `ns`→`namespace` 改名）。**侦察后结论是否定的：不改，
并把该 TODO 与其 README Dev Note 条目一并退役。** 理由不是"懒得改"，而是 TODO 的前提
——"`ns` 是需要纠正的词汇缺陷"——被仓库自身的一致性证据推翻。

**先理解再动手（侦察结论，全部实测）**
- **`ns` 是仓库通用惯用名**，不是 settings 的孤例：`client/locale/src/client/index.ts` 用它 12 次、
  `client/ui-slots/src/renderer.ts` 2 次，且已固化进两份**生成**产物
  （`tool-cordis/src/api-catalog.ts`、`cordis-client-runner` 的 catalog，共 4 处签名文本）。
- **该改名会改序列化协议，而不只是标识符**。`ns` 在本 seam 上是线上字段：
  - `SettingsNamespaceView.ns`（`types.ts:35`，客户端读的 JSON 字段）；
  - settings-controller 的 RPC 请求 schema `z.object({ ns: z.string().min(1) })`（`index.ts:33`）；
  - `@Remote update/replace/mutate(ns, …)` 的**参数名**，被生成目录渲染成签名文本。
- **面：47 个文件 / 8 个包**，外加双语 README、子系统文档、1 份生成产物、Cordis 事件签名
  （`settings/updated(ns, …)`、`settings/document-updated(ns, …)`）。
- README 自己已把它归入 **Dev Note「尚未决定的开放方向」**（显式声明非权威）。
- 线上字段**已有覆盖**：`settings-controller.host.spec.ts:125,164,191` 断言 `view?.ns`，
  客户端 mirror/scope 规格也断言 `ns:`。所以"线上契约无保护"这个理由也不成立。

**改动（5 文件）**
- `src/index.ts`：删掉 `SettingsDescriptor` 上那两行 TODO。
- `tests/settings.spec.ts`：新增 `keeps the descriptor key as ns`，并写清判定理由。
- `README.md` / `README.zh.md`：从 Dev Note 的开放方向列表里移除该条（它已不再是"未决"），
  重录侧车 `README.i18n.yaml`。

**验证证据**
```
$ env -u NODE_ENV npx vitest run packages/settings packages/api/settings-controller \
    packages/client/ui-settings packages/client/ui-settings-models \
    packages/client/ui-settings-plugins packages/client/ui-permission-presets \
    packages/extensions/tool-cordis
Test Files  39 passed (39)
     Tests  679 passed (679)

$ pnpm run typecheck                  # exit 0
$ pnpm run test:docs                  # 16 passed, 0 failed
$ pnpm run verify-translation-pairing # 810 pair(s), all consistent
```

**自检是决定性的**（我第一版写错了，已修正，值得记一笔）
第一版自检用**类型级**断言（`SettingsDescriptor['ns'] extends SettingsNamespace`）并声称
"改名即 typecheck 失败"。实测**它抓不到**：包级 `tsconfig.json` 的 `include` 只有 `src`，
`tests/` 根本不在 host/client 两个 typecheck 面里 —— 那条断言从未被编译，是死重。
修正为运行时断言 `Object.keys(descriptor)` 必须含 `ns` 且不含 `namespace`（即线上投影会拷贝的
自有键）。决定性对照：对源码施加一次**完整**改名（接口成员 + `describe()` 里的字面量键）后重跑 →
`FAIL … expected undefined to be 'ui-theme'`（16 failed | 73 passed）；还原后 89 passed。
**教训：先确认你的自检真的会被执行**；放在不被任何 tsconfig include 的文件里的类型断言等于没写。

**顺带修掉上轮遗留的生成产物陈旧**（同一主题的收尾，非新主题）
`pnpm run verify-cordis-api` 报 `api-catalog.ts`、`docs/subsystems/workspace.md`、
`workspace.zh.md` 陈旧。经比对，delta **恰好且仅有**第 4 轮删掉的 `create(path, title?)`
（`workspace.md:342` 仍写着 `title?: string`）——是第 4 轮的未完成收尾，与本轮 settings 改动无关。
跑 `gen-cordis-api.ts` 重新生成（11 行增删，内容见上），使第 4 轮真正闭环。
现 `verify-cordis-api` → `97 generated file(s)/region(s) are up to date`。

**为什么不写 Agent Note**：本轮不改任何行为与契约，只是退役一个已被证据否定的 TODO 并补一条
断言；AGENTS.md 豁免机械局部编辑。判定理由已就地写在源码注释、规格注释与本节。

**已提交**：本轮未 commit（按 TASK.md，改动留工作区由人审）。

**已知环境问题（非本轮造成）**
无新增。上轮的 `verify-cordis-api` 陈旧已在本轮修掉。

**下一轮从这里继续**
P2 只剩一条：
- `packages/guard/timeout-policy/src/index.ts:6` FIXME（`dsh-timeout-guard` 改名）降级判定。
  建议用本轮同样的方法：先确认"改名"是否真有收益、以及 `FIXME` 是否已名不副实，
  是则降级成说明，否则给出理由退役。
另 P3：`packages/e2b/**` 8 处 TODO 分类；`pnpm run duplication` 跑一次。

---

## 第 6 轮 — P2 `dsh-timeout-guard` FIXME 退役 ✅（判定：FIXME 陈旧，已删除）

**做了什么**
判定 BACKLOG P2 最后一条：`packages/guard/timeout-policy/src/index.ts:6` 的 FIXME 要求
"在首个 tagged release 前确定 `@deepseek-ai/dsh-timeout-guard` 改名"。**侦察后结论：这个
FIXME 是陈旧的，改名早已发生且方向与 FIXME 的暗示相反——已删，并补一条决定性自检。**

**先理解再动手（侦察结论，全部实测）**
- **改名台账已把它记为既定事项，且裁定的是当前这个名字。**
  `.agents/notes/archived/architecture/2026-08-11-repository-naming-contract-and-rename-ledger.md:259`
  记录：`@deepseek-ai/dsh-timeout-policy` → `@deepseek-ai/dsh-tool-call-timeout-policy`，
  并明确"keep its `guard/timeout-policy/` directory and plugin id `timeout-policy`"。
  即 **FIXME 假设的 `dsh-timeout-guard` 方向从未被采纳**，采纳的是全限定 `tool-call` 限定词。
- **package.json 与代码已与台账一致**：`package.json:2` 名字、`src/index.ts:11` 的 `@module`
  标记、`name = 'timeout-policy'` 插件 id，三者都已是台账裁定的形态。**无需任何改名动作。**
- **同批的 sibling FIXME 早已随改名删除，本轮是最后一个漏网的。**
  `2026-07-29-package-regrouping.md:41` 原文："`@deepseek-ai/dsh-sdk-jsonrpc-server` names the
  JSON-RPC server half … `@deepseek-ai/dsh-tool-call-timeout-policy` names the exact operation
  limited by the policy while keeping its `guard/timeout-policy/` home. **Their release-blocking
  `FIXME` markers are removed with those renames.**"
  实测：`packages/sdk/server/src/index.ts:9` 的 `@module @deepseek-ai/dsh-sdk-jsonrpc-server`
  已无 FIXME；全仓库 `grep -rn 'dsh-timeout-guard'` 只剩本包一处 → **本轮清掉最后残留**。
- **该归档 note 自己规定了删除程序**（`:77`）："a FIXME that later proves wrong must be removed
  explicitly with rationale, never silently dropped." 本轮正是执行这条：显式删除 + 就地写理由。
- **README 早就自己声明它是陈旧的**：`README.md:133` / `README.zh.md:133` 的 Dev Note 原文写着
  "so the FIXME is stale pending a code cleanup"。本轮就是把那句"待清理"兑现。
- 无自动门禁统计此类标记（`grep 'release-blocking' scripts/*.ts` 无输出），
  所以删除必须靠自检钉住，不能指望 CI 兜底。

**改动（5 文件）**
- `src/index.ts`：FIXME 三行 → 说明性 JSDoc，写清名字已由台账裁定并给出两个链接。
  **措辞刻意不复述被否定的旧名**——否则新注释自己会把 `dsh-timeout-guard` 字符串带回源码。
- `tests/timeout-policy.spec.ts`：新增 `pins the settled package name and carries no rename marker`。
- `README.md` / `README.zh.md`：Dev Note 由"FIXME 陈旧待清理"改为"无未决命名问题"。
- `README.i18n.yaml`：重录侧车。

**验证证据**
```
$ env -u NODE_ENV npx vitest run packages/guard/timeout-policy
Test Files  1 passed (1)
     Tests  13 passed (13)

$ pnpm run typecheck                  # exit 0（并据此重建了 lib/types/index.d.ts）
$ pnpm run test:docs                  # 16 passed, 0 failed（含 translation pairing 门禁）
```

**自检是决定性的**（沿用第 5 轮教训：先确认它真的会被执行）
断言放在 `tests/` 下、由 vitest 执行、且 `readFileSync` 读**真实源码文件**（非内存副本），
因此不可能像第 5 轮那版类型断言一样"从未被编译"。三条断言：包名恒为全限定名、
源码含 `@module @deepseek-ai/dsh-tool-call-timeout-policy`、源码**不含** `dsh-timeout-guard`。
决定性对照：把 FIXME 行重新注入 `src/index.ts` 后重跑 →
`AssertionError: expected '…' not to contain 'dsh-timeout-guard'`（1 failed | 12 passed）；
还原后 13 passed。
**附带收获**：该自检在我第一版措辞下就失败了——因为我的新注释里写了 "A `dsh-timeout-guard`
rename was only ever a suggestion"。这不只是笔误：测试正确地证明了"只要源码出现该字符串就红"，
于是我改成不复述旧名的措辞。**自检当场抓到了我自己引入的噪声。**

**生成产物**：`lib/types/index.d.ts:6` 原本拷着同一段 FIXME（是 build 产物）。
`pnpm run typecheck` 重建后 `grep -c 'dsh-timeout-guard'` → **0**。工作区未手工改产物。

**为什么不写 Agent Note**：本轮不改任何行为与契约，只是按归档 note 自己规定的程序删除一个
已被证据证伪的标记并补断言；AGENTS.md 豁免机械局部编辑，且判定理由已就地写在源码 JSDoc、
规格注释、README Dev Note 与本节。归档 note 是**冻结**的，按 archive policy 不得修改。

**已提交**：本轮未 commit（按 TASK.md，改动留工作区由人审）。

**已知环境问题（非本轮造成）**
无新增。本轮三条命令全绿。

**下一轮从这里继续**
P2 已清空（`ns`→`namespace`、`title` 死参数、本条均已了结）。下一轮进 P3，二选一：
- `packages/e2b/**` 8 处 TODO 分类：区分"须等 E2B 上游解锁（留文档）"与"只是没做完（可做）"；
- `pnpm run duplication`：跑一次看跨文件克隆分布，为后续「重复实现」类候选建立依据。
建议先跑 `duplication`（侦察成本低、能一次性产出多个候选），再据其输出挑 e2b 的那条。

---

## 第 7 轮 — 侦察 `duplication` + 清掉退役名的最后残留 ✅（判定：P3 侦察产出，顺带收口一个契约缺陷）

**做了什么**
按上一轮建议先跑 `pnpm run duplication` 做侦察，得到一条**反直觉结论**，它本身推翻了 BACKLOG 里
"重复实现"这一类候选的存在前提；侦察同时暴露出一处**真实契约缺陷**（同一命名标记在两处被判相反），
本轮把它修掉。

**一、侦察：`duplication` 报告的 "0 克隆" 是假的**

```
$ ./node_modules/.bin/jscpd --config .jscpd.json --reporters json --output /tmp/jscpd-out packages scripts
exit=0   time: 134ms
statistics.total: { clones: 0, duplicatedLines: 0, duplicatedTokens: 0, percentage: 0,
                    lines: 369254, sources: 1733, tokens: 1681320 }
```
1733 个源文件、37 万行、**0 克隆、0.00% 重复** —— 这个数字不可信，原因是实测出来的：

- `.jscpd.json` 配了 `ignorePattern: ["(?s)/\\* jscpd:ignore-start \\*/.*?/\\* jscpd:ignore-end \\*/"]`，
  而该正则要求注释里**只有** `jscpd:ignore-start`、紧接 ` */`。
- 仓库的实际写法是 **184 处**都带具名理由，例如
  `packages/shell/tool-pwsh-persistent/src/index.ts:1`：
  `/* jscpd:ignore-start -- deliberate mirror of tool-bash-persistent (persistent-pty note …):`。
  理由文本横在标记与 ` */` 之间 → **正则一处都匹配不到**。
- 对照证据：`grep -rn 'jscpd:ignore-start' … | grep -v 'jscpd:ignore-end'`（即真正的内联单行豁免）
  输出为**空**；`grep -rl 'jscpd:ignore'` 为 **0** 是 ctx_execute 沙箱的相对路径解析假象（单文件 grep 与
  仓库 `grep` 工具都正常），已复核排除。
- 于是 209 个 `/* … */` 块全部**未被豁免**，却仍报 0 克隆 —— 说明 0 来自 `minTokens: 60` /
  `minLines: 6` / `mode: "mild"` 的阈值，而不是"没有重复"。**`duplication` 当前的绿灯不构成任何证据。**

**结论（写给下一轮，避免重复劳动）**：在修 `ignorePattern` 之前，不要再用 `duplication` 的输出去
挑"重复实现"候选；它必然报 0。修 `ignorePattern` 是**独立一轮**的工作（含复核 184 处豁免是否都想保留），
本轮只做侦察与记录，不动它。

**二、侦察顺带发现的真缺陷：同一标记在两处被判相反**
`src/index.ts` 的测试要求"源码不得出现 `dsh-timeout-guard`"，而**同一包**的 `README.md:133` /
`README.zh.md:133` 明写"`src/index.ts` 中的 FIXME 要求确定 `@deepseek-ai/dsh-timeout-guard` 改名"。
两处对同一事实判断相反 → 契约与实现不符（P2 判据），已修。

**改动（本轮 3 文件，均在 `packages/guard/timeout-policy/`）**
- `src/index.ts`：`@module` JSDoc 中两条**归档 note 链接**（`archived/architecture/2026-08-11-…`、
  `2026-07-29-package-regrouping`）删除。归档 note 是**冻结**的，不是当前权威，源码 JSDoc 指过去
  等于把冻结记录当依据 → 改为直接陈述既定事实（名字声明了所限定的操作 + 保留 `guard/timeout-policy/` 家）。
  另：第 6 轮那版措辞在该段落里被本轮的 `not.toContain` 断言**当场判红**（见下），一并重写为不复述旧名的表述。
- `tests/timeout-policy.spec.ts:225`：断言注释里的 `dsh-timeout-guard` 去掉（断言本身不变）。
- `README.md` / `README.zh.md` / `README.i18n.yaml`：Dev Note 里"FIXME 要求改名"的**陈旧句子删除**，
  只留已成立的结论；侧车按程序重录。

**验证证据**
```
$ env -u NODE_ENV npx vitest run packages/guard/timeout-policy
Test Files  1 passed (1)
     Tests  13 passed (13)

$ pnpm run test:docs                  # 16 passed, 0 failed, 0 skipped in 12.57s
```

**决定性对照（沿用"先确认自检真的会被执行"）**
把 `FIXME: dsh-timeout-guard rename pending` 重新注入**真实源码文件**后重跑：
`AssertionError: expected '/**\n * Cooperative tool-call timeout…' not to contain 'dsh-timeout-guard'`
→ `1 failed | 12 passed`；还原后 `13 passed`。断言非空洞。

**保留断言原文的取舍（本轮唯一的判断点）**
旧名现在**恰好只剩 1 处**（`tests/timeout-policy.spec.ts:228` 的 `expect(source).not.toContain(...)`）。
- 放弃它 → 该字符串全仓库归零（`git grep` 实证），"旧名回归"对模型完全不可见；
- 保留它 → 源码任一位置重新出现旧名即红。

选择**保留**：它同时兑现上一轮"仅剩的字符串出现在自检断言里"的记录，且 `git grep` 是 CI 外的人工检查
（上一轮已实测**无自动门禁**统计此类标记），断言才是自动的那道。**两处判断相反的缺陷因此不再可能复发。**

**为什么不写 Agent Note**：本轮不改任何行为与契约（两条断言原样保留），只是删除陈旧句子、去掉指向冻结
note 的链接、并重写注释措辞；AGENTS.md 豁免机械局部编辑，判定理由已就地写在源码 JSDoc、规格注释与本节。
归档 note 冻结，不得修改。

**已提交**：本轮未 commit（按 TASK.md，改动留工作区由人审）。

**已知环境问题（非本轮造成）**
- `ctx_execute`（shell）在多文件 `grep` 时对**相对路径**解析异常，可返回 0 匹配而不报错；单文件 grep
  与仓库 `grep` 工具均正常。本轮已用两种方式交叉复核，结论不受影响。**后续侦察勿把 ctx 沙箱里的
  多文件 grep 空结果当作"不存在"证据。**
- 本机无 `timeout` 命令（`command not found: timeout`），脚本里别用它做超时兜底。

**下一轮从这里继续**
两条候选，优先级已由本轮侦察排定：
1. **修 `.jscpd.json` 的 `ignorePattern` 以匹配带具名理由的写法**（唯一能让 `duplication` 重新有用的事；
   否则 P3 的"重复实现"分支永远报 0）。修完先跑一次拿到**真实**克隆分布，再谈抽公共实现。
2. `packages/e2b/**` 8 处 TODO 分类（P3 原条目，尚未开始；不依赖第 1 条）。
建议先做 1（成本一条正则 + 一次跑，收益是解锁一整类候选），再挑 e2b。


## 第 8 轮 — 修 `.jscpd.json`：BACKLOG 的诊断被证伪，真正的根因是阈值 + 一个惰性选项 ✅（判定：结论与队列记录相反）

**做了什么**
按第 7 轮"下一轮从这里继续"第 1 条，修 `.jscpd.json` 的 `ignorePattern`。**动手前先做了受控实验，
结论推翻了该条目的诊断**：`ignorePattern` 不是"正则写错所以匹配不到"，而是**在 jscpd 5.0.12 里完全不生效**。
因此按原诊断去改正则会是一次零收益改动。本轮改为删除该惰性选项 + 留下决定性自检。

**一、根因：`ignorePattern` 在 Rust 引擎里是死选项**
`package.json` 声明 `jscpd: ^5.0.12`，实际安装 **5.0.12**；`node_modules/jscpd/run-jscpd.js` 显示它
只是 `spawnSync` 一个 **Rust 二进制**（`jscpd-darwin-arm64`），即 v5 Rust 引擎。
- `jscpd --help` **列出** `--ignore-pattern`（"Code-level regex patterns to skip matching tokens"），
  但上游 v5 选项表与 config 参考**都不含它** —— 是 v4 遗留的、被 CLI 接受却未实现的旗标。
- 受控实验（fixture 内含一对确定的克隆，`minTokens=60` 下必被报出）：

  | 配置 | clones |
  |---|---|
  | 无 `ignorePattern` | 1 |
  | 仓库现有 v4 块状正则 | 1 |
  | **刻意写入的乱码正则 `ZZZ_TOTALLY_BOGUS`** | **1** |

  乱码正则同样无效果 → **该选项对结果零影响**。在真实仓库上以 `minTokens=50`（此时确实有克隆）
  重跑三组，`clones/duplicatedLines/duplicatedTokens` **逐字节相同**。

**二、对照实验证明"标记"机制才是真正生效的那条路**
Rust 引擎**原生支持** `/* jscpd:ignore-start */ … /* jscpd:ignore-end */` 围栏：
同一 fixture 加上围栏 → 克隆从 1 变 0；去掉围栏 → 复现。仓库里 97 处 `ignore-start` 因此是**有效的**，
不需要 `ignorePattern` 帮忙。（同时确认 `ignore` glob 有效：`**/tests/**` 让 sources 2894→1558、
clones 3049→105。二者是不同机制，别混。）

**三、"0 克隆"的第二个成因：阈值正好压在数据上**
即便删掉惰性选项，仓库仍报 0。实测克隆规模分布（仓库真实数据）：

| minTokens | clones |
|---|---|
| **60（仓库当前值）** | **0** |
| 50 | 132 |
| 40 | 365 |
| 30 | 1088 |
| 20 | 3408 |

132 个克隆的 tokens：**p50=54、p90=59、max=71** —— 仓库的重复密度恰好落在 **50–60** 这一带，
`minTokens: 60` 把 132 个里的 122 个切掉，只留下 10 个（且都 ≥60 的也没被报出，见下）。
**"0.00% 重复"是阈值造出来的，不是仓库干净。**

**本轮唯一的主观判断（记录在案）**：把 `minTokens` 降到 50 会让 `lint-and-duplication` 门禁
（`exitCode: 1`）在 132 处**先存**克隆上立刻变红 —— 那是"弄坏 CI"而不是"改进仓库"，且修掉这 132 处
远超"一轮一件事"的规模。因此本轮**只修根因、不动阈值**：`.jscpd.json` 保持 `minTokens: 60`，
**门禁仍然 exit 0**（实测），行为与改动前一致 —— 本轮**不改门禁松紧**，只移除假承诺。
"要不要把阈值降进 50–60 带、让真克隆暴露出来"是一个**独立决定**，会让 `lint-and-duplication` 立刻变红
（132 处先存克隆），属于需要人拍板的范围，已写进 BACKLOG 作为独立条目。

**四、侦察顺带确认的候选（供下一轮用）**
在 `minTokens=50` 的真实输出里，有 115 对克隆**涉及生产源码**（非测试），例如：
`shell/tool-bash/src/index.ts:30` ↔ `shell/tool-pwsh/src/index.ts:48`、
`shell/bash-sandbox/src/index.ts:12` ↔ `shell/pwsh-sandbox/src/index.ts:15`、
`subagent/subagent-acp/src/run.ts:587` ↔ `subagent/subagent-dsh-sdk/src/run.ts:338`。
其中 bash/pwsh 这对正是 BACKLOG 里"两个包重复的注释 = 重复的实现"那条所指 —— **本轮拿到实证**，
但那是另一个主题，留给后续轮次。

**改动（2 文件）**
- `.jscpd.json`：删除 `ignorePattern`（惰性，且读起来像豁免机制却什么都不豁免）。阈值**未改**，
  门禁松紧与改动前一致。
- `scripts/duplication-config.spec.ts`（新增，4 用例）：钉住 (a) 配置不得再出现 `ignorePattern`；
  (b) `jscpd:ignore-start/end` 围栏确实压制克隆；(c) **无围栏的对照片必须仍被报出**（防空洞断言）；
  (d) 配置改动不得把扫描集缩成 0 文件却报"干净"。

**验证证据**
```
$ env -u NODE_ENV npx vitest run scripts/duplication-config.spec.ts scripts/oxlint-contract.spec.ts
Test Files  2 passed (2)
     Tests  18 passed (18)

$ ./node_modules/.bin/jscpd --config .jscpd.json packages scripts   # 门禁行为与改动前一致
exit=0   Found 0 clones   sources=1734

$ pnpm run typecheck      # exit 0
$ pnpm run test:docs      # 16 passed, 0 failed, 0 skipped in 12.56s
```

**决定性对照（两条断言分别验证非空洞）**
- 把 `ignorePattern` 重新注入 `.jscpd.json` → `1 failed | 3 passed`
  （`omits ignorePattern…` 红），还原 → 4 passed。
- 把 fixture 的 `jscpd:ignore-start` 拼错 → `1 failed | 3 passed`
  （`expected 1 to be +0`），还原 → 4 passed。
两个文件还原后与原文**逐字节相同**（已用 `fs.readFileSync` 比对）。

**为什么不写 Agent Note**：删掉一个不生效的配置键 + 加一个规格文件，不改任何产品行为与契约；
AGENTS.md 豁免机械局部编辑。判定依据已就地写在 `.jscpd.json` 所在的规格注释与本轮记录里。

**已提交**：本轮未 commit（按 TASK.md，改动留工作区由人审）。

**踩到的坑（写给下一轮）**
- jscpd 的 `ignore`/`output` 等相对路径按**配置文件所在目录**解析，不是 cwd。把临时配置写到 `/tmp`
  再扫 `packages` 会得到 `sources: 0` 的**假干净**——看起来像"没有重复"。自检里因此把配置写在
  scratch 目录但仍用**绝对扫描路径**，并断言 `sources > 1000` 兜住这个陷阱。
- 我的临时配置曾落在仓库根 `jscpd.config.json`，被 `git status` 抓到；本轮已清理，工作区无残留。

**下一轮从这里继续**
1. **阈值决策（需人拍板或谨慎推进）**：是否把 `minTokens` 降进 50–60 带。降了 = 立刻 132 克隆红。
   若要降，得先决定这 132 处是"逐个加围栏+理由"还是"抽公共实现"，那是一个成规模的主题。
2. **bash/pwsh 镜像对的实证收口**：`tool-bash`/`tool-pwsh` 与 `bash-sandbox`/`pwsh-sandbox` 两组镜像
   已在真实克隆数据里现形，可据实判断该抽公共实现还是补围栏理由（BACKLOG P1 那条的实证版）。
3. `packages/e2b/**` 8 处 TODO 分类（仍未开始，不依赖以上）。

---

## 第 9 轮 — bash/pwsh 镜像对实证收口：一个真 bug + 一处不成立的模型指令 ✅

**做了什么**
按第 8 轮"下一轮从这里继续"第 2 条，收口 `tool-bash`/`tool-pwsh` 镜像对。**结论与该条目的前提相反**：
这对镜像不是"重复实现该抽公共"，而是**藏在镜像里的一个真缺陷加一处不可执行的模型指令**。
两条都不是 BACKLOG 原本假设的"重复"，因此本轮不做提取，改为修缺陷 + 立自检。

**一、侦察方法：先用结构比对量化"重复"，再逐块判定**

按包名归一化后做行级最长公共块搜索（`minTokens` 之下的结构重复）：

| 位置 | 行数 | 性质 |
|---|---|---|
| 常量/接口区 | 44 | 真镜像，但**必须**各自持有（见下） |
| `retainedScrollback` + `pause` + `nextScrollbackOffset` | 28 | 逐字节相同 |
| `persistentShells` 注册表 | 23 | 逐字节相同 |
| **镜像内的行为差异** | — | **本轮发现的 bug 就在这里** |

`tool-pwsh-persistent/src/index.ts:1` 的围栏理由（"shares the session registry, polling loop,
and reset contract **by design**"）**被数据证实**：那 51 行确实是刻意的孪生代码，抽公共实现会把
两个后端的差异（`stty -echo` vs `prompt` 函数）挤进一个带分支的共享模块 —— 那违反仓库
"Prefer symmetry for parallel values"。**判定：不抽。** 围栏理由充分，保留。

**二、真 bug：pwsh 超时结果丢掉了状态尾标（对照 bash 才现形）**

两个包的超时分支**结构相同但行为不同**：

```ts
// tool-bash-persistent/src/index.ts:351
appendStatusMarker(partial, TIMEOUT_STATUS_MARKER),   // → "...partial\n[Command timed out or OOM]"

// tool-pwsh-persistent/src/index.ts（修复前）
partial,                                              // → 没有尾标
```

`TIMEOUT_STATUS_MARKER` 在 pwsh 包里**根本不存在** —— 只有 bash 有。后果：bash 在超时时给出
"本命令未报告退出码"的显式尾标，pwsh 什么都不给，模型无法区分"命令正常结束、输出就这些"与
"命令被 deadline 掐断"。而 pwsh 的 `renderCaptured` 只在 `exitCode !== 0` 时加尾标，
超时被 abort 的管线永远给不出退出码 → **该路径恒无状态**。

**受控实验（从两个包的真实源码里 eval 出 `renderCaptured` 逐例对比）**：

| 输入 | bash 工具 | pwsh 工具（修复前） |
|---|---|---|
| 成功 exit 0 | `hello` | `hello` |
| 失败 exit 1 | `…\n[Command finished with exit code 1]` | `…\n[exit code: 1]` |
| 失败 exit 1、输出为空 | `[Command finished with exit code 1]` | `[exit code: 1]` |
| exitCode undefined | `out` | `out` |

两者对"成功/失败"的处理各自自洽（bash 报每次结算，pwsh 只报非零）—— 差异是**有意的**，
不是 bug。真 bug 只在超时路径：bash 有 `TIMEOUT_STATUS_MARKER`、pwsh 没有。
README 也印证了这是**文档已承诺但实现没做到**：pwsh README:131 写 "Timeout returns bounded
partial output…"，而 bash README:129 明确写 "followed by `[Command timed out or OOM]`"。

**修法（最小 diff）**：给 pwsh 补上 `TIMEOUT_STATUS_MARKER` 常量（附注释说明为何结算路径
无法提供退出码），超时分支改用 `appendStatusMarker(partial, TIMEOUT_STATUS_MARKER)`。
两包 README（双语）同步补上尾标承诺。

**三、不成立的模型指令：裁剪通知让模型去搜一个不存在的文件**

两包源码各有一条相同的 TODO：

> `// TODO: Replace the file-search advice; arbitrary command output need not come from a searchable file.`

TODO 的判断**经实证成立**。原通知写的是 "only part of **this file** has been shown to you.
You should retry this tool after you have **searched inside the file** with `grep -n` / `Select-String`"。
但被裁剪的是**命令输出**，不是文件：

- `grep` 实证两个包的 `src/` 里**没有任何** `tmpdir`/`mkdtemp`/`writeFile` —— 输出从不落到文件；
- 保留的前缀**已经在这条结果里**，PTY 只留有限 scrollback，没有第二份可供搜索的副本。

即模型被指向一个不存在的东西。**修法**：改为点名"命令输出"，并给出两条真能执行的路
（`Retry with a command that emits less` / `write the output to a file and search that file`），
bash 用 `grep -n`、pwsh 用 `Select-String` 保持各自的 shell 方言。删 TODO（已兑现）。

**验证证据**
```
$ env -u NODE_ENV npx vitest run packages/shell/tool-pwsh-persistent packages/shell/tool-bash-persistent
Test Files  3 passed | 1 skipped (4)
     Tests  41 passed | 1 skipped (42)          # 修复前基线 39 passed

$ pnpm run typecheck     # exit 0
$ pnpm run test:docs     # 16 passed, 0 failed, 0 skipped in 12.54s
```

**决定性对照（两条断言分别验证非空洞）**
- 去掉 pwsh 超时分支的 `appendStatusMarker(...)` 还原为 `partial` →
  `1 failed | 20 passed`（`closes a timed-out shell…` 红）；还原 → 全绿。
- 把两包的裁剪通知改回 `searched inside the file` 措辞 → `2 failed | 39 passed`
  （两条新用例都红）；还原 → 全绿。文件还原后 `grep -c 'searched inside the file'` 为 0。

**为什么不做公共提取（本轮唯一的主观判断，记录在案）**
镜像区 51 行确实是逐字节重复，但差异点（初始化：bash `stty -echo` vs pwsh `prompt` 函数；
转义：`$'…'` vs 反引号；提取：去 prompt vs 去 PSReadLine 回显；状态尾标：两种方言）**贯穿
注册表内部**，不是可以参数化的边角。抽成一个带 4 个回调的共享模块会让当前"读一个包就知道
另一个包长什么样"的对称性变成"读共享模块才知道谁在什么时候回调"。围栏理由（by design）
与 `packages/AGENTS.md` 的 "Prefer symmetry for parallel values" 一致，**保留围栏**。
本轮的产出是把围栏**从"概括性理由"升级为"已证实的判定"**：重复是真的、有意的、且里面
藏着的那两处差异已各自修正。（与第 8 轮 P3 阈值条目无冲突：即使降 `minTokens`，这 97 处
围栏仍会正确压制它们。）

**为什么不写 Agent Note**：修复的是一处状态尾标缺失 + 一条不可执行的模型文案，两包 README
（双语 + 侧车）与规格同步更新；不引入新机制、新 public API 或新配置面。AGENTS.md 豁免
机械局部编辑，判定依据已就地写在源码注释、规格注释与本节。

**已提交**：本轮未 commit（按 TASK.md，改动留工作区由人审）。

**踩到的坑（写给下一轮）**
- **改 README 会连坐翻译配对门禁**。`test:docs` 里 `verify-translation-pairing` 要求中英两侧
  同步**并重录侧车**；`--write` 不接受空参数（会报 "recording pairs you did not review"），
  必须**点名**你确认过的文件：`pnpm run verify-translation-pairing --write <README.md> …`。
  只改英文不碰中文 → 门禁红，且报错信息只说 "out of sync"，不告诉你缺哪一步。
- `ctx_execute` 的 JS 沙箱**不支持 ESM `import`**（会以 `SyntaxError: Unexpected identifier`
  失败），且工作目录在临时目录里，`require('typescript')` 解析不到仓库依赖。
  要跑需要仓库依赖的探针脚本，写进仓库根再 `node` 跑，跑完立刻删（本轮已清理，无残留）。
- 用正则剥 TypeScript 类型注解很脆：`(\w+)\s*:\s*Type(\s*[,)=])` 会把 `incomplete = false`
  这类默认值吃掉。**用 `ts.transpileModule`，别用正则。**

**下一轮从这里继续**
1. **阈值决策（需人拍板）**：是否把 `.jscpd.json` 的 `minTokens` 降进 50–60 带（第 8 轮实测：
   降了 = 132 处先存克隆立刻红）。仍是 P3 待决，本轮未动。
2. `packages/e2b/**` 8 处 TODO 分类（P3，仍未开始，不依赖以上）—— 现在是队列里唯一
   **不需人拍板**就能推进的条目。**已在第 10 轮收口，见下。**

---

# 第 10 轮 — `packages/e2b/**` TODO 分类收口：6 处等上游 + 1 处真缺陷

**条目来源**：BACKLOG P3「审查 `packages/e2b/**` 的 8 处 TODO」（第 7 轮开出）。
选它的理由：队列里唯一**不需人拍板**的条目；另一条 `minTokens` 阈值已明确挂起等人决策。

## 一、先把 8 处逐个定性（本轮的实质产出）

`grep -rn 'TODO(e2b-'` 命中的**8 处标记 = 7 个不同标记名**（`e2b-pgid-identity` 出现两次，
另有 4 处 README 双语复述，非独立条目）：

| # | 标记 | 位置 | 定性 |
|---|---|---|---|
| 1 | `e2b-pgid-identity` | `remote.ts:87` | **等上游** — 需要 E2B 新增原子身份原语；用户态预检关不掉数值 PGID 复用竞态（注释已自证） |
| 2 | `e2b-pgid-identity` | `terminal.ts:303` | **等上游** — 同上，PTY/session id 变体 |
| 3 | `e2b-replace-environment` | `environment.ts:29` | **等上游** — E2B 合并（而非替换）command envs；探测的继承是引擎行为 |
| 4 | `e2b-status-watch` | `process.ts:540` | **等上游** — E2B 无法脱离「后代持有输出」单独观测直接命令退出 |
| 5 | `e2b-setup-rollback` | `e2b/src/index.ts:183` | **等上游** — 重试状态只在「真双重失败超出沙箱超时」时才需要；现无证据 |
| 6 | `e2b-terminal-setup-rollback` | `terminal.ts:561` | **等上游** — 同上，terminal 变体 |
| 7 | `e2b-publication-cancel` | `process.ts:485` | **可做，且是真缺陷** ← 本轮修 |

**判定**：#1–#6 是**等 E2B 上游**的，README 已在 `## Known Limitations and Deferred Work`
与 Dev Note 里如实记录 —— 按 `packages/AGENTS.md`「Package READMEs put durable consumer gaps …
under Known Limitations」，它们**位置正确，不该动**，也不该再当待办重开。
只有 #7 不需上游就能修，且它不是"没做完"，是**真 bug**。

## 二、#7 的根因：取消信号没进到 in-flight 的 SDK 读

`terminate()` 会 abort `terminationController`（`process.ts:231`）。`prepareState` 把该 signal
**贯穿了每一个** SDK 调用（`files.makeDir` / `commands.run` / `files.write`，`:399-414`），
但两条**监视回路**的读漏传了：

- `waitForProcessGroupId` 的 `sandbox.files.read(this.paths.pid)` —— 未传 signal；
- `waitForCommand` 的 `sandbox.files.read(this.paths.status)` —— 未传 signal。

**实证（先证后修；探针脚本写在仓库根、跑完已删，无残留）**：复刻该读法的最小脚本显示
`files.read(path)` 收到 `opts.signal === undefined`，在 `controller.abort()` 之后
**仍为 pending**（300ms 探测窗口内不 settle，`readAborted === false`）。
即：取消命令后，这笔已在飞的读**活过了** abort —— 正是 TODO 文字描述的那件事。
E2B SDK 2.29.1 的 `FilesystemRequestOpts` 明含 `signal`
（`extends Partial<Pick<ConnectionOpts, 'requestTimeoutMs' | 'signal'>>`），
所以不是"上游不支持"，是**本包漏传**。

**修法（最小 diff）**：复用**本包已有**的 `signalOpts()` 助手（`remote.ts:24`；
`terminal.ts` 早已 import 并在用），给两处读补 `signalOpts(this.terminationController.signal)`，
`process.ts` 补 import。删 TODO（已兑现），就地换成说明"为何必须带 signal"的局部注释。

## 三、验证证据

```
$ env -u NODE_ENV npx vitest run packages/e2b
Test Files  5 passed (5)
     Tests  163 passed (163)          # 修复前基线 161 → 本轮新增 2 条自检

$ pnpm run typecheck                 # exit 0
$ pnpm run test:docs                 # 16 passed, 0 failed, 0 skipped
```

**决定性对照（自检非空洞）**：把两处 `signalOpts(...)` 去掉（还原为修复前）→
`Test Files 1 failed | 1 passed (2)` / `Tests 2 failed | 105 passed (107)`，
两条新用例**同时红**；还原后 163 全绿。

**为什么这 2 条用例此前不可能红**：`FakeSandbox.files.read` 原签名是
`async (path: string): Promise<string>` —— **根本不接收 `opts`**，所以生产代码传不传 signal，
测试都看不见。本轮把假实现改成 `(path, opts?)` 并记录
`processGroupReadSignals` / `statusReadSignals`，缺陷才变得可观测。
**这是「测试替身比被测契约更窄，于是掩盖了缺陷」的又一实例**（与第 9 轮"README 与源码判反"
同类：都是**观测面**的问题，不是逻辑面），留给下一轮当模式用。

**中途踩的坑**：第一版假实现在 abort 时 `throw new DOMException`，结果**22 条既有用例红**。
原因：真实 `terminate()` 路径下，被 abort 的**轮询读**不必然让监视失败 —— 结算由已发布的
status 决定。假实现只需**记录** signal，断言放在"signal 是否在场 / 是否被 abort"上，
**不必**模拟 SDK 的拒绝语义。

## 四、为什么不改 README / 不写 Agent Note

本包 README 从不承诺"读是可取消的"，也没写过这个 TODO（`grep -rn 'publication-cancel'`
在 `docs/` 与 `packages/e2b/*/README*` 下**零命中**，唯一命中是本轮新用例的路径字符串）。
按 AGENTS.md「Keep comments local」，**没陈述过错误行为的文档就没有要修的地方**；
其余 6 处等上游条目**已在** Known Limitations / Dev Note 里，本轮不动。
故本轮**无 README 改动**，也就**不触发**第 9 轮记录的翻译配对门禁连坐。

改动是"漏传一个已有助手到两处调用"的局部修正 + 两条规格用例；不引入新机制、
新 public API、新配置面 → 符合 AGENTS.md 对机械局部编辑的豁免，**不写 Agent Note**。

**已提交**：本轮未 commit（按 TASK.md，改动留工作区由人审）。
改动面：`packages/e2b/subprocess-e2b/src/process.ts`（+8/−5）、
`packages/e2b/subprocess-e2b/tests/subprocess.spec.ts`（+47/−2）。

**下一轮从这里继续**
1. **阈值决策（仍需人拍板）**：`.jscpd.json` 的 `minTokens` 是否降进 50–60 带。
   第 8 轮实测：降了 = 132 处先存克隆立刻红。本轮未动。
2. **e2b 剩余 6 处 TODO 已定性为「等上游」**，不该再当待办重开 —— 除非 E2B 版本升级。
3. **队列现在没有"既不需人拍板、又已定性"的条目了** —— 下一轮需**重新侦察**
   （TASK.md「如何找候选」：真失败 > 具名 TODO > 契约不符 > 重复实现 > 过度设计）。
   建议先跑一次相关包的真实测试找红，而不是继续翻 TODO 台账。
   可复用的线索：本轮揭示的**观测面缺陷**模式（测试替身签名比契约窄）值得主动扫一遍 ——
   例如找那些 `read`/`run`/`list` 的 fake 实现忽略了 `opts` 的规格文件。
