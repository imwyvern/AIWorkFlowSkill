#!/bin/bash
# Poll tmux codex session for task completion, notify Discord when done
# Usage: poll-codex-done.sh <tmux-target> <discord-channel> <task-description>

TMUX_TARGET="${1:-autopilot:2.0}"
DISCORD_CHANNEL="${2:-1473294176128077888}"
TASK_DESC="${3:-Codex 任务}"

# Capture tmux pane
OUTPUT=$(tmux capture-pane -p -J -t "$TMUX_TARGET" -S -3 2>/dev/null)

# Check if codex is idle (showing prompt, not "thinking/running")
if echo "$OUTPUT" | grep -q '^\$ $\|^› \|^wes@.*%\s*$'; then
  # Codex is idle - check if there's a review report
  if [ -f /tmp/replyher-full-review.md ]; then
    # Task done - notify via openclaw
    openclaw message discord send --channel "$DISCORD_CHANNEL" --message "✅ $TASK_DESC 已完成！报告已写入 /tmp/replyher-full-review.md"
    # Remove this cron job
    crontab -l 2>/dev/null | grep -v "poll-codex-done" | crontab -
    exit 0
  fi
fi
