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
#   fleet-id.sh status <ID | T-code>         {state, label, result, conflict}: the one word a
#                                            reader shows (EPIC T497 C4 — S2 / S7 / S9)
#   fleet-id.sh route <ID | T-code>          who takes what was meant for it: `<ID>\t<how>`,
#                                            how = self · successor (down the prev chain) ·
#                                            parent · unknown (no ledger here); rc 1 nobody
#   fleet-id.sh children <ID | T-code> [--json]   the IDs it spawned (their `parent`)
#   fleet-id.sh family <ID | T-code> [<member ID>…]   JSON: the IDs it spawned (and
#                                            the members named), every ID that
#                                            continued one of them down `prev` (a redo),
#                                            this machine's ledgers + the hub mirror's
#                                            (EPIC T497 C5 — an EPIC driver's batch)
#   fleet-id.sh await <ID | T-code> [--timeout s] [--interval s]
#                                            until it has a result or closes: MERGED /
#                                            SUCCEEDED 0 · FAILED / BLOCKED … 1 · TIMEOUT 3 ·
#                                            EXITED 4 (closed with no result)
#   fleet-id.sh history [<filter>] [--all] [--json]   one row per ID: code · 状态 ·
#                                            result · closed at · title (closed ones, or --all)
#   fleet-id.sh continue <ID> [--seg N] [--exec]   「从这一段继续」: a NEW window, a new
#                                            ID whose prev is this one (S8)
#   fleet-id.sh reopen <ID> [--exec]         「恢复这个窗口」: the SAME ID, its newest segment
#   fleet-id.sh push [<ID>…]                 hand the ledgers (all, or these) to the hub's
#                                            mirror in (ID, seq) order from where it is
#                                            (EPIC T497 C2, fleet_id.py push): rc 0 · 3 no
#                                            hub here (nothing sent) · 75 the hub did not
#                                            answer (the next push, or the cleanup tick, resumes)
#   fleet-id.sh migrate [--apply] [--only T1,T2] [--json]
#                                            the old T records onto IDs (EPIC T497 C6, design
#                                            §5): each record's verdict by one rule — 已终态 ⇒
#                                            照抄结果 · worker's window there ⇒ 活着 (that ID,
#                                            the T number its alias) · its machine says no
#                                            window ⇒ 已退出 / 已取消 · never claimed ⇒ 已关闭 ·
#                                            没开起来 · the machine silent ⇒ 等节点回答 (never
#                                            moved). Dry by default; --apply writes (audited)
#   fleet-id.sh switch [status|on|off]       the hub's ID switch (on/off: the operator's
#                                            machines); written down in ids/.switch. Off =
#                                            every old road; on = the gate is «the window has
#                                            an ID»: no claim, a report is the ID's result
#
# `_post METHOD PATH` (the body on stdin → `<http code>\n<body>`) is push's one
# road to the hub: the node token is read here, per call (fleet_node_pair), never
# handed to python or put in an environment. FLEET_ID_HUB_POST is its seam;
# FLEET_ID_PUSH=0 keeps the spawn, the hook and result/close from pushing.
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
# `scanned` = a tmux server answered: only then is an ID with no window known to be
# gone (C4's status / route); with none, the ledger alone says (FLEET_ID_LIVE unset).
# FLEET_ID_LIVE_CMD is the selftest's seam (prints the live IDs).
live='' scanned=''
case "$1" in
  open|short|resolve|get|native|result|close|status|route|children|family|await|history|continue|reopen)
    if [ -n "${FLEET_ID_LIVE_CMD:-}" ]; then live=$(eval "$FLEET_ID_LIVE_CMD") && scanned=1
    elif [ -n "${TMUX:-}" ]; then live=$(fleet_lw '#{@fleet_id}' 2>/dev/null) && scanned=1
    else
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        tmux -L "$s" list-sessions >/dev/null 2>&1 && scanned=1
        live="$live"$'\n'"$(fleet_lw '#{@fleet_id}' tmux -L "$s" 2>/dev/null)"
      done <<EOF
$(fleet_sockets 2>/dev/null)
EOF
    fi ;;
