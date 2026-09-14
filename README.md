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
```

前置条件：`pnpm`、`DEEPSEEK_API_KEY`（或仓库根 `.env`）。

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
