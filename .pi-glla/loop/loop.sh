#!/usr/bin/env bash
# 驱动 dsh 循环迭代。每轮一个全新 headless session，状态靠磁盘文件交接。
#
#   ./.pi-glla/loop/loop.sh              # 默认 10 轮
#   MAX=3 ./.pi-glla/loop/loop.sh        # 跑 3 轮
#   DRY=1 ./.pi-glla/loop/loop.sh        # 只打印不执行
#   TASK_TIMEOUT=1800 ... loop.sh        # 单轮墙钟上限（秒），默认 30 分钟
#   MODEL=deepseek-v4-pro ... loop.sh    # 换模型（改的是循环专用 DSH_HOME）
#
# 终止条件：达到 MAX / PROGRESS.md 首行 DONE / PROGRESS.md 不再增长 /
#           连续两轮非零退出。
set -uo pipefail
cd "$(dirname "$0")/../.."

MAX="${MAX:-10}"
LOOP_DIR=".pi-glla/loop"
LOG_DIR="$LOOP_DIR/logs"
TASK_TIMEOUT="${TASK_TIMEOUT:-1800}"
mkdir -p "$LOG_DIR"

# 关键：清掉泄漏的 NODE_ENV，否则 client 规格整体加载失败。
unset NODE_ENV

# 循环专用 DSH_HOME：headless 读的是全局 ~/.dsh/settings.yaml，其中的
# agent-default-model 段会盖掉 --patch 的 composition entry（已实测：
# settings 有 deepseek-flash 时，patch 指定 v4-pro 仍然跑 deepseek-flash）。
# 要让循环跑固定模型，只能给它一份自己的 home —— 顺带也隔离了会话与凭证，
# 循环跑挂不会污染你日常的 dsh 状态。
MODEL="${MODEL:-deepseek-flash}"
LOOP_HOME="${LOOP_HOME:-$PWD/.pi-glla/loop/home}"
mkdir -p "$LOOP_HOME"
if [[ ! -f "$LOOP_HOME/settings.yaml" ]]; then
  cat > "$LOOP_HOME/settings.yaml" <<EOF
# 迭代循环专用 settings，由 loop.sh 首次运行时生成。
# 想换模型改这里，或跑 MODEL=... loop.sh 重新生成。
agent-default-model:
  provider: deepseek-official
  model: ${MODEL}
  reasoningEffort: high
permission:
  defaultPreset: danger-full-access
EOF
  # 凭证按 key 文件共享，避免复制密钥。
  for f in .credentials.yaml .anonymous-user-id; do
    [[ -f "$HOME/.dsh/$f" && ! -e "$LOOP_HOME/$f" ]] && ln -s "$HOME/.dsh/$f" "$LOOP_HOME/$f"
  done
fi
export DSH_HOME="$LOOP_HOME"

# 单实例锁：并发跑会互相覆盖 PROGRESS.md。mkdir 是原子的，macOS 无 flock。
mkdir "$LOOP_DIR/.lock" 2>/dev/null || { echo "已有 loop 在跑（$LOOP_DIR/.lock），退出。"; exit 1; }
trap 'rmdir "$LOOP_DIR/.lock" 2>/dev/null' EXIT

# 前置检查：缺 key 时 10 轮全废，不如现在停。
if [[ "${DRY:-0}" != "1" ]]; then
  if [[ -z "${DEEPSEEK_API_KEY:-}" && ! -f .env && ! -e "$LOOP_HOME/.credentials.yaml" ]]; then
    echo "缺 DEEPSEEK_API_KEY、.env 与凭证文件，退出。"; exit 1
  fi
  command -v pnpm >/dev/null || { echo "缺 pnpm，退出。"; exit 1; }
fi

# macOS 不自带 timeout（GNU coreutils 装成 gtimeout）。
if command -v timeout >/dev/null; then
  run_timed() { timeout "$TASK_TIMEOUT" "$@"; }
elif command -v gtimeout >/dev/null; then
  run_timed() { gtimeout "$TASK_TIMEOUT" "$@"; }
else
  run_timed() { "$@"; }
fi

prev_size=$(wc -c < "$LOOP_DIR/PROGRESS.md" 2>/dev/null | tr -d ' \t' || echo 0)
if [[ -z "$prev_size" ]]; then prev_size=0; fi
stall=0

for i in $(seq 1 "$MAX"); do
  echo "════════ iteration $i/$MAX ════════"

  if head -1 "$LOOP_DIR/PROGRESS.md" 2>/dev/null | grep -q '^DONE'; then
    echo "PROGRESS.md 标记 DONE，停止。"
    break
  fi

  task="$(cat "$LOOP_DIR/TASK.md")

---
## 当前进度（PROGRESS.md 末尾）
$(tail -40 "$LOOP_DIR/PROGRESS.md" 2>/dev/null || echo '（空，这是第一轮：先做侦察并建立 BACKLOG.md）')
---
## 待办队列（BACKLOG.md）
$(cat "$LOOP_DIR/BACKLOG.md" 2>/dev/null || echo '（空，本轮请自行侦察并填充）')"

  if [[ "${DRY:-0}" == "1" ]]; then
    echo "$task" | head -20
    continue
  fi

  log="$LOG_DIR/iter-$i.log"
  run_timed pnpm dsh --profile headless "$task" 2>&1 | tee "$log"
  rc="${PIPESTATUS[0]}"

  if (( rc == 0 )); then
    echo "── iteration ${i}: completed (model ${MODEL})"
  elif (( rc == 124 )); then
    echo "── iteration ${i}: timed out after ${TASK_TIMEOUT}s (${log})"
  else
    echo "── iteration ${i}: failed (exit ${rc})"
  fi

  # 每轮留一份 diff：改动互相污染时能归因到具体轮次。
  git diff > "$LOG_DIR/iter-${i}.diff" 2>/dev/null || true

  # 无进展判定：PROGRESS.md 没变长就是没记账（重写历史也算，故用长度而非哈希）。
  cur_size=$(wc -c < "$LOOP_DIR/PROGRESS.md" 2>/dev/null | tr -d ' \t')
  if [[ -z "$cur_size" ]]; then cur_size=0; fi
  if (( rc == 0 && cur_size <= prev_size )); then
    stall=$((stall + 1))
    echo "── iteration ${i}: PROGRESS.md 未增长 (${prev_size} -> ${cur_size}), stall=${stall}"
  elif (( rc != 0 )); then
    stall=$((stall + 1))
  else
    stall=0
  fi
  prev_size=$cur_size

  if (( stall >= 2 )); then
    echo "连续两轮无进展，停止。看 ${LOG_DIR}/iter-${i}.log"
    break
  fi
done

echo "循环结束。日志与每轮 diff 在 $LOG_DIR/"
