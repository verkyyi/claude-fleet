#!/bin/bash
# fleet-status-lib.sh — the status bar's view of THE MACHINE THE CURRENT SESSION
# IS ON (issue #1482, EPIC #1479 C3). Sourced by bin/tmux-status.sh on every
# render, and by the shell's own status line (C5, #1484): one function decides
# which machine a window is "on", and the rest read the two summaries the hub
# refresh loop leaves in $FLEET_STATUS_G — never the network (EPIC #1479 rule 2).
#
#   fleet_status_node <@remote> <me>   → FSN_KIND (local|remote) FSN_NODE FSN_WID
#       a window marked `@remote=<node>:<worker_id>` (a proxy onto another machine,
#       fleet-remote-view.sh) is ON <node>; any other window is on this machine
#       (<me>). The shell (C5) passes its right pane's window the same way, so
#       「当前会话所在机器」 is this one rule on every surface.
#   fleet_status_remote_head <sess>    → FSR_TS FSR_ME from global/remote_<sess>'s
#       header (fleet-hub-sessions.sh); rc 1 when there is no cache. FSR_TS is
#       when that cache was written — fleet_status_hub_ok's fallback clock.
#   fleet_status_hub_ok [fallback-ts]  → FSH_TS: when the hub last ANSWERED — the
#       epoch in global/hub_ok, which fleet-hub-sessions.sh writes on every
#       fleet_sessions round that stood (a 200 taken, a 304 restamped; issue
#       #1483, EPIC #1479 C4), else <fallback-ts> (a remote_<sess> #ts: a cache
#       from before hub_ok existed), else 0. THE one word on 「入口通不通」: the
#       sidebar's rows, this bar and the remote-row actions all read it here;
#       none of them probes the hub.
#   fleet_status_hub_lost <now>        → rc 0 = 失联: FSH_TS is older than
#       FLEET_HUB_SESSIONS_STALE (60 s), FSH_AGE the seconds since; rc 1 = fresh.
#   fleet_status_hub_node <label>      → HN_* from global/hub_nodes; rc 1: no row.
#   fleet_status_remote_node <sess> <label> → RN_AV (online|lost|maintenance) RN_N
#       RN_SEEN from the `#node` header line of global/remote_<sess> (#1475): the
#       hub's word on a machine when hub_nodes has no row for it — a login whose
#       identity is a certificate on a hub without #1502's cert door, the shell on a
#       colleague's computer first of all (#1484). rc 1: no such line.
#   fleet_status_hub_limit <label>     → HL_* from global/hub_limits; rc 1: no row.
#   fleet_status_age <secs>            → FSA: `3m` / `2h` / `1d` for 失联 N.
#   fleet_status_window_list on|off    → the window list (window-status-format /
#       -current-format) goes blank while the bar is in hub mode and comes back
#       when it leaves — saved in the global @status_wsf_saved / @status_wscf_saved
#       (flag @status_wlist_saved, what the conf's `wsaved=` reads). The ONLY thing
#       here that runs tmux, and only at a transition: this fleet's server is its
#       own (#159), so the global option IS this session's.
#
# Everything else is builtins: `read` over a US-separated file, no subshell — the
# bar renders every status-interval per attached client (#888).
#
# hub_nodes  (one per machine the hub shows; written by fleet-hub-sessions.sh):
#   #ts<US><epoch>
#   node<US>online|lost<US>load1<US>ncpu<US>mem_pct<US>sessions<US>fleet_version<US>age<US>mem_used_mb<US>mem_total_mb
#   sessions is `?` when the hub could not read a fleet there (#1465), never 0.
# hub_limits (one per subscription with a reading):
#   #ts<US><epoch>
#   label<US>pct5h<US>pctweek<US>account_uuid<US>hub_label
# `label` is this login's accounts/<label>.conf name when its CCQUOTA_ACCOUNT is
# that uuid (what a window's @cc_account holds), else the hub's own label.

# shellcheck disable=SC2034  # the FSN_* / FSR_* / FSH_* / HN_* / HL_* / FSA results are read by the sourcing script
FLEET_STATUS_G="${FLEET_STATUS_G:-${TMPDIR:-/tmp}/.claude-dash/global}"
_FS_US=$'\x1f'

fleet_status_node() {
  local remote="${1:-}" me="${2:-}"
  case "$remote" in
    ?*:*) FSN_KIND=remote; FSN_NODE=${remote%%:*}; FSN_WID=${remote#*:} ;;
    *)    FSN_KIND=local;  FSN_NODE=${me:-?};       FSN_WID='' ;;
  esac
  return 0
}

fleet_status_remote_head() {
  local f="$FLEET_STATUS_G/remote_${1:-}" k v _r
  FSR_TS=''; FSR_ME=''
  [ -n "${1:-}" ] && [ -s "$f" ] || return 1
  while IFS=$_FS_US read -r k v _r; do
    case "$k" in
      '#ts') FSR_TS=$v ;;
      '#me') FSR_ME=$v ;;
      '#'*)  ;;
      *)     break ;;                       # the rows: the header is over
    esac
  done < "$f"
  case "$FSR_TS" in ''|*[!0-9]*) FSR_TS=0 ;; esac
  return 0
}

