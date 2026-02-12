#!/bin/bash
# tmux-send.sh v5 — 向 autopilot tmux pane 发送消息并按 Enter
# 用法: tmux-send.sh <window_name> <message>
#
# v5: 三级发送策略 + 验证 + 重试
#   Level 1: send-keys -l (≤300 字符，最可靠)
#   Level 2: 分块 send-keys (≤800 字符，每 100 字符一块 + 50ms 延迟)
#   Level 3: paste-buffer -p (bracketed paste mode，>800 字符)
#   所有级别: 发送后验证 prompt 是否包含消息前缀，失败则降级重试
#
# v4: paste-buffer 无 bracketed paste，TUI 框架不识别 → 消息丢失
# v3: 长消息 paste-buffer（有 bug），短消息 send-keys

set -euo pipefail

TMUX="/opt/homebrew/bin/tmux"
SESSION="autopilot"
WINDOW="${1:?用法: tmux-send.sh <window> <message>}"
MESSAGE="${2:?缺少消息参数}"
LOCK_DIR="$HOME/.autopilot/locks"
STATE_DIR="$HOME/.autopilot/state"
mkdir -p "$LOCK_DIR" "$STATE_DIR"

# ---- 配置 ----
MAX_DIRECT=300          # send-keys -l 直发上限（中文 ~100 字）
MAX_CHUNKED=800         # 分块 send-keys 上限
CHUNK_SIZE=100          # 每块字符数
CHUNK_DELAY=0.05        # 块间延迟（秒）
VERIFY_WAIT=0.5         # 发送后等待验证的时间（秒）
VERIFY_PREFIX_LEN=20    # 验证时取消息前 N 字符匹配
MAX_RETRIES=2           # 最大重试次数（含降级）

sanitize() {
    echo "$1" | tr -cd 'a-zA-Z0-9_-'
}

normalize_int() {
    local val
    val=$(echo "${1:-}" | tr -dc '0-9')
    echo "${val:-0}"
}

log() {
    echo "[tmux-send $(date '+%H:%M:%S')] $*" >&2
}

SAFE_WINDOW="$(sanitize "$WINDOW")"
[ -n "$SAFE_WINDOW" ] || SAFE_WINDOW="window"
SEND_LOCK="${LOCK_DIR}/tmux-send-${SAFE_WINDOW}.lock.d"

acquire_send_lock() {
    if mkdir "$SEND_LOCK" 2>/dev/null; then
        echo "$$" > "${SEND_LOCK}/pid"
        return 0
    fi

    local existing_pid
    existing_pid=$(cat "${SEND_LOCK}/pid" 2>/dev/null || echo 0)
    existing_pid=$(normalize_int "$existing_pid")
    if [ "$existing_pid" -gt 0 ] && kill -0 "$existing_pid" 2>/dev/null; then
        return 1
    fi

    rm -rf "$SEND_LOCK" 2>/dev/null || true
    mkdir "$SEND_LOCK" 2>/dev/null || return 1
    echo "$$" > "${SEND_LOCK}/pid"
    return 0
}

if ! acquire_send_lock; then
    echo "ERROR: send lock busy for window '$WINDOW'" >&2
    exit 3
fi

TMPFILE=""
BUFFER_NAME=""
cleanup() {
    if [ -n "$BUFFER_NAME" ]; then
        "$TMUX" delete-buffer -b "$BUFFER_NAME" >/dev/null 2>&1 || true
    fi
    if [ -n "$TMPFILE" ] && [ -f "$TMPFILE" ]; then
        rm -f "$TMPFILE"
    fi
    rm -rf "$SEND_LOCK" 2>/dev/null || true
}
trap cleanup EXIT

# ---- 前置检查 ----
if ! "$TMUX" has-session -t "$SESSION" 2>/dev/null; then
    echo "ERROR: tmux session '$SESSION' 不存在" >&2
    exit 1
fi

if ! "$TMUX" list-windows -t "$SESSION" -F '#{window_name}' | grep -qx "$WINDOW"; then
    echo "ERROR: window '$WINDOW' 不存在" >&2
    exit 1
fi

PANE_CMD=$("$TMUX" list-panes -t "${SESSION}:${WINDOW}" -F '#{pane_current_command}' | head -1)
if [[ "$PANE_CMD" == "bash" || "$PANE_CMD" == "zsh" || "$PANE_CMD" == "sh" || "$PANE_CMD" == "fish" ]]; then
    echo "ERROR: window '$WINDOW' 中 codex 未运行 (当前: $PANE_CMD)，跳过发送" >&2
    exit 2
fi

