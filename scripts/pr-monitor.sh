#!/bin/bash
# PR Monitor - Lightweight check for new reviews/comments on our OpenClaw PRs
# Called by cron. Outputs changes or "NO_CHANGES".
# Uses batch GraphQL to minimize API calls.
set -euo pipefail

REPO="openclaw/openclaw"
SELF_USER="imwyvern"
STATE_FILE="$HOME/clawd/scripts/.pr-state.json"

[ -f "$STATE_FILE" ] || echo '{"last_check":"2026-01-01T00:00:00Z"}' > "$STATE_FILE"

LAST_CHECK=$(python3 -c "
import json
with open('$STATE_FILE') as f:
    print(json.load(f).get('last_check','2026-01-01T00:00:00Z'))
")
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Single API call: get all our PRs with latest review/comment timestamps
RESULT=$(gh api graphql -f query='
query {
  search(query: "repo:openclaw/openclaw author:imwyvern is:pr", type: ISSUE, first: 30) {
    nodes {
      ... on PullRequest {
        number
        title
        state
        mergedAt
        closedAt
        reviews(last: 5) {
          nodes { author { login } state submittedAt }
        }
        comments(last: 5) {
          nodes { author { login } createdAt }
        }
        reviewThreads(last: 10) {
          nodes {
            comments(last: 1) {
              nodes { author { login } createdAt }
            }
          }
        }
      }
    }
  }
}' 2>/dev/null) || { echo "NO_CHANGES"; exit 0; }

# Process with Python
OUTPUT=$(python3 -c "
import json, sys

result = json.loads('''$RESULT''')
last_check = '$LAST_CHECK'
nodes = result.get('data',{}).get('search',{}).get('nodes',[])

changes = []
for pr in nodes:
    num = pr.get('number')
    title = pr.get('title','?')[:60]
    state = pr.get('state','')

    # Check for merged/closed since last check
    if state == 'MERGED' and (pr.get('mergedAt','') or '') > last_check:
        changes.append(f'✅ #{num} MERGED: {title}')
        continue
    if state == 'CLOSED' and (pr.get('closedAt','') or '') > last_check:
        changes.append(f'❌ #{num} CLOSED: {title}')
        continue

    if state != 'OPEN':
        continue

    # Check reviews
    new_reviews = []
    for r in pr.get('reviews',{}).get('nodes',[]):
        login = (r.get('author') or {}).get('login','')
        if login == '$SELF_USER' or '[bot]' in login:
            continue
        if (r.get('submittedAt','') or '') > last_check:
            new_reviews.append(f\"{login}: {r.get('state','')}\")

    # Check issue comments
    new_comments = 0
    for c in pr.get('comments',{}).get('nodes',[]):
        login = (c.get('author') or {}).get('login','')
        if login == '$SELF_USER' or '[bot]' in login:
            continue
        if (c.get('createdAt','') or '') > last_check:
            new_comments += 1

    # Check review thread comments
    for thread in pr.get('reviewThreads',{}).get('nodes',[]):
        for c in thread.get('comments',{}).get('nodes',[]):
            login = (c.get('author') or {}).get('login','')
            if login == '$SELF_USER' or '[bot]' in login:
                continue
            if (c.get('createdAt','') or '') > last_check:
                new_comments += 1

    if new_reviews or new_comments > 0:
        parts = [f'🔔 #{num} ({title})']
        if new_reviews:
            parts.append('Reviews: ' + ', '.join(new_reviews))
        if new_comments > 0:
            parts.append(f'{new_comments} new comments')
        changes.append(' — '.join(parts))

if changes:
    print('\n'.join(changes))
else:
    print('NO_CHANGES')
" 2>/dev/null) || { echo "NO_CHANGES"; exit 0; }

# Update state
python3 -c "
import json
with open('$STATE_FILE','r') as f: d=json.load(f)
d['last_check']='$NOW'
with open('$STATE_FILE','w') as f: json.dump(d,f,indent=2)
"

echo "$OUTPUT"
