#!/bin/bash
# fleet-wait-reeval-selftest.sh — an IDLE window's "still waiting?" is re-asked (issue #1376).
#
# The Stop hook decides `looping` + @claude_wait once (#1370); fleet-wait-reeval.sh
# re-asks it for windows that will not Stop again on their own. On an ISOLATED tmux
# socket (PATH-shim, never the live server) with a fake `claude`:
#   A. Parent    — old children reasons clear without consulting related Tasks;
#                  actual native needs/working observations stay untouched
#   B. untouched — working / needs / a reasonless looping (the
#                  classifier's screen read) are never rewritten
#   C. bg        — a Bash-tool job under an idle agent → looping + bg; it ends → done
#   D. counts    — the summary line (`changed= windows= fleets=`), --dry-run writes
#                  nothing, FLEET_WAIT_REEVAL=0 is off, the via=reeval log line
#   E. parent-of — the old option is inert; Stop touches only its own window
#   F. degenerate— no children, no bg, no Loop: a done window is left exactly as it
#                  was — same options, same timestamp
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
REAL_TMUX="$(command -v tmux 2>/dev/null)"
st_need python3
[ -n "$REAL_TMUX" ] || { printf 'fleet-wait-reeval-selftest: tmux absent — SKIP\n'; exit 0; }
st_tally count

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleetreeval.XXXXXX")" || exit 2
SOCK="$WORK/s"
tf() { "$REAL_TMUX" -S "$SOCK" "$@"; }
trap 'tf kill-server 2>/dev/null; pkill -f "snapshot-fleetreeval-$$" 2>/dev/null; rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM HUP
mkdir -p "$WORK/path" "$WORK/conf" "$WORK/proj" "$WORK/sessions" "$WORK/root/bin" "$WORK/root/logs"
st_tmux_socket "$WORK/path" "$SOCK" strip
PATH="$WORK/path:$PATH"; export PATH
export FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1
export CLAUDE_PROJECTS_DIR="$WORK/proj" FLEET_CC_SESSIONS_DIR="$WORK/sessions"
export FLEET_CLAUDE_COMM="fakeclaude-fleetreeval-$$"
unset TMUX TMUX_PANE FLEET_MOD FLEET_WAIT_REEVAL
# A private root (bin/ of symlinks) so the via=reeval log lands in $WORK/root/logs,
# not the repo's; dotfiles too (fleet_worker_life.py loads .fleet-transfer.py).
for f in "$BIN"/* "$BIN"/.[!.]*; do [ -e "$f" ] && ln -s "$f" "$WORK/root/bin/${f##*/}"; done
RB="$WORK/root/bin"
LOGF="$WORK/conf/logs/reconcile.log"

FAKE="$WORK/$FLEET_CLAUDE_COMM.sh"
cat > "$FAKE" <<SH
#!/bin/bash
if [ "\${1:-}" = bg ]; then sh -c ': /shell-snapshots/snapshot-fleetreeval-$$; sleep 120; :' & fi
sleep 120 &
wait
SH
chmod +x "$FAKE"

SESS=fleet1376
tf -f /dev/null new-session -d -s "$SESS" -n par "exec sleep 300" || st_fail "cannot start isolated tmux"
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

# --- A. old Parent reasons clear independently ------------------------------------
tf set-window-option -t "$PAR" @claude_state 'done'
tf set-window-option -t "$PAR" @claude_state_ts 1000
K1=$(win kid1 101 issue-100)
tf set-window-option -t "$K1" @claude_state needs
out=$(re -- "$SESS")
st_eq "A: another Task needing input never creates a wait here" 'done ' "$(sw "$PAR")"
st_eq "A: no state change is counted" "changed=0 windows=1 fleets=1" "$out"
st_eq "A: the timestamp is left alone (nothing ran in the pane)" 1000 "$(opt "$PAR" @claude_state_ts)"
st_eq "A: the other Task is untouched" needs "$(opt "$K1" @claude_state)"
# Both old reasons can be cleared in one pass, even while the last Task works.
tf set-window-option -t "$PAR" @claude_state looping
tf set-window-option -t "$PAR" @claude_wait children
tf set-window-option -t "$K1" @claude_state looping
tf set-window-option -t "$K1" @claude_wait children
K2=$(win kid2 102 issue-101)
tf set-window-option -t "$K2" @claude_state working
out=$(re -- "$SESS" | tail -1)
st_eq "A: the intermediate old children reason clears" 'done ' "$(sw "$K1")"
st_eq "A: the root old children reason clears" 'done ' "$(sw "$PAR")"
st_eq "A: the independent active Task stays working" working "$(opt "$K2" @claude_state)"
st_eq "A: only the two old reasons changed" "changed=2 windows=2 fleets=1" "$out"
hasopt "$PAR" @claude_wait && st_fail "A: a retired reason is removed, not emptied" "$(tf show-options -w -t "$PAR")"
CHECKS=$((CHECKS+1))
out=$(re -- "$SESS" | tail -1)
st_eq "A: a second run changes nothing" "changed=0 windows=2 fleets=1" "$out"
tf kill-window -t "$K2"; tf kill-window -t "$K1"

