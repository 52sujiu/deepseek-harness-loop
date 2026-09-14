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
#
# 模型走本地 WorkBuddy relay（和 TUI 同一个模型），不走官方 deepseek-official：
# TUI 里那条路由叫 pi-workbuddy，但 headless 只认 llm-pi-ai 按 settings key
# 注册的名字 workbuddy —— 写成 pi-workbuddy 会 NO_ADAPTER。
# relay 声明 supportsReasoningEffort: false，所以这里不能设 reasoningEffort，
# 否则 UNSUPPORTED_REASONING_EFFORT；凭证是本地 relay 的占位串，不是密钥。
MODEL="${MODEL:-deepseek-v4.1-flash}"
MODEL_PROVIDER="${MODEL_PROVIDER:-workbuddy}"
RELAY_BASE_URL="${RELAY_BASE_URL:-http://127.0.0.1:8787/v1}"
LOOP_HOME="${LOOP_HOME:-$PWD/.pi-glla/loop/home}"
mkdir -p "$LOOP_HOME"
if [[ ! -f "$LOOP_HOME/settings.yaml" ]]; then
  cat > "$LOOP_HOME/settings.yaml" <<EOF
# 迭代循环专用 settings，由 loop.sh 首次运行时生成。
# 换模型：删掉本文件重跑，或直接改这里。
llm-pi-ai:
  providers:
    workbuddy:
      displayName: WorkBuddy (local relay)
      baseURL: ${RELAY_BASE_URL}
      api: openai-completions
      apiKeyEnv: WORKBUDDY_API_KEY
      compat:
        supportsDeveloperRole: false
        supportsReasoningEffort: false
      models:
        - id: deepseek-v4.1-flash
          name: Deepseek-V4.1-Flash (WorkBuddy)
          contextWindow: 300000
          maxTokens: 128000
agent-default-model:
  provider: ${MODEL_PROVIDER}
  model: ${MODEL}
permission:
  defaultPreset: danger-full-access
EOF
  # 凭证按 key 文件共享，避免复制密钥。
  for f in .credentials.yaml .anonymous-user-id; do
    [[ -f "$HOME/.dsh/$f" && ! -e "$LOOP_HOME/$f" ]] && ln -s "$HOME/.dsh/$f" "$LOOP_HOME/$f"
  done
fi
export DSH_HOME="$LOOP_HOME"
# 本地 relay 的占位凭证；真实密钥类路由才需要各自的环境变量。
export WORKBUDDY_API_KEY="${WORKBUDDY_API_KEY:-local-relay}"

# ── 无损压缩（context-mode 策略）───────────────────────────────────────────
# headless 默认挂的是官方 compaction-basic：八段式摘要，工具输出没有自己的
# 段落，压掉的原始内容不可恢复。myharness preset 里换成了 context-mode 的
# 子类（precompact 先把 span 存进知识库，再补 Conversation Transcript +
# Archive Index，每个被裁的位置都留 source 指针）。headless 不加载 preset，
# 所以这里用 --patch overlay 复刻同样的效果。
#
# 为什么是 disabled + insert 而不是直接改 name：--patch 按 id 定位时不允许
# 改 name（"name mismatch ... skipping"），只能关掉原行再插一行。
# 这也是上游 wire.mjs 存在的原因——它在 preset 文件里改那一行。
#
# 两个包都从 dsh-tui profile 的 node_modules 解析：DSH 的 preset/patch 行
# 用相对路径时按所在目录解析，裸包名则从 harness base 解析，用户装的第三方
# 包在 base 里不可见。
CMC_MODULE="$HOME/.dsh/profiles/dsh-tui/node_modules/dsh-context-mode-compaction/lib/types/index.js"
CM_MODE_MODULE="$HOME/.dsh/profiles/dsh-tui/node_modules/dsh-context-mode/lib/types/index.js"
for f in "$CMC_MODULE" "$CM_MODE_MODULE"; do
  [[ -f "$f" ]] || { echo "缺压缩包：$f（npm i -g 或装到 dsh-tui profile），退出。"; exit 1; }
done
CMC_PATCH="$LOOP_DIR/cmc.patch.yml"
cat > "$CMC_PATCH" <<EOF
# 由 loop.sh 生成，勿手改。把官方 compaction-basic 换成 context-mode 无损策略。
- id: compaction-basic
  disabled: true

