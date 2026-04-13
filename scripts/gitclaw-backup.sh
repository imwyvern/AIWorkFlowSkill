#!/bin/bash
# GitClaw: Auto-backup OpenClaw workspace to GitHub
set -e

BACKUP_DIR="$HOME/.openclaw/workspace-backup"
SOURCE_DIR="$HOME/clawd"

cd "$BACKUP_DIR"

# Sync files
cp "$SOURCE_DIR/SOUL.md" "$SOURCE_DIR/AGENTS.md" "$SOURCE_DIR/IDENTITY.md" \
   "$SOURCE_DIR/USER.md" "$SOURCE_DIR/TOOLS.md" "$SOURCE_DIR/MEMORY.md" \
   "$SOURCE_DIR/HEARTBEAT.md" . 2>/dev/null || true

# Sync memory
mkdir -p memory
rsync -a --delete "$SOURCE_DIR/memory/" memory/ 2>/dev/null || true

# Skills inventory
ls "$HOME/.openclaw/skills/" > skills-inventory.txt 2>/dev/null || true

# Check for changes
if git diff --quiet && git diff --cached --quiet; then
  echo "No changes to backup"
  exit 0
fi

# Commit and push
git add -A
CHANGES=$(git diff --cached --stat | tail -1)
git commit -m "chore: auto-backup $(date +%Y-%m-%d) — $CHANGES"
git push origin main 2>&1
echo "✅ Backup pushed at $(date)"
