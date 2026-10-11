#!/usr/bin/env bash
# fleet-role-windows-selftest.sh — the old resident seats move onto the new marks in
# place (issue #3121, EPIC #3111 C10): bin/fleet-role-windows.sh on an ISOLATED tmux
# server (its own -L label) with a sandbox FLEET_CONF_DIR and a stub stopper
# (FLEET_ROLE_WINDOWS_STOP) in place of fleet-worker-stop.sh:
#   A  --dry-run names every change and changes nothing
#   B  the old orchestrator seat → @fleet_role worker + @fleet_role_def orchestrator,
#      ONE roles.held line naming it, reap keep; fleet_role_holder answers it; the
#      pane (the conversation) is the same process
#   C  the old steward seat → the stopper called once with `<fleet> fid:<its id>`
#   D  a driver with @fleet_role_def epic-driver and no @agent_def → @agent_def
#      epic-driver + @agent_spawn 1; one that has an @agent_def is left alone
#   E  a pinned window → reap keep once; a policy set after that is never undone
#   F  re-run: nothing left to change ("0 window(s) changed"), the stopper not called
#   G  a child (@origin orchestrator) and an ordinary window are not touched
#   H  a live install whose diskguard still reopens a seat (FLEET_INSTALL_ROOT):
#      the seats are left as they are, said in one line each; the rest proceeds
# tmux absent → SKIP. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX=$(command -v tmux) || { echo 'fleet-role-windows selftest: tmux absent — SKIP'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/role-win.XXXXXX")" || exit 2
L="rwn$$"
export FLEET_SKIP_GLOBAL_CONF=1 FLEET_UI_QUIET=1 TMPDIR="$WORK"
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR/fleets/$L"
printf 'FLEET_REPO=acme/app\nFLEET_MAIN=%s/main\n' "$WORK" > "$FLEET_CONF_DIR/fleets/$L/conf"
unset TMUX TMUX_PANE
HELD="$FLEET_CONF_DIR/global/roles.held"
STOPLOG="$WORK/stop.log"
printf '#!/bin/sh\necho "$@" >> %s\n' "$STOPLOG" > "$WORK/stop.sh"; chmod +x "$WORK/stop.sh"
export FLEET_ROLE_WINDOWS_STOP="$WORK/stop.sh"
export FLEET_INSTALL_ROOT="$WORK/live"; mkdir -p "$FLEET_INSTALL_ROOT/bin"   # a post-#3118 install: no revive

FAIL=0; CHECKS=0
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '      got: %s\n' "$2" >&2; }
ok() { CHECKS=$((CHECKS + 1)); }
tf() { "$REAL_TMUX" -L "$L" "$@"; }
cleanup() { "$REAL_TMUX" -L "$L" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

tf -f /dev/null new-session -d -s "$L" -n home -c "$WORK" 'while :; do sleep 300; done' 2>/dev/null \
  || { echo 'fleet-role-windows selftest: cannot start an isolated tmux server — SKIP' >&2; exit 0; }
tf set-window-option -t "$L:home" @fleet_role home

win() {
  local n="$1" w; shift
  w=$(tf new-window -d -P -F '#{window_id}' -n "$n" -c "$WORK" 'while :; do sleep 300; done')
  tf set-window-option -t "$w" @fleet_role worker
  while [ "$#" -ge 2 ]; do tf set-window-option -t "$w" "$1" "$2"; shift 2; done
  printf '%s' "$w"
}
opt() { tf show-options -wqv -t "$1" "$2"; }
run() { PATH="$(dirname "$REAL_TMUX"):$PATH" bash "$BIN/fleet-role-windows.sh" --socket "$L" "$@" 2>&1; }
FID1=11111111-1111-4111-8111-111111111111
FID2=22222222-2222-4222-8222-222222222222

orch=$(win Orchestrator @fleet_role orchestrator @fleet_id "$FID1" @pin 1)
stew=$(win steward @fleet_role steward @fleet_id "$FID2" @reap_policy keep)
drv=$(win 批次 @fleet_role_def epic-driver @origin orchestrator @reap_policy done:2h)
drv2=$(win 批次2 @fleet_role_def epic-driver @agent_def epic-driver)
pinned=$(win 常用 @pin 1 @reap_policy done:2h)
child=$(win child @issue 7 @origin orchestrator @reap_policy merged)
plain=$(win plain)
pid0=$(tf display-message -p -t "$orch" '#{pane_pid}')

# --- A dry run ----------------------------------------------------------------------
r=$(run --dry-run); rc=$?
ok; [ "$rc" = 0 ] && case "$r" in *"would change 4 window(s)"*) true ;; *) false ;; esac || fail "A: dry run names 4 changes" "$rc:$r"
ok; [ "$(opt "$orch" @fleet_role)" = orchestrator ] && [ ! -f "$HELD" ] && [ ! -f "$STOPLOG" ] \
    && [ -z "$(opt "$drv" @agent_def)" ] && [ "$(opt "$pinned" @reap_policy)" = done:2h ] \
  || fail "A: …and changes nothing" "$(opt "$orch" @fleet_role) $(cat "$HELD" "$STOPLOG" 2>/dev/null)"

