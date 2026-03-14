#!/bin/bash
# test-agent.sh — Test Agent 主编排
# 用法:
#   test-agent.sh evaluate <project_dir> <window>
#   test-agent.sh enqueue <project_dir> <window> <reason>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=autopilot-lib.sh
source "${SCRIPT_DIR}/autopilot-lib.sh"
if [ -f "${SCRIPT_DIR}/autopilot-constants.sh" ]; then
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/autopilot-constants.sh"
fi

CONFIG_FILE="${AUTOPILOT_CONFIG_FILE:-$HOME/.autopilot/config.yaml}"
STATE_DIR="${STATE_DIR:-$HOME/.autopilot/state}"
LOG_DIR="${LOG_DIR:-$HOME/.autopilot/logs}"
COVERAGE_COLLECTOR="${SCRIPT_DIR}/coverage-collect.sh"
TASK_QUEUE="${SCRIPT_DIR}/task-queue.sh"
DISCORD_NOTIFIER="${SCRIPT_DIR}/discord-notify.sh"
RUN_LOG_BASENAME=".autopilot-test-run.log"
mkdir -p "$STATE_DIR" "$LOG_DIR"

log() {
    echo "[test-agent $(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

yaml_trim() {
    local v="${1:-}"
    v="${v%%#*}"
    v=$(echo "$v" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    v=$(echo "$v" | sed 's/^"//; s/"$//; s/^'\''//; s/'\''$//')
    echo "$v"
}

normalize_bool() {
    local raw
    raw=$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')
    case "$raw" in
        1|true|yes|on) echo "true" ;;
        *) echo "false" ;;
    esac
}

get_test_agent_enabled() {
    [ -f "$CONFIG_FILE" ] || { echo "false"; return 0; }
    awk '
        /^[[:space:]]*test_agent:[[:space:]]*$/ {in_test=1; next}
        in_test && /^[^[:space:]]/ {in_test=0}
        in_test && /^[[:space:]]*enabled:[[:space:]]*/ {
            sub(/^[[:space:]]*enabled:[[:space:]]*/, "", $0)
            print
            exit
        }
    ' "$CONFIG_FILE" 2>/dev/null | head -n1
}

get_changed_files_min() {
    [ -f "$CONFIG_FILE" ] || { echo "80"; return 0; }
    local value
    value=$(awk '
        /^[[:space:]]*test_agent:[[:space:]]*$/ {in_test=1; next}
        in_test && /^[^[:space:]]/ {in_test=0}
        in_test && /^[[:space:]]*coverage:[[:space:]]*$/ {in_cov=1; next}
        in_cov && in_test && /^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*:[[:space:]]*$/ && $0 !~ /^[[:space:]]*changed_files_min:[[:space:]]*/ {next}
        in_cov && /^[[:space:]]*changed_files_min:[[:space:]]*/ {
            sub(/^[[:space:]]*changed_files_min:[[:space:]]*/, "", $0)
            print
            exit
        }
    ' "$CONFIG_FILE" 2>/dev/null | head -n1)
    value=$(yaml_trim "$value")
    value=$(normalize_int "$value")
    [ "$value" -gt 0 ] || value=80
    echo "$value"
}

get_max_tasks_per_round() {
    [ -f "$CONFIG_FILE" ] || { echo "3"; return 0; }
    local value
    value=$(awk '
        /^[[:space:]]*test_agent:[[:space:]]*$/ {in_test=1; next}
        in_test && /^[^[:space:]]/ {in_test=0}
        in_test && /^[[:space:]]*queue:[[:space:]]*$/ {in_q=1; next}
        in_q && in_test && /^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*:[[:space:]]*$/ && $0 !~ /^[[:space:]]*max_tasks_per_round:[[:space:]]*/ {next}
        in_q && /^[[:space:]]*max_tasks_per_round:[[:space:]]*/ {
            sub(/^[[:space:]]*max_tasks_per_round:[[:space:]]*/, "", $0)
            print
            exit
        }
    ' "$CONFIG_FILE" 2>/dev/null | head -n1)
    value=$(yaml_trim "$value")
    value=$(normalize_int "$value")
    [ "$value" -gt 0 ] || value=3
    echo "$value"
}

default_test_cmd_for_package_manager() {
    local package_manager="${1:-npm}"
    case "$package_manager" in
        pnpm) echo "pnpm test" ;;
        yarn) echo "yarn test" ;;
        bun) echo "bun test" ;;
        *) echo "npm test" ;;
    esac
}

