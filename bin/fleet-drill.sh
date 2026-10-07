#!/bin/bash
# fleet drill invite [--ttl <2h|90m|7200>] [--login drill<x>] [--host <machine>] [--json]
# fleet drill approve <USER-CODE>       (the approve code in FLEET_DRILL_INVITE)
#   — mint a DRILL PERSON on the hub for one onboarding drill (claude-fleet#2010,
#     EPIC #1906 C16): the stand-in colleague bin/fleet-onboard-drill.sh confirms
#     its scan as, so the drill walks a NEW person's first time instead of being
#     confirmed as you (the #1901 run became "your second computer").
#
# Prints the one-time approve code, its expiry and the drill command to run:
#
#   fleet-onboard-drill.sh --login <login> --invite <code>
#
# The drill person (kind=drill) lives --ttl (default 2h, 5m…24h) and is deleted
# with its device and node when that runs out — or sooner, by the drill's own
# --teardown (DELETE /v1/self). It borrows no credential, gets no session pass,
# sees only its own sessions. Its login is the drill's throwaway OS login on
# --host (default: this machine), `drill` + up to 11 lowercase letters/digits
# (default drill<MMDDHHMM>).
#
# `approve` is the drill's scan (bin/fleet-onboard-drill.sh --invite): it
# confirms the pending login under USER-CODE (the 验证码 on the QR screen) as
# the drill person, POST /fleet/login/approve {code, approve_code} — no
# browser, no session, no token, no certificate: the code is the whole
# credential and it binds the login to the DRILL person, never to whoever is
# signed in anywhere. The code comes from the environment, never an argv.
#
# Who may invite: an admin. Asked with YOUR connection certificate (~/.ssh/fleet-cert,
# FLEET_CERT) signing the request; with no live certificate, the operator's
# token (CCQUOTA_VIEWER_TOKEN, ~/.ccquota/viewer-token). The code is printed,
# never written to a file.
#
# Exit: 0 invited / approved · 1 the hub refused / did not answer · 2 usage / no hub / no credential
set -u
PROG=fleet-drill
usage() { sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
note() { printf '%s: %s\n' "$PROG" "$*" >&2; }

SUB=${1-}
case "$SUB" in
  invite|approve) shift ;;
  -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
  *) usage ;;
esac
TTL='' LOGIN='' HOST='' JSON=0 UCODE=''
if [ "$SUB" = approve ]; then
  [ $# = 1 ] || usage
  UCODE=$(printf '%s' "$1" | tr 'a-z' 'A-Z'); set --
  printf '%s' "$UCODE" | grep -Eq '^[A-Z]{4}-[A-Z]{4}$' || { note "approve: the 验证码 looks like ABCD-EFGH (got '$UCODE')"; exit 2; }
  printf '%s' "${FLEET_DRILL_INVITE:-}" | grep -Eq '^fd_[a-z2-7]{26}$' \
    || { note 'approve: FLEET_DRILL_INVITE holds no approve code (fd_… from fleet drill invite)'; exit 2; }
fi
while [ $# -gt 0 ]; do
  case "$1" in
    --ttl)   [ $# -ge 2 ] || usage; TTL=$2; shift 2 ;;
    --login) [ $# -ge 2 ] || usage; LOGIN=$2; shift 2 ;;
    --host)  [ $# -ge 2 ] || usage; HOST=$2; shift 2 ;;
    --json)  JSON=1; shift ;;
    *)       note "unknown argument: $1"; usage ;;
  esac
done

# --ttl → seconds (0 = the hub's default)
TTLS=0
if [ -n "$TTL" ]; then
  case "$TTL" in
    *[!0-9hms]*|'') note "--ttl: a number of seconds, or 90m / 2h (got '$TTL')"; exit 2 ;;
    *h) TTLS=$(( ${TTL%h} * 3600 )) ;;
    *m) TTLS=$(( ${TTL%m} * 60 )) ;;
    *s) TTLS=${TTL%s} ;;
    *)  TTLS=$TTL ;;
  esac
fi
if [ -n "$LOGIN" ] && ! printf '%s' "$LOGIN" | grep -Eq '^drill[a-z0-9]{1,11}$'; then
  note "--login: drill + 1-11 lowercase letters or digits (got '$LOGIN')"; exit 2
fi
[ -n "$HOST" ] || HOST=$(hostname -s 2>/dev/null || hostname)