# --- the real run ----------------------------------------------------------------------
r=$(run); rc=$?
ok; [ "$rc" = 0 ] && case "$r" in *"4 window(s) changed"*) true ;; *) false ;; esac || fail "the run changes 4 windows" "$rc:$r"

# B
ok; [ "$(opt "$orch" @fleet_role)" = worker ] && [ "$(opt "$orch" @fleet_role_def)" = orchestrator ] \
  || fail "B: the seat is a worker row holding the orchestrator mark" "$(opt "$orch" @fleet_role)/$(opt "$orch" @fleet_role_def)"
ok; [ "$(grep -c '^orchestrator	' "$HELD" 2>/dev/null)" = 1 ] && [ "$(grep '^orchestrator' "$HELD" | cut -f3,4)" = "$FID1	$orch" ] \
  || fail "B: one roles.held line names it" "$(cat "$HELD" 2>/dev/null)"
ok; [ "$(opt "$orch" @reap_policy)" = keep ] || fail "B: reap keep" "$(opt "$orch" @reap_policy)"
h=$(PATH="$(dirname "$REAL_TMUX"):$PATH" bash -c '. "$1/fleet-lib.sh"; fleet_role_holder orchestrator "$2"' _ "$BIN" "$L" 2>&1)
ok; [ "$h" = "$orch" ] || fail "B: fleet_role_holder answers the seat" "$h"
ok; [ "$(tf display-message -p -t "$orch" '#{pane_pid}')" = "$pid0" ] || fail "B: the same process runs in it"

# C
ok; [ "$(cat "$STOPLOG" 2>/dev/null)" = "$L fid:$FID2" ] || fail "C: the steward seat is stopped by its fleet id, once" "$(cat "$STOPLOG" 2>/dev/null)"

# D
ok; [ "$(opt "$drv" @agent_def)" = epic-driver ] && [ "$(opt "$drv" @agent_spawn)" = 1 ] \
  || fail "D: the driver gets @agent_def epic-driver + @agent_spawn 1" "$(opt "$drv" @agent_def)/$(opt "$drv" @agent_spawn)"
ok; [ -z "$(opt "$drv2" @agent_spawn)" ] || fail "D: a driver that has an @agent_def is left alone"

# E
ok; [ "$(opt "$pinned" @reap_policy)" = keep ] || fail "E: a pinned window gets reap keep" "$(opt "$pinned" @reap_policy)"
tf set-window-option -t "$pinned" @reap_policy done:1h

# F re-run
: > "$STOPLOG"; tf set-window-option -t "$stew" @fleet_role worker   # the stub does not close it
r=$(run); rc=$?
ok; [ "$rc" = 0 ] && case "$r" in *"0 window(s) changed"*) true ;; *) false ;; esac || fail "F: a re-run changes nothing" "$rc:$r"
ok; [ ! -s "$STOPLOG" ] || fail "F: …and stops nothing" "$(cat "$STOPLOG")"
ok; [ "$(opt "$pinned" @reap_policy)" = done:1h ] || fail "E: a policy set afterwards is never undone" "$(opt "$pinned" @reap_policy)"

# G
ok; [ "$(opt "$child" @reap_policy)" = merged ] && [ "$(opt "$child" @origin)" = orchestrator ] && [ -z "$(opt "$child" @agent_def)" ] \
  || fail "G: the child is untouched"
ok; [ -z "$(opt "$plain" @reap_policy)$(opt "$plain" @fleet_role_def)$(opt "$plain" @agent_def)" ] || fail "G: an ordinary window is untouched"

# H an old live install still reopening seats
printf 'w="$(bash "$BIN/fleet-orchestrator.sh" ensure "$s" 2>/dev/null)"\n' > "$FLEET_INSTALL_ROOT/bin/fleet-diskguard.sh"
o2=$(win Orchestrator2 @fleet_role orchestrator @fleet_id 33333333-3333-4333-8333-333333333333)
s2=$(win steward2 @fleet_role steward @fleet_id 44444444-4444-4444-8444-444444444444)
p2=$(win 常用2 @pin 1)
: > "$STOPLOG"
r=$(run); rc=$?
ok; [ "$rc" = 0 ] && [ "$(opt "$o2" @fleet_role)" = orchestrator ] && [ "$(opt "$s2" @fleet_role)" = steward ] && [ ! -s "$STOPLOG" ] \
  || fail "H: an old live install → the seats are left as they are" "$rc:$r:$(cat "$STOPLOG")"
ok; [ "$(printf '%s\n' "$r" | grep -c 'still reopens a closed seat')" = 2 ] || fail "H: …said once per seat" "$r"
ok; [ "$(opt "$p2" @reap_policy)" = keep ] || fail "H: …and the rest proceeds" "$(opt "$p2" @reap_policy)"

if [ "$FAIL" -gt 0 ]; then echo "fleet-role-windows selftest: $FAIL of $CHECKS checks FAILED"; exit 1; fi
echo "fleet-role-windows selftest: PASS ($CHECKS checks)"
