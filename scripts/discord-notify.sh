#!/usr/bin/env bash
# discord-notify.sh — 自动推送开发动态到 Discord 对应频道
# Usage: discord-notify.sh <channel> <message>
set -euo pipefail

CHANNEL_NAME="${1:-}"
MSG="${2:-}"

if [[ -z "$CHANNEL_NAME" || -z "$MSG" ]]; then
  echo "Usage: $0 <channel> <message>" >&2
  exit 1
fi

BOT_TOKEN=$(
  python3 - "$HOME/.openclaw/openclaw.json" 2>/dev/null <<'PY' || true
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    token = data.get("channels", {}).get("discord", {}).get("token", "")
    if isinstance(token, str):
        print(token.strip())
except Exception:
    pass
PY
)

if [[ -z "$BOT_TOKEN" ]]; then
  echo "ERROR: failed to load Discord bot token from $HOME/.openclaw/openclaw.json" >&2
  exit 1
fi

case "$CHANNEL_NAME" in
  gonggao|公告)     CHANNEL_ID="1473294121878687837" ;;
  ribao|日报)       CHANNEL_ID="1473294128799416443" ;;
  chat|闲聊)        CHANNEL_ID="1473294135116169238" ;;
  agent-log)        CHANNEL_ID="1473294141843705877" ;;
  code-review)      CHANNEL_ID="1473294148126769364" ;;
  job-feed)         CHANNEL_ID="1473294154850369650" ;;
  applications)     CHANNEL_ID="1473294162240471284" ;;
  shike)            CHANNEL_ID="1473294169203150941" ;;
  replyher)         CHANNEL_ID="1473294176128077888" ;;
  simcity)          CHANNEL_ID="1473294182905938013" ;;
  autopilot)        CHANNEL_ID="1473294190094848133" ;;
  conduit)          CHANNEL_ID="1473294196717912310" ;;
  research)         CHANNEL_ID="1473294203596443690" ;;
  incidents)        CHANNEL_ID="1473294209682378815" ;;
  resources)        CHANNEL_ID="1473294216875479123" ;;
  *)
    echo "Unknown channel: $CHANNEL_NAME" >&2
    exit 1 ;;
esac

MSG_TRUNCATED="${MSG:0:1990}"

curl -s -X POST \
  -H "Authorization: Bot $BOT_TOKEN" \
  -H "Content-Type: application/json" \
  "https://discord.com/api/v10/channels/$CHANNEL_ID/messages" \
  -d "$(jq -n --arg content "$MSG_TRUNCATED" '{content: $content}')" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id','ERR'))" 2>/dev/null
