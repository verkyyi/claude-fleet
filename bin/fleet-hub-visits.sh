#!/bin/bash
# fleet-hub-visits.sh — count the trips back to the hub, and say why (issue #897).
#
# Nobody could tell how many times a day the operator lands back on the hub
# window, or what sent them there — so EPIC #894 (work between tasks without the
# hub) had no way to say whether it made those trips rarer. This is the meter:
# every arrival on the hub window appends ONE line to
#
#     logs/hub-visits-<session>.log        ts<TAB>from<TAB>cause
#
#   ts    — UTC, ISO-8601 to the second (2026-09-22T15:04:05Z)
#   from  — the window you came FROM: its `@wid` handle (issue #566) when it has
#           one, else its tmux `@N` window id; `-` when unknown (attach)
#   cause — WHY you landed there, one token:
#             f9 / home / g  the key that sent you (F9, the ⌂ tap, prefix g) —
#                            hub-zoom.sh / dash-zoom.sh stamp a one-shot
#                            `@hub_nav_via` session option before they jump
#             closed         the window you were on no longer exists: you closed a
#                            task and tmux dropped you on the hub
#             attach         a client attached with the hub as the current window
#             other          anything else (prefix n/p, a click, a script)
#           Later landings get a NEW cause token, never a new file (C4/C5 of
#           #894 write `home-sidebar` / `closed-next`) — `record` accepts any
#           lowercase [a-z0-9-] marker as the cause verbatim.
#
# The writer is the indexed `session-window-changed[73]` / `client-attached[73]`
# hooks in conf/tmux-attention.conf. Moving BETWEEN non-hub windows costs no fork:
# that branch only re-stamps `@hub_from`/`@hub_from_id` with tmux's own `set -F`.
# Only an arrival on the hub (a window holding the @dash pane) runs this script.
#
# Usage:
#   fleet-hub-visits.sh [--since 24h] [--session S] [--log FILE]
#       The table: visits in the window, grouped by cause. `--since` takes
#       N{s,m,h,d} (default 24h). No --session and no current tmux session ⇒ one
#       table per log file found. Reading rules (EPIC #894's metric table):
#       repeat arrivals within the SAME second count once; `attach` visits are
#       listed on their own line and NOT counted in the total — a reconnect or a
#       fleet-up is not a trip back.
#   fleet-hub-visits.sh --all ...
#       Every log under logs/, whatever session you are in.
#   fleet-hub-visits.sh --brief [--since 24h] [--session S | --all]
#       One line per fleet — `<session><TAB><count><TAB><top two causes>` — for
#       fleet-doctor's `hub` row. Prints nothing when there are no logs.
#   fleet-hub-visits.sh record <socket> <session> <marker> <from> <from-id>
#       The hook's writer. <marker> = the one-shot @hub_nav_via value, or
#       `attach`, or empty. Always exits 0 (run from a tmux hook).
#
# Knobs: FLEET_HUB_VISITS_MAX (default 5000) — the log is trimmed to its last N
# lines once it grows 10% past N, the same tail-and-move as needs.log/stuck.log.
# FLEET_HUB_VISITS_LOGDIR overrides logs/ (the selftest points it at a sandbox).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
LOGDIR="${FLEET_HUB_VISITS_LOGDIR:-$BIN/../logs}"
MAX="${FLEET_HUB_VISITS_MAX:-5000}"
case "$MAX" in ''|*[!0-9]*|0) MAX=5000 ;; esac

log_for() {   # $1=session → its log path (session names are sanitized; be safe anyway)
  printf '%s/hub-visits-%s.log' "$LOGDIR" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"
}

# ---- record (the hook's writer) ---------------------------------------------
if [ "${1:-}" = record ]; then
  sock="${2:-}" sess="${3:-}" marker="${4:-}" from="${5:-}" fromid="${6:-}"
  [ -n "$sess" ] || exit 0
  T() { if [ -n "$sock" ]; then tmux -S "$sock" "$@"; else tmux "$@"; fi; }
  case "$marker" in
    attach) cause=attach; from=- ;;
    *[!a-z0-9-]*|'') cause= ;;
    *) cause="$marker" ;;
  esac
  if [ -z "$cause" ]; then
    if [ -z "$fromid" ]; then
      cause=other
    elif T list-windows -t "=$sess" -F '#{window_id}' 2>/dev/null | grep -qx -- "$fromid"; then
      cause=other
    else
      cause=closed   # the window we came from is gone: a close dropped us here
    fi
  fi
  [ -n "$from" ] || from=-
  mkdir -p "$LOGDIR" 2>/dev/null || exit 0
  f=$(log_for "$sess")
  printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$from" "$cause" >> "$f" 2>/dev/null || exit 0
  n=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
  if [ "${n:-0}" -gt $(( MAX + MAX / 10 )) ]; then
    tail -n "$MAX" "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" 2>/dev/null
  fi
  exit 0
