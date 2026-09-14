# BACKLOG

迭代候选队列。每轮取最上面一条；做完移到底部 `## Done`。

判定优先级：真失败 > 契约与实现不符 > 具名 TODO > 重复实现 > 过度设计。

---

## P0 — 真失败 / 契约违反

- [x] **setupFile 顶层 `node:fs` import 让全部 jsdom 规格加载失败**（207 个文件）— 已修
  `scripts/test-proxy-environment.ts` 顶层 `import { globSync } from 'node:fs'` / `'node:path'`。它是全局 `setupFiles`，jsdom 规格也会加载它 → vite browser-externalize 把 `node:fs` 换成空 stub → `Error: No such built-in module: node:` → 该规格 0 test。
  **修法**：`vitestConfigFiles()` 内改为动态 `await import('node:fs'/'node:path')`；`clearAmbientProxyEnv` 保持顶层（纯 `process.env`/`Reflect`，jsdom 安全）。调用方 `scripts/test-proxy-environment.spec.ts` 改 `beforeAll` + 单用例循环（`it.each` 在收集期求值拿不到异步结果）。
  **验证**：`env -u NODE_ENV npx vitest run packages/client/ui-directory-picker-browse/tests/directory-browser.client.spec.tsx scripts/test-proxy-environment.spec.ts` → 2 files / 86 tests passed。

- [x] **`scripts/browser-bundled-externals.spec.ts` 的 vite 构建断言真失败** — 已修
  fixture 的 `mkdtempSync(join(tmpdir(), ...))` 在 macOS 得到 `/var/folders/...`（`/var` 是 `/private/var` 的符号链接）。spec 把 html 入口写成绝对路径，vite realpath 后落在 `root` 之外，rollup 拒绝相对 `fileName`。
  **修法**：`fixture()` 里对 mkdtemp 结果做 `realpathSync`（一行，所有 fixture 路径一起正过来）。产品代码无误。

- [x] **`NODE_ENV=production` 从外部环境泄漏进 vitest** — 已修
  `vitest.config.ts` 根级加 `env: { NODE_ENV: 'test' }`。vitest 只默认 `MODE`/`DEV`，不管 `NODE_ENV`，所以宿主 shell 的值会泄漏并翻转源码里的 dev/production 运行时判断（如 `client/store` 的 `devFreeze`）。
  **注意**：此项只影响 3 个测试失败，**不是** 207 个文件的成因（那是上面第一条，我最初归因错了）。

## P1 — 具名 TODO（实现已认定该做）

- [ ] `packages/hooks/*/src/index.ts:188,171` — `TODO(hook-continue-false)`：`merged.stop` 已记录但缺 run-level 停机机制。
  **排在 stop-loop-guard 之后**：侦察确认它需要新的核心原语（拦截点没有「硬停机整轮」的能力），而循环守卫不需要。

- [ ] `packages/util/atomic-write/src/index.ts:83` — `TODO(settings-atomic-durability)`：替换后未 fsync。数据丢失面。
- [x] `packages/shell/tool-bash-persistent/src/index.ts:14` 与 `tool-pwsh-persistent/src/index.ts:16` — 相同的 TODO：文件搜索建议对任意命令输出不适用。**两个包重复的注释 = 重复的实现**，查一下是否可以直接抽掉。**已收口（第 9 轮）**：TODO 成立但结论相反 —— 不是"重复该抽"，是**镜像里藏了一个真 bug + 一条不可执行的模型指令**。见下方 Done。

## 已评估 — 结论是不做（勿重复劳动）

- [x] ~~`packages/settings/settings/src/redact.ts:87` — `TODO(settings-wire-redaction)`~~ **判定：不改**
  `walk()` 只处理 `object`/`dict`/`array`，其余走 `default:` 原样返回 —— 但**当前不可达**：全仓库非测试 `src/` 里唯一的 `role('secret')` 是 `web-search-deepseek/src/index.ts:64` 的顶层 `apiKey`，走 `object` 分支被正确剥离。四个 shipped union（llm-deepseek:181-191、llm-pi-ai config.ts:243-337、permission-presets:167-213、ui-theme theme-settings.ts:42）都不包裹 secret。
  在 `walk()` 里 throw 会**打断四个正常工作的 union**；真正的 fail-closed 属于 `register()`（即 README 已记录的 `describeForWire()`），是明确更大的改动。
  **只有第三方插件注册「union 包裹的 secret」时才变成真问题** —— 等那时再做。

