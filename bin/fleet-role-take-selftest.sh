#!/usr/bin/env bash
# fleet-role-take-selftest.sh — take_role: any session that binds no issue takes the
# orchestrator role, one holder per role (issue #3114, EPIC #3111 C3).
#
# Drives bin/fleet-role-take.sh and fleet-lib.sh's fleet_role_holder /
# fleet_win_for_key / fleet_spawn_refused on an ISOLATED tmux server (its own -L
# label; bare `tmux` reaches it through $TMUX), with a sandbox FLEET_CONF_DIR:
#   A  a scratch takes it: exit 0, `@fleet_role_def orchestrator`, ONE line in
#      global/roles.held; fleet_win_for_key orchestrator answers the scratch; the
#      scratch may spawn; taking it again is 0 「already」
#   B  a second scratch: exit 4, the holder named; nothing changes
#   C  a window bound to an issue: exit 3, no mark, no line
#   D  --steal: the second takes it, the first loses its mark, one line names it
#   E  --drop from a window that does not hold it: exit 4; from the holder: 0,
#      mark and line gone, --who exit 1
#   F  a pin grants nothing: a pinned `guide` that took no role is refused a spawn;
#      once it takes the role it may
#   G  the holder's window goes: its line names nobody — a new taker needs no --steal
#   H  the old seat (`@fleet_role orchestrator`, # compat-1v) answers while nobody
#      took the role, and a taker is told it holds it (exit 4)
# tmux absent → SKIP. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX=$(command -v tmux) || { echo 'fleet-role-take selftest: tmux absent — SKIP'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/role-take.XXXXXX")" || exit 2
L="rtk$$"
export FLEET_SKIP_GLOBAL_CONF=1 FLEET_UI_QUIET=1 TMPDIR="$WORK"
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR/fleets/$L"
printf 'FLEET_REPO=acme/app\nFLEET_MAIN=%s/main\n' "$WORK" > "$FLEET_CONF_DIR/fleets/$L/conf"
unset TMUX TMUX_PANE FLEET_ALLOW_WORKER_SPAWN
HELD="$FLEET_CONF_DIR/global/roles.held"

FAIL=0; CHECKS=0
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '      got: %s\n' "$2" >&2; }
ok() { CHECKS=$((CHECKS + 1)); }
tf() { "$REAL_TMUX" -L "$L" "$@"; }
cleanup() { "$REAL_TMUX" -L "$L" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

tf -f /dev/null new-session -d -s "$L" -n home -c "$WORK" 'while :; do sleep 300; done' 2>/dev/null \
  || { echo 'fleet-role-take selftest: cannot start an isolated tmux server — SKIP' >&2; exit 0; }
INTMUX="$(tf display-message -p '#{socket_path}'),1,0"
tf set-window-option -t "$L:home" @fleet_role home

# win <name> [@opt val …] → a window id; worker windows unless told otherwise
win() {
  local n="$1" w; shift
  w=$(tf new-window -d -P -F '#{window_id}' -n "$n" -c "$WORK" 'while :; do sleep 300; done')
  tf set-window-option -t "$w" @fleet_role worker
  while [ "$#" -ge 2 ]; do tf set-window-option -t "$w" "$1" "$2"; shift 2; done
  printf '%s' "$w"
}
pane() { tf display-message -p -t "$1" '#{pane_id}'; }
take() { local w="$1"; shift; TMUX="$INTMUX" TMUX_PANE="$(pane "$w")" bash "$BIN/fleet-role-take.sh" orchestrator "$@" 2>&1; }
lib() { local p="$1"; shift; TMUX="$INTMUX" TMUX_PANE="$p" bash -c '. "$1/fleet-lib.sh"; shift; eval "$*"' _ "$BIN" "$@"; }
def() { tf display-message -p -t "$1" '#{@fleet_role_def}'; }
lines() { cat "$HELD" 2>/dev/null | grep -c '^orchestrator	'; }

s1=$(win scratch-1 @worktree "$WORK/app-scratch-1")
s2=$(win scratch-2 @worktree "$WORK/app-scratch-2")
wi=$(win issue-7 @issue 7 @repo acme/app)

# --- A a scratch takes it --------------------------------------------------------
r=$(take "$s1"); rc=$?
ok; [ "$rc" = 0 ] && [ "$(def "$s1")" = orchestrator ] && [ "$(lines)" = 1 ] \
  || fail "A: the scratch takes the role (exit 0, marked, one line)" "$rc:$r:$(def "$s1"):$(cat "$HELD" 2>/dev/null)"
ok; [ "$(cut -f4 "$HELD")" = "$s1" ] && [ -n "$(cut -f3 "$HELD")" ] || fail "A: the line names the window and its fleet id" "$(cat "$HELD")"
r=$(lib '' fleet_win_for_key orchestrator); ok; [ "$r" = "$s1" ] || fail "A: fleet_win_for_key orchestrator answers the holder" "$r"
lib "$(pane "$s1")" fleet_spawn_refused; rc=$?; ok; [ "$rc" = 1 ] || fail "A: the holder may spawn" "$rc"
lib "$(pane "$s2")" fleet_spawn_refused; rc=$?; ok; [ "$rc" = 0 ] || fail "A: a scratch that took nothing may not" "$rc"
r=$(take "$s1"); rc=$?; ok; [ "$rc" = 0 ] && case "$r" in *already*) true ;; *) false ;; esac || fail "A: taking it again is 0 「already」" "$rc:$r"
ok; [ "$(lines)" = 1 ] || fail "A: …still one line" "$(cat "$HELD")"