- insert:
    - id: cmc-compaction
      name: '${CMC_MODULE}'
      config:
        thresholdRatio: 0.8
        retainRatio: 0.1

    - id: dsh-context-mode
      name: '${CM_MODE_MODULE}'
      inject: [tools, systemPrompt]
      config:
        enabled: true
EOF

# 单实例锁：并发跑会互相覆盖 PROGRESS.md。mkdir 是原子的，macOS 无 flock。
mkdir "$LOOP_DIR/.lock" 2>/dev/null || { echo "已有 loop 在跑（$LOOP_DIR/.lock），退出。"; exit 1; }

# Ctrl-C：明确告诉人"这是你按的"，而不是留下一句像崩溃的 ELIFECYCLE。
# pnpm 在跑任意 script 前会做 depsStatusCheck，不同步时自动 install；
# 此时被中断，pnpm 会把 SIGINT 报成 "Command failed with exit code 1"。
interrupted=0
trap 'interrupted=1; echo; echo "已中断（Ctrl-C）。本轮作废，PROGRESS.md 未被写入。"; rmdir "$LOOP_DIR/.lock" 2>/dev/null; exit 130' INT TERM
trap 'rmdir "$LOOP_DIR/.lock" 2>/dev/null' EXIT

# 前置检查：relay 不通、依赖没装好，10 轮全废，不如现在停。
if [[ "${DRY:-0}" != "1" ]]; then
  command -v pnpm >/dev/null || { echo "缺 pnpm，退出。"; exit 1; }
  if ! curl -sf -m 5 -o /dev/null "${RELAY_BASE_URL%/v1}/v1/models" 2>/dev/null \
     && ! curl -sf -m 5 -o /dev/null "$RELAY_BASE_URL/models" 2>/dev/null; then
    echo "WorkBuddy relay（$RELAY_BASE_URL）不可达，退出。"; exit 1
  fi
  # 预热依赖：pnpm 会在每次 run script 前校验依赖状态，不同步就自动 install。
  # 放到循环外跑一次，中途就不会突然卡住几百秒（也免得被 Ctrl-C 打断时
  # 看到一句莫名其妙的 "Command failed with exit code 1"）。
  #
  # CI=true 是必需的，不是可选的：pnpm 要重建 node_modules 时会先问一句，
  # 非交互环境下它直接中止并报 ERR_PNPM_ABORTED_REMOVE_MODULES_DIR_NO_TTY。
  # 循环本来就不该有人在旁边敲 y。
  echo "校验依赖状态（首次可能要一两分钟，请等它跑完再 Ctrl-C）..."
  if ! CI=true pnpm install --frozen-lockfile >/dev/null 2>&1; then
    echo "依赖校验失败，先手动跑 pnpm install 看报错，退出。"; exit 1
  fi
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
  # tee 默认块缓冲：一轮跑完才落盘，中途 `tail -f` 看不到任何东西。
  # stdbuf 强制行缓冲（macOS 走 gstdbuf；都没有就退回原样，只是实时性差些）。
  if command -v stdbuf >/dev/null; then
    BUFFER=(stdbuf -oL -eL)
  elif command -v gstdbuf >/dev/null; then
    BUFFER=(gstdbuf -oL -eL)
  else
    BUFFER=()
  fi

  # 心跳：模型思考时可能几分钟没有任何输出，不报点什么会让人以为死了。
  ( while :; do
      sleep 30
      printf '   ... 第 %s 轮进行中（已 %ss，日志 %s）\n' "$i" "$SECONDS" "$(wc -l < "$log" 2>/dev/null || echo 0)行"
    done ) &
  heartbeat=$!

  run_timed "${BUFFER[@]}" pnpm dsh --profile headless --patch "$CMC_PATCH" "$task" 2>&1 | tee "$log"
  rc="${PIPESTATUS[0]}"
  kill "$heartbeat" 2>/dev/null; wait "$heartbeat" 2>/dev/null

  if (( rc == 0 )); then
    echo "── iteration ${i}: completed (model ${MODEL})"
  elif (( rc == 124 )); then
    echo "── iteration ${i}: timed out after ${TASK_TIMEOUT}s (${log})"
  elif (( rc == 130 )); then
    echo "── iteration ${i}: interrupted"
    break
  else
    echo "── iteration ${i}: failed (exit ${rc})"
    # 失败时把决定性的一行挑出来，别让人去翻整个 log。
    grep -aE '^dsh: |^\[ERROR\]|Error:|error:|ERR_PNPM' "$log" 2>/dev/null | head -5 | sed 's/^/     /'
    echo "     （完整日志 ${log}）"
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
