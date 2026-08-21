#!/bin/bash
# orphan-proc-reap-selftest.sh — hermetic tests for fleet_reap_worktree_procs'
# SCRATCHPAD matcher and its AGE GATE (issue #469).
#
# The gap this guards: Claude Code's per-session scratch dir does NOT live inside
# the worktree. It sits at
#   …/claude-<uid>/<worktree-path-with-/-turned-to->/<session-uuid>/scratchpad/
# so a mock/dev server started there has neither the worktree in its argv nor its
# cwd inside it — the pre-#469 matchers both missed it, and eleven such processes
# were found alive two days after their window had closed. The reaper now matches
# that mangled component too, delimited on BOTH sides so `…-scratch-1/` cannot
# swallow `…-scratch-11/` (the fleet allocates those names side by side).
#
# The age gate is the safety half: matcher (1) greps argv, and worktree-autoclean
# now sweeps KEPT worktrees hourly on a live machine, so a transient command that
# merely NAMES the path (a `grep`, an `ls`) must never be reaped.
#
# Asserts:
#   • SCRATCHPAD  a process whose cwd is in the session scratchpad (relative argv)
#                 is found for its worktree — the case both old matchers missed.
#   • WORKTREE    a process whose cwd is inside the worktree is still found (#151).
#   • DELIMITED   `wt-scratch-1` does NOT match `wt-scratch-11`'s scratchpad.
#   • SYMLINKED   a worktree reached through a SYMLINK (so the as-passed and the
#                 canonical path mangle differently) still matches, and the matcher
#                 stays SILENT — macOS awk rejects a literal newline in a -v value,
#                 which once killed the whole cwd matcher without failing anything.
#   • AGE GATE    a brand-new process is skipped when minage > 0, found when 0.
#   • KILL        kill mode actually reaps the scratchpad orphan.
#   • REFUSAL     a broad root (/, $HOME) is still refused, gate untouched.
#   • AGE PARSE   fleet_proc_age reads every POSIX etime shape.
#
# No tmux, no network, no git: a temp dir stands in for the worktree and a real
# `sleep` stands in for the orphan. lsof (or /proc) absent → SKIP cleanly.
# Exit 0 = pass; non-zero = fail.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
LIB="$BIN/fleet-lib.sh"
[ -f "$LIB" ] || { printf 'selftest: %s missing\n' "$LIB" >&2; exit 2; }
if ! command -v lsof >/dev/null 2>&1 && [ ! -d /proc ]; then
  printf 'selftest: neither lsof nor /proc — SKIP\n' >&2; exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/orphan-reap.XXXXXX")" || exit 2
# Physical path: lsof reports the resolved form (macOS /var → /private/var), and the
# mangled scratchpad name must be derived from the same string the reaper computes.
WORK="$(cd "$WORK" && pwd -P)"

PROBES=""
cleanup() { [ -n "$PROBES" ] && kill $PROBES 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

# shellcheck source=/dev/null
. "$LIB"

# mangled scratchpad dir for a worktree path, exactly as Claude Code names it
padfor() { printf '%s/pads/%s/%s/scratchpad' "$WORK" "$(printf '%s' "$1" | tr '/' '-')" "${2:-11111111-2222-3333-4444-555555555555}"; }

# Start a detached `sleep` with cwd inside $1 — RELATIVE argv on purpose, so only
# the cwd matcher can see it (this is the shape the real orphans had). Sets
# PROBE_PID rather than printing it: a command substitution would hold the pipe
# open until the backgrounded sleep exited, so the probe would already be dead by
# the time the caller got its pid. The >/dev/null on the job is part of that same
# rail — an inherited stdout is what would keep the substitution blocked.
PROBE_PID=""
probe() {   # $1=dir → sets $PROBE_PID
  mkdir -p "$1" || fail "cannot create $1"
  ( cd "$1" && exec sleep 45 ) >/dev/null 2>&1 &
  PROBE_PID=$!
  PROBES="$PROBES $PROBE_PID"
  # give the fork a beat to land its cwd before lsof snapshots it
  local i=0; while [ "$i" -lt 30 ]; do
    [ "$(lsof -a -d cwd -p "$PROBE_PID" -Fn 2>/dev/null | grep -c '^n')" -gt 0 ] && break
    i=$((i+1)); sleep 0.1
  done
}

WT="$WORK/wt-scratch-1"
WT11="$WORK/wt-scratch-11"
mkdir -p "$WT" "$WT11"

# --- SCRATCHPAD: the case both pre-#469 matchers missed ----------------------
pad="$(padfor "$WT")"
probe "$pad"; p_pad="$PROBE_PID"
got="$(fleet_reap_worktree_procs "$WT" dry)"
case " $got " in
  *" $p_pad "*) ok "a process in the session scratchpad is found for its worktree" ;;
  *) fail "scratchpad orphan $p_pad not found (cwd=$pad)" "$got" ;;
esac

