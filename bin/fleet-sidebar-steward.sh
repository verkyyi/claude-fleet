#!/bin/bash
# fleet-sidebar-steward.sh — what one item under the sidebar's 停放 / 待你动手
# rows does (issue #2913). Those rows open into their lists (fleet-sidebar.py
# steward_rows: `stewitem:park:<owner/name#N>` · `stewitem:todo:<id>` ·
# `stewitem:more:<park|todo>`), read off orch_<session>'s `parkl=` / `todol=`
# columns (fleet-hub-sessions.sh; fleet_steward.py list_cell). A tap on one opens
# its menu here:
#
#   menu <session> <stewitem:…> [--print]
#       park  立刻唤醒 (wake) · 打开 #N (the issue, in the person's browser)
#       todo  勾掉 (tick) · 打开 #N (where it came from) · 打开待办单 (the desk ticket)
#       more  the steward's page, where the whole list is
#     --print prints `key<TAB>name<TAB>command` per item (the selftest).
#   wake <session> <owner/name#N>   fleet-park.sh wake, on the steward's machine
#   tick <session> <todo id>        fleet-steward-tick.sh todo-done, the same
#
# The parked session and the list live on the machine the steward runs on, so
# wake / tick are the steward's to run: on that machine (a node holding the
# steward window, fleet_win_for_key steward) they run at once; anywhere else
# (the client shell — every row is remote) they go to the steward session as
# ONE message through fleet-sidebar-remote.sh (the hub write road every remote
# row action takes), naming the exact command — the steward's
# skill runs it (skills/fleet-steward/SKILL.md «侧栏»). No steward session ⇒ the
# toast says to tick it on the ticket. Either way the outcome is a toast.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
# shellcheck source=/dev/null
. "$BIN/fleet-ui-lang.sh"
fleet_ui_pin

verb="${1:-}"; sess="${2:-}"; arg="${3:-}"
[ -n "$sess" ] || exit 0
G="${FLEET_STATUS_G:-${FLEET_C:-${TMPDIR:-/tmp/claude-fleet-$(id -u)}/.claude-dash}/global}"
client=$(tmux list-clients -t "$sess" -F '#{client_activity} #{client_name}' 2>/dev/null \
  | sort -rn | head -1 | cut -d' ' -f2-)
toast() { tmux display-message ${client:+-c "$client"} "fleet: $1" 2>/dev/null || :; }
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
fe() { printf '%s' "$1" | sed 's/#/##/g'; }

# item <kind> <id> → `id<US>what<US>source<US>wait` of that item off orch_<sess>,
# plus the line's desk / page links: `#desk <url>` / `#page <url>` lines
item() {
  python3 - "$G/orch_$sess" "$1" "$2" <<'PY'
import base64, json, re, sys
path, kind, want = sys.argv[1:4]
try:
    first = open(path, encoding="utf-8").readline().rstrip("\n").split("\x1f")
except OSError:
    sys.exit(0)
cells = {}
for c in first[7:]:
    k, eq, v = c.strip().partition("=")
    if eq:
        cells.setdefault(k, v)
if re.fullmatch(r"https?://[-A-Za-z0-9._~:/?#@+,=%]{1,292}", cells.get("page", "")):
    print("#page\x1f" + cells["page"])
v = cells.get({"park": "parkl", "todo": "todol"}.get(kind, ""), "")
try:
    d = json.loads(base64.urlsafe_b64decode(v + "=" * (-len(v) % 4)).decode("utf-8")) if v else {}
except ValueError:
    d = {}
d = d if isinstance(d, dict) else {}
if re.fullmatch(r"https?://[-A-Za-z0-9._~:/?#@+,=%]{1,200}", str(d.get("u") or "")):
    print("#desk\x1f" + d["u"])
for e in d.get("i") or []:
    if not isinstance(e, dict):
        continue
    key = str(e.get("r") if kind == "park" else e.get("id") or "")
    if key and key == want:
        print("\x1f".join(re.sub(r"[\x00-\x1f]", " ", str(x or "")) for x in
                          (key, e.get("k") if kind == "park" else e.get("w"), e.get("s") or "", e.get("w") or "")))
        break
PY
}

