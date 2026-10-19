#!/bin/bash
# bin-inventory: 人工入口 — 管理员设每人可用机器，docs/public/*/admin/machines.md
# fleet-machine-policy.sh — which machines a person may use (issue #3824): the
# hub's per-person machine allowlist.
#
#   fleet-machine-policy.sh show [<principal>] [--json]   every list (with a principal: each machine, open or not)
#   fleet-machine-policy.sh set   <principal> <machine>…  only these machines
#   fleet-machine-policy.sh all   <principal>             every machine, said explicitly
#   fleet-machine-policy.sh deny  <principal>             no machine at all ([])
#   fleet-machine-policy.sh clear <principal>             no list: every machine (the default)
#
# <principal> is a principal ID such as gh:2987262; <machine> the name a machine
# joined as (its first label: mac-b, mac-e, linux-a). A machine off the
# list keeps the person's login, home and history — it just cannot be used:
# no route / certificate login / relay / entry key there, no placement there
# (auto or named), no credential lease and no session pass there (a session
# already open stops at its pass's next check, within ~30 s), and its sessions
# read 已停用（管理员限制）. `clear` (or `all`) puts it back as it was.
# docs/dev/SHARED-MACHINE.md «机器白名单».
#
# Who may: the operator — a viewer token in CCQUOTA_VIEWER_TOKEN, read from the
# ENVIRONMENT only, handed to curl on stdin (`-H @-`), never in an argv.
# The hub: CCQUOTA_HUB_URL, else FLEET_HUB_URL (fleet.conf), else node.env's.
#
# Exit status: 0 done · 1 the hub could not be asked (no token / URL /
# unreachable; nothing changed) · 2 usage · 4 the hub refused (not the
# operator, a bad principal or machine name, or a hub that predates #3824).
#
# Seams: FLEET_HUB_CURL (default `curl`) is the transport, for the selftest.
set -uo pipefail

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=fleet-lib.sh
. "$BIN/fleet-lib.sh"

die() { printf 'fleet-machine-policy: %s\n' "$2" >&2; exit "$1"; }
usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; }

[ $# -gt 0 ] || { usage >&2; die 2 'say show, set, all, deny or clear'; }
ACTION=$1; shift
JSON='' PRINCIPAL=''
NAMES=()
case "$ACTION" in
  show)
    while [ $# -gt 0 ]; do
      case "$1" in
        --json) JSON=1; shift ;;
        -*) die 2 "show: unknown option '$1'" ;;
        *) [ -z "$PRINCIPAL" ] || die 2 'show [<principal>] [--json]'; PRINCIPAL=$1; shift ;;
      esac
    done ;;
  set|all|deny|clear)
    [ $# -ge 1 ] || die 2 "$ACTION <principal>…"
    PRINCIPAL=$1; shift
    if [ "$ACTION" = set ]; then
      [ $# -ge 1 ] || die 2 'set needs at least one machine (deny for none)'
      NAMES=("$@")
    else
      [ $# -eq 0 ] || die 2 "$ACTION takes no machine names"
    fi ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; die 2 "unknown action '$ACTION'" ;;
esac

MACHINE_POLICY_PATH=/v1/fleet/machine-policy
CURL=${FLEET_HUB_CURL:-curl}
TIMEOUT=${FLEET_HUB_TIMEOUT:-15}
_TOK=${CCQUOTA_VIEWER_TOKEN:-}
[ -n "$_TOK" ] || die 1 "no CCQUOTA_VIEWER_TOKEN — the operator's call reads the hub's viewer token from the environment (never from a file)"
_URL=${CCQUOTA_HUB_URL:-${FLEET_HUB_URL:-}}
[ -n "$_URL" ] || _URL=$(_fleet_node_env_val CCQUOTA_HUB_URL 2>/dev/null)
[ -n "$_URL" ] || die 1 "no hub URL — set CCQUOTA_HUB_URL (or FLEET_HUB_URL in fleet.conf)"
_URL=${_URL%/}

# _call <method> <path> [<body>] — the hub's answer as "<json>\n<code>".
_call() {
  local method=$1 pth=$2 body=${3:-}
  if [ -n "$body" ]; then
    printf 'Authorization: Bearer %s\n' "$_TOK" | "$CURL" -sS --max-time "$TIMEOUT" -o - -w '\n%{http_code}' \
      -H @- -H 'Content-Type: application/json' -X "$method" --data-binary "$body" "$_URL$pth" 2>/dev/null
  else
    printf 'Authorization: Bearer %s\n' "$_TOK" | "$CURL" -sS --max-time "$TIMEOUT" -o - -w '\n%{http_code}' \
      -H @- "$_URL$pth" 2>/dev/null
  fi
}

_answer() {
  local resp=$1 rc=$2 code json
  [ "$rc" -eq 0 ] && [ -n "$resp" ] || die 1 "hub unreachable ($_URL): curl exit $rc — nothing changed"
  code=$(printf '%s\n' "$resp" | tail -n 1)
  json=$(printf '%s\n' "$resp" | sed '$d')
  case "$code" in
    200) printf '%s' "$json" ;;
    400) die 4 "the hub refused it (400): $(printf '%s' "$json" | head -c 300)" ;;
    401|403) die 4 "the hub says this is not the operator ($code) — CCQUOTA_VIEWER_TOKEN must be the hub's viewer token" ;;
    404|405) die 4 "the hub has no $MACHINE_POLICY_PATH ($code) — it predates issue #3824; redeploy it" ;;
    *) die 4 "hub answered HTTP $code: $(printf '%s' "$json" | head -c 300)" ;;
  esac
}

