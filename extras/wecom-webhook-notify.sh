#!/bin/sh
# wecom-webhook-notify.sh "<message>" — send a text message via a WeCom 群机器人
# webhook (https://developer.work.weixin.qq.com/document/path/99110).
# Point FLEET_NOTIFY_CMD at this script and put the webhook URL in
# ~/.config/claude-fleet-webhook (chmod 600) or env WECOM_WEBHOOK.
# Works as-is for Slack-style webhooks too with a payload tweak.
set -u  # POSIX sh: pipefail is bash-only (dash has none)
msg="${1:-}"; [ -z "$msg" ] && exit 0
HOOK="${WECOM_WEBHOOK:-$(cat "$HOME/.config/claude-fleet-webhook" 2>/dev/null)}"
[ -z "$HOOK" ] && exit 0
# markdown msgtype: renders **bold** / # headings / <font color="warning"> when the
# caller passes them; plain text passes through unchanged.
payload=$(python3 -c 'import json,sys;print(json.dumps({"msgtype":"markdown","markdown":{"content":sys.argv[1]}}))' "$msg")
exec curl -sS -m 8 -H 'Content-Type: application/json' --data "$payload" "$HOOK" >/dev/null 2>&1
