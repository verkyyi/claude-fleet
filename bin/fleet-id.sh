#!/bin/bash
# fleet-id.sh — a window's ID and its ledger (EPIC T497 C1; bin/fleet_id.py holds
# the rules and says them in full).
#
#   fleet-id.sh hook                         SessionStart (both agents): add the native
#                                            segment this start is, by §4.2's rules
#   fleet-id.sh open <ID> [--agent a] [--window @w [--socket L]] [--repo o/r] [--title t] [--key k]
#                         [--task Tn] [--parent ID] [--prev ID]
#                                            the spawn's `opened`; prints the short code
#                                            and stamps it on --window as @task_short
#   fleet-id.sh native <ID> --agent a --native <sid> --source startup|resume|clear|compact [--hint handoff]
#   fleet-id.sh result <ID> --state s [--summary …] [--pr N] [--agent a]
#   fleet-id.sh close  <ID> [--reason r]
#   fleet-id.sh get    <ID | T-code> [--json]  the ID, its segments (agent · native id ·
#                                            start–end · trigger · compactions), results
#   fleet-id.sh short  <ID>                  its short code, T-<5+>
#   fleet-id.sh resolve <ID | T-code>        → the full ID; rc 1 none, rc 2 ambiguous
#                                            (the candidates on stderr — never a pick)
#
# The ledger is $FLEET_CONF_DIR/ids/<ID>.ndjson. Nothing decides anything off it
# yet: it is written beside the old task record until the switch (EPIC T497 C7).
# The hook never fails and never prints; FLEET_ID_HOOK=0 turns it off.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
case "${1:-}" in
  hook) exec python3 "$BIN/fleet_id.py" hook ;;
  ''|-h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d'; exit 0 ;;
esac
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

# Every live window's ID on this login's fleets: a window opened before its ledger
# is still an ID a short code may name, and one a new code must not collide with.
live=''
case "$1" in
  open|short|resolve|get|native|result|close)
    if [ -n "${TMUX:-}" ]; then live=$(fleet_lw '#{@fleet_id}' 2>/dev/null)
    else
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        live="$live"$'\n'"$(fleet_lw '#{@fleet_id}' tmux -L "$s" 2>/dev/null)"
      done <<EOF
$(fleet_sockets 2>/dev/null)
EOF
    fi ;;
esac
cmd=$1; shift
if [ "$cmd" = open ]; then
  win=''; sock=''; prev=''; oargs=()
  for a in "$@"; do
    case "$prev" in
      --window) win=$a ;;
      --socket) sock=$a; prev=''; continue ;;
    esac
    [ "$a" = --socket ] || oargs+=("$a")
    prev=$a
  done
  short=$(FLEET_ID_LIVE="$live" python3 "$BIN/fleet_id.py" open ${oargs[@]+"${oargs[@]}"}) || exit 1
  tm=(tmux); [ -n "$sock" ] && tm+=(-L "$sock")
  [ -z "$win" ] || [ -z "$short" ] || "${tm[@]}" set-window-option -t "$win" @task_short "$short" 2>/dev/null || :
  printf '%s\n' "$short"
  exit 0
fi
FLEET_ID_LIVE="$live" exec python3 "$BIN/fleet_id.py" "$cmd" "$@"
