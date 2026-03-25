#!/usr/bin/env bash
# review-agent.sh — Visual review agent for frontend commits
# Takes Playwright headless screenshots, saves pending review for OpenClaw
# session to process (no separate API key needed).
#
# Usage:
#   review-agent.sh <project_dir> <window_name> [commit_hash]
#
# Exit codes:
#   0  = Screenshots captured (review pending) or skipped
#   2  = ERROR (screenshot failure)
#   3  = SKIP (no URL configured / not a frontend project)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=autopilot-constants.sh
source "${SCRIPT_DIR}/autopilot-constants.sh" 2>/dev/null || true
# shellcheck source=autopilot-lib.sh
source "${SCRIPT_DIR}/autopilot-lib.sh" 2>/dev/null || true

PROJECT_DIR="${1:?Usage: review-agent.sh <project_dir> <window_name> [commit_hash]}"
WINDOW="${2:?Usage: review-agent.sh <project_dir> <window_name> [commit_hash]}"
COMMIT="${3:-HEAD}"

SAFE=$(basename "$PROJECT_DIR" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')
LOG_DIR="${HOME}/.autopilot/logs"
LOG="${LOG_DIR}/review-agent-${SAFE}.log"
SCREENSHOT_DIR="${HOME}/.autopilot/review-screenshots/${SAFE}"
STATE_DIR="${HOME}/.autopilot/state"
COOLDOWN_FILE="${STATE_DIR}/review-agent-cooldown-${SAFE}"
REPORT_DIR="${HOME}/.autopilot/review-reports"

mkdir -p "$LOG_DIR" "$SCREENSHOT_DIR" "$REPORT_DIR" "$STATE_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# ── Cooldown: 5 min between reviews for same project ──
COOLDOWN_SECONDS=300
if [ -f "$COOLDOWN_FILE" ]; then
    last_run=$(cat "$COOLDOWN_FILE" 2>/dev/null || echo 0)
    now=$(date +%s)
    elapsed=$((now - last_run))
    if [ "$elapsed" -lt "$COOLDOWN_SECONDS" ]; then
        log "⏭ Skipping review — cooldown (${elapsed}s < ${COOLDOWN_SECONDS}s)"
        exit 0
    fi
fi

# ── Step 1: Check if commit touches frontend files ──
FRONTEND_EXTENSIONS="\.vue$|\.tsx$|\.jsx$|\.html$|\.css$|\.scss$|\.less$|\.svelte$"
COMMIT_HASH=$(git -C "$PROJECT_DIR" rev-parse "${COMMIT}" 2>/dev/null || echo "")
[ -n "$COMMIT_HASH" ] || { log "❌ Cannot resolve commit ${COMMIT}"; exit 2; }

CHANGED_FILES=$(git -C "$PROJECT_DIR" diff --name-only "${COMMIT_HASH}^..${COMMIT_HASH}" 2>/dev/null || echo "")
FRONTEND_FILES=$(echo "$CHANGED_FILES" | grep -E "$FRONTEND_EXTENSIONS" || true)

if [ -z "$FRONTEND_FILES" ]; then
    log "⏭ No frontend files in commit ${COMMIT_HASH:0:7}, skipping visual review"
    exit 0
fi

FRONTEND_COUNT=$(echo "$FRONTEND_FILES" | wc -l | tr -d ' ')
TOTAL_LINES=$(git -C "$PROJECT_DIR" diff --stat "${COMMIT_HASH}^..${COMMIT_HASH}" 2>/dev/null | tail -1 | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo "0")

if [ "$TOTAL_LINES" -lt 10 ]; then
    log "⏭ Only ${TOTAL_LINES} lines changed, below threshold (10), skipping"
    exit 0
fi

log "🔍 Visual review triggered: ${FRONTEND_COUNT} frontend files, ${TOTAL_LINES} lines changed"
log "   Files: $(echo "$FRONTEND_FILES" | tr '\n' ' ')"

# ── Step 2: Determine project URL and pages to screenshot ──
get_project_url() {
    case "$1" in
        youxin-demo)           echo "http://localhost:3200" ;;
        shike)                 echo "http://localhost:5192" ;;
        replyher_android-2|replyher-android-2) echo "https://replyher.com" ;;
        soulkeyboard-wechat)   echo "https://replyher.com" ;;
        *)                     echo "" ;;
    esac
}

get_project_pages() {
    case "$1" in
        youxin-demo)           echo "/ /write /send /me /safe-card" ;;
        shike)                 echo "/ /#/pages/login/login" ;;
        replyher_android-2|replyher-android-2) echo "/ /zh-CN/privacy.html" ;;
        soulkeyboard-wechat)   echo "/" ;;
        *)                     echo "" ;;
    esac
}

BASE_URL=$(get_project_url "$SAFE")
PAGES=$(get_project_pages "$SAFE")

if [ -z "$BASE_URL" ]; then
    log "⏭ No URL configured for project ${SAFE}, skipping visual review"
    exit 3
fi

# Verify URL is reachable
if ! curl -sI --connect-timeout 5 --max-time 10 "$BASE_URL" > /dev/null 2>&1; then
    log "⚠️ URL not reachable: ${BASE_URL}, skipping"
    exit 2
fi

log "📸 Taking screenshots from ${BASE_URL}"