- [x] ~~`packages/settings/settings/src/index.ts:78` — `TODO(settings-namespace-vocabulary)`~~ **判定：不改**（第 5 轮）
  TODO 的前提（"`ns` 是需要纠正的词汇缺陷"）被仓库自身的一致性推翻：
  - `ns` 是**通用惯用名**——`client/locale` 用 12 次、`client/ui-slots` 2 次，且已固化进两份**生成**目录。
  - 它在本 seam 上是**线上字段**，不只是标识符：`SettingsNamespaceView.ns`、
    settings-controller 的 `z.object({ ns })` 请求 schema、`@Remote update/replace/mutate(ns, …)` 参数名。
  - 面：**47 文件 / 8 包** + 双语 README + 子系统文档 + 1 生成产物 + Cordis 事件签名。
  - 线上字段**已有测试覆盖**（`settings-controller.host.spec.ts:125,164,191`）。
  **已执行**：删 TODO、删 README Dev Note 开放项（双语 + 重录侧车）、加一条决定性断言。
  **验证**：39 files / 679 tests passed；`typecheck` exit 0；`test:docs` 16 passed；
  `verify-translation-pairing` 810 consistent。

## P2 — 契约与实现不符（需先确认是否真问题）

（空。四条均已判定：`ns`→`namespace` 退役、「死 `title` 参数」删除、`dsh-timeout-guard` FIXME 删除、
第 7 轮"同一命名标记在源码断言与 README 中被判相反"已修。）

## P3 — 架构 / 新工具

- [ ] **决定 `duplication` 的 `minTokens` 阈值（第 8 轮实测，需人拍板）**（P3，接管第 7 轮条目）
  第 7 轮的诊断（"`ignorePattern` 正则写错"）**已被第 8 轮实验证伪**：该选项在 jscpd 5.0.12（Rust 引擎）
  里**完全不生效** —— 无它 / 仓库原正则 / 乱码正则三组结果逐字节相同。已删除该惰性键（第 8 轮完成）。
  真正的成因是阈值：`minTokens: 60` → **0 克隆**；50 → 132；40 → 365；30 → 1088。
  仓库克隆规模 p50=54 / p90=59 / max=71，**密度恰好卡在 50–60 带**，阈值把它们全切掉。
  **待决**：是否降阈值。降了门禁（`exitCode: 1`）会立刻在 132 处先存克隆上变红，需同时决定
  这 132 处是"逐处补 `jscpd:ignore-start/end` 围栏 + 具名理由"还是"抽公共实现"。
  **在此之前，不要把 `duplication` 的绿灯当作"没有重复"的证据。**
- [x] **审查 `packages/e2b/**` 的 8 处 TODO** — **已收口（第 10 轮）**：6 处定性为「等 E2B 上游」
  （README 已在 Known Limitations / Dev Note 如实记录，位置正确、不该动、不该重开）；
  1 处 `e2b-publication-cancel` 是**真缺陷**（取消信号漏传进 in-flight 的 SDK 读），已修。
  见下方 Done。**此条不再有待办残留。**

---

## Done

- [x] **`packages/e2b/**` TODO 分类收口：6 处等上游 + 1 处真缺陷**（第 10 轮）
  8 处 `TODO(e2b-*)` 标记（= 7 个标记名，`e2b-pgid-identity` 出现两次）逐个定性：
  - **6 处等 E2B 上游**（`pgid-identity`×2、`replace-environment`、`status-watch`、
    `setup-rollback`、`terminal-setup-rollback`）—— 都卡在 E2B 引擎行为上，
    README 已在 Known Limitations / Dev Note 如实记录，**位置正确、保持原样**。
  - **1 处是真缺陷**：`e2b-publication-cancel`。`terminate()` abort 的
    `terminationController.signal` 贯穿了 `prepareState` 的每个 SDK 调用，
    却**漏在两条监视回路的 `files.read` 上**（`paths.pid`、`paths.status`）→
    取消后这笔已在飞的读**活过 abort**（探针实证：`opts.signal === undefined`，
    abort 后仍 pending）。E2B SDK 2.29.1 的 `FilesystemRequestOpts` 明含 `signal`，
    故属**本包漏传**，非上游缺失。
  **修法**：复用本包已有的 `signalOpts()`（`remote.ts:24`，`terminal.ts` 早已在用），
  两处读补 `signalOpts(this.terminationController.signal)`；删 TODO。
  **验证**：`env -u NODE_ENV npx vitest run packages/e2b` → 5 files / **163 passed**
  （基线 161，+2 条自检）；`typecheck` exit 0；`test:docs` 16 passed。
  决定性对照：去掉两处 `signalOpts` → **2 failed | 105 passed**（两条新用例同时红），还原 → 全绿。
  **关键教训**：`FakeSandbox.files.read` 原签名不接收 `opts`，所以**无论生产代码传不传
  signal，测试都看不见** —— 测试替身比被测契约窄，掩盖了缺陷。本轮扩宽假实现后缺陷才可观测。
  无 README 改动（文档从未承诺可取消性，也未写过该 TODO）→ 不触发翻译配对门禁。
  不写 Agent Note（局部漏传修正，符合机械编辑豁免）。未 commit，留工作区由人审。

