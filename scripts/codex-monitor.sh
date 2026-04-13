#!/bin/bash
# Monitor Codex task completion by checking rollout file modification times
# If a file hasn't been modified in 10+ minutes, consider the task done.

TASK1="/Users/wes/.codex/sessions/2026/01/25/rollout-2026-01-25T22-08-01-019bf8ea-93bc-7172-8d19-c6c6addf6a3c.jsonl"
TASK2="/Users/wes/.codex/sessions/2026/02/03/rollout-2026-02-03T09-05-27-019c2477-58a7-72f1-ac71-0e84507e5ed7.jsonl"
STATE="/tmp/codex-monitor-state.json"

now=$(date +%s)

# Get file mod times
t1_mod=$(stat -f %m "$TASK1" 2>/dev/null || echo 0)
t2_mod=$(stat -f %m "$TASK2" 2>/dev/null || echo 0)

t1_age=$(( now - t1_mod ))
t2_age=$(( now - t2_mod ))

# Threshold: 10 minutes = 600 seconds
THRESHOLD=600

# Read previous state
t1_notified="false"
t2_notified="false"
if [ -f "$STATE" ]; then
    t1_notified=$(python3 -c "import json; d=json.load(open('$STATE')); print(d.get('t1_notified','false'))" 2>/dev/null || echo "false")
    t2_notified=$(python3 -c "import json; d=json.load(open('$STATE')); print(d.get('t2_notified','false'))" 2>/dev/null || echo "false")
fi

result=""

if [ "$t1_age" -gt "$THRESHOLD" ] && [ "$t1_notified" = "false" ]; then
    result="${result}任务1（SoulKeyboard百万词库）已停止活动 ${t1_age} 秒，可能已完成。\n"
    t1_notified="true"
fi

if [ "$t2_age" -gt "$THRESHOLD" ] && [ "$t2_notified" = "false" ]; then
    result="${result}任务2（Agent SimCity/ClawCity）已停止活动 ${t2_age} 秒，可能已完成。\n"
    t2_notified="true"
fi

# If task resumed (file updated again), reset notification
if [ "$t1_age" -lt "$THRESHOLD" ]; then
    t1_notified="false"
fi
if [ "$t2_age" -lt "$THRESHOLD" ]; then
    t2_notified="false"
fi

# Save state
python3 -c "import json; json.dump({'t1_notified':'$t1_notified','t2_notified':'$t2_notified','t1_age':$t1_age,'t2_age':$t2_age}, open('$STATE','w'))"

# Output status
if [ -n "$result" ]; then
    echo -e "$result"
else
    echo "STILL_RUNNING t1_age=${t1_age}s t2_age=${t2_age}s"
fi