# --- B. untouched -----------------------------------------------------------------
K1=$(win kid1 101 issue-100)
tf set-window-option -t "$K1" @claude_state working
for st in working needs; do
  tf set-window-option -t "$PAR" @claude_state "$st"
  re -- "$SESS" >/dev/null
  st_eq "B: a $st parent is never rewritten" "$st " "$(sw "$PAR")"
done
tf set-window-option -t "$PAR" @claude_state 'done'
tf set-window-option -t "$K1" @claude_state 'done'
tf set-window-option -t "$PAR" @claude_state looping
re -- "$SESS" >/dev/null
st_eq "B: a reasonless looping (a screen read) is left" 'looping ' "$(sw "$PAR")"
tf kill-window -t "$K1"
tf set-window-option -t "$PAR" @claude_state 'done'

# --- C. bg ------------------------------------------------------------------------
BGW=$(win bgw 110 '' "exec bash $FAKE bg")
for _ in $(seq 1 50); do
  pgrep -f "snapshot-fleetreeval-$$" >/dev/null 2>&1 && break; sleep 0.1
done
tf set-window-option -t "$BGW" @claude_state 'done'
re -- "$SESS" >/dev/null
st_eq "C: an idle agent still owning a Bash-tool job → looping + bg" "looping bg" "$(sw "$BGW")"
pkill -f "snapshot-fleetreeval-$$" 2>/dev/null
for _ in $(seq 1 50); do pgrep -f "snapshot-fleetreeval-$$" >/dev/null 2>&1 || break; sleep 0.1; done
re -- "$SESS" >/dev/null
st_eq "C: the job ended → done" 'done ' "$(sw "$BGW")"
tf kill-window -t "$BGW"

# --- D. counts / dry-run / off / log ----------------------------------------------
K1=$(win kid1 101 issue-100)
tf set-window-option -t "$K1" @claude_state working
tf set-window-option -t "$PAR" @claude_state looping
tf set-window-option -t "$PAR" @claude_wait children
out=$(re --dry-run -- "$SESS")
st_eq "D: --dry-run reports the change…" "reeval: $SESS:$PAR looping (children) -> done
changed=1 windows=1 fleets=1" "$out"
st_eq "D: …and writes nothing" 'looping children' "$(sw "$PAR")"
out=$(FLEET_WAIT_REEVAL=0 re -- "$SESS")
st_eq "D: FLEET_WAIT_REEVAL=0 is off" "changed=0 windows=0 fleets=0" "$out"
st_eq "D: …and writes nothing" 'looping children' "$(sw "$PAR")"
: > "$LOGF"
out=$(re --quiet -- "$SESS")
st_eq "D: --quiet prints only the summary" "changed=1 windows=1 fleets=1" "$out"
grep -q "$SESS:$PAR *looping (children) -> done via=reeval" "$LOGF" || st_fail "D: the change is logged via=reeval" "$(cat "$LOGF")"
CHECKS=$((CHECKS+1))
out=$(re --window "$PAR" "$SESS")
st_eq "D: --window on an unchanged window" "changed=0 windows=1 fleets=1" "$out"

# --- E. Stop and legacy --parent-of cannot change another Task ---------------------
tf set-window-option -t "$PAR" @claude_state looping
tf set-window-option -t "$PAR" @claude_wait children
P=$(tf display-message -p -t "$K1" '#{pane_id}')
env TMUX="$SOCK,1,0" TMUX_PANE="$P" sh "$BIN/set-claude-state.sh" 'done' </dev/null >/dev/null 2>&1
st_eq "E: this Task stopped done" 'done' "$(opt "$K1" @claude_state)"
st_eq "E: Stop does not re-ask its former Parent" 'looping children' "$(sw "$PAR")"
out=$(re --parent-of "$K1" "$SESS")
st_eq "E: old --parent-of with a live origin is inert" "changed=0 windows=0 fleets=0" "$out"
st_eq "E: old entry changes no other window" 'looping children' "$(sw "$PAR")"
out=$(re --parent-of '' "$SESS")
st_eq "E: an empty legacy address cannot become a full-fleet sweep" "changed=0 windows=0 fleets=0" "$out"
out=$(re --parent-of)
st_eq "E: a missing legacy address is inert too" "changed=0 windows=0 fleets=0" "$out"
re --window "$PAR" "$SESS" >/dev/null
st_eq "E: normal self re-evaluation clears the old stamp" 'done ' "$(sw "$PAR")"
tf kill-window -t "$K1"

# --- F. degenerate ------------------------------------------------------------------
F=$(win plain 140)
tf set-window-option -t "$F" @claude_state 'done'
tf set-window-option -t "$F" @claude_needs ''
tf set-window-option -t "$F" @claude_state_ts 4242
before=$(tf show-options -w -t "$F")
out=$(re -- "$SESS" | tail -1)
st_eq "F: nothing waits → nothing changes" "changed=0" "${out%% *}"
st_eq "F: the window's options are byte for byte the same" "$before" "$(tf show-options -w -t "$F")"

printf 'fleet-wait-reeval-selftest: OK (%d checks)\n' "$CHECKS"
