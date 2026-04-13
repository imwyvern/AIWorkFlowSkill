#!/bin/bash
# Track MediaClaw Codex PRD completion progress
# Runs every 5 minutes, checks commits and status, logs to file

TARGET="autopilot:mediaclaw-2"
LOG="/tmp/mediaclaw-codex-progress.log"
BACKEND="/Users/wes/projects/mediaclaw/server/project/aitoearn-backend"
DISCORD_CHANNEL="1487875303597670582"  # #mediaclaw > 开发

echo "[$(date)] Starting MediaClaw Codex tracker" >> "$LOG"

while true; do
    # Capture current status
    STATUS=$(tmux capture-pane -t "$TARGET" -p 2>/dev/null | tail -5)
    
    # Check if idle (prompt visible, no "Working")
    if echo "$STATUS" | grep -q "^›"; then
        if ! echo "$STATUS" | grep -q "Working"; then
            # Codex is idle - check what it accomplished
            cd "$BACKEND" 2>/dev/null
            RECENT_COMMITS=$(git log --oneline --since="1 hour ago" 2>/dev/null | head -10)
            TOTAL_TODAY=$(git log --oneline --since="12 hours ago" 2>/dev/null | wc -l | tr -d ' ')
            
            echo "[$(date)] Codex IDLE. Commits in last 12h: $TOTAL_TODAY" >> "$LOG"
            echo "$RECENT_COMMITS" >> "$LOG"
            
            # Check remaining quota from status line
            QUOTA=$(echo "$STATUS" | grep -oE '[0-9]+% left' | head -1)
            echo "[$(date)] Quota: $QUOTA" >> "$LOG"
            
            echo "[$(date)] Codex finished or paused. Check $LOG for details." >> "$LOG"
            exit 0
        fi
    fi
    
    # Log periodic progress
    cd "$BACKEND" 2>/dev/null
    COMMITS_NOW=$(git log --oneline --since="1 hour ago" 2>/dev/null | wc -l | tr -d ' ')
    echo "[$(date)] Working... Commits this hour: $COMMITS_NOW" >> "$LOG"
    
    sleep 300  # Check every 5 minutes
done