# --- B a second taker is told who holds it ---------------------------------------
r=$(take "$s2"); rc=$?
ok; [ "$rc" = 4 ] && case "$r" in *"$s1"*scratch-1*) true ;; *) false ;; esac || fail "B: the second taker exits 4, the holder named" "$rc:$r"
ok; [ -z "$(def "$s2")" ] && [ "$(cut -f4 "$HELD")" = "$s1" ] || fail "B: …and nothing changed" "$(def "$s2") $(cat "$HELD")"
r=$(TMUX="$INTMUX" bash "$BIN/fleet-role-take.sh" orchestrator --who 2>&1); rc=$?
ok; [ "$rc" = 0 ] && case "$r" in *"$s1"*) true ;; *) false ;; esac || fail "B: --who names the holder" "$rc:$r"

# --- C an issue window cannot ---------------------------------------------------
r=$(take "$wi"); rc=$?
ok; [ "$rc" = 3 ] && [ -z "$(def "$wi")" ] && [ "$(cut -f4 "$HELD")" = "$s1" ] || fail "C: an issue window exits 3, unmarked" "$rc:$r"
r=$(TMUX="$INTMUX" TMUX_PANE="$(pane "$s1")" bash "$BIN/fleet-role-take.sh" chef 2>&1); rc=$?
ok; [ "$rc" = 2 ] || fail "C: an unknown role is usage (2)" "$rc:$r"

# --- D --steal ------------------------------------------------------------------
r=$(take "$s2" --steal); rc=$?
ok; [ "$rc" = 0 ] && [ "$(def "$s2")" = orchestrator ] && [ -z "$(def "$s1")" ] \
  || fail "D: --steal moves the mark" "$rc:$r:[$(def "$s1")][$(def "$s2")]"
ok; [ "$(lines)" = 1 ] && [ "$(cut -f4 "$HELD")" = "$s2" ] || fail "D: one line, naming the new holder" "$(cat "$HELD")"
r=$(lib '' fleet_win_for_key orchestrator); ok; [ "$r" = "$s2" ] || fail "D: the key follows the holder" "$r"
lib "$(pane "$s1")" fleet_spawn_refused; rc=$?; ok; [ "$rc" = 0 ] || fail "D: the old holder may no longer spawn" "$rc"

# --- E --drop ------------------------------------------------------------------
r=$(take "$s1" --drop); rc=$?; ok; [ "$rc" = 4 ] && [ "$(def "$s2")" = orchestrator ] || fail "E: --drop from a non-holder exits 4, changes nothing" "$rc:$r"
r=$(take "$s2" --drop); rc=$?
ok; [ "$rc" = 0 ] && [ -z "$(def "$s2")" ] && [ "$(lines)" = 0 ] || fail "E: the holder drops it (mark + line gone)" "$rc:$r:$(cat "$HELD")"
TMUX="$INTMUX" bash "$BIN/fleet-role-take.sh" orchestrator --who >/dev/null 2>&1; rc=$?
ok; [ "$rc" = 1 ] || fail "E: --who with nobody exits 1" "$rc"
lib '' fleet_win_for_key orchestrator >/dev/null 2>&1; rc=$?; ok; [ "$rc" = 1 ] || fail "E: nobody answers orchestrator" "$rc"

# --- F a pin grants nothing -----------------------------------------------------
wg=$(win guide @pin 1 @norepo 1)
lib "$(pane "$wg")" fleet_spawn_refused; rc=$?; ok; [ "$rc" = 0 ] || fail "F: a pinned guide that took no role is refused a spawn" "$rc"
r=$(take "$wg"); rc=$?; ok; [ "$rc" = 0 ] || fail "F: the guide takes the role" "$rc:$r"
lib "$(pane "$wg")" fleet_spawn_refused; rc=$?; ok; [ "$rc" = 1 ] || fail "F: …then it may spawn" "$rc"

# --- G the holder's window goes ------------------------------------------------
tf kill-window -t "$wg"
lib '' fleet_win_for_key orchestrator >/dev/null 2>&1; rc=$?; ok; [ "$rc" = 1 ] || fail "G: a line whose window went names nobody" "$rc"
r=$(take "$s1"); rc=$?; ok; [ "$rc" = 0 ] && [ "$(cut -f4 "$HELD")" = "$s1" ] || fail "G: a new taker needs no --steal" "$rc:$r"
take "$s1" --drop >/dev/null

# --- H the old seat (compat-1v) -------------------------------------------------
wo=$(win orchestrator @norepo 1); tf set-window-option -t "$wo" @fleet_role orchestrator
r=$(lib '' fleet_win_for_key orchestrator); ok; [ "$r" = "$wo" ] || fail "H: with nobody holding it the old seat answers" "$r"
r=$(take "$s2"); rc=$?
ok; [ "$rc" = 4 ] && case "$r" in *"$wo"*) true ;; *) false ;; esac || fail "H: a taker is told the old seat holds it" "$rc:$r"
r=$(take "$s2" --steal); rc=$?
r2=$(lib '' fleet_win_for_key orchestrator)
ok; [ "$rc" = 0 ] && [ "$r2" = "$s2" ] || fail "H: --steal from the old seat: the record wins" "$rc:$r:$r2"

if [ "$FAIL" -gt 0 ]; then
  printf 'fleet-role-take selftest: %d of %d checks FAILED\n' "$FAIL" "$CHECKS" >&2
  exit 1
fi
printf 'fleet-role-take selftest: %d checks passed (take · second 4 · issue 3 · steal · drop · pin grants nothing · gone holder · old seat)\n' "$CHECKS"