# --- WORKTREE: the #151 matcher is untouched ---------------------------------
probe "$WT/sub"; p_wt="$PROBE_PID"
got="$(fleet_reap_worktree_procs "$WT" dry)"
case " $got " in
  *" $p_wt "*) ok "a process with cwd inside the worktree is still found (#151)" ;;
  *) fail "worktree-cwd orphan $p_wt not found — #151 regressed" "$got" ;;
esac

# --- DELIMITED: -scratch-1 must not swallow -scratch-11 ----------------------
probe "$(padfor "$WT11")"; p_11="$PROBE_PID"
got="$(fleet_reap_worktree_procs "$WT" dry)"
case " $got " in
  *" $p_11 "*) fail "wt-scratch-1 swallowed wt-scratch-11's scratchpad orphan $p_11" "$got" ;;
  *) ok "the mangled match is delimited — -scratch-1 does not swallow -scratch-11" ;;
esac
got="$(fleet_reap_worktree_procs "$WT11" dry)"
case " $got " in
  *" $p_11 "*) ok "wt-scratch-11 finds its own scratchpad orphan" ;;
  *) fail "wt-scratch-11 did not find its own orphan $p_11" "$got" ;;
esac

# --- SYMLINKED: the as-passed and canonical forms mangle differently ---------
# On macOS a $TMPDIR worktree is reached as /var/… but resolves to /private/var/…,
# so the reaper carries TWO mangled patterns. Joining them for awk with a literal
# newline made awk abort ("newline in string") and silently drop every cwd match —
# the failure mode this assertion exists to pin. stderr must stay empty.
ln -s "$WT" "$WORK/wtlink" || fail "cannot create the symlink"
err="$WORK/symlink.err"
got="$(fleet_reap_worktree_procs "$WORK/wtlink" dry 2>"$err")"
[ -s "$err" ] && fail "the matcher wrote to stderr for a symlinked worktree" "$(cat "$err")"
case " $got " in
  *" $p_pad "*) ok "a symlink-reached worktree still finds its scratchpad orphan, silently" ;;
  *) fail "symlinked worktree lost the scratchpad orphan $p_pad" "$got" ;;
esac

# --- AGE GATE ----------------------------------------------------------------
got="$(fleet_reap_worktree_procs "$WT" dry 2 600)"
case " $got " in
  *" $p_pad "*) fail "the age gate did not skip a brand-new process $p_pad" "$got" ;;
  *) ok "minage>0 skips a process younger than the gate" ;;
esac
got="$(fleet_reap_worktree_procs "$WT" dry 2 0)"
case " $got " in
  *" $p_pad "*) ok "minage=0 leaves the gate off (prune-time behaviour unchanged)" ;;
  *) fail "minage=0 changed the unfiltered result" "$got" ;;
esac

# --- REFUSAL: a broad root is still refused ----------------------------------
for root in / "$HOME" /tmp; do
  case "$(fleet_reap_worktree_procs "$root" dry)" in
    refused*) : ;;
    *) fail "a broad root was NOT refused: $root" ;;
  esac
done
ok "broad roots (/ \$HOME /tmp) are still refused outright"

# --- KILL: the scratchpad orphan is actually reaped --------------------------
out="$(fleet_reap_worktree_procs "$WT" kill 2)"
case "$out" in reaped:*) : ;; *) fail "kill mode reported no reap" "$out" ;; esac
kill -0 "$p_pad" 2>/dev/null && fail "scratchpad orphan $p_pad survived kill mode" "$out"
kill -0 "$p_wt"  2>/dev/null && fail "worktree orphan $p_wt survived kill mode" "$out"
ok "kill mode reaps both the worktree and the scratchpad orphan"
kill -0 "$p_11" 2>/dev/null || fail "the neighbouring wt-scratch-11 orphan was killed too"
ok "the neighbouring worktree's orphan is left running"

# --- AGE PARSE: every POSIX etime shape --------------------------------------
age_of() { printf '%s' "$1" | awk -F'[-:]' '
  { if (NF==4)      s=$1*86400 + $2*3600 + $3*60 + $4
    else if (NF==3) s=$1*3600 + $2*60 + $3
    else if (NF==2) s=$1*60 + $2
    else            s=0
    printf "%d\n", s }'; }
[ "$(age_of '00:07')"     = 7       ] || fail "etime mm:ss parsed wrong"
[ "$(age_of '02:30')"     = 150     ] || fail "etime mm:ss (minutes) parsed wrong"
[ "$(age_of '01:00:00')"  = 3600    ] || fail "etime hh:mm:ss parsed wrong"
[ "$(age_of '2-03:00:00')" = 183600 ] || fail "etime dd-hh:mm:ss parsed wrong"
ok "fleet_proc_age parses mm:ss / hh:mm:ss / dd-hh:mm:ss"
[ "$(fleet_proc_age 999999)" = 0 ] || fail "a dead pid must read as age 0 (gate fails closed)"
[ "$(fleet_proc_age "$$")" -ge 0 ] || fail "fleet_proc_age failed on a live pid"
ok "fleet_proc_age reads 0 for a dead pid — an age gate fails closed"

printf 'selftest OK: %s checks — scratchpad orphans are reaped, neighbours and fresh procs are not (issue #469)\n' "$pass"
