#!/usr/bin/env bash
# review-agent.sh — Visual review agent for frontend commits
# Compares headless browser screenshots against task/commit description
# using Claude vision API to detect "builds but doesn't work" issues.
#
# Usage:
#   review-agent.sh <project_dir> <window_name> [commit_hash]
#
# Exit codes:
#   0  = PASS (or skipped — no frontend files changed)
#   1  = FAIL (visual review found issues)
#   2  = ERROR (screenshot/API failure)
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
# Project URL + pages mapping (bash 3.x compatible)
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
# Use npx playwright to take screenshots
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
      // Wait extra for animations/renders
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

SCREENSHOT_RESULTS=$(npx playwright test --version > /dev/null 2>&1 && node "$SCREENSHOT_SCRIPT" "$BASE_URL" "$PAGES" "$SCREENSHOT_DIR" 2>>"$LOG" || echo "[]")
rm -f "$SCREENSHOT_SCRIPT"

# Fallback: if playwright not available, use curl-based basic check
if [ "$SCREENSHOT_RESULTS" = "[]" ] || [ -z "$SCREENSHOT_RESULTS" ]; then
    log "⚠️ Playwright screenshot failed, trying fallback..."

    # Check if we have playwright installed
    if ! command -v npx >/dev/null 2>&1 || ! npx playwright --version >/dev/null 2>&1; then
        log "❌ Playwright not installed. Install with: npx playwright install chromium"
        
        # Fallback: use OpenClaw browser tool via CLI
        # Generate a simple check script that OpenClaw can run
        FALLBACK_REPORT="${REPORT_DIR}/${SAFE}-${COMMIT_HASH:0:7}-fallback.md"
        cat > "$FALLBACK_REPORT" << EOF
# Review Agent Fallback Report
- Project: ${SAFE}
- Commit: ${COMMIT_HASH:0:7}
- Frontend files: ${FRONTEND_COUNT}
- Lines changed: ${TOTAL_LINES}
- Status: NEEDS_MANUAL_REVIEW (Playwright not available)
- Files changed:
$(echo "$FRONTEND_FILES" | sed 's/^/  - /')
EOF
        log "📋 Fallback report written to ${FALLBACK_REPORT}"
        exit 2
    fi

    # Retry with explicit chromium
    npx playwright install chromium >> "$LOG" 2>&1 || true
    SCREENSHOT_RESULTS=$(node "$SCREENSHOT_SCRIPT" "$BASE_URL" "$PAGES" "$SCREENSHOT_DIR" 2>>"$LOG" || echo "[]")
fi

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

# ── Step 4: Get task description (from queue or commit message) ──
COMMIT_MSG=$(git -C "$PROJECT_DIR" log -1 --format="%B" "$COMMIT_HASH" 2>/dev/null || echo "")

# Try to get original task description from queue
QUEUE_FILE="${HOME}/.autopilot/task-queue/${SAFE}.md"
TASK_DESC=""
if [ -f "$QUEUE_FILE" ]; then
    # Get the most recently completed task
    TASK_DESC=$(grep -B1 '^\- \[x\]' "$QUEUE_FILE" 2>/dev/null | tail -2 | head -1 || true)
fi

# Fallback to commit message
[ -z "$TASK_DESC" ] && TASK_DESC="$COMMIT_MSG"

# Get recent diff summary for context
DIFF_STAT=$(git -C "$PROJECT_DIR" diff --stat "${COMMIT_HASH}^..${COMMIT_HASH}" 2>/dev/null | head -20 || echo "")

log "📝 Task description: ${TASK_DESC:0:200}"

# ── Step 5: Send to Claude Vision API for review ──
# Build the API request using python3 (handles base64 encoding + JSON assembly)
API_PAYLOAD_FILE=$(mktemp /tmp/review-payload-XXXXXX.json)

python3 - "$SCREENSHOT_DIR" "$TASK_DESC" "$DIFF_STAT" "$FRONTEND_FILES" "$API_PAYLOAD_FILE" << 'PYEOF'
import sys, json, base64, glob, os

screenshot_dir = sys.argv[1]
task_desc = sys.argv[2][:2000]
diff_stat = sys.argv[3][:1000]
frontend_files = sys.argv[4][:1000]
out_file = sys.argv[5]

pngs = sorted(glob.glob(os.path.join(screenshot_dir, "*.png")))
if not pngs:
    print("NO_SCREENSHOTS")
    sys.exit(1)

