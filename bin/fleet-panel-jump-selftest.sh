#!/bin/bash
# fleet-panel-jump-selftest.sh — the panels' 「到 …」 button (issue #2834, EPIC
# #2831): bin/fleet-panel-jump.sh goes through fleet_win_for_key and refuses
# rather than guesses. On an isolated tmux server:
#   A  orchestrator: one window wears @fleet_role orchestrator → exit 0, the
#      session's current window is it
#   B  NOTFOUND: no window wears the role → exit 1, the current window unchanged
#   C  AMBIGUOUS: two windows wear it → exit 2, the current window unchanged
#   D  no key / no pane → exit 3
# tmux absent → SKIP. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
command -v tmux >/dev/null 2>&1 || { echo 'panel-jump selftest: tmux absent — SKIP'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/panel-jump.XXXXXX")" || exit 2
L="pjump$$"
export FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$WORK/conf"
mkdir -p "$FLEET_CONF_DIR"
unset TMUX TMUX_PANE
cleanup() { tmux -L "$L" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

FAIL=0
pass() { printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

tmux -L "$L" -f /dev/null new-session -d -s "$L" -n steward -x 120 -y 30 'sleep 600'
tmux -L "$L" new-window -d -t "$L:" -n orch 'sleep 600'
tmux -L "$L" new-window -d -t "$L:" -n other 'sleep 600'
w_st=$(tmux -L "$L" display-message -p -t "$L:steward" '#{window_id}')
w_or=$(tmux -L "$L" display-message -p -t "$L:orch" '#{window_id}')
w_ot=$(tmux -L "$L" display-message -p -t "$L:other" '#{window_id}')
pane=$(tmux -L "$L" display-message -p -t "$L:steward" '#{pane_id}')
tmux -L "$L" set-option -w -t "$w_st" @fleet_role steward
sock=$(tmux -L "$L" display-message -p '#{socket_path}')
cur() { tmux -L "$L" display-message -p -t "$L:" '#{window_id}'; }
jump() { TMUX="$sock,1,0" TMUX_PANE="$pane" bash "$BIN/fleet-panel-jump.sh" "$@" 2>/dev/null; }

# B — nobody wears the role
tmux -L "$L" select-window -t "$w_st"
jump orchestrator; rc=$?
[ "$rc" = 1 ] && [ "$(cur)" = "$w_st" ] && pass "B: NOTFOUND → exit 1, nothing switched" || bad "B: rc=$rc cur=$(cur)"

# A — one orchestrator
tmux -L "$L" set-option -w -t "$w_or" @fleet_role orchestrator
jump orchestrator; rc=$?
[ "$rc" = 0 ] && [ "$(cur)" = "$w_or" ] && pass "A: orchestrator → exit 0, its window is current" || bad "A: rc=$rc cur=$(cur) want $w_or"

# C — two of them
tmux -L "$L" select-window -t "$w_st"
tmux -L "$L" set-option -w -t "$w_ot" @fleet_role orchestrator
jump orchestrator; rc=$?
[ "$rc" = 2 ] && [ "$(cur)" = "$w_st" ] && pass "C: AMBIGUOUS → exit 2, nothing switched" || bad "C: rc=$rc cur=$(cur)"

# D — usage
jump; rc=$?
TMUX="$sock,1,0" bash "$BIN/fleet-panel-jump.sh" orchestrator 2>/dev/null; rc2=$?
[ "$rc" = 3 ] && [ "$rc2" = 3 ] && pass "D: no key / no pane → exit 3" || bad "D: rc=$rc rc2=$rc2"

[ "$FAIL" = 0 ] && echo 'panel-jump selftest: all passed' && exit 0
exit 1
