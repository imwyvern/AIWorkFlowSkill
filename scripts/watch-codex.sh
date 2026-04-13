#!/bin/bash
# watch-codex.sh — Monitor a tmux Codex session for idle state
# Usage: watch-codex.sh <tmux-target> [max-minutes]
# Checks every 30s, exits when Codex is idle (not Working/Inspecting/Running)

TARGET="${1:?Usage: watch-codex.sh <tmux-target> [max-minutes]}"
MAX_MIN="${2:-120}"
ELAPSED=0

while [ $ELAPSED -lt $((MAX_MIN * 60)) ]; do
  pane=$(tmux capture-pane -t "$TARGET" -p 2>/dev/null | tail -10)
  
  # Check if Codex is actively working
  if echo "$pane" | grep -qE "Working|Inspecting|Ran |Read |Explored|Waiting for background"; then
    sleep 30
    ELAPSED=$((ELAPSED + 30))
    continue
  fi
  
  # Check if stuck on approval prompt
  if echo "$pane" | grep -qE "Would you like to run|Yes, proceed|Press enter to confirm"; then
    echo "APPROVAL_NEEDED at $(date)"
    echo "$pane"
    exit 2
  fi
  
  # Codex appears idle
  if echo "$pane" | grep -qE "› |? for shortcuts|context left"; then
    echo "IDLE at $(date)"
    echo "$pane"
    exit 0
  fi
  
  sleep 30
  ELAPSED=$((ELAPSED + 30))
done

echo "TIMEOUT after ${MAX_MIN}min at $(date)"
exit 1
