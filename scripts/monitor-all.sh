#!/bin/bash
# monitor-all.sh v1 — 统一监控所有项目，事件驱动输出
# 用法: monitor-all.sh
# 输出: JSON，只包含有变化的项目。无变化时输出 {"changes":false}
# 
# 检测逻辑：
#   1. 对每个项目运行 codex-status.sh
#   2. 读取 git HEAD 和最近 commit 信息
#   3. 对比 state 文件中的上次状态
#   4. 只输出发生变化的项目
#
# 变化定义：
#   - 状态变化（working→idle, idle→working, shell, compact 等）
#   - 新 commit 产生（HEAD 变了）
#   - context 跨过阈值（>LOW_CONTEXT_THRESHOLD, >LOW_CONTEXT_CRITICAL_THRESHOLD）
#   - 连续 3 轮无 commit 但 working（追踪但不告警）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "${SCRIPT_DIR}/autopilot-constants.sh" ]; then
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/autopilot-constants.sh"
fi
LOW_CONTEXT_THRESHOLD="${LOW_CONTEXT_THRESHOLD:-25}"
LOW_CONTEXT_CRITICAL_THRESHOLD="${LOW_CONTEXT_CRITICAL_THRESHOLD:-15}"

STATE_DIR="$HOME/.autopilot/state"
LOCK_DIR="$HOME/.autopilot/locks"
MONITOR_LOCK="${LOCK_DIR}/monitor-all.lock.d"
mkdir -p "$STATE_DIR" "$LOCK_DIR"

TMUX="/opt/homebrew/bin/tmux"

normalize_int() {
    local val
    val=$(echo "${1:-}" | tr -dc '0-9')
    echo "${val:-0}"
}

acquire_script_lock() {
    if mkdir "$MONITOR_LOCK" 2>/dev/null; then
        echo "$$" > "${MONITOR_LOCK}/pid"
        return 0
    fi

    local existing_pid
    existing_pid=$(cat "${MONITOR_LOCK}/pid" 2>/dev/null || echo 0)
    existing_pid=$(normalize_int "$existing_pid")

    if [ "$existing_pid" -gt 0 ] && kill -0 "$existing_pid" 2>/dev/null; then
        return 1
    fi

    rm -rf "$MONITOR_LOCK" 2>/dev/null || true
    mkdir "$MONITOR_LOCK" 2>/dev/null || return 1
    echo "$$" > "${MONITOR_LOCK}/pid"
    return 0
}

if ! acquire_script_lock; then
    echo '{"changes":false}'
    exit 0
fi
trap 'rm -rf "$MONITOR_LOCK" 2>/dev/null || true' EXIT

# 项目配置（优先读取 watchdog-projects.conf）
PROJECT_CONFIG_FILE="$HOME/.autopilot/watchdog-projects.conf"
DEFAULT_PROJECTS=(
    "Shike:/Users/wes/Shike"
    "agent-simcity:/Users/wes/projects/agent-simcity"
    "replyher_android-2:/Users/wes/replyher_android-2"
)
PROJECTS=()

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
    fi
}

CHANGES=()
ALL_STATUS=()

load_projects