get_jest_test_cmd() {
    local package_manager="${1:-npm}"
    [ -f "$CONFIG_FILE" ] || {
        echo "$(default_test_cmd_for_package_manager "$package_manager") -- --coverage --ci"
        return 0
    }

    local value
    value=$(awk '
        /^[[:space:]]*test_agent:[[:space:]]*$/ {in_test=1; next}
        in_test && /^[^[:space:]]/ {in_test=0}
        in_test && /^[[:space:]]*frameworks:[[:space:]]*$/ {in_fw=1; next}
        in_fw && in_test && /^[[:space:]]*jest:[[:space:]]*$/ {in_jest=1; next}
        in_jest && /^[[:space:]]*test_cmd:[[:space:]]*/ {
            sub(/^[[:space:]]*test_cmd:[[:space:]]*/, "", $0)
            print
            exit
        }
    ' "$CONFIG_FILE" 2>/dev/null | head -n1)
    value=$(yaml_trim "$value")
    [ -n "$value" ] || value="$(default_test_cmd_for_package_manager "$package_manager") -- --coverage --ci"
    echo "$value"
}

write_state_atomic() {
    local safe="$1" json_payload="$2"
    local state_file tmp_file
    state_file="${STATE_DIR}/test-agent-${safe}.json"
    tmp_file="${state_file}.tmp.$$"
    printf '%s\n' "$json_payload" > "$tmp_file"
    mv -f "$tmp_file" "$state_file"
}

list_test_packages() {
    local project_dir="$1"
    "$COVERAGE_COLLECTOR" packages "$project_dir" 2>/dev/null || jq -n --arg project "$project_dir" '{root:$project,monorepo:false,packages:[]}'
}

build_framework_test_cmd() {
    local tool="$1" package_manager="$2"
    case "$tool" in
        jest)
            get_jest_test_cmd "$package_manager"
            ;;
        vitest)
            case "$package_manager" in
                pnpm) echo "pnpm exec vitest run --coverage" ;;
                yarn) echo "yarn vitest run --coverage" ;;
                bun) echo "bun x vitest run --coverage" ;;
                *) echo "npx vitest run --coverage" ;;
            esac
            ;;
        node_test)
            echo "node --test --experimental-test-coverage"
            ;;
        package_script)
            default_test_cmd_for_package_manager "$package_manager"
            ;;
        junit)
            echo "./gradlew test jacocoTestReport"
            ;;
        bats)
            echo "bats test/"
            ;;
        *)
            echo ""
            ;;
    esac
}

run_coverage_collection_cmd() {
    local package_dir="$1" tool="$2" package_manager="$3" package_name="$4"
    local cmd run_log summary_log rc
    cmd=$(build_framework_test_cmd "$tool" "$package_manager")
    run_log="${package_dir}/${RUN_LOG_BASENAME}"
    summary_log="${LOG_DIR}/test-agent-run-$(sanitize "$package_name")-$(now_ts).log"

    rm -f "$run_log"
    if [ -z "$cmd" ]; then
        echo 0
        return 0
    fi

    set +e
    (
        cd "$package_dir" &&
        run_with_timeout 180 bash -lc "$cmd"
    ) >"$run_log" 2>&1
    rc=$?
    set -e

    cp "$run_log" "$summary_log" 2>/dev/null || true
    if [ "$rc" -ne 0 ]; then
        log "测试/覆盖率命令退出非 0 (${package_name}, tool=${tool}, rc=${rc})，日志: ${summary_log}"
    fi
    echo "$rc"
}

