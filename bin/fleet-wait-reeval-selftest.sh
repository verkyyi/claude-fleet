#!/bin/bash
# fleet-wait-reeval-selftest.sh — an IDLE window's "still waiting?" is re-asked (issue #1376).
#
# The Stop hook decides `looping` + @claude_wait once (#1370); fleet-wait-reeval.sh
# re-asks it for windows that will not Stop again on their own. On an ISOLATED tmux
# socket (PATH-shim, never the live server) with a fake `claude`:
#   A. children  — an idle `done` parent whose child is unfinished → looping +
#                  children; every child finished → done, the option removed; a
#                  grandchild finishing cascades through its parent in one run
#   B. untouched — working / needs / a sleep transition / a reasonless looping (the
#                  classifier's screen read) are never rewritten
#   C. bg        — a Bash-tool job under an idle agent → looping + bg; it ends → done
#   D. counts    — the summary line (`changed= windows= fleets=`), --dry-run writes
#                  nothing, FLEET_WAIT_REEVAL=0 is off, the via=reeval log line
#   E. parent-of — a child's Stop re-asks its parent at once (set-claude-state.sh)
#   F. degenerate— no children, no bg, no Loop: a done window is left exactly as it
#                  was — same options, same timestamp
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX="$(command -v tmux 2>/dev/null)"
command -v python3 >/dev/null 2>&1 || { printf 'fleet-wait-reeval-selftest: python3 absent — SKIP\n'; exit 0; }
[ -n "$REAL_TMUX" ] || { printf 'fleet-wait-reeval-selftest: tmux absent — SKIP\n'; exit 0; }
CHECKS=0
fail() { printf 'fleet-wait-reeval-selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
eq() { CHECKS=$((CHECKS+1)); [ "$2" = "$3" ] || fail "$1 (want '$2', got '$3')" "${4:-}"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleetreeval.XXXXXX")" || exit 2
SOCK="$WORK/s"
tf() { "$REAL_TMUX" -S "$SOCK" "$@"; }
trap 'tf kill-server 2>/dev/null; pkill -f "snapshot-fleetreeval-$$" 2>/dev/null; rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM HUP
mkdir -p "$WORK/path" "$WORK/conf" "$WORK/proj" "$WORK/sessions" "$WORK/root/bin" "$WORK/root/logs"
cat > "$WORK/path/tmux" <<SH
#!/bin/sh
case "\${1:-}" in -L|-S) shift 2 ;; esac
exec "$REAL_TMUX" -S "$SOCK" "\$@"
SH
chmod +x "$WORK/path/tmux"
PATH="$WORK/path:$PATH"; export PATH
export FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1
export CLAUDE_PROJECTS_DIR="$WORK/proj" FLEET_CC_SESSIONS_DIR="$WORK/sessions"
export FLEET_CLAUDE_COMM="fakeclaude-fleetreeval-$$"
unset TMUX TMUX_PANE FLEET_MOD FLEET_WAIT_REEVAL
# A private root (bin/ of symlinks) so the via=reeval log lands in $WORK/root/logs,
# not the repo's; dotfiles too (fleet-sleep.py loads .fleet-transfer.py).
for f in "$BIN"/* "$BIN"/.[!.]*; do [ -e "$f" ] && ln -s "$f" "$WORK/root/bin/${f##*/}"; done
RB="$WORK/root/bin"
LOGF="$WORK/root/logs/reconcile.log"

FAKE="$WORK/$FLEET_CLAUDE_COMM.sh"
cat > "$FAKE" <<SH
#!/bin/bash
if [ "\${1:-}" = bg ]; then sh -c ': /shell-snapshots/snapshot-fleetreeval-$$; sleep 120; :' & fi
sleep 120 &
wait
SH
chmod +x "$FAKE"

SESS=fleet1376
tf -f /dev/null new-session -d -s "$SESS" -n par "exec sleep 300" || fail "cannot start isolated tmux"
win() {   # <name> <@issue> [@origin] [command] → window id
  local w
  w=$(tf new-window -d -P -F '#{window_id}' -t "$SESS" -n "$1" "${4:-exec sleep 300}")
  tf set-window-option -t "$w" @issue "$2"
  [ -n "${3:-}" ] && tf set-window-option -t "$w" @origin "$3"
  printf '%s' "$w"
}
PAR=$(tf display-message -p -t "$SESS:par" '#{window_id}')
tf set-window-option -t "$PAR" @issue 100
opt()  { tf display-message -p -t "$1" "#{$2}"; }
hasopt() { tf show-options -w -t "$1" 2>/dev/null | grep -q "^$2 "; }
re() { bash "$RB/fleet-wait-reeval.sh" "$@"; }
sw() { printf '%s %s' "$(opt "$1" @claude_state)" "$(opt "$1" @claude_wait)"; }

