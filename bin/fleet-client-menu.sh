#!/usr/bin/env bash
# fleet-client-menu.sh — 我的客户端 (issue #1932, EPIC #1906 C13): the clients a
# person holds at once — device, terminal, when last used — and a way to
# disconnect one. The sidebar's row menu lists it in the client (FLEET_SHELL=1).
#
#   fleet-client-menu.sh menu <shell session> [<client>] [--print]
#       draw the list as a tmux menu on that client: one item per client, the
#       primary (where pages and files go) marked ●, this computer's marked
#       （这台）and greyed; picking another asks y/n, then disconnects it.
#       --print: `key<TAB>name<TAB>command` lines (tests)
#   fleet-client-menu.sh revoke <lease id> [<client>]
#       disconnect it (fleet-client-lease.py revoke): its lease and action key
#       are dropped on the hub at once, its screen says why; toasted either way
#
# The list is asked of the hub afresh (fleet-client-lease.py list); out of reach,
# the keeper's last copy (client.list.json) is shown, titled as such. Which one is
# this computer's: client.lease beside it. Strings: fleet-ui-lang.sh, the table.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/fleet-ui-lang.sh"
fleet_ui_pin
t() { fleet_ui_t "$@"; }
CL_DIR="${TMPDIR:-/tmp}"
CL_DIR="${CL_DIR%/}"
LEASE_CMD="${FLEET_CLIENT_LEASE_CMD:-python3 $BIN/fleet-client-lease.py}"
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
fe() { printf '%s' "$1" | sed 's/#/##/g'; }

sub=${1:-}; shift || :
case "$sub" in
  revoke)
    id=${1:-}; client=${2:-}
    [ -n "$id" ] || { printf 'usage: fleet-client-menu.sh revoke <lease id> [<client>]\n' >&2; exit 2; }
    if out=$($LEASE_CMD revoke --target "$id" 2>&1) && [ "${out%%$'\t'*}" = revoked ]; then
      msg=$(t clients_revoked); rc=0
    else
      msg="$(t clients_revoke_failed) ${out##*: }"; rc=1
    fi
    tmux display-message ${client:+-c "$client"} "$msg" 2>/dev/null || printf '%s\n' "$msg"
    exit "$rc"
    ;;
  menu) ;;
  *) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac

sess=${1:-}; client=${2:-}; PRINT=''
[ "${3:-}" = --print ] && PRINT=1
[ "$client" = --print ] && { PRINT=1; client=''; }
own=''; { read -r own < "$CL_DIR/client.lease"; } 2>/dev/null
title=$(t clients_title)
list=$($LEASE_CMD list 2>/dev/null) || list=''
case "$list" in
  '{'*) ;;
  *) list=$(cat "$CL_DIR/client.list.json" 2>/dev/null) || list=''
     title="$title · $(t clients_stale)" ;;
esac

self=$(printf '%q' "$BIN/fleet-client-menu.sh")
rows=$(OWN="$own" LIST="$list" python3 - <<'PY'
import json, os, time
try:
    d = json.loads(os.environ.get("LIST") or "{}")
except ValueError:
    d = {}
own, prim = os.environ.get("OWN") or "", d.get("primary") or ""
now = time.time()


def ago(ts):
    if not ts:
        return ""
    try:
        import datetime
        t = datetime.datetime.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=datetime.timezone.utc).timestamp()
    except ValueError:
        return ""
    s = max(0, int(now - t))
    return "now" if s < 60 else "m %d" % (s // 60) if s < 3600 else "h %d" % (s // 3600) if s < 86400 else "d %d" % (s // 86400)


for c in d.get("clients") or []:
    if not isinstance(c, dict) or not c.get("id"):
        continue
    words = [c.get("device") or "?"]
    if c.get("terminal"):
        words.append(c["terminal"])
    if c.get("via") and c.get("via") != "local" and c.get("host"):
        words.append("@" + c["host"])
    # \037, not TAB: `read` collapses two TABs in a row (an empty field)
    print("\037".join([c["id"], "1" if c["id"] == prim else "", "1" if c["id"] == own else "",
                     " · ".join(w.replace("\037", " ") for w in words), ago(c.get("last_input") or c.get("since") or "")]))
PY
)

margs=(); n=0
while IFS=$'\037' read -r id prim mine label ago; do
  [ -n "$id" ] || continue
  n=$((n + 1))
  case "$ago" in
    now) when=$(t clients_now) ;;
    '') when='' ;;
    m\ *) when=$(t clients_ago_m "${ago#* }") ;;
    h\ *) when=$(t clients_ago_h "${ago#* }") ;;
    *) when=$(t clients_ago_d "${ago#* }") ;;
  esac
  name="$label${when:+ · $when}"
  [ -n "$prim" ] && name="● $name"
  if [ -n "$mine" ]; then
    margs+=("-$(fe "$name") $(t clients_this)" "" "")
  else
    confirm=$(t clients_confirm_fmt "$label")
    cmd="run-shell -b $(sq "$self revoke $(printf '%q' "$id") $(printf '%q' "$client") >/dev/null 2>&1 || :")"
    margs+=("$(fe "$name")" "$([ "$n" -le 9 ] && printf '%s' "$n")" "confirm-before -p $(sq "$(fe "$confirm")") \"$(printf '%s' "$cmd" | sed 's/["\\]/\\&/g')\"")
  fi
done <<< "$rows"
[ "$n" -gt 0 ] || margs+=("-$(t clients_none)" "" "")
margs+=("" "-$(t clients_hint)" "" "")

if [ -n "$PRINT" ]; then
  printf 'title\t%s\n' "$title"
  i=0
  while [ "$i" -lt "${#margs[@]}" ]; do
    if [ -z "${margs[$i]}" ]; then i=$((i + 1)); continue; fi
    printf '%s\t%s\t%s\n' "${margs[$((i + 1))]}" "${margs[$i]}" "${margs[$((i + 2))]}"
    i=$((i + 3))
  done
  exit 0
fi
. "$BIN/fleet-popup-lib.sh" 2>/dev/null && fleet_menu_style 2>/dev/null || :
tmux display-menu ${client:+-c "$client"} -x P -y P ${FMENU_STYLE[@]+"${FMENU_STYLE[@]}"} \
  -T "#[align=centre] $(fe "$title") " -- ${margs[@]+"${margs[@]}"} 2>/dev/null || :
exit 0
