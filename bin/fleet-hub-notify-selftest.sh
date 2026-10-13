#!/bin/bash
# fleet-hub-notify-selftest.sh — the hub image's FLEET_NOTIFY_CMD (issue #4086):
# tokenledger/notify/fleet-hub-notify.sh, driven with a stub `wget` on PATH that
# records its argv. No network.
#
#   A. off       no FLEET_NOTIFY_WEBHOOK, or no message → exit 0, wget never runs
#   B. wecom     qyapi.weixin.qq.com → {"msgtype":"markdown",…}, the message's
#                quotes / backslashes / newlines escaped into one JSON string
#   C. bark      api.day.app → {"title":"fleet","body":…}
#   D. feishu    open.feishu.cn → {"msg_type":"text",…}; anything else {"text":…}
#   E. refuse    an http:// address → exit 1, nothing sent
#   F. failed    wget fails → exit 1, the host named, never the address
#   G. image     the Dockerfile copies it to /usr/local/bin/fleet-hub-notify,
#                and it is executable in git (the COPY keeps the mode)
# Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
N="$ROOT/tokenledger/notify/fleet-hub-notify.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/hub-notify-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
fail=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }

mkdir -p "$WORK/stub"
cat > "$WORK/stub/wget" <<'EOF'
#!/bin/sh
for a in "$@"; do printf '%s\n' "$a"; done > "$STUB_LOG"
[ "${STUB_FAIL:-0}" = 1 ] && exit 1
exit 0
EOF
chmod 755 "$WORK/stub/wget"
export STUB_LOG="$WORK/argv"
run() { rm -f "$STUB_LOG"; PATH="$WORK/stub:$PATH" sh "$N" "$@" 2>"$WORK/err"; }
body() { grep -A1 -x -- '--post-data' "$STUB_LOG" | tail -n 1; }

# A
FLEET_NOTIFY_WEBHOOK= run 'hello'; rc=$?
[ "$rc" = 0 ] && [ ! -e "$STUB_LOG" ] && ok "A no webhook: nothing sent" || bad "A no webhook rc=$rc"
FLEET_NOTIFY_WEBHOOK=https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=k run ''; rc=$?
[ "$rc" = 0 ] && [ ! -e "$STUB_LOG" ] && ok "A no message: nothing sent" || bad "A no message rc=$rc"

# B
msg='svc_degraded svc:livepage: 3 "failed"
code=infra_error \x'
FLEET_NOTIFY_WEBHOOK='https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=k' run "$msg"; rc=$?
want='{"msgtype":"markdown","markdown":{"content":"svc_degraded svc:livepage: 3 \"failed\"\ncode=infra_error \\x"}}'
[ "$rc" = 0 ] && [ "$(body)" = "$want" ] && ok "B wecom body" || bad "B wecom rc=$rc body=$(body)"
grep -qx 'https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=k' "$STUB_LOG" && ok "B posted to the webhook" || bad "B url"
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json,sys; json.loads(sys.argv[1])' "$(body)" && ok "B valid JSON" || bad "B not JSON"
fi

# C
FLEET_NOTIFY_WEBHOOK=https://api.day.app/KEY run 'hi'; rc=$?
[ "$rc" = 0 ] && [ "$(body)" = '{"title":"fleet","body":"hi","group":"fleet"}' ] && ok "C bark body" || bad "C bark $(body)"

# D
FLEET_NOTIFY_WEBHOOK=https://open.feishu.cn/open-apis/bot/v2/hook/x run 'hi'
[ "$(body)" = '{"msg_type":"text","content":{"text":"hi"}}' ] && ok "D feishu body" || bad "D feishu $(body)"
FLEET_NOTIFY_WEBHOOK=https://hooks.example.com/x run 'hi'
[ "$(body)" = '{"text":"hi"}' ] && ok "D generic body" || bad "D generic $(body)"

# E
FLEET_NOTIFY_WEBHOOK=http://hooks.example.com/x run 'hi'; rc=$?
[ "$rc" = 1 ] && [ ! -e "$STUB_LOG" ] && ok "E http refused" || bad "E http rc=$rc"

# F
STUB_FAIL=1 FLEET_NOTIFY_WEBHOOK='https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=SECRETKEY' run 'hi'; rc=$?
if [ "$rc" = 1 ] && grep -q 'qyapi.weixin.qq.com' "$WORK/err" && ! grep -q SECRETKEY "$WORK/err"; then
  ok "F failure: host named, key not"
else bad "F rc=$rc err=$(cat "$WORK/err")"; fi

# G
grep -qx 'COPY notify/fleet-hub-notify.sh /usr/local/bin/fleet-hub-notify' "$ROOT/tokenledger/Dockerfile" \
  && ok "G Dockerfile copies it" || bad "G Dockerfile line missing"
if git -C "$ROOT" ls-files -s tokenledger/notify/fleet-hub-notify.sh 2>/dev/null | grep -q '^100755'; then
  ok "G executable in git"
elif [ -x "$N" ]; then ok "G executable (not a checkout)"; else bad "G not executable"; fi

[ "$fail" = 0 ] && echo "hub-notify selftest: PASS" || echo "hub-notify selftest: FAIL"
exit "$fail"
