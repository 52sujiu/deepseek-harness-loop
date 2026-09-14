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

- [ ] **`devFreeze` 的运行时 NODE_ENV 判断在产物中是死代码**（`packages/client/store/src/index.ts:170`）
  确认：`packages/client/store/lib/index.js`（tsdown staticLinked 产物）里 `process.env` 出现 **0 次**，`devFreeze` 已内联为无条件 `return freeze(value, true)`。即 dev/prod 分叉在产物里被 `define` 静态消除。
  **要做**：判断是否该删掉源码里的运行时判断（既然构建期已决定），以及 `tsdown.client.ts:478` 的 `?? 'production'` 默认值是否是真正的决策点。需先确认构建时替换用的是哪个 NODE_ENV 值、dev 构建是否真能走到另一分支。

## P1 — 具名 TODO（实现已认定该做）

- [ ] `packages/hooks/*/src/index.ts:188,171` — `TODO(hook-continue-false)`：`merged.stop` 已记录但缺 run-level 停机机制。
  **排在 stop-loop-guard 之后**：侦察确认它需要新的核心原语（拦截点没有「硬停机整轮」的能力），而循环守卫不需要。

- [ ] `packages/util/atomic-write/src/index.ts:83` — `TODO(settings-atomic-durability)`：替换后未 fsync。数据丢失面。
- [ ] `packages/shell/tool-bash-persistent/src/index.ts:14` 与 `tool-pwsh-persistent/src/index.ts:16` — 相同的 TODO：文件搜索建议对任意命令输出不适用。**两个包重复的注释 = 重复的实现**，查一下是否可以直接抽掉。

## 已评估 — 结论是不做（勿重复劳动）

- [x] ~~`packages/settings/settings/src/redact.ts:87` — `TODO(settings-wire-redaction)`~~ **判定：不改**
  `walk()` 只处理 `object`/`dict`/`array`，其余走 `default:` 原样返回 —— 但**当前不可达**：全仓库非测试 `src/` 里唯一的 `role('secret')` 是 `web-search-deepseek/src/index.ts:64` 的顶层 `apiKey`，走 `object` 分支被正确剥离。四个 shipped union（llm-deepseek:181-191、llm-pi-ai config.ts:243-337、permission-presets:167-213、ui-theme theme-settings.ts:42）都不包裹 secret。
  在 `walk()` 里 throw 会**打断四个正常工作的 union**；真正的 fail-closed 属于 `register()`（即 README 已记录的 `describeForWire()`），是明确更大的改动。
  **只有第三方插件注册「union 包裹的 secret」时才变成真问题** —— 等那时再做。

## P2 — 契约与实现不符（需先确认是否真问题）

- [ ] `packages/settings/settings/src/index.ts:78` — `TODO(settings-namespace-vocabulary)`：`ns` 应改名 `namespace`。跨模块改动，需评估面。
- [ ] `packages/workspace/workspace/src/index.ts:152` — `title` 已失去最后的 production 调用者。**可能是可直接删除的死字段**——先确认，能删就是纯收益。
- [ ] `packages/guard/timeout-policy/src/index.ts:6` — `FIXME`：`dsh-timeout-guard` 改名悬而未决。先判断是否还打算改，不打算就把 FIXME 降级成说明。

## P3 — 架构 / 新工具

- [ ] 审查 `packages/e2b/**` 的 8 处 TODO：这是 POC 区，需判断哪些是真要在 E2B 上游改动后才能做（那就留文档）、哪些只是没做完。
- [ ] `pnpm run duplication`：跑一次，看跨文件克隆分布。

---

## Done

- [x] **`TODO(stop-loop-guard)`** — 连续强制续跑加上了上限（commit `4a4eee8020`）
  `hook-protocol` 新增 `createStopLoopCounts`（按 session+turn 计数、只留最高 key、
  内存态）；两个 bridge 各接 `stopLoopCap`（Config 字段，默认 8）。
  codex 的 `stop_hook_active` 硬编码 `false` 一并换成真实计数。
  **验证**：`env -u NODE_ENV npx vitest run packages/hooks` → 19 files / 215 tests passed；
  `pnpm run typecheck` → exit 0。
