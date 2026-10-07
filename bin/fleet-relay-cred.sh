#!/bin/bash
# fleet-relay-cred.sh — this machine's pass for the Singapore relay (issue
# #1974, EPIC #1967 C7).
#
#   fleet-relay-cred.sh fetch [--force]     mint this login's relay credential (kept 0600)
#   fleet-relay-cred.sh check               ask the hub whether the kept one still passes
#   fleet-relay-cred.sh path                where it is kept
#   fleet-relay-cred.sh revoke <machine>    the operator drops every one of a machine's
#   fleet-relay-cred.sh status [<machine>]  the operator lists who holds one
#
# What it is: a trusted machine that cannot reach the upstream directly sends
# its sessions through the relay (docs/CRED-RELAY.md). The relay holds no
# subscription credential; it lets a request through only when the hub's
# GET /v1/relay/check accepts the pass in its X-Fleet-Relay header — this
# credential (`frl1.…`), minted per machine and login by
# POST /v1/node/relay-credential for a TRUSTED machine only, and dropped by the
# operator (`revoke`), by marking the machine untrusted, or by revoking the
# machine's credentials. The hub keeps only its hash.
#
# Where it lives: $FLEET_CONF_DIR/cred-proxy/relay.token (0600, the directory
# 0700) — read by the machine's own proxy (fleet-cred-proxy, C3) and nothing
# else. Never in a config, an argv, a log or the environment of a session.
#
# Who may:
#   fetch / check     this login's node token (node.env, read inside the one
#                     subshell that calls the hub, never exported: issue #1491)
#   revoke / status   the operator: CCQUOTA_VIEWER_TOKEN from the ENVIRONMENT only
#
# The hub: CCQUOTA_HUB_URL, else FLEET_HUB_URL (fleet.conf), else node.env's.
#
# Exit status:
#   0   done (fetch: ISSUED or KEPT; check: OK)
#   1   the hub could not be asked: no token, no hub URL, unreachable
#   2   usage
#   3   check: the hub refused the kept pass (or none is kept) — `fetch --force`
#   4   the hub refused the call: untrusted / revoked / no account (fetch),
#       not the operator (revoke / status), or a hub that predates #1974
#   10  fetch / check with the hub module off (CCQUOTA_FLEET≠1): nothing asked
#
# Output, one line on stdout:
#   relay: ISSUED m4/alice → <path>    relay: KEPT m4 (passes)
#   relay: OK m4                       relay: REFUSED <why>
#   relay: REVOKED m4                  relay: m4 alice bob
#
# Seams: FLEET_HUB_CURL (default `curl`) is the transport, for the selftest.
set -uo pipefail

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=fleet-lib.sh
. "$BIN/fleet-lib.sh"

die() { printf 'fleet-relay-cred: %s\n' "$2" >&2; exit "$1"; }
usage() { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; }