merge_evaluation_payload() {
    local raw_json="$1" run_results_file="$2" project_dir="$3" window="$4"
    local enabled now
    enabled=$(normalize_bool "$(get_test_agent_enabled)")
    now=$(now_ts)

    python3 - "$raw_json" "$run_results_file" "$project_dir" "$window" "$enabled" "$now" <<'PYEOF'
import json
import sys
from pathlib import Path

payload = json.loads(sys.argv[1] or "{}")
run_results_path = Path(sys.argv[2])
project_dir = sys.argv[3]
window = sys.argv[4]
enabled = sys.argv[5].lower() == "true"
generated_at = int(sys.argv[6])

run_results = []
if run_results_path.exists():
    for raw in run_results_path.read_text(encoding="utf-8", errors="ignore").splitlines():
        raw = raw.strip()
        if raw:
            run_results.append(json.loads(raw))

run_map = {item.get("relative_dir", "."): item for item in run_results}
supported_tools = {"jest", "vitest", "node_test"}

packages = payload.get("packages") or []
for package in packages:
    relative_dir = package.get("relative_dir") or "."
    run_info = run_map.get(relative_dir, {})
    package["collect_rc"] = int(run_info.get("collect_rc", package.get("collect_rc", 0) or 0))
    package["test_cmd"] = run_info.get("test_cmd", package.get("test_cmd") or "")
    package["package_manager"] = run_info.get("package_manager", package.get("package_manager") or "")
    package["phase1_supported"] = (package.get("tool") or "") in supported_tools

payload["project_dir"] = project_dir
payload["window"] = window
payload["test_agent_enabled"] = enabled
payload["generated_at"] = generated_at
payload["collect_rc"] = max([int(package.get("collect_rc", 0) or 0) for package in packages] + [int(payload.get("collect_rc", 0) or 0)])
payload["phase1_supported"] = all((package.get("tool") or "") in supported_tools for package in packages) if packages else False

print(json.dumps(payload, ensure_ascii=False))
PYEOF
}

evaluate_core() {
    local project_dir="$1" window="$2"

    [ -d "$project_dir" ] || {
        jq -n --arg project "$project_dir" --arg window "$window" --arg now "$(now_ts)" \
            '{tool:"unknown",monorepo:false,package_count:0,packages:[],line_coverage:0,files:[],project_dir:$project,window:$window,generated_at:($now|tonumber),error:"project_dir_not_found"}'
        return 0
    }

    local packages_json package_count tmp_run_results raw_json
    packages_json=$(list_test_packages "$project_dir")
    package_count=$(echo "$packages_json" | jq -r '.packages | length' 2>/dev/null || echo 0)
    package_count=$(normalize_int "$package_count")

    if [ "$package_count" -eq 0 ]; then
        jq -n --arg project "$project_dir" --arg window "$window" --arg now "$(now_ts)" \
            '{tool:"unknown",monorepo:false,package_count:0,packages:[],line_coverage:0,files:[],project_dir:$project,window:$window,generated_at:($now|tonumber),error:"no_test_packages"}'
        return 0
    fi

    tmp_run_results=$(mktemp /tmp/test-agent-run-results.XXXXXX)

    while IFS= read -r package_item; do
        [ -n "$package_item" ] || continue
        local package_dir relative_dir package_name tool package_manager run_rc test_cmd
        package_dir=$(echo "$package_item" | jq -r '.dir')
        relative_dir=$(echo "$package_item" | jq -r '.relative_dir // "."')
        package_name=$(echo "$package_item" | jq -r '.name')
        tool=$(echo "$package_item" | jq -r '.framework // "unknown"')
        package_manager=$(echo "$package_item" | jq -r '.package_manager // "npm"')
        run_rc=$(run_coverage_collection_cmd "$package_dir" "$tool" "$package_manager" "$package_name")
        test_cmd=$(build_framework_test_cmd "$tool" "$package_manager")
        jq -c -n \
            --arg relative_dir "$relative_dir" \
            --arg package_manager "$package_manager" \
            --arg test_cmd "$test_cmd" \
            --arg run_rc "$run_rc" \
            '{relative_dir:$relative_dir,package_manager:$package_manager,test_cmd:$test_cmd,collect_rc:($run_rc|tonumber)}' >> "$tmp_run_results"
    done < <(echo "$packages_json" | jq -c '.packages[]?')

    raw_json=$("$COVERAGE_COLLECTOR" collect "$project_dir" 2>/dev/null || jq -n '{tool:"unknown",monorepo:false,package_count:0,packages:[],line_coverage:0,files:[],error:"collect_failed"}')
    merge_evaluation_payload "$raw_json" "$tmp_run_results" "$project_dir" "$window"
    rm -f "$tmp_run_results"
}