- [x] **bash/pwsh 镜像对实证收口：一个真 bug + 一处不可执行的模型指令**（第 9 轮）
  原条目的前提（"重复的注释 = 重复的实现，查一下是否可以直接抽掉"）**被实证推翻**：镜像区确实是
  刻意的（围栏理由 "shares the session registry, polling loop, and reset contract by design"
  被结构比对证实），但**里面藏了两处该修的东西**：
  1. **真 bug**：pwsh 超时路径丢掉了状态尾标。`TIMEOUT_STATUS_MARKER` 只有 bash 有，
     pwsh 的 `renderCaptured` 又只在 `exitCode !== 0` 时加尾标，而超时被 abort 的管线永远
     给不出退出码 → 该路径恒无状态，模型无法区分"命令正常结束"与"被 deadline 掐断"。
     bash README 承诺了 `[Command timed out or OOM]`，pwsh README 没承诺、实现也没有。
     **修法**：pwsh 补 `TIMEOUT_STATUS_MARKER` + 超时分支改用 `appendStatusMarker(...)`。
  2. **不成立的指令**：裁剪通知让模型 "searched inside the file"，但被裁剪的是**命令输出**——
     两包 `src/` 里没有任何文件写入路径（`grep` 实证无 `tmpdir`/`writeFile`），保留的前缀
     已在结果里，PTY 无第二份副本。改为点名命令输出 + 两条真能执行的路。
  **判定：不抽公共实现** —— 差异点（初始化、转义、提取、状态尾标四种方言）贯穿注册表内部，
  抽走会把对称性换成带回调的共享模块，违反 `packages/AGENTS.md` 的 "Prefer symmetry"。
  **验证**：41 passed（基线 39）；`typecheck` exit 0；`test:docs` 16 passed。
  两条决定性对照：还原超时尾标 → `1 failed`；还原旧文案 → `2 failed`。各自还原后全绿。

- [x] **删除 `.jscpd.json` 的惰性 `ignorePattern` + 钉住围栏机制**（第 8 轮）
  **判定：第 7 轮的诊断被证伪**，`ignorePattern` 在 jscpd 5.0.12（Rust 引擎）里**不生效**（乱码正则
  亦无影响，三组结果逐字节相同），故按原诊断"改正则"是零收益。改为删除该键 + 新增
  `scripts/duplication-config.spec.ts`(4 用例，含**无围栏对照片**防空洞断言)。
  同时查明"0 克隆"的真因是 `minTokens: 60` 恰好切在克隆密度带（p50=54/p90=59）上，
  阈值决策另立 P3 条目。
  **验证**：18 tests passed；`typecheck` exit 0；`test:docs` 16 passed；
  门禁 `jscpd --config .jscpd.json packages scripts` 仍 exit 0（行为与改动前一致）；
  两条决定性对照（重新注入 `ignorePattern` / 拼错围栏标记）各自 `1 failed | 3 passed`，还原后 4 passed。

- [x] **`duplication` 侦察 + 退役名最后一处相矛盾的说法**（第 7 轮）
  侦察得出：`pnpm run duplication` 的 `0 clones / 0.00%` 是**假绿**——`.jscpd.json` 的 `ignorePattern`
  匹配不到仓库实际使用的带理由豁免写法（184 处全落空），阈值把结果压成 0。修它另立 P3 条目。
  侦察顺带暴露真缺陷：`src/index.ts` 的测试断言"源码不得出现 `dsh-timeout-guard`"，而同包
  `README.md:133` / `README.zh.md:133` 却写"`src/index.ts` 中的 FIXME 要求确定该改名"——**同一事实两处判反**。
  已删 README 陈旧句、去掉 `@module` JSDoc 指向**冻结**归档 note 的两条链接、重写措辞不复述旧名。
  **验证**：13 tests passed；`test:docs` 16 passed / 0 failed；
  决定性对照：重新注入标记 → `1 failed | 12 passed`，还原 → 13 passed。
  旧名全仓库仅剩 `tests/timeout-policy.spec.ts:228` 一处在断言内部（有意保留，见 PROGRESS 第 7 轮）。

