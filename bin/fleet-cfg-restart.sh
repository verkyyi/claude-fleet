#!/bin/bash
# fleet-cfg-restart.sh — reopen the sessions running an OLD configuration once they
# are idle (issue #1783, EPIC #1776 C7).
#
# A session's configuration is fixed at launch and fingerprinted on its window as
# @agent_cfg (#1782); $FLEET_CONF_DIR/global/agent-cfg.expected holds the one a
# fresh session would get now (rewritten by every install-apply and team apply).
# They differ after a stable move or a team-config change, and the dozen sessions
# still open quietly keep running the old one — so "did it reopen?" became the
# first thing to rule out whenever something misbehaved. The sidebar marks such a
# row 配置旧 (tmux-dashboard-rows.sh); this tick reopens it.
#
# Each tick (fleet-sleep-daemon.sh, after the reeval), per fleet: the windows whose
# @agent_cfg differs from the expected one are judged by fleet_cfg_restart_why —
# a Claude session, `done` for FLEET_CFG_RESTART_IDLE seconds (600), no /loop
# round held, no Bash-tool job running, not asleep; a working / looping / needs
# session is never touched — and at most FLEET_CFG_RESTART_MAX (1) of them is
# handed to `fleet-migrate.sh --cfg-stale` (fleet_bg, detached: a reopen is a cold
# boot). That is the same close + `claude --resume <same session>` road a quota
# move takes, so the conversation goes on in the new window; migrate asks the
# judge AGAIN right before its /exit, and records a `reason=cfg-stale` row in
# /fleet-history. @cfg_restart_ts holds a window off for the idle span after a try,
# so a reopen that did not happen is retried, never hammered.
#
# FLEET_CFG_RESTART (EPIC #1776 decision 4: default auto):
#   auto  reopen as above
#   ask   reopen nothing; one alert per window per fingerprint names it instead
#   off   nothing (the sidebar still marks the row; --list / --count still answer)
# A Codex session is marked but never reopened here (migrate is Claude's road).
#
# Usage: fleet-cfg-restart.sh [--dry-run] [--quiet] [--] [<session>...]
#        fleet-cfg-restart.sh --list  [<session>...]   one `sess wid name verdict` row
#                                                      per stale session
#        fleet-cfg-restart.sh --count [<session>...]   how many sessions are stale
# No session = every live fleet (fleet_sockets). Always exits 0 except on a usage
# error (2).
set -uo pipefail
BIN=$(cd "$(dirname "$0")" && pwd)
. "$BIN/fleet-lib.sh"

DRY='' QUIET='' MODE=tick
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --quiet) QUIET=1 ;;
    --list) MODE=list ;;
    --count) MODE=count ;;
    --) shift; break ;;
    -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
    -*) printf 'fleet-cfg-restart: unknown option %s\n' "$1" >&2; exit 2 ;;
    *) break ;;
  esac
  shift
done

POLICY="${FLEET_CFG_RESTART:-auto}"
case "$POLICY" in auto|ask|off) ;; *) POLICY=auto ;; esac
IDLE="${FLEET_CFG_RESTART_IDLE:-600}"; case "$IDLE" in ''|*[!0-9]*) IDLE=600 ;; esac
MAX="${FLEET_CFG_RESTART_MAX:-1}";     case "$MAX" in ''|*[!0-9]*) MAX=1 ;; esac
MIGRATE="${FLEET_CFG_RESTART_MIGRATE:-$BIN/fleet-migrate.sh}"   # selftest seam
LOG="$BIN/../logs/cfg-restart.log"

if [ $# -gt 0 ]; then sockets=$*; else sockets=$(fleet_sockets); fi
fleet_cfg_expected_load
total=0
say() { [ -n "$QUIET" ] || printf '%s\n' "$*"; }

for sess in $sockets; do
  # The stale ones first, off ONE list-windows: a compare per window, no fork;
  # only those are judged further.
  stale=''
  while IFS='|' read -r wid ag fp ts; do
    [ -n "$wid" ] || continue
    fleet_cfg_state "$ag" "$fp"
    [ "$FCFG_STATE" = stale ] && stale+="$wid|$fp|$ts"$'\n'
  done < <(tmux -L "$sess" list-windows -t "=$sess" \
             -F '#{window_id}|#{@cc_agent}|#{@agent_cfg}|#{@cfg_restart_ts}' 2>/dev/null)
  [ -n "$stale" ] || continue
  picked=0
  while IFS='|' read -r wid fp ts; do
    [ -n "$wid" ] || continue
    total=$((total + 1))
    nm=$(tmux -L "$sess" display-message -p -t "$wid" '#{window_name}' 2>/dev/null)
    case "$nm" in dash|plan|backlog|home) total=$((total - 1)); continue ;; esac
    [ "$MODE" = count ] && continue
    why=$(FLEET_CFG_RESTART_IDLE=$IDLE fleet_cfg_restart_why "$sess" "$wid" "$IDLE") && why=reopen
    if [ "$MODE" = list ]; then printf '%s\t%s\t%s\t%s\n' "$sess" "$wid" "$nm" "$why"; continue; fi
    [ "$why" = reopen ] || continue
    [ "$POLICY" != off ] || continue
    case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
    [ $(( $(date +%s) - ts )) -ge "$IDLE" ] || continue        # tried lately: hold off
    if [ "$POLICY" = ask ]; then
      [ "$(tmux -L "$sess" display-message -p -t "$wid" '#{@cfg_asked}' 2>/dev/null)" = "$fp" ] && continue
      say "ask: $sess:$nm ($wid) runs an old configuration and is idle"
      [ -n "$DRY" ] && continue
      tmux -L "$sess" set-option -w -t "$wid" @cfg_asked "$fp" 2>/dev/null
      bash "$BIN/fleet-alerts.sh" event -L "$sess" cfg-stale \
        "$nm: 配置旧，空闲中，可重开（fleet-migrate.sh --cfg-stale） · runs an old configuration" >/dev/null 2>&1 || :
      continue
    fi
    [ "$picked" -lt "$MAX" ] || { say "later: $sess:$nm ($wid) — $MAX reopen(s) per fleet per tick"; continue; }
    picked=$((picked + 1))
    say "reopen: $sess:$nm ($wid) onto the current configuration"
    [ -n "$DRY" ] && continue
    tmux -L "$sess" set-option -w -t "$wid" @cfg_restart_ts "$(date +%s)" 2>/dev/null
    mkdir -p "${LOG%/*}" 2>/dev/null
    printf '%s reopen %s:%s (%s) reason=cfg-stale\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$sess" "$nm" "$wid" >> "$LOG" 2>/dev/null
    fleet_bg -L "$sess" "bash '$MIGRATE' --cfg-stale --session '$sess' --alert '$wid'"
  done <<< "$stale"
done
[ "$MODE" = count ] && printf '%s\n' "$total"
exit 0
