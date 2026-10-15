#!/bin/bash
# fleet-status-lib.sh — what the hub refresh loop leaves in $FLEET_STATUS_G,
# read without the network (issue #1482, EPIC #1479 C3 rule 2): the remote cache's
# header and 「入口通不通」. (The old client's status bar read more here — the
# machine a window is on, hub_nodes / hub_limits rows, its window list — and those
# readers went with it, issue #3008.)
#
#   fleet_status_remote_head <sess>    → FSR_TS FSR_ME from global/remote_<sess>'s
#       header (fleet-hub-sessions.sh); rc 1 when there is no cache. FSR_TS is
#       when that cache was written — fleet_status_hub_ok's fallback clock.
#   fleet_status_hub_ok [fallback-ts]  → FSH_TS: when the hub last ANSWERED — the
#       epoch in global/hub_ok, which fleet-hub-sessions.sh writes on every
#       fleet_sessions round that stood (a 200 taken, a 304 restamped; issue
#       #1483, EPIC #1479 C4), else <fallback-ts> (a remote_<sess> #ts: a cache
#       from before hub_ok existed), else 0. THE one word on 「入口通不通」: the
#       alerts, the 看台 and the remote-row actions all read it here; none of
#       them probes the hub.
#   fleet_status_hub_lost <now>        → rc 0 = 失联: FSH_TS is older than
#       FLEET_HUB_SESSIONS_STALE (60 s), FSH_AGE the seconds since; rc 1 = fresh.
#   fleet_status_age <secs>            → FSA: `3m` / `2h` / `1d` for 失联 N.
#
# Everything is builtins: `read` over a US-separated file, no subshell (#888).

# shellcheck disable=SC2034  # the FSR_* / FSH_* / FSA results are read by the sourcing script
FLEET_STATUS_G="${FLEET_STATUS_G:-${TMPDIR:-/tmp/claude-fleet-$(id -u)}/.claude-dash/global}"
_FS_US=$'\x1f'

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

fleet_status_age() {
  local s="${1:-0}"
  case "$s" in ''|*[!0-9]*) s=0 ;; esac
  if   [ "$s" -lt 7200 ];  then FSA="$(( s / 60 ))m"
  elif [ "$s" -lt 172800 ]; then FSA="$(( s / 3600 ))h"
  else                            FSA="$(( s / 86400 ))d"; fi
}