case "$ACTION" in
  set|all|deny|clear)
    body=$(python3 -c '
import json, sys
act, who, names = sys.argv[1], sys.argv[2], sys.argv[3:]
body = {"principal": who, "allow": names if act == "set" else ([] if act == "deny" else None)}
if act == "all": body["all"] = True
print(json.dumps(body))
' "$ACTION" "$PRINCIPAL" ${NAMES[@]+"${NAMES[@]}"})
    resp=$(_call PUT "$MACHINE_POLICY_PATH" "$body"); rc=$?
    json=$(_answer "$resp" "$rc") || exit $?
    printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
a = d.get("allow")
what = "every machine (explicit)" if d.get("all") else "no list — every machine" if a is None else ("no machine at all" if a == [] else " ".join(a))
print("machine-policy: SET %s: %s" % (sys.argv[1], what))
' "$PRINCIPAL" || exit 4
    exit 0 ;;
  show)
    q=''
    [ -z "$PRINCIPAL" ] || q="?$(python3 -c 'import sys, urllib.parse as u; print(u.urlencode({"principal": sys.argv[1]}))' "$PRINCIPAL")"
    resp=$(_call GET "$MACHINE_POLICY_PATH$q"); rc=$?
    json=$(_answer "$resp" "$rc") || exit $?
    [ -z "$JSON" ] || { printf '%s\n' "$json"; exit 0; }
    printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
want = sys.argv[1]
n = 0
for u in d.get("users") or []:
    if want and u["principal"] != want:
        continue
    n += 1
    if u.get("error"):
        print("machine-policy: %s MALFORMED (no machine): %s" % (u["principal"], u["error"]))
    else:
        print("machine-policy: %s %s" % (u["principal"], "(every machine)" if u.get("all") else (" ".join(u.get("allow") or []) or "(no machine)")))
if not n:
    print("machine-policy: %s" % ("no list for %s — every machine" % want if want else "no lists — everyone may use every machine"))
e = d.get("effective") or {}
for m in e.get("machines") or []:
    print("  %-5s %s%s" % ("OPEN" if m.get("allowed") else "OFF", m["machine"], "" if m.get("allowed") else " — " + m.get("reason", "")))
' "$PRINCIPAL" || exit 4
    exit 0 ;;
esac