hub_url() {
  local u="${CCQUOTA_HUB_URL:-${FLEET_HUB_URL:-}}"
  if [ -z "$u" ]; then
    u=$(sed -n 's/^export FLEET_HUB_URL="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/fleet.conf" 2>/dev/null | head -n 1)
  fi
  if [ -z "$u" ]; then
    u=$(python3 -c 'import json,sys
try: print(str(json.load(open(sys.argv[1])).get("url") or ""))
except Exception: pass' "${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet/hub.json" 2>/dev/null)
  fi
  case "$u" in http://*|https://*) printf '%s' "${u%/}" ;; *) return 1 ;; esac
}
HUB=$(hub_url) || { note "no hub (FLEET_HUB_URL in fleet.conf, CCQUOTA_HUB_URL)"; exit 2; }

CERT_KEY="${FLEET_CERT:-$HOME/.ssh/fleet-cert}"; CERT_PUB="$CERT_KEY-cert.pub"
cert_live() {
  [ -f "$CERT_KEY" ] && [ -f "$CERT_PUB" ] || return 1
  ssh-keygen -L -f "$CERT_PUB" 2>/dev/null | python3 -c '
import sys, time
for line in sys.stdin:
    w = line.split()
    if line.strip().startswith("Valid:") and "forever" not in line and len(w) >= 5:
        sys.exit(0 if time.strftime("%Y-%m-%dT%H:%M:%S") < w[4] else 1)
sys.exit(0)'
}

OUT=$(mktemp "${TMPDIR:-/tmp}/fleet-drill.XXXXXX") || exit 1
trap 'rm -f "$OUT"' EXIT
if [ "$SUB" = approve ]; then
  # the code is the only credential sent: no cookie, no token, no certificate
  code=$(printf '{"code":"%s","approve_code":"%s"}' "$UCODE" "$FLEET_DRILL_INVITE" | curl -sS -m 20 -o "$OUT" -w '%{http_code}' \
         -X POST -H 'Content-Type: application/json' --data-binary @- "$HUB/fleet/login/approve" 2>/dev/null)
  cat "$OUT"; echo
  case "$code" in
    200) exit 0 ;;
    '')  note "the hub did not answer ($HUB)"; exit 1 ;;
    *)   note "the hub refused the approve code (HTTP $code)"; exit 1 ;;
  esac
fi
if cert_live; then
  ts=$(date +%s)
  sig=$(printf 'fleet-drill %s invite %s %s %s' "$ts" "$HOST" "$LOGIN" "$TTLS" \
        | ssh-keygen -Y sign -f "$CERT_KEY" -n fleet-drill@claude-fleet 2>/dev/null) \
    || { note "ssh-keygen -Y sign failed with $CERT_KEY"; exit 1; }
  body=$(python3 -c 'import json,sys; print(json.dumps({"host":sys.argv[1],"login":sys.argv[2],"ttl_seconds":int(sys.argv[3]),"cert":open(sys.argv[4]).readline().strip(),"sig":sys.argv[5],"ts":int(sys.argv[6])}))' \
         "$HOST" "$LOGIN" "$TTLS" "$CERT_PUB" "$sig" "$ts") || exit 1
  code=$(printf '%s' "$body" | curl -sS -m 30 -o "$OUT" -w '%{http_code}' -X POST \
         -H 'Content-Type: application/json' --data-binary @- "$HUB/v1/admin/drill" 2>/dev/null)
else
  TOK="${CCQUOTA_VIEWER_TOKEN:-}"
  [ -n "$TOK" ] || { [ -r "$HOME/.ccquota/viewer-token" ] && read -r TOK < "$HOME/.ccquota/viewer-token"; } || TOK=''
  [ -n "$TOK" ] || { note "no live connection certificate ($CERT_PUB — run fleet login) and no operator token — nothing sent"; exit 2; }
  body=$(python3 -c 'import json,sys; print(json.dumps({"host":sys.argv[1],"login":sys.argv[2],"ttl_seconds":int(sys.argv[3])}))' "$HOST" "$LOGIN" "$TTLS") || exit 1
  # the token rides a header read from stdin's sibling: never an argv
  code=$(printf 'Authorization: Bearer %s\n' "$TOK" | curl -sS -m 30 -o "$OUT" -w '%{http_code}' -X POST \
         -H @- -H 'Content-Type: application/json' --data-binary "$body" "$HUB/v1/admin/drill" 2>/dev/null)
fi
case "$code" in
  200) ;;
  '') note "the hub did not answer ($HUB)"; exit 1 ;;
  *)  note "the hub refused (HTTP $code): $(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("error",""))
except Exception: print(open(sys.argv[1]).read()[:200])' "$OUT" 2>/dev/null)"; exit 1 ;;
esac
if [ "$JSON" = 1 ]; then cat "$OUT"; echo; exit 0; fi
python3 - "$OUT" "$(cd "$(dirname "$0")" && pwd)" <<'PY'
import json, sys, datetime
d = json.load(open(sys.argv[1]))
exp = datetime.datetime.fromisoformat(d["expires_at"].replace("Z", "+00:00")).astimezone()
print("演练同事  %s（kind=%s）· 登录名 %s @ %s" % (d["person_id"], d["kind"], d["login"], d["host"]))
print("确认码    %s  （只能用一次）" % d["approve_code"])
print("到期      %s（到期入口自动删除这个人、设备和节点）" % exp.strftime("%m-%d %H:%M"))
print()
print("下一步：  %s/fleet-onboard-drill.sh --login %s --invite %s" % (sys.argv[2], d["login"], d["approve_code"]))
PY