# ── Step 3: Take screenshots with Playwright ──
PLAYWRIGHT_IMPORT="/opt/homebrew/Cellar/node/25.3.0/lib/node_modules/playwright/index.mjs"
SCREENSHOT_SCRIPT=$(mktemp /tmp/review-screenshot-XXXXXX.mjs)
cat > "$SCREENSHOT_SCRIPT" << JSEOF
import { chromium } from '${PLAYWRIGHT_IMPORT}';

const baseUrl = process.argv[2];
const pages = process.argv[3].split(' ').filter(Boolean);
const outDir = process.argv[4];
const device = { width: 390, height: 844 }; // iPhone 14 Pro

(async () => {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    viewport: device,
    deviceScaleFactor: 2,
    isMobile: true,
    userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15'
  });

  const results = [];
  for (const path of pages) {
    const url = baseUrl + path;
    const safeName = path.replace(/\//g, '_').replace(/^_/, '') || 'home';
    const outPath = outDir + '/' + safeName + '.png';
    try {
      const page = await context.newPage();
      await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 10000 });
      await page.waitForTimeout(3000);
      await page.screenshot({ path: outPath, fullPage: true });
      await page.close();
      results.push({ path, file: outPath, status: 'ok' });
    } catch (e) {
      results.push({ path, file: null, status: 'error', error: e.message });
    }
  }

  await browser.close();
  console.log(JSON.stringify(results));
})();
JSEOF

SCREENSHOT_RESULTS=$(node "$SCREENSHOT_SCRIPT" "$BASE_URL" "$PAGES" "$SCREENSHOT_DIR" 2>>"$LOG" || echo "[]")
rm -f "$SCREENSHOT_SCRIPT"

# Count successful screenshots
SCREENSHOT_COUNT=$(echo "$SCREENSHOT_RESULTS" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
print(sum(1 for r in data if r.get('status') == 'ok'))
" 2>/dev/null || echo "0")

if [ "$SCREENSHOT_COUNT" -eq 0 ]; then
    log "❌ No screenshots captured, cannot review"
    exit 2
fi

log "📸 Captured ${SCREENSHOT_COUNT} screenshots"

# ── Step 4: Get task description ──
COMMIT_MSG=$(git -C "$PROJECT_DIR" log -1 --format="%B" "$COMMIT_HASH" 2>/dev/null || echo "")
DIFF_STAT=$(git -C "$PROJECT_DIR" diff --stat "${COMMIT_HASH}^..${COMMIT_HASH}" 2>/dev/null | head -20 || echo "")

# Try queue for richer task description
QUEUE_FILE="${HOME}/.autopilot/task-queue/${SAFE}.md"
TASK_DESC=""
if [ -f "$QUEUE_FILE" ]; then
    TASK_DESC=$(grep -B1 '^\- \[x\]' "$QUEUE_FILE" 2>/dev/null | tail -2 | head -1 || true)
fi
[ -z "$TASK_DESC" ] && TASK_DESC="$COMMIT_MSG"

log "📝 Task description: ${TASK_DESC:0:200}"

# ── Step 5: Save pending review for OpenClaw session ──
REVIEW_REQUEST="${REPORT_DIR}/${SAFE}-${COMMIT_HASH:0:7}-pending.json"
python3 - "$SAFE" "$COMMIT_HASH" "$SCREENSHOT_DIR" "$TASK_DESC" "$DIFF_STAT" "$FRONTEND_FILES" "$WINDOW" "$REVIEW_REQUEST" << 'PYEOF'
import sys, json, glob, os
safe, commit, ss_dir, task, diff, files, window, out = sys.argv[1:9]
screenshots = sorted(glob.glob(os.path.join(ss_dir, "*.png")))
json.dump({
    "project": safe,
    "commit": commit[:7],
    "window": window,
    "screenshots": screenshots,
    "screenshot_dir": ss_dir,
    "task_description": task[:2000],
    "diff_stat": diff[:1000],
    "frontend_files": files[:1000],
    "status": "pending",
    "created_at": __import__('datetime').datetime.now().isoformat()
}, open(out, 'w'), indent=2)
print("OK")
PYEOF

log "📋 Review request saved: ${REVIEW_REQUEST}"

# Notify Discord
if [ -x "${SCRIPT_DIR}/discord-notify.sh" ]; then
    discord_channel=$(get_discord_channel_for_window "$WINDOW" 2>/dev/null || true)
    [ -n "$discord_channel" ] && \
        "${SCRIPT_DIR}/discord-notify.sh" "$discord_channel" \
            "👁 review-agent: ${SCREENSHOT_COUNT}张截图已拍 — ${SAFE} ${COMMIT_HASH:0:7}，Claude 审查中..." \
            >/dev/null 2>&1 || true
fi

# Save report template
REPORT="${REPORT_DIR}/${SAFE}-${COMMIT_HASH:0:7}.md"
cat > "$REPORT" << EOF
# Visual Review — Pending
- **Project:** ${SAFE}
- **Commit:** ${COMMIT_HASH:0:7}
- **Time:** $(date '+%Y-%m-%d %H:%M:%S')
- **Screenshots:** ${SCREENSHOT_DIR}/ (${SCREENSHOT_COUNT} pages)
- **Frontend files (${FRONTEND_COUNT}):**
$(echo "$FRONTEND_FILES" | sed 's/^/  - /')

## Task Description
${TASK_DESC:0:1000}

## Diff Stat
${DIFF_STAT}
EOF

# Update cooldown
date +%s > "$COOLDOWN_FILE"

log "✅ Screenshots captured, review pending OpenClaw processing"
exit 0
