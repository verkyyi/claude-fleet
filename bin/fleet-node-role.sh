#!/bin/bash
# fleet-node-role.sh — what each node is: managed or client (issue #4886).
#
#   fleet-node-role.sh plan                       every roster login: its role and the backfill's proposal
#   fleet-node-role.sh set <endpoint_id> managed|client|-   the operator's word on one node (- clears it)
#   fleet-node-role.sh apply [--yes]              the backfill: every UNTYPED login gets its proposal
#
# managed = a login of a 托管 machine or a cluster pod — the fleet runs tasks there;
# client = a person's terminal: it connects, looks and opens windows, hosts no
# repo and runs no task (the repo-authority check skips it, placement passes it
# over, and the node itself refuses fleet-repo.sh add / fleet host on / opening a
# session). A join sets it (a 托管 code or a login the hub opened: managed; a
# plain code or a device's `fleet login`: client); a row from before #4886 holds
# none until `apply` — run it only after the operator confirmed `plan`'s list.
# apply never changes a typed row.
#
# Who may: the operator — a viewer token in CCQUOTA_VIEWER_TOKEN, read from the
# ENVIRONMENT only and handed to curl on stdin, never an argv. The hub:
# CCQUOTA_HUB_URL, else FLEET_HUB_URL. GET/POST /v1/fleet/nodes/role.
#
# Exit 0 done · 1 the hub could not be asked · 2 usage / not confirmed · 4 refused.
# Seam: FLEET_HUB_CURL (default curl).
set -uo pipefail

die() { printf 'fleet-node-role: %s\n' "$2" >&2; exit "$1"; }
usage() { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; }

URL=${CCQUOTA_HUB_URL:-${FLEET_HUB_URL:-}}
CURL=${FLEET_HUB_CURL:-curl}

call() {   # call GET|POST [<body>] → the JSON on stdout, or die
  local resp rc code json
  [ -n "${CCQUOTA_VIEWER_TOKEN:-}" ] || die 1 'CCQUOTA_VIEWER_TOKEN is not set — the hub viewer token (the operator), read from the environment only'
  [ -n "$URL" ] || die 1 'no hub: CCQUOTA_HUB_URL / FLEET_HUB_URL unset'
  if [ "$1" = POST ]; then
    resp=$(printf 'Authorization: Bearer %s\n' "$CCQUOTA_VIEWER_TOKEN" | "$CURL" -sS --max-time 15 -o - -w '\n%{http_code}' \
      -H @- -H 'Content-Type: application/json' -X POST --data-binary "$2" "${URL%/}/v1/fleet/nodes/role" 2>/dev/null); rc=$?
  else
    resp=$(printf 'Authorization: Bearer %s\n' "$CCQUOTA_VIEWER_TOKEN" | "$CURL" -sS --max-time 15 -o - -w '\n%{http_code}' \
      -H @- "${URL%/}/v1/fleet/nodes/role" 2>/dev/null); rc=$?
  fi
  [ "$rc" = 0 ] && [ -n "$resp" ] || die 1 "hub unreachable ($URL): curl exit $rc"
  code=$(printf '%s\n' "$resp" | tail -n 1); json=$(printf '%s\n' "$resp" | sed '$d')
  case "$code" in
    200) printf '%s' "$json" ;;
    404|405) [ "$1" = POST ] && die 4 "the hub refused it ($code): $(printf '%s' "$json" | head -c 200)"
             die 4 "the hub has no $code route — a hub older than #4886" ;;
    *) die 4 "the hub answered HTTP $code: $(printf '%s' "$json" | head -c 300)" ;;
  esac
}

rows() {   # the plan as TSV: endpoint host user status role proposed why
  call GET | python3 -c 'import json,sys
for n in json.load(sys.stdin).get("nodes", []):
    print("\t".join([n["endpoint_id"], n["hostname"], n["os_user"], n.get("status",""), n.get("role") or "-", n["proposed"], n.get("why","")]))'
}

set_one() {   # set_one <endpoint> <role>
  local body
  body=$(python3 -c 'import json,sys; print(json.dumps({"endpoint_id": sys.argv[1], "role": sys.argv[2]}))' "$1" "$2")
  call POST "$body" >/dev/null && printf 'role: SET %s %s\n' "$1" "${2:--}"
}

cmd=${1:-}; [ $# -gt 0 ] && shift
case "$cmd" in
  plan)
    [ $# = 0 ] || die 2 'plan takes no argument'
    out=$(rows) || exit $?
    printf '%-28s %-32s %-12s %-8s %-8s %-8s %s\n' endpoint machine login status role proposed why
    printf '%s\n' "$out" | while IFS=$'\t' read -r e h u s r p w; do
      [ -n "$e" ] && printf '%-28s %-32s %-12s %-8s %-8s %-8s %s\n' "$e" "$h" "$u" "$s" "$r" "$p" "$w"
    done ;;
  set)
    [ $# = 2 ] || die 2 'set <endpoint_id> managed|client|-'
    case "$2" in managed|client) r=$2 ;; -) r='' ;; *) die 2 "a node is managed or client, not '$2'" ;; esac
    set_one "$1" "$r" ;;
  apply)
    yes=0; [ "${1:-}" = --yes ] && yes=1
    out=$(rows) || exit $?
    todo=$(printf '%s\n' "$out" | awk -F'\t' '$1 != "" && $5 == "-"')
    [ -n "$todo" ] || { echo 'role: every login is typed — nothing to backfill'; exit 0; }
    printf '%s\n' "$todo" | awk -F'\t' '{ printf "  %s  %s/%s → %s (%s)\n", $1, $2, $3, $6, $7 }'
    if [ "$yes" != 1 ]; then
      [ -t 0 ] || die 2 'not confirmed — rerun with --yes once the operator confirmed this list'
      printf '写入这 %s 行？ [y/N] ' "$(printf '%s\n' "$todo" | grep -c .)"; read -r a; case "$a" in y|Y) ;; *) die 2 'not confirmed — nothing written' ;; esac
    fi
    printf '%s\n' "$todo" | while IFS=$'\t' read -r e _ _ _ _ p _; do set_one "$e" "$p" || exit $?; done ;;
  -h|--help) usage ;;
  '') usage >&2; exit 2 ;;
  *) usage >&2; die 2 "unknown action '$cmd'" ;;
esac