prompt = f"""You are a frontend visual QA reviewer. Compare these screenshots against the task description and code changes.

## Task Description
{task_desc}

## Code Changes (diff stat)
{diff_stat}

## Changed Files
{frontend_files}

## Screenshots
The following screenshots are from the live site (mobile viewport 390x844).

For each page, evaluate:
1. Does the visual output match what the code/task intended?
2. Are there blank/empty areas that should have content?
3. Are elements visually broken, overlapping, or invisible?
4. Are colors/fonts/spacing consistent with the design system?
5. Are interactive states (loading/empty/error) handled?

Respond in this exact JSON format:
```json
{{
  "verdict": "PASS" or "FAIL",
  "score": 0-100,
  "pages": [
    {{
      "path": "/page",
      "status": "PASS" or "FAIL",
      "issues": ["issue description"]
    }}
  ],
  "summary": "one-line summary",
  "fix_suggestions": ["actionable fix 1", "fix 2"]
}}
```"""

content = [{"type": "text", "text": prompt}]
for png_path in pngs:
    page_name = os.path.basename(png_path).replace(".png", "")
    with open(png_path, "rb") as f:
        b64 = base64.b64encode(f.read()).decode()
    content.append({"type": "text", "text": f"Page: /{page_name}"})
    content.append({
        "type": "image",
        "source": {"type": "base64", "media_type": "image/png", "data": b64}
    })

payload = {
    "model": "claude-sonnet-4-20250514",
    "max_tokens": 2000,
    "messages": [{"role": "user", "content": content}]
}

with open(out_file, "w") as f:
    json.dump(payload, f)

print(f"OK:{len(pngs)}")
PYEOF

PAYLOAD_STATUS=$?
if [ "$PAYLOAD_STATUS" -ne 0 ]; then
    log "❌ Failed to build API payload"
    rm -f "$API_PAYLOAD_FILE"
    exit 2
fi

# Call Claude API
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
if [ -z "$ANTHROPIC_API_KEY" ]; then
    # Try to read from zshrc / env files (launchd doesn't source shell rc)
    ANTHROPIC_API_KEY=$(grep -s '^export ANTHROPIC_API_KEY=' "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.env" 2>/dev/null | head -1 | sed 's/^export //' | sed 's/^ANTHROPIC_API_KEY=//' | tr -d '"'"'" || true)
fi

if [ -z "$ANTHROPIC_API_KEY" ]; then
    log "⚠️ No ANTHROPIC_API_KEY, trying OpenClaw gateway proxy..."
    # Try OpenClaw gateway as anthropic proxy (it has its own API keys)
    OPENCLAW_API_URL="http://localhost:4080"
    if curl -s --connect-timeout 3 "${OPENCLAW_API_URL}/health" > /dev/null 2>&1; then
        USE_OPENCLAW_PROXY=true
    else
        log "⚠️ OpenClaw gateway not available either, saving for manual review"
        REVIEW_REQUEST="${REPORT_DIR}/${SAFE}-${COMMIT_HASH:0:7}-request.json"
        echo "{\"project\":\"${SAFE}\",\"commit\":\"${COMMIT_HASH:0:7}\",\"screenshots\":\"${SCREENSHOT_DIR}\",\"task\":$(echo "$TASK_DESC" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')}" > "$REVIEW_REQUEST"
        log "📋 Review request saved: ${REVIEW_REQUEST}"
        OPENCLAW_REVIEW=true
    fi
fi

REVIEW_RESULT=""