- [x] **`dsh-timeout-guard` FIXME 退役**（第 6 轮）
  判定该 FIXME 陈旧并删除：改名台账 `2026-08-11-repository-naming-contract-and-rename-ledger.md:259`
  已记录 `dsh-timeout-policy` → `dsh-tool-call-timeout-policy`（保留 `guard/timeout-policy/` 与
  插件 id `timeout-policy`），当前包**已符合**；`2026-07-29-package-regrouping.md:41` 明言两个
  release-blocking FIXME 随改名一并移除，sibling 早已删，本包是最后残留。README Dev Note 原本
  就自称"stale pending a code cleanup"，本轮兑现。
  新增决定性自检 `pins the settled package name and carries no rename marker`（读真实源码文件，
  断言包名 + 无旧标记）；对照实验：重新注入标记 → 1 failed，还原 → 13 passed。
  仅剩的 `dsh-timeout-guard` 字符串出现在自检断言里。
  **验证**：13 tests passed；`typecheck` exit 0（并重建 `lib/types/index.d.ts`，产物中旧标记归零）；
  `test:docs` 16 passed。

- [x] **`TODO(settings-namespace-vocabulary)` 退役 + 第 4 轮生成产物闭环**（第 5 轮）
  判定「不改名」并退役该 TODO 与 README Dev Note 条目；新增 `keeps the descriptor key as ns`
  断言钉住线上字段。顺带跑 `gen-cordis-api.ts` 修掉第 4 轮遗留的
  `api-catalog.ts` / `workspace.md` / `workspace.zh.md` 陈旧（delta 恰好只有 `create(path, title?)`）。
  **验证**：39 files / 679 tests passed；`typecheck` exit 0；`test:docs` 16 passed；
  `verify-cordis-api` 97 up to date；`verify-translation-pairing` 810 consistent。
  详见 PROGRESS.md 第 5 轮（含"自检必须先确认会被执行"的教训）。

- [x] **`packages/workspace/workspace/src/index.ts:152` 的死 `title` 参数** — 已删（第 4 轮）
  `WorkspaceRegistry.create(path, title?)` → `create(path)`；`createCanonical` 同步收敛，
  `title ?? defaultWorkspaceTitle(canonical)` 变为 `defaultWorkspaceTitle(canonical)`。
  删除源码 TODO、`@param title`、README 对示例的第二实参，以及 README 对里已完成的
  Dev Note 开放项（重录侧车）。测试三处调用点去实参；「duplicate display name」用例
  改用两个同末段目录造重名，仍真正覆盖原契约。
  新增自检：`create` 的 arity 必须为 1（决定性——加回参数即失败）。
  **验证**：workspace + workspace-controller + webhook → 14 files / 168 tests passed；
  `typecheck` exit 0；`test:docs` 16 passed；`verify-translation-pairing` 810 pair(s) consistent。

- [x] **`devFreeze` 的运行时 NODE_ENV 判断「是死代码」** — 判定反转：**不是死代码，是生产 bug**（第 3 轮）
  根因不在 `store`，在构建预设：`tsdown.client.ts` 的动态面 `clientConfig` 有
  `define`，静态面 `staticLinkedConfig` 没有。`platform: 'browser'` 下 rolldown 把
  未定义的 `process.env` 换成 `{}` → `=== 'production'` 折叠为 `false` →
  **开发分支进入生产产物**，`devFreeze` 在生产下也无条件深冻结。
  「产物里 `process.env` 出现 0 次」属实，但被误读成「define 已静态消除」。
  **修法**：抽出 `browserEnvironmentDefines()`，两个构建面都用；
  `scripts/client-bundle-purity.spec.ts` 加断言钉住两个面。
  **验证**：4 files / 51 tests passed；`pnpm run test:gui` 378 files / 5425 passed；
  `typecheck` exit 0；移除修复后新用例失败（决定性自检）。
  Agent Note：`2026-09-15-static-face-environment-defines.*`（三语）。

- [x] **`TODO(stop-loop-guard)`** — 连续强制续跑加上了上限（commit `4a4eee8020`）
  `hook-protocol` 新增 `createStopLoopCounts`（按 session+turn 计数、只留最高 key、
  内存态）；两个 bridge 各接 `stopLoopCap`（Config 字段，默认 8）。
  codex 的 `stop_hook_active` 硬编码 `false` 一并换成真实计数。
  **验证**：`env -u NODE_ENV npx vitest run packages/hooks` → 19 files / 215 tests passed；
  `pnpm run typecheck` → exit 0。
