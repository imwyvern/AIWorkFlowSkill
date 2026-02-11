#!/bin/bash
# codex-status.sh v3 — 确定性检测 Codex TUI 状态
# 用法: codex-status.sh <window_name>
# 输出 JSON: {"status":"<state>","context":"XX%","context_num":N,...}
# 状态: working | idle | idle_low_context | permission | permission_with_remember | shell | absent
# Exit codes: 0=working, 1=idle/permission, 2=shell, 3=absent/error

set -euo pipefail

TMUX="/opt/homebrew/bin/tmux"
SESSION="autopilot"
WINDOW="${1:?用法: codex-status.sh <window>}"

# ---- 基础检查 ----
if ! "$TMUX" has-session -t "$SESSION" 2>/dev/null; then
    echo '{"status":"absent","detail":"tmux session not found"}'
    exit 3
fi

if ! "$TMUX" list-windows -t "$SESSION" -F '#{window_name}' | grep -qx "$WINDOW"; then
    echo '{"status":"absent","detail":"window not found"}'
    exit 3
fi

PANE_CMD=$("$TMUX" list-panes -t "${SESSION}:${WINDOW}" -F '#{pane_current_command}' | head -1)

if [[ "$PANE_CMD" == "bash" || "$PANE_CMD" == "zsh" || "$PANE_CMD" == "sh" || "$PANE_CMD" == "fish" ]]; then
    echo "{\"status\":\"shell\",\"detail\":\"pane running $PANE_CMD\"}"
    exit 2
fi

# ---- 捕获 pane 输出 ----
PANE=$("$TMUX" capture-pane -t "${SESSION}:${WINDOW}" -p -S -25 2>&1)

# ---- 提取 context ----
CONTEXT=$(echo "$PANE" | grep -o '[0-9]*% context left' | tail -1 | grep -o '[0-9]*%' || echo "unknown")
CONTEXT_NUM=$(echo "$CONTEXT" | tr -d '%')
# 安全处理：非数字时设为 -1（标记为 unknown）
if ! [[ "$CONTEXT_NUM" =~ ^[0-9]+$ ]]; then
    CONTEXT_NUM=-1
fi

# ============================================================
# 检测 1: "esc to interrupt" — 100% 确定性工作中标志
# ============================================================
if echo "$PANE" | grep -qE "esc to interrupt"; then
    LAST_ACTIVITY=$(echo "$PANE" | grep -oE "• [A-Z][^ │(]*[^│(]*" | tail -1 | head -c 120 || echo "")
    echo "{\"status\":\"working\",\"context\":\"$CONTEXT\",\"context_num\":$CONTEXT_NUM,\"last_activity\":\"$LAST_ACTIVITY\"}"
    exit 0
fi

# ---- 取活动区域（跳过底栏）----
ACTIVITY_LINES=$(echo "$PANE" | tail -15 | head -12)

# ============================================================
# 检测 2: "• <Verb>" 活动行
#   a) 通用后缀: (ing|ed|te|d|ote) + 空格
#   b) 不规则动词白名单: Ran, Wrote, Read, Built, Sent, Found, Made, Took, Set, Got, Put, Did
#   c) 独立动词 + └ 树形输出
#   d) 特殊短语
# ============================================================

# 2a + 2b: 通用 + 不规则
if echo "$ACTIVITY_LINES" | grep -qE "^  ?• ([A-Z][a-z]+(ing|ed|te|d|ote) |Ran |Wrote |Read |Set |Got |Put |Did |Built |Sent |Found |Made |Took )"; then
    LAST_ACTIVITY=$(echo "$ACTIVITY_LINES" | grep -oE "• [A-Z][a-z]+ [^│]*" | tail -1 | head -c 120 || echo "")
    echo "{\"status\":\"working\",\"context\":\"$CONTEXT\",\"context_num\":$CONTEXT_NUM,\"last_activity\":\"$LAST_ACTIVITY\"}"
    exit 0
fi

# 2c: 独立动词行 + 下一行有 └
if echo "$ACTIVITY_LINES" | grep -qE "^  ?• [A-Z][a-z]+$" && echo "$ACTIVITY_LINES" | grep -qE "^ +└"; then
    LAST_ACTIVITY=$(echo "$ACTIVITY_LINES" | grep -oE "• [A-Z][a-z]+" | tail -1 | head -c 120 || echo "")
    echo "{\"status\":\"working\",\"context\":\"$CONTEXT\",\"context_num\":$CONTEXT_NUM,\"last_activity\":\"$LAST_ACTIVITY\"}"
    exit 0
fi

# 2d: 特殊短语
if echo "$ACTIVITY_LINES" | grep -qE "^  ?• (Context compacted|Waiting for background|Compacting context)"; then
    LAST_ACTIVITY=$(echo "$ACTIVITY_LINES" | grep -oE "• (Context compacted|Waiting for background|Compacting context)" | tail -1 | head -c 120 || echo "")
    echo "{\"status\":\"working\",\"context\":\"$CONTEXT\",\"context_num\":$CONTEXT_NUM,\"last_activity\":\"$LAST_ACTIVITY\"}"
    exit 0
fi

# ============================================================
# 检测 3: 权限确认
# ============================================================
if echo "$ACTIVITY_LINES" | grep -qE "Yes, proceed|Press enter to confirm|don't ask again|Allow once|Allow always"; then
    if echo "$ACTIVITY_LINES" | grep -qE "don't ask again|Allow always"; then
        echo "{\"status\":\"permission_with_remember\",\"context\":\"$CONTEXT\",\"context_num\":$CONTEXT_NUM,\"detail\":\"can permanently allow\"}"
    else
        echo "{\"status\":\"permission\",\"context\":\"$CONTEXT\",\"context_num\":$CONTEXT_NUM,\"detail\":\"waiting for permission\"}"
    fi
    exit 1
fi

# ============================================================
# 检测 4: 空转 — 区分低 context 和正常
# ============================================================
PROMPT_LINE=$(echo "$PANE" | grep "^›" | tail -1 | head -c 120 || echo "")

# context unknown 时不触发 compact（可能 TUI 还没渲染完），当普通 idle
if [ "$CONTEXT_NUM" -ge 1 ] && [ "$CONTEXT_NUM" -le 25 ]; then
    echo "{\"status\":\"idle_low_context\",\"context\":\"$CONTEXT\",\"context_num\":$CONTEXT_NUM,\"prompt\":\"$PROMPT_LINE\"}"
    exit 1
fi

echo "{\"status\":\"idle\",\"context\":\"$CONTEXT\",\"context_num\":$CONTEXT_NUM,\"prompt\":\"$PROMPT_LINE\"}"
exit 1
