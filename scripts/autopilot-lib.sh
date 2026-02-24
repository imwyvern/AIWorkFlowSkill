#!/bin/bash
# autopilot-lib.sh — shared utility functions for autopilot scripts
# Source this file: source "${SCRIPT_DIR}/autopilot-lib.sh"
#
# Provides:
#   normalize_int()        — sanitize to integer
#   sanitize()             — safe filename from window name
#   now_ts()               — current unix timestamp
#   run_with_timeout()     — macOS-compatible timeout wrapper
#   load_telegram_config() — sets LIB_TG_TOKEN and LIB_TG_CHAT
#   send_telegram()        — send Telegram message (background)
#   acquire_lock()         — mkdir-based lock with stale timeout
#   release_lock()         — release mkdir lock
#
# Requires caller to set:
#   LOCK_DIR — for acquire_lock/release_lock

# Guard against double-sourcing
[ -n "${_AUTOPILOT_LIB_LOADED:-}" ] && return 0
_AUTOPILOT_LIB_LOADED=1

normalize_int() {
    local val
    val=$(echo "${1:-}" | tr -dc '0-9')
    echo "${val:-0}"
}

sanitize() {
    echo "${1:-}" | tr -cd 'a-zA-Z0-9_-'
}

now_ts() {
    date +%s
}

# macOS-compatible timeout (prefers timeout/gtimeout, fallback to background+kill)
_LIB_TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then
    _LIB_TIMEOUT_CMD="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
    _LIB_TIMEOUT_CMD="gtimeout"
fi

run_with_timeout() {
    local secs="$1"; shift
    if [ -n "$_LIB_TIMEOUT_CMD" ]; then
        "$_LIB_TIMEOUT_CMD" "$secs" "$@"
    else
        "$@" &
        local pid=$!
        (
            sleep "$secs"
            kill "$pid" 2>/dev/null
        ) &
        local watcher=$!
        wait "$pid" 2>/dev/null
        local rc=$?
        kill "$watcher" 2>/dev/null || true
        wait "$watcher" 2>/dev/null || true
        return "$rc"
    fi
}

# Load Telegram config from ~/.autopilot/config.yaml
# Sets: LIB_TG_TOKEN, LIB_TG_CHAT
load_telegram_config() {
    local config_file="${HOME}/.autopilot/config.yaml"
    LIB_TG_TOKEN=$(grep -E '^[[:space:]]*bot_token[[:space:]]*:' "$config_file" 2>/dev/null | awk '{print $2}' | tr -d '"' || true)
    LIB_TG_CHAT=$(grep -E '^[[:space:]]*chat_id[[:space:]]*:' "$config_file" 2>/dev/null | awk '{print $2}' | tr -d '"' || true)
}

# Send a Telegram message (background, non-blocking)
# Usage: send_telegram "message text"
send_telegram() {
    local msg="${1:-}"
    [ -n "$msg" ] || return 0
    if [ -z "${LIB_TG_TOKEN:-}" ] || [ -z "${LIB_TG_CHAT:-}" ]; then
        load_telegram_config
    fi
    if [ -n "${LIB_TG_TOKEN:-}" ] && [ -n "${LIB_TG_CHAT:-}" ]; then
        curl -s -X POST "https://api.telegram.org/bot${LIB_TG_TOKEN}/sendMessage" \
            -d chat_id="${LIB_TG_CHAT}" --data-urlencode "text=${msg}" >/dev/null 2>&1 &
    fi
}

# mkdir-based lock with stale timeout (macOS compatible, no flock)
# Usage: acquire_lock <lock_name> [stale_seconds]
#   lock_name: creates ${LOCK_DIR}/<lock_name>.lock.d
#   stale_seconds: auto-expire after this many seconds (default: 60)
# Requires: LOCK_DIR to be set by the caller
acquire_lock() {
    local lock_name="${1:?acquire_lock: lock_name required}"
    local stale_seconds="${2:-60}"
    local lock_path="${LOCK_DIR:?LOCK_DIR not set}/${lock_name}.lock.d"

    if mkdir "$lock_path" 2>/dev/null; then
        echo "$$" > "${lock_path}/pid"
        return 0
    fi

    # Check for stale lock
    if [ -d "$lock_path" ]; then
        local lock_age
        lock_age=$(( $(now_ts) - $(stat -f %m "$lock_path" 2>/dev/null || echo 0) ))
        if [ "$lock_age" -gt "$stale_seconds" ]; then
            rm -rf "$lock_path" 2>/dev/null || true
            if mkdir "$lock_path" 2>/dev/null; then
                echo "$$" > "${lock_path}/pid"
                return 0
            fi
        fi
    fi
    return 1
}

# Release a mkdir-based lock
# Usage: release_lock <lock_name>
release_lock() {
    local lock_name="${1:?release_lock: lock_name required}"
    rm -rf "${LOCK_DIR:?LOCK_DIR not set}/${lock_name}.lock.d" 2>/dev/null || true
}