# ---- 消息预处理 ----
SINGLE_LINE=$(echo "$MESSAGE" | tr '\n' ' ' | tr '\r' ' ' | sed 's/  */ /g; s/^ *//; s/ *$//')
MSG_LEN=${#SINGLE_LINE}

# ---- 验证函数：检查消息是否进入了 Codex prompt ----
verify_message_in_prompt() {
    sleep "$VERIFY_WAIT"
    local pane_content
    pane_content=$("$TMUX" capture-pane -t "${SESSION}:${WINDOW}" -p 2>/dev/null | tail -5)
    
    # 取消息前 VERIFY_PREFIX_LEN 个字符作为匹配目标
    local prefix="${SINGLE_LINE:0:$VERIFY_PREFIX_LEN}"
    
    if echo "$pane_content" | grep -qF "$prefix"; then
        return 0  # 验证通过
    fi
    
    # 有时 TUI 已经开始处理（显示 "Working" / "Thinking"），也算成功
    if echo "$pane_content" | grep -qE '(esc to interrupt|Working|Thinking|Exploring|Ran )'; then
        return 0
    fi
    
    return 1  # 验证失败
}

# ---- Level 1: send-keys 直发 ----
send_direct() {
    log "Level 1: send-keys 直发 (${MSG_LEN} 字符)"
    "$TMUX" send-keys -t "${SESSION}:${WINDOW}" -l "$SINGLE_LINE"
    sleep 0.2
    "$TMUX" send-keys -t "${SESSION}:${WINDOW}" Enter
}

# ---- Level 2: 分块 send-keys ----
send_chunked() {
    log "Level 2: 分块 send-keys (${MSG_LEN} 字符, 块大小 ${CHUNK_SIZE})"
    local offset=0
    local remaining="$MSG_LEN"
    
    while [ "$offset" -lt "$MSG_LEN" ]; do
        local chunk="${SINGLE_LINE:$offset:$CHUNK_SIZE}"
        "$TMUX" send-keys -t "${SESSION}:${WINDOW}" -l "$chunk"
        offset=$((offset + CHUNK_SIZE))
        
        # 块间延迟，让 TUI 有时间处理输入缓冲
        if [ "$offset" -lt "$MSG_LEN" ]; then
            sleep "$CHUNK_DELAY"
        fi
    done
    
    sleep 0.2
    "$TMUX" send-keys -t "${SESSION}:${WINDOW}" Enter
}

# ---- Level 3: paste-buffer (bracketed paste mode) ----
send_paste_buffer() {
    log "Level 3: paste-buffer -p bracketed paste (${MSG_LEN} 字符)"
    TMPFILE=$(mktemp /tmp/tmux-paste.XXXXXX)
    printf '%s' "$SINGLE_LINE" > "$TMPFILE"
    
    BUFFER_NAME="autopilot-msg-${SAFE_WINDOW}-$$-$(date +%s)-${RANDOM}"
    "$TMUX" load-buffer -b "$BUFFER_NAME" "$TMPFILE"
    
    # -p = bracketed paste mode (发送 \e[200~ ... \e[201~ 序列)
    # 这让 TUI 框架正确识别为粘贴操作而非逐键输入
    "$TMUX" paste-buffer -b "$BUFFER_NAME" -t "${SESSION}:${WINDOW}" -d -p
    BUFFER_NAME=""
    
    sleep 0.5
    "$TMUX" send-keys -t "${SESSION}:${WINDOW}" Enter
    
    rm -f "$TMPFILE"
    TMPFILE=""
}

# ---- 主发送逻辑：三级策略 + 验证 + 重试 ----
send_success=false

if [ "$MSG_LEN" -le "$MAX_DIRECT" ]; then
    # 短消息：Level 1 直发
    send_direct
    if verify_message_in_prompt; then
        send_success=true
    else
        log "Level 1 验证失败，重试一次"
        # 清除可能的残留输入
        "$TMUX" send-keys -t "${SESSION}:${WINDOW}" C-u
        sleep 0.3
        send_direct
        if verify_message_in_prompt; then
            send_success=true
        else
            log "Level 1 重试失败，降级到 Level 2"
            "$TMUX" send-keys -t "${SESSION}:${WINDOW}" C-u
            sleep 0.3
            send_chunked
            verify_message_in_prompt && send_success=true
        fi
    fi

elif [ "$MSG_LEN" -le "$MAX_CHUNKED" ]; then
    # 中等消息：Level 2 分块
    send_chunked
    if verify_message_in_prompt; then
        send_success=true
    else
        log "Level 2 验证失败，降级到 Level 3"
        "$TMUX" send-keys -t "${SESSION}:${WINDOW}" C-u
        sleep 0.3
        send_paste_buffer
        if verify_message_in_prompt; then
            send_success=true
        else
            log "Level 3 也失败，最后尝试截断用 Level 1"
            "$TMUX" send-keys -t "${SESSION}:${WINDOW}" C-u
            sleep 0.3
            # 截断到 MAX_DIRECT 长度，保证能发出去
            SINGLE_LINE="${SINGLE_LINE:0:$MAX_DIRECT}"
            MSG_LEN=${#SINGLE_LINE}
            send_direct
            verify_message_in_prompt && send_success=true
        fi
    fi

else
    # 超长消息：Level 3 paste-buffer
    send_paste_buffer
    if verify_message_in_prompt; then
        send_success=true
    else
        log "Level 3 验证失败，截断到 ${MAX_CHUNKED} 用 Level 2 重试"
        "$TMUX" send-keys -t "${SESSION}:${WINDOW}" C-u
        sleep 0.3
        SINGLE_LINE="${SINGLE_LINE:0:$MAX_CHUNKED}"
        MSG_LEN=${#SINGLE_LINE}
        send_chunked
        verify_message_in_prompt && send_success=true
    fi
fi

# ---- 结果输出 ----
if $send_success; then
    echo "OK: 已发送 ${MSG_LEN} 字符到 ${SESSION}:${WINDOW}"
    # 标记手动任务发送
    date +%s > "${STATE_DIR}/manual-task-${SAFE_WINDOW}"
    exit 0
else
    # 即使验证失败，消息可能已经被 Codex 接收并开始处理
    # （verify 检查的是 prompt 显示，但 Codex 可能已经在 Working 状态）
    log "WARNING: 验证未通过，但消息可能已被接收"
    echo "WARN: 发送 ${MSG_LEN} 字符到 ${SESSION}:${WINDOW}，但验证未确认"
    date +%s > "${STATE_DIR}/manual-task-${SAFE_WINDOW}"
    exit 0  # 不报错，避免阻塞调用方
fi
