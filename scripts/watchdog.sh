#!/bin/bash
# watchdog.sh v4 — 统一 autopilot 守护进程 + Layer 1 自动检查
#
# 职责分工：
#   watchdog.sh (本脚本) — 快速响应，10-30秒级别
#     ✅ 权限提示 → 立即 auto-approve (p Enter)
#     ✅ idle 检测 → 5 分钟无活动自动 nudge (信号驱动)
#     ✅ 低上下文 → 发 /compact
#     ✅ shell 恢复 → codex resume
#     ✅ Layer 1: 新 commit → 自动 lint/tsc/pattern 扫描
#     ✅ 信号驱动 nudge: 连续 feat 无 test → 要求写测试
#   cron (10min) — 慢速汇报
#     ✅ 进度统计 → Telegram 报告
#     ✅ 智能 nudge → LLM 生成针对性指令
#
# 用法: 通过 launchd 管理，开机自启
# 日志: ~/.autopilot/logs/watchdog.log

# NOTE: do NOT add `set -e`.
# This script intentionally tolerates non-zero probe commands (e.g. grep no-match),
# and the ERR trap is diagnostic-only.
set -uo pipefail
TMUX="/opt/homebrew/bin/tmux"
CODEX="/opt/homebrew/bin/codex"
SESSION="autopilot"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/autopilot-lib.sh"
if [ -f "${SCRIPT_DIR}/autopilot-constants.sh" ]; then
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/autopilot-constants.sh"
fi

# ---- 时间参数 ----
TICK=10                   # 主循环间隔（秒）
IDLE_THRESHOLD="${IDLE_THRESHOLD:-300}"              # idle 超过多久触发 nudge（秒）
IDLE_CONFIRM_PROBES="${IDLE_CONFIRM_PROBES:-3}"      # 连续多少次 idle 才确认空闲
WORKING_INERTIA_SECONDS="${WORKING_INERTIA_SECONDS:-90}" # 最近 working 的惯性窗口（秒）
NUDGE_COOLDOWN=300        # 同一窗口 nudge 冷却（秒），防止反复骚扰
PERMISSION_COOLDOWN=60    # 权限 approve 冷却（秒）
COMPACT_COOLDOWN=600      # compact 冷却（秒）
SHELL_COOLDOWN=300        # shell 恢复冷却（秒）
LOW_CONTEXT_THRESHOLD="${LOW_CONTEXT_THRESHOLD:-25}"
ACK_CHECK_MAX_JOBS="${ACK_CHECK_MAX_JOBS:-8}"
ACK_CHECK_LOCK_STALE_SECONDS="${ACK_CHECK_LOCK_STALE_SECONDS:-120}"

# ---- 路径 ----
LOG="$HOME/.autopilot/logs/watchdog.log"
LOCK_DIR="$HOME/.autopilot/locks"
STATE_DIR="$HOME/.autopilot/state"
COOLDOWN_DIR="$STATE_DIR/watchdog-cooldown"
ACTIVITY_DIR="$STATE_DIR/watchdog-activity"
COMMIT_COUNT_DIR="$STATE_DIR/watchdog-commits"
REVIEW_COOLDOWN=7200       # 增量 review 冷却（秒）= 2 小时
COMMITS_FOR_REVIEW=15      # 触发增量 review 的 commit 数
FEAT_WITHOUT_TEST_LIMIT=5  # 连续 feat 无 test 触发写测试 nudge
mkdir -p "$(dirname "$LOG")" "$LOCK_DIR" "$COOLDOWN_DIR" "$ACTIVITY_DIR" "$COMMIT_COUNT_DIR"

count_prd_todo_remaining() {
    local project_dir="$1"
    local prd_todo="${project_dir}/prd-todo.md"
    local remaining=0

    if [ -f "$prd_todo" ]; then
        remaining=$(grep '^- ' "$prd_todo" | grep -vic '✅\|⛔\|blocked\|done\|完成\|^- \\[x\\]\\|^- \\[X\\]' || true)
        remaining=$(normalize_int "$remaining")
    fi

    echo "$remaining"
}

# 检测 prd-todo.md 是否有新增待办（对比上次快照）
detect_prd_todo_changes() {
    local safe="$1" project_dir="$2"
    local prd_todo="${project_dir}/prd-todo.md"
    local snapshot_file="${STATE_DIR}/prd-snapshot-${safe}.md5"
    
    [ -f "$prd_todo" ] || return 1
    
    local current_hash
    if command -v md5 >/dev/null 2>&1; then
        current_hash=$(md5 -q "$prd_todo" 2>/dev/null)
    elif command -v md5sum >/dev/null 2>&1; then
        current_hash=$(md5sum "$prd_todo" | awk '{print $1}')
    else
        return 1
    fi
    
    local prev_hash
    prev_hash=$(cat "$snapshot_file" 2>/dev/null || echo "")
    
    # 保存当前快照
    echo "$current_hash" > "$snapshot_file"
    
    # 首次运行不算变化
    [ -z "$prev_hash" ] && return 1
    
    # hash 不同 = 有变化
    [ "$current_hash" != "$prev_hash" ]
}

is_prd_todo_complete() {
    [ "$(count_prd_todo_remaining "$1")" -eq 0 ]
}

# ---- 项目配置 ----
# watchdog-projects.conf 格式: window:project_dir:nudge_message
PROJECT_CONFIG_FILE="$HOME/.autopilot/watchdog-projects.conf"
DEFAULT_PROJECTS=(
    "Shike:/Users/wes/Shike"
    "agent-simcity:/Users/wes/projects/agent-simcity"
    "replyher_android-2:/Users/wes/replyher_android-2"
)
PROJECTS=()

# ---- 工具函数 ----
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
}

hash_text() {
    local content="$1"
    if command -v md5 >/dev/null 2>&1; then
        printf '%s' "$content" | md5 -q
        return 0
    fi
    if command -v md5sum >/dev/null 2>&1; then
        printf '%s' "$content" | md5sum | awk '{print $1}'
        return 0
    fi
    if command -v shasum >/dev/null 2>&1; then
        printf '%s' "$content" | shasum -a 256 | awk '{print $1}'
        return 0
    fi
    echo "nohash-$(now_ts)"
}

assert_runtime_ready() {
    if [ ! -x "$TMUX" ]; then
        echo "watchdog fatal: tmux not executable at $TMUX" >&2
        exit 1
    fi
    if [ ! -x "${SCRIPT_DIR}/codex-status.sh" ]; then
        echo "watchdog fatal: missing ${SCRIPT_DIR}/codex-status.sh" >&2
        exit 1
    fi
    if [ ! -x "${SCRIPT_DIR}/tmux-send.sh" ]; then
        echo "watchdog fatal: missing ${SCRIPT_DIR}/tmux-send.sh" >&2
        exit 1
    fi
    if [ ! -x "$CODEX" ]; then
        log "⚠️ watchdog: codex binary not found at $CODEX, shell recovery may fail"
    fi
}

