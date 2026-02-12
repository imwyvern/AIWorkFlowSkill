#!/bin/bash
# task-queue.sh — 紧急/临时任务队列管理
#
# 定位: 短期、具体、可一次 commit 解决的任务（bug、小迭代）
#       与 prd-todo.md（长期功能规划）互补，不替代
#       queue 优先级高于 prd-todo（watchdog handle_idle 优先级 2 vs 4）
#
# 用法:
#   task-queue.sh add <project> <task> [priority]   # 添加任务 (priority: high/normal)
#   task-queue.sh list <project>                     # 列出队列
#   task-queue.sh next <project>                     # 获取下一个待办任务
#   task-queue.sh start <project>                    # 标记第一个待办为进行中
#   task-queue.sh done <project> [commit_hash]       # 完成 + 自动同步 prd-todo
#   task-queue.sh fail <project> [reason]            # 失败（自动重新入队）
#   task-queue.sh count <project>                    # 待办数
#   task-queue.sh summary                            # 全局概要

set -euo pipefail

QUEUE_DIR="$HOME/.autopilot/task-queue"
mkdir -p "$QUEUE_DIR"

sanitize() {
    echo "$1" | tr -cd 'a-zA-Z0-9_-'
}

now_iso() {
    date '+%Y-%m-%d %H:%M'
}

queue_file() {
    local project="$1"
    local safe
    safe=$(sanitize "$project")
    echo "${QUEUE_DIR}/${safe}.md"
}

# 确保队列文件存在且有 header
ensure_queue() {
    local file="$1"
    if [ ! -f "$file" ]; then
        cat > "$file" << 'HEADER'
# Task Queue
# States: [ ]=pending, [>]=in-progress, [x]=done, [!]=failed
HEADER
    fi
}

cmd_add() {
    local project="${1:?用法: task-queue.sh add <project> <task>}"
    local task="${2:?缺少任务描述}"
    local priority="${3:-normal}"
    local file
    file=$(queue_file "$project")
    ensure_queue "$file"

    local entry="- [ ] ${task} | added: $(now_iso)"

    if [ "$priority" = "high" ]; then
        # 高优先级: 插入到第一个 [ ] 之前（python 处理，避免 sed UTF-8 问题）
        python3 << PYEOF
f = "$file"
entry = "$entry"
lines = open(f).readlines()
inserted = False
for i, line in enumerate(lines):
    if line.startswith("- [ ]"):
        lines.insert(i, entry + "\n")
        inserted = True
        break
if not inserted:
    lines.append(entry + "\n")
open(f, "w").writelines(lines)
PYEOF
    else
        echo "$entry" >> "$file"
    fi

    echo "OK: 任务已添加到 ${project} 队列"
}

cmd_list() {
    local project="${1:?用法: task-queue.sh list <project>}"
    local file
    file=$(queue_file "$project")
    if [ ! -f "$file" ]; then
        echo "(空队列)"
        return
    fi
    grep '^\- \[' "$file" || echo "(空队列)"
}

cmd_next() {
    local project="${1:?}"
    local file
    file=$(queue_file "$project")
    [ -f "$file" ] || return 1

    # 返回第一个待办任务（去掉 metadata）
    local line
    line=$(grep -m1 '^\- \[ \]' "$file" || true)
    [ -z "$line" ] && return 1

    # 提取任务描述（| 之前的部分）
    echo "$line" | sed 's/^- \[ \] //; s/ | added:.*$//'
}

cmd_start() {
    local project="${1:?}"
    local file
    file=$(queue_file "$project")
    [ -f "$file" ] || return 1

    # 把第一个 [ ] 改为 [→]，加 started 时间
    local has_todo
    has_todo=$(grep -c '^\- \[ \]' "$file" || true)
    [ "$has_todo" -gt 0 ] || return 1

    # macOS sed: 只替换第一个匹配
    local task_line
    task_line=$(grep -m1 '^\- \[ \]' "$file")
    local new_line
    new_line=$(echo "$task_line" | sed "s/^\- \[ \]/- [→]/" | sed "s/$/ | started: $(now_iso)/")

    # 用 python 做精确的第一行替换（避免 sed 对特殊字符的问题）
    python3 -c "
import sys
content = open('$file', 'r').read()
old = '''$task_line'''
new = '''$new_line'''
content = content.replace(old, new, 1)
open('$file', 'w').write(content)
" 2>/dev/null || {
        # fallback: sed
        sed -i '' "0,/^\- \[ \]/s/^\- \[ \]/- [→]/" "$file"
    }
    echo "OK: 任务已标记为进行中"
}