get_changed_files_this_round() {
    local project_dir="$1"

    if git -C "$project_dir" rev-parse --verify HEAD~1 >/dev/null 2>&1; then
        git -C "$project_dir" diff --name-only --relative HEAD~1 HEAD 2>/dev/null || true
    else
        git -C "$project_dir" diff --name-only --relative 2>/dev/null || true
    fi
}

build_task_candidates() {
    local eval_json="$1" changed_files="$2" threshold="$3" max_tasks="$4"

    CHANGED_FILES="$changed_files" python3 - "$threshold" "$max_tasks" "$eval_json" <<'PYEOF'
import json
import os
import sys

threshold = float(sys.argv[1])
max_tasks = int(sys.argv[2])
payload_raw = sys.argv[3]
changed_set = set(p.strip().lstrip("./") for p in os.environ.get("CHANGED_FILES", "").split("\n") if p.strip())

def lines_to_text(lines):
    if not lines:
        return "无"
    arr = []
    for item in lines[:30]:
        try:
            arr.append(str(int(item)))
        except Exception:
            continue
    return ",".join(arr) if arr else "无"

payload = json.loads(payload_raw or "{}")
files = payload.get("files", [])

low_files = []
for f in files:
    path = (f.get("path") or "").lstrip("./")
    if not path:
        continue
    pct = float(f.get("line_pct") or 0)
    if pct >= threshold:
        continue
    low_files.append({
        "path": path,
        "line_pct": pct,
        "uncovered_lines": f.get("uncovered_lines") or [],
        "changed": path in changed_set,
    })

low_files.sort(key=lambda item: (0 if item["changed"] else 1, item["line_pct"], item["path"]))
selected = low_files[:max_tasks]

for item in selected:
    item["task_text"] = (
        f"为 {item['path']} 补充单元测试，目标覆盖率 >80%。"
        f"当前覆盖率 {item['line_pct']:.2f}%，未覆盖行：{lines_to_text(item['uncovered_lines'])}"
    )

print(json.dumps({"tasks": selected}, ensure_ascii=False))
PYEOF
}

queue_has_similar_test_task() {
    local queue_file="$1" file_path="$2"
    [ -f "$queue_file" ] || return 1
    grep -E '^\- \[( |→)\].*\| type: test' "$queue_file" 2>/dev/null | grep -F " ${file_path}" | grep -qvE "${file_path}[a-zA-Z0-9_.]" 2>/dev/null
}

send_test_agent_notification() {
    local window="$1" message="$2"
    [ -x "$DISCORD_NOTIFIER" ] || return 0
    "$DISCORD_NOTIFIER" --by-window "$window" "$message" >/dev/null 2>&1 || log "⚠️ ${window}: discord test-agent notify failed"
}