# --- A. children ------------------------------------------------------------------
tf set-window-option -t "$PAR" @claude_state 'done'
tf set-window-option -t "$PAR" @claude_state_ts 1000
K1=$(win kid1 101 issue-100)
tf set-window-option -t "$K1" @claude_state needs
out=$(re -- "$SESS")
eq "A: a done parent with an unfinished child → looping + children" "looping children" "$(sw "$PAR")"
case "$out" in *"reeval: $SESS:$PAR done -> looping (children)"*) CHECKS=$((CHECKS+1)) ;; *) fail "A: the change is printed" "$out" ;; esac
eq "A: the timestamp is left alone (nothing ran in the pane)" 1000 "$(opt "$PAR" @claude_state_ts)"
eq "A: …and the child is untouched" needs "$(opt "$K1" @claude_state)"
out=$(re -- "$SESS" | tail -1)
eq "A: a second run changes nothing" "changed=0 windows=1 fleets=1" "$out"
# a grandchild finishing → its parent (`looping` children) → done → the root → done, one run
tf set-window-option -t "$K1" @claude_state looping
tf set-window-option -t "$K1" @claude_wait children
K2=$(win kid2 102 issue-101)
tf set-window-option -t "$K2" @claude_state working
tf set-window-option -t "$K2" @claude_state 'done'
out=$(re -- "$SESS" | tail -1)
eq "A: the grandchild done → its parent done" 'done ' "$(sw "$K1")"
eq "A: …and the root done, in the same run (cascade)" 'done ' "$(sw "$PAR")"
eq "A: two changes counted" "changed=2 windows=3 fleets=1" "$out"
hasopt "$PAR" @claude_wait && fail "A: a lapsed reason is removed, not emptied" "$(tf show-options -w -t "$PAR")"
CHECKS=$((CHECKS+1))
tf kill-window -t "$K2"; tf kill-window -t "$K1"

# --- B. untouched -----------------------------------------------------------------
K1=$(win kid1 101 issue-100)
tf set-window-option -t "$K1" @claude_state working
for st in working needs; do
  tf set-window-option -t "$PAR" @claude_state "$st"
  re -- "$SESS" >/dev/null
  eq "B: a $st parent is never rewritten" "$st " "$(sw "$PAR")"
done
tf set-window-option -t "$PAR" @claude_state 'done'
tf set-window-option -t "$PAR" @worker_lifecycle sleeping
re -- "$SESS" >/dev/null
eq "B: a window in a sleep transition is left" 'done ' "$(sw "$PAR")"
tf set-window-option -u -t "$PAR" @worker_lifecycle
tf set-window-option -t "$K1" @claude_state 'done'
tf set-window-option -t "$PAR" @claude_state looping
re -- "$SESS" >/dev/null
eq "B: a reasonless looping (a screen read) is left" 'looping ' "$(sw "$PAR")"
tf kill-window -t "$K1"
tf set-window-option -t "$PAR" @claude_state 'done'

# --- C. bg ------------------------------------------------------------------------
BGW=$(win bgw 110 '' "exec bash $FAKE bg")
for _ in $(seq 1 50); do
  pgrep -f "snapshot-fleetreeval-$$" >/dev/null 2>&1 && break; sleep 0.1
done
tf set-window-option -t "$BGW" @claude_state 'done'
re -- "$SESS" >/dev/null
eq "C: an idle agent still owning a Bash-tool job → looping + bg" "looping bg" "$(sw "$BGW")"
pkill -f "snapshot-fleetreeval-$$" 2>/dev/null
for _ in $(seq 1 50); do pgrep -f "snapshot-fleetreeval-$$" >/dev/null 2>&1 || break; sleep 0.1; done
re -- "$SESS" >/dev/null
eq "C: the job ended → done" 'done ' "$(sw "$BGW")"
tf kill-window -t "$BGW"

# --- D. counts / dry-run / off / log ----------------------------------------------
K1=$(win kid1 101 issue-100)
tf set-window-option -t "$K1" @claude_state working
out=$(re --dry-run -- "$SESS")
eq "D: --dry-run reports the change…" "reeval: $SESS:$PAR done -> looping (children)
changed=1 windows=1 fleets=1" "$out"
eq "D: …and writes nothing" 'done ' "$(sw "$PAR")"
out=$(FLEET_WAIT_REEVAL=0 re -- "$SESS")
eq "D: FLEET_WAIT_REEVAL=0 is off" "changed=0 windows=0 fleets=0" "$out"
eq "D: …and writes nothing" 'done ' "$(sw "$PAR")"
: > "$LOGF"
out=$(re --quiet -- "$SESS")
eq "D: --quiet prints only the summary" "changed=1 windows=1 fleets=1" "$out"
grep -q "$SESS:$PAR *done -> looping (children) via=reeval" "$LOGF" || fail "D: the change is logged via=reeval" "$(cat "$LOGF")"
CHECKS=$((CHECKS+1))
out=$(re --window "$PAR" "$SESS")
eq "D: --window on an unchanged window" "changed=0 windows=1 fleets=1" "$out"

# --- E. a child's Stop re-asks its parent ------------------------------------------
P=$(tf display-message -p -t "$K1" '#{pane_id}')
env TMUX="$SOCK,1,0" TMUX_PANE="$P" sh "$BIN/set-claude-state.sh" 'done' </dev/null >/dev/null 2>&1
for _ in $(seq 1 50); do [ "$(opt "$PAR" @claude_state)" = 'done' ] && break; sleep 0.1; done
eq "E: the child stopped done" 'done' "$(opt "$K1" @claude_state)"
eq "E: …and its parent was re-asked → done" 'done ' "$(sw "$PAR")"
out=$(re --parent-of "$PAR" "$SESS")
eq "E: --parent-of a window with no @origin is a no-op" "changed=0 windows=0 fleets=1" "$out"
tf kill-window -t "$K1"

# --- F. degenerate ------------------------------------------------------------------
F=$(win plain 140)
tf set-window-option -t "$F" @claude_state 'done'
tf set-window-option -t "$F" @claude_needs ''
tf set-window-option -t "$F" @claude_state_ts 4242
before=$(tf show-options -w -t "$F")
out=$(re -- "$SESS" | tail -1)
eq "F: nothing waits → nothing changes" "changed=0" "${out%% *}"
eq "F: the window's options are byte for byte the same" "$before" "$(tf show-options -w -t "$F")"

printf 'fleet-wait-reeval-selftest: OK (%d checks)\n' "$CHECKS"
