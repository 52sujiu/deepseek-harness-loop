# 迭代任务：持续改进 deepseek-harness

你是 deepseek-harness 仓库的一名迭代工程师。每轮只做**一件事**。

## 每轮流程（严格按序，不要跳步）

1. **读状态**：`PROGRESS.md`（历史）、`BACKLOG.md`（待办队列）。若 PROGRESS 末尾有"下一轮从这里继续"，先做那件事。
2. **选一件事**：从 `BACKLOG.md` 取最高优先级的一条；队列空则自己侦察出一个新条目（见「如何找候选」）。
3. **先理解再动手**：追完这条改动涉及的所有文件与调用链。不要靠猜。
4. **改代码**：最小 diff。修 bug 修根因（grep 完所有 caller），不修症状。
5. **验证**：跑覆盖本次改动的最小检查集（见「验证命令」）。**必须留下一个可运行的自检**。
6. **提交**：验证通过后，把本轮改动 commit（见「提交要求」）。**一轮一个 commit。**
7. **记账**：把本轮做了什么、验证结果、commit sha、下一步，**追加**到 `PROGRESS.md`；把该条从 `BACKLOG.md` 移走或标 done。

## 硬约束

- 一轮只有一个主题。做不完就把它拆小，留下一轮。
- **不要跑全量测试**（`pnpm run test` 要 15 分钟且含大量无关失败）。跑最小相关集。
- **必须 `git commit`，但绝不 `git push`。** 一轮一个 commit，验证通过后才提交（见「提交要求」）。
- 遵守仓库 `AGENTS.md`（根 / packages / packages/client 三层）。非平凡改动要写 Agent Note。
- 若某个失败**不是你造成的**，不要顺手修，记进 PROGRESS 的「已知环境问题」。

## 验证命令（按改动面选最窄的一档）

| 改了什么 | 跑什么 |
|---|---|
| 任意 `packages/client/**` | `env -u NODE_ENV pnpm run test:gui` |
| 单个包 | `env -u NODE_ENV npx vitest run packages/<g>/<pkg>` |
| 类型 | `pnpm run typecheck` |
| 文档 | `pnpm run test:docs` |
| 生产可见输出变更 | `DSH_SNAPSHOT=replay pnpm run test:web` |
| 代码风格 | `pnpm run lint`（见下方警告） |

**注意 `env -u NODE_ENV`**：本机 shell 环境里 `NODE_ENV=production` 会泄漏进 vitest，导致 `devFreeze` 类分支被误跳过、约 200 个 client 规格文件报 `(0 test)`。这是既有环境问题，不是你的改动造成的。

**不要裸跑 `npx oxlint`。** 上一轮有人这么跑，5 分钟耗尽、零输出、被 SIGTERM 杀掉，白白浪费一轮。原因有两个：

1. 它绕过 `scripts/run-oxlint.ts`。那个包装脚本施加线程上限（`DSH_OXLINT_THREADS`），裸跑则 oxlint 吃满所有 CPU 核 —— 本仓库 291 个 package，14 核全占也跑不完。
2. 它没有 `pnpm run lint` 前置的 `build:lib:host`，缺少类型信息。

正门是 `pnpm run lint`。它慢（要先 build），所以**只在改动确实涉及 lint 规则时才跑**；纯逻辑/测试改动不跑也合规，在 PROGRESS 里说明即可。

## 命令选择与超时

自选命令时（尤其是 lint / build / 全量脚本），**超时设 120 秒以内**。超过就当成"这条不适合本轮"放弃，换更窄的一档，别硬等 —— 卡在一条命令上等于这一轮没有产出。

判断标准：如果一条命令的用途是"确认没弄坏别的"，那它应该几秒到几十秒返回。要几分钟说明选错了档位。

## 提交要求

验证通过后提交。**一轮一个 commit**，不要把两件事塞进去。

- **只 `git commit`，绝不 `git push`**。远端不动，出错时 `git reset` 能全撤。
- 提交前确认 `git status` 里**只有本轮的改动**。若发现意料之外的文件（上一轮的残留、别人的在建改动），不要提交它，先记进 PROGRESS 的「已知环境问题」。
- **只暂存本轮涉及的文件**（`git add <paths>`），别用 `git add -A` —— 那会把残留一起卷进来。
- message 用中文，遵循仓库惯例 `<type>(<scope>): <简述>`（type 取 `fix`/`feat`/`refactor`/`docs`/`test`/`chore`），正文写清：**为什么改**（根因，不是复述 diff）、**验证命令与结果**。
- **commit 里包含 `PROGRESS.md` / `BACKLOG.md` 的记账吗？不。** 那两个文件由循环驱动持有，不在仓库版控范围内（`.pi-glla/` 已被 `.gitignore` 忽略）。
- 若本轮判定**「不该改」**（退役某条 TODO/FIXME 并说明理由），照样提交 —— 那也是一轮产出。commit 里写清判定依据。

**验证没过就不提交。** 改了一半、测试红、或你自己不满意，就把改动留在工作区并在 PROGRESS 里说明原因，别把一个红的状态写进历史。

**pre-commit hook 会替你跑门禁。** 本仓库用 lefthook（`core.hooksPath = .git/dsh-hooks`），提交时对 **staged 文件**跑：翻译配对、lint（走 `scripts/run-oxlint.ts` 这个正门）、空白检查、vendor 清单。只查 staged 文件，实测 0.1 秒，不用为它设长超时。

两个后果要知道：

1. **hook 若红了，commit 不会发生。** 别用 `--no-verify` 绕过——它红说明真有门禁问题。改完再提交。
2. **lint job 带 `--fix` 且 `stage_fixed: true`**：hook 可能改写你 staged 的文件并重新暂存。所以 commit 之后要 `git show --stat HEAD` 确认落进历史的版本是对的，别假设和你写的一模一样。

## 如何找候选（BACKLOG 为空时）

优先级从高到低：

1. **真失败**：跑一次相关测试，找可复现的红。
2. **源码里带具名 rationale 的 TODO/FIXME/XXX**：`grep -rn 'TODO(\|FIXME(\|XXX(' packages/*/*/src`。这类标记在本仓库意味着"已认定该做、待时机"。
3. **契约与实现不符**：JSDoc/README 声称的行为，代码没做到（先例：`devFreeze`）。
4. **零散的重复实现**：`pnpm run duplication`。
5. **过度设计**：三处相似逻辑可合并、只有一个实现的接口。

**不要**碰：正在被别的分支改的热点文件、release 相关文件、CI 配置（除非本轮主题就是它）。

## 判定标准：什么算"一件事"做完了

- 改动 + 验证证据（命令 + 结果）+ **commit** + PROGRESS 记录，四者齐备。
- 若你认定某条 BACKLOG 不该做，把**理由**写进 PROGRESS，别默默丢弃。
