#!/bin/bash
# tmux-send.sh v3 — 向 autopilot tmux pane 发送消息并按 Enter
# 用法: tmux-send.sh <window_name> <message>
#
# v3: 短消息 (<=150) 用 send-keys，长消息用 paste-buffer（绕过 TUI 输入限制）
# v2 的"写文件+自然语言指令"方案已废弃（Codex 不理解间接指令）

set -euo pipefail

TMUX="/opt/homebrew/bin/tmux"
SESSION="autopilot"
WINDOW="${1:?用法: tmux-send.sh <window> <message>}"
MESSAGE="${2:?缺少消息参数}"

# 检查 session 存在
if ! "$TMUX" has-session -t "$SESSION" 2>/dev/null; then
    echo "ERROR: tmux session '$SESSION' 不存在" >&2
    exit 1
fi

# 检查 window 存在
if ! "$TMUX" list-windows -t "$SESSION" -F '#{window_name}' | grep -qx "$WINDOW"; then
    echo "ERROR: window '$WINDOW' 不存在" >&2
    exit 1
fi

# 检查 codex 是否在运行（防止在 shell 里误执行）
PANE_CMD=$("$TMUX" list-panes -t "${SESSION}:${WINDOW}" -F '#{pane_current_command}' | head -1)
if [[ "$PANE_CMD" == "bash" || "$PANE_CMD" == "zsh" || "$PANE_CMD" == "sh" || "$PANE_CMD" == "fish" ]]; then
    echo "ERROR: window '$WINDOW' 中 codex 未运行 (当前: $PANE_CMD)，跳过发送" >&2
    exit 2
fi

# 多行合并为单行
SINGLE_LINE=$(echo "$MESSAGE" | tr '\n' ' ' | tr '\r' ' ' | sed 's/  */ /g; s/^ *//; s/ *$//')

MAX_DIRECT=150

if [ ${#SINGLE_LINE} -le $MAX_DIRECT ]; then
    # 短消息：直接 send-keys（最可靠）
    "$TMUX" send-keys -t "${SESSION}:${WINDOW}" -l "$SINGLE_LINE"
    sleep 0.2
    "$TMUX" send-keys -t "${SESSION}:${WINDOW}" Enter
    echo "OK: 已发送 ${#SINGLE_LINE} 字符到 ${SESSION}:${WINDOW}"
else
    # 长消息：通过 tmux paste-buffer 直接粘贴（与用户手动粘贴等效）
    TMPFILE=$(mktemp /tmp/tmux-paste.XXXXXX)
    printf '%s' "$SINGLE_LINE" > "$TMPFILE"

    "$TMUX" load-buffer -b autopilot-msg "$TMPFILE"
    "$TMUX" paste-buffer -b autopilot-msg -t "${SESSION}:${WINDOW}" -d
    rm -f "$TMPFILE"

    sleep 0.3
    "$TMUX" send-keys -t "${SESSION}:${WINDOW}" Enter
    echo "OK: 长消息(${#SINGLE_LINE}字符)通过 paste-buffer 发送到 ${SESSION}:${WINDOW}"
fi
