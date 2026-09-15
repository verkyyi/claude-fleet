#!/bin/bash
# fleet-loadgen.sh — bounded, SELF-CLEANING CPU load for a worker's experiment.
#
# WHY: load experiments are legitimate and necessary — #691/#693 exist precisely
# to ask "does this selftest's real-time assertion still hold on a busy box?".
# What is not legitimate is the hand-written form every worker reaches for:
#
#     for i in 1 2 3 4 5 6 7 8; do (while :; do :; done) & done; BURN="$(jobs -p)"
#     trap 'kill $BURN 2>/dev/null' EXIT
#     …experiment…
#     kill $BURN
#
# On 2026-09-15 (issue #697) that exact snippet leaked 8 zsh spinners at ~70% CPU
# each. They survived 3h20m as PPID=1 orphans and drove the machine to load 108 —
# `ps` and `uptime` started timing out, both fleet daemons wedged, and the
# orphan-rate evidence in a DIFFERENT issue (#682) was silently poisoned by it.
# The cleanup never ran: the EXIT trap did not fire and the trailing kill was
# never reached. Every fleet orphan defense missed it, because all of them are
# keyed on a worktree or a pane and these belonged to neither.
#
# The lesson is not "trap harder". A trap lives in the PARENT — SIGKILL the
# parent, close the pane, OOM-kill the shell, and the trap is simply not there
# any more. So this tool moves the deadline INTO EACH BURNER, twice over:
#
#   1. a kernel alarm — `perl -e 'alarm N; exec …'`. alarm(2) is preserved across
#      execve(2), so the timer is armed by the kernel against the burner itself
#      before bash ever starts. Nothing in userspace can lose it.
#   2. a `$SECONDS` bound inside the burn loop — the belt under the alarm, for a
#      host with no perl.
#
# Both live in the burner's own process. Kill this script however you like: the
# burners still expire on schedule. The parent's own trap is kept, but purely as
# a FAST PATH so ^C stops the load now instead of at the deadline — it is not
# what makes the tool safe.
#
# Usage:
#   fleet-loadgen.sh <n> [secs]              apply load for secs, wait, clean up
#   fleet-loadgen.sh <n> [secs] -- cmd…      run cmd UNDER the load; burners stop
#                                            the moment cmd exits (exit = cmd's)
#   fleet-loadgen.sh <n> [secs] --detach     start and return; burners self-expire
#   fleet-loadgen.sh --status [tag]          list this user's live burners
#   fleet-loadgen.sh --stop [tag]            kill them now (all, or one tag's)
#   fleet-loadgen.sh --help
#
#   --tag <t>   label this batch (default: pid-epoch) so --status/--stop can
#               select it. The tag is in each burner's argv, which is also what
#               makes a leaked burner identifiable in `ps` — and what
#               bin/fleet-diskguard.sh's orphan watchdog fingerprints.
#
# Defaults + caps (a typo must not be able to ask for 8 hours of load):
#   secs                       default 60
#   FLEET_LOADGEN_MAX_PROCS    default 64   refuse more burners than this
#   FLEET_LOADGEN_MAX_SECS     default 900  refuse a longer deadline than this
#
# Exit: 0 ok · 2 bad usage/over a cap · otherwise the `--` command's status.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"

MAX_PROCS="${FLEET_LOADGEN_MAX_PROCS:-64}"
MAX_SECS="${FLEET_LOADGEN_MAX_SECS:-900}"

# The marker every burner carries in its argv. Deliberately distinctive: the `#`
# keeps it from matching this script's own command line, so --status/--stop can
# never see themselves. bin/fleet-diskguard.sh matches the same literal.
MARK='FLEET_LOADGEN_BURNER'

die() { printf 'fleet-loadgen: %s\n' "$1" >&2; exit "${2:-2}"; }
usage() { sed -n '2,55p' "$0"; }

# Every live burner of this user, as "pid ppid pcpu etime command". Reads ps
# directly rather than pgrep: it is portable across macOS/Linux without flag
# archaeology, and it hands us etime — which is what says "this one has been
# burning for three hours" at a glance. $1 (optional) filters by tag.
burners() {   # [tag] → rows on stdout
  # The marker is the LAST argv token of a burner, so an untagged match is a
  # plain substring but a tagged one must end at a token boundary — else tag
  # `t1` would also select `t10`.
  local tag="${1:-}" pat="$MARK#" me; me="$(id -un 2>/dev/null)"
  [ -n "$tag" ] && pat="$MARK#$(printf '%s' "$tag" | sed 's/[.]/\\./g')\$"
  # `-Ao` + an awk user filter rather than `ps -u`: -A and -u fight each other
  # differently on BSD and procps, and this needs no flag archaeology. The marker
  # match is done INSIDE the same awk rather than by a downstream grep — a grep
  # carries the pattern in its own argv and would otherwise list itself.
  ps -Ao pid=,user=,ppid=,pcpu=,etime=,command= 2>/dev/null \
    | awk -v me="$me" -v self="$$" -v pat="$pat" '
        $2==me && $1!=self && $3!=self && $0 ~ pat {
          printf "%s %s %s %s", $1, $3, $4, $5;
          for (i=6; i<=NF; i++) printf " %s", $i; print "" }' || true
}

mode=run; tag=""; n=""; secs=""
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)   usage; exit 0 ;;
    --status)    mode=status; shift; tag="${1:-}"; break ;;
    --stop)      mode=stop;   shift; tag="${1:-}"; break ;;
    --detach)    mode=detach; shift ;;
    --tag)       shift; tag="${1:-}"; [ -n "$tag" ] || die "--tag needs a value"; shift ;;
    --)          shift; args=("$@"); mode=cmd; break ;;
    -*)          die "unknown option '$1' (see --help)" ;;
    *)           if [ -z "$n" ]; then n="$1"; elif [ -z "$secs" ]; then secs="$1";
                 else die "unexpected argument '$1'"; fi; shift ;;
  esac