load_projects() {
    PROJECTS=()

    if [ -f "$PROJECT_CONFIG_FILE" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            line="${line%$'\r'}"
            case "$line" in
                ""|\#*)
                    continue
                    ;;
            esac

            local window rest dir
            window="${line%%:*}"
            rest="${line#*:}"
            [ "$rest" = "$line" ] && continue
            dir="${rest%%:*}"

            [ -z "$window" ] && continue
            [ -z "$dir" ] && continue
            PROJECTS+=("${window}:${dir}")
        done < "$PROJECT_CONFIG_FILE"
    fi

    if [ ${#PROJECTS[@]} -eq 0 ]; then
        PROJECTS=("${DEFAULT_PROJECTS[@]}")
        log "⚠️ project config missing/empty, fallback to defaults (${#PROJECTS[@]} projects)"
    fi
}

send_tmux_message() {
    local window="$1" message="$2" action="$3"
    local output rc
    local safe_w
    safe_w=$(echo "$window" | tr -cd 'a-zA-Z0-9_-')

    output=$("$SCRIPT_DIR/tmux-send.sh" "$window" "$message" 2>&1)
    rc=$?
    # 清除 tmux-send 写的 manual-task 标记（这是 watchdog 自己发的，不是人工的）
    rm -f "${STATE_DIR}/manual-task-${safe_w}" 2>/dev/null
    if [ "$rc" -ne 0 ]; then
        output=$(echo "$output" | tr '\n' ' ' | tr -s ' ' | sed 's/^ *//; s/ *$//')
        log "❌ ${window}: ${action} send failed (rc=${rc}) — ${output:0:160}"
        return "$rc"
    fi

    # 保存最后成功发送的 nudge 内容（供 pre-compact 快照使用）
    echo "$message" > "${STATE_DIR}/last-nudge-msg-${safe_w}" 2>/dev/null || true

    return 0
}

extract_status_field() {
    local status_json="$1" field="$2" value
    value=$(echo "$status_json" | jq -r ".${field} // \"\"" 2>/dev/null || true)
    echo "$value"
}

extract_context_num_field() {
    local status_json="$1" ctx
    ctx=$(echo "$status_json" | jq -r '.context_num // -1' 2>/dev/null || echo "-1")
    if [[ "$ctx" =~ ^-?[0-9]+$ ]]; then
        echo "$ctx"
    else
        echo "-1"
    fi
}

get_window_status_json() {
    local window="$1" result
    # codex-status.sh exit codes: 0=working, 1=idle/permission, 2=shell, 3=absent
    # All are valid outputs; only capture stderr failures
    result=$("$SCRIPT_DIR/codex-status.sh" "$window" 2>/dev/null) || true
    if [ -z "$result" ] || ! echo "$result" | jq -e '.status' >/dev/null 2>&1; then
        echo '{"status":"absent","context_num":-1}'
    else
        echo "$result"
    fi
}

extract_json_number() {
    local status_json="$1" field="$2" value
    value=$(echo "$status_json" | jq -r ".${field} // -1" 2>/dev/null || echo "-1")
    if ! [[ "$value" =~ ^-?[0-9]+$ ]]; then
        value=-1
    fi
    echo "$value"
}

send_telegram_alert() {
    local window="$1" text="$2"
    send_telegram "🚨 ${window}: ${text}"
}

start_nudge_ack_check() {
    local window="$1" safe="$2" project_dir="$3" before_head="$4" before_ctx="$5" reason="$6"
    local ack_lock="${LOCK_DIR}/ack-${safe}.lock.d"
    local active_ack_jobs

    active_ack_jobs=$(find "$LOCK_DIR" -maxdepth 1 -type d -name 'ack-*.lock.d' 2>/dev/null | wc -l | tr -d ' ')
    active_ack_jobs=$(normalize_int "$active_ack_jobs")
    if [ "$active_ack_jobs" -ge "$ACK_CHECK_MAX_JOBS" ]; then
        log "⏭ ${window}: skip ack check (active=${active_ack_jobs}, cap=${ACK_CHECK_MAX_JOBS})"
        return 0
    fi

    if [ -d "$ack_lock" ]; then
        local lock_age
        lock_age=$(( $(now_ts) - $(stat -f %m "$ack_lock" 2>/dev/null || echo 0) ))
        if [ "$lock_age" -gt "$ACK_CHECK_LOCK_STALE_SECONDS" ]; then
            rm -rf "$ack_lock" 2>/dev/null || true
        fi
    fi

    mkdir "$ack_lock" 2>/dev/null || return 0
    echo "$$" > "${ack_lock}/parent_pid"
    (
        trap 'rm -rf "'"$ack_lock"'"' EXIT
        echo "$$" > "${ack_lock}/pid"
        local elapsed=0
        while [ "$elapsed" -lt 60 ]; do
            local cur_head cur_json cur_state cur_ctx
            cur_head=$(run_with_timeout 10 git -C "$project_dir" rev-parse HEAD 2>/dev/null || echo "none")
            if [ "$cur_head" != "none" ] && [ "$cur_head" != "$before_head" ]; then
                log "✅ ${window}: ${reason} ack by new commit (${before_head:0:7}→${cur_head:0:7})"
                return 0
            fi

            cur_json=$(get_window_status_json "$window")
            cur_state=$(extract_status_field "$cur_json" "status")
            cur_ctx=$(extract_context_num_field "$cur_json")

            if [ "$cur_state" = "working" ]; then
                log "✅ ${window}: ${reason} ack by working state"
                return 0
            fi

            if [ "$before_ctx" -ge 0 ] && [ "$cur_ctx" -ge 0 ] && [ "$cur_ctx" != "$before_ctx" ]; then
                log "✅ ${window}: ${reason} ack by context change (${before_ctx}%→${cur_ctx}%)"
                return 0
            fi

            sleep 10
            elapsed=$((elapsed + 10))
        done

        log "⚠️ ${window}: ${reason} no-ack in 60s (head/context unchanged)"
    ) &
}

sync_project_status() {
    local project_dir="$1" event="$2"
    shift 2 || true
    if [ -x "$SCRIPT_DIR/status-sync.sh" ]; then
        "$SCRIPT_DIR/status-sync.sh" "$project_dir" "$event" "$@" >/dev/null 2>&1 || true
    fi
}

pid_start_signature() {
    local pid="$1"
    LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null | awk '{$1=$1; print}'
}

pid_is_same_process() {
    local pid="$1" expected_start="$2" current_start
    [ "$pid" -gt 0 ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    [ -n "$expected_start" ] || return 1
    current_start=$(pid_start_signature "$pid")
    [ -n "$current_start" ] || return 1
    [ "$current_start" = "$expected_start" ]
}

pid_looks_like_watchdog() {
    local pid="$1" cmdline
    [ "$pid" -gt 0 ] || return 1
    cmdline=$(ps -p "$pid" -o command= 2>/dev/null || true)
    echo "$cmdline" | grep -q 'watchdog.sh'
}

rotate_log() {
    local lines
    lines=$(wc -l < "$LOG" 2>/dev/null || echo 0)
    if [ "$lines" -gt 5000 ]; then
        tail -2000 "$LOG" > "${LOG}.tmp" && mv -f "${LOG}.tmp" "$LOG"
        log "📋 Log rotated (was ${lines} lines)"
    fi
    # 回收后台僵尸进程（wait -n 需要 bash 4.3+，macOS 默认 3.2）
    wait 2>/dev/null || true
    # 清理过期冷却/活动文件
    find "$COOLDOWN_DIR" -type f -mtime +1 -delete 2>/dev/null
    find "$ACTIVITY_DIR" -type f -mtime +1 -delete 2>/dev/null
}

# 冷却机制：检查某个 action 是否在冷却中
in_cooldown() {
    local key="$1" seconds="$2"
    local file="${COOLDOWN_DIR}/${key}"
    if [ -f "$file" ]; then
        local last=$(cat "$file" 2>/dev/null || echo 0)
        local now=$(now_ts)
        [ $((now - last)) -lt "$seconds" ] && return 0
    fi
    return 1
}

set_cooldown() {
    local key="$1"
    now_ts > "${COOLDOWN_DIR}/${key}"
}

# 记录窗口最后一次有活动的时间
update_activity() {
    local safe="$1"
    now_ts > "${ACTIVITY_DIR}/${safe}"
}

get_idle_seconds() {
    local safe="$1"
    local file="${ACTIVITY_DIR}/${safe}"
    if [ -f "$file" ]; then
        local last=$(cat "$file" 2>/dev/null || echo 0)
        local now=$(now_ts)
        echo $((now - last))
    else
        # 首次运行没有记录，初始化为当前时间并返回 0
        # 下次如果还是 idle，就会开始累计
        update_activity "$safe"
        echo 0
    fi
}

reset_idle_probe() {
    local safe="$1"
    echo 0 > "${ACTIVITY_DIR}/idle-probe-${safe}"
}

# 连续确认 + working 惯性，避免快照抖动误判 idle
idle_state_confirmed() {
    local safe="$1"
    local probe_file="${ACTIVITY_DIR}/idle-probe-${safe}"
    local probe_count idle_secs

    idle_secs=$(get_idle_seconds "$safe")
    if [ "$idle_secs" -lt "$WORKING_INERTIA_SECONDS" ]; then
        echo 0 > "$probe_file"
        return 1
    fi

    probe_count=$(cat "$probe_file" 2>/dev/null || echo 0)
    probe_count=$(normalize_int "$probe_count")
    probe_count=$((probe_count + 1))
    echo "$probe_count" > "$probe_file"

    if [ "$probe_count" -lt "$IDLE_CONFIRM_PROBES" ]; then
        return 1
    fi

    return 0
}

# ---- 状态检测（统一来源 codex-status.sh）----
detect_state() {
    local window="$1"
    local safe="${2:-$(sanitize "$window")}" status_json state ctx_num

    status_json=$(get_window_status_json "$window")
    state=$(extract_status_field "$status_json" "status")
    [ -n "$state" ] || state="absent"

    # 兼容 post-compact 恢复协议（基于统一状态输出的 context_num）
    ctx_num=$(extract_context_num_field "$status_json")
    if [ "$ctx_num" -ge 70 ]; then
        local compact_flag="${STATE_DIR}/post-compact-${safe}"
        if [ -f "${STATE_DIR}/was-low-context-${safe}" ]; then
            touch "$compact_flag"
            rm -f "${STATE_DIR}/was-low-context-${safe}"
        fi
    elif [ "$ctx_num" -ge 0 ] && [ "$ctx_num" -le "$LOW_CONTEXT_THRESHOLD" ]; then
        touch "${STATE_DIR}/was-low-context-${safe}"
    fi

    # Fix 5: compact 失败检测
    local compact_ts_file="${STATE_DIR}/compact-sent-ts-${safe}"
    if [ -f "$compact_ts_file" ] && [ "$ctx_num" -ge 0 ] && [ "$ctx_num" -le "$LOW_CONTEXT_THRESHOLD" ]; then
        local compact_sent_ts compact_elapsed compact_fail_file compact_fail_count
        compact_sent_ts=$(cat "$compact_ts_file" 2>/dev/null || echo 0)
        compact_sent_ts=$(normalize_int "$compact_sent_ts")
        compact_elapsed=$(( $(now_ts) - compact_sent_ts ))
        if [ "$compact_elapsed" -ge 180 ]; then
            # 3 分钟后 context 仍低 → compact 失败
            compact_fail_file="${STATE_DIR}/compact-fail-count-${safe}"
            compact_fail_count=$(cat "$compact_fail_file" 2>/dev/null || echo 0)
            compact_fail_count=$(normalize_int "$compact_fail_count")
            compact_fail_count=$((compact_fail_count + 1))
            echo "$compact_fail_count" > "$compact_fail_file"
            rm -f "$compact_ts_file"
            log "⚠️ ${window}: compact failure #${compact_fail_count} (context still ${ctx_num}% after ${compact_elapsed}s)"
            if [ "$compact_fail_count" -ge 3 ]; then
                send_telegram_alert "$window" "compact 连续 ${compact_fail_count} 次失败，context 仍 ${ctx_num}%"
                echo 0 > "$compact_fail_file"
            fi
        fi
    elif [ -f "$compact_ts_file" ] && [ "$ctx_num" -gt "$LOW_CONTEXT_THRESHOLD" ]; then
        # compact 成功，重置计数
        rm -f "$compact_ts_file"
        echo 0 > "${STATE_DIR}/compact-fail-count-${safe}" 2>/dev/null || true
    fi

    echo "$state"
}

# ---- 动作处理 ----
handle_permission() {
    local window="$1" safe="$2"
    local key="permission-${safe}"
    in_cooldown "$key" "$PERMISSION_COOLDOWN" && return

    acquire_lock "$safe" || { log "⏭ ${window}: permission locked"; return; }
    # 二次检查
    local recheck
    recheck=$($TMUX capture-pane -t "${SESSION}:${window}" -p 2>/dev/null | tail -8)
    if echo "$recheck" | grep -qF "Press enter to confirm or esc to cancel" && echo "$recheck" | grep -qF "(p)"; then
        $TMUX send-keys -t "${SESSION}:${window}" "p" Enter
        set_cooldown "$key"
        log "✅ ${window}: auto-approved permission"
    fi
    release_lock "$safe"
}

handle_idle() {
    local window="$1" safe="$2" project_dir="$3"

    # PRD 完成不代表没事做 — 还有 review fixes、autocheck issues、manual tasks
    # 只有当 PRD 完成 + 无 pending issues + 无 review issues 时才降低 nudge 频率
    local has_pending_work=false
    if [ -f "${STATE_DIR}/autocheck-issues-${safe}" ]; then
        has_pending_work=true
    fi
    if [ -f "${STATE_DIR}/prd-issues-${safe}" ]; then
        has_pending_work=true
    fi
    # 提前检查队列（用于后续绕过判断）
    local has_queue_task_early=false
    local queue_peek
    queue_peek=$("${SCRIPT_DIR}/task-queue.sh" next "$safe" 2>/dev/null || true)
    [ -n "$queue_peek" ] && has_queue_task_early=true

    if is_prd_todo_complete "$project_dir" && [ "$has_pending_work" = "false" ]; then
        local review_file="${STATE_DIR}/layer2-review-${safe}.txt"
        if [ -f "$review_file" ] && ! grep -qi "CLEAN" "$review_file" 2>/dev/null; then
            log "ℹ️ ${window}: PRD complete but review has issues, normal nudge"
        else
            if [ "$has_queue_task_early" = "true" ]; then
                # 队列有任务 → 绕过 prd-done 冷却
                log "📋 ${window}: PRD done but queue has tasks, bypassing prd-done cooldown"
            else
                # 真的没事做了 → 完全停止 nudge，不要干扰
                # 手动消息和队列任务会正常处理（由优先级 1/2 分支负责）
                log "ℹ️ ${window}: PRD complete + review clean + no queue, skip nudge entirely"
                return
            fi
        fi
    fi

    # 检查是否有手动任务在 pending（手动消息 → 暂停 nudge 直到 Codex 开始工作）
    # 保护时间 300s (5分钟)：复杂任务 Codex 可能需要几分钟才开始 working
    local manual_task_file="${STATE_DIR}/manual-task-${safe}"
    if [ -f "$manual_task_file" ]; then
        local manual_ts
        manual_ts=$(cat "$manual_task_file" 2>/dev/null || echo 0)
        manual_ts=$(normalize_int "$manual_ts")
        local manual_age=$(( $(now_ts) - manual_ts ))
        if [ "$manual_age" -lt 300 ]; then
            log "⏭ ${window}: manual task sent ${manual_age}s ago, skipping nudge (protect 300s)"
            release_lock "$safe" 2>/dev/null || true
            return
        else
            rm -f "$manual_task_file"
        fi
    fi

    # 复用之前的队列检查结果（避免重复调用 task-queue.sh）
    local has_queue_task="$has_queue_task_early"

    # 指数退避: nudge 次数越多，冷却越长 (300, 600, 1200, 2400, 4800, 9600)
    # 但队列任务绕过退避（用户主动提交 = 最高优先级）
    local nudge_count_file="${COOLDOWN_DIR}/nudge-count-${safe}"
    local nudge_count
    nudge_count=$(cat "$nudge_count_file" 2>/dev/null || echo 0)
    nudge_count=$(normalize_int "$nudge_count")

    if [ "$has_queue_task" = "false" ]; then
        # 只有非队列任务才受退避限制
        # 超过 6 次无响应 → 停止 nudge，发一次 Telegram 告警
        if [ "$nudge_count" -ge 6 ]; then
            local alert_file="${STATE_DIR}/alert-stalled-${safe}"
            if ! [ -f "$alert_file" ]; then
                touch "$alert_file"
                log "🚨 ${window}: stalled after ${nudge_count} nudges, stopping auto-nudge"
                send_telegram "🚨 ${window} 已 nudge ${nudge_count} 次无响应，自动 nudge 已停止。请手动检查。"
            fi
            return
        fi

        local effective_cooldown=$((NUDGE_COOLDOWN * (1 << (nudge_count > 5 ? 5 : nudge_count))))
        local key="nudge-${safe}"
        in_cooldown "$key" "$effective_cooldown" && return
    else
        log "📋 ${window}: queue task pending, bypassing backoff (nudge_count=${nudge_count})"
    fi

    local idle_secs
    idle_secs=$(get_idle_seconds "$safe")
    if [ "$idle_secs" -lt "$IDLE_THRESHOLD" ]; then
        return  # 还没 idle 够久
    fi

    # P0-1 兜底: 最近 5 分钟有 commit → 短暂休息，不 nudge
    local last_commit_ts
    last_commit_ts=$(run_with_timeout 10 git -C "$project_dir" log -1 --format="%ct" 2>/dev/null || echo 0)
    last_commit_ts=$(normalize_int "$last_commit_ts")
    local commit_age=$(( $(now_ts) - last_commit_ts ))
    if [ "$commit_age" -lt 300 ]; then
        return
    fi

    acquire_lock "$safe" || { log "⏭ ${window}: nudge locked"; return; }
    # 二次检查
    local state2
    state2=$(detect_state "$window" "$safe")
    if [ "$state2" = "idle" ] || [ "$state2" = "idle_low_context" ]; then
        local nudge_msg before_head before_ctx before_status_json
        before_head=$(run_with_timeout 10 git -C "$project_dir" rev-parse HEAD 2>/dev/null || echo "none")
        before_status_json=$(get_window_status_json "$window")
        before_ctx=$(extract_context_num_field "$before_status_json")

        local manual_block_reason
        manual_block_reason=$(echo "$before_status_json" | jq -r '.manual_block_reason // ""' 2>/dev/null || echo "")
        if [ -n "$manual_block_reason" ]; then
            log "🛑 ${window}: manual block detected (${manual_block_reason}) — pausing nudges"
            send_telegram_alert "$window" "manual block detected (${manual_block_reason})"
            sync_project_status "$project_dir" "nudge_blocked_manual" "window=${window}" "state=idle" "issue=${manual_block_reason}"
            release_lock "$safe"
            return
        fi

        local weekly_limit_pct
        weekly_limit_pct=$(extract_json_number "$before_status_json" "weekly_limit_pct")
        local weekly_limit_low=false
        local weekly_limit_exhausted=false
        if [ "$weekly_limit_pct" -ge 0 ] && [ "$weekly_limit_pct" -le 2 ]; then
            weekly_limit_exhausted=true
            weekly_limit_low=true
            log "🔴 ${window}: weekly limit exhausted (${weekly_limit_pct}%) — switching to Claude AgentTeam"
        elif [ "$weekly_limit_pct" -ge 0 ] && [ "$weekly_limit_pct" -lt 10 ]; then
            weekly_limit_low=true
            log "⚠️ ${window}: weekly limit low (${weekly_limit_pct}%) — will skip normal nudge (queue/compact still allowed)"
        fi

        # 优先级 1: post-compact 恢复协议（带上下文快照）
        local compact_flag="${STATE_DIR}/post-compact-${safe}"
        if [ -f "$compact_flag" ]; then
            # 从快照中恢复具体上下文
            local snapshot_file="${STATE_DIR}/pre-compact-snapshot-${safe}"
            local uncommitted="" recent_work="" queue_task="" last_nudge=""
            if [ -f "$snapshot_file" ]; then
                uncommitted=$(grep '^UNCOMMITTED_FILES:' "$snapshot_file" | sed 's/^UNCOMMITTED_FILES: //' || true)
                recent_work=$(grep '^RECENT_COMMITS:' "$snapshot_file" | sed 's/^RECENT_COMMITS: //' || true)
                queue_task=$(grep '^QUEUE_IN_PROGRESS:' "$snapshot_file" | sed 's/^QUEUE_IN_PROGRESS: //' || true)
                last_nudge=$(grep '^LAST_NUDGE:' "$snapshot_file" | sed 's/^LAST_NUDGE: //' || true)
            fi

            # 构造有针对性的恢复消息
            nudge_msg="compaction完成。先阅读 CONVENTIONS.md 与 prd-todo.md。"
            # 未提交改动 — 最高优先级
            if [ -n "$uncommitted" ]; then
                nudge_msg="${nudge_msg} 重要: 有未提交的改动(${uncommitted:0:100}),请先检查并commit。"
            fi
            # 恢复具体任务
            if [ -n "$queue_task" ]; then
                nudge_msg="${nudge_msg} 之前正在做: ${queue_task:0:100}。"
            elif [ -n "$last_nudge" ]; then
                nudge_msg="${nudge_msg} 之前的任务: ${last_nudge:0:120}。"
            elif [ -n "$recent_work" ]; then
                nudge_msg="${nudge_msg} 最近工作方向: ${recent_work:0:100}。"
            fi

            if send_tmux_message "$window" "$nudge_msg" "post-compact recovery nudge"; then
                rm -f "$compact_flag" "$snapshot_file"
                set_cooldown "$key"
                log "🔄 ${window}: post-compact recovery nudge sent (with snapshot)"
                start_nudge_ack_check "$window" "$safe" "$project_dir" "$before_head" "$before_ctx" "post-compact recovery nudge"
                sync_project_status "$project_dir" "nudge_sent" "window=${window}" "reason=post_compact" "state=idle"
            fi
            release_lock "$safe"
            return
        fi

        # 优先级 2: 任务队列（用户手动提交的 bug/需求）
        local queue_task
        queue_task=$("${SCRIPT_DIR}/task-queue.sh" next "$safe" 2>/dev/null || true)
        if [ -n "$queue_task" ]; then
            if [ "$weekly_limit_exhausted" = "true" ]; then
                # Codex 额度耗尽 → 用 Claude AgentTeam 替代
                "${SCRIPT_DIR}/task-queue.sh" start "$safe" 2>/dev/null || true
                log "🤖 ${window}: Codex limit exhausted, dispatching to Claude AgentTeam"
                ( "${SCRIPT_DIR}/claude-fallback.sh" "$safe" "$project_dir" "$queue_task" \
                    >> "${HOME}/.autopilot/logs/claude-fallback.log" 2>&1 ) &
                set_cooldown "$key"
                echo 0 > "$nudge_count_file"
                sync_project_status "$project_dir" "claude_fallback" "window=${window}" "state=idle"
            else
                # 正常 Codex 派发
                nudge_msg="${queue_task:0:280}"
                if send_tmux_message "$window" "$nudge_msg" "queue task"; then
                    "${SCRIPT_DIR}/task-queue.sh" start "$safe" 2>/dev/null || true
                    set_cooldown "$key"
                    echo 0 > "$nudge_count_file"  # 队列任务重置退避计数
                    log "📋 ${window}: queue task sent — ${nudge_msg:0:80}"
                    start_nudge_ack_check "$window" "$safe" "$project_dir" "$before_head" "$before_ctx" "queue task"
                    sync_project_status "$project_dir" "queue_task_sent" "window=${window}" "state=idle"
                    send_telegram "📋 ${window}: 开始处理队列任务 — ${nudge_msg:0:100}"
                fi
            fi
            release_lock "$safe"
            return
        fi

        # weekly limit 低 → 跳过普通 nudge（queue/compact 已在上面处理）
        if [ "$weekly_limit_low" = "true" ]; then
            if [ "$weekly_limit_exhausted" = "true" ]; then
                # 额度耗尽但还有 autocheck/prd issues → 用 Claude 修
                local fallback_task=""
                if [ -f "${STATE_DIR}/autocheck-issues-${safe}" ]; then
                    fallback_task="修复以下自动检查问题: $(cat "${STATE_DIR}/autocheck-issues-${safe}" 2>/dev/null)"
                    rm -f "${STATE_DIR}/autocheck-issues-${safe}"
                elif [ -f "${STATE_DIR}/prd-issues-${safe}" ]; then
                    fallback_task="修复PRD验证失败项: $(cat "${STATE_DIR}/prd-issues-${safe}" 2>/dev/null)"
                    rm -f "${STATE_DIR}/prd-issues-${safe}"
                fi
                if [ -n "$fallback_task" ]; then
                    log "🤖 ${window}: Codex exhausted + pending issues → Claude fallback"
                    ( "${SCRIPT_DIR}/claude-fallback.sh" "$safe" "$project_dir" "$fallback_task" \
                        >> "${HOME}/.autopilot/logs/claude-fallback.log" 2>&1 ) &
                    set_cooldown "$key"
                    sync_project_status "$project_dir" "claude_fallback" "window=${window}" "reason=issues"
                fi
            else
                log "⚠️ ${window}: weekly limit low (${weekly_limit_pct}%) — skipping normal nudge"
                send_telegram_alert "$window" "weekly limit low (${weekly_limit_pct}%) — skipping normal nudge"
            fi
            sync_project_status "$project_dir" "nudge_skipped" "window=${window}" "state=idle" "reason=limit_low"
            release_lock "$safe"
            return
        fi

        # 优先级 3: Layer 1 自动检查发现的问题
        local issues_file="${STATE_DIR}/autocheck-issues-${safe}"
        local prd_issues_file="${STATE_DIR}/prd-issues-${safe}"
        local used_issues_file=false
        local used_prd_issues_file=false
        if [ -f "$issues_file" ]; then
            local issues
            issues=$(cat "$issues_file")
            nudge_msg="修复以下自动检查发现的问题，然后继续推进：${issues}"
            used_issues_file=true
        elif [ -f "$prd_issues_file" ]; then
            local prd_issues
            prd_issues=$(cat "$prd_issues_file")
            nudge_msg="PRD checker 未通过，先修复以下失败项：${prd_issues}"
            used_prd_issues_file=true
        else
            nudge_msg=$(get_smart_nudge "$safe" "$project_dir")
        fi

        local nudge_reason="idle"
        local git_dirty
        # 过滤运行时文件(status.json, prd-progress.json, .code-review/, locks/, logs/, state/)
        # 只关注有实质代码改动的 dirty
        git_dirty=$(git -C "$project_dir" status --porcelain 2>/dev/null \
            | grep -v 'status\.json' \
            | grep -v 'prd-progress\.json' \
            | grep -v '\.code-review/' \
            | grep -v 'locks/' \
            | grep -v 'logs/' \
            | grep -v 'state/' \
            || true)
        if [ -n "$git_dirty" ]; then
            local dirty_summary
            dirty_summary=$(printf '%s' "$git_dirty" | head -n 5 | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')
            [ -z "$dirty_summary" ] && dirty_summary="uncommitted changes"
            nudge_msg="当前仓库存在未提交改动（${dirty_summary:0:120}），请先提交/暂存再继续新任务。"
            nudge_reason="git_dirty"
            log "🛠 ${window}: dirty tree detected before idle nudge; nudging to commit"
        fi

        if send_tmux_message "$window" "$nudge_msg" "idle nudge"; then
            if [ "$nudge_reason" != "git_dirty" ]; then
                [ "$used_issues_file" = "true" ] && rm -f "$issues_file"
                [ "$used_prd_issues_file" = "true" ] && rm -f "$prd_issues_file"
            fi
            set_cooldown "$key"
            echo $((nudge_count + 1)) > "$nudge_count_file"
            log "📤 ${window}: auto-nudged #$((nudge_count+1)) (idle ${idle_secs}s) — ${nudge_msg:0:80}"
            start_nudge_ack_check "$window" "$safe" "$project_dir" "$before_head" "$before_ctx" "idle nudge"
            sync_project_status "$project_dir" "nudge_sent" "window=${window}" "reason=${nudge_reason}" "state=idle"
        fi
    fi
    release_lock "$safe"
}

handle_low_context() {
    local window="$1" safe="$2" project_dir="$3"
    local key="compact-${safe}"
    in_cooldown "$key" "$COMPACT_COOLDOWN" && return

    acquire_lock "$safe" || { log "⏭ ${window}: compact locked"; return; }
    # 二次检查：必须仍在 idle 状态（› 提示符）且低上下文
    local state2
    state2=$(detect_state "$window" "$safe")
    if [ "$state2" = "idle_low_context" ]; then
        # ★ compact 前保存上下文快照：未提交改动 + 最近任务 + 队列状态
        local snapshot_file="${STATE_DIR}/pre-compact-snapshot-${safe}"
        {
            echo "# Pre-compact snapshot $(date '+%Y-%m-%d %H:%M:%S')"
            # 未提交改动
            local dirty_files
            dirty_files=$(git -C "$project_dir" diff --name-only 2>/dev/null | head -10 || true)
            local staged_files
            staged_files=$(git -C "$project_dir" diff --cached --name-only 2>/dev/null | head -10 || true)
            if [ -n "$dirty_files" ] || [ -n "$staged_files" ]; then
                echo "UNCOMMITTED_FILES: ${dirty_files} ${staged_files}"
            fi
            # 最近 commit（反映当前工作方向）
            local recent
            recent=$(git -C "$project_dir" log --oneline -3 --format="%s" 2>/dev/null | tr '\n' '; ' || true)
            [ -n "$recent" ] && echo "RECENT_COMMITS: ${recent}"
            # 队列中进行中的任务
            local queue_task
            queue_task=$(grep -m1 '^\- \[→\]' "${HOME}/.autopilot/task-queue/${safe}.md" 2>/dev/null | sed 's/^- \[→\] //; s/ | added:.*$//' || true)
            [ -n "$queue_task" ] && echo "QUEUE_IN_PROGRESS: ${queue_task}"
            # 最后一次 nudge 内容
            local last_nudge_file="${STATE_DIR}/last-nudge-msg-${safe}"
            [ -f "$last_nudge_file" ] && echo "LAST_NUDGE: $(cat "$last_nudge_file")"
        } > "$snapshot_file"
        log "📸 ${window}: saved pre-compact snapshot"

        if send_tmux_message "$window" "/compact" "compact"; then
            set_cooldown "$key"
            # Fix 5: 记录 compact 发送时间
            now_ts > "${STATE_DIR}/compact-sent-ts-${safe}"
            log "🗜 ${window}: sent /compact"
            sync_project_status "$project_dir" "compact_sent" "window=${window}" "state=idle_low_context"
        fi
    fi
    release_lock "$safe"
}

handle_shell() {
    local window="$1" safe="$2" project_dir="$3"
    local key="shell-${safe}"
    in_cooldown "$key" "$SHELL_COOLDOWN" && return

    acquire_lock "$safe" || { log "⏭ ${window}: shell locked"; return; }
    # 二次检查：必须仍在 shell 状态
    local state2
    state2=$(detect_state "$window" "$safe")
    if [ "$state2" = "shell" ]; then
        $TMUX send-keys -t "${SESSION}:${window}" "cd '${project_dir}' && (${CODEX} resume --last 2>/dev/null || ${CODEX} --full-auto)" Enter
        set_cooldown "$key"
        log "🔄 ${window}: shell recovery"
        sync_project_status "$project_dir" "shell_recovery" "window=${window}" "state=shell"
    fi
    release_lock "$safe"
}

# ---- Layer 1: 自动检查 ----

# 获取当前 commit hash
get_head() {
    local dir="$1"
    git -C "$dir" rev-parse HEAD 2>/dev/null || echo "none"
}

# 检测新 commit 并运行自动检查
check_new_commits() {
    local window="$1" safe="$2" project_dir="$3"
    local head_file="${COMMIT_COUNT_DIR}/${safe}-head"
    local count_file="${COMMIT_COUNT_DIR}/${safe}-since-review"

    local current_head
    current_head=$(run_with_timeout 10 git -C "$project_dir" rev-parse HEAD 2>/dev/null || echo "none")
    [ "$current_head" = "none" ] && return

    local last_head
    last_head=$(cat "$head_file" 2>/dev/null || echo "none")

    # 没有新 commit
    [ "$current_head" = "$last_head" ] && return

    # 记录新 head
    echo "$current_head" > "$head_file"

    # P0-1 fix: 有新 commit 说明刚在工作，重置 activity 时间戳
    update_activity "$safe"
    # 重置 nudge 退避计数 + 清除 stalled 告警
    echo 0 > "${COOLDOWN_DIR}/nudge-count-${safe}"
    rm -f "${STATE_DIR}/alert-stalled-${safe}"
    # Fix 4: 新 commit 重置 review 重试计数
    rm -f "${STATE_DIR}/review-retry-count-${safe}" "${STATE_DIR}/review-failed-${safe}"

    # 增加 commit 计数
    local count
    count=$(cat "$count_file" 2>/dev/null || echo 0)
    # 计算新增 commit 数
    local new_commits=1
    if [ "$last_head" != "none" ]; then
        new_commits=$(git -C "$project_dir" rev-list "${last_head}..${current_head}" --count 2>/dev/null || echo 1)
    fi
    count=$((count + new_commits))
    echo "$count" > "$count_file"

    # 获取最新 commit message
    local msg
    msg=$(git -C "$project_dir" log -1 --format="%s" 2>/dev/null || echo "")

    log "📝 ${window}: new commit (+${new_commits}, total since review: ${count}) — ${msg}"
    sync_project_status "$project_dir" "commit" "window=${window}" "head=${current_head}" "new_commits=${new_commits}" "since_review=${count}" "state=working"

    # 队列任务完成检测：如果有进行中的队列任务，新 commit = 任务完成
    local queue_in_progress
    queue_in_progress=$(grep -c '^\- \[→\]' "${HOME}/.autopilot/task-queue/${safe}.md" 2>/dev/null || echo 0)
    if [ "$queue_in_progress" -gt 0 ]; then
        "${SCRIPT_DIR}/task-queue.sh" done "$safe" "${current_head:0:7}" 2>/dev/null || true
        log "📋✅ ${window}: queue task completed (commit ${current_head:0:7})"
        # 检查是否还有更多队列任务
        local remaining
        remaining=$("${SCRIPT_DIR}/task-queue.sh" count "$safe" 2>/dev/null || echo 0)
        if [ "$remaining" -gt 0 ]; then
            log "📋 ${window}: ${remaining} more tasks in queue"
        fi
        # Telegram 通知完成
        local done_msg="✅ ${window}: 队列任务完成 (${current_head:0:7}) — ${msg:0:80}"
        [ "$remaining" -gt 0 ] && done_msg="${done_msg}\n📋 还剩 ${remaining} 个任务待处理"
        send_telegram "$done_msg"
    fi

    # Layer 1 自动检查
    run_auto_checks "$window" "$safe" "$project_dir" "$msg"
    # PRD 引擎：按本次 commit 变更文件自动匹配并执行 checker
    run_prd_checks_for_commit "$window" "$safe" "$project_dir" "$last_head" "$current_head"

    # Layer 2 触发检查：commit 数达标且 idle 时，通知 cron 触发增量 review
    check_incremental_review_trigger "$window" "$safe" "$project_dir" "$count"
}

run_auto_checks() {
    local window="$1" safe="$2" project_dir="$3" commit_msg="$4"
    local key="autocheck-${safe}"
    in_cooldown "$key" 120 && return  # 2 分钟内不重复跑
    set_cooldown "$key"

    # 后台异步执行，不阻塞主循环
    # 用 lockfile 防止同一项目同时跑多个 autocheck
    local check_lock="${LOCK_DIR}/autocheck-${safe}.lock.d"
    if ! mkdir "$check_lock" 2>/dev/null; then
        log "⏭ ${window}: autocheck already running, skip"
        return
    fi
    (
        trap 'rm -rf "'"$check_lock"'"' EXIT
        local issues=""

        # 危险模式扫描（仅扫描 git 跟踪文件，避免 node_modules 误报）
        local danger
        danger=$(cd "$project_dir" && git grep -nI -E '\beval\s*\(' -- '*.ts' '*.tsx' 2>/dev/null | grep -vc "test\|spec\|mock" 2>/dev/null || true)
        danger=$(normalize_int "$danger")
        if [ "$danger" -gt 0 ]; then
            issues="${issues}发现 eval() 调用 (${danger} 处). "
        fi

        # 硬编码密钥扫描（仅扫描 git 跟踪文件，避免依赖目录噪音）
        local secrets
        secrets=$(cd "$project_dir" && git grep -nI -E '(api_key|apiKey|secret|password)\s*[:=]\s*["'"'"'][^"'"'"']{8,}' -- '*.ts' '*.tsx' 2>/dev/null | grep -vc "test\|mock\|spec\|example\|type\|interface\|\.d\.ts" 2>/dev/null || true)
        secrets=$(normalize_int "$secrets")
        if [ "$secrets" -gt 0 ]; then
            issues="${issues}疑似硬编码密钥 (${secrets} 处). "
        fi

        # TypeScript 类型检查（可能慢，但在后台不阻塞）
        if [ -f "${project_dir}/tsconfig.json" ]; then
            local tsc_out
            tsc_out=$(cd "$project_dir" && run_with_timeout 30 npx tsc --noEmit 2>&1 | grep -c "error TS" 2>/dev/null || true)
            tsc_out=$(normalize_int "$tsc_out")
            if [ "$tsc_out" -gt 0 ]; then
                issues="${issues}TypeScript 类型错误 (${tsc_out} errors). "
            fi
        fi

        # 如果 fix: commit，自动跑测试（后台，有 timeout）
        if echo "$commit_msg" | grep -qE '^fix'; then
            if [ -f "${project_dir}/package.json" ]; then
                local test_result
                test_result=$(cd "$project_dir" && run_with_timeout 60 npx jest --passWithNoTests --silent 2>&1 | tail -3)
                if echo "$test_result" | grep -qiE 'fail|error'; then
                    issues="${issues}fix commit 后测试失败! "
                    # 写标记文件供 get_smart_nudge 使用
                    echo "1" > "${COMMIT_COUNT_DIR}/${safe}-test-fail"
                fi
            fi
        fi

        if [ -n "$issues" ]; then
            # P1-4: issue hash 去重，相同问题不重复 nudge
            local issues_hash
            issues_hash=$(hash_text "$issues")
            local prev_hash
            prev_hash=$(cat "${STATE_DIR}/autocheck-hash-${safe}" 2>/dev/null || echo "")
            if [ "$issues_hash" = "$prev_hash" ]; then
                log "⏭ ${window}: Layer 1 issues unchanged, skip re-nudge"
            else
                echo "$issues_hash" > "${STATE_DIR}/autocheck-hash-${safe}"
                log "⚠️ ${window}: Layer 1 issues — ${issues}"
                echo "$issues" > "${STATE_DIR}/autocheck-issues-${safe}.tmp" && mv -f "${STATE_DIR}/autocheck-issues-${safe}.tmp" "${STATE_DIR}/autocheck-issues-${safe}"
            fi
        fi
    ) &
}

run_prd_checks_for_commit() {
    local window="$1" safe="$2" project_dir="$3" last_head="$4" current_head="$5"
    local prd_items="${project_dir}/prd-items.yaml"
    local prd_verify="${SCRIPT_DIR}/prd-verify.sh"
    local prd_engine="${SCRIPT_DIR}/prd_verify_engine.py"
    local output_file="${project_dir}/prd-progress.json"
    local issues_file="${STATE_DIR}/prd-issues-${safe}"
    local -a verify_cmd

    [ -f "$prd_items" ] || return
    if [ -x "$prd_verify" ]; then
        verify_cmd=("$prd_verify" --project-dir "$project_dir")
    elif [ -f "$prd_engine" ]; then
        verify_cmd=("python3" "$prd_engine" --project-dir "$project_dir")
    else
        return
    fi

    local changed_files
    if [ "$last_head" != "none" ]; then
        changed_files=$(run_with_timeout 10 git -C "$project_dir" diff --name-only "${last_head}..${current_head}" --diff-filter=ACMR 2>/dev/null || true)
    else
        changed_files=$(run_with_timeout 10 git -C "$project_dir" show --pretty='' --name-only "${current_head}" --diff-filter=ACMR 2>/dev/null || true)
    fi
    changed_files=$(echo "$changed_files" | sed '/^$/d')
    [ -z "$changed_files" ] && return

    local changed_files_json
    changed_files_json=$(printf '%s\n' "$changed_files" | python3 -c 'import json,sys; print(json.dumps([line.rstrip("\n") for line in sys.stdin if line.rstrip("\n")], ensure_ascii=False))' 2>/dev/null || echo "[]")
    local verify_output rc
    verify_output=$(run_with_timeout 45 "${verify_cmd[@]}" --changed-files "$changed_files_json" --output "$output_file" --sync-todo --print-failures-only 2>&1)
    rc=$?

    if [ "$rc" -eq 0 ]; then
        rm -f "$issues_file"
        log "✅ ${window}: PRD verify passed for ${current_head:0:7}"
        sync_project_status "$project_dir" "prd_verify_pass" "window=${window}" "state=working" "head=${current_head}"
        return
    fi

    verify_output=$(echo "$verify_output" | tr '\n' ' ' | tr -s ' ' | sed 's/^ *//; s/ *$//')
    echo "$verify_output" > "${issues_file}.tmp" && mv -f "${issues_file}.tmp" "$issues_file"
    log "⚠️ ${window}: PRD verify failed — ${verify_output:0:200}"
    sync_project_status "$project_dir" "prd_verify_fail" "window=${window}" "state=working" "head=${current_head}" "issues=${verify_output:0:220}"
}

# Layer 2 增量 review 触发
check_incremental_review_trigger() {
    local window="$1" safe="$2" project_dir="$3" count="$4"
    local key="review-${safe}"

    # 冷却检查
    in_cooldown "$key" "$REVIEW_COOLDOWN" && return

    # 条件1: commit 数 >= 阈值 OR 2 小时无 review
    local last_review_ts_file="${COMMIT_COUNT_DIR}/${safe}-last-review-ts"
    local last_review_ts
    last_review_ts=$(cat "$last_review_ts_file" 2>/dev/null || echo 0)
    local time_since_review=$(( $(now_ts) - last_review_ts ))

    local should_trigger=false
    if [ "$count" -ge "$COMMITS_FOR_REVIEW" ]; then
        should_trigger=true
    elif [ "$time_since_review" -ge "$REVIEW_COOLDOWN" ] && [ "$count" -gt 0 ]; then
        should_trigger=true
    fi
    # 快速 re-review：如果上次 review 有问题（issues 文件存在），降低触发门槛
    # 只需 3 个 fix commit + 30 分钟冷却
    local issues_file="${STATE_DIR}/autocheck-issues-${safe}"
    if [ -f "$issues_file" ] && [ "$count" -ge 3 ] && [ "$time_since_review" -ge 1800 ]; then
        should_trigger=true
        log "🔄 ${window}: fast re-review triggered (${count} fix commits, issues pending)"
    fi
    [ "$should_trigger" = "false" ] && return

    # 条件2: 当前是 idle 状态
    local state
    state=$(detect_state "$window" "$safe")
    [ "$state" != "idle" ] && return

    # 触发增量 review — 写 pending 标记，cron 执行成功后才重置计数（两阶段提交）
    local trigger_file="${STATE_DIR}/review-trigger-${safe}"
    local tmp_trigger="${trigger_file}.tmp"
    if command -v jq >/dev/null 2>&1; then
        jq -n --arg project_dir "$project_dir" --arg window "$window" '{project_dir:$project_dir,window:$window}' > "$tmp_trigger"
    else
        # 兼容无 jq 环境：退回旧格式（仅 project_dir）
        echo "${project_dir}" > "$tmp_trigger"
    fi
    mv -f "$tmp_trigger" "$trigger_file"
    set_cooldown "$key"
    sync_project_status "$project_dir" "review_triggered" "window=${window}" "since_review=${count}" "state=idle"

    # 注意：commit 计数不在这里重置！由 cron 端确认 review 成功后重置
    # cron 需要: echo 0 > ${COMMIT_COUNT_DIR}/${safe}-since-review && now_ts > ${last_review_ts_file}

    log "🔍 ${window}: incremental review triggered (${count} commits, ${time_since_review}s since last review)"
}

# 信号驱动 nudge 消息
get_smart_nudge() {
    local safe="$1" project_dir="$2"

    # 先检查 PRD 是否全部完成 — 如果全完成了，不要强制写测试
    local prd_todo="${project_dir}/prd-todo.md"
    if [ -f "$prd_todo" ]; then
        local remaining
        remaining=$(grep '^- ' "$prd_todo" | grep -vic '✅\|⛔\|blocked\|done\|完成\|^\- \[x\]\|^\- \[X\]' || true)
        remaining=$(normalize_int "$remaining")
        if [ "$remaining" -eq 0 ]; then
            # PRD 完成 → 检查是否有 review issues 或 autocheck issues 需要修
            local issues_file="${STATE_DIR}/autocheck-issues-${safe}"
            local prd_issues_file="${STATE_DIR}/prd-issues-${safe}"
            if [ -f "$issues_file" ]; then
                local pending_issues
                pending_issues=$(cat "$issues_file" | head -c 200)
                echo "PRD 已完成，但仍有自动检查发现的问题待修复：${pending_issues}"
                return
            fi
            if [ -f "$prd_issues_file" ]; then
                local pending_prd
                pending_prd=$(cat "$prd_issues_file" | head -c 200)
                echo "PRD 已完成，但 PRD checker 仍有失败项：${pending_prd}"
                return
            fi
            # 检查是否有未处理的 review 结果
            local review_file="${STATE_DIR}/layer2-review-${safe}.txt"
            if [ -f "$review_file" ]; then
                local review_content
                review_content=$(cat "$review_file" 2>/dev/null | head -c 200)
                if ! echo "$review_content" | grep -qi "CLEAN"; then
                    echo "PRD 已完成，但上次 review 发现问题需要修复。读 ${review_file} 并修复所有 P1/P2 问题，然后 git commit。"
                    return
                fi
            fi
            echo "PRD 和 review 均已完成。运行测试确认无回归，检查是否有遗漏的优化项。"
            return
        fi
    fi

    # 检查连续 feat commit 无 test
    local recent_msgs
    recent_msgs=$(git -C "$project_dir" log -10 --format="%s" 2>/dev/null)

    local consecutive_feat=0
    while IFS= read -r msg; do
        if echo "$msg" | grep -qE '^(feat|feature)'; then
            consecutive_feat=$((consecutive_feat + 1))
        elif echo "$msg" | grep -qE '^test'; then
            break  # 遇到 test commit 就停，计数归零
        else
            break  # 遇到非 feat/非 test commit 就停（fix/chore/docs 不算连续 feat）
        fi
    done <<< "$recent_msgs"

    if [ "$consecutive_feat" -ge "$FEAT_WITHOUT_TEST_LIMIT" ]; then
        echo "为最近完成的功能写单元测试，确保包含 happy path + error path，断言要验证行为不是实现。写完后继续推进下一项任务。"
        return
    fi

    # 检查连续 checkpoint/空 commit
    local checkpoint_count=0
    while IFS= read -r msg; do
        if echo "$msg" | grep -qiE 'checkpoint|wip|fixup|squash'; then
            checkpoint_count=$((checkpoint_count + 1))
        else
            break
        fi
    done <<< "$recent_msgs"

    if [ "$checkpoint_count" -ge 3 ]; then
        echo "看起来进展受阻了。描述一下当前遇到的困难，然后换个思路解决。"
        return
    fi

    # 检查测试是否失败
    if [ -f "${project_dir}/package.json" ]; then
        local test_status="${COMMIT_COUNT_DIR}/${safe}-test-fail"
        if [ -f "$test_status" ]; then
            rm -f "$test_status"
            echo "修复失败的测试，优先级高于新功能开发。"
            return
        fi
    fi

    # PRD 驱动 nudge：从 prd-todo.md 读取下一个待办
    if [ -f "$prd_todo" ]; then
        local next_task
        next_task=$(grep '^- ' "$prd_todo" | grep -vi '✅\|⛔\|blocked\|done\|完成\|^\- \[x\]\|^\- \[X\]' | head -1 | sed 's/^- //')
        if [ -n "$next_task" ]; then
            echo "实现以下 PRD 需求：${next_task}"
            return
        fi
    fi

    # 默认：带最近 commit 上下文
    local last_msg
    last_msg=$(git -C "$project_dir" log -1 --format="%s" 2>/dev/null || echo "")
    if [ -n "$last_msg" ]; then
        echo "上一个 commit: '${last_msg:0:80}'。基于此继续推进，或开始下一个 PRD 待办。"
    else
        echo "继续推进下一项任务"
    fi
}

# ---- 主循环 ----
# ---- 进程级互斥锁 ----
WATCHDOG_LOCK="${LOCK_DIR}/watchdog-main.lock.d"
if ! mkdir "$WATCHDOG_LOCK" 2>/dev/null; then
    # 通过 PID + 进程启动签名识别锁持有者，避免 PID 复用误判
    existing_pid=$(cat "${WATCHDOG_LOCK}/pid" 2>/dev/null || echo 0)
    existing_pid=$(normalize_int "$existing_pid")
    existing_start_sig=$(cat "${WATCHDOG_LOCK}/start_sig" 2>/dev/null || echo "")
    if pid_is_same_process "$existing_pid" "$existing_start_sig"; then
        echo "Another watchdog is running (pid ${existing_pid}). Exiting."
        exit 1
    elif [ -z "$existing_start_sig" ] && [ "$existing_pid" -gt 0 ] && kill -0 "$existing_pid" 2>/dev/null && pid_looks_like_watchdog "$existing_pid"; then
        # 兼容旧锁格式（仅有 pid）
        echo "Another watchdog is running (pid ${existing_pid}, legacy lock). Exiting."
        exit 1
    else
        log "🔓 Stale lock found (pid ${existing_pid} dead), reclaiming"
        rm -rf "$WATCHDOG_LOCK" 2>/dev/null
        mkdir "$WATCHDOG_LOCK" 2>/dev/null || { echo "Failed to reclaim lock. Exiting."; exit 1; }
    fi
fi
echo $$ > "${WATCHDOG_LOCK}/pid"
pid_start_signature "$$" > "${WATCHDOG_LOCK}/start_sig" 2>/dev/null || true
now_ts > "${WATCHDOG_LOCK}/started_at"
# ERR trap 仅用于诊断；不要与 set -e 组合
trap 'log "💥 ERR at line $LINENO (code=$?)"' ERR
# Graceful shutdown: kill background jobs, clean lock
cleanup_watchdog() {
    local pids
    pids=$(jobs -p 2>/dev/null || true)
    if [ -n "$pids" ]; then
        kill $pids 2>/dev/null || true
        # Give children 2s to clean up their own locks
        sleep 2
        kill -9 $pids 2>/dev/null || true
    fi
    rm -rf "$WATCHDOG_LOCK"
}
trap cleanup_watchdog EXIT
trap 'log "🛑 Received SIGTERM, shutting down..."; exit 0' TERM INT

assert_runtime_ready
load_projects
log "🚀 Watchdog v4 started (tick=${TICK}s, idle_threshold=${IDLE_THRESHOLD}s, idle_confirm=${IDLE_CONFIRM_PROBES}, inertia=${WORKING_INERTIA_SECONDS}s, projects=${#PROJECTS[@]}, pid=$$)"

cycle=0
while true; do
    for entry in "${PROJECTS[@]}"; do
        window="${entry%%:*}"
        project_dir="${entry#*:}"
        safe=$(sanitize "$window")

        state=$(detect_state "$window" "$safe")

        # 每 30 轮（~5 分钟）记录一次状态
        if [ $((cycle % 30)) -eq 0 ] && [ "$cycle" -gt 0 ]; then
            log "📊 ${window}: state=${state}"
        fi

        # Layer 1: 检测新 commit 并自动检查
        check_new_commits "$window" "$safe" "$project_dir"

        # 检测 prd-todo.md 变化（新需求加入）→ 重置 nudge 计数，重新激活
        if detect_prd_todo_changes "$safe" "$project_dir"; then
            new_remaining=$(count_prd_todo_remaining "$project_dir")
            if [ "$new_remaining" -gt 0 ]; then
                log "📋 ${window}: prd-todo.md updated, ${new_remaining} items remaining — resetting nudge"
                echo 0 > "${COOLDOWN_DIR}/nudge-count-${safe}"
                rm -f "${STATE_DIR}/alert-stalled-${safe}"
                send_telegram_alert "$window" "prd-todo.md 有新需求 (${new_remaining} 项待完成)，已重新激活 nudge"
            fi
        fi

        # Fix 6: 非 working 状态清除僵死追踪
        if [ "$state" != "working" ]; then
            rm -f "${STATE_DIR}/working-since-${safe}" "${STATE_DIR}/working-head-${safe}" "${STATE_DIR}/working-ctx-${safe}" "${STATE_DIR}/stall-alerted-${safe}" 2>/dev/null || true
        fi

        case "$state" in
            working)
                update_activity "$safe"
                reset_idle_probe "$safe"
                # Fix 6: TUI 僵死检测
                stall_head=$(cat "${COMMIT_COUNT_DIR}/${safe}-head" 2>/dev/null || echo "none")
                stall_json=$(get_window_status_json "$window")
                stall_ctx=$(extract_context_num_field "$stall_json")
                working_since_f="${STATE_DIR}/working-since-${safe}"
                working_head_f="${STATE_DIR}/working-head-${safe}"
                working_ctx_f="${STATE_DIR}/working-ctx-${safe}"
                prev_stall_head=$(cat "$working_head_f" 2>/dev/null || echo "")
                prev_stall_ctx=$(cat "$working_ctx_f" 2>/dev/null || echo "")
                if [ "$stall_head" != "$prev_stall_head" ] || [ "$stall_ctx" != "$prev_stall_ctx" ]; then
                    # HEAD 或 context 变化 → 重置追踪
                    now_ts > "$working_since_f"
                    echo "$stall_head" > "$working_head_f"
                    echo "$stall_ctx" > "$working_ctx_f"
                    rm -f "${STATE_DIR}/stall-alerted-${safe}"
                else
                    # 没变化 → 检查持续时间
                    working_since_val=$(cat "$working_since_f" 2>/dev/null || echo 0)
                    working_since_val=$(normalize_int "$working_since_val")
                    stall_dur=$(( $(now_ts) - working_since_val ))
                    if [ "$stall_dur" -ge 1800 ]; then
                        # 30 分钟 → Telegram 告警
                        if [ ! -f "${STATE_DIR}/stall-alerted-${safe}" ]; then
                            send_telegram_alert "$window" "TUI 可能僵死（working ${stall_dur}s 但 HEAD 和 context 无变化）"
                            touch "${STATE_DIR}/stall-alerted-${safe}"
                            log "🚨 ${window}: possible TUI stall (${stall_dur}s, HEAD=${stall_head:0:7}, ctx=${stall_ctx}%)"
                        fi
                    elif [ "$stall_dur" -ge 900 ]; then
                        # 15 分钟 → 日志 warn
                        log "⚠️ ${window}: working ${stall_dur}s with no HEAD/context change (HEAD=${stall_head:0:7}, ctx=${stall_ctx}%)"
                    fi
                fi
                ;;
            permission|permission_with_remember)
                reset_idle_probe "$safe"
                handle_permission "$window" "$safe"
                ;;
            idle)
                if idle_state_confirmed "$safe"; then
                    handle_idle "$window" "$safe" "$project_dir"
                fi
                ;;
            idle_low_context)
                if idle_state_confirmed "$safe"; then
                    handle_low_context "$window" "$safe" "$project_dir"
                fi
                ;;
            shell)
                reset_idle_probe "$safe"
                handle_shell "$window" "$safe" "$project_dir"
                ;;
            absent)
                # tmux window 不存在，跳过
                reset_idle_probe "$safe"
                ;;
        esac
    done

    cycle=$((cycle + 1))
    # 每 300 轮（~50 分钟）轮转日志
    if [ $((cycle % 300)) -eq 0 ]; then
        rotate_log
    fi

    sleep "$TICK"
done