fi

# ---- summaries ----------------------------------------------------------------
since=24h sess= brief=0 logf= all=0
while [ $# -gt 0 ]; do
  case "$1" in
    --since)   since="${2:-}"; shift 2 ;;
    --since=*) since="${1#*=}"; shift ;;
    --session) sess="${2:-}"; shift 2 ;;
    --session=*) sess="${1#*=}"; shift ;;
    --log)     logf="${2:-}"; shift 2 ;;
    --brief)   brief=1; shift ;;
    --all)     all=1; shift ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) printf 'fleet-hub-visits: unknown argument: %s (try --help)\n' "$1" >&2; exit 2 ;;
  esac
done

case "$since" in
  *[0-9]s) secs=${since%s} ;;
  *[0-9]m) secs=$(( ${since%m} * 60 )) ;;
  *[0-9]h) secs=$(( ${since%h} * 3600 )) ;;
  *[0-9]d) secs=$(( ${since%d} * 86400 )) ;;
  *) secs= ;;
esac
case "${secs:-x}" in *[!0-9]*) printf 'fleet-hub-visits: --since wants N{s,m,h,d}, got %s\n' "$since" >&2; exit 2 ;; esac
c=$(( $(date +%s) - secs ))
cut=$(date -u -d "@$c" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$c" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
[ -n "$cut" ] || { printf 'fleet-hub-visits: could not compute the cutoff time\n' >&2; exit 2; }

# Which logs: --log wins, then --all, then --session, then the session we are
# in, else all of them.
files=()
if [ -n "$logf" ]; then
  files=("$logf")
else
  [ "$all" = 1 ] && sess=
  [ -n "$sess" ] || [ "$all" = 1 ] || sess=$(tmux display-message -p '#{session_name}' 2>/dev/null)
  if [ -n "$sess" ]; then
    files=("$(log_for "$sess")")
  else
    for f in "$LOGDIR"/hub-visits-*.log; do [ -f "$f" ] && files+=("$f"); done
  fi
fi

if [ "${#files[@]}" -eq 0 ]; then
  [ "$brief" = 1 ] && exit 0
  printf 'no hub-visit logs yet under %s — the hooks write one on the first hub arrival\n' "$LOGDIR"
  exit 0
fi

rc=0
for f in ${files[@]+"${files[@]}"}; do
  name=$(basename "$f" .log); name=${name#hub-visits-}
  if [ ! -f "$f" ]; then
    [ "$brief" = 1 ] && continue
    printf 'hub visits · %s · last %s: 0 (no log yet: %s)\n' "$name" "$since" "$f"
    continue
  fi
  awk -F'\t' -v cut="$cut" -v name="$name" -v since="$since" -v brief="$brief" '
    $1 >= cut && NF >= 3 {
      # repeat arrivals in one second = one visit (attach deduped on its own, so
      # an uncounted attach never swallows a real trip in the same second)
      key = $1 SUBSEP ($3 == "attach")
      if (key in seen) next
      seen[key] = 1
      if ($3 == "attach") { att++; next }
      if (!($3 in n)) order[++k] = $3
      n[$3]++; tot++
    }
    END {
      # rank causes by count, most first
      for (i = 1; i <= k; i++) for (j = i + 1; j <= k; j++)
        if (n[order[j]] > n[order[i]]) { t = order[i]; order[i] = order[j]; order[j] = t }
      if (brief == 1) {
        top = ""
        for (i = 1; i <= k && i <= 2; i++) top = top (i > 1 ? ", " : "") order[i] " x" n[order[i]]
        printf "%s\t%d\t%s\n", name, tot, (top == "" ? "-" : top)
        exit
      }
      printf "hub visits · %s · last %s: %d%s\n", name, since, tot, (att ? sprintf(" (+%d attach, not counted)", att) : "")
      if (tot + att == 0) exit
      printf "  %-14s %5s\n", "cause", "count"
      for (i = 1; i <= k; i++) printf "  %-14s %5d\n", order[i], n[order[i]]
      if (att) printf "  %-14s %5d  (not counted)\n", "attach", att
    }' "$f" || rc=1
done
exit "$rc"