done

case "$mode" in
  status)
    rows="$(burners "$tag")"
    if [ -z "$rows" ]; then
      echo "fleet-loadgen: no live burners${tag:+ for tag '$tag'}"
    else
      printf '%-8s %-8s %6s %10s  %s\n' PID PPID '%CPU' ELAPSED TAG
      printf '%s\n' "$rows" | while read -r p pp pc et rest; do
        # The tag is the token right after the marker in the burner's argv.
        t="$(printf '%s' "$rest" | tr ' ' '\n' | grep -F "$MARK#" | head -1 | sed "s/.*$MARK#//")"
        # PPID 1 is the whole point of this tool existing: say it loudly.
        printf '%-8s %-8s %5s%% %10s  %s%s\n' "$p" "$pp" "$pc" "$et" "$t" \
          "$([ "$pp" = 1 ] && echo '   ⚠ ORPHANED (PPID=1)')"
      done
    fi
    exit 0 ;;
  stop)
    pids="$(burners "$tag" | awk '{print $1}')"
    if [ -z "$pids" ]; then echo "fleet-loadgen: nothing to stop${tag:+ for tag '$tag'}"; exit 0; fi
    # shellcheck disable=SC2086  # intentional word-split: a pid list
    kill -TERM $pids 2>/dev/null
    sleep 1
    for p in $pids; do kill -0 "$p" 2>/dev/null && kill -KILL "$p" 2>/dev/null; done
    echo "fleet-loadgen: stopped $(printf '%s\n' "$pids" | wc -l | tr -d ' ') burner(s)${tag:+ for tag '$tag'}"
    exit 0 ;;
esac

[ -n "$n" ] || { usage; exit 2; }
case "$n" in ''|*[!0-9]*) die "burner count must be a positive integer, got '$n'" ;; esac
[ "$n" -ge 1 ] || die "burner count must be >= 1"
[ "$n" -le "$MAX_PROCS" ] || die "refusing $n burners — cap is FLEET_LOADGEN_MAX_PROCS=$MAX_PROCS"
secs="${secs:-60}"
case "$secs" in ''|*[!0-9]*) die "seconds must be a positive integer, got '$secs'" ;; esac
[ "$secs" -ge 1 ] || die "seconds must be >= 1"
[ "$secs" -le "$MAX_SECS" ] || die "refusing a ${secs}s deadline — cap is FLEET_LOADGEN_MAX_SECS=$MAX_SECS"
[ -n "$tag" ] || tag="$$-$(date +%s)"
case "$tag" in *[!A-Za-z0-9._-]*) die "--tag must be [A-Za-z0-9._-], got '$tag'" ;; esac

# The burn loop. Pure builtins — no forks, so N burners are N processes, not a
# fork storm. The inner counter does the burning; the outer `$SECONDS` test is
# deadline #2 (see the header), checked once per ~5k arithmetic ops rather than
# once per op. `unset TMOUT` keeps bash from arming an alarm of its own over the
# kernel one we exec'd in with.
BURN_SRC='unset TMOUT; SECONDS=0; while [ "$SECONDS" -lt '"$secs"' ]; do i=0; while [ "$i" -lt 5000 ]; do i=$((i+1)); done; done'

PIDS=""
start_burners() {
  local i=0
  while [ "$i" -lt "$n" ]; do
    i=$((i+1))
    if command -v perl >/dev/null 2>&1; then
      # Deadline #1: alarm(2) armed BEFORE the exec, preserved across it, owned by
      # the burner's own process. This is the one that survives a SIGKILLed parent.
      perl -e 'alarm shift; exec @ARGV or exit 127' "$secs" \
        bash -c "$BURN_SRC" "$MARK#$tag" >/dev/null 2>&1 &
    else
      bash -c "$BURN_SRC" "$MARK#$tag" >/dev/null 2>&1 &
    fi
    PIDS="$PIDS $!"
  done
}

# Fast path only — see the header. If this never runs, the burners still expire.
stop_burners() {
  [ -n "$PIDS" ] || return 0
  # shellcheck disable=SC2086
  kill -TERM $PIDS 2>/dev/null
  local p
  for p in $PIDS; do kill -0 "$p" 2>/dev/null && kill -KILL "$p" 2>/dev/null; done
  PIDS=""
}

start_burners
printf 'fleet-loadgen: %d burner(s), tag=%s, hard deadline %ds%s\n' \
  "$n" "$tag" "$secs" "$(command -v perl >/dev/null 2>&1 || echo ' (no perl — $SECONDS bound only)')" >&2

case "$mode" in
  detach)
    # Detached is safe here in a way the hand-written form never was: the burners
    # carry their own deadline, so "I forgot about it" costs $secs, not 3h20m.
    printf 'fleet-loadgen: detached — they expire on their own in %ds; `%s --status %s` to watch, `--stop %s` to end early\n' \
      "$secs" "$0" "$tag" "$tag" >&2
    exit 0 ;;
  cmd)
    trap 'stop_burners' EXIT INT TERM
    [ "${#args[@]}" -gt 0 ] || die "-- needs a command to run under the load"
    "${args[@]}"; rc=$?
    stop_burners
    trap - EXIT INT TERM
    exit "$rc" ;;
  *)
    trap 'stop_burners; exit 130' INT TERM
    trap 'stop_burners' EXIT
    wait
    exit 0 ;;
esac
