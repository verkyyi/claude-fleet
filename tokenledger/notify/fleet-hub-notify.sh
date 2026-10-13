#!/bin/sh
# fleet-hub-notify "<message>" — the hub's FLEET_NOTIFY_CMD (claude-fleet#4086).
#
# The hub runs `<FLEET_NOTIFY_CMD> "<message>"` with no shell (svc_degraded,
# claude-fleet#4007). Its image is alpine: no python3, no curl — the node's
# extras/wecom-webhook-notify.sh cannot run there. This one needs only busybox
# (sh, sed, wget) and ships in the image as /usr/local/bin/fleet-hub-notify.
#
# Where it goes: FLEET_NOTIFY_WEBHOOK, read from the environment only (the
# overlay takes it from a Secret key — never written in a manifest). The host
# picks the body:
#   qyapi.weixin.qq.com        WeCom group robot   {"msgtype":"markdown",…}
#   open.feishu.cn / larksuite Feishu / Lark robot {"msg_type":"text",…}
#   api.day.app                Bark (the phone)    {"title":"fleet","body":…}
#   anything else              {"text":…}          (Slack-style)
# No webhook, or no message ⇒ exit 0, nothing sent. Never prints the address.
#
# Exit: 0 sent / nothing to do · 1 the send failed (the hub logs it).
set -u
msg=${1:-}
hook=${FLEET_NOTIFY_WEBHOOK:-}
[ -n "$msg" ] && [ -n "$hook" ] || exit 0
case "$hook" in
  https://*) ;;
  *) echo "fleet-hub-notify: FLEET_NOTIFY_WEBHOOK is not https:// — not sent" >&2; exit 1 ;;
esac

# one JSON string: \ and " escaped, newlines and tabs as \n \t
js=$(printf '%s' "$msg" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g' | sed -e ':a' -e '$!N' -e '$!ba' -e 's/\n/\\n/g')
host=${hook#https://}; host=${host%%/*}
case "$host" in
  qyapi.weixin.qq.com) body="{\"msgtype\":\"markdown\",\"markdown\":{\"content\":\"$js\"}}" ;;
  open.feishu.cn|open.larksuite.com) body="{\"msg_type\":\"text\",\"content\":{\"text\":\"$js\"}}" ;;
  api.day.app) body="{\"title\":\"fleet\",\"body\":\"$js\",\"group\":\"fleet\"}" ;;
  *) body="{\"text\":\"$js\"}" ;;
esac
if wget -q -T 10 -O /dev/null --header 'Content-Type: application/json; charset=utf-8' \
    --post-data "$body" "$hook" 2>/dev/null; then
  exit 0
fi
echo "fleet-hub-notify: the webhook at $host did not take it" >&2
exit 1