# issue_url <owner/name#N> → its GitHub page ("" when it is not one)
issue_url() {
  case "$1" in
    */*'#'[0-9]*) r=${1%%#*}; n=${1#*#}; n=${n%%[!0-9]*}; printf 'https://github.com/%s/issues/%s' "$r" "$n" ;;
  esac
}

# steward_wid → the steward session's worker_id (fleet-hub-sessions.sh), "" none
steward_wid() { head -1 "$G/steward_all_$sess" 2>/dev/null | tr -d '\r'; }

# handoff <what> <script> <arg>… — run bin/<script> here when this machine holds
# the steward, else ask the steward to (one message naming its own install's
# copy), toasting the outcome
handoff() {
  local what=$1 script=$2 out rc w side cmd a
  shift 2
  if [ "${FLEET_SHELL:-0}" != 1 ] && [ -f "$BIN/fleet_steward.py" ] \
     && { [ -n "${FLEET_SIDEBAR_STEWARD_LOCAL:-}" ] || fleet_win_for_key steward >/dev/null 2>&1; }; then
    out=$(FLEET_SESSION="$sess" bash "$BIN/$script" "$@" 2>&1); rc=$?
    if [ "$rc" = 0 ]; then toast "$(fleet_ui_t steward_menu_done_fmt "$what")"
    else toast "$(fleet_ui_t steward_menu_failed_fmt "$what · $(printf '%s' "$out" | tail -1)")"; fi
    side=$(tmux list-panes -t "$sess:" -F '#{pane_id} #{@sidebar}' 2>/dev/null | awk '$2==1{print $1; exit}')
    [ -z "$side" ] || tmux send-keys -t "$side" F11 2>/dev/null || :
    return 0
  fi
  w=$(steward_wid)
  if [ -z "$w" ]; then toast "$(fleet_ui_t steward_menu_no_steward)"; return 0; fi
  # shellcheck disable=SC2088  # a literal: the path on the steward's machine, not here
  cmd="~/.claude/fleet/bin/$script"
  for a in "$@"; do cmd="$cmd $(sq "$a")"; done
  FLEET_SIDEBAR_TEXT="[sidebar] $what — please run: $cmd" \
    bash "$BIN/fleet-sidebar-remote.sh" message "$sess" "wid:$w" "$client" >/dev/null 2>&1 || :
  toast "$(fleet_ui_t steward_menu_sent_fmt "$what")"
}

case "$verb" in
  wake)
    case "$arg" in */*'#'[0-9]*) ;; *) exit 2 ;; esac
    handoff "$(fleet_ui_t steward_menu_wake) $arg" fleet-park.sh wake "$arg"
    exit 0 ;;
  tick)
    case "$arg" in ''|*[!A-Za-z0-9_.-]*) exit 2 ;; esac
    handoff "$(fleet_ui_t steward_menu_tick) $arg" fleet-steward-tick.sh todo-done --id "$arg"
    exit 0 ;;
  menu) ;;
  *) exit 2 ;;
esac

PRINT=''; [ "${4:-}" = --print ] && PRINT=1
rest=${arg#stewitem:}; kind=${rest%%:*}; id=${rest#*:}
case "$kind" in park|todo|more) ;; *) exit 0 ;; esac
lines=$(item "$([ "$kind" = more ] && printf '%s' "$id" || printf '%s' "$kind")" "$id")
page=$(printf '%s\n' "$lines" | awk -F $'\037' '$1 == "#page" { print $2; exit }')
desk=$(printf '%s\n' "$lines" | awk -F $'\037' '$1 == "#desk" { print $2; exit }')
it=$(printf '%s\n' "$lines" | awk -F $'\037' '$1 !~ /^#/ && NF > 1 { print; exit }')
IFS=$'\037' read -r _key what src _wait <<<"$it"

items=()
add() { items+=("$1" "$2" "$3"); }
self="bash $(sq "$BIN/fleet-sidebar-steward.sh")"
run() { printf 'run-shell -b %s' "$(sq "$1 >/dev/null 2>&1 || :")"; }
opener() { run "bash $(sq "$BIN/fleet-open.sh") $(sq "$1")"; }
title=''
case "$kind" in
  park)
    [ -n "$it" ] || exit 0
    title="$id${what:+ · $what}"
    add "$(fleet_ui_t steward_menu_wake)" w "$(run "$self wake $(sq "$sess") $(sq "$id")")"
    u=$(issue_url "$id"); [ -n "$u" ] && add "$(fleet_ui_t steward_menu_open_issue_fmt "#${id#*#}")" o "$(opener "$u")"
    ;;
  todo)
    [ -n "$it" ] || exit 0
    title=$what
    add "$(fleet_ui_t steward_menu_tick)" x "$(run "$self tick $(sq "$sess") $(sq "$id")")"
    u=$(issue_url "$src"); [ -n "$u" ] && add "$(fleet_ui_t steward_menu_open_issue_fmt "#${src#*#}")" o "$(opener "$u")"
    [ -n "$desk" ] && add "$(fleet_ui_t steward_menu_open_desk)" d "$(opener "$desk")"
    ;;
  more)
    [ -n "$page" ] || exit 0
    if [ -z "$PRINT" ]; then bash "$BIN/fleet-open.sh" "$page" >/dev/null 2>&1 || :; exit 0; fi
    title=$page; add "page" p "$(opener "$page")"
    ;;
esac
if [ -n "$PRINT" ]; then
  printf 'title\t%s\n' "$title"
  i=0; while [ "$i" -lt "${#items[@]}" ]; do
    printf '%s\t%s\t%s\n' "${items[$((i + 1))]}" "${items[$i]}" "${items[$((i + 2))]}"; i=$((i + 3))
  done
  exit 0
fi
[ -n "$client" ] || exit 0
side=$(tmux list-panes -t "$sess:" -F '#{pane_id} #{@sidebar}' 2>/dev/null | awk '$2==1{print $1; exit}')
margs=(); i=0
while [ "$i" -lt "${#items[@]}" ]; do
  margs+=("$(fe "${items[$i]}")" "${items[$((i + 1))]}" "${items[$((i + 2))]}"); i=$((i + 3))
done
margs+=("" "-$(fleet_ui_t ui_close)" "" "")
# shellcheck source=/dev/null
. "$BIN/fleet-popup-lib.sh"; fleet_menu_style
tmux display-menu -c "$client" ${side:+-t "$side"} -x P -y P ${FMENU_STYLE[@]+"${FMENU_STYLE[@]}"} \
  -T "#[align=centre] $(fe "$title") " -- ${margs[@]+"${margs[@]}"} 2>/dev/null || :
exit 0