for entry in "${PROJECTS[@]}"; do
    WINDOW="${entry%%:*}"
    DIR="${entry##*:}"
    STATE_FILE="$STATE_DIR/${WINDOW}.json"

    # --- 当前状态 ---
    STATUS_JSON=$("$SCRIPT_DIR/codex-status.sh" "$WINDOW" 2>&1) || true
    CUR_STATUS=$(echo "$STATUS_JSON" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
    CUR_CONTEXT=$(echo "$STATUS_JSON" | grep -o '"context_num":[0-9-]*' | head -1 | cut -d: -f2 || true)
    [ -z "$CUR_STATUS" ] && CUR_STATUS="absent"
    [ -z "$CUR_CONTEXT" ] && CUR_CONTEXT=-1

    # Git 信息
    CUR_HEAD=$(cd "$DIR" && git rev-parse --short HEAD 2>/dev/null || echo "none")
    CUR_COMMIT_MSG=$(cd "$DIR" && git log --oneline -1 --format="%s" 2>/dev/null | head -c 80 || echo "")
    CUR_COMMIT_TIME=$(cd "$DIR" && git log -1 --format="%ct" 2>/dev/null || echo "0")
    COMMITS_30M=$(cd "$DIR" && git log --oneline --since="30 minutes ago" 2>/dev/null | wc -l | tr -d ' ' || echo "0")

    # Codex 最后输出（用于智能 nudge）
    LAST_OUTPUT=""
    if [ "$CUR_STATUS" = "idle" ] || [ "$CUR_STATUS" = "idle_low_context" ]; then
        LAST_OUTPUT=$("$TMUX" capture-pane -t "autopilot:${WINDOW}" -p -S -20 2>/dev/null | head -15 | tr '\n' '|' || echo "")
    fi

    # --- 读取上次状态 ---
    PREV_STATUS="unknown"
    PREV_HEAD="none"
    PREV_CONTEXT=-1
    PREV_WORKING_NO_COMMIT=0
    if [ -f "$STATE_FILE" ]; then
        PREV_STATUS=$(jq -r '.status // "unknown"' "$STATE_FILE" 2>/dev/null || echo "unknown")
        PREV_HEAD=$(jq -r '.head // "none"' "$STATE_FILE" 2>/dev/null || echo "none")
        PREV_CONTEXT=$(jq -r '.context_num // -1' "$STATE_FILE" 2>/dev/null || echo "-1")
        PREV_WORKING_NO_COMMIT=$(jq -r '.working_no_commit // 0' "$STATE_FILE" 2>/dev/null || echo "0")
    fi

    # --- 判断变化 ---
    HAS_CHANGE=false
    CHANGE_REASONS=""

    # 状态变化
    if [ "$CUR_STATUS" != "$PREV_STATUS" ]; then
        HAS_CHANGE=true
        CHANGE_REASONS="${CHANGE_REASONS}status:${PREV_STATUS}→${CUR_STATUS} "
    fi

    # 新 commit
    NEW_COMMITS=0
    if [ "$CUR_HEAD" != "$PREV_HEAD" ] && [ "$PREV_HEAD" != "none" ]; then
        HAS_CHANGE=true
        NEW_COMMITS=$(cd "$DIR" && git log --oneline "${PREV_HEAD}..${CUR_HEAD}" 2>/dev/null | wc -l | tr -d ' ' || echo "1")
        CHANGE_REASONS="${CHANGE_REASONS}commits:+${NEW_COMMITS} "
    fi

    # Context 跨阈值
    if [ "$PREV_CONTEXT" -gt "$LOW_CONTEXT_THRESHOLD" ] && [ "$CUR_CONTEXT" -le "$LOW_CONTEXT_THRESHOLD" ] && [ "$CUR_CONTEXT" -gt 0 ]; then
        HAS_CHANGE=true
        CHANGE_REASONS="${CHANGE_REASONS}context:${PREV_CONTEXT}%→${CUR_CONTEXT}%(low) "
    fi
    if [ "$PREV_CONTEXT" -gt "$LOW_CONTEXT_CRITICAL_THRESHOLD" ] && [ "$CUR_CONTEXT" -le "$LOW_CONTEXT_CRITICAL_THRESHOLD" ] && [ "$CUR_CONTEXT" -gt 0 ]; then
        HAS_CHANGE=true
        CHANGE_REASONS="${CHANGE_REASONS}context:critical(${CUR_CONTEXT}%) "
    fi

    # Working 无 commit 计数
    WORKING_NO_COMMIT=0
    if [ "$CUR_STATUS" = "working" ] && [ "$CUR_HEAD" = "$PREV_HEAD" ]; then
        WORKING_NO_COMMIT=$((PREV_WORKING_NO_COMMIT + 1))
    fi

    # 首次运行（无历史状态）也算变化
    if [ "$PREV_STATUS" = "unknown" ]; then
        HAS_CHANGE=true
        CHANGE_REASONS="initial "
    fi

    # --- 保存当前状态（原子写入）---
    jq -n \
      --arg status "$CUR_STATUS" \
      --argjson context_num "$CUR_CONTEXT" \
      --arg head "$CUR_HEAD" \
      --arg commit_msg "$CUR_COMMIT_MSG" \
      --argjson commit_time "$CUR_COMMIT_TIME" \
      --argjson commits_30m "$COMMITS_30M" \
      --argjson working_no_commit "$WORKING_NO_COMMIT" \
      --argjson last_check "$(date +%s)" \
      '{status:$status,context_num:$context_num,head:$head,commit_msg:$commit_msg,commit_time:$commit_time,commits_30m:$commits_30m,working_no_commit:$working_no_commit,last_check:$last_check}' \
      > "$STATE_FILE.tmp" && mv -f "$STATE_FILE.tmp" "$STATE_FILE"

    # --- 构建项目状态行 ---
    STATUS_EMOJI="✅"
    if [ "$CUR_STATUS" = "idle" ] || [ "$CUR_STATUS" = "idle_low_context" ]; then STATUS_EMOJI="⚠️"; fi
    if [ "$CUR_STATUS" = "shell" ]; then STATUS_EMOJI="🔄"; fi
    if [ "$CUR_STATUS" = "permission" ] || [ "$CUR_STATUS" = "permission_with_remember" ]; then STATUS_EMOJI="🔑"; fi

    # 多维度状态：读取 status.json
    LIFECYCLE=""
    if [ -f "${DIR}/status.json" ]; then
        phase=$(jq -r '.phase // "unknown"' "${DIR}/status.json" 2>/dev/null)
        dev_st=$(jq -r '.phases.dev.status // "pending"' "${DIR}/status.json" 2>/dev/null)
        review_st=$(jq -r '.phases.review.status // "pending"' "${DIR}/status.json" 2>/dev/null)
        test_st=$(jq -r '.phases.test.status // "pending"' "${DIR}/status.json" 2>/dev/null)
        deploy_st=$(jq -r '.phases.deploy.status // "pending"' "${DIR}/status.json" 2>/dev/null)

        # Build lifecycle string
        [ "$dev_st" = "done" ] && LIFECYCLE="✅dev" || LIFECYCLE="🔨dev"
        if [ "$review_st" = "done" ]; then
            LIFECYCLE="${LIFECYCLE} → ✅review"
        elif [ "$review_st" = "in_progress" ]; then
            r_p0=$(jq -r '.phases.review.p0 // 0' "${DIR}/status.json" 2>/dev/null)
            r_p1=$(jq -r '.phases.review.p1 // 0' "${DIR}/status.json" 2>/dev/null)
            LIFECYCLE="${LIFECYCLE} → 🔍review(${r_p0}P0 ${r_p1}P1)"
        else
            LIFECYCLE="${LIFECYCLE} → ⏳review"
        fi
        if [ "$test_st" = "done" ]; then
            LIFECYCLE="${LIFECYCLE} → ✅test"
        elif [ "$test_st" = "in_progress" ]; then
            bugs=$(jq -r '.phases.test.bugs | length // 0' "${DIR}/status.json" 2>/dev/null)
            LIFECYCLE="${LIFECYCLE} → 🔧test(${bugs}bugs)"
        else
            LIFECYCLE="${LIFECYCLE} → ⏳test"
        fi
        [ "$deploy_st" = "done" ] && LIFECYCLE="${LIFECYCLE} → ✅deploy" || LIFECYCLE="${LIFECYCLE} → ⏳deploy"
    fi

    PROJECT_LINE="${STATUS_EMOJI} ${WINDOW}: ${CUR_STATUS} | ${CUR_CONTEXT}% ctx | ${COMMITS_30M}c/30m"
    [ -n "$CUR_COMMIT_MSG" ] && PROJECT_LINE="${PROJECT_LINE} | ${CUR_COMMIT_MSG}"
    [ -n "$LIFECYCLE" ] && PROJECT_LINE="${PROJECT_LINE}"$'\n'"  ${LIFECYCLE}"

    ALL_STATUS+=("$PROJECT_LINE")

    if $HAS_CHANGE; then
        # 构建变化 JSON（使用 jq 安全转义）
        CHANGE_JSON=$(jq -n \
          --arg window "$WINDOW" \
          --arg dir "$DIR" \
          --arg status "$CUR_STATUS" \
          --arg prev_status "$PREV_STATUS" \
          --argjson context "$CUR_CONTEXT" \
          --arg head "$CUR_HEAD" \
          --arg prev_head "$PREV_HEAD" \
          --argjson new_commits "$NEW_COMMITS" \
          --argjson commits_30m "$COMMITS_30M" \
          --arg commit_msg "$CUR_COMMIT_MSG" \
          --argjson working_no_commit "$WORKING_NO_COMMIT" \
          --arg reasons "$CHANGE_REASONS" \
          --arg last_output "$LAST_OUTPUT" \
          '{window:$window,dir:$dir,status:$status,prev_status:$prev_status,context:$context,head:$head,prev_head:$prev_head,new_commits:$new_commits,commits_30m:$commits_30m,commit_msg:$commit_msg,working_no_commit:$working_no_commit,reasons:$reasons,last_output:$last_output}')
        CHANGES+=("$CHANGE_JSON")
    fi
done

# --- 保底心跳：如果超过 2 小时没有任何变化，强制输出一次全局状态 ---
HEARTBEAT_FILE="$STATE_DIR/.last_report"
FORCE_REPORT=false
if [ -f "$HEARTBEAT_FILE" ]; then
    LAST_REPORT_AGE=$(( $(date +%s) - $(stat -f %m "$HEARTBEAT_FILE" 2>/dev/null || echo 0) ))
    [ "$LAST_REPORT_AGE" -ge 7200 ] && FORCE_REPORT=true
else
    FORCE_REPORT=true  # 首次运行
fi

# --- 输出 ---
if [ ${#CHANGES[@]} -eq 0 ] && ! $FORCE_REPORT; then
    echo '{"changes":false}'
elif [ ${#CHANGES[@]} -eq 0 ] && $FORCE_REPORT; then
    touch "$HEARTBEAT_FILE"
    # 构建心跳 JSON（使用 jq）
    SUMMARY_JSON=$(printf '%s\n' "${ALL_STATUS[@]}" | jq -R . | jq -s .)
    echo "{\"changes\":true,\"heartbeat\":true,\"projects\":[],\"summary\":$SUMMARY_JSON}"
else
    touch "$HEARTBEAT_FILE"
    # 输出变化的项目（使用 jq 安全构建）
    PROJECTS_JSON=$(printf '%s\n' "${CHANGES[@]}" | jq -s .)
    SUMMARY_JSON=$(printf '%s\n' "${ALL_STATUS[@]}" | jq -R . | jq -s .)
    
    # 计算总进度信息
    TOTAL_COMMITS=0
    for entry in "${PROJECTS[@]}"; do
        D="${entry##*:}"
        C=$(cd "$D" && git rev-list --count HEAD 2>/dev/null || echo "0")
        TOTAL_COMMITS=$((TOTAL_COMMITS + C))
    done
    
    echo "{\"changes\":true,\"projects\":$PROJECTS_JSON,\"summary\":$SUMMARY_JSON,\"total_commits\":$TOTAL_COMMITS}"
fi

# Layer 2: 消费 watchdog 写的增量 review trigger 文件
if [ -x "${SCRIPT_DIR}/consume-review-trigger.sh" ]; then
    "${SCRIPT_DIR}/consume-review-trigger.sh" >> "$HOME/.autopilot/logs/watchdog.log" 2>&1
fi
