#!/bin/bash
# consume-review-trigger.sh — cron 端消费 watchdog 写的增量 review trigger
#
# 由 monitor-all.sh 或 cron 调用。
# 检查 review-trigger-* 文件，执行增量 review，成功后重置 watchdog 计数。

set -uo pipefail

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}"
if [ -f "${SCRIPT_DIR}/autopilot-constants.sh" ]; then
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/autopilot-constants.sh"
fi
LAYER2_FILE_PREVIEW_LIMIT="${LAYER2_FILE_PREVIEW_LIMIT:-20}"
LAYER2_FALLBACK_COMMIT_WINDOW="${LAYER2_FALLBACK_COMMIT_WINDOW:-30}"
TSC_TIMEOUT_SECONDS="${TSC_TIMEOUT_SECONDS:-30}"
REVIEW_OUTPUT_WAIT_SECONDS="${REVIEW_OUTPUT_WAIT_SECONDS:-90}"
REVIEW_TRIGGER_STALE_SECONDS="${REVIEW_TRIGGER_STALE_SECONDS:-7200}"

# 数字清洗
normalize_int() {
    local val
    val=$(echo "$1" | tr -dc '0-9')
    echo "${val:-0}"
}

sanitize() {
    echo "$1" | tr -cd 'a-zA-Z0-9_-'
}

resolve_window_from_safe() {
    local safe="$1"
    local tmux_bin="/opt/homebrew/bin/tmux"
    local session_name="autopilot"
    local windows window_name window_safe

    if [ ! -x "$tmux_bin" ]; then
        echo "$safe"
        return 0
    fi

    windows=$("$tmux_bin" list-windows -t "$session_name" -F '#{window_name}' 2>/dev/null || true)
    while IFS= read -r window_name; do
        [ -n "$window_name" ] || continue
        window_safe=$(sanitize "$window_name")
        if [ "$window_safe" = "$safe" ]; then
            echo "$window_name"
            return 0
        fi
    done <<< "$windows"

    echo "$safe"
}
STATE_DIR="$HOME/.autopilot/state"
COMMIT_COUNT_DIR="$STATE_DIR/watchdog-commits"
LOG="$HOME/.autopilot/logs/watchdog.log"
LOCK_DIR="$HOME/.autopilot/locks"
REVIEW_LOCK="${LOCK_DIR}/consume-review-trigger.lock.d"
mkdir -p "$STATE_DIR" "$COMMIT_COUNT_DIR" "$(dirname "$LOG")" "$LOCK_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [review-consumer] $*" >> "$LOG"
}

now_ts() {
    date +%s
}

notify_review_result() {
    local tg_token tg_chat config_file msg
    config_file="$HOME/.autopilot/config.yaml"
    tg_token=$(grep '^bot_token' "$config_file" 2>/dev/null | awk '{print $2}' | tr -d '"')
    tg_chat=$(grep '^chat_id' "$config_file" 2>/dev/null | awk '{print $2}' | tr -d '"')
    msg="$1"
    if [ -n "$tg_token" ] && [ -n "$tg_chat" ]; then
        curl -s -X POST "https://api.telegram.org/bot${tg_token}/sendMessage" \
            -d chat_id="$tg_chat" -d text="$msg" >/dev/null 2>&1 &
    fi
}

TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD="gtimeout"
fi

run_with_timeout() {
    local secs="$1"
    shift
    if [ -n "$TIMEOUT_CMD" ]; then
        "$TIMEOUT_CMD" "$secs" "$@"
    else
        "$@"
    fi
}