esac
cmd=$1; shift
case "$cmd" in
  _post)
    pair=$(fleet_node_pair 2>/dev/null) || exit 3
    url=${pair%%	*}; tok=${pair#*	}
    body=$(cat)
    resp=$(printf 'header = "Authorization: %s"\n' "$(fleet_node_auth "$1" "$url$2" "$tok")" | \
      "${FLEET_HUB_CURL:-curl}" -sS --max-time "${FLEET_HUB_TIMEOUT:-10}" -K - -o - -w '\n%{http_code}' \
        -X "$1" -H 'Content-Type: application/json' ${body:+--data-binary "$body"} "$url$2" 2>/dev/null) || { printf '0\n'; exit 0; }
    printf '%s\n%s\n' "$(printf '%s\n' "$resp" | tail -n 1)" "$(printf '%s\n' "$resp" | sed '$d')"
    exit 0 ;;
  push)
    if [ -z "${FLEET_ID_HUB_POST:-}" ]; then
      sess=$(fleet_current_session 2>/dev/null) || sess=''
      if [ -n "$sess" ]; then fleet_hub_on "$sess" || exit 3; fi
      fleet_node_pair >/dev/null 2>&1 || exit 3
    fi
    wins=''
    if [ -n "${TMUX:-}" ]; then wins=$(fleet_lw '#{@fleet_id}	#{window_id}' 2>/dev/null | sed 's/	/		/')
    else
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        wins="$wins"$'\n'"$(fleet_lw '#{@fleet_id}	#{window_id}' tmux -L "$s" 2>/dev/null | sed "s/	/	$s	/")"
      done <<EOF
$(fleet_sockets 2>/dev/null)
EOF
    fi
    FLEET_ID_WINDOWS="$wins" FLEET_ID_LIVE="$live" exec python3 "$BIN/fleet_id.py" push "$@" ;;
esac
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
  [ "${FLEET_ID_PUSH:-1}" = 0 ] || ( bash "$BIN/fleet-id.sh" push "$1" </dev/null >/dev/null 2>&1 & )
  exit 0
fi
# 「从这一段继续」/「恢复这个窗口」 (EPIC T497 C4, design §4.4): the plan is the
# ledger's (fleet_id.py continue / reopen); --exec opens the window through the one
# spawner, dash-raw-session.sh — a new ID with --prev, or the same one with --fid.
if [ "$cmd" = continue ] || [ "$cmd" = reopen ]; then
  ex=0; pargs=()
  for a in "$@"; do if [ "$a" = --exec ]; then ex=1; else pargs+=("$a"); fi; done
  if [ -n "$scanned" ]; then plan=$(FLEET_ID_LIVE="$live" python3 "$BIN/fleet_id.py" "$cmd" ${pargs[@]+"${pargs[@]}"}) || exit 1
  else plan=$(python3 "$BIN/fleet_id.py" "$cmd" ${pargs[@]+"${pargs[@]}"}) || exit 1; fi
  [ "$ex" = 1 ] || { printf '%s\n' "$plan"; exit 0; }
  fields=$(printf '%s' "$plan" | python3 -c 'import json,sys; d=json.load(sys.stdin)
print("\t".join(str(d.get(k) or "-") for k in ("id","native","agent","worktree","repo","title")))')
  IFS=$'\t' read -r p_id p_native p_agent p_wt p_repo p_title <<< "$fields"
  rargs=(--resume "$p_native" --origin hub)
  [ "$p_agent" = codex ] && rargs+=(--agent codex)
  [ "$p_title" = - ] || rargs+=(--name "$p_title")
  if [ "$p_repo" != - ] && [ "$p_wt" != - ] && [ -d "$p_wt" ]; then rargs+=(--repo "$p_repo" --worktree "$p_wt")
  elif [ "$p_repo" = - ]; then rargs+=(--no-repo)
  else
    printf 'fleet-id: %s worked in %s (%s), which is gone — by hand: recreate it, then `claude --resume %s` there\n' \
      "$p_id" "$p_wt" "$p_repo" "$p_native" >&2
    exit 1
  fi
  if [ "$cmd" = continue ]; then rargs+=(--prev "$p_id"); else rargs+=(--fid "$p_id"); fi
  exec bash "${FLEET_ID_SPAWN:-$BIN/dash-raw-session.sh}" "${rargs[@]}"
fi
if [ -n "$scanned" ]; then FLEET_ID_LIVE="$live" exec python3 "$BIN/fleet_id.py" "$cmd" "$@"; fi
exec python3 "$BIN/fleet_id.py" "$cmd" "$@"
