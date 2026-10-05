#!/bin/bash
# fleet-trace-lib.sh — the ⌂ latency trace (issue #1611): millisecond marks down
# the chain a ⌂ tap / F9 runs — hub-zoom.sh → fleet-sidebar.sh home →
# fleet-task-pick.sh --popup → dash-popup.sh → (the popup's command string) →
# the picker — so the hub-visits line the press ends on says where the time went:
#
#   …<TAB>home-pick<TAB>ms=238 conf:21 side:48 pick:61 popup:93 open:118 keys:131 rows:236 fzf:238 close:1904 done:1909
#
# `ms=` is the press as the SERVER saw it: from run-shell's first line (t0) to
# the picker handing the list to fzf (the `fzf` mark; the last mark when there
# is none). Every mark is cumulative ms from t0. The press → run-shell gap is the
# client's (Termius, the ssh link) and only a replay client sees it:
# bin/task-pick-latency-selftest.sh drives one and reads this column beside it.
#
# ONE env string rides the chain: FLEET_HOME_MS = the trace FILE
# (`$TMPDIR/.claude-dash/home-trace.<pid>.<n>`), one `<name>:<ms>` line per mark.
# A mark never waits for a clock: under macOS's bash 3.2 the stamp is a perl in
# the BACKGROUND (the mark costs one fork, ~1 ms, not perl's ~5 ms start; every
# stamp lands ~4 ms after its mark point, the same for all, so the deltas hold),
# and where the shell has $EPOCHREALTIME (bash ≥ 5) it is a builtin append. Off
# the ⌂ path there is NOTHING: a mark with no trace started is a no-op, so a
# hook's `fleet-sidebar.sh sync` or a prefix-Space picker never pays.
# FLEET_HOME_TRACE=0 switches it off (no file, no marks, no column).
#
#   fleet_home_trace_start   t0 = now: starts the trace (hub-zoom.sh's first line)
#   fleet_home_mark <name>   append `<name>:<ms>`; no-op without a trace
#   fleet_home_end <name>    the LAST mark of a shell: stamps, then waits for every
#                            stamp of this shell to land — call it before
#                            fleet_home_extra, which runs in a `$(…)` subshell
#                            and cannot wait for this shell's children
#   fleet_home_extra         prints the hub-visits column `ms=<N> <marks…>` and
#                            ENDS the trace (removes the file); nothing without one
#   fleet_home_trace_drop    ends a trace nothing will record (a refused popup)
#
# Sourced by scripts that do NOT load fleet-lib.sh (dash-popup.sh, the picker
# inside the popup), so it stays dependency-free and /bin/sh-parseable
# (hub-zoom.sh runs under sh). Ships with the fleet client (fleetclient/manifest):
# fleet-sidebar.sh and dash-popup.sh source it on every login.

_fleet_home_stamp() {   # <name> — append `<name>:<ms since the epoch>` to the trace file
  if [ -n "${EPOCHREALTIME:-}" ]; then
    local s=${EPOCHREALTIME%.*} f=${EPOCHREALTIME#*.}000
    printf '%s:%s\n' "$1" "$(( s * 1000 + 10#${f:0:3} ))" >> "$FLEET_HOME_MS" 2>/dev/null
  else
    ( perl -MTime::HiRes=time -e 'printf "%s:%d\n", $ARGV[0], time()*1000' "$1" >> "$FLEET_HOME_MS" 2>/dev/null ) &
  fi
}

fleet_home_trace_start() {
  [ "${FLEET_HOME_TRACE:-1}" != 0 ] || return 0
  # A trace already running (hub-zoom.sh --hub, exec'd back from the sidebar)
  # goes on; one whose file is gone (recorded and removed) is over — start anew.
  if [ -n "${FLEET_HOME_MS:-}" ] && [ -f "$FLEET_HOME_MS" ]; then return 0; fi
  local d="${TMPDIR:-/tmp}/.claude-dash"
  [ -d "$d" ] || mkdir -p "$d" 2>/dev/null || { FLEET_HOME_MS=''; return 0; }
  FLEET_HOME_MS="$d/home-trace.$$.$RANDOM"
  : > "$FLEET_HOME_MS" 2>/dev/null || { FLEET_HOME_MS=''; return 0; }
  export FLEET_HOME_MS
  _fleet_home_stamp t0
}

fleet_home_mark() {
  [ -n "${FLEET_HOME_MS:-}" ] && [ -f "$FLEET_HOME_MS" ] || return 0
  _fleet_home_stamp "$1"
}

fleet_home_end() {
  fleet_home_mark "$1"
  wait
}

fleet_home_trace_drop() {
  [ -n "${FLEET_HOME_MS:-}" ] || return 0
  wait   # this shell's own background stamps, so none recreates the file
  rm -f "$FLEET_HOME_MS" 2>/dev/null
  FLEET_HOME_MS=''
}

fleet_home_extra() {
  [ -n "${FLEET_HOME_MS:-}" ] && [ -f "$FLEET_HOME_MS" ] || return 0
  wait   # the stamps still landing from this shell
  local name ms t0='' head='' last='' marks='' sorted
  # Sorted by time: stamps from two processes a few ms apart may land out of order.
  sorted=$(sort -t: -k2,2n "$FLEET_HOME_MS" 2>/dev/null)
  rm -f "$FLEET_HOME_MS" 2>/dev/null
  FLEET_HOME_MS=''
  while IFS=: read -r name ms; do
    case "$ms" in ''|*[!0-9]*) continue ;; esac
    [ -n "$name" ] || continue
    if [ -z "$t0" ]; then
      [ "$name" = t0 ] || continue
      t0=$ms; continue
    fi
    [ "$name" != t0 ] || continue
    last=$(( ms - t0 ))
    [ "$name" != fzf ] || head=$last
    marks="$marks${marks:+ }$name:$last"
  done <<TRACE
$sorted
TRACE
  [ -n "$t0" ] && [ -n "$marks" ] || return 0
  [ -n "$head" ] || head=$last
  printf 'ms=%s %s' "$head" "$marks"
}