is_codex_idle() {
    local window="$1" status_json status
    [ -x "${SCRIPT_DIR}/codex-status.sh" ] || return 1
    status_json=$("${SCRIPT_DIR}/codex-status.sh" "$window" 2>/dev/null || echo '{"status":"absent"}')
    status=$(echo "$status_json" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
    [ "$status" = "idle" ] || [ "$status" = "idle_low_context" ]
}

wait_for_non_empty_file() {
    local file="$1" timeout_secs="$2"
    local waited=0

    while [ "$waited" -lt "$timeout_secs" ]; do
        [ -s "$file" ] && return 0
        sleep 5
        waited=$((waited + 5))
    done

    return 1
}

is_layer2_output_clean() {
    local content="${1:-}"
    printf '%s\n' "$content" | awk '
        {
            line = $0
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            if (line != "") {
                count += 1
                value = toupper(line)
            }
        }
        END {
            if (count == 1 && value == "CLEAN") {
                exit 0
            }
            exit 1
        }
    '
}

sync_project_status() {
    local project_dir="$1" event="$2"
    shift 2 || true
    if [ -x "${SCRIPT_DIR}/status-sync.sh" ]; then
        "${SCRIPT_DIR}/status-sync.sh" "$project_dir" "$event" "$@" >/dev/null 2>&1 || true
    fi
}

sync_review_bugfix_items() {
    local project_dir="$1" review_file="$2" window="$3"
    local items_file="${project_dir}/prd-items.yaml"
    local sync_script="${SCRIPT_DIR}/review_to_prd_bugfix.py"

    [ -f "$items_file" ] || return 0
    [ -x "$sync_script" ] || return 0
    [ -s "$review_file" ] || return 0

    local sync_output
    sync_output=$(python3 "$sync_script" --review-file "$review_file" --items-file "$items_file" 2>&1 || true)
    if echo "$sync_output" | grep -qE '"added_bugfixes":[[:space:]]*[1-9][0-9]*'; then
        log "🧩 ${window}: review->bugfix sync ${sync_output}"
        sync_project_status "$project_dir" "prd_bugfix_synced" "window=${window}"
    fi
}

acquire_script_lock() {
    if mkdir "$REVIEW_LOCK" 2>/dev/null; then
        echo "$$" > "${REVIEW_LOCK}/pid"
        return 0
    fi

    local existing_pid
    existing_pid=$(cat "${REVIEW_LOCK}/pid" 2>/dev/null || echo 0)
    existing_pid=$(normalize_int "$existing_pid")

    if [ "$existing_pid" -gt 0 ] && kill -0 "$existing_pid" 2>/dev/null; then
        log "⏭ lock held by pid ${existing_pid}, skip this round"
        return 1
    fi

    rm -rf "$REVIEW_LOCK" 2>/dev/null || true
    if mkdir "$REVIEW_LOCK" 2>/dev/null; then
        echo "$$" > "${REVIEW_LOCK}/pid"
        log "🔓 reclaimed stale lock from pid ${existing_pid}"
        return 0
    fi

    log "⚠️ failed to acquire review consumer lock"
    return 1
}

if ! acquire_script_lock; then
    exit 0
fi
trap 'rm -rf "$REVIEW_LOCK" 2>/dev/null || true' EXIT

# 扫描所有 trigger 文件
for trigger_file in "${STATE_DIR}"/review-trigger-*; do
    [ -f "$trigger_file" ] || continue

    safe=$(basename "$trigger_file" | sed 's/review-trigger-//')
    trigger_payload=$(cat "$trigger_file" 2>/dev/null || echo "")
    project_dir="$trigger_payload"
    window=""
    if command -v jq >/dev/null 2>&1 && echo "$trigger_payload" | jq -e . >/dev/null 2>&1; then
        parsed_project_dir=$(echo "$trigger_payload" | jq -r '.project_dir // empty' 2>/dev/null || echo "")
        parsed_window=$(echo "$trigger_payload" | jq -r '.window // empty' 2>/dev/null || echo "")
        [ -n "$parsed_project_dir" ] && project_dir="$parsed_project_dir"
        [ -n "$parsed_window" ] && window="$parsed_window"
    fi
    [ -n "$window" ] || window=$(resolve_window_from_safe "$safe")

    if [ ! -d "$project_dir" ]; then
        log "⚠️ ${safe}: project dir not found: ${project_dir}"
        rm -f "$trigger_file"
        continue
    fi
    trigger_mtime=$(stat -f %m "$trigger_file" 2>/dev/null || echo 0)
    trigger_age=$(( $(now_ts) - trigger_mtime ))
    stale_trigger=false
    if [ "$trigger_age" -ge "$REVIEW_TRIGGER_STALE_SECONDS" ]; then
        stale_trigger=true
        log "⚠️ ${safe}: review trigger stale (${trigger_age}s) — forcing consumption"
    fi

    log "🔍 ${safe}: consuming incremental review trigger for ${project_dir}"

    # 记录 review 开始
    review_commit=$(git -C "$project_dir" rev-parse HEAD 2>/dev/null)
    last_review=$(cat "${project_dir}/.last-review-commit" 2>/dev/null || git -C "$project_dir" log -50 --format="%H" 2>/dev/null | tail -1)
    review_output_file="${STATE_DIR}/layer2-review-${safe}.txt"

    # 检查是否已有 in-progress review（防重复发送）
    in_progress_file="${STATE_DIR}/review-in-progress-${safe}"
    if [ -f "$in_progress_file" ]; then
        ip_age=$(( $(now_ts) - $(stat -f %m "$in_progress_file" 2>/dev/null || echo 0) ))
        if [ "$ip_age" -lt 600 ]; then
            # 10 分钟内已发送 review，等待结果
            if [ -s "$review_output_file" ]; then
                # 输出文件已有内容，标记完成
                rm -f "$in_progress_file"
                log "✅ ${safe}: review output received after ${ip_age}s"
            else
                log "⏭ ${safe}: review in-progress (${ip_age}s), waiting for output"
                continue
            fi
        else
            # 超过 10 分钟无结果，清理标记重试
            rm -f "$in_progress_file"
            log "⚠️ ${safe}: review in-progress stale (${ip_age}s), retrying"
        fi
    fi

    # M-5: 非 idle 不消费 trigger，留待下轮
    if ! $stale_trigger && ! is_codex_idle "$window"; then
        log "⏭ ${safe}: Codex not idle, keep trigger for next round"
        continue
    fi

    # Layer 1: 快速自动扫描
    local_issues=""

    if [ -f "${project_dir}/tsconfig.json" ]; then
        tsc_output=""
        tsc_rc=0
        tsc_output=$(cd "$project_dir" && run_with_timeout "$TSC_TIMEOUT_SECONDS" npx tsc --noEmit 2>&1) || tsc_rc=$?
        if [ "$tsc_rc" -eq 124 ] || [ "$tsc_rc" -eq 137 ]; then
            local_issues="${local_issues}tsc: timeout(${TSC_TIMEOUT_SECONDS}s). "
        else
            tsc_errors=$(echo "$tsc_output" | grep -c "error TS" 2>/dev/null || true)
            tsc_errors=$(normalize_int "$tsc_errors")
            if [ "$tsc_errors" -gt 0 ]; then
                local_issues="${local_issues}tsc: ${tsc_errors} errors. "
            fi
        fi
    fi

    danger=$(cd "$project_dir" && git grep -nI -E '\beval\s*\(' -- '*.ts' '*.tsx' 2>/dev/null | grep -vc "test\|spec\|mock" 2>/dev/null || true)
    danger=$(normalize_int "$danger")
    if [ "$danger" -gt 0 ]; then
        local_issues="${local_issues}eval: ${danger}处. "
    fi

    # 获取变更文件列表
    changed_files=""
    review_range=""
    if [ -n "$last_review" ] && git -C "$project_dir" cat-file -e "$last_review" 2>/dev/null; then
        review_range="${last_review}..HEAD"
        changed_files=$(git -C "$project_dir" diff "$review_range" --name-only --diff-filter=ACMR 2>/dev/null || true)
    else
        review_range="HEAD~${LAYER2_FALLBACK_COMMIT_WINDOW}..HEAD"
        changed_files=$(git -C "$project_dir" diff "$review_range" --name-only --diff-filter=ACMR 2>/dev/null || true)
    fi
    changed_files=$(echo "$changed_files" | sed '/^$/d')

    layer2_completed=false
    layer2_issues=""

    if [ -n "$changed_files" ]; then
        changed_count=$(echo "$changed_files" | wc -l | tr -d ' ')
        changed_count=$(normalize_int "$changed_count")
        preview_files=$(echo "$changed_files" | head -n "$LAYER2_FILE_PREVIEW_LIMIT")
        file_list=$(echo "$preview_files" | tr '\n' ', ' | sed 's/, $//')
        scope_hint="全量审查范围: git diff ${review_range} --name-only --diff-filter=ACMR（共${changed_count}个文件）"
        if [ "$changed_count" -gt "$LAYER2_FILE_PREVIEW_LIMIT" ]; then
            omitted=$((changed_count - LAYER2_FILE_PREVIEW_LIMIT))
            scope_hint="${scope_hint}；以下仅预览前${LAYER2_FILE_PREVIEW_LIMIT}个: ${file_list} ...(+${omitted} files omitted)"
        else
            scope_hint="${scope_hint}；文件: ${file_list}"
        fi
        review_msg="执行增量review(P0-P3)。把结果写入 ${review_output_file}；如果无问题仅写 CLEAN。请按完整范围审查，不要只看预览列表。${scope_hint}"

        if [ ! -x "${SCRIPT_DIR}/tmux-send.sh" ]; then
            log "⏭ ${safe}: tmux-send.sh missing, keep trigger"
            continue
        fi

        rm -f "$review_output_file"
        if "${SCRIPT_DIR}/tmux-send.sh" "$window" "$review_msg" >/dev/null 2>&1; then
            touch "$in_progress_file"
            log "📤 ${safe}: Layer 2 incremental review instruction sent to Codex"
        else
            log "⏭ ${safe}: failed to send Layer 2 instruction, keep trigger"
            continue
        fi

        # 不再阻塞等待 — 由 in-progress 机制在下轮检查输出
        if [ ! -s "$review_output_file" ]; then
            log "⏭ ${safe}: review sent, waiting for output (in-progress)"
            continue
        fi
        rm -f "$in_progress_file"

        layer2_raw=$(cat "$review_output_file" 2>/dev/null || echo "")
        layer2_raw_flat=$(echo "$layer2_raw" | tr '\n' ' ' | tr -s ' ' | sed 's/^ *//; s/ *$//')
        sync_review_bugfix_items "$project_dir" "$review_output_file" "$window"
        if ! is_layer2_output_clean "$layer2_raw"; then
            layer2_issues="layer2: ${layer2_raw_flat:0:400}. "
        fi
        layer2_completed=true
    else
        # 无增量文件时不阻塞消费
        layer2_completed=true
    fi

    combined_issues="${local_issues}${layer2_issues}"

    if [ "$layer2_completed" != "true" ]; then
        log "⏭ ${safe}: layer2 not completed, keep trigger"
        continue
    fi

    # Telegram 通知函数
        if [ -n "$combined_issues" ]; then
        log "⚠️ ${safe}: review found issues: ${combined_issues}"
        # 有问题时写 issues 文件供 watchdog nudge 修复，不重置计数
        echo "$combined_issues" > "${STATE_DIR}/autocheck-issues-${safe}.tmp" && mv -f "${STATE_DIR}/autocheck-issues-${safe}.tmp" "${STATE_DIR}/autocheck-issues-${safe}"
        log "⚠️ ${safe}: issues written for watchdog nudge, counters NOT reset"
        # 重置 commit 计数为 0（fix 后的新 commit 重新累积，达到阈值后自动 re-review）
        echo 0 > "${COMMIT_COUNT_DIR}/${safe}-since-review"
        now_ts > "${COMMIT_COUNT_DIR}/${safe}-last-review-ts"
        sync_project_status "$project_dir" "review_issues" "window=${window}" "issues=${combined_issues}" "state=idle"
        # Telegram 通知 review 结果
        issue_preview="${combined_issues:0:200}"
        notify_review_result "🔍 ${window} Review 发现问题，已触发修复循环：${issue_preview}"
    else
        log "✅ ${safe}: review clean"
        # review CLEAN = 本轮迭代完成
        echo 0 > "${COMMIT_COUNT_DIR}/${safe}-since-review"
        now_ts > "${COMMIT_COUNT_DIR}/${safe}-last-review-ts"
        rm -f "${STATE_DIR}/autocheck-issues-${safe}"
        # Review CLEAN → reset nudge backoff (Codex proved responsive)
        echo 0 > "${COOLDOWN_DIR}/nudge-count-${safe}" 2>/dev/null || true
        rm -f "${STATE_DIR}/alert-stalled-${safe}" 2>/dev/null || true
        sync_project_status "$project_dir" "review_clean" "window=${window}" "state=idle"
        # Telegram 通知 CLEAN
        notify_review_result "✅ ${window} Review CLEAN 🟢 本轮迭代完成，代码质量达标！"
    fi

    # 记录 review commit 点
    if [ -n "$review_commit" ]; then
        echo "$review_commit" > "${project_dir}/.last-review-commit"
    fi

    # 写 review 历史
    review_dir="${project_dir}/.code-review"
    mkdir -p "$review_dir" 2>/dev/null
    review_file="${review_dir}/$(date '+%Y-%m-%d-%H%M%S')-$$.json"
    if command -v jq >/dev/null 2>&1; then
        jq -n \
          --arg d "$(date '+%Y-%m-%d')" \
          --arg i "${combined_issues:-none}" \
          --arg c "${review_commit}" \
          '{date:$d,type:"incremental",issues:$i,commit:$c}' > "$review_file"
    else
        python3 - "$review_file" "$(date '+%Y-%m-%d')" "${combined_issues:-none}" "${review_commit}" <<'PY'
import json
import pathlib
import sys

review_path = pathlib.Path(sys.argv[1])
payload = {
    "date": sys.argv[2],
    "type": "incremental",
    "issues": sys.argv[3],
    "commit": sys.argv[4],
}
review_path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
PY
    fi

    # 清理 trigger 文件（mv 替代 rm 防 race condition）
    mv -f "$trigger_file" "${trigger_file}.done" 2>/dev/null
    rm -f "${trigger_file}.done" 2>/dev/null
    if [ -n "$combined_issues" ]; then
        log "✅ ${safe}: review consumed, counters not reset"
    else
        log "✅ ${safe}: review consumed, counters reset"
    fi
done