maybe_notify_evaluation_failure() {
    local window="$1" eval_json="$2"
    local summary
    summary=$(echo "$eval_json" | jq -r '
        [
          (.packages // [])[]
          | select((.collect_rc // 0) != 0)
          | "\(.name) rc=\(.collect_rc)"
        ] | join("; ")
    ' 2>/dev/null || echo "")
    if [ -n "$summary" ]; then
        send_test_agent_notification "$window" "🧪 ${window}: 测试执行失败，检查 test-agent。${summary}"
    fi
}

maybe_notify_enqueue_issues() {
    local window="$1" result_json="$2"
    local failure_summary
    failure_summary=$(echo "$result_json" | jq -r '
        [
          (.evaluation.packages // [])[]
          | select((.collect_rc // 0) != 0)
          | "\(.name) rc=\(.collect_rc)"
        ] | join("; ")
    ' 2>/dev/null || echo "")
    if [ -n "$failure_summary" ]; then
        send_test_agent_notification "$window" "🧪 ${window}: 测试执行失败，检查 test-agent。${failure_summary}"
        return 0
    fi

    local enqueued
    enqueued=$(echo "$result_json" | jq -r '.enqueued // 0' 2>/dev/null || echo 0)
    enqueued=$(normalize_int "$enqueued")
    if [ "$enqueued" -gt 0 ]; then
        local targets
        targets=$(echo "$result_json" | jq -r '[.candidates.tasks[]?.path][0:3] | join(", ")' 2>/dev/null || echo "")
        send_test_agent_notification "$window" "🧪 ${window}: 检测到覆盖率问题，已入队 ${enqueued} 个测试任务。${targets}"
    fi
}

test_agent_evaluate() {
    local project_dir="$1" window="$2"
    local safe eval_json state_json

    safe=$(sanitize "$window")
    [ -n "$safe" ] || safe="window"
    eval_json=$(evaluate_core "$project_dir" "$window")

    state_json=$(jq -n \
        --arg window "$window" \
        --arg project "$project_dir" \
        --argjson eval "$eval_json" \
        --arg now "$(now_ts)" '
        {
            mode:"evaluate",
            window:$window,
            project_dir:$project,
            evaluation:$eval,
            generated_at:($now|tonumber)
        }
    ')
    write_state_atomic "$safe" "$state_json"
    maybe_notify_evaluation_failure "$window" "$eval_json"
    echo "$eval_json"
}

test_agent_enqueue() {
    local project_dir="$1" window="$2" reason="$3"
    local safe threshold max_tasks eval_json changed_files tasks_json
    local queue_file enqueued_count skipped_count

    safe=$(sanitize "$window")
    [ -n "$safe" ] || safe="window"
    threshold=$(get_changed_files_min)
    max_tasks=$(get_max_tasks_per_round)

    eval_json=$(evaluate_core "$project_dir" "$window")
    changed_files=$(get_changed_files_this_round "$project_dir")
    tasks_json=$(build_task_candidates "$eval_json" "$changed_files" "$threshold" "$max_tasks")

    queue_file="$HOME/.autopilot/task-queue/${safe}.md"
    enqueued_count=0
    skipped_count=0

    while IFS= read -r task_item; do
        [ -n "$task_item" ] || continue
        local file_path task_text
        file_path=$(echo "$task_item" | jq -r '.path // ""' 2>/dev/null || echo "")
        task_text=$(echo "$task_item" | jq -r '.task_text // ""' 2>/dev/null || echo "")
        [ -n "$file_path" ] || continue
        [ -n "$task_text" ] || continue

        if queue_has_similar_test_task "$queue_file" "$file_path"; then
            skipped_count=$((skipped_count + 1))
            continue
        fi

        if "$TASK_QUEUE" add "$safe" "$task_text" normal --type test >/dev/null 2>&1; then
            enqueued_count=$((enqueued_count + 1))
        else
            skipped_count=$((skipped_count + 1))
        fi
    done < <(echo "$tasks_json" | jq -c '.tasks[]?' 2>/dev/null || true)

    local result_json
    result_json=$(jq -n \
        --arg window "$window" \
        --arg project "$project_dir" \
        --arg reason "$reason" \
        --argjson eval "$eval_json" \
        --argjson candidates "$tasks_json" \
        --arg threshold "$threshold" \
        --arg max_tasks "$max_tasks" \
        --arg enqueued "$enqueued_count" \
        --arg skipped "$skipped_count" \
        --arg now "$(now_ts)" '
        {
            mode:"enqueue",
            window:$window,
            project_dir:$project,
            reason:$reason,
            threshold:($threshold|tonumber),
            max_tasks_per_round:($max_tasks|tonumber),
            enqueued:($enqueued|tonumber),
            skipped:($skipped|tonumber),
            evaluation:$eval,
            candidates:$candidates,
            generated_at:($now|tonumber)
        }
    ')

    write_state_atomic "$safe" "$result_json"
    maybe_notify_enqueue_issues "$window" "$result_json"
    echo "$result_json"
}

usage() {
    cat <<'USAGE'
用法:
  test-agent.sh evaluate <project_dir> <window>
  test-agent.sh enqueue <project_dir> <window> <reason>
USAGE
}

main() {
    local cmd="${1:-}"
    case "$cmd" in
        evaluate|test_agent_evaluate)
            local project_dir="${2:-}"
            local window="${3:-}"
            [ -n "$project_dir" ] && [ -n "$window" ] || { usage; exit 1; }
            test_agent_evaluate "$project_dir" "$window"
            ;;
        enqueue|test_agent_enqueue)
            local project_dir="${2:-}"
            local window="${3:-}"
            local reason="${4:-manual}"
            [ -n "$project_dir" ] && [ -n "$window" ] || { usage; exit 1; }
            test_agent_enqueue "$project_dir" "$window" "$reason"
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"