cmd_done() {
    local project="${1:?}"
    local commit="${2:-}"
    local file
    file=$(queue_file "$project")
    [ -f "$file" ] || return 1

    local commit_info=""
    [ -n "$commit" ] && commit_info=" | commit: ${commit}"

    # 把第一个 [→] 改为 [x]（用 python 处理 UTF-8 安全）
    if grep -q '^\- \[→\]' "$file"; then
        local done_time
        done_time=$(now_iso)
        python3 << PYEOF
import sys
f = "$file"
done_info = " | done: ${done_time}${commit_info}"
content = open(f).read()
content = content.replace("- [→]", "- [x]", 1)
lines = content.split("\n")
for i, line in enumerate(lines):
    if "- [x]" in line and "done:" not in line and "started:" in line:
        lines[i] = line + done_info
        break
open(f, "w").write("\n".join(lines))
PYEOF
        # 自动同步 prd-todo: 如果队列任务关键词匹配 prd-todo 中的未完成项，标记为 ✅
        sync_prd_todo "$project" "$file"
        
        echo "OK: 任务已完成"
    else
        return 1
    fi
}

# 队列任务完成后，检查 prd-todo.md 是否有对应项可以标记完成
sync_prd_todo() {
    local project="$1" queue_file="$2"
    
    # 找到项目目录
    local project_dir=""
    local conf="$HOME/.autopilot/watchdog-projects.conf"
    if [ -f "$conf" ]; then
        while IFS=: read -r w d _rest; do
            local w_safe
            w_safe=$(sanitize "$w")
            if [ "$w_safe" = "$project" ]; then
                project_dir="$d"
                break
            fi
        done < <(grep -v '^#' "$conf" | grep -v '^$')
    fi
    [ -n "$project_dir" ] || return 0
    
    local prd_todo="${project_dir}/prd-todo.md"
    [ -f "$prd_todo" ] || return 0
    
    # 提取刚完成的任务描述（最近的 [x] 行）
    local done_task
    done_task=$(grep -m1 '^\- \[x\].*done:' "$queue_file" | tail -1 | sed 's/^- \[x\] //; s/ | added:.*$//')
    [ -n "$done_task" ] || return 0
    
    # 提取关键词（取前 3 个非停用词）
    local keywords
    keywords=$(echo "$done_task" | tr '：:，, ' '\n' | grep -v '^$' | head -3)
    
    # 在 prd-todo 中搜索匹配的未完成项
    local matched=false
    while IFS= read -r kw; do
        [ -n "$kw" ] || continue
        # 检查 prd-todo 中是否有包含该关键词的未完成行
        if grep -q "^- .*${kw}" "$prd_todo" 2>/dev/null && \
           grep "^- .*${kw}" "$prd_todo" | grep -qv '✅' 2>/dev/null; then
            matched=true
            break
        fi
    done <<< "$keywords"
    
    if $matched; then
        echo "INFO: prd-todo.md 中可能有对应项可标记完成，需人工确认"
    fi
}

cmd_fail() {
    local project="${1:?}"
    local reason="${2:-unknown}"
    local file
    file=$(queue_file "$project")
    [ -f "$file" ] || return 1

    if grep -q '^\- \[→\]' "$file"; then
        # 提取任务描述（在改标记之前）
        local task_desc
        task_desc=$(grep -m1 '^\- \[→\]' "$file" | sed 's/^- \[→\] //; s/ | added:.*$//')
        # 改为 [!] 标记失败（python 处理 UTF-8）
        python3 << PYEOF
f = "$file"
content = open(f).read()
content = content.replace("- [→]", "- [!]", 1)
open(f, "w").write(content)
PYEOF
        echo "- [ ] ${task_desc} (retry) | added: $(now_iso)" >> "$file"
        echo "OK: 任务已标记失败并重新入队"
    else
        return 1
    fi
}

cmd_count() {
    local project="${1:?}"
    local file
    file=$(queue_file "$project")
    [ -f "$file" ] || { echo 0; return; }
    grep -c '^\- \[ \]' "$file" 2>/dev/null || echo 0
}

cmd_summary() {
    local total=0
    for f in "${QUEUE_DIR}"/*.md; do
        [ -f "$f" ] || continue
        local proj
        proj=$(basename "$f" .md)
        local count
        count=$(grep -c '^\- \[ \]' "$f" 2>/dev/null || true)
        count=$(echo "$count" | tr -dc '0-9'); count=${count:-0}
        local in_progress
        in_progress=$(grep -c '^\- \[→\]' "$f" 2>/dev/null || true)
        in_progress=$(echo "$in_progress" | tr -dc '0-9'); in_progress=${in_progress:-0}
        if [ "$count" -gt 0 ] || [ "$in_progress" -gt 0 ]; then
            echo "${proj}: ${count} 待办, ${in_progress} 进行中"
            total=$((total + count + in_progress))
        fi
    done
    if [ "$total" -eq 0 ]; then echo "(所有队列为空)"; fi
}

# ---- 主入口 ----
ACTION="${1:-help}"
shift || true

case "$ACTION" in
    add)     cmd_add "$@" ;;
    list)    cmd_list "$@" ;;
    next)    cmd_next "$@" ;;
    start)   cmd_start "$@" ;;
    done)    cmd_done "$@" ;;
    fail)    cmd_fail "$@" ;;
    count)   cmd_count "$@" ;;
    summary) cmd_summary ;;
    *)       echo "用法: task-queue.sh {add|list|next|start|done|fail|count|summary} [args...]" ;;
esac