ACTION='' MACHINE='' FORCE=0
[ $# -gt 0 ] || { usage >&2; die 2 'say fetch, check, path, revoke or status'; }
case "$1" in
  fetch)
    case "${2:-}" in ''|--force) [ "${2:-}" = --force ] && FORCE=1 ;; *) die 2 "fetch takes only --force" ;; esac
    [ $# -le 2 ] || die 2 'fetch [--force]'
    ACTION=fetch ;;
  check|path)
    [ $# -eq 1 ] || die 2 "$1 takes no argument"
    ACTION=$1 ;;
  revoke)
    [ $# -eq 2 ] || die 2 'revoke <machine>'
    ACTION=revoke MACHINE=$2 ;;
  status)
    [ $# -le 2 ] || die 2 'status [<machine>]'
    ACTION=status MACHINE=${2:-} ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; die 2 "unknown action '$1'" ;;
esac
if [ -n "$MACHINE" ]; then
  printf '%s' "$MACHINE" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$' || die 2 "'$MACHINE' is not a machine name"
  MACHINE=$(printf '%s' "$MACHINE" | tr 'A-Z' 'a-z' | cut -d. -f1)
fi

CURL=${FLEET_HUB_CURL:-curl}
TIMEOUT=${FLEET_HUB_TIMEOUT:-15}
DIR="$FLEET_CONF_DIR/cred-proxy"
FILE="$DIR/relay.token"

# _sep_push — separated (#1971): the proxy runs as the role account and reads its
# OWN state dir; hand it the pass this login keeps. Quiet, best effort.
_sep_push() {
  [ -f "$FLEET_CONF_DIR/credsep.json" ] && [ -s "$FILE" ] || return 0
  bash "$(dirname "$0")/fleet-cred-proxy.sh" relay < "$FILE" >/dev/null 2>&1 || true
}

if [ "$ACTION" = path ]; then
  printf '%s\n' "$FILE"
  exit 0
fi

# _call <method> <path> [<body>] — "<json>\n<code>". The bearer goes to curl
# on stdin, never in its argv.
_call() {
  local method=$1 pth=$2 body=${3:-}
  if [ -n "$body" ]; then
    printf 'Authorization: Bearer %s\n' "$_TOK" | "$CURL" -sS --max-time "$TIMEOUT" -o - -w '\n%{http_code}' \
      -H @- -H 'Content-Type: application/json' -X "$method" --data-binary "$body" "$_URL$pth" 2>/dev/null
  else
    printf 'Authorization: Bearer %s\n' "$_TOK" | "$CURL" -sS --max-time "$TIMEOUT" -o - -w '\n%{http_code}' \
      -H @- -X "$method" "$_URL$pth" 2>/dev/null
  fi
}

# _check_kept — the hub's verdict on the kept pass: "<json>\n<code>". The pass
# goes to curl on stdin, never in its argv.
_check_kept() {
  { printf 'X-Fleet-Relay: '; cat "$FILE"; printf '\nX-Forwarded-Uri: /anthropic/v1/messages\n'; } |
    "$CURL" -sS --max-time "$TIMEOUT" -o - -w '\n%{http_code}' -H @- "$_URL/v1/relay/check" 2>/dev/null
}

_msg() { printf '%s' "$1" | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: d={}
print((d.get("message") or d.get("error") or "")[:300])' 2>/dev/null; }

if [ "$ACTION" = fetch ] || [ "$ACTION" = check ]; then
  if [ "${CCQUOTA_FLEET:-0}" != 1 ]; then
    printf 'fleet-relay-cred: the hub module is off (CCQUOTA_FLEET≠1) — no hub, nothing asked\n' >&2
    exit 10
  fi
  _URL=${CCQUOTA_HUB_URL:-${FLEET_HUB_URL:-}}
  [ -n "$_URL" ] || _URL=$(_fleet_node_env_val CCQUOTA_HUB_URL 2>/dev/null)
  [ -n "$_URL" ] || die 1 "no hub URL — set CCQUOTA_HUB_URL (or FLEET_HUB_URL in fleet.conf)"
  _URL=${_URL%/}

  # check (and fetch without --force): does the kept pass still pass?
  if [ "$ACTION" = check ] || { [ "$FORCE" = 0 ] && [ -s "$FILE" ]; }; then
    if [ -s "$FILE" ]; then
      resp=$(_check_kept); rc=$?
      [ "$rc" -eq 0 ] && [ -n "$resp" ] || die 1 "hub unreachable ($_URL): curl exit $rc"
      code=$(printf '%s\n' "$resp" | tail -n 1)
      case "$code" in
        200)
          if [ "$ACTION" = check ]; then printf 'relay: OK %s\n' "$(hostname -s | tr A-Z a-z)"
          else _sep_push; printf 'relay: KEPT %s (passes)\n' "$(hostname -s | tr A-Z a-z)"; fi
          exit 0 ;;
        403)
          [ "$ACTION" = check ] && { printf 'relay: REFUSED %s\n' "$(_msg "$(printf '%s\n' "$resp" | sed '$d')")"; exit 3; } ;;
        404|405) die 4 "the hub has no relay check ($code) — it predates issue #1974; redeploy it" ;;
        *) die 1 "the hub answered HTTP $code to the check" ;;
      esac
    elif [ "$ACTION" = check ]; then
      printf 'relay: REFUSED no pass kept at %s — run: fleet-relay-cred.sh fetch\n' "$FILE"
      exit 3
    fi
  fi

  # fetch: mint a new one (replaces this login's old one on the hub).
  if why=$(_fleet_hub_creds_missing); then
    die 1 "$why"
  fi
  # One subshell: the node token enters its environment and dies with it (#1491).
  resp=$(_fleet_hub_env; _TOK=$CCQUOTA_TOKEN _URL=${CCQUOTA_HUB_URL%/}; _call POST /v1/node/relay-credential); rc=$?
  [ "$rc" -eq 0 ] && [ -n "$resp" ] || die 1 "hub unreachable ($_URL): curl exit $rc — nothing changed"
  code=$(printf '%s\n' "$resp" | tail -n 1)
  json=$(printf '%s\n' "$resp" | sed '$d')
  case "$code" in
    200) ;;
    401) die 4 "the hub does not know this node's token (401)" ;;
    403) die 4 "the hub refused: $(_msg "$json")" ;;
    404|405) die 4 "the hub has no relay credentials ($code) — it predates issue #1974; redeploy it" ;;
    *) die 4 "hub answered HTTP $code: $(_msg "$json")" ;;
  esac
  ( umask 077; mkdir -p "$DIR" ) || die 1 "cannot make $DIR"
  chmod 700 "$DIR" 2>/dev/null
  tmp="$DIR/.relay.token.$$"
  line=$(printf '%s' "$json" | ( umask 077; python3 -c '
import json, sys
d = json.load(sys.stdin)
tok = d.get("token") or ""
if not tok.startswith("frl1."):
    sys.exit(4)
with open(sys.argv[1], "w") as f:
    f.write(tok)
print("%s/%s" % (d.get("machine") or "?", d.get("login") or "?"))
' "$tmp" )) || { rm -f "$tmp"; die 4 "the hub answered without a relay credential — it predates issue #1974"; }
  chmod 600 "$tmp" && mv -f "$tmp" "$FILE" || { rm -f "$tmp"; die 1 "cannot write $FILE"; }
  _sep_push
  printf 'relay: ISSUED %s → %s\n' "$line" "$FILE"
  exit 0
fi

# revoke / status: the operator's.
_TOK=${CCQUOTA_VIEWER_TOKEN:-}
[ -n "$_TOK" ] || die 1 "no CCQUOTA_VIEWER_TOKEN — the operator's call reads the hub's viewer token from the environment (never from a file)"
_URL=${CCQUOTA_HUB_URL:-${FLEET_HUB_URL:-}}
[ -n "$_URL" ] || _URL=$(_fleet_node_env_val CCQUOTA_HUB_URL 2>/dev/null)
[ -n "$_URL" ] || die 1 "no hub URL — set CCQUOTA_HUB_URL (or FLEET_HUB_URL in fleet.conf)"
_URL=${_URL%/}

_answer() {
  local resp=$1 rc=$2 code json
  [ "$rc" -eq 0 ] && [ -n "$resp" ] || die 1 "hub unreachable ($_URL): curl exit $rc — nothing changed"
  code=$(printf '%s\n' "$resp" | tail -n 1)
  json=$(printf '%s\n' "$resp" | sed '$d')
  case "$code" in
    200) printf '%s' "$json" ;;
    400) die 4 "the hub refused it (400): $(_msg "$json") — does it predate issue #1974?" ;;
    401|403) die 4 "the hub says this is not the operator ($code) — CCQUOTA_VIEWER_TOKEN must be the hub's viewer token" ;;
    404|405) die 4 "the hub has no such route ($code) — is the hub module on (CCQUOTA_FLEET=1)?" ;;
    *) die 4 "hub answered HTTP $code: $(_msg "$json")" ;;
  esac
}

if [ "$ACTION" = revoke ]; then
  resp=$(_call PUT /v1/fleet/settings "$(printf '{"key":"fleet.node_relay.%s","value":""}' "$MACHINE")"); rc=$?
  _answer "$resp" "$rc" >/dev/null || exit $?
  printf 'relay: REVOKED %s\n' "$MACHINE"
  exit 0
fi

resp=$(_call GET /v1/fleet/settings); rc=$?
settings=$(_answer "$resp" "$rc") || exit $?
printf '%s' "$settings" | python3 -c '
import json, sys
want = sys.argv[1]
pre = "fleet.node_relay."
rows = {}
for k, v in ((json.load(sys.stdin).get("settings") or {}).items()):
    if k.startswith(pre) and v:
        rows[k[len(pre):]] = " ".join(w.split(":")[0] for w in v.split())
if want:
    rows = {want: rows.get(want, "-")}
if not rows:
    print("relay: (no machine holds a relay credential)")
for m in sorted(rows):
    print("relay: %s %s" % (m, rows[m]))
' "$MACHINE"