# Strategy: try direct API first, fallback to OpenClaw cron trigger
if [ "${OPENCLAW_REVIEW:-false}" = "false" ] && [ -n "$ANTHROPIC_API_KEY" ]; then
    log "🤖 Sending screenshots to Claude Vision (direct API)..."
    
    API_RESPONSE=$(curl -s --max-time 120 \
        https://api.anthropic.com/v1/messages \
        -H "Content-Type: application/json" \
        -H "x-api-key: ${ANTHROPIC_API_KEY}" \
        -H "anthropic-version: 2023-06-01" \
        -d @"$API_PAYLOAD_FILE" 2>>"$LOG")
    
    # Extract the text response
    REVIEW_RESULT=$(echo "$API_RESPONSE" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    if 'error' in data:
        print(f'ERROR: {data[\"error\"].get(\"message\", str(data[\"error\"]))}')
    else:
        for block in data.get('content', []):
            if block.get('type') == 'text':
                print(block['text'])
                break
except Exception as e:
    print(f'ERROR: {e}')
" 2>/dev/null || echo "ERROR: Failed to parse API response")

    # If API key invalid, fall through to OpenClaw
    if echo "$REVIEW_RESULT" | grep -q "invalid x-api-key\|authentication_error"; then
        log "⚠️ Anthropic API key invalid, falling back to OpenClaw cron review"
        REVIEW_RESULT=""
    fi
fi

rm -f "$API_PAYLOAD_FILE"

# Fallback: trigger OpenClaw cron to do vision review via its own model access
if [ -z "$REVIEW_RESULT" ] || echo "$REVIEW_RESULT" | grep -q "^ERROR:"; then
    log "🤖 Triggering OpenClaw cron for vision review..."
    
    # Write review request with all context
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
    
    # Trigger OpenClaw cron to process the review
    if command -v openclaw >/dev/null 2>&1; then
        openclaw cron run --task "review-agent-check" 2>>"$LOG" || true
    fi
    
    # Notify Discord that review is pending
    if [ -x "${SCRIPT_DIR}/discord-notify.sh" ]; then
        discord_channel=$(get_discord_channel_for_window "$WINDOW" 2>/dev/null || true)
        [ -n "$discord_channel" ] && \
            "${SCRIPT_DIR}/discord-notify.sh" "$discord_channel" \
                "👁 Visual review 截图完成 (${SCREENSHOT_COUNT}张) — ${SAFE} ${COMMIT_HASH:0:7}，等待 Claude 审查..." \
                >/dev/null 2>&1 || true
    fi
    
    log "📋 Review request saved: ${REVIEW_REQUEST}"
    log "📸 Screenshots: ${SCREENSHOT_DIR}/"
    
    # Update cooldown  
    date +%s > "$COOLDOWN_FILE"
    exit 0  # Not a failure — review is deferred to OpenClaw
fi

# ── Step 6: Parse result and take action ──
if [ -z "$REVIEW_RESULT" ] || echo "$REVIEW_RESULT" | grep -q "^ERROR:"; then
    log "⚠️ Vision API failed: ${REVIEW_RESULT:-empty response}"
    # Save screenshots for manual review
    REPORT="${REPORT_DIR}/${SAFE}-${COMMIT_HASH:0:7}-manual.md"
    cat > "$REPORT" << EOF
# Visual Review — Manual Required
- **Project:** ${SAFE}
- **Commit:** ${COMMIT_HASH:0:7}
- **Time:** $(date '+%Y-%m-%d %H:%M:%S')
- **Frontend files (${FRONTEND_COUNT}):**
$(echo "$FRONTEND_FILES" | sed 's/^/  - /')
- **Screenshots:** ${SCREENSHOT_DIR}/
- **Task:** ${TASK_DESC:0:500}
- **API Error:** ${REVIEW_RESULT:-no response}
EOF
    log "📋 Manual review report: ${REPORT}"
    exit 2
fi

# Parse JSON verdict
VERDICT=$(echo "$REVIEW_RESULT" | python3 -c "
import json, sys, re
text = sys.stdin.read()
# Extract JSON from markdown code blocks if present
m = re.search(r'\`\`\`json\s*(.*?)\s*\`\`\`', text, re.DOTALL)
if m:
    text = m.group(1)
try:
    data = json.loads(text)
    print(data.get('verdict', 'UNKNOWN'))
except:
    # Try to find verdict in raw text
    if 'PASS' in text.upper():
        print('PASS')
    elif 'FAIL' in text.upper():
        print('FAIL')
    else:
        print('UNKNOWN')
" 2>/dev/null || echo "UNKNOWN")

SCORE=$(echo "$REVIEW_RESULT" | python3 -c "
import json, sys, re
text = sys.stdin.read()
m = re.search(r'\`\`\`json\s*(.*?)\s*\`\`\`', text, re.DOTALL)
if m: text = m.group(1)
try:
    data = json.loads(text)
    print(data.get('score', 0))
except:
    print(0)
" 2>/dev/null || echo "0")

SUMMARY=$(echo "$REVIEW_RESULT" | python3 -c "
import json, sys, re
text = sys.stdin.read()
m = re.search(r'\`\`\`json\s*(.*?)\s*\`\`\`', text, re.DOTALL)
if m: text = m.group(1)
try:
    data = json.loads(text)
    print(data.get('summary', 'No summary'))
except:
    print(text[:200])
" 2>/dev/null || echo "No summary")

# Save full report
REPORT="${REPORT_DIR}/${SAFE}-${COMMIT_HASH:0:7}.md"
cat > "$REPORT" << EOF
# Visual Review Report
- **Project:** ${SAFE}
- **Commit:** ${COMMIT_HASH:0:7}
- **Time:** $(date '+%Y-%m-%d %H:%M:%S')
- **Verdict:** ${VERDICT}
- **Score:** ${SCORE}/100
- **Summary:** ${SUMMARY}
- **Frontend files (${FRONTEND_COUNT}):**
$(echo "$FRONTEND_FILES" | sed 's/^/  - /')

## Full Review
${REVIEW_RESULT}

## Task Description
${TASK_DESC:0:1000}
EOF

log "📋 Review report: ${REPORT}"
log "   Verdict: ${VERDICT} (${SCORE}/100) — ${SUMMARY}"

# Update cooldown
date +%s > "$COOLDOWN_FILE"

# ── Step 7: Act on result ──
if [ "$VERDICT" = "PASS" ]; then
    log "✅ Visual review PASSED (${SCORE}/100)"
    
    # Notify Discord
    if [ -x "${SCRIPT_DIR}/discord-notify.sh" ]; then
        discord_channel=$(get_discord_channel_for_window "$WINDOW" 2>/dev/null || true)
        [ -n "$discord_channel" ] && \
            "${SCRIPT_DIR}/discord-notify.sh" "$discord_channel" \
                "✅ Visual Review PASS (${SCORE}/100) — ${SAFE} ${COMMIT_HASH:0:7}: ${SUMMARY:0:150}" \
                >/dev/null 2>&1 || true
    fi
    exit 0

elif [ "$VERDICT" = "FAIL" ]; then
    log "❌ Visual review FAILED (${SCORE}/100)"
    
    # Extract fix suggestions for auto-enqueue
    FIX_SUGGESTIONS=$(echo "$REVIEW_RESULT" | python3 -c "
import json, sys, re
text = sys.stdin.read()
m = re.search(r'\`\`\`json\s*(.*?)\s*\`\`\`', text, re.DOTALL)
if m: text = m.group(1)
try:
    data = json.loads(text)
    fixes = data.get('fix_suggestions', [])
    for f in fixes[:5]:
        print(f'- {f}')
except:
    print('- Check review report for details')
" 2>/dev/null || echo "- Check review report for details")
    
    # Auto-enqueue fix task (with 1h cooldown to prevent loops)
    FIX_COOLDOWN_FILE="${STATE_DIR}/review-fix-cooldown-${SAFE}"
    should_enqueue=true
    if [ -f "$FIX_COOLDOWN_FILE" ]; then
        last_fix=$(cat "$FIX_COOLDOWN_FILE" 2>/dev/null || echo 0)
        fix_elapsed=$(( $(date +%s) - last_fix ))
        if [ "$fix_elapsed" -lt 3600 ]; then
            should_enqueue=false
            log "⏭ Fix enqueue skipped — cooldown (${fix_elapsed}s < 3600s)"
        fi
    fi
    
    if [ "$should_enqueue" = "true" ] && [ -x "${SCRIPT_DIR}/task-queue.sh" ]; then
        FIX_TASK="[review-agent] 视觉 review 失败 (${SCORE}/100): ${SUMMARY:0:100}。修复要点:\n${FIX_SUGGESTIONS}"
        "${SCRIPT_DIR}/task-queue.sh" add "$SAFE" "$FIX_TASK" high --type frontend 2>/dev/null || true
        date +%s > "$FIX_COOLDOWN_FILE"
        log "📋 Auto-enqueued fix task (high priority, frontend type)"
    fi
    
    # Notify Discord
    if [ -x "${SCRIPT_DIR}/discord-notify.sh" ]; then
        discord_channel=$(get_discord_channel_for_window "$WINDOW" 2>/dev/null || true)
        discord_msg="⚠️ Visual Review FAIL (${SCORE}/100) — ${SAFE} ${COMMIT_HASH:0:7}\n${SUMMARY:0:200}"
        [ "$should_enqueue" = "true" ] && discord_msg="${discord_msg}\n📋 已自动入队修复任务"
        [ -n "$discord_channel" ] && \
            "${SCRIPT_DIR}/discord-notify.sh" "$discord_channel" "$discord_msg" \
                >/dev/null 2>&1 || true
    fi
    
    exit 1
else
    log "⚠️ Review verdict unclear: ${VERDICT}"
    exit 2
fi