fleet_status_hub_ok() {
  local f="$FLEET_STATUS_G/hub_ok" _r
  FSH_TS=''
  [ -s "$f" ] && { read -r FSH_TS _r < "$f" || :; } 2>/dev/null     # read sets it even with no final newline
  case "$FSH_TS" in ''|*[!0-9]*) FSH_TS="${1:-0}" ;; esac    # no file (pre-#1483 loop), or junk
  case "$FSH_TS" in ''|*[!0-9]*) FSH_TS=0 ;; esac
  return 0
}

fleet_status_hub_lost() {
  local now="${1:-0}" stale="${FLEET_HUB_SESSIONS_STALE:-60}"
  case "$now" in ''|*[!0-9]*) now=0 ;; esac
  case "$stale" in ''|*[!0-9]*) stale=60 ;; esac
  FSH_AGE=$(( now - ${FSH_TS:-0} )); [ "$FSH_AGE" -lt 0 ] && FSH_AGE=0
  [ "$FSH_AGE" -gt "$stale" ]
}

fleet_status_hub_node() {
  local f="$FLEET_STATUS_G/hub_nodes" want="${1:-}" k a b c d e g h i j
  HN_TS=0 HN_AV='' HN_LOAD1='' HN_NCPU='' HN_MEM='' HN_SESS='' HN_VER='' HN_AGE='' HN_USED='' HN_TOTAL=''
  [ -n "$want" ] && [ -s "$f" ] || return 1
  while IFS=$_FS_US read -r k a b c d e g h i j; do
    case "$k" in
      '#ts')   HN_TS=$a; case "$HN_TS" in ''|*[!0-9]*) HN_TS=0 ;; esac ;;
      "$want") HN_AV=$a; HN_LOAD1=$b; HN_NCPU=$c; HN_MEM=$d; HN_SESS=$e; HN_VER=$g; HN_AGE=$h; HN_USED=$i; HN_TOTAL=$j
               return 0 ;;
    esac
  done < "$f"
  return 1
}

fleet_status_remote_node() {
  local f="$FLEET_STATUS_G/remote_${1:-}" want="${2:-}" k a b c d _r
  RN_AV='' RN_N='' RN_SEEN=''
  [ -n "${1:-}" ] && [ -n "$want" ] && [ -s "$f" ] || return 1
  while IFS=$_FS_US read -r k a b c d _r; do
    case "$k" in
      '#node') [ "$a" = "$want" ] && { RN_AV=$b; RN_N=$c; RN_SEEN=$d; return 0; } ;;
      '#'*)    ;;
      *)       break ;;                       # the rows: the header is over
    esac
  done < "$f"
  return 1
}

fleet_status_hub_limit() {
  local f="$FLEET_STATUS_G/hub_limits" want="${1:-}" k a b c d
  HL_TS=0 HL_5H='' HL_WK=''
  [ -n "$want" ] && [ -s "$f" ] || return 1
  while IFS=$_FS_US read -r k a b c d; do
    case "$k" in
      '#ts')   HL_TS=$a; case "$HL_TS" in ''|*[!0-9]*) HL_TS=0 ;; esac ;;
      "$want") HL_5H=$a; HL_WK=$b; return 0 ;;
      *)       [ "$d" = "$want" ] && { HL_5H=$a; HL_WK=$b; return 0; } ;;   # the hub's own label
    esac
  done < "$f"
  return 1
}

fleet_status_age() {
  local s="${1:-0}"
  case "$s" in ''|*[!0-9]*) s=0 ;; esac
  if   [ "$s" -lt 7200 ];  then FSA="$(( s / 60 ))m"
  elif [ "$s" -lt 172800 ]; then FSA="$(( s / 3600 ))h"
  else                            FSA="$(( s / 86400 ))d"; fi
}

fleet_status_window_list() {
  local wsf wscf
  case "${1:-}" in
    on)
      wsf=$(tmux show-options -gqv window-status-format 2>/dev/null)
      wscf=$(tmux show-options -gqv window-status-current-format 2>/dev/null)
      [ -n "$wsf$wscf" ] || return 0
      # one option per format (a tmux prints a control character inside an
      # option value escaped, so a joined pair would not split back), plus the
      # flag the conf's `wsaved=` reads
      tmux set-option -g @status_wsf_saved "$wsf" \; \
           set-option -g @status_wscf_saved "$wscf" \; \
           set-option -g @status_wlist_saved 1 \; \
           set-option -g window-status-format '' \; \
           set-option -g window-status-current-format '' 2>/dev/null ;;
    off)
      [ -n "$(tmux show-options -gqv @status_wlist_saved 2>/dev/null)" ] || return 0
      wsf=$(tmux show-options -gqv @status_wsf_saved 2>/dev/null)
      wscf=$(tmux show-options -gqv @status_wscf_saved 2>/dev/null)
      tmux set-option -g window-status-format "$wsf" \; \
           set-option -g window-status-current-format "$wscf" \; \
           set-option -gu @status_wlist_saved \; \
           set-option -gu @status_wsf_saved \; \
           set-option -gu @status_wscf_saved 2>/dev/null ;;
  esac
  return 0
}
